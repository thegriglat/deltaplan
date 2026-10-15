---
type: "research"
status: "active"
module: "speed-feel"
area: "flight"
updated: "2026-10-15"
summary: "SPF-1: скрипты и таблицы замеров болтанки, тангажа киля, частот ленты и тросов; команды воспроизведения"
related: ["docs/research/speed-feel.md"]
conclusion: "Итог и выводы — docs/research/speed-feel.md; здесь только код, данные и команды воспроизведения."
data: "out/jitter.json, out/jitter_ratio.csv, out/theta_view.json, out/flutter_wires.json"
applied_in: "SPF-2, SPF-3, SPF-4, SPF-5"
---
# SPF-1: числа и источники для ощущения скорости

Итог — `docs/research/speed-feel.md`. Код и данные здесь. Только чтение игры (ничего не меняет).

## Воспроизведение (из корня копии, godot 4.7.2, python3 stdlib)

```
export XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD")
godot --headless --path . --import          # один раз в копии
# п.1 и п.2: штиль + порывы GustSpectrum (≈ 7 мин, headless, один процесс)
godot --headless --path . res://tools/research/speed-feel/jitter_theta.tscn -- --out=$PWD/tools/research/speed-feel/out/jitter.json
python3 tools/research/speed-feel/analyze_jitter.py     # out/jitter_ratio.csv
python3 tools/research/speed-feel/theta_view.py --json tools/research/speed-feel/out/theta_view.json
# п.3 и п.4: частоты ленты и тросов
python3 tools/research/speed-feel/flutter_wires.py --json tools/research/speed-feel/out/flutter_wires.json
```

Параметры замера (`jitter_theta.gd`): σ_u = σ_w = 1 м/с, L = 30/100/300 м, 5 сидов (11…55), разгон 40 с + 200 с, шаг 1/120 с, крылья `training` (по умолчанию) и `sport`, плотность постоянная.

## Файлы
- `out/jitter.json` — штиль (`calm`: θ, γ, α, снижение) и порывы (`gust`: jitter по сидам, V, n_min/n_max).
- `out/jitter_ratio.csv`, `out/theta_view.json`, `out/flutter_wires.json` — таблицы документа.

## Источники и лицензии
Данные — только собственные замеры модели и числа из опубликованных работ (ссылки в документе, тексты и PDF не хранятся). Паспорта крыльев (диаметры тросов) — из `tools/research/data/wing_passports/` (Wills Wing T2/T2C Manual, Bautek Fizz; публичные руководства производителей, числа и URL). Новых файлов в `ASSETS.md` нет.
