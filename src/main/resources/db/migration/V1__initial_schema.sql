CREATE TABLE shows (
    id              UUID PRIMARY KEY,
    name            VARCHAR(255) NOT NULL,
    price_paise     BIGINT NOT NULL,
    per_user_limit  INT NOT NULL DEFAULT 4,
    created_at      TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE seats (
    id              BIGSERIAL PRIMARY KEY,
    show_id         UUID NOT NULL REFERENCES shows(id),
    seat_number     VARCHAR(20) NOT NULL,
    status          VARCHAR(20) NOT NULL DEFAULT 'AVAILABLE',
    created_at      TIMESTAMP NOT NULL DEFAULT now(),

    CONSTRAINT uq_seat_per_show UNIQUE (show_id, seat_number),
    CONSTRAINT chk_seat_status CHECK (status IN ('AVAILABLE', 'HELD', 'CONFIRMED'))
);

CREATE INDEX idx_seats_show_id ON seats(show_id);
CREATE INDEX idx_seats_show_status ON seats(show_id, status);

CREATE TABLE reservations (
    id              UUID PRIMARY KEY,
    show_id         UUID NOT NULL REFERENCES shows(id),
    user_id         VARCHAR(255) NOT NULL,
    amount_paise    BIGINT NOT NULL,
    status          VARCHAR(20) NOT NULL DEFAULT 'CONFIRMED',
    idempotency_key VARCHAR(255) NOT NULL,
    request_hash    VARCHAR(64) NOT NULL,
    created_at      TIMESTAMP NOT NULL DEFAULT now(),
    cancelled_at    TIMESTAMP,

    CONSTRAINT uq_idempotency UNIQUE (user_id, idempotency_key),
    CONSTRAINT chk_reservation_status CHECK (status IN ('CONFIRMED', 'CANCELLED'))
);

CREATE TABLE reservation_seats (
    reservation_id  UUID NOT NULL REFERENCES reservations(id),
    seat_id         BIGINT NOT NULL REFERENCES seats(id),

    PRIMARY KEY (reservation_id, seat_id)
);

CREATE TABLE show_user (
    show_id         UUID NOT NULL REFERENCES shows(id),
    user_id         VARCHAR(255) NOT NULL,
    reserved_count  INT NOT NULL DEFAULT 0,

    PRIMARY KEY (show_id, user_id)
);
