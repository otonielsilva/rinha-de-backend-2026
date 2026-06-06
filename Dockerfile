FROM golang:1.23-alpine AS builder

WORKDIR /src
COPY go.mod ./
COPY cmd ./cmd
COPY internal ./internal

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o /out/api ./cmd/api

# Pre-build snapshot during Docker image build
FROM alpine:3.20 AS snapshot-builder

RUN apk add --no-cache ca-certificates curl
WORKDIR /app
COPY --from=builder /out/api /app/api
COPY resources /app/resources

RUN mkdir -p /app/cache && \
    RINHA_RESOURCES_DIR=/app/resources \
    RINHA_CACHE_DIR=/app/cache \
    RINHA_WARMUP_ONLY=1 \
    /app/api && \
    echo "Snapshot references.bin pre-built during image build"

FROM alpine:3.20

RUN apk add --no-cache ca-certificates curl
WORKDIR /app
COPY --from=builder /out/api /app/api
COPY --from=snapshot-builder /app/cache /app/cache
COPY resources /app/resources
EXPOSE 9999
ENTRYPOINT ["/app/api"]

