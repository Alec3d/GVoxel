"""Compare option A with the saved pre-change Lua sources, without running GMod."""
import argparse
import json
from pathlib import Path
import re
import statistics
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
GAME = ROOT.parent.parent.parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--baseline", type=Path, default=ROOT.parent.parent / "gvoxel_before_option_a_20261026.zip")
parser.add_argument("--runs", type=int, default=3)
args = parser.parse_args()
if not 1 <= args.runs <= 10:
    parser.error("--runs must be between 1 and 10")
output = ROOT / "tests" / "option-a-20261026"
output.mkdir(exist_ok=True)
pattern = re.compile(r"PROFILE A (.+): ([\d.]+) ms CPU; (\d+) Vector allocations")
results = {"baseline": [], "option_a": []}

with tempfile.TemporaryDirectory(prefix="vm_option_a_", dir=output) as directory:
    # Validate the exact cleanup root before TemporaryDirectory removes it.
    temporary = Path(directory).resolve()
    assert temporary.is_relative_to(output.resolve())
    assert temporary.name.startswith("vm_option_a_")
    baseline = temporary / "gvoxel"
    with zipfile.ZipFile(args.baseline) as archive:
        for entry in archive.infolist():
            name = Path(entry.filename)
            if not entry.is_dir() and name.parts[:2] == ("gvoxel", "lua"):
                target = (temporary / name).resolve()
                assert target.is_relative_to(baseline / "lua")
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(entry))
    tests = baseline / "tests"
    tests.mkdir(exist_ok=True)
    for name in ("field_spec.lua", "float_vectors.lua", "bsp_spec.lua", "profile_option_a.lua"):
        (tests / name).write_bytes((ROOT / "tests" / name).read_bytes())
    fixture = Path("native-20261026/foreground_native_region_fixture.json")
    (tests / fixture).parent.mkdir(exist_ok=True)
    (tests / fixture).write_bytes((ROOT / "tests" / fixture).read_bytes())
    runner = (ROOT / "tests" / "run_tests.py").read_text(encoding="utf-8")
    runner = runner.replace("GAME = ROOT.parent.parent.parent.parent", f"GAME = Path({str(GAME)!r})")
    (tests / "run_tests.py").write_text(runner, encoding="utf-8")
    for number in range(1, args.runs + 1):
        order = ("baseline", "option_a") if number % 2 else ("option_a", "baseline")
        for variant in order:
            source = baseline if variant == "baseline" else ROOT
            process = subprocess.run(
                [sys.executable, str(source / "tests" / "run_tests.py"), "--profile-option-a"],
                check=True, text=True, capture_output=True,
            )
            (output / f"{variant}-{number}.txt").write_text(process.stdout, encoding="utf-8")
            phases = {label: {"cpu_ms": float(cpu), "vectors": int(vectors)}
                      for label, cpu, vectors in pattern.findall(process.stdout)}
            assert len(phases) == 17, "incomplete profile"
            signatures = [line for line in process.stdout.splitlines() if line.startswith("SIGNATURE A")]
            assert len(signatures) == 4
            heap = float(re.search(r"HEAP A prepared: ([\d.]+)", process.stdout)[1])
            results[variant].append({"phases": phases, "signatures": signatures, "prepared_lua_kib": heap})
            print(f"Finished {variant} {number}/{args.runs}", flush=True)

signature = results["baseline"][0]["signatures"]
for runs in results.values():
    assert all(run["signatures"] == signature for run in runs), "geometry/normal/hull signatures changed"
summary = {}
for variant, runs in results.items():
    summary[variant] = {
        "edit_cpu_ms": statistics.median(sum(p["cpu_ms"] for name, p in run["phases"].items()
                                            if name != "initial preparation") for run in runs),
        "edit_vectors": statistics.median(sum(p["vectors"] for name, p in run["phases"].items()
                                             if name != "initial preparation") for run in runs),
        "prepared_lua_kib": statistics.median(run["prepared_lua_kib"] for run in runs),
    }
report = {"scope": "LuaJIT float adapter on real saved gm_construct scan; no game/FPS measurement",
          "runs": results, "median": summary, "signatures_identical": True}
(output / "comparison.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
print(json.dumps(summary, indent=2))
print("PASS: all four geometry, normal and swept-hull signatures identical across variants/runs")
