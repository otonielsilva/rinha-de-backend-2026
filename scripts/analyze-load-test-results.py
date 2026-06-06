#!/usr/bin/env python3
"""
Analyze load test results and generate detailed comparison reports.

Usage:
    ./scripts/analyze-load-test-results.py 20260605-120000
    ./scripts/analyze-load-test-results.py 20260605-120000 --format json
    ./scripts/analyze-load-test-results.py 20260605-120000 --format html
"""

import json
import sys
import os
from pathlib import Path
from typing import Dict, List, Any, Optional
import re
from datetime import datetime
import argparse


class LoadTestAnalyzer:
    def __init__(self, results_dir: str):
        self.results_path = Path("scripts/load-test-results") / results_dir
        if not self.results_path.exists():
            raise FileNotFoundError(f"Results directory not found: {self.results_path}")

        self.branches = [
            d.name for d in self.results_path.iterdir()
            if d.is_dir() and d.name != "__pycache__"
        ]

    def parse_k6_output(self, log_file: Path) -> Dict[str, Any]:
        """Parse k6 JSON output and extract metrics."""
        if not log_file.exists():
            return {}

        metrics = {
            "http_requests": 0,
            "http_errors": 0,
            "http_timeouts": 0,
            "p99_latency_ms": 0,
            "p95_latency_ms": 0,
            "avg_latency_ms": 0,
            "min_latency_ms": 0,
            "max_latency_ms": 0,
            "checks_passed": 0,
            "checks_failed": 0,
            "success_rate": 0.0,
        }

        try:
            with open(log_file) as f:
                content = f.read()

                # Extract HTTP metrics
                http_reqs = re.search(r"(\d+)\s+http_reqs", content)
                if http_reqs:
                    metrics["http_requests"] = int(http_reqs.group(1))

                http_errors = re.search(r"(\d+)\s+http_errors", content)
                if http_errors:
                    metrics["http_errors"] = int(http_errors.group(1))

                http_timeouts = re.search(r"(\d+)\s+http.*timeout", content)
                if http_timeouts:
                    metrics["http_timeouts"] = int(http_timeouts.group(1))

                # Extract latency metrics
                p99 = re.search(r"http_req_duration.*?p\(99\)=(\d+\.?\d*)", content)
                if p99:
                    metrics["p99_latency_ms"] = float(p99.group(1))

                p95 = re.search(r"http_req_duration.*?p\(95\)=(\d+\.?\d*)", content)
                if p95:
                    metrics["p95_latency_ms"] = float(p95.group(1))

                avg = re.search(r"http_req_duration.*?avg=(\d+\.?\d*)", content)
                if avg:
                    metrics["avg_latency_ms"] = float(avg.group(1))

                min_lat = re.search(r"http_req_duration.*?min=(\d+\.?\d*)", content)
                if min_lat:
                    metrics["min_latency_ms"] = float(min_lat.group(1))

                max_lat = re.search(r"http_req_duration.*?max=(\d+\.?\d*)", content)
                if max_lat:
                    metrics["max_latency_ms"] = float(max_lat.group(1))

                # Calculate success rate
                if metrics["http_requests"] > 0:
                    failed = metrics["http_errors"] + metrics["http_timeouts"]
                    metrics["success_rate"] = (
                        (metrics["http_requests"] - failed) / metrics["http_requests"] * 100
                    )

        except Exception as e:
            print(f"Error parsing {log_file}: {e}", file=sys.stderr)

        return metrics

    def analyze_branch(self, branch: str) -> Dict[str, Any]:
        """Analyze results for a single branch."""
        branch_dir = self.results_path / branch
        metrics_file = branch_dir / "metrics.json"
        k6_log = branch_dir / "k6-output.log"
        summary_file = branch_dir / "SUMMARY.md"

        result = {
            "branch": branch,
            "commit": "unknown",
            "test_date": "unknown",
            "metrics": {},
        }

        # Try to read metrics.json first
        if metrics_file.exists():
            try:
                with open(metrics_file) as f:
                    result["metrics"] = json.load(f)
            except json.JSONDecodeError:
                pass

        # Parse k6 log if metrics.json didn't have complete data
        if not result["metrics"] or len(result["metrics"]) < 5:
            result["metrics"] = self.parse_k6_output(k6_log)

        # Extract commit from summary
        if summary_file.exists():
            try:
                with open(summary_file) as f:
                    for line in f:
                        if "Commit:" in line:
                            result["commit"] = line.split(":")[-1].strip()
                        if "Test Date:" in line:
                            result["test_date"] = line.split(":")[-1].strip()
            except Exception as e:
                print(f"Error reading {summary_file}: {e}", file=sys.stderr)

        return result

    def generate_json_report(self) -> str:
        """Generate JSON report."""
        results = []
        for branch in sorted(self.branches):
            results.append(self.analyze_branch(branch))

        return json.dumps({"timestamp": str(self.results_path),
                          "results": results}, indent=2)

    def generate_markdown_report(self) -> str:
        """Generate Markdown comparison report."""
        results = [self.analyze_branch(b) for b in sorted(self.branches)]

        report = f"""# Load Test Comparison Report

**Results Directory:** {self.results_path.name}
**Generated:** {datetime.now().isoformat()}

## Summary Table

| Branch | Commit | Requests | Errors | P99 (ms) | Avg (ms) | Success % |
|--------|--------|----------|--------|----------|----------|-----------|
"""

        for r in results:
            m = r["metrics"]
            requests = m.get("http_requests", "N/A")
            errors = m.get("http_errors", "N/A")
            p99 = f"{m.get('p99_latency_ms', 0):.1f}" if m.get("p99_latency_ms") else "N/A"
            avg = f"{m.get('avg_latency_ms', 0):.1f}" if m.get("avg_latency_ms") else "N/A"
            success = f"{m.get('success_rate', 0):.1f}%" if m.get("success_rate") else "N/A"
            report += f"| {r['branch']} | {r['commit']} | {requests} | {errors} | {p99} | {avg} | {success} |\n"

        # Detailed analysis per branch
        report += "\n## Detailed Results\n\n"

        for r in results:
            m = r["metrics"]
            report += f"### {r['branch']}\n\n"
            report += f"**Commit:** {r['commit']}  \n"
            report += f"**Test Date:** {r['test_date']}  \n\n"

            if m:
                report += "**Metrics:**\n"
                report += f"- HTTP Requests: {m.get('http_requests', 'N/A')}\n"
                report += f"- HTTP Errors: {m.get('http_errors', 'N/A')}\n"
                report += f"- HTTP Timeouts: {m.get('http_timeouts', 'N/A')}\n"
                report += f"- P99 Latency: {m.get('p99_latency_ms', 'N/A')} ms\n"
                report += f"- P95 Latency: {m.get('p95_latency_ms', 'N/A')} ms\n"
                report += f"- Avg Latency: {m.get('avg_latency_ms', 'N/A')} ms\n"
                report += f"- Min Latency: {m.get('min_latency_ms', 'N/A')} ms\n"
                report += f"- Max Latency: {m.get('max_latency_ms', 'N/A')} ms\n"
                report += f"- Success Rate: {m.get('success_rate', 'N/A')}%\n"
            report += "\n"

        return report

    def generate_html_report(self) -> str:
        """Generate HTML comparison report."""
        results = [self.analyze_branch(b) for b in sorted(self.branches)]

        html = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Load Test Comparison Report</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 20px; }
        h1 { color: #333; border-bottom: 2px solid #007bff; padding-bottom: 10px; }
        h2 { color: #555; margin-top: 30px; }
        table { border-collapse: collapse; width: 100%; margin-top: 10px; }
        th, td { padding: 12px; text-align: left; border-bottom: 1px solid #ddd; }
        th { background-color: #007bff; color: white; }
        tr:hover { background-color: #f5f5f5; }
        .success { color: #28a745; }
        .error { color: #dc3545; }
        .warning { color: #ffc107; }
        .metric { background-color: #f8f9fa; padding: 15px; margin: 10px 0; border-left: 4px solid #007bff; }
        .comparison { display: flex; gap: 20px; flex-wrap: wrap; }
        .branch-card { flex: 1; min-width: 300px; border: 1px solid #ddd; padding: 15px; border-radius: 5px; }
    </style>
</head>
<body>
    <h1>Load Test Comparison Report</h1>
    <p><strong>Results Directory:</strong> {}</p>
    <p><strong>Generated:</strong> {}</p>

    <h2>Summary Table</h2>
    <table>
        <tr>
            <th>Branch</th>
            <th>Commit</th>
            <th>Requests</th>
            <th>Errors</th>
            <th>P99 (ms)</th>
            <th>Avg (ms)</th>
            <th>Success %</th>
        </tr>
""".format(self.results_path.name, datetime.now().isoformat())

        for r in results:
            m = r["metrics"]
            requests = m.get("http_requests", "N/A")
            errors = m.get("http_errors", "N/A")
            error_class = "error" if errors and errors > 0 else "success"
            p99 = f"{m.get('p99_latency_ms', 0):.1f}" if m.get("p99_latency_ms") else "N/A"
            avg = f"{m.get('avg_latency_ms', 0):.1f}" if m.get("avg_latency_ms") else "N/A"
            success = f"{m.get('success_rate', 0):.1f}%" if m.get("success_rate") else "N/A"
            success_class = "success" if m.get("success_rate", 0) >= 99 else "warning" if m.get("success_rate", 0) >= 95 else "error"

            html += f"""        <tr>
            <td>{r['branch']}</td>
            <td>{r['commit']}</td>
            <td>{requests}</td>
            <td class="{error_class}">{errors}</td>
            <td>{p99}</td>
            <td>{avg}</td>
            <td class="{success_class}">{success}</td>
        </tr>
"""

        html += """    </table>

    <h2>Detailed Results</h2>
    <div class="comparison">
"""

        for r in results:
            m = r["metrics"]
            success_class = "success" if m.get("success_rate", 0) >= 99 else "warning" if m.get("success_rate", 0) >= 95 else "error"

            html += f"""        <div class="branch-card">
            <h3>{r['branch']}</h3>
            <div class="metric">
                <strong>Commit:</strong> {r['commit']}<br>
                <strong>Test Date:</strong> {r['test_date']}
            </div>
"""

            if m:
                html += f"""            <div class="metric">
                <strong>HTTP Requests:</strong> {m.get('http_requests', 'N/A')}<br>
                <strong>HTTP Errors:</strong> <span class="error">{m.get('http_errors', 'N/A')}</span><br>
                <strong>HTTP Timeouts:</strong> {m.get('http_timeouts', 'N/A')}<br>
                <strong class="{success_class}">Success Rate:</strong> <span class="{success_class}">{m.get('success_rate', 'N/A')}%</span>
            </div>
            <div class="metric">
                <strong>P99 Latency:</strong> {m.get('p99_latency_ms', 'N/A')} ms<br>
                <strong>P95 Latency:</strong> {m.get('p95_latency_ms', 'N/A')} ms<br>
                <strong>Avg Latency:</strong> {m.get('avg_latency_ms', 'N/A')} ms<br>
                <strong>Min/Max Latency:</strong> {m.get('min_latency_ms', 'N/A')} / {m.get('max_latency_ms', 'N/A')} ms
            </div>
"""
            html += """        </div>
"""

        html += """    </div>
</body>
</html>
"""
        return html


def main():
    parser = argparse.ArgumentParser(
        description="Analyze load test results and generate reports"
    )
    parser.add_argument("results_dir", help="Results directory name (e.g., 20260605-120000)")
    parser.add_argument(
        "--format",
        choices=["json", "markdown", "html"],
        default="markdown",
        help="Output format (default: markdown)",
    )
    parser.add_argument(
        "--output",
        help="Output file (default: stdout)",
    )

    args = parser.parse_args()

    try:
        analyzer = LoadTestAnalyzer(args.results_dir)
    except FileNotFoundError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    if args.format == "json":
        output = analyzer.generate_json_report()
    elif args.format == "html":
        output = analyzer.generate_html_report()
    else:  # markdown
        output = analyzer.generate_markdown_report()

    if args.output:
        with open(args.output, "w") as f:
            f.write(output)
        print(f"Report written to {args.output}")
    else:
        print(output)


if __name__ == "__main__":
    main()
