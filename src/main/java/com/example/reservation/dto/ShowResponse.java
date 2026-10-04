package com.example.reservation.dto;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.util.List;
import java.util.UUID;

public record ShowResponse(
        @JsonProperty("show_id") UUID showId,
        String name,
        @JsonProperty("price_paise") long pricePaise,
        @JsonProperty("per_user_limit") int perUserLimit,
        @JsonProperty("total_seats") int totalSeats,
        int available,
        int held,
        int confirmed,
        List<SeatInfo> seats
) {
    public record SeatInfo(String seat, String status) {}
}
