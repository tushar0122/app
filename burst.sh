#!/usr/bin/env bash
set -uo pipefail

BASE_URL="${1:-http://localhost:8080}"
JWT_SECRET="${2:-super-secret-key-for-development-only-change-in-production-min-32-chars}"
HOT_SEAT_USERS="${HOT_SEAT_USERS:-200}"
PARALLEL="${PARALLEL:-50}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

TMPDIR_BURST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BURST"' EXIT

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_ASSERTIONS=0
START_TIME=$(date +%s)

pass() {
    TOTAL_PASS=$((TOTAL_PASS + 1))
    TOTAL_ASSERTIONS=$((TOTAL_ASSERTIONS + 1))
    printf "${GREEN}  PASS${NC} %s\n" "$1"
}

fail() {
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    TOTAL_ASSERTIONS=$((TOTAL_ASSERTIONS + 1))
    printf "${RED}  FAIL${NC} %s\n" "$1"
}

info() { printf "${YELLOW}  >>>${NC} %s\n" "$1"; }

error_detail() {
    printf "${RED}       ERROR${NC} %s\n" "$1"
}

# ── JWT (header computed once, reused everywhere) ──────────────

JWT_HEADER=$(echo -n '{"alg":"HS256","typ":"JWT"}' | openssl enc -base64 -A | tr '+/' '-_' | tr -d '=')

jwt_fast() {
    local sub=$1 role=${2:-}
    local payload
    if [ -n "$role" ]; then
        payload=$(printf '{"sub":"%s","role":"%s"}' "$sub" "$role" | openssl enc -base64 -A | tr '+/' '-_' | tr -d '=')
    else
        payload=$(printf '{"sub":"%s"}' "$sub" | openssl enc -base64 -A | tr '+/' '-_' | tr -d '=')
    fi
    local sig
    sig=$(printf '%s.%s' "$JWT_HEADER" "$payload" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | openssl enc -base64 -A | tr '+/' '-_' | tr -d '=')
    printf '%s.%s.%s' "$JWT_HEADER" "$payload" "$sig"
}

ADMIN_TOKEN=$(jwt_fast "admin-1" "admin")

# ── Helpers ────────────────────────────────────────────────────

create_show() {
    local name=$1 seats_json=$2 price=$3 limit=$4
    local body
    body=$(printf '{"name":"%s","seats":%s,"price_paise":%d,"per_user_limit":%d}' \
        "$name" "$seats_json" "$price" "$limit")
    local response http_code body_resp
    response=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/shows" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -d "$body")
    http_code=$(echo "$response" | tail -1)
    body_resp=$(echo "$response" | sed '$d')
    if [ "$http_code" != "201" ]; then
        fail "Create show '$name' failed (HTTP $http_code)"
        error_detail "Response: $body_resp"
        return 1
    fi
    echo "$body_resp"
}

get_show() { curl -s "$BASE_URL/shows/$1"; }

extract_field() {
    echo "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -1 | cut -d'"' -f4
}

extract_number() {
    echo "$1" | grep -o "\"$2\":[0-9]*" | head -1 | cut -d: -f2
}

# ── fire_reserve: parallel workers (token gen + curl in one) ───
#
# Each worker reads a chunk of the input, generates JWT tokens,
# and fires HTTP requests — all inside a single background job.
# No intermediate script files, no sequential loops.

fire_reserve() {
    local show_id=$1 results_dir=$2 input_file=$3
    local total
    total=$(wc -l < "$input_file" | tr -d ' ')
    local workers=$PARALLEL
    [ "$workers" -gt "$total" ] && workers=$total

    # Number each line: "1 user-00001 key-00001 A1"
    awk '{print NR, $0}' "$input_file" > "$results_dir/numbered.txt"

    # Split into per-worker chunk files
    local chunk_size=$(( (total + workers - 1) / workers ))
    local chunk_id=0 count=0
    local cf="$results_dir/w_0.txt"
    : > "$cf"
    while IFS= read -r line; do
        echo "$line" >> "$cf"
        count=$((count + 1))
        if [ "$count" -ge "$chunk_size" ]; then
            chunk_id=$((chunk_id + 1))
            cf="$results_dir/w_${chunk_id}.txt"
            : > "$cf"
            count=0
        fi
    done < "$results_dir/numbered.txt"

    info "Firing $total requests ($workers workers x ~$chunk_size each)..."

    # Launch workers — each generates tokens + fires curls for its chunk
    for wf in "$results_dir"/w_*.txt; do
        [ -s "$wf" ] || continue
        (
            while IFS=' ' read -r num user_id idem_key seats_csv; do
                # Inline JWT generation (no function call overhead)
                local payload sig token
                payload=$(printf '{"sub":"%s"}' "$user_id" | openssl enc -base64 -A | tr '+/' '-_' | tr -d '=')
                sig=$(printf '%s.%s' "$JWT_HEADER" "$payload" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | openssl enc -base64 -A | tr '+/' '-_' | tr -d '=')
                token="$JWT_HEADER.$payload.$sig"

                # Fast single-seat path (no sed/tr/paste)
                local seats_json
                case "$seats_csv" in
                    *,*) seats_json=$(echo "$seats_csv" | tr ',' '\n' | sed 's/.*/"&"/' | paste -sd',' | sed 's/^/[/;s/$/]/') ;;
                    *)   seats_json="[\"$seats_csv\"]" ;;
                esac

                curl -s --connect-timeout 10 -m 30 -w '\n%{http_code}' \
                    -X POST "$BASE_URL/shows/$show_id/reserve" \
                    -H "Content-Type: application/json" \
                    -H "Authorization: Bearer $token" \
                    -H "Idempotency-Key: $idem_key" \
                    -d "{\"seats\":$seats_json}" > "$results_dir/$num.resp" 2>/dev/null || true
                if [ -f "$results_dir/$num.resp" ] && [ -s "$results_dir/$num.resp" ]; then
                    tail -1 "$results_dir/$num.resp" > "$results_dir/$num.status"
                else
                    echo "000" > "$results_dir/$num.status"
                fi
            done < "$wf"
        ) &
    done
    wait
}

count_status() {
    local dir=$1 code=$2 result
    result=$(grep -rl "^${code}$" "$dir"/*.status 2>/dev/null | wc -l | tr -d ' ')
    echo "${result:-0}"
}

count_5xx() {
    local dir=$1 result
    result=$(grep -rl '^5' "$dir"/*.status 2>/dev/null | wc -l | tr -d ' ')
    echo "${result:-0}"
}

show_errors() {
    local dir=$1 label=$2
    local err_files
    err_files=$(grep -rl '^5' "$dir"/*.status 2>/dev/null || true)
    if [ -n "$err_files" ]; then
        local shown=0
        for sf in $err_files; do
            [ "$shown" -ge 3 ] && break
            local num
            num=$(basename "$sf" .status)
            local resp_body=""
            if [ -f "$dir/$num.resp" ]; then
                resp_body=$(sed '$d' "$dir/$num.resp" 2>/dev/null || true)
            fi
            error_detail "$label request #$num -> HTTP $(cat "$sf")"
            [ -n "$resp_body" ] && error_detail "  Body: $resp_body"
            shown=$((shown + 1))
        done
        local total_err
        total_err=$(echo "$err_files" | wc -l | tr -d ' ')
        if [ "$total_err" -gt 3 ]; then
            error_detail "... and $((total_err - 3)) more 5xx errors"
        fi
    fi
}

# ── Connectivity ──────────────────────────────────────────────

check_connectivity() {
    printf "\n${BOLD}Preflight${NC}\n"
    local health_resp health_code
    health_resp=$(curl -s -w "\n%{http_code}" --connect-timeout 5 "$BASE_URL/health/live" 2>&1) || true
    health_code=$(echo "$health_resp" | tail -1)
    if [ "$health_code" != "200" ]; then
        printf "${RED}  Cannot reach %s (HTTP %s)${NC}\n" "$BASE_URL" "$health_code"
        exit 1
    fi
    pass "Service reachable at $BASE_URL"
}

# ── Test 1: Hot-Seat Storm ────────────────────────────────────

test_hot_seat() {
    printf "\n${BOLD}=== Test 1: Hot-Seat Storm (%d users -> seat A1) ===${NC}\n" "$HOT_SEAT_USERS"

    local seats='["A1","A2","A3","A4","A5","A6","A7","A8","A9","A10"]'
    local resp
    resp=$(create_show "hot-seat-test" "$seats" 25000 4) || return 0
    local show_id
    show_id=$(extract_field "$resp" "show_id")
    if [ -z "$show_id" ]; then
        fail "Could not extract show_id"
        return 0
    fi
    info "Show created: $show_id"

    local results_dir="$TMPDIR_BURST/hot_seat"
    mkdir -p "$results_dir"

    local input_file="$results_dir/input.txt"
    for i in $(seq 1 "$HOT_SEAT_USERS"); do
        printf "user-%05d key-user-%05d A1\n" "$i" "$i"
    done > "$input_file"
    fire_reserve "$show_id" "$results_dir" "$input_file"

    local c201 c409 c5xx
    c201=$(count_status "$results_dir" 201)
    c409=$(count_status "$results_dir" 409)
    c5xx=$(count_5xx "$results_dir")

    printf "${DIM}  Results: 201=%d  409=%d  5xx=%d${NC}\n" "$c201" "$c409" "$c5xx"

    [ "$c201" -eq 1 ] && pass "Exactly 1 winner" || fail "Expected 1 winner, got $c201"
    [ "$c5xx" -eq 0 ] && pass "Zero 5xx errors" || { fail "Got $c5xx server errors"; show_errors "$results_dir" "Hot-seat"; }

    local total_responses=$((c201 + c409 + c5xx))
    [ "$total_responses" -eq "$HOT_SEAT_USERS" ] \
        && pass "All $HOT_SEAT_USERS requests got a response" \
        || fail "Only $total_responses/$HOT_SEAT_USERS requests got responses"

    local show_state
    show_state=$(get_show "$show_id")
    local available confirmed total
    available=$(extract_number "$show_state" "available")
    confirmed=$(extract_number "$show_state" "confirmed")
    total=$(extract_number "$show_state" "total_seats")
    local sum=$((available + confirmed))

    printf "${DIM}  Seats: available=%d confirmed=%d total=%d${NC}\n" "$available" "$confirmed" "$total"
    [ "$sum" -eq "$total" ] && pass "Reconciliation: $available + $confirmed = $total" \
                            || fail "Reconciliation: $available + $confirmed = $sum (expected $total)"
}

# ── Test 2: Per-User Limit ────────────────────────────────────

test_per_user_limit() {
    local limit=4 requests=10
    printf "\n${BOLD}=== Test 2: Per-User Limit (1 user, %d requests, limit=%d) ===${NC}\n" "$requests" "$limit"

    local seats_json='['
    for i in $(seq 1 20); do
        [ "$i" -gt 1 ] && seats_json+=','
        seats_json+=$(printf '"S%d"' "$i")
    done
    seats_json+=']'

    local resp
    resp=$(create_show "limit-test" "$seats_json" 10000 "$limit") || return 0
    local show_id
    show_id=$(extract_field "$resp" "show_id")
    info "Show created: $show_id (limit=$limit)"

    local results_dir="$TMPDIR_BURST/per_user"
    mkdir -p "$results_dir"

    local input_file="$results_dir/input.txt"
    for i in $(seq 1 "$requests"); do
        printf "limit-user key-limit-%d S%d\n" "$i" "$i"
    done > "$input_file"
    fire_reserve "$show_id" "$results_dir" "$input_file"

    local c201 c409 c5xx
    c201=$(count_status "$results_dir" 201)
    c409=$(count_status "$results_dir" 409)
    c5xx=$(count_5xx "$results_dir")

    printf "${DIM}  Results: 201=%d  409=%d  5xx=%d${NC}\n" "$c201" "$c409" "$c5xx"

    [ "$c201" -le "$limit" ] && pass "Confirmed ($c201) <= limit ($limit)" \
                             || fail "Confirmed ($c201) > limit ($limit)"
    [ "$c201" -gt 0 ] && pass "At least 1 reservation succeeded" \
                      || fail "No reservations succeeded"
    [ "$c5xx" -eq 0 ] && pass "Zero 5xx errors" || { fail "Got $c5xx server errors"; show_errors "$results_dir" "Per-user"; }

    local show_state
    show_state=$(get_show "$show_id")
    local confirmed
    confirmed=$(extract_number "$show_state" "confirmed")
    [ "$confirmed" -le "$limit" ] && pass "DB confirmed ($confirmed) <= limit ($limit)" \
                                  || fail "DB confirmed ($confirmed) > limit ($limit)"
    [ "$confirmed" -eq "$c201" ] && pass "DB confirmed ($confirmed) matches 201 count ($c201)" \
                                 || fail "DB confirmed ($confirmed) != 201 count ($c201)"
}

# ── Test 3: Idempotency ──────────────────────────────────────

test_idempotency() {
    local dupes=20
    printf "\n${BOLD}=== Test 3: Idempotency (%d identical requests) ===${NC}\n" "$dupes"

    local resp
    resp=$(create_show "idempotency-test" '["I1","I2","I3","I4","I5"]' 5000 4) || return 0
    local show_id
    show_id=$(extract_field "$resp" "show_id")
    info "Show created: $show_id"

    local results_dir="$TMPDIR_BURST/idempotency"
    mkdir -p "$results_dir"

    local input_file="$results_dir/input.txt"
    for i in $(seq 1 "$dupes"); do
        echo "idemp-user same-key-123 I1"
    done > "$input_file"
    fire_reserve "$show_id" "$results_dir" "$input_file"

    local c201 c409 c5xx
    c201=$(count_status "$results_dir" 201)
    c409=$(count_status "$results_dir" 409)
    c5xx=$(count_5xx "$results_dir")

    printf "${DIM}  Results: 201=%d  409=%d  5xx=%d${NC}\n" "$c201" "$c409" "$c5xx"

    [ "$c5xx" -eq 0 ] && pass "Zero 5xx errors" || { fail "Got $c5xx server errors"; show_errors "$results_dir" "Idempotency"; }

    local show_state
    show_state=$(get_show "$show_id")
    local confirmed
    confirmed=$(extract_number "$show_state" "confirmed")
    [ "$confirmed" -eq 1 ] && pass "Exactly 1 reservation in DB" \
                           || fail "Expected 1 reservation, got $confirmed"

    info "Testing same key with different seat..."
    local token
    token=$(jwt_fast "idemp-user")
    local conflict_resp conflict_status conflict_body
    conflict_resp=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/shows/$show_id/reserve" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token" \
        -H "Idempotency-Key: same-key-123" \
        -d '{"seats":["I2"]}')
    conflict_status=$(echo "$conflict_resp" | tail -1)
    conflict_body=$(echo "$conflict_resp" | sed '$d')

    if [ "$conflict_status" = "409" ]; then
        pass "Same key + different seat -> 409"
    else
        fail "Same key + different seat: expected 409, got $conflict_status"
        error_detail "Response: $conflict_body"
    fi
}

# ── Test 4: Cancel + Re-reserve ──────────────────────────────

test_cancel() {
    printf "\n${BOLD}=== Test 4: Cancel and Re-reserve ===${NC}\n"

    local resp
    resp=$(create_show "cancel-test" '["C1","C2","C3"]' 5000 4) || return 0
    local show_id
    show_id=$(extract_field "$resp" "show_id")
    info "Show created: $show_id"

    local token
    token=$(jwt_fast "cancel-user")

    # Reserve C1
    local reserve_resp reserve_status reserve_body
    reserve_resp=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/shows/$show_id/reserve" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token" \
        -H "Idempotency-Key: cancel-key-1" \
        -d '{"seats":["C1"]}')
    reserve_status=$(echo "$reserve_resp" | tail -1)
    reserve_body=$(echo "$reserve_resp" | sed '$d')
    if [ "$reserve_status" != "201" ]; then
        fail "Reserve C1 failed (HTTP $reserve_status)"
        error_detail "Response: $reserve_body"
        return 0
    fi
    local res_id
    res_id=$(extract_field "$reserve_body" "reservation_id")
    pass "Reserved C1 (id=$res_id)"

    # Cancel
    local cancel_resp cancel_status
    cancel_resp=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/reservations/$res_id/cancel" \
        -H "Authorization: Bearer $token")
    cancel_status=$(echo "$cancel_resp" | tail -1)
    [ "$cancel_status" = "200" ] && pass "Cancelled reservation" \
        || { fail "Cancel returned HTTP $cancel_status"; error_detail "$(echo "$cancel_resp" | sed '$d')"; }

    # Double cancel
    local double_resp double_status
    double_resp=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/reservations/$res_id/cancel" \
        -H "Authorization: Bearer $token")
    double_status=$(echo "$double_resp" | tail -1)
    [ "$double_status" = "409" ] && pass "Double cancel -> 409" \
        || fail "Double cancel: expected 409, got $double_status"

    # Wrong user
    local token2
    token2=$(jwt_fast "other-user")
    local wrong_resp wrong_status
    wrong_resp=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/reservations/$res_id/cancel" \
        -H "Authorization: Bearer $token2")
    wrong_status=$(echo "$wrong_resp" | tail -1)
    [ "$wrong_status" = "403" ] && pass "Wrong user cancel -> 403" \
        || fail "Wrong user cancel: expected 403, got $wrong_status"

    # Re-reserve
    local re_resp re_status
    re_resp=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/shows/$show_id/reserve" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token2" \
        -H "Idempotency-Key: re-reserve-key" \
        -d '{"seats":["C1"]}')
    re_status=$(echo "$re_resp" | tail -1)
    [ "$re_status" = "201" ] && pass "Re-reserved cancelled seat C1" \
        || fail "Re-reserve: expected 201, got $re_status"

    # Reconciliation
    local show_state
    show_state=$(get_show "$show_id")
    local available confirmed total
    available=$(extract_number "$show_state" "available")
    confirmed=$(extract_number "$show_state" "confirmed")
    total=$(extract_number "$show_state" "total_seats")
    local sum=$((available + confirmed))
    [ "$sum" -eq "$total" ] && pass "Reconciliation: $available + $confirmed = $total" \
        || { fail "Reconciliation: $available + $confirmed = $sum (expected $total)"; error_detail "$show_state"; }
}

# ── Run ───────────────────────────────────────────────────────

printf "\n${BOLD}========================================${NC}\n"
printf "${BOLD}    SEAT RESERVATION BURST TEST${NC}\n"
printf "${BOLD}========================================${NC}\n"
printf "\n  Target:   %s\n" "$BASE_URL"
printf "  Workers:  %d parallel\n" "$PARALLEL"
printf "  Storm:    %d users\n" "$HOT_SEAT_USERS"

check_connectivity
test_hot_seat
test_per_user_limit
test_idempotency
test_cancel

end_time=$(date +%s)
duration=$((end_time - START_TIME))

printf "\n${BOLD}========================================${NC}\n"
printf "  Duration: %ds\n" "$duration"
if [ "$TOTAL_FAIL" -eq 0 ]; then
    printf "  ${GREEN}${BOLD}ALL %d ASSERTIONS PASSED${NC}\n" "$TOTAL_ASSERTIONS"
else
    printf "  ${RED}${BOLD}%d FAILED${NC} / %d assertions (%d passed)\n" \
        "$TOTAL_FAIL" "$TOTAL_ASSERTIONS" "$TOTAL_PASS"
fi
printf "${BOLD}========================================${NC}\n\n"

[ "$TOTAL_FAIL" -eq 0 ] && exit 0 || exit 1
