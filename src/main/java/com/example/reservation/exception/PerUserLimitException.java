package com.example.reservation.exception;

public class PerUserLimitException extends RuntimeException {
    public PerUserLimitException(String message) {
        super(message);
    }
}
