#!/usr/bin/env python3
"""Prepare a pre-PERF-02 Flutter UI baseline without changing the worktree.

Usage: python3 scripts/prepare-directory-benchmark.py --baseline-ref <commit>
Then build app with -t ../.native/perf-02/baseline/benchmark.dart.
"""
import argparse
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref", required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    revision = subprocess.check_output(
        ["git", "rev-parse", "--verify", args.baseline_ref + "^{commit}"],
        cwd=root, text=True,
    ).strip()
    target = root / ".native/perf-02/baseline"
    target.mkdir(parents=True, exist_ok=True)
    for name in ("main.dart", "file_browser.dart"):
        source = subprocess.check_output(
            ["git", "show", f"{revision}:app/lib/{name}"], cwd=root, text=True,
        )

        def rewrite(match):
            uri = match[2]
            if ":" in uri or (name == "main.dart" and uri == "file_browser.dart"):
                return match[0]
            return match[1] + "'package:vhdx_reader/" + uri + "';"

        source = re.sub(r"(import |export )'([^']+)';", rewrite, source)
        if name == "file_browser.dart":
            old_enum = "enum FileSort { name, size, modified, type }"
            if old_enum not in source:
                raise SystemExit("Expected a pre-PERF-02 file_browser.dart baseline")
            # Reuse the identical enum type expected by today's BrowserSettings.
            source = source.replace(old_enum, "")
            source = (
                "import 'package:vhdx_reader/file_order.dart' show FileSort;\n"
                "export 'package:vhdx_reader/file_order.dart' show FileSort;\n"
                + source
            )
        (target / name).write_text(source, encoding="utf-8")
    harness = (root / "app/tool/directory_ui_benchmark.dart").read_text(encoding="utf-8")
    harness = harness.replace("'package:vhdx_reader/main.dart'", "'main.dart'")
    harness = harness.replace("'package:vhdx_reader/file_browser.dart'", "'file_browser.dart'")
    # Old UI only publishes the complete directory and has no loading property.
    harness = harness.replace("!contents.loading && ", "")
    (target / "benchmark.dart").write_text(harness, encoding="utf-8")
    (target / "revision.txt").write_text(revision + "\n", encoding="utf-8")
    print(target)


if __name__ == "__main__":
    main()
