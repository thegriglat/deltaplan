---
type: research
module: pilot-handling
status: active
updated: "2026-11-04"
conclusion: "см. docs/research/pilot-handling/lateral-x.md"
data: "tools/research/pilot-handling/lateral_x/out/"
applied_in: []
summary: "PHD-2: боковой отклик после X в игре (headless) и чувствительность к Cnp в прототипе; скрипты и данные."
---
# PHD-2: боковая раскачка после X

Записка — `docs/research/pilot-handling/lateral-x.md`. Вердикт — `tools/research/pilot-handling/out/PHD-2_verdict.json` (PHD-К2).

## Файлы
- `lateral_batch.gd/.tscn`, `run.sh` — игровая модель (`PendulumModel`, без изменений кода): состояния T30/T45 (установившийся вираж регулятором крена),
  S1 (короткий боковой ввод 0,6), T30P (вираж 30° + «на себя» −0,4), S0 (прямой, толчок по рысканию 0,15 рад/с или по крену 0,3 рад/с);
  сценарии H (держать), A (X как в игре), A2 (экспонента τ 0,2 с), B05/B1/B2 (линейный возврат 0,5/1/2 с), C (руки отпущены), KR/KRC/KP/KPC (толчок, руки держат/отпущены).
  Выход `out/game_<крыло>.json` (ряд 20 Гц: φ, β, p, r, ψ̇, положение пилота, ввод, V, θ).
- `analyze.py` — метрики и Прони (вычитание полинома 3-й степени, чтобы отделить быстрые моды от спирали) → `out/game_metrics.json`, `out/game_table.md`, `out/game_fast.md` (`python3 analyze.py fast`).
- `summarize.py` — моды для вердикта → `out/summary_modes_game.json`.
- `proto_cnp.py` — прототип GameSim (`tools/research/pendulum/pd21_lateral.py`, ProbeSim): `run` (Cnp 0 / +0,0568 / −0,068 против базы), `linear` и `stab` (линейная 5-состояний модель, пересчёт осей) → `out/proto_cnp.jsonl`, `out/linear_axes.json`, `out/stab_axes.json`.
- `verdict.py` — сборка `PHD-2_verdict.json` из out/*.

## Воспроизведение
```
.dpcli/dpcli lock cpu import -- godot --headless --path . --import      # один раз; libdp_air_tune.so скопировать из копии модуля
for w in training laminar sport icaro_mastr; do
  .dpcli/dpcli job --lock cpu start phd2-$w 3000 tools/research/pilot-handling/lateral_x/run.sh --wings=$w --out=tools/research/pilot-handling/lateral_x/out/game_$w.json
done
python3 tools/research/pilot-handling/lateral_x/analyze.py > tools/research/pilot-handling/lateral_x/out/game_table.md
python3 tools/research/pilot-handling/lateral_x/analyze.py fast > tools/research/pilot-handling/lateral_x/out/game_fast.md
python3 tools/research/pilot-handling/lateral_x/summarize.py
.dpcli/dpcli job --lock cpu start phd2-proto 3000 python3 tools/research/pilot-handling/lateral_x/proto_cnp.py run --out tools/research/pilot-handling/lateral_x/out/proto_cnp.jsonl --jobs 6
python3 tools/research/pilot-handling/lateral_x/proto_cnp.py linear --out tools/research/pilot-handling/lateral_x/out/linear_axes.json
python3 tools/research/pilot-handling/lateral_x/proto_cnp.py stab --out tools/research/pilot-handling/lateral_x/out/stab_axes.json
python3 tools/research/pilot-handling/lateral_x/verdict.py
```
Python — системный `python3` с numpy 2.2 (venv heat_ca в этой машине отсутствует). Сырые `out/game_*.json` (≈2 МБ каждый, всего ≈8 МБ) коммитятся.

## Источники и лицензии данных
Входных внешних данных нет. Литература — ссылки в записке и в `docs/research/pendulum-yaw-literature.md` (числа Kochi 2020 / Cook & Spottiswoode 2005 —
открытый доступ, цитируются как числа, файлы не копируются).
