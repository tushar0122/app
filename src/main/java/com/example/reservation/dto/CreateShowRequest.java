package com.example.reservation.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.Positive;

import java.util.List;

public record CreateShowRequest(
        @NotBlank String name,
        @NotEmpty List<String> seats,
        @JsonProperty("price_paise") @Positive long pricePaise,
        @JsonProperty("per_user_limit") Integer perUserLimit
) {}
