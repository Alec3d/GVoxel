"""Sequential before/after CPU comparison; never launches or controls GMod."""
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
OUTPUT = ROOT / "tests" / "fast-holes-20261026"
OUTPUT.mkdir(exist_ok=True)
results = {"before": [], "after": []}
pattern = re.compile(r"HOLE (\w+) r(\d+): brush ([\d.]+); collision ([\d.]+); mesh ([\d.]+); native input ([\d.]+) ms; (\d+) chunks / (\d+) triangles / (\d+) cooks")
with tempfile.TemporaryDirectory(prefix="vm_holes_", dir=OUTPUT) as directory:
    temporary = Path(directory).resolve()
    assert temporary.is_relative_to(OUTPUT.resolve()) and temporary.name.startswith("vm_holes_")
    baseline = temporary / "gvoxel"
    with zipfile.ZipFile(ROOT.parent.parent / "gvoxel_before_fast_holes_20261026.zip") as archive:
        for entry in archive.infolist():
            name = Path(entry.filename)
            if not entry.is_dir() and name.parts[0] == "lua":
                target = (baseline / name).resolve()
                assert target.is_relative_to(baseline / "lua")
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(entry))
    assert (baseline / "lua/gvoxel/sh_field.lua").exists()
    tests = baseline / "tests"
    tests.mkdir()
    for name in ("field_spec.lua", "float_vectors.lua", "bsp_spec.lua", "profile_holes.lua"):
        (tests / name).write_bytes((ROOT / "tests" / name).read_bytes())
    fixture = Path("native-20261026/foreground_native_region_fixture.json")
    (tests / fixture).parent.mkdir()
    (tests / fixture).write_bytes((ROOT / "tests" / fixture).read_bytes())
    runner = (ROOT / "tests/run_tests.py").read_text(encoding="utf-8")
    runner = runner.replace("GAME = ROOT.parent.parent.parent.parent", f"GAME = Path({str(GAME)!r})")
    (tests / "run_tests.py").write_text(runner, encoding="utf-8")
    for run in range(1, 4):
        for variant in (("before", "after") if run % 2 else ("after", "before")):
            source = baseline if variant == "before" else ROOT
            process = subprocess.run([sys.executable, str(source / "tests/run_tests.py"), "--profile-holes"],
                                     check=True, capture_output=True, text=True)
            (OUTPUT / f"{variant}-{run}.txt").write_text(process.stdout, encoding="utf-8")
            rows = {}
            for scene, radius, *values in pattern.findall(process.stdout):
                rows[f"{scene} r{radius}"] = dict(zip(("brush", "collision", "mesh", "native_input", "chunks", "triangles", "cooks"), map(float, values)))
            assert len(rows) == 9
            signatures = [line for line in process.stdout.splitlines() if line.startswith("SIGNATURE HOLE")]
            assert len(signatures) == 9
            warm = {scene: {"cpu_ms": float(cpu), "lua_kib": float(heap)} for scene, cpu, heap in
                    re.findall(r"WARM HOLES (\w+): ([\d.]+) ms CPU; ([\d.]+) KiB", process.stdout)}
            results[variant].append({"phases": rows, "signatures": signatures, "warm": warm})
            print(f"Completed {variant} {run}/3", flush=True)
signatures = results["before"][0]["signatures"]
assert all(row["signatures"] == signatures for runs in results.values() for row in runs), "collision/triangle signatures changed"
summary = {}
for variant, runs in results.items():
    summary[variant] = {scene: {phase: statistics.median(run["phases"][scene][phase] for run in runs)
                              for phase in runs[0]["phases"][scene]} for scene in runs[0]["phases"]}
report = {"scope": "Float Vector/LuaJIT CPU adapters; no native latency or FPS measurement", "runs": results,
          "median_ms": summary, "signatures_identical": True}
(OUTPUT / "comparison.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
print(json.dumps(summary, indent=2))
print("PASS: nine triangle/hull signatures identical across six processes")
