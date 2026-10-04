package com.example.reservation.exception;

import java.util.UUID;

public class AlreadyCancelledException extends RuntimeException {
    public AlreadyCancelledException(UUID reservationId) {
        super("Reservation already cancelled: " + reservationId);
    }
}
