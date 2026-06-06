# Load Generator

The load generator creates simulated traffic to the demo using
[k6](https://grafana.com/docs/k6/latest/).

It runs a weighted mix of HTTP tasks (browse products, recommendations,
reviews, ads, cart, checkout) against the frontend proxy, and emits all three
telemetry signals as `service.name=load-generator`:

- **traces**: requests carry a W3C `traceparent` (via the vendored
  `http-instrumentation-tempo` jslib), and the generator emits its own spans
  through the `k6/x/tracing` extension (`xk6-client-tracing`) so it appears as a
  service in the trace backend.
- **metrics**: k6's OpenTelemetry output (`--out opentelemetry`).
- **logs**: k6 writes JSON logs to a shared volume that the collector tails with
  a `filelog` receiver (k6 has no native OTLP log export).

## Accessing the Load Generator

The k6 web dashboard is available at `http://localhost:8080/loadgen/`.

## Custom k6 binary

k6 is compiled with the `xk6-client-tracing` extension. The
[Dockerfile](./Dockerfile) builds the binary with `xk6` against k6 v2.0, using
a fork of the extension migrated to the k6 v2 module path. Override the
`XK6_CLIENT_TRACING_REPO` / `XK6_CLIENT_TRACING_REF` build args to point at a
different source once the migration lands upstream.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `LOADGEN_HOST` | `http://frontend-proxy:8080` | Target base URL |
| `LOADGEN_VUS` | `5` | Number of virtual users |
| `LOADGEN_BROWSER_TRAFFIC_ENABLED` | `false` | Enable the k6 browser scenario |
| `LOADGEN_TRACING_ENDPOINT` | `otel-collector:4317` | OTLP endpoint for emitted spans |

Custom configuration uses a `LOADGEN_` prefix because `K6_VUS`, `K6_DURATION`,
and similar names are reserved k6 option env vars that would override the
script's `scenarios` block.

## Modifying the Load Generator

Edit [`load.js`](./load.js). See the
[k6 documentation](https://grafana.com/docs/k6/latest/using-k6/) for the test
API.
