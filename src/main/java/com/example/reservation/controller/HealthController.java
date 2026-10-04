package com.example.reservation.controller;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import javax.sql.DataSource;
import java.sql.Connection;
import java.util.Map;

@RestController
@RequestMapping("/health")
public class HealthController {

    private final DataSource dataSource;

    public HealthController(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    @GetMapping("/live")
    public ResponseEntity<Map<String, String>> liveness() {
        return ResponseEntity.ok(Map.of("status", "UP"));
    }

    @GetMapping("/ready")
    public ResponseEntity<Map<String, String>> readiness() {
        try (Connection conn = dataSource.getConnection()) {
            conn.createStatement().execute("SELECT 1");
            return ResponseEntity.ok(Map.of("status", "UP", "database", "reachable"));
        } catch (Exception e) {
            return ResponseEntity.status(503).body(Map.of("status", "DOWN", "database", "unreachable"));
        }
    }
}
