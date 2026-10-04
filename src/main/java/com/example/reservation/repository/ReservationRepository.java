package com.example.reservation.repository;

import com.example.reservation.entity.Reservation;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Optional;
import java.util.UUID;

public interface ReservationRepository extends JpaRepository<Reservation, UUID> {

    Optional<Reservation> findByShowIdAndUserIdAndIdempotencyKey(UUID showId, String userId, String idempotencyKey);

    @Query(value = "SELECT * FROM reservations WHERE id = :id FOR UPDATE", nativeQuery = true)
    Optional<Reservation> findByIdForUpdate(@Param("id") UUID id);
}
