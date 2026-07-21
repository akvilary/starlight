# Starlight baseline — pre-TODO-fixes

Hardware: AMD Ryzen 5 5600H (12 cores), Linux, loopback
Build:   swift build -c release, epoll backend, router mode
wrk:     -t12 -c256 -d10s --latency (3 runs each, 15s cooldown between)

| Endpoint         | run 1    | run 2    | run 3    | AVG      | p50    | p99    |
|------------------|----------|----------|----------|----------|--------|--------|
| `/`              | 273,449  | 274,191  | 274,473  | 274,038  | 760µs  | 3.6ms  |
| `/health`        | 270,373  | 275,629  | 276,492  | 274,165  | 761µs  | 3.3ms  |
| `/users/42`      | 259,633  | 257,472  | 255,678  | 257,594  | 787µs  | 4.4ms  |

Used as reference for regression checks during TODO fixes.
