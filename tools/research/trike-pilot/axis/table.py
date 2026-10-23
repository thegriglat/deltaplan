"""TP-26: сводная таблица осей из логов run_axis.sh (build/research/trike-pilot/axis). Запуск из корня копии."""
import glob, re, sys
d = sys.argv[1] if len(sys.argv) > 1 else "build/research/trike-pilot/axis"
print("ось_м | связка v км/ч | набор м/с | разбег м | Tmax даН | игрок: упор v км/ч / vz | фугоида k | период с | горизонт газ/v км/ч")
for a in sorted({re.search(r"axis_([\d.]+)_", f).group(1) for f in glob.glob(d + "/axis_*_*.log")}):
    c = open(f"{d}/axis_{a}_tow_trike_climb.log").read()
    k = open(f"{d}/axis_{a}_trike_pilot_k6.log").read()
    m = re.search(r"climb_ms=([\d.]+) speed_kmh=([\d.]+) liftoff_m=(\d+) tmax_dan=([\d.]+)", c)
    u = re.search(r"штанга на упоре, полный газ: v [\d.]+ м/с \((\d+) км/ч\), vz ([\d.-]+)", k)
    p = re.search(r"отношение за период ([\d.]+), период ([\d.]+)", k)
    h = re.search(r"горизонтальный полёт: газ ([\d.]+), v [\d.]+ м/с \((\d+) км/ч\)", k)
    print(f"{a} | {m.group(2)} | {m.group(1)} | {m.group(3)} | {m.group(4)} | {u.group(1)} / {u.group(2)} | {p.group(1)} | {p.group(2)} | {h.group(1)}/{h.group(2)}")
