#!/usr/bin/env bash
# Bench driver for starlight-benchmark (Phase 0 TCP echo).
#
# Phase 0 ships a TCP echo server, not HTTP — the HTTP/1 codec lands in
# Phase 2. TCP echo is the right baseline for measuring the per-loop
# SO_REUSEPORT acceptor model in isolation: it tests how fast we can accept
# connections and bounce bytes back, with zero parsing overhead.
#
# Usage:
#     bench/tcp_echo.sh [host] [port] [duration_sec] [connections] [msg_bytes]
#
# Defaults:
#     host=127.0.0.1  port=8080  duration=10  connections=256  msg_bytes=64
#
# Requires: bash, nc (netcat), /dev/tcp support. No external deps.

set -euo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-8080}"
DURATION="${3:-10}"
CONN="${4:-256}"
BYTES="${5:-64}"

echo "═"
echo "  starlight Phase 0 — TCP echo throughput"
echo "═"
echo "  Target        : ${HOST}:${PORT}"
echo "  Duration      : ${DURATION}s"
echo "  Connections   : ${CONN} (parallel)"
echo "  Message size  : ${BYTES} bytes"
echo "═"
echo ""

# Sanity check: confirm the server is up and echoing before the load test.
SANITY=$(printf "PING" | timeout 1 nc -w 1 "${HOST}" "${PORT}" || true)
if [[ "${SANITY}" != "PING" ]]; then
    echo "ERROR: server is not echoing. Got: '${SANITY}'"
    echo "Start it first:  ./.build/release/starlight-benchmark --port ${PORT}"
    exit 1
fi
echo "✓ Sanity check passed (server echoes 'PING')"

# Generate a payload file once — every connection streams the same bytes.
PAYLOAD=$(mktemp)
trap 'rm -f "${PAYLOAD}"' EXIT
head -c $((BYTES * 10000)) /dev/urandom > "${PAYLOAD}"

# Run `CONN` parallel nc workers, each piping the payload to the server and
# discarding the echo. Kill them all after ${DURATION} seconds.
echo ""
echo "Running ${DURATION}s load test with ${CONN} parallel connections…"
PIDS=()
for i in $(seq 1 "${CONN}"); do
    (
        # Each worker loops sending payload until killed.
        end=$((SECONDS + DURATION))
        while [[ ${SECONDS} -lt ${end} ]]; do
            nc -w 1 "${HOST}" "${PORT}" < "${PAYLOAD}" > /dev/null 2>&1 || true
        done
    ) 2>/dev/null &   # silence "Killed" messages on shutdown
    PIDS+=($!)
done

# Let them run for DURATION seconds, then kill them all.
sleep "${DURATION}"
for pid in "${PIDS[@]}"; do
    kill -9 "${pid}" 2>/dev/null || true
done
wait 2>/dev/null || true

echo "Load test complete."
echo ""
echo "Inspect the benchmark driver's stdout for stats lines:"
echo "    stats  conns=<N>  rx=<bytes>  tx=<bytes>"
echo ""
echo "Throughput estimate  ≈  rx / duration  (each byte echoed = 1 byte received + 1 sent)"
