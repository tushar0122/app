#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-http://localhost:8080}"
JWT_SECRET="${2:-super-secret-key-for-development-only-change-in-production-min-32-chars}"
HOT_SEAT_USERS="${HOT_SEAT_USERS:-500}"
PARALLEL="${PARALLEL:-100}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

TMPDIR_BURST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BURST"' EXIT

pass() { printf "${GREEN}PASS${NC} %s\n" "$1"; }
fail() { printf "${RED}FAIL${NC} %s\n" "$1"; }
info() { printf "${YELLOW}>>>${NC} %s\n" "$1"; }

# ── JWT generation ──────────────────────────────────────────────

base64url() {
    openssl enc -base64 -A | tr '+/' '-_' | tr -d '='
}

jwt() {
    local sub=$1 role=${2:-}
    local header payload
    header=$(echo -n '{"alg":"HS256","typ":"JWT"}' | base64url)
    if [ -n "$role" ]; then
        payload=$(printf '{"sub":"%s","role":"%s"}' "$sub" "$role" | base64url)
    else
        payload=$(printf '{"sub":"%s"}' "$sub" | base64url)
    fi
    local sig
    sig=$(echo -n "$header.$payload" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | base64url)
    echo "$header.$payload.$sig"
}

ADMIN_TOKEN=$(jwt "admin-1" "admin")

# ── Helper: create show ────────────────────────────────────────

create_show() {
    local name=$1 seats_json=$2 price=$3 limit=$4
    local body
    body=$(printf '{"name":"%s","seats":%s,"price_paise":%d,"per_user_limit":%d}' \
        "$name" "$seats_json" "$price" "$limit")
    curl -s -X POST "$BASE_URL/shows" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -d "$body"
}

get_show() {
    curl -s "$BASE_URL/shows/$1"
}

# ── Helper: fire concurrent reservations ───────────────────────

fire_reserve() {
    local show_id=$1 results_dir=$2
    shift 2
    # remaining args: lines of "user_id idempotency_key seat1,seat2,..."
    local i=0
    while IFS=' ' read -r user_id idem_key seats_csv; do
        i=$((i + 1))
        local token
        token=$(jwt "$user_id")
        local seats_json
        seats_json=$(echo "$seats_csv" | tr ',' '\n' | sed 's/.*/"&"/' | paste -sd',' | sed 's/^/[/;s/$/]/')
        local body
        body=$(printf '{"seats":%s}' "$seats_json")
        echo "curl -s -o /dev/null -w '%{http_code}' -X POST '$BASE_URL/shows/$show_id/reserve' \
            -H 'Content-Type: application/json' \
            -H 'Authorization: Bearer $token' \
            -H 'Idempotency-Key: $idem_key' \
            -d '$body' > '$results_dir/$i.status'" >> "$results_dir/commands.sh"
    done

    chmod +x "$results_dir/commands.sh"
    # Run commands in parallel using xargs
    cat "$results_dir/commands.sh" | xargs -I{} -P "$PARALLEL" bash -c '{}'
}

count_status() {
    local dir=$1 code=$2
    grep -rl "^${code}$" "$dir"/*.status 2>/dev/null | wc -l | tr -d ' '
}

# ── Test 1: Hot-Seat Storm ─────────────────────────────────────

test_hot_seat() {
    printf "\n${BOLD}═══ Test 1: Hot-Seat Storm (%d users → seat A1) ═══${NC}\n" "$HOT_SEAT_USERS"

    local seats='["A1","A2","A3","A4","A5","A6","A7","A8","A9","A10"]'
    local resp
    resp=$(create_show "hot-seat-test" "$seats" 25000 4)
    local show_id
    show_id=$(echo "$resp" | grep -o '"show_id":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -z "$show_id" ]; then
        fail "Could not create show"
        echo "$resp"
        return 1
    fi
    info "Show created: $show_id"

    local results_dir="$TMPDIR_BURST/hot_seat"
    mkdir -p "$results_dir"

    info "Firing $HOT_SEAT_USERS concurrent requests for seat A1..."
    for i in $(seq 1 "$HOT_SEAT_USERS"); do
        local uid
        uid=$(printf "user-%05d" "$i")
        echo "$uid key-$uid A1"
    done | fire_reserve "$show_id" "$results_dir"

    local c201 c409 c5xx
    c201=$(count_status "$results_dir" 201)
    c409=$(count_status "$results_dir" 409)
    c5xx=$(grep -rl '^5' "$results_dir"/*.status 2>/dev/null | wc -l | tr -d ' ')

    printf "  201: %d  |  409: %d  |  5xx: %d\n" "$c201" "$c409" "$c5xx"

    [ "$c201" -eq 1 ] && pass "Exactly 1 winner" || fail "Expected 1 winner, got $c201"
    [ "$c5xx" -eq 0 ] && pass "Zero 5xx errors" || fail "Got $c5xx server errors"

    # Reconciliation
    local show_state
    show_state=$(get_show "$show_id")
    local available confirmed total
    available=$(echo "$show_state" | grep -o '"available":[0-9]*' | cut -d: -f2)
    confirmed=$(echo "$show_state" | grep -o '"confirmed":[0-9]*' | cut -d: -f2)
    total=$(echo "$show_state" | grep -o '"total_seats":[0-9]*' | cut -d: -f2)
    local sum=$((available + confirmed))

    printf "  Seats: available=%d confirmed=%d total=%d\n" "$available" "$confirmed" "$total"
    [ "$sum" -eq "$total" ] && pass "Reconciliation: $available + $confirmed = $total" \
                            || fail "Reconciliation failed: $sum != $total"
}

# ── Test 2: Per-User Limit ─────────────────────────────────────

test_per_user_limit() {
    local limit=4
    local requests=10
    printf "\n${BOLD}═══ Test 2: Per-User Limit (1 user, %d requests, limit=%d) ═══${NC}\n" "$requests" "$limit"

    local seats_json='['
    for i in $(seq 1 20); do
        [ "$i" -gt 1 ] && seats_json+=','
        seats_json+=$(printf '"S%d"' "$i")
    done
    seats_json+=']'

    local resp
    resp=$(create_show "limit-test" "$seats_json" 10000 "$limit")
    local show_id
    show_id=$(echo "$resp" | grep -o '"show_id":"[^"]*"' | head -1 | cut -d'"' -f4)
    info "Show created: $show_id (limit=$limit)"

    local results_dir="$TMPDIR_BURST/per_user"
    mkdir -p "$results_dir"

    info "Firing $requests concurrent single-seat requests from one user..."
    for i in $(seq 1 "$requests"); do
        local seat
        seat=$(printf "S%d" "$i")
        echo "limit-user key-limit-$i $seat"
    done | fire_reserve "$show_id" "$results_dir"

    local c201 c409
    c201=$(count_status "$results_dir" 201)
    c409=$(count_status "$results_dir" 409)

    printf "  201: %d  |  409: %d\n" "$c201" "$c409"

    [ "$c201" -le "$limit" ] && pass "Confirmed seats ($c201) <= limit ($limit)" \
                             || fail "Confirmed seats ($c201) > limit ($limit)"
    [ "$c201" -gt 0 ] && pass "At least 1 reservation succeeded" \
                      || fail "No reservations succeeded"

    local show_state
    show_state=$(get_show "$show_id")
    local confirmed
    confirmed=$(echo "$show_state" | grep -o '"confirmed":[0-9]*' | cut -d: -f2)
    [ "$confirmed" -le "$limit" ] && pass "DB confirmed count ($confirmed) <= limit ($limit)" \
                                  || fail "DB confirmed count ($confirmed) > limit ($limit)"
}

# ── Test 3: Idempotency ────────────────────────────────────────

test_idempotency() {
    local dupes=50
    printf "\n${BOLD}═══ Test 3: Idempotency (%d identical requests) ═══${NC}\n" "$dupes"

    local resp
    resp=$(create_show "idempotency-test" '["I1","I2","I3","I4","I5"]' 5000 4)
    local show_id
    show_id=$(echo "$resp" | grep -o '"show_id":"[^"]*"' | head -1 | cut -d'"' -f4)
    info "Show created: $show_id"

    local results_dir="$TMPDIR_BURST/idempotency"
    mkdir -p "$results_dir"

    info "Firing $dupes identical requests (same user, same key, same seat)..."
    for i in $(seq 1 "$dupes"); do
        echo "idemp-user same-key-123 I1"
    done | fire_reserve "$show_id" "$results_dir"

    local c201 c409 c5xx
    c201=$(count_status "$results_dir" 201)
    c409=$(count_status "$results_dir" 409)
    c5xx=$(grep -rl '^5' "$results_dir"/*.status 2>/dev/null | wc -l | tr -d ' ')

    printf "  201: %d  |  409: %d  |  5xx: %d\n" "$c201" "$c409" "$c5xx"

    local total_success=$((c201))
    [ "$c5xx" -eq 0 ] && pass "Zero 5xx errors" || fail "Got $c5xx server errors"

    local show_state
    show_state=$(get_show "$show_id")
    local confirmed
    confirmed=$(echo "$show_state" | grep -o '"confirmed":[0-9]*' | cut -d: -f2)
    [ "$confirmed" -eq 1 ] && pass "Exactly 1 reservation in DB" \
                           || fail "Expected 1 reservation, got $confirmed"

    # Same key, different seat → must be 409
    info "Testing same key with different seat..."
    local token
    token=$(jwt "idemp-user")
    local conflict_status
    conflict_status=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/shows/$show_id/reserve" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token" \
        -H "Idempotency-Key: same-key-123" \
        -d '{"seats":["I2"]}')

    [ "$conflict_status" -eq 409 ] && pass "Same key + different seat → 409" \
                                   || fail "Expected 409, got $conflict_status"
}

# ── Test 4: Cancellation + Re-reserve ──────────────────────────

test_cancel() {
    printf "\n${BOLD}═══ Test 4: Cancel and Re-reserve ═══${NC}\n"

    local resp
    resp=$(create_show "cancel-test" '["C1","C2","C3"]' 5000 4)
    local show_id
    show_id=$(echo "$resp" | grep -o '"show_id":"[^"]*"' | head -1 | cut -d'"' -f4)
    info "Show created: $show_id"

    # Reserve C1
    local token
    token=$(jwt "cancel-user")
    local reserve_resp
    reserve_resp=$(curl -s -X POST "$BASE_URL/shows/$show_id/reserve" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token" \
        -H "Idempotency-Key: cancel-key-1" \
        -d '{"seats":["C1"]}')
    local res_id
    res_id=$(echo "$reserve_resp" | grep -o '"reservation_id":"[^"]*"' | cut -d'"' -f4)
    [ -n "$res_id" ] && pass "Reserved C1 (id=$res_id)" || { fail "Reserve failed"; return 1; }

    # Cancel
    local cancel_status
    cancel_status=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/reservations/$res_id/cancel" \
        -H "Authorization: Bearer $token")
    [ "$cancel_status" -eq 200 ] && pass "Cancelled reservation" || fail "Cancel returned $cancel_status"

    # Double cancel
    local double_cancel
    double_cancel=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/reservations/$res_id/cancel" \
        -H "Authorization: Bearer $token")
    [ "$double_cancel" -eq 409 ] && pass "Double cancel → 409" || fail "Double cancel returned $double_cancel"

    # Re-reserve same seat with different user
    local token2
    token2=$(jwt "other-user")
    local re_reserve
    re_reserve=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/shows/$show_id/reserve" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token2" \
        -H "Idempotency-Key: re-reserve-key" \
        -d '{"seats":["C1"]}')
    [ "$re_reserve" -eq 201 ] && pass "Re-reserved cancelled seat C1" || fail "Re-reserve returned $re_reserve"

    # Reconciliation
    local show_state
    show_state=$(get_show "$show_id")
    local available confirmed total
    available=$(echo "$show_state" | grep -o '"available":[0-9]*' | cut -d: -f2)
    confirmed=$(echo "$show_state" | grep -o '"confirmed":[0-9]*' | cut -d: -f2)
    total=$(echo "$show_state" | grep -o '"total_seats":[0-9]*' | cut -d: -f2)
    local sum=$((available + confirmed))
    [ "$sum" -eq "$total" ] && pass "Reconciliation: $available + $confirmed = $total" \
                            || fail "Reconciliation failed: $sum != $total"
}

# ── Run all tests ──────────────────────────────────────────────

printf "${BOLD}Burst Test — %s${NC}\n" "$BASE_URL"
printf "Parallel workers: %d\n" "$PARALLEL"

test_hot_seat
test_per_user_limit
test_idempotency
test_cancel

printf "\n${BOLD}═══ All tests complete ═══${NC}\n"
