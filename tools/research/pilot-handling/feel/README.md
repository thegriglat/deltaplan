---
type: research
status: active
module: pilot-handling
summary: "Команды воспроизведения замеров «надувного» отклика (PHD-3)"
updated: 2026-11-04
---
# PHD-3: «надувной» отклик
Из корня копии (≈ 6 мин CPU на 4 крыла, потом ≈ 1 мин на cmdlp). Нужен `addons/dp_air/bin/libdp_air_tune.so` (в .gitignore; скопировать из основной копии) и `godot --headless --path . --import`.
```
export XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD")
.dpcli/dpcli lock cpu phd3 -- godot --headless --path . res://tools/research/pilot-handling/feel/feel.tscn -- --part=all --out=tools/research/pilot-handling/feel/feel.json
.dpcli/dpcli lock cpu phd3 -- godot --headless --path . res://tools/research/pilot-handling/feel/feel.tscn -- --part=cmdlp --wings=training,laminar,sport --out=tools/research/pilot-handling/feel/cmdlp.json
python3 tools/research/pilot-handling/feel/analyze.py   # summary.json, analysis.txt
```
Части (`--part=`): inertia, deriv, chain, swing, freq, cmdlp. Вывод — `docs/research/pilot-handling/feel.md`, вердикт — `tools/research/pilot-handling/out/PHD-3_verdict.json`.
Данные игры — только конфиги репозитория. Источники (веб): ICAS 2022-0135 (Takamatsu & Ochi) — только текст для сверки, не копировался; прочие — по ссылкам в записке; лицензии данных не требуются.
