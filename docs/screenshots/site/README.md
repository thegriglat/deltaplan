# Новые кадры сайта (октябрь 2026)

Перезняты готовыми инструментами `tools/shots`: обновлены 3D-модели крыльев (48 вариантов), новые кадры игрового процесса.

## Кадры для сайта

| Файл | Что на кадре | Команда съёмки |
|---|---|---|
| 01_группа_в_термике_1.jpg | Группа в термике (кадр 1) | `godot … res://tools/shots/itch_shot.tscn -- --autostart --autopilot --bots=8 --kind=gaggle --times=150,220,300 --out=... --tag=gaggle` |
| 02_группа_в_термике_2.jpg | Группа в термике (кадр 2) | (см. 01) |
| 03_группа_в_термике_3.jpg | Группа в термике (кадр 3) | (см. 01) |
| 04_старт_крылья_на_склоне.jpg | Старт, крылья на склоне | `godot … res://tools/shots/itch_shot.tscn -- --autostart --autopilot --bots=8 --kind=launch --out=... --tag=launch` |
| 05_разбег.jpg | Разбег | `godot … res://tools/shots/itch_shot.tscn -- --autostart --autopilot --bots=8 --kind=run --out=... --tag=run` |
| 06_у_кромки_облаков.jpg | У кромки облаков | `godot … res://tools/shots/itch_shot.tscn -- --autostart --autopilot --bots=8 --kind=high --out=... --tag=high` |
| 07_славутич_сзади.jpg | Славутич, вид сзади | `godot … res://tools/shots/itch_shot.tscn -- --autostart --autopilot --bots=8 --kind=chase --times=20 --wing=slavutich_ut --out=... --tag=chase_slavutich_ut` |
| 08_piuma_сзади.jpg | Piuma, вид сзади | `godot … res://tools/shots/itch_shot.tscn -- --autostart --autopilot --bots=8 --kind=chase --times=20 --wing=icaro_piuma --out=... --tag=chase_icaro_piuma` |
| 09_eagle_сзади.jpg | Eagle, вид сзади | `godot … res://tools/shots/itch_shot.tscn -- --autostart --autopilot --bots=8 --kind=chase --times=20 --wing=ww_eagle --out=... --tag=chase_ww_eagle` |
| 10_t2c_сзади.jpg | T2C, вид сзади | `godot … res://tools/shots/itch_shot.tscn -- --autostart --autopilot --bots=8 --kind=chase --times=20 --wing=ww_t2c --out=... --tag=chase_ww_t2c` |

Все кадры:
- JPEG, качество 85, размер 1600×900, ≤ 350 КБ
- Снято с `XDG_DATA_HOME=$(mktemp -d)`, timeout 150 с, DISPLAY=:0, --audio-driver Dummy, --fullscreen
- Без интерфейса игры (автоматично для itch_shot)

Процесс съёмки:
- `tools/shots/gameplay.sh` — геймплей: кабина, сзади, свободная камера (обновлены)
- `tools/shots/e2e.sh` — локации: полёт и итог для каждого места (пересняты)
- `tools/shots/itch_shot.tscn` — сценарии: gaggle, launch, run, high, chase (новые кадры для сайта)
