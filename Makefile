.PHONY: build test dev up down wait-ready smoke load generate-data estimated-requests post-run

GOCACHE ?= /tmp/go-build
PARTICIPANT ?=
REPO_URL ?=
SUBMISSION_ID ?= default
COMMIT ?=
ISSUE ?=
READY_URL ?= http://localhost:9999/ready
READY_RETRIES ?= 20
READY_SLEEP ?= 3

build:
	go build ./cmd/api

test:
	GOCACHE=$(GOCACHE) go test ./...

dev:
	GOCACHE=$(GOCACHE) go run ./cmd/api

up:
	docker compose up --build -d

down:
	docker compose down

wait-ready:
	@i=0; \
	until curl -fsS "$(READY_URL)" >/dev/null; do \
		i=$$((i + 1)); \
		if [ $$i -ge "$(READY_RETRIES)" ]; then \
			echo "timeout waiting for $(READY_URL)" >&2; \
			exit 1; \
		fi; \
		sleep "$(READY_SLEEP)"; \
	done

smoke:
	@status=0; \
	docker compose up --build -d; \
	i=0; \
	until curl -fsS "$(READY_URL)" >/dev/null; do \
		i=$$((i + 1)); \
		if [ $$i -ge "$(READY_RETRIES)" ]; then \
			echo "timeout waiting for $(READY_URL)" >&2; \
			status=1; \
			break; \
		fi; \
		sleep "$(READY_SLEEP)"; \
	done; \
	if [ $$status -eq 0 ]; then \
		K6_NO_USAGE_REPORT=true docker compose -f test/docker-compose.yml --profile smoke up --abort-on-container-exit --exit-code-from k6-smoke || status=$$?; \
	fi; \
	docker compose down; \
	exit $$status

load:
	@status=0; \
	docker compose up --build -d; \
	i=0; \
	until curl -fsS "$(READY_URL)" >/dev/null; do \
		i=$$((i + 1)); \
		if [ $$i -ge "$(READY_RETRIES)" ]; then \
			echo "timeout waiting for $(READY_URL)" >&2; \
			status=1; \
			break; \
		fi; \
		sleep "$(READY_SLEEP)"; \
	done; \
	if [ $$status -eq 0 ]; then \
		K6_NO_USAGE_REPORT=true docker compose -f test/docker-compose.yml --profile test up --abort-on-container-exit --exit-code-from k6 || status=$$?; \
	fi; \
	docker compose down; \
	exit $$status

generate-data:
	./generate-data.sh

estimated-requests:
	./estimated-requests.sh

post-run:
	./post-run.sh $(PARTICIPANT) $(REPO_URL) $(SUBMISSION_ID) $(COMMIT) $(ISSUE)
