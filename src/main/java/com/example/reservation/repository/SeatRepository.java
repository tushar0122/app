package com.example.reservation.repository;

import com.example.reservation.entity.Seat;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface SeatRepository extends JpaRepository<Seat, Long> {

    List<Seat> findByShowId(UUID showId);

    @Query("SELECT s FROM Seat s WHERE s.showId = :showId AND s.seatNumber IN :seatNumbers ORDER BY s.seatNumber")
    List<Seat> findByShowIdAndSeatNumberIn(@Param("showId") UUID showId,
                                           @Param("seatNumbers") List<String> seatNumbers);

    @Query(value = "SELECT * FROM seats WHERE show_id = :showId AND seat_number IN :seatNumbers ORDER BY seat_number FOR UPDATE",
           nativeQuery = true)
    List<Seat> findByShowIdAndSeatNumbersForUpdate(@Param("showId") UUID showId,
                                                    @Param("seatNumbers") List<String> seatNumbers);

    @Query(value = "SELECT s.* FROM seats s JOIN reservation_seats rs ON s.id = rs.seat_id " +
                   "WHERE rs.reservation_id = :reservationId ORDER BY s.seat_number FOR UPDATE",
           nativeQuery = true)
    List<Seat> findByReservationIdForUpdate(@Param("reservationId") UUID reservationId);

    long countByShowIdAndStatus(UUID showId, String status);
}
