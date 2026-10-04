package com.example.reservation.exception;

public class NotReservationOwnerException extends RuntimeException {
    public NotReservationOwnerException() {
        super("You are not the owner of this reservation");
    }
}
