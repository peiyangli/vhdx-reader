#!/usr/bin/env python3
"""Prepare isolated before/after PERF-07 Flutter profile targets.

Use --baseline-file for a saved pre-change thumbnails.dart, or --baseline-ref
for a pre-PERF-07 commit. Production files and cache directories are untouched.
Build from app with -t ../.native/perf-07/repro/benchmark.dart; set
VHDX_THUMB_BENCH_OUTPUT to a new JSONL path before launching the executable.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def imports(source):
    return re.sub(
        r"(import|export) '([a-z_]+\.dart)'",
        r"\1 'package:vhdx_reader/\2'",
        source,
    )


def idle(source):
    marker = '  Future<void> _diskTail'
    if marker not in source:
        raise SystemExit('Expected the thumbnail disk scheduler')
    return source.replace(marker, '''  Future<void> get benchmarkIdle async {
    while (_running > 0 || _queue.isNotEmpty || _lookups > 0 || _lookupQueue.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await _diskTail;
  }
''' + marker, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--baseline-file', type=Path)
    group.add_argument('--baseline-ref')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    if args.baseline_file:
        baseline = args.baseline_file.read_text(encoding='utf-8')
        origin = str(args.baseline_file)
    else:
        revision = subprocess.check_output(
            ['git', 'rev-parse', '--verify', args.baseline_ref + '^{commit}'],
            cwd=root, text=True,
        ).strip()
        baseline = subprocess.check_output(
            ['git', 'show', f'{revision}:app/lib/thumbnails.dart'],
            cwd=root, text=True,
        )
        origin = revision
    candidate = (root / 'app/lib/thumbnails.dart').read_text(encoding='utf-8')
    if 'Future<void> _writeDisk(_Job job, Thumbnail value)' not in baseline:
        raise SystemExit('Expected a pre-PERF-07 thumbnails.dart baseline')
    if 'persistenceCountLimit' not in candidate:
        raise SystemExit('Expected the PERF-07 implementation in app/lib/thumbnails.dart')
    metadata = {
        'baseline': origin,
        'baseline_sha256': hashlib.sha256(baseline.encode()).hexdigest(),
        'candidate_sha256': hashlib.sha256(candidate.encode()).hexdigest(),
        'notes': 'Synthetic 8 ms generation, real PNG/filesystem I/O; round 0 warmup; OS cache not flushed.',
    }
    # Same artificial write delay and codec boundary hook as the candidate.
    baseline = baseline.replace(
        '@visibleForTesting this.videoTransport,',
        '@visibleForTesting this.videoTransport,\n    @visibleForTesting this.persistenceHook,',
    ).replace(
        'final String? videoTransport;',
        'final String? videoTransport;\n  final Future<void> Function(String)? persistenceHook;',
    ).replace(
        'await temporary.writeAsString(encoded);',
        "await persistenceHook?.call('write');\n          await temporary.writeAsString(encoded);",
    ).replace(
        'final epoch = _diskEpoch;\n    final bytes',
        "final epoch = _diskEpoch;\n    await persistenceHook?.call('encode');\n    final bytes",
    )
    target = root / '.native/perf-07/repro'
    target.mkdir(parents=True, exist_ok=True)
    for name, source in [('baseline', baseline), ('candidate', candidate)]:
        (target / f'{name}.dart').write_text(idle(imports(source)), encoding='utf-8')
    harness = (root / 'scripts/benchmarks/thumbnail_cache.dart').read_text(encoding='utf-8')
    (target / 'benchmark.dart').write_text(harness, encoding='utf-8')
    (target / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
    print(target)


if __name__ == '__main__':
    main()
