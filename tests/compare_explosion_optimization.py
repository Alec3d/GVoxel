"""Alternate before/after CPU profiles in fresh installed LuaJIT processes."""
import argparse
import hashlib
from pathlib import Path
import re
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--baseline", type=Path,
                    default=ROOT.parent.parent / "gvoxel_before_explosion_optimization_20261027.zip")
parser.add_argument("--runs", type=int, default=3)
parser.add_argument("--report", type=Path)
args = parser.parse_args()
if args.runs < 1 or not args.baseline.is_file():
    parser.error("A saved baseline and at least one run are required")

pattern = re.compile(r"TANK (rpg_impact|tank_rpg_impact) r\d+:.*total ([\d.]+) ms")
samples = {version: {case: [] for case in ("rpg_impact", "tank_rpg_impact")}
           for version in ("before", "after")}
logs = []
for run in range(args.runs):
    order = ("before", "after") if run % 2 == 0 else ("after", "before")
    for version in order:
        command = [sys.executable, str(ROOT / "tests/run_tank_profile.py"), "--explosions-only"]
        if version == "before":
            command += ["--geometry", str(args.baseline.resolve())]
        output = subprocess.check_output(command, text=True, encoding="utf-8")
        results = pattern.findall(output)
        if len(results) != 2:
            raise RuntimeError("Incomplete explosion profile:\n" + output)
        for case, elapsed in results:
            samples[version][case].append(float(elapsed))
        logs.append(f"RUN {run + 1} {version}\n{output}")

lines = ["CPU ONLY: float Vector adapters; no engine scheduling, native cooks, GPU, network or FPS.",
         "Each process reports the median last 3 of 5 trials; alternating fresh processes.",
         "Baseline SHA256 " + hashlib.sha256(args.baseline.read_bytes()).hexdigest()]
for module in ("sh_bsp_geometry", "sh_field", "sh_collision", "sh_crater"):
    path = ROOT / f"lua/gvoxel/{module}.lua"
    lines.append(module + " SHA256 " + hashlib.sha256(path.read_bytes()).hexdigest())
for case in samples["before"]:
    before = statistics.median(samples["before"][case])
    after = statistics.median(samples["after"][case])
    lines.append(f"{case}: before={samples['before'][case]}; after={samples['after'][case]}; "
                 f"median {before:.2f} -> {after:.2f} ms CPU; reduction {(1 - after / before) * 100:.1f}%")
summary = "\n".join(lines)
print(summary, flush=True)
if args.report:
    args.report.write_text(summary + "\n\n" + "\n".join(logs), encoding="utf-8")
