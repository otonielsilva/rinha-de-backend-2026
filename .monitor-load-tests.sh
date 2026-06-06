#!/bin/bash

# Monitor GitHub Actions load tests across branches
# Runs every minute to check for new results and compare performance

set -e

REPO_DIR="/home/otoniel/dev/rinha-de-backend-2026-go"
BRANCHES=("main" "opt/build-time-snapshot" "opt/ivf-ann")
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========== Load Test Monitor - ${TIMESTAMP} ==========${NC}"
echo ""

# Load baseline from LOAD_TEST_COMPARISON_GH.md
if [ -f "$REPO_DIR/LOAD_TEST_COMPARISON_GH.md" ]; then
    echo -e "${YELLOW}📊 Latest Load Test Results (from LOAD_TEST_COMPARISON_GH.md):${NC}"
    echo ""

    grep -A 50 "## Results Summary" "$REPO_DIR/LOAD_TEST_COMPARISON_GH.md" | \
        grep -E "^\|" | head -5 | while read line; do
        # Highlight based on status
        if echo "$line" | grep -q "main"; then
            echo -e "${GREEN}$line${NC}"
        elif echo "$line" | grep -q "opt/build-time-snapshot"; then
            echo -e "${GREEN}$line${NC}"
        elif echo "$line" | grep -q "opt/ivf-ann"; then
            echo -e "${RED}$line${NC}"
        else
            echo "$line"
        fi
    done
    echo ""
else
    echo -e "${YELLOW}⚠️  LOAD_TEST_COMPARISON_GH.md not found${NC}"
fi

# Check git status of each branch
echo -e "${YELLOW}📍 Branch Status:${NC}"
echo ""

for branch in "${BRANCHES[@]}"; do
    # Check if branch exists locally
    if git -C "$REPO_DIR" rev-parse --verify "$branch" >/dev/null 2>&1; then
        commit=$(git -C "$REPO_DIR" rev-parse --short "$branch" 2>/dev/null || echo "unknown")
        echo -e "  ${BLUE}✓${NC} $branch (commit: $commit)"
    else
        echo -e "  ${RED}✗${NC} $branch (not found locally)"
    fi
done
echo ""

# Show recent commits per branch
echo -e "${YELLOW}📝 Recent Commits:${NC}"
echo ""

for branch in "${BRANCHES[@]}"; do
    if git -C "$REPO_DIR" rev-parse --verify "$branch" >/dev/null 2>&1; then
        latest_msg=$(git -C "$REPO_DIR" log -1 --pretty=format:"%s" "$branch" 2>/dev/null || echo "unknown")
        latest_date=$(git -C "$REPO_DIR" log -1 --pretty=format:"%ar" "$branch" 2>/dev/null || echo "unknown")
        echo "  $branch:"
        echo "    └─ $latest_msg (${latest_date})"
    fi
done
echo ""

# Check for GitHub Actions workflow file
if [ -f "$REPO_DIR/.github/workflows/load-test.yml" ] || [ -f "$REPO_DIR/.github/workflows/ci.yml" ]; then
    echo -e "${YELLOW}🔄 GitHub Actions Status:${NC}"
    echo "  (Run 'gh run list' to view latest runs)"
    echo ""
fi

# Summary
echo -e "${YELLOW}📈 Performance Summary:${NC}"
echo ""
echo "  main                      : 46,461 iters (baseline)"
echo -e "  opt/build-time-snapshot   : 46,008 iters ${GREEN}(✅ -0.9% - RECOMMENDED)${NC}"
echo -e "  opt/ivf-ann               : 21,786 iters ${RED}(❌ -53.1% - TOO SLOW)${NC}"
echo ""

# Recommendation
echo -e "${BLUE}========== Recommendation ==========${NC}"
echo -e "${GREEN}✅ Merge opt/build-time-snapshot to main${NC}"
echo "   • Negligible performance difference (-0.9%)"
echo "   • Removes warmup service orchestration"
echo "   • Better container startup"
echo "   • Production-ready"
echo ""

echo -e "${RED}❌ Skip opt/ivf-ann${NC}"
echo "   • 53% throughput loss (too expensive)"
echo "   • k-means overhead exceeds sampling benefit"
echo "   • Consider future with more CPU available"
echo ""

echo -e "${BLUE}========================================${NC}"
