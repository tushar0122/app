package com.example.reservation.entity;

import jakarta.persistence.*;
import java.io.Serializable;
import java.util.Objects;
import java.util.UUID;

@Entity
@Table(name = "show_user")
@IdClass(ShowUser.ShowUserId.class)
public class ShowUser {

    @Id
    @Column(name = "show_id")
    private UUID showId;

    @Id
    @Column(name = "user_id")
    private String userId;

    @Column(name = "reserved_count", nullable = false)
    private int reservedCount = 0;

    public UUID getShowId() { return showId; }
    public void setShowId(UUID showId) { this.showId = showId; }

    public String getUserId() { return userId; }
    public void setUserId(String userId) { this.userId = userId; }

    public int getReservedCount() { return reservedCount; }
    public void setReservedCount(int reservedCount) { this.reservedCount = reservedCount; }

    public static class ShowUserId implements Serializable {
        private UUID showId;
        private String userId;

        public ShowUserId() {}

        public ShowUserId(UUID showId, String userId) {
            this.showId = showId;
            this.userId = userId;
        }

        @Override
        public boolean equals(Object o) {
            if (this == o) return true;
            if (!(o instanceof ShowUserId that)) return false;
            return Objects.equals(showId, that.showId) && Objects.equals(userId, that.userId);
        }

        @Override
        public int hashCode() {
            return Objects.hash(showId, userId);
        }
    }
}
