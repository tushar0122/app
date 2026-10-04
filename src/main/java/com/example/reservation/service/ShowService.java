package com.example.reservation.service;

import com.example.reservation.dto.CreateShowRequest;
import com.example.reservation.dto.ShowResponse;
import com.example.reservation.entity.Seat;
import com.example.reservation.entity.Show;
import com.example.reservation.exception.ShowNotFoundException;
import com.example.reservation.repository.SeatRepository;
import com.example.reservation.repository.ShowRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;

@Service
public class ShowService {

    private static final Logger log = LoggerFactory.getLogger(ShowService.class);

    private final ShowRepository showRepository;
    private final SeatRepository seatRepository;

    public ShowService(ShowRepository showRepository, SeatRepository seatRepository) {
        this.showRepository = showRepository;
        this.seatRepository = seatRepository;
    }

    @Transactional
    public ShowResponse createShow(CreateShowRequest request) {
        Show show = new Show();
        show.setName(request.name());
        show.setPricePaise(request.pricePaise());
        show.setPerUserLimit(request.perUserLimit() != null ? request.perUserLimit() : 4);
        showRepository.save(show);

        List<Seat> seats = request.seats().stream().map(seatNumber -> {
            Seat seat = new Seat();
            seat.setShowId(show.getId());
            seat.setSeatNumber(seatNumber);
            return seat;
        }).toList();
        seatRepository.saveAll(seats);

        log.info("Created show id={} name={} seats={}", show.getId(), show.getName(), seats.size());
        return toResponse(show, seats);
    }

    @Transactional(readOnly = true)
    public ShowResponse getShow(UUID showId) {
        Show show = showRepository.findById(showId)
                .orElseThrow(() -> new ShowNotFoundException(showId));
        List<Seat> seats = seatRepository.findByShowId(showId);
        return toResponse(show, seats);
    }

    private ShowResponse toResponse(Show show, List<Seat> seats) {
        int available = 0, held = 0, confirmed = 0;
        for (Seat s : seats) {
            switch (s.getStatus()) {
                case "AVAILABLE" -> available++;
                case "HELD" -> held++;
                case "CONFIRMED" -> confirmed++;
            }
        }

        List<ShowResponse.SeatInfo> seatInfos = seats.stream()
                .map(s -> new ShowResponse.SeatInfo(s.getSeatNumber(), s.getStatus()))
                .toList();

        return new ShowResponse(
                show.getId(), show.getName(), show.getPricePaise(), show.getPerUserLimit(),
                seats.size(), available, held, confirmed, seatInfos
        );
    }
}
