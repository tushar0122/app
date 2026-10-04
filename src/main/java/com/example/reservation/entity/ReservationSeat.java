package com.example.reservation.entity;

import jakarta.persistence.*;
import java.io.Serializable;
import java.util.Objects;
import java.util.UUID;

@Entity
@Table(name = "reservation_seats")
@IdClass(ReservationSeat.ReservationSeatId.class)
public class ReservationSeat {

    @Id
    @Column(name = "reservation_id")
    private UUID reservationId;

    @Id
    @Column(name = "seat_id")
    private Long seatId;

    public UUID getReservationId() { return reservationId; }
    public void setReservationId(UUID reservationId) { this.reservationId = reservationId; }

    public Long getSeatId() { return seatId; }
    public void setSeatId(Long seatId) { this.seatId = seatId; }

    public static class ReservationSeatId implements Serializable {
        private UUID reservationId;
        private Long seatId;

        public ReservationSeatId() {}

        public ReservationSeatId(UUID reservationId, Long seatId) {
            this.reservationId = reservationId;
            this.seatId = seatId;
        }

        @Override
        public boolean equals(Object o) {
            if (this == o) return true;
            if (!(o instanceof ReservationSeatId that)) return false;
            return Objects.equals(reservationId, that.reservationId) && Objects.equals(seatId, that.seatId);
        }

        @Override
        public int hashCode() {
            return Objects.hash(reservationId, seatId);
        }
    }
}
