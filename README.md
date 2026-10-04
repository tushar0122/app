# Seat Reservation Service

Correct-under-concurrency seat reservation API. Never double-sells a seat, enforces per-user booking limits under load, and handles idempotent retries — even when thousands of buyers hit the same seat simultaneously.

**Stack:** Java 21, Spring Boot 3.4, PostgreSQL 16, Docker

---

## Burst Test Script

The included `burst.sh` script fires concurrent HTTP requests against a running instance to verify correctness under load. It covers four scenarios:

| Test | What it does |
|------|-------------|
| **Hot-Seat Storm** | N users race for the same seat — exactly 1 must win, 0 server errors |
| **Per-User Limit** | One user fires requests exceeding the booking limit — confirmed count never exceeds the cap |
| **Idempotency** | 50 identical requests (same user, same key, same seat) — exactly 1 reservation in DB |
| **Cancel + Re-reserve** | Reserve, cancel, double-cancel (409), re-reserve by another user |

### Run it

```bash
# Start the service
docker compose up -d

# Run with defaults (200 users, 50 parallel workers)
./burst.sh

# Custom target and concurrency
./burst.sh http://localhost:8080 your-jwt-secret

# Tune the blast
HOT_SEAT_USERS=1000 PARALLEL=200 ./burst.sh

# Windows CMD / PowerShell (requires Git for Windows)
bash burst.sh
bash burst.sh http://localhost:8080
HOT_SEAT_USERS=500 PARALLEL=100 bash burst.sh
```

### Requirements

- `curl`, `openssl`, `awk` (standard on Linux/macOS)
- **Windows:** works with [Git Bash](https://gitforwindows.org/) (bundled with Git for Windows)
- A running instance with the matching `JWT_SECRET`

---

## Quick Start

### Docker Compose (recommended)

```bash
docker compose up -d
```

This starts PostgreSQL 16 and the app. The API is available at `http://localhost:8080`.

### Local Development

Prerequisites: Java 21, Maven, PostgreSQL 16 running locally.

```bash
export PGHOST=localhost PGPORT=5432 PGDATABASE=reservation PGUSER=reservation PGPASSWORD=reservation
export JWT_SECRET=super-secret-key-for-development-only-change-in-production-min-32-chars
mvn spring-boot:run
```

---

## Configuration

All configuration is via environment variables — no defaults baked in for database credentials.

| Variable | Description | Default |
|----------|-------------|---------|
| `PGHOST` | PostgreSQL host | *(required)* |
| `PGPORT` | PostgreSQL port | *(required)* |
| `PGDATABASE` | Database name | *(required)* |
| `PGUSER` | Database user | *(required)* |
| `PGPASSWORD` | Database password | *(required)* |
| `JWT_SECRET` | HMAC-SHA256 signing key (min 32 chars) | dev-only fallback |
| `PORT` | HTTP server port | `8080` |

---

## API

Interactive docs available at `/swagger-ui/index.html` when the service is running.

### Public

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/shows/{id}` | Show details with seat availability counts |
| `GET` | `/health/live` | Liveness probe (app up) |
| `GET` | `/health/ready` | Readiness probe (DB reachable) |

### Authenticated (JWT Bearer)

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/shows` | Create a show *(admin role required)* |
| `POST` | `/shows/{id}/reserve` | Reserve seats (requires `Idempotency-Key` header) |
| `POST` | `/reservations/{id}/cancel` | Cancel a reservation (owner only) |

### Authentication

Requests carry a JWT in the `Authorization: Bearer <token>` header. The token is HMAC-SHA256 signed with the configured `JWT_SECRET`.

Claims:
- `sub` — user ID (any string)
- `role` — set to `admin` for show creation (omit for regular users)

#### Generating a JWT token

Tokens are signed with the `JWT_SECRET` env var. For local development with the default secret, you can generate tokens using bash + openssl:

```bash
# Helper function
jwt() {
  local secret="super-secret-key-for-development-only-change-in-production-min-32-chars"
  local header=$(echo -n '{"alg":"HS256","typ":"JWT"}' | openssl enc -base64 -A | tr '+/' '-_' | tr -d '=')
  local payload=$(echo -n "$1" | openssl enc -base64 -A | tr '+/' '-_' | tr -d '=')
  local sig=$(echo -n "$header.$payload" | openssl dgst -sha256 -hmac "$secret" -binary | openssl enc -base64 -A | tr '+/' '-_' | tr -d '=')
  echo "$header.$payload.$sig"
}

# Admin token (can create shows)
jwt '{"sub":"admin-1","role":"admin"}'

# Regular user token (can reserve/cancel)
jwt '{"sub":"user-1"}'
```

Or use any JWT library — the token just needs `{"alg":"HS256"}` header, a `sub` claim, and HMAC-SHA256 signature with the secret.

#### Pre-generated dev tokens

These tokens work with the default dev secret (do not use in production):

| Role | Token |
|------|-------|
| Admin | `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhZG1pbi0xIiwicm9sZSI6ImFkbWluIn0.h_ltaIcmJXgQmvvCjCf5T1i0KsDSo0ohmNfzGHhmFGs` |
| User-1 | `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyLTEifQ.P1kjROjO4vn9zD1ypnXeHbypB4u5V32o7FC-okoEG0Y` |
| User-2 | `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyLTIifQ.28JMVMkE4mg-oight7aPui_2Os-RGZGj7oWP8N-hX0Y` |

### Testing the API

After starting the service (`docker compose up -d`), test the full flow:

```bash
# Variables (use pre-generated tokens above or generate your own)
BASE=http://localhost:8080
ADMIN=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhZG1pbi0xIiwicm9sZSI6ImFkbWluIn0.h_ltaIcmJXgQmvvCjCf5T1i0KsDSo0ohmNfzGHhmFGs
USER1=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyLTEifQ.P1kjROjO4vn9zD1ypnXeHbypB4u5V32o7FC-okoEG0Y

# 1. Health check
curl $BASE/health/ready

# 2. Create a show (admin only)
curl -X POST $BASE/shows \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $ADMIN" \
  -d '{"name":"Avengers","seats":["A1","A2","A3","B1","B2"],"price_paise":50000,"per_user_limit":2}'

# 3. View show details (public, no auth needed)
curl $BASE/shows/<show_id>

# 4. Reserve seats
curl -X POST $BASE/shows/<show_id>/reserve \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $USER1" \
  -H "Idempotency-Key: my-unique-key-1" \
  -d '{"seats":["A1","A2"]}'

# 5. Cancel a reservation
curl -X POST $BASE/reservations/<reservation_id>/cancel \
  -H "Authorization: Bearer $USER1"
```

Replace `<show_id>` and `<reservation_id>` with values from the responses.

**PowerShell / CMD users:** Use Git Bash to run the above, or replace single quotes with double quotes and escape inner quotes:

```powershell
curl -X POST http://localhost:8080/shows `
  -H "Content-Type: application/json" `
  -H "Authorization: Bearer $ADMIN" `
  -d "{\"name\":\"Avengers\",\"seats\":[\"A1\",\"A2\"],\"price_paise\":50000,\"per_user_limit\":2}"
```

### Reserve Request

```json
POST /shows/{id}/reserve
Idempotency-Key: unique-key-per-attempt

{
  "seats": ["A1", "A2"]
}
```

**201** — reservation confirmed, returns reservation ID, seats, and total price (integer paise).

**409** — seat taken, per-user limit exceeded, idempotency key reused with different seats, or already cancelled.

---

## Concurrency Model

All reservation decisions happen inside a single PostgreSQL transaction using `SELECT ... FOR UPDATE` row-level locks:

1. Lock `show_user(show_id, user_id)` — serializes requests from the same user
2. Lock seat rows in sorted order — prevents deadlocks across multi-seat requests
3. Check-then-mutate under lock — no window for races

The cancel flow locks in the same order (`show_user` then seats) to prevent cross-flow deadlocks.

Idempotency uses a two-layer check: a fast pre-lock lookup, then a post-lock re-check under `READ COMMITTED` isolation. The unique constraint `(show_id, user_id, idempotency_key)` aligns with the `show_user` lock scope, making both layers race-free without `ON CONFLICT` fallbacks.

See [WRITEUP.md](WRITEUP.md) for the full design rationale.

---

## Observability

### Metrics

Prometheus endpoint at `/actuator/prometheus`:

- `reservations_confirmed_total` — successful reservations
- `reservations_cancelled_total` — successful cancellations
- `reservations_declined_total{reason=seat_taken|per_user_limit|idempotent_replay}` — decline counters
- `http_server_requests_seconds` — request latency by endpoint (Spring Boot auto)
- HikariCP pool metrics — connection pool utilization (auto)

### Structured Logging

JSON logs with `request_id` correlation (from `X-Request-ID` header or auto-generated UUID):

```json
{"timestamp":"...","level":"INFO","logger":"...","request_id":"abc-123","message":"Reservation confirmed ..."}
```

---

## Project Structure

```
├── burst.sh                          # Concurrency test script
├── docker-compose.yml                # PostgreSQL + app
├── Dockerfile                        # Multi-stage build, non-root user
├── WRITEUP.md                        # Design rationale and decisions
├── docs/
│   ├── problem.md                    # Problem statement
│   └── design.md                     # High-level design
└── src/main/java/com/example/reservation/
    ├── controller/                   # REST endpoints
    ├── service/                      # Business logic + transactions
    ├── entity/                       # JPA entities
    ├── dto/                          # Request/response records
    ├── repository/                   # Spring Data + native queries
    ├── security/                     # JWT filter + Spring Security config
    ├── config/                       # OpenAPI config
    └── exception/                    # Domain exceptions + global handler
```
