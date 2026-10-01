# Кадры для сайта (октябрь 2026)

Сняты готовыми инструментами `tools/shots` после обновления крыльев (48 моделей). Место — Онгудай, старт по умолчанию. Все кадры — JPEG 1600×900, q85 (05 — q80, чтобы уложиться в 350 КБ). Каждый запуск — `XDG_DATA_HOME=$(mktemp -d) timeout 150 godot --path . --audio-driver Dummy --fullscreen --resolution 1920x1080 …`, окно на настоящем дисплее; исходный png уменьшен до 1600×900.

| Файл | Что на кадре | Аргументы после `godot … ` |
|---|---|---|
| 01_в_термике.jpg | бот в термике над долиной | `res://tools/shots/itch_shot.tscn -- --autostart --autopilot --bots=8 --kind=gaggle --times=150,220,300 --out=<каталог> --tag=gaggle` → `gaggle_1.png` |
| 02_в_термике_над_стартом.jpg | бот в термике над стартом | то же → `gaggle_3.png` |
| 03_разбег.jpg | крыло на разбеге, вид со старта | `res://tools/shots/itch_shot.tscn -- --autostart --autopilot --bots=8 --kind=run --out=<каталог> --tag=run` |
| 04_у_кромки_облаков.jpg | у кромки облаков | `res://tools/shots/itch_shot.tscn -- --autostart --autopilot --bots=8 --kind=high --out=<каталог> --tag=high` |
| 05_славутич_ут_сзади.jpg | «Славутич УТ» сзади над склоном | `-- --autostart --autopilot --no-overlay --camera=chase --time=20 --wing=slavutich_ut --screenshot=<файл>.png` |
| 06_icaro_piuma_сзади.jpg | Icaro Piuma сзади | то же, `--wing=icaro_piuma` |
| 07_ww_eagle_сзади.jpg | Wills Wing Eagle сзади | то же, `--wing=ww_eagle` |
| 08_ww_t2c_сзади.jpg | Wills Wing T2C сзади | то же, `--wing=ww_t2c` |

Не вошли: `itch_shot --kind=launch` (крыльев на склоне в кадре не видно), `--kind=chase` с `--wing=` (камера не на крыле игрока — снято через main.tscn, как `tools/shots/gameplay.sh`).

Кадры `docs/screenshots/gameplay/*.jpg` пересняты `tools/shots/gameplay.sh`. Кадры `docs/screenshots/e2e/` не пересняты: `tools/shots/e2e.sh` на всех местах падает с «e2e_shot: FAIL (мир за меню не загрузился)» (01.10.2026).
