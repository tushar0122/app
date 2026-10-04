package com.example.reservation.repository;

import com.example.reservation.entity.ShowUser;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Optional;
import java.util.UUID;

public interface ShowUserRepository extends JpaRepository<ShowUser, ShowUser.ShowUserId> {

    @Query(value = "SELECT * FROM show_user WHERE show_id = :showId AND user_id = :userId FOR UPDATE",
           nativeQuery = true)
    Optional<ShowUser> findByShowIdAndUserIdForUpdate(@Param("showId") UUID showId,
                                                      @Param("userId") String userId);
}
