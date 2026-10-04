package com.example.reservation.service;

import com.example.reservation.dto.ReservationResponse;
import com.example.reservation.dto.ReserveRequest;
import com.example.reservation.entity.*;
import com.example.reservation.exception.*;
import com.example.reservation.repository.*;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.*;

@Service
public class ReservationService {

    private static final Logger log = LoggerFactory.getLogger(ReservationService.class);

    private final ShowRepository showRepository;
    private final SeatRepository seatRepository;
    private final ReservationRepository reservationRepository;
    private final ReservationSeatRepository reservationSeatRepository;
    private final ShowUserRepository showUserRepository;

    public ReservationService(ShowRepository showRepository,
                              SeatRepository seatRepository,
                              ReservationRepository reservationRepository,
                              ReservationSeatRepository reservationSeatRepository,
                              ShowUserRepository showUserRepository) {
        this.showRepository = showRepository;
        this.seatRepository = seatRepository;
        this.reservationRepository = reservationRepository;
        this.reservationSeatRepository = reservationSeatRepository;
        this.showUserRepository = showUserRepository;
    }

    @Transactional
    public ReservationResponse reserve(UUID showId, String userId, String idempotencyKey,
                                       ReserveRequest request) {
        List<String> sortedSeats = request.seats().stream().sorted().toList();
        String requestHash = hashSeats(sortedSeats);

        // 1. Idempotency check
        Optional<Reservation> existing = reservationRepository
                .findByUserIdAndIdempotencyKey(userId, idempotencyKey);
        if (existing.isPresent()) {
            return handleIdempotency(existing.get(), requestHash);
        }

        // 2. Load show
        Show show = showRepository.findById(showId)
                .orElseThrow(() -> new ShowNotFoundException(showId));

        // 3. Lock show_user row and check per-user limit
        ShowUser showUser = showUserRepository
                .findByShowIdAndUserIdForUpdate(showId, userId)
                .orElse(null);

        int currentCount = showUser != null ? showUser.getReservedCount() : 0;
        if (currentCount + sortedSeats.size() > show.getPerUserLimit()) {
            log.info("Per-user limit exceeded user={} show={} current={} requested={}",
                    userId, showId, currentCount, sortedSeats.size());
            throw new PerUserLimitException("Per-user limit of " + show.getPerUserLimit() + " exceeded");
        }

        // 4. Lock seat rows in deterministic order and check availability
        List<Seat> seats = seatRepository.findByShowIdAndSeatNumbersForUpdate(showId, sortedSeats);

        if (seats.size() != sortedSeats.size()) {
            throw new SeatTakenException("One or more requested seats do not exist");
        }

        for (Seat seat : seats) {
            if (!"AVAILABLE".equals(seat.getStatus())) {
                log.info("Seat taken seat={} show={} user={}", seat.getSeatNumber(), showId, userId);
                throw new SeatTakenException("One or more requested seats are already reserved");
            }
        }

        // 5. Create reservation
        Reservation reservation = new Reservation();
        reservation.setShowId(showId);
        reservation.setUserId(userId);
        reservation.setAmountPaise(show.getPricePaise() * sortedSeats.size());
        reservation.setIdempotencyKey(idempotencyKey);
        reservation.setRequestHash(requestHash);

        try {
            reservationRepository.save(reservation);
            reservationRepository.flush();
        } catch (DataIntegrityViolationException e) {
            // Concurrent request with same idempotency key won the race
            Reservation winner = reservationRepository
                    .findByUserIdAndIdempotencyKey(userId, idempotencyKey)
                    .orElseThrow(() -> e);
            return handleIdempotency(winner, requestHash);
        }

        // 6. Create reservation_seats and update seat status
        for (Seat seat : seats) {
            ReservationSeat rs = new ReservationSeat();
            rs.setReservationId(reservation.getId());
            rs.setSeatId(seat.getId());
            reservationSeatRepository.save(rs);

            seat.setStatus("CONFIRMED");
            seatRepository.save(seat);
        }

        // 7. Update show_user counter
        if (showUser == null) {
            showUser = new ShowUser();
            showUser.setShowId(showId);
            showUser.setUserId(userId);
            showUser.setReservedCount(sortedSeats.size());
        } else {
            showUser.setReservedCount(showUser.getReservedCount() + sortedSeats.size());
        }
        showUserRepository.save(showUser);

        log.info("Reservation confirmed id={} show={} user={} seats={}",
                reservation.getId(), showId, userId, sortedSeats);

        return toResponse(reservation, sortedSeats);
    }

    private ReservationResponse handleIdempotency(Reservation existing, String requestHash) {
        if (!existing.getRequestHash().equals(requestHash)) {
            throw new IdempotencyConflictException(
                    "Idempotency key already used with different request");
        }
        List<Long> seatIds = reservationSeatRepository.findSeatIdsByReservationId(existing.getId());
        List<String> seatNumbers = seatRepository.findAllById(seatIds).stream()
                .map(Seat::getSeatNumber)
                .sorted()
                .toList();
        log.info("Idempotent replay id={} user={}", existing.getId(), existing.getUserId());
        return toResponse(existing, seatNumbers);
    }

    private ReservationResponse toResponse(Reservation reservation, List<String> seatNumbers) {
        return new ReservationResponse(
                reservation.getId(),
                reservation.getShowId(),
                reservation.getUserId(),
                seatNumbers,
                reservation.getAmountPaise(),
                reservation.getStatus()
        );
    }

    private String hashSeats(List<String> sortedSeats) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] hash = digest.digest(String.join(",", sortedSeats).getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(hash);
        } catch (NoSuchAlgorithmException e) {
            throw new RuntimeException(e);
        }
    }
}
