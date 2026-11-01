---
type: "research"
status: "active"
module: "pilot-feedback-trim"
area: "flight"
updated: "2026-11-02"
summary: "PFT-1: скрипты и данные замера трима на нейтрали и фугоиды после X (Godot headless)."
related: ["docs/research/pilot-feedback-trim/longitudinal.md"]
---
# PFT-1: продольный канал «Маятника» — трим на нейтрали и фугоида после X

Записка с выводами — `docs/research/pilot-feedback-trim/longitudinal.md`; итог по контракту PFT-К2 —
`tools/research/pilot-feedback-trim/out/PFT-1_verdict.json`. Код игры, конфиги и тесты не менялись.

## Что внутри
- `trim_batch.gd` / `.tscn` — headless-сцена: модель `PendulumModel` напрямую (как её создаёт `Glider.setup`: масса пилота
  `pilot.json` 85 кг, зажатая в диапазон крыла, или эталонная масса крыла `--mass=ref`), штиль, `step(1/120)`.
  Режимы: `steady` (ввод 0, `arms_relaxed` — «брошенная ручка», сдвиг подвески), `launch` (разбег по склону и отрыв),
  `xtest` (установившийся режим → X / мгновенная / плавная отдача).
- `run.sh` — обёртка запуска (профиль `XDG_DATA_HOME` по имени копии), `versions.sh` — прогон по тегам,
  `run_all.sh` — основной пакет; `analyze_x.py`, `analyze_launch.py`, `analyze_versions.py`, `table_steady.py` — разбор.
- `out/` — сырьё `*.json.gz` (ряды V, θ, γ, α, крена; ≈ 5 МБ), `*_an.json` и `*_table.txt` — разбор и итоговые таблицы; `versions/` — по тегам.

## Воспроизведение (из корня копии, `XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD")`, первый запуск — `godot --headless --path . --import`)
```
L=tools/research/pilot-feedback-trim/longitudinal
W=$(cat $L/out/wings_all.txt)      # topless + kingpost + trainer + soviet из configs/wings/*.json (поле group)
# (а) установившийся режим, плотность постоянная 1,225; масса игры (85 кг) и эталонная
for ms in game ref; do .dpcli/dpcli lock cpu pft1 -- $L/run.sh --mode=steady --wings=$W --hold=60 --shift=1,2,3,4 --mass=$ms --out=$L/out/steady_$ms.json; done
#   то же на высоте 1000 м (плотность по высоте): --alt=1  (файлы *_alt1000.json)
python3 $L/table_steady.py
# (б) разбег и отрыв
.dpcli/dpcli lock cpu pft1 -- $L/run.sh --mode=launch --wings=sport,moyes_litespeed_rx,ww_t2c,apogee,training --slope=12,17 --out=$L/out/launch_head.json
python3 $L/analyze_launch.py $L/out/launch_head.json
# (в) X: полный ход, частичный (q-0.2…), вираж 30°; постоянная X (X0.2…X4); без отпускания рук (--release_event=0)
.dpcli/dpcli lock cpu pft1 -- $L/run.sh --mode=xtest --wings=sport,moyes_litespeed_rx,ww_t2c,apogee,training --hold=60 --after=90 --out=$L/out/x_head.json
.dpcli/dpcli lock cpu pft1 -- $L/run.sh --mode=xtest --wings=... --kinds=q-0.2,q-0.4,q0.2,q0.4 --hows=X,instant --out=$L/out/x_part.json
python3 $L/analyze_x.py $L/out/x_part.json $L/out/x_part_an.json
# версии: git worktree add --detach ~/worktrees/deltaplan/pft1-<тег> <тег>; скопировать trim_batch.gd/.tscn и run.sh в тот же
# путь внутри worktree; затем
$L/versions.sh $L/out/versions v1.5.15 v1.5.20 v1.5.21 v1.6.0 v1.7.0 ; python3 $L/analyze_versions.py
git worktree remove ~/worktrees/deltaplan/pft1-<тег>
```
Данные — только собственные расчёты модели; лицензии внешних данных нет. Паспорта крыльев — `configs/wings/*.json` (источники в их `_doc`).
Дальше — см. `docs/research/pilot-feedback-trim/longitudinal.md`.
