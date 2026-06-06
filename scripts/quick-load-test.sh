#!/usr/bin/env bash
# Quick load test runner with sensible defaults

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Default: test main, ivf-v2-zero-alloc, and phase4
BRANCHES="${1:---all}"

echo "🚀 Starting load test comparison..."
echo "   Branches: $BRANCHES"
echo ""

# Run the comparison
bash scripts/compare-branches-load-test.sh $BRANCHES

# Extract timestamp from the most recent results directory
LATEST_RESULT=$(ls -td scripts/load-test-results/*/ 2>/dev/null | head -1 | xargs -I {} basename {})

if [ -z "$LATEST_RESULT" ]; then
    echo "❌ No results found"
    exit 1
fi

echo ""
echo "📊 Generating reports..."
python3 scripts/analyze-load-test-results.py "$LATEST_RESULT" --format markdown

echo ""
echo "📁 Full results in: scripts/load-test-results/$LATEST_RESULT"
echo ""
echo "✅ To view HTML report:"
echo "   python3 scripts/analyze-load-test-results.py $LATEST_RESULT --format html --output report.html"
echo "   open report.html"
