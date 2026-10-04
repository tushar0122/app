package com.example.reservation.exception;

import com.example.reservation.dto.ErrorResponse;
import org.slf4j.MDC;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

@RestControllerAdvice
public class GlobalExceptionHandler {

    @ExceptionHandler(ShowNotFoundException.class)
    public ResponseEntity<ErrorResponse> handleShowNotFound(ShowNotFoundException ex) {
        return ResponseEntity.status(HttpStatus.NOT_FOUND)
                .body(new ErrorResponse("SHOW_NOT_FOUND", ex.getMessage(), MDC.get("requestId")));
    }

    @ExceptionHandler(SeatTakenException.class)
    public ResponseEntity<ErrorResponse> handleSeatTaken(SeatTakenException ex) {
        return ResponseEntity.status(HttpStatus.CONFLICT)
                .body(new ErrorResponse("SEAT_TAKEN", ex.getMessage(), MDC.get("requestId")));
    }

    @ExceptionHandler(PerUserLimitException.class)
    public ResponseEntity<ErrorResponse> handlePerUserLimit(PerUserLimitException ex) {
        return ResponseEntity.status(HttpStatus.CONFLICT)
                .body(new ErrorResponse("PER_USER_LIMIT_EXCEEDED", ex.getMessage(), MDC.get("requestId")));
    }

    @ExceptionHandler(IdempotencyConflictException.class)
    public ResponseEntity<ErrorResponse> handleIdempotencyConflict(IdempotencyConflictException ex) {
        return ResponseEntity.status(HttpStatus.CONFLICT)
                .body(new ErrorResponse("IDEMPOTENCY_KEY_REUSED", ex.getMessage(), MDC.get("requestId")));
    }

    @ExceptionHandler(AlreadyCancelledException.class)
    public ResponseEntity<ErrorResponse> handleAlreadyCancelled(AlreadyCancelledException ex) {
        return ResponseEntity.status(HttpStatus.CONFLICT)
                .body(new ErrorResponse("ALREADY_CANCELLED", ex.getMessage(), MDC.get("requestId")));
    }

    @ExceptionHandler(ReservationNotFoundException.class)
    public ResponseEntity<ErrorResponse> handleReservationNotFound(ReservationNotFoundException ex) {
        return ResponseEntity.status(HttpStatus.NOT_FOUND)
                .body(new ErrorResponse("RESERVATION_NOT_FOUND", ex.getMessage(), MDC.get("requestId")));
    }

    @ExceptionHandler(NotReservationOwnerException.class)
    public ResponseEntity<ErrorResponse> handleNotOwner(NotReservationOwnerException ex) {
        return ResponseEntity.status(HttpStatus.FORBIDDEN)
                .body(new ErrorResponse("NOT_RESERVATION_OWNER", ex.getMessage(), MDC.get("requestId")));
    }

    @ExceptionHandler(InvalidSeatException.class)
    public ResponseEntity<ErrorResponse> handleInvalidSeat(InvalidSeatException ex) {
        return ResponseEntity.badRequest()
                .body(new ErrorResponse("INVALID_SEAT", ex.getMessage(), MDC.get("requestId")));
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<ErrorResponse> handleValidation(MethodArgumentNotValidException ex) {
        return ResponseEntity.badRequest()
                .body(new ErrorResponse("INVALID_REQUEST", "Invalid request body", MDC.get("requestId")));
    }

    @ExceptionHandler(org.springframework.web.bind.MissingRequestHeaderException.class)
    public ResponseEntity<ErrorResponse> handleMissingHeader(
            org.springframework.web.bind.MissingRequestHeaderException ex) {
        return ResponseEntity.badRequest()
                .body(new ErrorResponse("INVALID_REQUEST", ex.getMessage(), MDC.get("requestId")));
    }
}
