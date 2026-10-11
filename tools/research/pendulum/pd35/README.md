---
type: "research"
status: "active"
module: "pendulum"
updated: "2026-10-11"
summary: "PD-35: посадка маятника — ход рук у земли по досягаемости, касание «встал на ноги / пробежал / жёстко», C_N 90° полос × cos²Λ, центр давления в обратном потоке; скрипты пачек и замеров."
related: ["docs/research/pendulum.md", "tools/research/pendulum/README.md"]
conclusion: "Правильная посадка в штиль жёсткая (гор. 5,9–7,2 м/с > 5), во встречный 3 м/с мягкая (3–4 шага); C_N 90° крыла 1,54–1,62 → 1,21–1,26; полёт как в 1.5.5, болтанка sport 0/66, --dive-all 0/48; точный угол полосы выключен (плоский штопор учебного)."
data: "tools/research/pendulum/out/pd19_pd35*.jsonl"
applied_in: "docs/research/pendulum.md"
---
# PD-35: посадка «Маятника»

Разбор — `docs/research/pendulum.md` → «Посадка (PD-35)».

| Файл | Что |
|---|---|
| `cn_static.py` | статика C_N, C_L, C_D крыла прототипа по α 20…90° |
| `gt.sh` | тесты godot в копии: `gt.sh <фильтр> [K=V …]` (временный профиль, MemoryMax 12G) |
| `early.sh` | ранняя отдача (2 м) по вариантам физики |
| `feel.sh`, `feel_table.py`, `feel_table.md` | отклик в полёте до/после (`test_pendulum_flight_feel`, `PD35_FEEL=1`), таблица и её итог |
| `spin.sh` | штопор по вариантам (какая правка) |
| `ref.sh` | пересчёт эталона прототипа (`export_reference.py`, полный и `--ground`) |
| `seq.sh` | отклик, посадка, посадка с трима, штопор — по одному godot |

Варианты физики «до PD-35» в тестах маятника — переменные окружения (`pendulum_sim.gd → pd35_env`): `PD35_SWEEPNORM=0`, `PD35_CPREV=0`, `PD35_ALPHAEXACT=1` (точный угол). Болтанка и `--dive-all`:
```
PY=/home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python
$PY tools/research/pendulum/pd19_batch.py plan pd35b '[{"name":"pd35b","strips":{"stall_cp_reverse":true}}]' --sc turb,dive,dive_all
$PY tools/research/pendulum/pd19_batch.py run pd35b && $PY tools/research/pendulum/pd19_batch.py sum pd35b
```
«До» (1.5.5) — вариант `{"stall_cp_reverse":false,"cd90_sweep_norm":false,"sweep_alpha_exact":false}` (`pd19_pd35.jsonl`, вариант `pre`).
