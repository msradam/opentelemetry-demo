# Load generator memory benchmark

Reproducible comparison of the k6 load generator against the Locust load
generator it replaces, motivated by
[#2685](https://github.com/open-telemetry/opentelemetry-demo/issues/2685)
(the load generator is the demo's largest memory consumer).

The goal is a clean-room, fully reproducible measurement that anyone can run to
independently confirm the numbers.

## What it measures

Each load generator runs in its own fresh container against the same target (the
demo `frontend`), under an identical workload (same user/VU count, same task
mix, same wait times), exporting telemetry to a real collector. The script
samples steady-state memory (RSS) and reports the average.

Four configurations:

| Configuration | Engine | Browser traffic |
| --- | --- | --- |
| `k6 (HTTP)` | k6 | off (proposed default) |
| `Locust (HTTP)` | Locust | off |
| `Locust (browser, default)` | Locust | on, embedded Chromium (demo's current default) |
| `k6 (browser, embedded)` | k6 | on, embedded Chromium |

The HTTP rows are the same-functionality comparison (identical task mix and
telemetry). The browser rows compare full functionality including front-end RUM
traffic.

## Running it

```bash
./benchmark/run-benchmark.sh
```

Tunables (env vars): `USERS` (default 5), `WARMUP` (60s), `SAMPLES` (6),
`SAMPLE_INTERVAL` (10s). Results are written to `benchmark/results.md`.

Requirements: Docker, and this repository (the script builds the k6 image from
`src/load-generator/Dockerfile` and the Locust comparator from a `main` git
worktree, so no published images are required).

## Sample results

A sample run (5 users, 120s warmup, 6 samples; Apple M-series under colima).
Absolute numbers depend on the host, so reproduce locally to confirm; the
ratios are the point.

| Configuration | Avg memory |
| --- | ---: |
| k6 (HTTP) | 25 MiB |
| Locust (HTTP) | 75 MiB |
| Locust (browser, default) | 1081 MiB |
| k6 (browser, embedded) | 214 MiB |

Image sizes: k6 200 MB, Locust 2.32 GB.

- Same functionality (HTTP + the three telemetry signals): k6 uses ~67% less
  memory than Locust (25 vs 75 MiB).
- Full functionality (with front-end browser traffic): k6 uses ~80% less (214 MiB
  vs 1081 MiB). k6 drives one efficient headless browser; Locust's default model
  spawns a Chromium per browser user.
- Versus the demo's current default (Locust with browser traffic, ~1081 MiB), the
  proposed k6 HTTP default (~25 MiB) is roughly 40x smaller, and the image is
  ~11x smaller.

## Fairness notes

- Both engines run the same number of users/VUs against the same target with the
  same per-task wait-time distribution, so the offered load is equivalent by
  construction. The script also records k6 iteration counts.
- Memory is sampled from `docker stats` (RSS) multiple times at steady state and
  averaged, after a warmup so connection pools and (for browser) Chromium are
  fully initialized.
- The browser rows embed Chromium in both images so they compare on equal
  footing. This is **not** how production browser traffic should run: k6 can
  offload Chromium to a separate, memory-capped container via
  [crocochrome](https://github.com/grafana/crocochrome) and
  `K6_BROWSER_WS_URL`, keeping the load generator itself small. The embedded row
  exists only to compare the two engines directly.

## Interpreting

Reduced memory at equivalent functionality is the win condition for #2685. The
HTTP rows isolate the engine cost; the browser rows show full-functionality
parity; and comparing `k6 (HTTP)` against `Locust (browser, default)` shows the
delta against what the demo ships today.
