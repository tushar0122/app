package com.example.reservation.exception;

public class SeatTakenException extends RuntimeException {
    public SeatTakenException(String message) {
        super(message);
    }
}
