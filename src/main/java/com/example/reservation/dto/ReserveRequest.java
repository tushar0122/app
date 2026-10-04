package com.example.reservation.dto;

import jakarta.validation.constraints.NotEmpty;

import java.util.List;

public record ReserveRequest(
        @NotEmpty List<String> seats
) {}
