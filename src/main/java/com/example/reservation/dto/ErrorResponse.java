package com.example.reservation.dto;

import com.fasterxml.jackson.annotation.JsonProperty;

public record ErrorResponse(
        String error,
        String message,
        @JsonProperty("request_id") String requestId
) {}
