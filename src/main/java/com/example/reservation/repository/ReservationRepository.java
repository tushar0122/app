package com.example.reservation.repository;

import com.example.reservation.entity.Reservation;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Optional;
import java.util.UUID;

public interface ReservationRepository extends JpaRepository<Reservation, UUID> {

    Optional<Reservation> findByUserIdAndIdempotencyKey(String userId, String idempotencyKey);

    @Modifying
    @Query(value = "INSERT INTO reservations (id, show_id, user_id, amount_paise, status, idempotency_key, request_hash, created_at) " +
                   "VALUES (:id, :showId, :userId, :amountPaise, 'CONFIRMED', :idempotencyKey, :requestHash, now()) " +
                   "ON CONFLICT (user_id, idempotency_key) DO NOTHING",
           nativeQuery = true)
    int insertIfAbsent(@Param("id") UUID id,
                       @Param("showId") UUID showId,
                       @Param("userId") String userId,
                       @Param("amountPaise") long amountPaise,
                       @Param("idempotencyKey") String idempotencyKey,
                       @Param("requestHash") String requestHash);
}
