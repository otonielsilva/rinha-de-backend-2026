#!/bin/bash
# Download GitHub Actions load test results

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "======================================================================"
echo "GitHub Actions Results Downloader"
echo "======================================================================"
echo ""

# Check if gh CLI is available
if ! command -v gh &> /dev/null; then
    echo "❌ GitHub CLI not found. Install with:"
    echo "   brew install gh (macOS)"
    echo "   sudo apt install gh (Ubuntu/Debian)"
    exit 1
fi

# Get run IDs from user
echo "First, get the RUN IDs from:"
echo "  ! gh run list --limit 10 --json headBranch,status,conclusion,databaseId"
echo ""
echo "Enter RUN IDs (or 'q' to quit):"
echo ""

# Branches to download
declare -A branches=(
    [main]="main"
    [snapshot]="opt/build-time-snapshot"
    [ivf]="opt/ivf-ann"
)

# Download function
download_artifacts() {
    local branch_key=$1
    local branch_name=$2
    local run_id=$3

    if [ -z "$run_id" ] || [ "$run_id" = "0" ]; then
        echo "⏭️  Skipping $branch_name"
        return
    fi

    local dir="gh-results-${branch_key}"
    echo "📥 Downloading $branch_name (RUN_ID: $run_id)..."

    mkdir -p "$dir"
    gh run download "$run_id" -D "$dir/" || {
        echo "❌ Failed to download $branch_name"
        return 1
    }

    if [ -f "$dir/load-test-results/results.json" ]; then
        echo "✅ $branch_name artifacts downloaded"
        cat "$dir/load-test-results/results.json" | jq '.' | head -10
    else
        echo "⚠️  results.json not found in artifacts"
    fi
    echo ""
}

# Interactive input
for key in "${!branches[@]}"; do
    read -p "RUN_ID for ${branches[$key]} (or 0 to skip): " run_id
    download_artifacts "$key" "${branches[$key]}" "$run_id"
done

echo ""
echo "======================================================================"
echo "Summary"
echo "======================================================================"
echo ""

for key in "${!branches[@]}"; do
    dir="gh-results-${key}"
    if [ -f "$dir/load-test-results/results.json" ]; then
        echo "✅ $dir/load-test-results/results.json"
    else
        echo "❌ $dir — no results"
    fi
done

echo ""
echo "When all downloads are complete, compare results with:"
echo "  python3 /tmp/process_results.py"
