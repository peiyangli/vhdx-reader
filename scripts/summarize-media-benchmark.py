#!/usr/bin/env python3
"""Summarize saved HTTP/native transport trials; never reads media or credentials."""
import argparse
import csv
import io
import json
import math
import statistics
from pathlib import Path


def read(path):
    data = path.read_bytes()
    return data.decode("utf-16" if data[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8-sig")


def median(values):
    values = list(values)
    return round(statistics.median(values), 3) if all(math.isfinite(v) for v in values) else None


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
result = {"transport": {}, "playback": {}, "notes": [
    "Fresh volume per transport/round; OS caches not cleared.",
    "Transport release benchmark: no decode/render; timed transfers exclude SHA-256.",
    "Warm = after verification read, not necessarily cache-resident (32 MiB exceeds 16 MiB cache).",
    "Playback Flutter Debug with release Rust/native libraries; 5 ms polling; first frame includes player initialization.",
    "seek_restart is libmpv PLAYBACK_RESTART latency, not a measured screen presentation timestamp.",
    "worker_read_bytes is logical file data returned by the worker, NOT physical SSD/source bytes.",
    "cpu_ms is whole-process Windows CPU, quantized; no stable CPU improvement claim.",
]}
for name in ["bitlocker-avi.csv", "plain-32m.csv"]:
    rows = list(csv.DictReader(io.StringIO(read(args.directory / name))))
    result["transport"][name] = {}
    for phase in ["fresh_volume", "warm"]:
        result["transport"][name][phase] = {}
        for transport in ["http", "native"]:
            group = [r for r in rows if r["phase"] == phase and r["transport"] == transport]
            assert group, (name, phase, transport)
            result["transport"][name][phase][transport] = {
                "trials": len(group),
                **{key: median(float(r[key]) for r in group) for key in
                   ["ms", "cpu_ms", "mib_per_second", "worker_calls", "worker_bytes", "worker_ns"]},
            }
log = read(args.directory / "playback.log")
assert "All tests passed!" in log, "Playback test did not complete successfully"
rows = [json.loads(line.split("MEDIA_TRANSPORT ", 1)[1]) for line in log.splitlines()
        if "MEDIA_TRANSPORT {" in line]
assert rows, "No playback measurements"
for filename in dict.fromkeys(r["file"] for r in rows):
    result["playback"][filename] = {}
    for transport in ["http", "native"]:
        group = [r for r in rows if r["file"] == filename and r["transport"] == transport]
        assert group
        result["playback"][filename][transport] = {
            "trials": len(group),
            **{key.replace("_us", "_ms"): median(r[key] / 1000 for r in group)
               for key in ["open_us", "first_frame_us", "close_us"]},
            "seek_restart_ms": median(value / 1000 for r in group for value in r["seek_restart_us"]),
            "cpu_ms": median(r["cpu_ms"] for r in group) if all(r["cpu_ms"] is not None for r in group) else None,
            "worker_read_bytes": median(r["after_seek"]["worker_read_bytes"] for r in group),
        }
result["playback_trials"] = rows
args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print(args.output)
