---
type: "research"
status: "active"
module: "sea-ships"
area: "world"
updated: "2026-10-17"
summary: "SEA-12: цена кадра GPU слоя судов (опыт noships) на учебном острове и ongudai, medium и high; base ветки против base main."
related: ["docs/contracts/grass-rocks.md", "docs/contracts/sea-ships.md", "docs/plan/sea-ships.md"]
---
# Цена GPU судов и моря: замер SEA-12

## Протокол

G3 v2 (`docs/contracts/grass-rocks.md`): RTX 4070 SUPER, `DISPLAY=:0`, 1920×1080 полноэкранно, под замком GPU, пресеты medium и high, отметки `2:cockpit 30:chase 60:chase`, `--keep=nocloudfx`, опыты `base,noships,base2`. Опыт `noships` (новый, `tools/bench/frame_profile.gd`) прячет `ShipLayer` по образцу `nocrosses`; на отметке в журнал пишется `PROFILE ships`: узлов-LOD слоя и сколько из них в пирамиде видимости камеры (по центру узла).

Цена судов = base − noships (GPU окна, мс); шум = |base2 − base|. Места: `training_island` (море, 12 узлов судов) и `ongudai` (моря нет, слой пуст: 0 узлов, цена должна быть нулевой — проверка шума).

Команды (в копии задачи; перед первым запуском в свежей копии — `godot --headless --path . --import`):

```bash
.dpcli/dpcli job --lock gpu start SEA-12-perf 3600 env SKIP_FLY=1 TAG_SUFFIX=_noclouds \
  tools/bench/frame_profile.sh build/perf/SEA-12 "medium high" "training_island ongudai" \
  --sample=2 --keep=nocloudfx --exps=base,noships,base2
# main (в /home/greg/deltaplan, без noships):
.dpcli/dpcli job --lock gpu start SEA-12-main 3600 env SKIP_FLY=1 TAG_SUFFIX=_noclouds \
  tools/bench/frame_profile.sh <абс. путь>/build/perf/SEA-12-main "medium high" training_island \
  --sample=2 --keep=nocloudfx --exps=base,base2
```

Данные обоих прогонов ветки и main (jsonl, без xdg и логов): локально `/home/greg/deltaplan/build/perf_data/sea_ships_SEA-12.tar.gz` (вне скоупа задачи, не в git; каталоги `SEA-12-run1`, `SEA-12`, `SEA-12-main`). Стадия sea при сборке места на учебном острове не считается (`res://`); на реальных местах — 1,1–3,3 с по отчётам SEA-2 (не GPU).

## Суда в кадре (training_island)

Узлов-LOD слоя судов: 12 (все виды × LOD). В пирамиде видимости: medium 12/12 на 2 и 30 с, 3/12 на 60 с; high 3, 9, 3 на 2/30/60 с. Разница draw calls base − noships на учебном острове: 0–5 (high: 4, 4, 1 в прогоне 2; 1, 3, 1 в прогоне 1). На ongudai — 0.

## Цена судов, GPU мс (base − noships; в скобках шум |base2 − base|)

| пресет | место | отметка | прогон 1 | прогон 2 |
|---|---|---|---|---|
| high | training_island | 2 | −0,055 (0,04) | −0,010 (0,01) |
| high | training_island | 30 | −0,073 (0,04) | +0,003 (0,05) |
| high | training_island | 60 | −0,035 (0,05) | +0,089 (0,09) |
| high | ongudai | 2 | −0,010 (0,01) | −0,051 (0,17) |
| high | ongudai | 30 | +0,223 (0,06) | −0,382 (1,80) |
| high | ongudai | 60 | −0,069 (0,11) | −0,023 (0,04) |
| medium | training_island | 2 | +0,752 (0,92) | −0,039 (0,28) |
| medium | training_island | 30 | −0,330 (0,51) | +0,523 (0,91) |
| medium | training_island | 60 | −0,042 (1,28) | −0,028 (0,09) |
| medium | ongudai | 2 | +0,100 (0,12) | нет (не долетели до FLYING) |
| medium | ongudai | 30 | +0,119 (0,55) | +0,158 (0,01) |
| medium | ongudai | 60 | +0,069 (0,05) | −0,001 (0,00) |

Среднее по отметкам и двум прогонам: high / training_island −0,014 мс; high / ongudai −0,05 мс (разброс определяет отметка 30 со шумом 1,8); medium / training_island +0,14 мс при шуме до 1,3 мс на отметку (не годен); medium / ongudai +0,09 мс (слоя нет — это и есть уровень шума метода).

## Ветка против main (base, training_island, GPU мс)

main = `e9fec4dd`, ветка = `feature/sea-ships` + SEA-12 (общий предок `da87052e`; main ушёл вперёд на ~150 файлов, из них 12 в scripts/configs — не только суда; сравнение грубое). Шум main мал (≤ 0,06 мс).

| пресет | отметка | main base | ветка base, прогон 1 | ветка base, прогон 2 |
|---|---|---|---|---|
| high | 2 | 4,73 | 3,65 | 4,68 |
| high | 30 | 5,24 | 3,95 | 5,18 |
| high | 60 | 5,27 | 3,72 | 5,27 |
| medium | 2 | 4,22 | 5,35 | 3,22 |
| medium | 30 | 4,78 | 4,16 | 4,16 |
| medium | 60 | 4,78 | 4,80 | 3,20 |

Прогон 2 ветки на high совпадает с main в пределах 0,07 мс (разница −0,06, −0,07, 0,00). Прогон 1 ниже на 1,1–1,5 мс при том же числе draw calls (599/672/627 против 619/705/818) — вероятно, другое состояние машины/кадра, а не код. Medium на ветке не воспроизводится между прогонами (до 1,6 мс на одной отметке при разных draw calls: на отметке 60 — 559 и 382): полёт с автопилотом не детерминирован, положение камеры в двух прогонах разное. Достоверно: на high ветка не дороже main.

## Вывод

- Цена судов на GPU неотличима от шума метода: на high на учебном острове |base − noships| ≤ 0,09 мс на каждой отметке обоих прогонов; на ongudai (слоя нет) те же величины колеблются так же (−0,38…+0,22) — значит, наблюдаемый «эффект» — шум, не суда. Оценка сверху: ≤ ~0,1 мс при 12 узлах-LOD и 3–12 из них в кадре.
- Draw calls: +1…+4 на кадр с судами; нулевая нагрузка без моря (0 узлов).
- Пресет medium этим протоколом не измерим: шум на отметках 0,3–1,3 мс > 0,1 мс (критерий годности нарушен и после повтора). Оценку по medium взять с high (тот же слой, тот же код); для точного значения нужен детерминированный полёт (фиксированная поза камеры), не автопилот.
- Критерий годности G3 (шум ≤ 0,1 мс на каждой отметке) выполнен на high / training_island в обоих прогонах; на остальных — нет, оба прогона приведены.

## Допущения и границы

- «В пирамиде» — по центру узла, без радиуса; затенение и тени не разделены.
- 1920×1080 вместо окна GR-протоколов; облака выключены (`nocloudfx`), как в G3.
- Учебный остров — фиксированные 12 узлов; на реальных местах судов до ~100 на квадрат: цена масштабируется числом видимых узлов, дальше ~линейно по draw calls, но этим замером не проверена.
