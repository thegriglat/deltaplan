"""Б2: цена на сетках игры до/после — из логов bench.sh (метки base и b2) → out/cost.md.

    python3 tools/research/b2/cost.py [метка_до] [метка_после]
"""
import re
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parent / "out"
B = OUT / "bench"


def text(p):
    return p.read_text(errors="replace") if p.exists() else ""


def bench_rows(tag, dx, q):
    """{(ветер, режим): (итерации, эталон, стена с, GPU с, мс/итер)} и мс на итерацию (полная / без θ′_d)."""
    rows, it = {}, {}
    for ln in text(B / f"{tag}_bench{dx}_q{q}.log").splitlines():
        m = re.match(r"^\s*(\d+) м/с \| ([^|]+?) \| ([^|]+?) \| ([\d.]+) \| ([\d.]+) \| ([\d.]+) \|", ln)
        if m:
            rows[(int(m[1]), m[2].strip())] = (m[3].strip(), float(m[4]), float(m[5]), float(m[6]))
        m = re.search(r"итерация целиком ([\d.]+) мс", ln)
        if m:
            it["full"] = float(m[1])
        m = re.search(r"итерация без θ′_d \(решение без нагрева\) ([\d.]+) мс", ln)
        if m:
            it["mech"] = float(m[1])
        m = re.search(r"Онгудай 400 м, 3 м/с: (.*)", ln)
        if m:
            it["warm"] = m[1].strip()
    return rows, it


def runtime_lines(tag):
    keys = ("air_model: поле", "AirRuntime, загрузка с окнами", "— загрузка: итераций", "сдвиг (тёплый)",
            "пересчёт", "окно 100 м, ", "окно 50 м, ", "тестов,")
    out = []
    for ln in text(B / f"{tag}_gpu_tests.log").splitlines():
        if any(k in ln for k in keys) and not ln.startswith("ERROR"):
            out.append(ln.strip())
    return out


def main():
    a, b = (sys.argv[1:3] + ["base", "b2"][len(sys.argv[1:3]):])[:2]
    md = [f"# Б2: цена на сетках игры, {a} → {b}", "",
          "Bench `test_air_picard_bench` (AIR_PICARD_BENCH=1; QUICK=1 — только 3 м/с; полный — 0/3/6 м/с, пара, загрузка).",
          "Итерации детерминированы; стена и GPU — шумные (посторонний процесс на GPU возможен).", ""]
    for dx in (400, 200):
        for q in (1, 0):
            ra, ia = bench_rows(a, dx, q)
            rb, ib = bench_rows(b, dx, q)
            md += [f"## {dx} м, {'QUICK' if q else 'полный'}", "",
                   f"Итерация: {ia.get('full', '—')} → {ib.get('full', '—')} мс; без θ′_d {ia.get('mech', '—')} → "
                   f"{ib.get('mech', '—')} мс", "",
                   "| ветер | режим | итераций (эталон f32) | стена, с | GPU, с | мс/итер |", "|---|---|---|---|---|---|"]
            for k in sorted(set(ra) | set(rb)):
                x, y = ra.get(k), rb.get(k)
                f = lambda r, i: "—" if r is None else str(r[i])
                md.append(f"| {k[0]} м/с | {k[1]} | {f(x, 0)} → {f(y, 0)} | {f(x, 1)} → {f(y, 1)} | {f(x, 2)} → {f(y, 2)} "
                          f"| {f(x, 3)} → {f(y, 3)} |")
            if "warm" in ia or "warm" in ib:
                md += ["", f"Тёплый старт: {ia.get('warm', '—')}", "", f"→ {ib.get('warm', '—')}"]
            md.append("")
    for tag in (a, b):
        md += [f"## GPU-тесты test_air_ ({tag}): AirRuntime и окна", "", "```"] + runtime_lines(tag) + ["```", ""]
    (OUT / "cost.md").write_text("\n".join(md) + "\n")
    print("\n".join(md))


if __name__ == "__main__":
    main()
