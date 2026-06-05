#!/bin/bash

set -e

RESULTS_DIR="load-test-results"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_BASE="${RESULTS_DIR}/${TIMESTAMP}"
REMOTE="origin"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

mkdir -p "$RESULTS_BASE"

echo -e "${BLUE}=== Load Test Runner ===${NC}"
echo "Results directory: $RESULTS_BASE"
echo ""

# Get initial branch
INITIAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo -e "${YELLOW}Initial branch: $INITIAL_BRANCH${NC}"

# Fetch latest from remote
echo -e "${YELLOW}Fetching latest branches from remote...${NC}"
git fetch "$REMOTE" > /dev/null 2>&1
echo -e "${GREEN}✓ Fetch complete${NC}"
echo ""

# Get all remote branches except main/master, strip the remote prefix
BRANCHES=$(git branch -r | grep "$REMOTE/" | grep -v "HEAD" | grep -v "main\|master" | sed "s|^ *$REMOTE/||" | sort -u)

if [ -z "$BRANCHES" ]; then
  echo -e "${RED}No branches found to test (excluding main/master)${NC}"
  exit 1
fi

echo "Branches to test:"
echo "$BRANCHES" | sed 's/^/  - /'
echo ""

# Test results summary
declare -A results
declare -A durations
declare -A iterations

for branch in $BRANCHES; do
  echo -e "${BLUE}Testing branch: ${YELLOW}$branch${NC}"

  # Checkout branch (create local tracking if needed)
  if git rev-parse --verify "$branch" > /dev/null 2>&1; then
    # Local branch exists
    if ! git checkout "$branch" > /dev/null 2>&1; then
      echo -e "${RED}  ✗ Failed to checkout branch${NC}"
      results["$branch"]="CHECKOUT_FAILED"
      continue
    fi
  else
    # Local branch doesn't exist, create from remote
    echo -e "${YELLOW}  Creating local tracking branch for $REMOTE/$branch${NC}"
    if ! git checkout -b "$branch" "$REMOTE/$branch" > /dev/null 2>&1; then
      echo -e "${RED}  ✗ Failed to checkout remote branch${NC}"
      results["$branch"]="CHECKOUT_FAILED"
      continue
    fi
  fi

  # Update to latest remote
  echo -e "${YELLOW}  Pulling latest from remote...${NC}"
  if ! git pull --rebase "$REMOTE" "$branch" > /dev/null 2>&1; then
    echo -e "${YELLOW}  ⚠ Pull/rebase had issues (continuing anyway)${NC}"
  fi

  BRANCH_RESULTS_DIR="${RESULTS_BASE}/${branch}"
  mkdir -p "$BRANCH_RESULTS_DIR"

  # Build image
  echo -e "${YELLOW}  Building Docker image...${NC}"
  if ! docker build -t rinhabackend-2026:test .. > "$BRANCH_RESULTS_DIR/build.log" 2>&1; then
    echo -e "${RED}  ✗ Build failed${NC}"
    results["$branch"]="BUILD_FAILED"
    continue
  fi
  echo -e "${GREEN}  ✓ Build successful${NC}"

  # Run load test
  echo -e "${YELLOW}  Running load test...${NC}"
  export DOCKER_IMAGE="rinhabackend-2026:test"

  COMPOSE="docker compose -f ../docker-compose.yml -f ../docker-compose.load-test.yml"

  # Start services
  if ! $COMPOSE up -d > /dev/null 2>&1; then
    echo -e "${RED}  ✗ Failed to start services${NC}"
    results["$branch"]="START_FAILED"
    $COMPOSE down -v 2>/dev/null || true
    continue
  fi

  # Wait for k6 to complete
  EXIT_CODE=0
  if ! $COMPOSE wait k6-load > "$BRANCH_RESULTS_DIR/wait.log" 2>&1; then
    EXIT_CODE=$?
  fi

  # Collect logs
  $COMPOSE logs k6-load > "$BRANCH_RESULTS_DIR/k6-output.log" 2>&1 || true
  $COMPOSE logs api1 > "$BRANCH_RESULTS_DIR/api1.log" 2>&1 || true
  $COMPOSE logs api2 > "$BRANCH_RESULTS_DIR/api2.log" 2>&1 || true
  $COMPOSE logs lb > "$BRANCH_RESULTS_DIR/lb.log" 2>&1 || true

  # Collect results
  if [ -f "../test/results.json" ]; then
    cp "../test/results.json" "$BRANCH_RESULTS_DIR/results.json"

    # Generate markdown summary
    {
      echo "# Load Test Results: $branch"
      echo ""
      echo "**Test Date:** $(date)"
      echo ""
      echo "## Scoring Results"
      echo ""

      # Extract scoring data
      FINAL_SCORE=$(jq '.scoring.final_score' "$BRANCH_RESULTS_DIR/results.json" 2>/dev/null)
      P99=$(jq '.p99' "$BRANCH_RESULTS_DIR/results.json" 2>/dev/null)

      echo "- **Final Score:** $FINAL_SCORE"
      echo "- **P99 Latency:** ${P99}ms"
      echo ""

      echo "## Detection Breakdown"
      echo ""

      # Extract detection metrics
      TP=$(jq '.scoring.breakdown.true_positive_detections' "$BRANCH_RESULTS_DIR/results.json" 2>/dev/null)
      TN=$(jq '.scoring.breakdown.true_negative_detections' "$BRANCH_RESULTS_DIR/results.json" 2>/dev/null)
      FP=$(jq '.scoring.breakdown.false_positive_detections' "$BRANCH_RESULTS_DIR/results.json" 2>/dev/null)
      FN=$(jq '.scoring.breakdown.false_negative_detections' "$BRANCH_RESULTS_DIR/results.json" 2>/dev/null)
      ERRORS=$(jq '.scoring.breakdown.http_errors' "$BRANCH_RESULTS_DIR/results.json" 2>/dev/null)

      echo "| Metric | Count |"
      echo "|--------|-------|"
      echo "| True Positives (TP) | $TP |"
      echo "| True Negatives (TN) | $TN |"
      echo "| False Positives (FP) | $FP |"
      echo "| False Negatives (FN) | $FN |"
      echo "| HTTP Errors | $ERRORS |"
      echo ""

      # Calculate accuracy
      TOTAL=$((TP + TN + FP + FN + ERRORS))
      if [ "$TOTAL" -gt 0 ]; then
        ACCURACY=$(echo "scale=4; ($TP + $TN) / ($TOTAL - $ERRORS) * 100" | bc 2>/dev/null || echo "N/A")
        echo "**Accuracy:** ${ACCURACY}%"
        echo ""
      fi

      echo "## Expected Distribution"
      echo ""

      # Extract expected distribution
      TOTAL_EXPECTED=$(jq '.expected.total' "$BRANCH_RESULTS_DIR/results.json" 2>/dev/null)
      FRAUD_COUNT=$(jq '.expected.fraud_count' "$BRANCH_RESULTS_DIR/results.json" 2>/dev/null)
      LEGIT_COUNT=$(jq '.expected.legit_count' "$BRANCH_RESULTS_DIR/results.json" 2>/dev/null)
      EDGE_CASE=$(jq '.expected.edge_case_count' "$BRANCH_RESULTS_DIR/results.json" 2>/dev/null)

      echo "| Category | Count | Rate |"
      echo "|----------|-------|------|"
      echo "| Total Payloads | $TOTAL_EXPECTED | 100% |"
      echo "| Fraud Cases | $FRAUD_COUNT | $(jq '.expected.fraud_rate * 100' "$BRANCH_RESULTS_DIR/results.json" 2>/dev/null | cut -d. -f1)% |"
      echo "| Legitimate Cases | $LEGIT_COUNT | $(jq '.expected.legit_rate * 100' "$BRANCH_RESULTS_DIR/results.json" 2>/dev/null | cut -d. -f1)% |"
      echo "| Edge Cases | $EDGE_CASE | $(jq '.expected.edge_case_rate * 100' "$BRANCH_RESULTS_DIR/results.json" 2>/dev/null | cut -d. -f1)% |"
      echo ""

      echo "## Error Metrics"
      echo ""

      FAILURE_RATE=$(jq '.scoring.failure_rate * 100' "$BRANCH_RESULTS_DIR/results.json" 2>/dev/null)
      ERROR_EPSILON=$(jq '.scoring.error_rate_epsilon * 100' "$BRANCH_RESULTS_DIR/results.json" 2>/dev/null)
      WEIGHTED_ERRORS=$(jq '.scoring.weighted_errors_E' "$BRANCH_RESULTS_DIR/results.json" 2>/dev/null)

      echo "- **Failure Rate:** ${FAILURE_RATE}%"
      echo "- **Error Rate (epsilon):** ${ERROR_EPSILON}%"
      echo "- **Weighted Errors:** $WEIGHTED_ERRORS"
      echo ""

    } > "$BRANCH_RESULTS_DIR/RESULTS.md"

    echo -e "${GREEN}  ✓ Markdown summary generated${NC}"

    if [ "$EXIT_CODE" -eq 0 ]; then
      echo -e "${GREEN}  ✓ Load test successful${NC}"
      results["$branch"]="PASSED"
    else
      echo -e "${YELLOW}  ⚠ Load test completed with exit code $EXIT_CODE${NC}"
      results["$branch"]="COMPLETED_WITH_ERRORS"
    fi
  else
    echo -e "${RED}  ✗ Results file not found${NC}"
    results["$branch"]="NO_RESULTS"
  fi

  # Cleanup
  $COMPOSE down -v > /dev/null 2>&1 || true
  unset DOCKER_IMAGE

  echo ""
done

# Return to initial branch
echo -e "${BLUE}Returning to initial branch: ${YELLOW}$INITIAL_BRANCH${NC}"
git checkout "$INITIAL_BRANCH" > /dev/null 2>&1 || echo -e "${RED}Warning: Could not return to $INITIAL_BRANCH${NC}"

# Print summary
echo ""
echo -e "${BLUE}=== Test Summary ===${NC}"
echo ""
echo "Results stored in: $RESULTS_BASE"
echo ""

# Create summary file
SUMMARY_FILE="${RESULTS_BASE}/SUMMARY.txt"
{
  echo "Load Test Summary - $(date)"
  echo "========================================"
  echo ""
  echo "Branch Results:"

  for branch in $BRANCHES; do
    STATUS=${results["$branch"]}
    ITERS=${iterations["$branch"]}
    DURATION=${durations["$branch"]}

    if [ -z "$STATUS" ]; then
      STATUS="UNKNOWN"
    fi

    printf "%-40s | Status: %-20s | Iterations: %s | Duration: %s\n" "$branch" "$STATUS" "$ITERS" "$DURATION"
  done

  echo ""
  echo "Detailed results in respective branch directories"
} | tee "$SUMMARY_FILE"

# Print table
echo ""
echo -e "${BLUE}Branch Results Table:${NC}"
echo ""
printf "%-40s | %-20s | %12s | %10s\n" "Branch" "Status" "Iterations" "Duration(s)"
echo "--------------------------------------|----------------------|--------------|----------"

for branch in $BRANCHES; do
  STATUS=${results["$branch"]}
  ITERS=${iterations["$branch"]:-"N/A"}
  DURATION=${durations["$branch"]:-"N/A"}

  if [ -z "$STATUS" ]; then
    STATUS="UNKNOWN"
  fi

  case "$STATUS" in
    "PASSED")
      STATUS_COLORED="${GREEN}${STATUS}${NC}"
      ;;
    "COMPLETED_WITH_ERRORS")
      STATUS_COLORED="${YELLOW}${STATUS}${NC}"
      ;;
    *)
      STATUS_COLORED="${RED}${STATUS}${NC}"
      ;;
  esac

  printf "%-40s | ${STATUS_COLORED:--} | %12s | %10s\n" "$branch" "$ITERS" "$DURATION"
done

echo ""
echo -e "${GREEN}All tests completed!${NC}"
echo -e "${YELLOW}View detailed results in: ${RESULTS_BASE}${NC}"
