# Seat Reservation at Scale — System Design

## 1. Problem Statement

Build and deploy a backend service for selling assigned seats for an event such as a concert or movie hall.

The system must remain correct when thousands of users attempt to reserve seats concurrently, including the extreme case where hundreds or thousands of users attempt to reserve the exact same seat.

### Primary correctness requirements

The system must guarantee:

1. A seat can never be confirmed for two users.
2. A user cannot exceed the per-show booking limit.
3. Retrying the same request with the same idempotency key must not create another reservation.
4. Reusing an idempotency key with a different request must be rejected.
5. Normal business contention must return 4xx responses rather than 5xx.
6. The seat-count reconciliation invariant must always hold.
7. User identity must come from authentication, not from the request body.
8. The system must remain correct under concurrent requests.

---

# 2. Functional Requirements

## FR1 — Create Show

Admin can create a show.

### Request

`POST /shows`

```json
{
  "name": "friday-night",
  "seats": ["A1", "A2", "A3", "A12"],
  "price_paise": 25000,
  "per_user_limit": 4
}
```

### Behaviour

* Create a unique show ID.
* Create all seats associated with the show.
* Every seat starts in `AVAILABLE` state.
* `price_paise` is an integer.
* No floating-point money values.
* Seat numbers must be unique within a show.
* `per_user_limit` defaults to 4 if not supplied.

---

# 3. FR2 — Reserve Seats

Authenticated user can reserve one or more seats.

### Endpoint

`POST /shows/{showId}/reserve`

### Authentication

```http
Authorization: Bearer <JWT>
Idempotency-Key: abc-123
```

### Request

```json
{
  "seats": ["A12"]
}
```

The request must NOT contain a trusted `user_id`.

The user identity is extracted from the authentication token.

Example JWT:

```json
{
  "sub": "user-123"
}
```

---

## Successful response

HTTP `201 Created`

```json
{
  "reservation_id": "reservation-123",
  "show_id": "show-123",
  "user_id": "user-123",
  "seats": ["A12"],
  "amount_paise": 25000,
  "status": "CONFIRMED"
}
```

---

# 4. FR3 — No Double Booking

A seat can belong to only one confirmed reservation.

Example:

```text
20,000 users
        |
        | all request A12
        v
     PostgreSQL
        |
        +---- User 1 → wins
        |
        +---- Users 2-20,000 → 409 SEAT_TAKEN
```

Expected result:

```text
201 = 1
409 = 19,999
5xx = 0
```

The critical rule is:

> Never perform a separate "check availability" and "update availability" without synchronization.

Bad:

```text
SELECT status
if AVAILABLE:
    UPDATE status
```

This is vulnerable to race conditions.

Instead, the decision must happen inside an atomic database transaction using row-level locking.

---

# 5. FR4 — Per-User Booking Limit

Default:

```text
4 seats per user per show
```

Example:

```text
User A already has 4 seats.

User A requests another seat.

→ 409 PER_USER_LIMIT
```

This must remain correct even if the same user sends many requests concurrently.

Example:

```text
User A
   |
   +--> request 1
   +--> request 2
   +--> request 3
   +--> ...
   +--> request 10
```

The system must never allow more than 4 seats.

---

# 6. FR5 — Idempotency

Every reservation request requires an idempotency key.

Example:

```http
Idempotency-Key: abc123
```

### First request

```text
abc123 + A12
```

Creates:

```text
Reservation R1
```

### Retry

```text
abc123 + A12
```

Must return the original reservation.

It must NOT create R2.

---

## Same key + different body

First:

```text
abc123 + A12
```

Second:

```text
abc123 + A13
```

Must return:

```text
409 Conflict
```

because an idempotency key represents one logical operation.

---

# 7. FR6 — Multi-Seat Reservation

Choose:

> All-or-nothing.

Example:

```text
Request:
[A12, A13]
```

If:

```text
A12 = AVAILABLE
A13 = AVAILABLE
```

both are reserved.

If:

```text
A12 = AVAILABLE
A13 = CONFIRMED
```

the entire request fails.

Result:

```text
409 Conflict
```

A12 remains available.

This avoids partial reservations.

---

# 8. FR7 — Release / Cancellation

Choose the explicit cancellation model.

### Endpoint

`POST /reservations/{id}/cancel`

Only the reservation owner can cancel.

State transition:

```text
CONFIRMED
     |
     | cancel
     v
CANCELLED
     |
     v
seat becomes AVAILABLE
```

A cancelled seat can subsequently be reserved by another user.

---

# 9. Why We Do Not Use HELD in This Design

The assignment allows either:

1. Explicit cancellation
2. Time-boxed holds

This design chooses explicit cancellation.

Therefore the normal seat lifecycle is:

```text
AVAILABLE → CONFIRMED → AVAILABLE
```

There is no active hold in the normal flow.

However, `HELD` can remain as an enum/API state so the design can be extended later.

The GET API can therefore return:

```text
available + held + confirmed = total_seats
```

with:

```text
held = 0
```

for this implementation.

Example:

```text
available = 99
held = 0
confirmed = 1
total = 100

99 + 0 + 1 = 100
```

---

# 10. Payment Scope

The assignment mentions avoiding double charging on retried requests, but does not require integrating an actual payment provider.

For this implementation:

> A successful reservation represents a confirmed purchase.

Therefore:

```text
POST /reserve
       |
       v
Reservation CONFIRMED
```

There is no external payment gateway.

In a production system:

```text
Reservation
     |
     v
Payment
     |
     v
Confirmed
```

Cancellation of a paid reservation would trigger the appropriate refund workflow.

Payment integration is deliberately outside this take-home scope.

---

# 11. FR8 — Get Show State

### Endpoint

`GET /shows/{showId}`

Example:

```json
{
  "show_id": "show-123",
  "name": "friday-night",
  "price_paise": 25000,
  "total_seats": 100,
  "available": 96,
  "held": 0,
  "confirmed": 4,
  "seats": [
    {
      "seat": "A1",
      "status": "AVAILABLE"
    },
    {
      "seat": "A2",
      "status": "CONFIRMED"
    }
  ]
}
```

### Reconciliation invariant

Always:

```text
available + held + confirmed = total_seats
```

---

# 12. FR9 — Health

## Liveness

`GET /health/live`

Checks whether the application is alive.

It should NOT require PostgreSQL to be healthy.

---

## Readiness

`GET /health/ready`

Checks:

```text
Application alive
+
Database reachable
```

If PostgreSQL is unavailable:

```text
503 Service Unavailable
```

The service should fail closed rather than accepting reservations without the database.

---

# 13. FR10 — Metrics

Minimum metrics:

```text
reservations_confirmed_total

reservations_declined_total{
    reason="seat_taken"
}

reservations_declined_total{
    reason="per_user_limit"
}

reservations_declined_total{
    reason="idempotent_replay"
}

seats_available
```

Additional useful metrics:

```text
reservation_requests_total

reservation_request_duration_seconds

reservation_errors_total

db_transaction_duration_seconds
```

---

# 14. Non-Functional Requirements

## NFR1 — Correctness

Highest priority.

No:

* double booking
* over-booking
* duplicate reservation
* duplicate state transition

---

## NFR2 — Concurrency

The system should handle approximately:

```text
20,000 concurrent reservation requests
```

including hot-seat contention.

Example:

```text
20,000 users → A12
```

Expected:

```text
1 × 201
19,999 × 409
0 × 500
```

---

## NFR3 — Strong Consistency

Seat ownership requires strong consistency.

PostgreSQL is the source of truth.

Do not make reservation decisions from stale cache data.

---

## NFR4 — Availability

The application should:

* survive cold starts
* restart safely
* reconnect to the database
* expose readiness state
* recover after transient failures

---

## NFR5 — Idempotency

Retries must not create additional reservations.

---

## NFR6 — Security

* Authentication required for reservation.
* Identity comes from token.
* Do not trust `user_id` from request body.
* Only owner can cancel.
* Admin authentication required for show creation.

---

## NFR7 — Observability

System must provide:

* structured logs
* request/correlation ID
* Prometheus metrics
* liveness
* readiness

---

## NFR8 — Deployability

Clean checkout should run using Docker.

Example:

```bash
docker compose up
```

Production deployment should use the same containerized application.

---

# 15. Core Entities

Main entities:

```text
Show
Seat
Reservation
ReservationSeat
ShowUser
Idempotency
```

A separate User table is not strictly required for this assignment because identity can come from JWT.

---

# 16. Database Choice

Use:

> PostgreSQL

Reasons:

* ACID transactions
* Row-level locks
* `SELECT FOR UPDATE`
* Unique constraints
* Strong consistency
* Excellent concurrency support
* Simple architecture

Avoid unnecessary Redis/Kafka for the core reservation decision.

---

# 17. Database Model

## `shows`

```text
shows
--------------------------------
id                  UUID PK
name                VARCHAR
price_paise         BIGINT
per_user_limit      INT
created_at          TIMESTAMP
```

Money is stored as integer paise.

Example:

```text
₹250.00 = 25000 paise
```

Never use floating point.

---

# 18. `seats`

```text
seats
--------------------------------
id                  BIGINT PK
show_id             UUID FK
seat_number         VARCHAR
status              ENUM
created_at          TIMESTAMP

UNIQUE(show_id, seat_number)
```

Status:

```text
AVAILABLE
HELD
CONFIRMED
```

`HELD` is retained for future extensibility but isn't used in the selected explicit-cancellation model.

---

# 19. `reservations`

```text
reservations
--------------------------------
id                  UUID PK
show_id             UUID FK
user_id             VARCHAR
amount_paise        BIGINT
status              ENUM
idempotency_key     VARCHAR
request_hash        VARCHAR
created_at          TIMESTAMP
cancelled_at        TIMESTAMP NULL
```

Possible statuses:

```text
CONFIRMED
CANCELLED
```

Unique idempotency constraint:

```sql
UNIQUE(user_id, idempotency_key)
```

---

# 20. `reservation_seats`

```text
reservation_seats
--------------------------------
reservation_id      UUID FK
seat_id             BIGINT FK

PRIMARY KEY(reservation_id, seat_id)
```

Relationship:

```text
Reservation R1
   |
   +--- A12
   +--- A13
   +--- A14
```

---

# 21. `show_user`

Used to serialize concurrent reservations for the same user/show and efficiently enforce the booking limit.

```text
show_user
--------------------------------
show_id             UUID FK
user_id             VARCHAR
reserved_count      INT

PRIMARY KEY(show_id, user_id)
```

Example:

```text
show-1
user-123
reserved_count = 3
```

---

# 22. Why `show_user` Is Important

Suppose limit = 4.

User has 3 seats.

Then 10 concurrent requests arrive.

A naïve implementation:

```text
SELECT COUNT(*)
```

can allow multiple requests to see:

```text
count = 3
```

and all proceed.

Instead:

```sql
SELECT *
FROM show_user
WHERE show_id = ?
AND user_id = ?
FOR UPDATE;
```

Only one transaction can make the user's booking decision at a time.

Then:

```text
current_count + requested_seats <= limit
```

is evaluated safely.

---

# 23. API Design

| Method | Endpoint                    | Purpose            |
| ------ | --------------------------- | ------------------ |
| POST   | `/shows`                    | Create show        |
| GET    | `/shows/{id}`               | Get show state     |
| POST   | `/shows/{id}/reserve`       | Reserve seats      |
| POST   | `/reservations/{id}/cancel` | Cancel reservation |
| GET    | `/health/live`              | Liveness           |
| GET    | `/health/ready`             | Readiness          |
| GET    | `/metrics`                  | Prometheus metrics |

---

# 24. HTTP Status Codes

## Success

```text
201 Created
```

---

## Seat already taken

```text
409 Conflict
```

---

## Per-user limit exceeded

```text
409 Conflict
```

---

## Same idempotency key + different request

```text
409 Conflict
```

---

## Invalid request

```text
400 Bad Request
```

---

## Missing/invalid authentication

```text
401 Unauthorized
```

---

## Cancelling another user's reservation

```text
403 Forbidden
```

---

## Show/reservation not found

```text
404 Not Found
```

---

## Unexpected infrastructure failure

```text
5xx
```

Normal reservation contention must NOT become 5xx.

---

# 25. High-Level Architecture

```text
                         Internet
                            |
                            v
                    +---------------+
                    |   Spring Boot |
                    |      API      |
                    +-------+-------+
                            |
                +-----------+-----------+
                |                       |
                v                       v
        Reservation Service          Metrics
                |
                v
        +---------------+
        |  PostgreSQL   |
        |               |
        | shows         |
        | seats         |
        | reservations  |
        | reservation_  |
        | seats         |
        | show_user     |
        +---------------+
```

Observability:

```text
Spring Boot
    |
    +---- /metrics ----> Prometheus
    |
    +---- logs --------> Platform logs
```

---

# 26. Reservation Transaction

This is the most important part of the design.

Reservation should execute inside one database transaction.

Conceptually:

```text
BEGIN
    |
    v
Check idempotency
    |
    +-- Existing + same request
    |       |
    |       +--> return original reservation
    |
    +-- Existing + different request
    |       |
    |       +--> 409
    |
    v
Lock show_user row
    |
    v
Check per-user limit
    |
    +-- exceeded --> 409
    |
    v
Sort requested seats
    |
    v
Lock seat rows in deterministic order
    |
    v
Check all seats AVAILABLE
    |
    +-- any unavailable --> 409
    |
    v
Create reservation
    |
    v
Create reservation_seats
    |
    v
Update seats → CONFIRMED
    |
    v
Increment show_user.reserved_count
    |
    v
COMMIT
```

---

# 27. Hot Seat Concurrency

Suppose:

```text
500 users → A12
```

Each transaction executes:

```sql
SELECT *
FROM seats
WHERE show_id = ?
AND seat_number = 'A12'
FOR UPDATE;
```

PostgreSQL allows only one transaction to hold the row lock at a time.

Example:

```text
User A
  |
  +-- obtains A12 lock
  |
  +-- sees AVAILABLE
  |
  +-- changes to CONFIRMED
  |
  +-- COMMIT
```

Then User B gets the lock:

```text
A12 = CONFIRMED
```

Therefore:

```text
409 SEAT_TAKEN
```

The same happens for all remaining requests.

Result:

```text
1 × 201
499 × 409
0 × 500
```

---

# 28. Multi-Seat Locking

For:

```text
[A12, A13, A14]
```

sort the seats before locking.

Example:

```text
A12
A13
A14
```

Then:

```sql
SELECT *
FROM seats
WHERE show_id = ?
AND seat_number IN (...)
ORDER BY seat_number
FOR UPDATE;
```

Every transaction acquires locks in the same order.

This reduces deadlock risk.

Bad:

```text
Transaction 1:
A12 → A13

Transaction 2:
A13 → A12
```

This can produce a deadlock.

Correct:

```text
Transaction 1:
A12 → A13

Transaction 2:
A12 → A13
```

---

# 29. All-or-Nothing Multi-Seat Reservation

Example:

```text
Request:
A12 + A13
```

Database:

```text
A12 = AVAILABLE
A13 = CONFIRMED
```

Transaction detects that not all requested seats are available.

Return:

```text
409 Conflict
```

No seat is modified.

Therefore:

```text
A12 = AVAILABLE
A13 = CONFIRMED
```

This is atomic.

---

# 30. Idempotency Implementation

Store:

```text
user_id
idempotency_key
request_hash
reservation_id
```

Example:

```text
user-123
abc123
hash(["A12"])
R100
```

### First request

```text
abc123 + A12

No existing key
        |
        v
Create reservation R100
        |
        v
Store idempotency record
```

### Retry

```text
abc123 + A12

Key exists
Hash matches
        |
        v
Return R100
```

No additional reservation.

---

# 31. Same Key, Different Request

Stored:

```text
abc123
hash(A12)
```

Incoming:

```text
abc123
hash(A13)
```

Hashes differ.

Return:

```text
409 Conflict
```

No database state change.

---

# 32. Concurrent Idempotent Requests

Important case:

Two identical requests arrive at exactly the same time:

```text
User A
   |
   +---- Request 1: key=abc, A12
   |
   +---- Request 2: key=abc, A12
```

Both may initially see no idempotency record.

The database unique constraint:

```sql
UNIQUE(user_id, idempotency_key)
```

ensures only one can create the idempotency record.

One transaction wins.

The other must handle the uniqueness conflict and return the original reservation.

This is another reason the database must enforce the invariant rather than relying only on application code.

---

# 33. Cancellation Transaction

Cancellation:

```text
POST /reservations/{id}/cancel
```

Inside transaction:

```text
BEGIN
    |
    v
Lock reservation
    |
    v
Verify authenticated user owns reservation
    |
    v
Lock associated seats
    |
    v
Verify reservation still owns them
    |
    v
Set seats → AVAILABLE
    |
    v
Set reservation → CANCELLED
    |
    v
Decrement show_user.reserved_count
    |
    v
COMMIT
```

This prevents a release operation from incorrectly affecting a newly booked seat.

---

# 34. Identity and Security

Authentication:

```http
Authorization: Bearer <JWT>
```

JWT:

```json
{
  "sub": "user-123"
}
```

The application obtains:

```text
user_id = authentication.getName()
```

Do NOT trust:

```json
{
  "user_id": "another-user"
}
```

from the request.

For cancellation:

```text
JWT user = reservation.user_id
```

must be true.

Otherwise:

```text
403 Forbidden
```

---

# 35. Observability

## Metrics

Minimum:

```text
reservations_confirmed_total

reservations_declined_total{reason="seat_taken"}

reservations_declined_total{reason="per_user_limit"}

reservations_declined_total{reason="idempotent_replay"}

seats_available
```

Additional:

```text
reservation_requests_total

reservation_request_duration_seconds

reservation_errors_total

db_transaction_duration_seconds
```

---

# 36. Structured Logging

Example:

```json
{
  "timestamp": "2026-10-04T10:00:00Z",
  "level": "INFO",
  "request_id": "req-123",
  "user_id": "user-456",
  "show_id": "show-789",
  "operation": "reserve",
  "seats": ["A12"],
  "result": "SEAT_TAKEN"
}
```

Never log authentication tokens.

---

# 37. Request ID

Support:

```http
X-Request-ID: abc123
```

If absent, generate one.

Every log entry for the request includes:

```text
request_id=abc123
```

This makes debugging concurrent traffic much easier.

---

# 38. Health Checks

## Liveness

```text
GET /health/live
```

Returns success if application process is alive.

Do not make liveness depend on PostgreSQL.

---

## Readiness

```text
GET /health/ready
```

Checks PostgreSQL connectivity.

If database unavailable:

```text
503
```

This prevents the application from being considered ready when it cannot perform reservation operations.

---

# 39. Load Test / Burst Test

The repository should contain a command such as:

```bash
./burst.sh <BASE_URL>
```

or:

```bash
make burst BASE_URL=<BASE_URL>
```

The script should:

1. Create/fetch a test show.
2. Generate simulated users.
3. Generate authentication tokens.
4. Fire concurrent requests.
5. Target hot seats.
6. Test idempotency.
7. Test per-user limit.
8. Fetch final show state.
9. Print reconciliation.

---

# 40. Simulating 20,000 Users

We do not need 20,000 permanent database users.

The load generator can create identities:

```text
user-00001
user-00002
...
user-20000
```

and generate corresponding test tokens.

Example:

```text
20,000 requests
        |
        +---- user-00001 → A12
        +---- user-00002 → A12
        +---- user-00003 → A12
        ...
        +---- user-20000 → A12
```

The API sees 20,000 authenticated users.

---

# 41. Expected Hot-Seat Test

Example:

```text
Show:
100 seats

20,000 concurrent users
all requesting A12
```

Expected:

```text
201 CREATED       1
409 SEAT_TAKEN    19,999
5xx               0
```

Final:

```text
total      = 100
available  = 99
held       = 0
confirmed  = 1
```

Invariant:

```text
99 + 0 + 1 = 100
```

---

# 42. Per-User Concurrency Test

Show limit:

```text
4
```

One user sends:

```text
10 concurrent requests
```

for different seats.

Expected:

```text
confirmed seats <= 4
```

For example:

```text
201 = 4
409 PER_USER_LIMIT = 6
```

Never:

```text
confirmed = 5+
```

---

# 43. Idempotency Burst Test

Send many identical concurrent requests:

```text
user-1
seat=A12
idempotency-key=abc123
```

Expected:

```text
Exactly one reservation
```

All retries should resolve to the same reservation.

Then:

```text
same key
different seat=A13
```

must produce:

```text
409
```

---

# 44. Consistency During Burst

After the load test:

```text
GET /shows/{id}
```

Calculate:

```text
available + held + confirmed
```

It must equal:

```text
total_seats
```

Example:

```text
96 + 0 + 4 = 100 ✓
```

---

# 45. Consistency vs Availability

PostgreSQL is the source of truth.

If PostgreSQL is unavailable:

```text
Reservation
     |
     v
DB unavailable
     |
     v
Do NOT reserve from cache
     |
     v
Fail request
```

Reason:

A stale cache could say:

```text
A12 = AVAILABLE
```

while another transaction has already confirmed A12.

For seat reservation, correctness is more important than accepting requests during a database partition.

---

# 46. Why Not Redis for Seat Ownership?

Redis could be used for distributed locking, but it introduces another consistency boundary.

Using PostgreSQL alone gives:

```text
One source of truth
+
Transactions
+
Row locks
+
Constraints
```

This is simpler and safer for a one-day assignment.

Redis could be introduced later for caching/read-heavy workloads, but reservation correctness should remain backed by PostgreSQL.

---

# 47. Why Not Kafka for Reservation?

Kafka is useful for asynchronous events such as:

* notifications
* analytics
* audit events
* downstream processing

But the actual reservation decision should be synchronous:

```text
HTTP
 ↓
PostgreSQL transaction
 ↓
201 / 409
```

Do not make the critical booking path:

```text
HTTP
 ↓
Kafka
 ↓
consumer
 ↓
DB
```

unless there is a strong reason.

---

# 48. Deployment

Recommended architecture:

```text
Internet
   |
   v
Render / Railway
   |
   v
Spring Boot Docker container
   |
   v
Managed PostgreSQL
```

Local:

```bash
docker compose up
```

The Docker container should run the same application used in production.

---

# 49. Suggested Project Structure

```text
src/main/java/com/example/reservation/

├── controller/
│   ├── ShowController
│   ├── ReservationController
│   └── HealthController
│
├── service/
│   ├── ShowService
│   └── ReservationService
│
├── repository/
│   ├── ShowRepository
│   ├── SeatRepository
│   ├── ReservationRepository
│   └── ShowUserRepository
│
├── entity/
│   ├── Show
│   ├── Seat
│   ├── Reservation
│   ├── ReservationSeat
│   └── ShowUser
│
├── dto/
│
├── exception/
│
├── security/
│
├── metrics/
│
└── config/
```

---

# 50. Main Correctness Mechanisms

The design relies on four major mechanisms:

## 1. PostgreSQL transaction

All reservation state changes occur atomically.

## 2. Row-level locking

```sql
SELECT ... FOR UPDATE
```

serializes competing transactions on the same seat.

## 3. Deterministic locking order

Multi-seat requests lock seats in sorted order to avoid deadlocks.

## 4. Database unique constraints

Idempotency is enforced by:

```sql
UNIQUE(user_id, idempotency_key)
```

These mechanisms together form the correctness boundary.

---

# 51. State Machines

## Seat

```text
AVAILABLE
    |
    | reserve
    v
CONFIRMED
    |
    | cancel
    v
AVAILABLE
```

`HELD` is reserved for future time-boxed-hold support.

---

## Reservation

```text
CONFIRMED
    |
    | cancel
    v
CANCELLED
```

---

# 52. Important Invariants

### Invariant 1 — Seat uniqueness

At most one active reservation owns a seat.

### Invariant 2 — User limit

```text
reserved_count <= per_user_limit
```

### Invariant 3 — Reconciliation

```text
available + held + confirmed = total_seats
```

### Invariant 4 — Idempotency

One `(user_id, idempotency_key)` maps to one logical reservation.

### Invariant 5 — Ownership

A reservation can only be cancelled by its owner.

### Invariant 6 — Money

All money values are integer paise.

---

# 53. Error Model

Domain errors should be explicit.

Example:

```json
{
  "error": "SEAT_TAKEN",
  "message": "One or more requested seats are already reserved",
  "request_id": "req-123"
}
```

Other errors:

```text
SEAT_TAKEN
PER_USER_LIMIT_EXCEEDED
IDEMPOTENCY_KEY_REUSED
RESERVATION_NOT_FOUND
NOT_RESERVATION_OWNER
SHOW_NOT_FOUND
INVALID_REQUEST
```

These should map to appropriate 4xx responses.

---

# 54. Implementation Order

Given the one-day time budget:

## Phase 1 — Project setup

```text
Spring Boot
PostgreSQL
Docker
Flyway
```

## Phase 2 — Core schema

```text
shows
seats
reservations
reservation_seats
show_user
```

## Phase 3 — Create/Get Show

```text
POST /shows
GET /shows/{id}
```

## Phase 4 — Reservation

Implement:

```text
transaction
+
idempotency
+
show_user locking
+
seat locking
+
all-or-nothing
```

## Phase 5 — Cancellation

```text
POST /reservations/{id}/cancel
```

## Phase 6 — Authentication

JWT/token-derived identity.

## Phase 7 — Observability

Metrics + logs + health.

## Phase 8 — Concurrency tests

Test:

```text
hot seat
per-user limit
idempotency
multi-seat
cancellation
```

## Phase 9 — 20k burst

Run against the deployed URL.

## Phase 10 — Deployment + README

Only after the system is working locally.

---

# 55. The Core Design in One Diagram

```text
                         CLIENTS
                            |
                            |
                 20,000 concurrent requests
                            |
                            v
                  +-------------------+
                  |   Spring Boot API |
                  +---------+---------+
                            |
                            v
                  +-------------------+
                  | ReservationService|
                  +---------+---------+
                            |
                       Transaction
                            |
             +--------------+--------------+
             |                             |
             v                             v
      Lock show_user                 Lock seat rows
      FOR UPDATE                     FOR UPDATE
             |                             |
             |                             |
             +--------------+--------------+
                            |
                            v
                    Check invariants
                            |
               +------------+------------+
               |                         |
            Valid                    Invalid
               |                         |
               v                         v
        Create reservation             409
        Update seats
        Update counter
               |
               v
             COMMIT
               |
               v
             201
```

---

# 56. Final Architecture Decision

For this assignment, the recommended implementation is:

```text
Language:          Java
Framework:         Spring Boot
Database:          PostgreSQL
Container:         Docker
Deployment:        Render/Railway/etc.
Authentication:    JWT
Seat consistency:  PostgreSQL row locking
Idempotency:       PostgreSQL unique constraint + request hash
Multi-seat:        All-or-nothing
Release model:     Explicit cancellation
Payment:           Out of scope
Cache:             Not required
Redis:             Not required
Kafka:             Not required
Metrics:           Prometheus
Logs:              Structured JSON
Health:            Liveness + DB-backed readiness
Load test:         20,000 concurrent simulated users
```