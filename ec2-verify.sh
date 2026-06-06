#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./ec2-verify.sh [--image IMAGE] [smoke|load]

Examples:
  ./ec2-verify.sh
  ./ec2-verify.sh load
  ./ec2-verify.sh --image myuser/rinhabackend-2026:latest smoke

Behavior:
  - smoke: starts the stack, checks /ready, runs test/smoke.js
  - load: starts the stack, checks /ready, runs test/test.js
  - --image: pulls and reuses a prebuilt image instead of building from source
EOF
}

require_cmd() {
    local cmd_name="$1"
    if ! command -v "$cmd_name" >/dev/null 2>&1; then
        echo "erro: comando obrigatório não encontrado: $cmd_name" >&2
        exit 1
    fi
}

wait_ready() {
    local url="$1"
    local retries="${2:-40}"
    local sleep_secs="${3:-3}"
    local attempt=1

    until curl -fsS "$url" >/dev/null; do
        if (( attempt >= retries )); then
            echo "erro: timeout aguardando $url" >&2
            return 1
        fi
        attempt=$((attempt + 1))
        sleep "$sleep_secs"
    done
}

verify_ready() {
    local base_url="$1"
    local ready_body
    ready_body="$(curl -fsS "$base_url/ready")"

    if [[ "$ready_body" != "ok" ]]; then
        echo "erro: /ready respondeu diferente de 'ok': $ready_body" >&2
        return 1
    fi

    echo "ready: ok"
}

verify_fraud_score() {
    local base_url="$1"
    local response

    response="$(
        curl -fsS \
            -X POST "$base_url/fraud-score" \
            -H 'Content-Type: application/json' \
            --data-binary @- <<'JSON'
{
  "id": "ec2-verify-001",
  "transaction": {
    "amount": 384.88,
    "installments": 3,
    "requested_at": "2026-03-11T20:23:35Z"
  },
  "customer": {
    "avg_amount": 769.76,
    "tx_count_24h": 3,
    "known_merchants": ["MERC-009", "MERC-001", "MERC-001"]
  },
  "merchant": {
    "id": "MERC-001",
    "mcc": "5912",
    "avg_amount": 298.95
  },
  "terminal": {
    "is_online": false,
    "card_present": true,
    "km_from_home": 13.7090520965
  },
  "last_transaction": {
    "timestamp": "2026-03-11T14:58:35Z",
    "km_from_current": 18.8626479774
  }
}
JSON
    )"

    jq -e '
        (.approved | type == "boolean")
        and (.fraud_score | type == "number")
    ' >/dev/null <<<"$response"

    echo "fraud-score: ok"
}

run_compose() {
    local compose_args=("$@")
    docker compose "${compose_args[@]}" up -d
}

main() {
    local image=""
    local mode="smoke"

    while (($#)); do
        case "$1" in
            --image)
                image="${2:-}"
                if [[ -z "$image" ]]; then
                    echo "erro: --image exige um valor" >&2
                    usage
                    exit 1
                fi
                shift 2
                ;;
            smoke|load)
                mode="$1"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "erro: argumento desconhecido: $1" >&2
                usage
                exit 1
                ;;
        esac
    done

    require_cmd docker
    require_cmd curl
    require_cmd jq

    local stack_args=()

    if [[ -n "$image" ]]; then
        echo "pulando build local e usando imagem: $image"
        docker pull "$image"
        export DOCKER_IMAGE="$image"
        stack_args=(--no-build)
    else
        stack_args=(--build)
    fi

    cleanup() {
        docker compose down -v >/dev/null 2>&1 || true
        docker compose -f test/docker-compose.yml down -v >/dev/null 2>&1 || true
    }
    trap cleanup EXIT

    echo "subindo stack principal..."
    run_compose "${stack_args[@]}"

    echo "aguardando /ready..."
    wait_ready "http://localhost:9999/ready"

    verify_ready "http://localhost:9999"
    verify_fraud_score "http://localhost:9999"

    case "$mode" in
        smoke)
            echo "rodando smoke test..."
            K6_NO_USAGE_REPORT=true docker compose -f test/docker-compose.yml --profile smoke up --abort-on-container-exit --exit-code-from k6-smoke
            ;;
        load)
            echo "rodando load test..."
            K6_NO_USAGE_REPORT=true docker compose -f test/docker-compose.yml --profile test up --abort-on-container-exit --exit-code-from k6
            ;;
    esac

    echo "verificação concluída com sucesso"
}

main "$@"
