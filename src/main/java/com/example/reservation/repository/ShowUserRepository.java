package com.example.reservation.repository;

import com.example.reservation.entity.ShowUser;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Optional;
import java.util.UUID;

public interface ShowUserRepository extends JpaRepository<ShowUser, ShowUser.ShowUserId> {

    @Modifying
    @Query(value = "INSERT INTO show_user (show_id, user_id, reserved_count) VALUES (:showId, :userId, 0) ON CONFLICT DO NOTHING",
           nativeQuery = true)
    void createIfAbsent(@Param("showId") UUID showId, @Param("userId") String userId);

    @Query(value = "SELECT * FROM show_user WHERE show_id = :showId AND user_id = :userId FOR UPDATE",
           nativeQuery = true)
    Optional<ShowUser> findByShowIdAndUserIdForUpdate(@Param("showId") UUID showId,
                                                      @Param("userId") String userId);
}
