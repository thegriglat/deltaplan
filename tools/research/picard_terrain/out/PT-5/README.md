---
type: "research"
status: "closed"
module: "picard-terrain"
updated: "2026-11-09"
summary: "PT-5: воспроизведение замера ротора Perdigão и мачт."
conclusion: "см. текст"
data: "tools/research/picard_terrain/out/"
applied_in: ""
---
# PT-5: ротор Perdigão и мачты

Воспроизведение (из корня копии, поля R4 — `~/data/picard_terrain/states`, готовы PT-1..3):

    tools/research/sw_charges_3d/py tools/research/picard_terrain/rotor.py     # ~1 мин, CPU; -> rows.jsonl, rotor.json, table.md
    python3 tools/research/picard_terrain/contract/check_contract.py rows tools/research/picard_terrain/out/PT-5/rows.jsonl

Критерий, разрезы, правила выборки, допущения — в докстринге `rotor.py`. Данные: SWD1 `points.json` (мачты ISFS NCAR/EOL, doi:10.26023/ZDMJ-D1TY-FG14),
Menke et al. 2019 (ACP 19, 2713; `tools/research/data/perdigao/menke2019/fig8_zones_approx.csv`, оцифровка ±50 м), рельеф GLO-30 (лицензии — ASSETS.md).
Сочетания cut+adv2 (после PT-4): появятся состояния `perdigao_*_d30_cut_adv2_l{1,3}` и строки PT-4 в out/PT-4/rows.jsonl — перезапуск скрипта добавит их.
