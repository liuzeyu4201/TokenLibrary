FROM golang:1.25-bookworm AS build
WORKDIR /src
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
RUN CGO_ENABLED=0 go build -trimpath -o /out/tokenlibrary ./cmd/tokenlibrary \
    && CGO_ENABLED=0 go build -trimpath -o /out/library-admin ./cmd/library-admin

# Keep pg_dump/pg_restore on exactly the same major as the database service.
FROM postgres:17-bookworm@sha256:639ab7ceb90e13123085b741fb31ef493fba25463002f6da665352e7b534b652
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --create-home --home-dir /app app
WORKDIR /app
COPY --from=build /out/tokenlibrary /out/library-admin /usr/local/bin/
COPY server/schema/initial.sql /app/schema/initial.sql
USER 10001:10001
ENV SCHEMA_PATH=/app/schema/initial.sql
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=9 \
    CMD curl --fail --silent http://127.0.0.1:8080/health/ready >/dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/tokenlibrary"]
