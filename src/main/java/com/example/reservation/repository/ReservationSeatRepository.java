package com.example.reservation.repository;

import com.example.reservation.entity.ReservationSeat;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface ReservationSeatRepository extends JpaRepository<ReservationSeat, ReservationSeat.ReservationSeatId> {

    @Query("SELECT rs.seatId FROM ReservationSeat rs WHERE rs.reservationId = :reservationId")
    List<Long> findSeatIdsByReservationId(@Param("reservationId") UUID reservationId);
}
