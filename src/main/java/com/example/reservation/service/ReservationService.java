package com.example.reservation.service;

import com.example.reservation.dto.ReservationResponse;
import com.example.reservation.dto.ReserveRequest;
import com.example.reservation.entity.*;
import com.example.reservation.exception.*;
import com.example.reservation.repository.*;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
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
                .findByShowIdAndUserIdAndIdempotencyKey(showId, userId, idempotencyKey);
        if (existing.isPresent()) {
            return handleIdempotency(existing.get(), requestHash);
        }

        // 2. Load show
        Show show = showRepository.findById(showId)
                .orElseThrow(() -> new ShowNotFoundException(showId));

        // 3. Ensure show_user row exists (ON CONFLICT DO NOTHING makes concurrent first-timers safe)
        showUserRepository.createIfAbsent(showId, userId);

        // 4. Lock show_user row
        ShowUser showUser = showUserRepository
                .findByShowIdAndUserIdForUpdate(showId, userId)
                .orElseThrow(() -> new IllegalStateException("show_user row was not created"));

        // 5. Re-check idempotency after serialization.
        //    Under READ COMMITTED, this now sees any reservation committed
        //    by a concurrent request that held this lock before us.
        existing = reservationRepository
                .findByShowIdAndUserIdAndIdempotencyKey(showId, userId, idempotencyKey);
        if (existing.isPresent()) {
            return handleIdempotency(existing.get(), requestHash);
        }

        // 6. Per-user limit check
        int currentCount = showUser.getReservedCount();
        if (currentCount + sortedSeats.size() > show.getPerUserLimit()) {
            log.info("Per-user limit exceeded user={} show={} current={} requested={}",
                    userId, showId, currentCount, sortedSeats.size());
            throw new PerUserLimitException("Per-user limit of " + show.getPerUserLimit() + " exceeded");
        }

        // 7. Lock seat rows in deterministic order and check availability
        List<Seat> seats = seatRepository.findByShowIdAndSeatNumbersForUpdate(showId, sortedSeats);

        if (seats.size() != sortedSeats.size()) {
            throw new InvalidSeatException("One or more requested seats do not exist in this show");
        }

        for (Seat seat : seats) {
            if (!"AVAILABLE".equals(seat.getStatus())) {
                log.info("Seat taken seat={} show={} user={}", seat.getSeatNumber(), showId, userId);
                throw new SeatTakenException("One or more requested seats are already reserved");
            }
        }

        // 8. All checks passed — insert reservation
        UUID reservationId = UUID.randomUUID();
        long amountPaise = show.getPricePaise() * sortedSeats.size();

        Reservation reservation = new Reservation();
        reservation.setId(reservationId);
        reservation.setShowId(showId);
        reservation.setUserId(userId);
        reservation.setAmountPaise(amountPaise);
        reservation.setStatus("CONFIRMED");
        reservation.setIdempotencyKey(idempotencyKey);
        reservation.setRequestHash(requestHash);
        reservationRepository.save(reservation);

        // 9. Create reservation_seats and update seat status
        for (Seat seat : seats) {
            ReservationSeat rs = new ReservationSeat();
            rs.setReservationId(reservationId);
            rs.setSeatId(seat.getId());
            reservationSeatRepository.save(rs);

            seat.setStatus("CONFIRMED");
            seatRepository.save(seat);
        }

        // 10. Update show_user counter
        showUser.setReservedCount(showUser.getReservedCount() + sortedSeats.size());
        showUserRepository.save(showUser);

        log.info("Reservation confirmed id={} show={} user={} seats={}",
                reservationId, showId, userId, sortedSeats);

        return new ReservationResponse(
                reservationId, showId, userId, sortedSeats, amountPaise, "CONFIRMED");
    }

    @Transactional
    public ReservationResponse cancel(UUID reservationId, String userId) {
        // 1. Read reservation (no lock yet — just to get show_id and verify existence/ownership)
        Reservation reservation = reservationRepository.findById(reservationId)
                .orElseThrow(() -> new ReservationNotFoundException(reservationId));

        if (!reservation.getUserId().equals(userId)) {
            throw new NotReservationOwnerException();
        }

        // 2. Lock show_user first — same order as reserve flow to prevent deadlocks
        ShowUser showUser = showUserRepository
                .findByShowIdAndUserIdForUpdate(reservation.getShowId(), userId)
                .orElseThrow(() -> new IllegalStateException("show_user row not found"));

        // 3. Lock reservation row
        reservation = reservationRepository.findByIdForUpdate(reservationId)
                .orElseThrow(() -> new ReservationNotFoundException(reservationId));

        if ("CANCELLED".equals(reservation.getStatus())) {
            throw new AlreadyCancelledException(reservationId);
        }

        // 4. Lock associated seats and set to AVAILABLE
        List<Seat> seats = seatRepository.findByReservationIdForUpdate(reservationId);
        for (Seat seat : seats) {
            seat.setStatus("AVAILABLE");
            seatRepository.save(seat);
        }

        // 5. Update reservation status
        reservation.setStatus("CANCELLED");
        reservation.setCancelledAt(java.time.Instant.now());
        reservationRepository.save(reservation);

        // 6. Decrement show_user counter
        showUser.setReservedCount(showUser.getReservedCount() - seats.size());
        showUserRepository.save(showUser);

        List<String> seatNumbers = seats.stream().map(Seat::getSeatNumber).sorted().toList();
        log.info("Reservation cancelled id={} user={} seats={}", reservationId, userId, seatNumbers);

        return toResponse(reservation, seatNumbers);
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
