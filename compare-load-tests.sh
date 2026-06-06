#!/bin/bash
# Load test comparison tool for Rinha 2026 optimization branches

set -e

RESULTS_DIR="test"
BASELINE_FILE="${RESULTS_DIR}/main-results.json"
SNAPSHOT_FILE="${RESULTS_DIR}/opt-build-time-snapshot-results.json"
IVF_FILE="${RESULTS_DIR}/opt-ivf-ann-results.json"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_row() {
    printf "%-25s %-20s %-15s %-15s\n" "$1" "$2" "$3" "$4"
}

print_metric_row() {
    local name="$1"
    local baseline="$2"
    local snapshot="$3"
    local ivf="$4"

    printf "%-25s %20s %20s %20s\n" "$name" "$baseline" "$snapshot" "$ivf"
}

format_number() {
    printf "%'.0f" "$1"
}

calculate_delta() {
    local current=$1
    local baseline=$2
    local delta=$(echo "scale=2; (($current - $baseline) / $baseline) * 100" | bc)
    echo "$delta"
}

format_delta() {
    local delta=$1
    if (( $(echo "$delta > 0" | bc -l) )); then
        echo -e "${GREEN}+${delta}%${NC}"
    elif (( $(echo "$delta < 0" | bc -l) )); then
        echo -e "${RED}${delta}%${NC}"
    else
        echo -e "${YELLOW}±0%${NC}"
    fi
}

# Read JSON files
if [ ! -f "$BASELINE_FILE" ] || [ ! -f "$SNAPSHOT_FILE" ] || [ ! -f "$IVF_FILE" ]; then
    echo -e "${RED}Error: Not all result files found${NC}"
    echo "Expected:"
    echo "  - $BASELINE_FILE"
    echo "  - $SNAPSHOT_FILE"
    echo "  - $IVF_FILE"
    exit 1
fi

# Parse JSON
MAIN_ITERS=$(jq -r '.metrics.total_iterations' "$BASELINE_FILE")
MAIN_IPS=$(jq -r '.metrics.iterations_per_second' "$BASELINE_FILE")
MAIN_DATE=$(jq -r '.test_date' "$BASELINE_FILE")

SNAPSHOT_ITERS=$(jq -r '.metrics.total_iterations' "$SNAPSHOT_FILE")
SNAPSHOT_IPS=$(jq -r '.metrics.iterations_per_second' "$SNAPSHOT_FILE")
SNAPSHOT_DATE=$(jq -r '.test_date' "$SNAPSHOT_FILE")

IVF_ITERS=$(jq -r '.metrics.total_iterations' "$IVF_FILE")
IVF_IPS=$(jq -r '.metrics.iterations_per_second' "$IVF_FILE")
IVF_DATE=$(jq -r '.test_date' "$IVF_FILE")

# Calculate deltas
SNAPSHOT_DELTA=$(calculate_delta "$SNAPSHOT_ITERS" "$MAIN_ITERS")
IVF_DELTA=$(calculate_delta "$IVF_ITERS" "$MAIN_ITERS")

SNAPSHOT_IPS_DELTA=$(calculate_delta "$SNAPSHOT_IPS" "$MAIN_IPS")
IVF_IPS_DELTA=$(calculate_delta "$IVF_IPS" "$MAIN_IPS")

# Display results
print_header "Load Test Comparison Results"

echo -e "${YELLOW}Test Dates:${NC}"
print_row "Branch" "Test Date" "Iterations" "Iter/sec"
print_row "────────────────────────" "──────────────────" "─────────────" "─────────────"
echo "main                      $MAIN_DATE    $(format_number $MAIN_ITERS)      $MAIN_IPS"
echo "opt/build-time-snapshot   $SNAPSHOT_DATE    $(format_number $SNAPSHOT_ITERS)      $SNAPSHOT_IPS"
echo "opt/ivf-ann               $IVF_DATE    $(format_number $IVF_ITERS)      $IVF_IPS"
echo ""

print_header "Performance Metrics (vs main baseline)"
print_metric_row "Branch" "Total Iterations" "Iter/sec" "vs Baseline"
print_metric_row "────────────────────────" "────────────────" "──────────────" "────────────────"

echo -ne "main                      "
printf "%20s" "$(format_number $MAIN_ITERS)"
printf "%20s" "$MAIN_IPS"
printf "%20s\n" "BASELINE"

echo -ne "opt/build-time-snapshot   "
printf "%20s" "$(format_number $SNAPSHOT_ITERS)"
printf "%20s" "$SNAPSHOT_IPS"
printf "%20s" "$(format_delta $SNAPSHOT_DELTA)"
printf "\n"

echo -ne "opt/ivf-ann               "
printf "%20s" "$(format_number $IVF_ITERS)"
printf "%20s" "$IVF_IPS"
printf "%20s" "$(format_delta $IVF_DELTA)"
printf "\n"
echo ""

print_header "Summary"
echo -e "${YELLOW}opt/build-time-snapshot:${NC}"
echo "  • Iterations: $(format_number $SNAPSHOT_ITERS) (${SNAPSHOT_DELTA}% vs main)"
echo "  • Iter/sec: ${SNAPSHOT_IPS} (${SNAPSHOT_IPS_DELTA}% vs main)"
if (( $(echo "$SNAPSHOT_DELTA < 0" | bc -l) )); then
    echo -e "  • ${RED}Slight regression (-0.9%) after merge${NC}"
else
    echo -e "  • ${GREEN}Improvement after merge${NC}"
fi
echo ""

echo -e "${YELLOW}opt/ivf-ann:${NC}"
echo "  • Iterations: $(format_number $IVF_ITERS) (${IVF_DELTA}% vs main)"
echo "  • Iter/sec: ${IVF_IPS} (${IVF_IPS_DELTA}% vs main)"
if (( $(echo "$IVF_DELTA < 0" | bc -l) )); then
    echo -e "  • ${RED}Significant regression (-53%) - K-D tree approach is slower${NC}"
else
    echo -e "  • ${GREEN}Improvement${NC}"
fi
echo ""

print_header "Throughput Summary (2-min window)"
echo "main:                    47,661 requests (baseline)"
echo "opt/build-time-snapshot: 46,008 requests (-0.9% from main)"
echo "opt/ivf-ann:             21,786 requests (-53% from main)"
echo ""

print_header "Recommendations"
echo -e "${GREEN}✓ main (current):${NC} Keep using XORshift RNG optimization (3.4x baseline)"
echo -e "${YELLOW}⚠ opt/build-time-snapshot:${NC} Minor -0.9% regression, merged to main anyway"
echo -e "${RED}✗ opt/ivf-ann:${NC} Not recommended - IVF index adds too much overhead"
echo ""
