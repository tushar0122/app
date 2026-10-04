package com.example.reservation.controller;

import com.example.reservation.dto.ReservationResponse;
import com.example.reservation.dto.ReserveRequest;
import com.example.reservation.service.ReservationService;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.*;

import java.util.UUID;

@RestController
public class ReservationController {

    private final ReservationService reservationService;

    public ReservationController(ReservationService reservationService) {
        this.reservationService = reservationService;
    }

    @PostMapping("/shows/{showId}/reserve")
    public ResponseEntity<ReservationResponse> reserve(
            @PathVariable UUID showId,
            @RequestHeader("Idempotency-Key") String idempotencyKey,
            @Valid @RequestBody ReserveRequest request,
            Authentication authentication) {

        String userId = authentication.getName();
        ReservationResponse response = reservationService.reserve(showId, userId, idempotencyKey, request);
        return ResponseEntity.status(HttpStatus.CREATED).body(response);
    }

    @PostMapping("/reservations/{reservationId}/cancel")
    public ResponseEntity<ReservationResponse> cancel(
            @PathVariable UUID reservationId,
            Authentication authentication) {

        String userId = authentication.getName();
        ReservationResponse response = reservationService.cancel(reservationId, userId);
        return ResponseEntity.ok(response);
    }
}
