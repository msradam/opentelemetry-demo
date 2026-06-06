# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Build a custom k6 binary bundling the trace-emitting extension. The load
# generator emits its own spans (via k6/x/tracing) so it appears as a service
# in the trace backend, mirroring the previous Locust setup.
FROM docker.io/library/golang:1.26-bookworm AS builder

ARG K6_VERSION=v2.0.0
# Source for the xk6-client-tracing extension, migrated to the k6 v2 module
# path. Override these to point at upstream once the migration lands there.
ARG XK6_CLIENT_TRACING_REPO=https://github.com/msradam/xk6-client-tracing.git
ARG XK6_CLIENT_TRACING_REF=k6-v2-migration

RUN go install go.k6.io/xk6/cmd/xk6@v1.4.6

RUN git clone --depth 1 --branch "${XK6_CLIENT_TRACING_REF}" \
    "${XK6_CLIENT_TRACING_REPO}" /src/xk6-client-tracing

# xk6 reads the k6 version from the K6_VERSION env (exposed by the ARG above),
# so it must not also be passed as a positional argument.
RUN xk6 build \
    --with github.com/grafana/xk6-client-tracing=/src/xk6-client-tracing \
    --output /k6

FROM docker.io/library/debian:bookworm-slim
WORKDIR /loadgen
RUN mkdir -p /loadgen-logs
COPY --from=builder /k6 /usr/bin/k6
COPY ./src/load-generator/load.js ./load.js
COPY ./src/load-generator/people.json ./people.json
COPY ./src/load-generator/vendor ./vendor
# --log-output / --log-format are only honored as flags (not env vars). k6 logs,
# including the script's console output, are written as JSON to a shared volume
# that the collector tails via a filelog receiver.
ENTRYPOINT ["k6", "run", "--log-output=file=/loadgen-logs/k6.log", "--log-format=json", "/loadgen/load.js"]
