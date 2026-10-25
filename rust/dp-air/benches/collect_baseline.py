#!/usr/bin/env python3
"""Собирает медианы criterion (rust/target/criterion) в baseline.json, мкс.
Запуск после `cargo bench -p dp-air` из корня репозитория."""
import json, platform, datetime, pathlib, sys

root = pathlib.Path(__file__).resolve().parents[2] / "target" / "criterion"
res = {}
for est in sorted(root.glob("*/new/estimates.json")):
    d = json.loads(est.read_text())
    res[est.parent.parent.name] = round(d["median"]["point_estimate"] / 1000.0, 6)  # нс -> мкс
if not res:
    sys.exit("нет результатов criterion в " + str(root))
cpu = "?"
try:
    cpu = next(l.split(":", 1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name"))
except Exception:
    pass
out = {
    "unit": "us",
    "stat": "median",
    "model": "Calm",
    "profile": "release",
    "date": datetime.date.today().isoformat(),
    "machine": {"cpu": cpu, "platform": platform.platform()},
    "median_us": res,
}
p = pathlib.Path(__file__).with_name("baseline.json")
p.write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n")
print(p)
