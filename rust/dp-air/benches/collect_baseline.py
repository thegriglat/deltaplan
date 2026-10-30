#!/usr/bin/env python3
"""Собирает медианы criterion (rust/target/criterion) в baseline.json, мкс.
Запуск после `cargo bench -p dp-air` из корня репозитория:
    benches/collect_baseline.py Formula   # бенчи formula.rs (имена formula_*)
    benches/collect_baseline.py Calm      # бенчи calm.rs (остальные имена)
Модель — аргумент (по умолчанию Formula); ключи других моделей в файле сохраняются."""
import json, platform, datetime, pathlib, sys

model = sys.argv[1] if len(sys.argv) > 1 else "Formula"
if model not in ("Formula", "Calm"):
    sys.exit("модель: Formula | Calm")
root = pathlib.Path(__file__).resolve().parents[2] / "target" / "criterion"
res = {}
for est in sorted(root.glob("*/new/estimates.json")):
    name = est.parent.parent.name
    if name.startswith("formula_") != (model == "Formula"):
        continue
    d = json.loads(est.read_text())
    res[name] = round(d["median"]["point_estimate"] / 1000.0, 6)  # нс -> мкс
if not res:
    sys.exit("нет результатов criterion для %s в %s" % (model, root))
cpu = "?"
try:
    cpu = next(l.split(":", 1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name"))
except Exception:
    pass
p = pathlib.Path(__file__).with_name("baseline.json")
old = json.loads(p.read_text()) if p.exists() else {}
models = old.get("models")
if models is None:  # прежний формат (RW-4): одна модель на верхнем уровне
    models = {}
    if "median_us" in old:
        models[old.get("model", "Calm")] = {
            "date": old.get("date"),
            "machine": old.get("machine"),
            "median_us": old["median_us"],
        }
models[model] = {
    "date": datetime.date.today().isoformat(),
    "machine": {"cpu": cpu, "platform": platform.platform()},
    "median_us": res,
}
out = {
    "unit": "us",
    "stat": "median",
    "profile": "release",
    "thresholds_us": {"sample_many_18": 50, "sample_many_1000": 2000, "advance_to": 500},
    "models": dict(sorted(models.items())),
}
p.write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n")
print(p)
