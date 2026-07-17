# Starlight baseline — pre-audit

Hardware: AMD Ryzen 5 5600H (12 cores), Linux, loopback
Build:   swift build -c release, epoll backend, router mode
wrk:     -t12 -c256 -d10s --latency

| Endpoint         | req/s    | p50    | p99     |
|------------------|----------|--------|---------|
| `/`              | 296,771  | 622µs  | 9.91ms  |
| `/health`        | 292,029  | 640µs  | 7.75ms  |
| `/users/42`      | 266,549  | 691µs  | 13.12ms |
