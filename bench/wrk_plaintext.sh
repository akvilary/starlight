#!/usr/bin/env bash
# Bench driver for starlight-benchmark (Phase 0 TCP echo).
#
# Usage:
#     bench/wrk_plaintext.sh [host] [port] [duration] [connections] [threads]
#
# Defaults:
#     host=127.0.0.1  port=8080  duration=30s  connections=256  threads=<cores>
#
# Requires wrk (https://github.com/wg/wrk). On Ubuntu: `apt install wrk`.

set -euo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-8080}"
DURATION="${3:-30s}"
CONNECTIONS="${4:-256}"
THREADS="${5:-$(nproc)}"

URL="http://${HOST}:${PORT}/"

echo "═"
echo "  starlight Phase 0 — wrk TCP echo"
echo "═"
echo "  URL          : ${URL}"
echo "  duration     : ${DURATION}"
echo "  connections  : ${CONNECTIONS}"
echo "  threads      : ${THREADS}"
echo "  (note: server is TCP echo; wrk reports raw throughput)"
echo "═"

wrk -t"${THREADS}" -c"${CONNECTIONS}" -d"${DURATION}" --latency "${URL}"
