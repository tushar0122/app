# Write-Up

## 1. The Atomic Decision

Every reservation decision happens inside a single PostgreSQL transaction using `SELECT ... FOR UPDATE` row-level locks. There is no separate "check then update" — the check and the mutation happen while the calling transaction holds the lock, so no other transaction can interleave.

### Reserve flow (10 steps, one transaction)

1. **Fast-path idempotency check** — read-only lookup, no lock. Returns the cached response immediately for simple retries.
2. **Load show** — fetch show metadata (price, per-user limit).
3. **Ensure `show_user` row exists** — `INSERT INTO show_user ... ON CONFLICT DO NOTHING`. Two concurrent first-time users for the same show both issue the INSERT; exactly one creates the row, the other silently no-ops. This guarantees the row exists before we try to lock it.
4. **Lock `show_user` row** — `SELECT ... FOR UPDATE` on `show_user(show_id, user_id)`. This serializes every request from the same user for the same show. Only one transaction holds this lock at a time; the rest queue.
5. **Re-check idempotency under lock** — after acquiring the lock, re-query `reservations` for the same `(show_id, user_id, idempotency_key)`. Under READ COMMITTED, this now sees any reservation committed by the transaction that held the lock before us. This catches concurrent duplicate retries that both passed the fast-path check at step 1.
6. **Per-user limit check** — `show_user.reserved_count + requested_seats <= per_user_limit`. Safe because step 4 serializes concurrent requests from the same user.
7. **Lock seat rows** — `SELECT ... FROM seats WHERE show_id = ? AND seat_number IN (...) ORDER BY seat_number FOR UPDATE`. Acquires row locks on the requested seats in deterministic sorted order. Then checks each seat's status is `AVAILABLE`. If any seat is taken, the entire request fails (all-or-nothing).
8. **Insert reservation** — create the `reservations` row via JPA `save()`.
9. **Create `reservation_seats` + update seat status** — link seats to the reservation and set status to `CONFIRMED`.
10. **Increment `show_user.reserved_count`** — update the counter for future limit checks.

### Why it's race-free

The seat lock at step 7 ensures only one transaction holds a given seat row at a time. The second transaction blocks at step 7 until the first commits. Under READ COMMITTED, the second transaction then re-reads the seat's status, sees `CONFIRMED`, and returns `409 SEAT_TAKEN`. There is no window between the check and the update — they happen under the same lock.

For per-user limits, the `show_user` lock at step 4 plays the same role. Even if a user fires 10 concurrent requests, they are serialized at step 4. Each transaction sees the true `reserved_count` left by the previous one.

### Deadlock avoidance (multi-seat)

Seats are sorted by `seat_number` before locking (`ORDER BY seat_number` in the SQL query). Every transaction acquires locks in the same globally consistent order, which eliminates the A→B / B→A deadlock cycle.

The cancel flow also follows the same lock ordering as reserve — `show_user` first, then reservation, then seats — to prevent cross-flow deadlocks between concurrent reserve and cancel operations on the same user.

---

## 2. Idempotency

### Where the key is stored

The `reservations` table has columns `idempotency_key` and `request_hash`, with a unique constraint:

```sql
UNIQUE(show_id, user_id, idempotency_key)
```

Scoped per-show per-user — a client can reuse the same key across different shows without conflict.

### How exactly-once is enforced

Two layers, both within the same transaction:

1. **Pre-lock fast path (step 1):** Before acquiring any locks, query `reservations` for `(show_id, user_id, idempotency_key)`. If found and the hash matches, return the original reservation. This handles the common retry-after-success case with zero lock contention.

2. **Post-lock re-check (step 5):** After acquiring the `show_user FOR UPDATE` lock, re-query the same lookup. Under READ COMMITTED, this now sees any reservation committed by a concurrent request that held the lock before us. Since the lock serializes all requests for the same `(show_id, user_id)` — the same scope as the unique constraint — no concurrent duplicate can slip past step 5 to create a second reservation.

### Same-key-different-body handling

A SHA-256 hash of the sorted seat list is stored as `request_hash` alongside the idempotency key. On replay, the stored hash is compared against the incoming request's hash. If they differ, the request is rejected with `409 IDEMPOTENCY_KEY_REUSED`. This detects when a client reuses a key with different seats.

---

## 3. Holds & Expiry

This design uses **explicit cancellation**, not time-boxed holds.

Seat lifecycle: `AVAILABLE → CONFIRMED → AVAILABLE` (via cancel).

The `HELD` state is retained in the schema's CHECK constraint (`status IN ('AVAILABLE', 'HELD', 'CONFIRMED')`) for future extensibility, but is not used. The GET show API reports `held = 0`.

Cancel rules:
- Only the reservation owner can cancel (verified from JWT `sub` claim; others get `403`)
- Double-cancel returns `409 ALREADY_CANCELLED`
- Cancelled seats become immediately re-bookable by any user
- The cancel transaction locks in the same order as reserve (`show_user → reservation → seats`) to prevent deadlocks

---

## 4. Consistency vs Availability

The system chooses **consistency over availability** (CP).

PostgreSQL is the single source of truth. If the database is unreachable:
- `/health/ready` returns `503 Service Unavailable`
- Reservation requests fail (the Spring transaction cannot begin)
- The system does **not** fall back to cache, queue, or optimistic acceptance

This is the correct trade-off for seat reservation: a stale cache could report seat A12 as available while another transaction already confirmed it. Accepting a reservation without the database would risk a double-sell — a correctness violation that is far more costly than a brief service interruption.

No Redis or Kafka sits in the reservation path. The atomic decision lives entirely in PostgreSQL transactions, which eliminates consistency boundaries between systems.

---

## 5. Observability

### Metrics (Prometheus at `/actuator/prometheus`)

| Metric | Type | What it tracks |
|--------|------|----------------|
| `reservations_confirmed_total` | Counter | Successful reservations |
| `reservations_cancelled_total` | Counter | Successful cancellations |
| `reservations_declined_total{reason=seat_taken}` | Counter | Seat contention declines |
| `reservations_declined_total{reason=per_user_limit}` | Counter | Per-user limit violations |
| `reservations_declined_total{reason=idempotent_replay}` | Counter | Idempotent retries served from cache |
| `http_server_requests_seconds` | Timer | Request latency by endpoint and HTTP status (Spring Boot auto) |
| HikariCP pool metrics | Gauge | DB connection pool utilization (auto) |

### Structured Logs

Every log line is JSON with a correlation ID:

```json
{"timestamp":"2026-10-04T...","level":"INFO","logger":"...","request_id":"abc-123","message":"Reservation confirmed id=... show=... user=... seats=[A12]"}
```

The `request_id` is read from the `X-Request-ID` header (or generated as a UUID) and propagated via MDC to every log entry and response header.

### What I'd get paged for at 2am

1. **5xx rate > 0** — business contention (seat taken, limit exceeded) should always be 4xx. Any 5xx means a bug or infrastructure failure. Check DB connectivity and HikariCP pool exhaustion (`hikaricp_connections_active` near max).
2. **`/health/ready` returning 503** — database unreachable. Investigate PostgreSQL process health, disk space, and network connectivity.
3. **Request p99 latency climbing sharply** — lock queue growing. Either a hot-seat storm (expected, transient) or transactions holding locks too long. Check `pg_stat_activity` for blocked/idle-in-transaction queries.
4. **`reservations_confirmed_total` flat while `declined{reason=seat_taken}` spikes continuously** — could indicate all seats are sold (normal) or a locking bug where the winner's transaction is stuck and never commits. Distinguish by checking the show's available count via the API.
5. **HikariCP connection pool saturation** — `hikaricp_connections_pending` growing means requests are waiting for a DB connection. Need to tune pool size or investigate long-running transactions.

---

## 6. AI Usage

I used AI tools throughout this project in a **directed** capacity — I made the design and correctness decisions; the AI handled code generation and boilerplate.

### Phase 1: Design (ChatGPT)

I started with ChatGPT to break down the problem into structured sections: functional requirements, non-functional requirements, core entities, API model, database schema, and high-level design. This produced the `docs/design.md` document. I reviewed and edited the output to match my understanding of the concurrency requirements before writing any code.

### Phase 2: Implementation (Claude Code)

I used Claude Code to build the application incrementally, one phase at a time:

1. Project scaffold (Spring Boot, Docker, Flyway, health endpoints)
2. Database schema and JPA entities
3. Create/Get Show APIs
4. Reserve endpoint with transaction and locking
5. Cancel endpoint and idempotency hardening
6. JWT authentication
7. Prometheus metrics
8. Dockerfile hardening
9. Burst test script
10. Swagger UI

**After every phase, I reviewed the generated code for correctness.** Several of my reviews caught real issues that I directed the AI to fix:

- **`SELECT FOR UPDATE` on a non-existent `show_user` row** — the AI's initial code would silently skip the lock for first-time users. I identified this and directed the `INSERT ... ON CONFLICT DO NOTHING` fix.
- **Wrong exception types** — `SeatTakenException` was used for non-existent seats (should be `InvalidSeatException` with 400) and for already-cancelled reservations (should be `AlreadyCancelledException` with 409). I caught both.
- **Cancel flow deadlock risk** — the AI's initial cancel locked `reservation → seats → show_user`, while reserve locked `show_user → seats`. I identified the inconsistent lock ordering and directed the fix to lock `show_user` first in both flows.
- **Unnecessary DB re-read** — the AI added a `findById` after creating a reservation to build the response. I pointed out all fields were already in scope and directed the removal.
- **Idempotency via try/catch** — the initial approach caught `DataIntegrityViolationException`. I questioned this and we moved to `INSERT ... ON CONFLICT DO NOTHING`, then ultimately to a simpler `save()` after adding the post-lock re-check that made the safety net redundant.
- **Idempotency scope** — I identified that scoping the unique constraint to `(show_id, user_id, idempotency_key)` instead of `(user_id, idempotency_key)` was more practical and simplified the concurrency model.
- **Redundant ON CONFLICT after post-lock check** — after adding the post-lock idempotency re-check, I traced through the concurrency scenarios and concluded the `INSERT ON CONFLICT DO NOTHING` safety net was no longer needed, since the `show_user` lock serializes requests at the same scope as the unique constraint. Directed the simplification to a plain `save()`.

### Summary

The AI accelerated boilerplate (JPA entities, Spring Security config, Dockerfile, bash scripting) and provided initial implementations. The correctness-critical decisions — lock ordering, idempotency layering, scope of unique constraints, exception semantics — came from my review. Every commit reflects code I had reviewed and understood before merging.

---

## 7. What I'd Do Next

1. **Time-boxed holds** — add a `HELD` state with a configurable TTL and a scheduled job (`@Scheduled`) that expires stale holds back to `AVAILABLE`. Useful for a checkout flow where the user has a window to complete payment.
2. **Connection pool tuning** — profile under a real 20k burst to find the optimal HikariCP pool size and PostgreSQL `max_connections`. The current default of 20 may need adjustment based on actual lock wait times.
3. **Rate limiting** — per-user request throttling (e.g., bucket4j or resilience4j) to prevent a single client from monopolizing the DB lock queue during a hot-seat storm.
4. **Payment integration** — add a `PENDING_PAYMENT` state between hold and confirm, with an external payment provider's webhook confirming or rolling back the reservation.
5. **Read replicas** — route `GET /shows/{id}` to a PostgreSQL read replica to offload the primary during high-traffic on-sale events. Reservation writes stay on the primary.
6. **Event streaming** — publish reservation events to Kafka/SQS for downstream consumers (notifications, analytics, audit trail) without coupling them to the transaction path.
7. **Horizontal scaling** — the current design is stateless (JWT auth, no session) and scales horizontally behind a load balancer. The bottleneck is PostgreSQL row locks, which could be alleviated with seat-level partitioning or sharding by show for very large deployments.
