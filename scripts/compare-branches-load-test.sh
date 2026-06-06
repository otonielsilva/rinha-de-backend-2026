#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Load Test Comparison Script for Multiple Branches
# ============================================================================
# Usage:
#   ./scripts/compare-branches-load-test.sh main opt/ivf-v2-zero-alloc
#   ./scripts/compare-branches-load-test.sh --all
#   ./scripts/compare-branches-load-test.sh --branches main,opt/ivf-v2-zero-alloc,opt/phase4-tuning
#
# Output:
#   - Individual results in scripts/load-test-results/[timestamp]/[branch]/
#   - Comparison CSV: scripts/load-test-results/[timestamp]/COMPARISON.csv
# ============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_DIR="scripts/load-test-results/${TIMESTAMP}"
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
LOAD_TEST_TIMEOUT="${LOAD_TEST_TIMEOUT:-480}"  # 8 minutes per branch
READY_TIMEOUT="${READY_TIMEOUT:-60}"
READY_URL="${READY_URL:-http://localhost:9999/ready}"
BRANCHES=()
COMPARE_ONLY=false

# ============================================================================
# Utility Functions
# ============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[✗]${NC} $*"
}

die() {
    log_error "$@"
    exit 1
}

wait_for_ready() {
    local timeout=$1
    local elapsed=0
    log_info "Waiting for API to be ready (max ${timeout}s)..."

    until curl -fsS "$READY_URL" >/dev/null 2>&1; do
        if [ $elapsed -ge $timeout ]; then
            return 1
        fi
        elapsed=$((elapsed + 1))
        sleep 1
    done
    log_success "API is ready"
    return 0
}

cleanup_docker() {
    log_info "Cleaning up Docker containers..."
    docker compose down 2>/dev/null || true
    sleep 2
}

run_load_test_for_branch() {
    local branch=$1
    local branch_results_dir="${RESULTS_DIR}/${branch//\//-}"

    mkdir -p "$branch_results_dir"

    log_info "=========================================="
    log_info "Testing branch: $branch"
    log_info "=========================================="

    # Checkout branch
    if ! git checkout "$branch" 2>&1 | tail -3; then
        log_error "Failed to checkout $branch"
        return 1
    fi

    local commit=$(git rev-parse --short HEAD)
    log_info "Commit: $commit"

    # Build Docker image
    log_info "Building Docker image..."
    if ! timeout 300 docker compose build --no-cache api 2>&1 | tail -20 > "${branch_results_dir}/build.log"; then
        log_error "Build failed"
        cat "${branch_results_dir}/build.log"
        return 1
    fi
    log_success "Build completed"

    # Start services
    log_info "Starting services..."
    cleanup_docker

    if ! docker compose up -d 2>&1 > "${branch_results_dir}/startup.log"; then
        log_error "Failed to start services"
        cat "${branch_results_dir}/startup.log"
        cleanup_docker
        return 1
    fi

    # Wait for API to be ready
    if ! timeout $READY_TIMEOUT wait_for_ready $READY_TIMEOUT; then
        log_error "API failed to become ready within ${READY_TIMEOUT}s"
        docker compose logs > "${branch_results_dir}/logs-failed-startup.log"
        cleanup_docker
        return 1
    fi

    # Run load test
    log_info "Running load test..."
    local k6_status=0
    if ! timeout $LOAD_TEST_TIMEOUT \
        K6_NO_USAGE_REPORT=true docker compose -f test/docker-compose.yml \
        --profile test run --rm k6 2>&1 | tee "${branch_results_dir}/k6-output.log"; then
        k6_status=$?
        log_warn "Load test exited with status $k6_status"
    fi

    # Collect results
    log_info "Collecting results..."
    docker compose logs api > "${branch_results_dir}/api.log" 2>&1 || true
    docker compose logs nginx > "${branch_results_dir}/nginx.log" 2>&1 || true

    # Extract metrics from k6 output
    extract_metrics_from_k6 "${branch_results_dir}/k6-output.log" > "${branch_results_dir}/metrics.json" || {
        log_warn "Could not extract metrics from k6 output"
    }

    # Cleanup
    cleanup_docker

    # Generate summary
    generate_branch_summary "$branch" "$commit" "${branch_results_dir}"

    log_success "Branch $branch testing completed"
    return 0
}

extract_metrics_from_k6() {
    local log_file=$1

    # Extract key metrics using grep + awk
    local http_reqs=$(grep -i "http_reqs" "$log_file" | tail -1 | awk '{print $2}')
    local http_errors=$(grep -i "http_errors\|http.*error" "$log_file" | tail -1 | awk '{print $2}')
    local p99=$(grep -i "p(99)" "$log_file" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
    local avg=$(grep -i "avg.*http_req_duration" "$log_file" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)

    jq -n \
        --arg http_reqs "$http_reqs" \
        --arg http_errors "$http_errors" \
        --arg p99 "$p99" \
        --arg avg "$avg" \
        '{
            http_reqs: ($http_reqs | tonumber | select(. > 0) // empty),
            http_errors: ($http_errors | tonumber | select(. > 0) // empty),
            p99_ms: ($p99 | tonumber | select(. > 0) // empty),
            avg_ms: ($avg | tonumber | select(. > 0) // empty)
        }' 2>/dev/null || echo '{}'
}

generate_branch_summary() {
    local branch=$1
    local commit=$2
    local results_dir=$3

    cat > "${results_dir}/SUMMARY.md" <<EOF
# Load Test Results: $branch

**Commit:** $commit
**Test Date:** $(date -Iseconds)
**Results Directory:** $results_dir

## Metrics

EOF

    if [ -f "${results_dir}/metrics.json" ]; then
        cat "${results_dir}/metrics.json" | jq -r '
            "- HTTP Requests: " + (.http_reqs // "N/A" | tostring) + "\n" +
            "- HTTP Errors: " + (.http_errors // "N/A" | tostring) + "\n" +
            "- P99 Latency: " + (.p99_ms // "N/A" | tostring) + " ms\n" +
            "- Avg Latency: " + (.avg_ms // "N/A" | tostring) + " ms"
        ' >> "${results_dir}/SUMMARY.md" 2>/dev/null || true
    fi

    cat >> "${results_dir}/SUMMARY.md" <<EOF

## Logs

- Build log: \`build.log\`
- K6 output: \`k6-output.log\`
- API logs: \`api.log\`
- Nginx logs: \`nginx.log\`
- Metrics: \`metrics.json\`
EOF
}

generate_comparison() {
    log_info "=========================================="
    log_info "Generating Comparison Report"
    log_info "=========================================="

    local csv_file="${RESULTS_DIR}/COMPARISON.csv"
    local md_file="${RESULTS_DIR}/COMPARISON.md"

    # CSV Header
    echo "branch,commit,http_reqs,http_errors,p99_ms,avg_ms,status" > "$csv_file"
    echo "# Load Test Comparison - $TIMESTAMP" > "$md_file"
    echo "" >> "$md_file"
    echo "| Branch | Commit | Requests | Errors | P99 (ms) | Avg (ms) |" >> "$md_file"
    echo "|--------|--------|----------|--------|----------|----------|" >> "$md_file"

    for branch in "${BRANCHES[@]}"; do
        local branch_dir="${RESULTS_DIR}/${branch//\//-}"
        if [ ! -d "$branch_dir" ]; then
            continue
        fi

        local summary="${branch_dir}/SUMMARY.md"
        if [ ! -f "$summary" ]; then
            continue
        fi

        local metrics="${branch_dir}/metrics.json"
        if [ ! -f "$metrics" ]; then
            log_warn "No metrics found for $branch"
            continue
        fi

        local commit=$(git log -1 --format='%h' -- "$branch_dir" 2>/dev/null || echo "unknown")

        # Extract metrics
        local data=$(jq -r '
            .http_reqs as $reqs |
            .http_errors as $errors |
            .p99_ms as $p99 |
            .avg_ms as $avg |
            "\(.http_reqs // 0),\(.http_errors // 0),\(.p99_ms // 0),\(.avg_ms // 0)"
        ' "$metrics" 2>/dev/null || echo "0,0,0,0")

        echo "$branch,$commit,$data,completed" >> "$csv_file"

        local reqs=$(echo "$data" | cut -d, -f1)
        local errors=$(echo "$data" | cut -d, -f2)
        local p99=$(echo "$data" | cut -d, -f3)
        local avg=$(echo "$data" | cut -d, -f4)

        echo "| $branch | $commit | $reqs | $errors | $p99 | $avg |" >> "$md_file"
    done

    log_success "Comparison reports generated:"
    log_info "  CSV: $csv_file"
    log_info "  Markdown: $md_file"

    # Display comparison
    echo ""
    log_info "Summary:"
    cat "$md_file"
}

parse_arguments() {
    if [ $# -eq 0 ]; then
        log_error "No branches specified"
        print_usage
        exit 1
    fi

    while [ $# -gt 0 ]; do
        case "$1" in
            --all)
                # All opt branches + main
                BRANCHES=("main" "opt/ivf-v2-zero-alloc" "opt/phase4-tuning")
                shift
                ;;
            --branches)
                # Comma-separated list
                shift
                IFS=',' read -ra BRANCHES <<< "$1"
                shift
                ;;
            --compare-only)
                COMPARE_ONLY=true
                shift
                ;;
            *)
                BRANCHES+=("$1")
                shift
                ;;
        esac
    done
}

print_usage() {
    cat <<EOF
Usage: $0 [OPTIONS] [BRANCHES...]

Run load tests on multiple branches and compare results.

Options:
  --all              Test all optimization branches (main, opt/ivf-v2-zero-alloc, opt/phase4-tuning)
  --branches LIST    Test branches from comma-separated list (e.g., main,opt/ivf-v2-zero-alloc)
  --compare-only     Skip testing, only generate comparison from existing results

Arguments:
  BRANCHES           Individual branches to test (space-separated)

Examples:
  $0 main opt/ivf-v2-zero-alloc
  $0 --all
  $0 --branches main,opt/ivf-v2-zero-alloc,opt/phase4-tuning

Environment Variables:
  LOAD_TEST_TIMEOUT    Timeout per branch in seconds (default: 480)
  READY_TIMEOUT        Timeout for API readiness in seconds (default: 60)
  READY_URL            URL to check for API readiness (default: http://localhost:9999/ready)

EOF
}

# ============================================================================
# Main
# ============================================================================

main() {
    parse_arguments "$@"

    log_info "Load Test Comparison Script"
    log_info "Branches to test: ${BRANCHES[*]}"
    log_info "Results will be saved to: $RESULTS_DIR"
    log_info "Current branch: $ORIGINAL_BRANCH"
    echo ""

    mkdir -p "$RESULTS_DIR"

    if [ "$COMPARE_ONLY" = false ]; then
        local failed_branches=()

        for branch in "${BRANCHES[@]}"; do
            if ! run_load_test_for_branch "$branch"; then
                failed_branches+=("$branch")
            fi
            echo ""
        done

        # Return to original branch
        log_info "Returning to original branch: $ORIGINAL_BRANCH"
        git checkout "$ORIGINAL_BRANCH" 2>&1 | tail -2

        if [ ${#failed_branches[@]} -gt 0 ]; then
            log_warn "Some branches failed: ${failed_branches[*]}"
        fi
    fi

    # Generate comparison
    generate_comparison

    log_success "All tests completed!"
    log_info "Results saved to: $RESULTS_DIR"
}

main "$@"
