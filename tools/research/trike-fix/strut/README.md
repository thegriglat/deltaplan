---
type: "research"
status: "active"
module: "trike-fix"
area: "flight"
updated: "2026-11-02"
summary: "TKF-9: воспроизведение замера и расчёта штанги у подкоса"
related: ["docs/research/trike-fix/strut.md"]
---
# TKF-9: штанга на триме и на упоре
Воспроизведение (из корня копии; Rust-расширение собрано `tools/build_rust.sh tune linux`, `godot --headless --path . --import`):
```
godot --headless --path . res://tools/research/trike-fix/strut/speed_bar_run.tscn -- --out=tools/research/trike-fix/strut/out/speed_bar.json   # скорость <-> bar_deg_phys, газ 0/1, ввод -1..+1 (ход «на себя» 0,25)
godot --headless --path . res://tools/research/trike-fix/strut/speed_bar_cm.tscn -- --out=...   # то же с видом при ЦМ за подвеской (+0,13), тангаж тележки; вывод строки SPEED_BAR берётся из лога, файлы speed_bar_cm.json / pitch_cm.json
python3 tools/research/trike-fix/strut/geometry.py          # окно хода штанги в треугольнике (TT-К6): -8,40...+4,95 град
python3 tools/research/trike-fix/strut/check_proposal.py    # зазоры для вариантов хода «на себя», out/proposal.json
```
Источники и вывод - `docs/research/trike-fix/strut.md`. Лицензии данных: внешние файлы не загружались (только числа из публичных паспортов BMAA HADS, P&M manuals, форумов; тексты не копировались); ASSETS.md не менялся.
