---
type: "guide"
status: "active"
module: "air-onnx"
updated: "2026-10-03"
summary: "Как вставить нейросеть ветра (П-2, файл .onnx) в игру и полетать: проверка файла, куда положить (git или user://), сборка, выбор в настройках, что видно в журнале, быстрая проверка без игры"
related: ["docs/contracts/air-onnx.md", "docs/guide/air-model.md", "tools/air_onnx/README.md", "native/air_onnx/README.md"]
---
# Нейросеть ветра: как вставить сеть П-2 и полетать

Игра умеет считать ветер над рельефом нейросетью на процессоре (без видеокарты) вместо решателя на GPU. Сеть — файл
`model.onnx`. Формат файла — контракт O1, где его искать — O6 (`docs/contracts/air-onnx.md`). Здесь — по шагам,
что сделать, чтобы полететь на сети П-2 (9 карт на входе). Все команды — из корня репозитория.

Нужно: Python-окружение пилота (`PY` ниже), Godot 4.7.2 (`godot` в PATH), для сборки — сеть при первом запуске
(скачиваются зависимости расширения).

```bash
PY="env CUDA_VISIBLE_DEVICES= /home/greg/deltaplan-air-nn/tools/research/air_nn_pilot/.venv/bin/python -B"
```

## 1. Проверить файл

Сеть П-2 после обучения: `~/air_nn_data/pilot/runs/2026-10-03_p2/main/model.onnx`.

```bash
$PY tools/air_onnx/test_contract_o1.py --model ~/air_nn_data/pilot/runs/2026-10-03_p2/main/model.onnx   # итог: O1: OK
$PY tools/air_onnx/export_onnx.py --info ~/air_nn_data/pilot/runs/2026-10-03_p2/main/model.onnx          # входы, выход, метаданные
```

Ожидается: входы `maps` [1, 9, 96, 96] и `nums` [1, 18], выход `out` [1, 91, 96, 96], float32, opset 17. Метаданные
(`deltaplan.*`) у сырого `main/model.onnx` пилота могут отсутствовать — это нормально: игра тогда проверяет только
имена и формы.

Если готового `model.onnx` нет, а есть чекпойнт, экспортировать (с метаданными):

```bash
$PY tools/air_onnx/export_onnx.py --ckpt ~/air_nn_data/pilot/runs/2026-10-03_p2/main --out model.onnx
```

Проверка из шага выше повторяется и для этого файла.

## 2. Положить файл

Игра ищет сеть в таком порядке (O6), берётся первый существующий:

1. `--air-nn-model=<путь>` в командной строке игры. Путь задан, а файла нет — отказ, дальше поиск не идёт.
2. `user://air_nn/model.onnx` — подмена без пересборки.
3. `air_model.nn_model` из `configs/atmosphere.json`, по умолчанию `res://data/air_nn/model.onnx`.

**Вариант А — в репозиторий (попадает в сборку).**

```bash
cp ~/air_nn_data/pilot/runs/2026-10-03_p2/main/model.onnx data/air_nn/model.onnx
git add data/air_nn/model.onnx && git commit -m "Сеть П-2 (data/air_nn/model.onnx)"
```

Экспорт игры включает `*.onnx` (`export_presets.cfg → include_filter`), ORT читает файл из памяти.

**Вариант Б — подмена без пересборки (`user://`).** Имя папки пользователя игры — `Deltaplan`
(`project.godot`: `config/use_custom_user_dir=true`, `config/custom_user_dir_name="Deltaplan"`). Положить файл:

| ОС | Куда |
|---|---|
| Linux | `~/.local/share/Deltaplan/air_nn/model.onnx` |
| Windows | `%APPDATA%\Deltaplan\air_nn\model.onnx` |

```bash
mkdir -p ~/.local/share/Deltaplan/air_nn && cp model.onnx ~/.local/share/Deltaplan/air_nn/model.onnx
```

Файл из `user://` важнее файла из сборки. Для разовой проверки можно и не копировать: запустить игру с
`--air-nn-model=/полный/путь/model.onnx` (после `--` при запуске из Godot).

## 3. Собрать расширение и игру

Расширение `AirOnnx` (ONNX Runtime) нужно собрать; без него игра на нейросети не летит, а на упрощённой модели
ветра работает как обычно.

```bash
tools/build.sh linux       # или windows, или all
```

`tools/build.sh` сам собирает расширение (`native/air_onnx/build.sh <платформа>`), если оно ещё не собрано, затем
импорт и экспорт, и проверяет, что библиотеки лежат рядом с исполняемым файлом: Linux — `libair_onnx.so` и
`libonnxruntime.so.1`; Windows — `air_onnx.dll`, `onnxruntime.dll` и четыре DLL VC++ runtime (`msvcp140.dll`,
`msvcp140_1.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`, лежат рядом с exe, ничего ставить не нужно). Результат —
`build/<платформа>/` и `build/deltaplan-<платформа>.zip`. `AIR_ONNX=0 tools/build.sh …` — собрать без расширения.

Если Godot нужен вручную (импорт, тесты), его запускают с временным профилем, чтобы не трогать настоящий, и
с шаблонами экспорта симлинком (как в `tools/check.sh`):

```bash
export XDG_DATA_HOME=$(mktemp -d)
mkdir -p "$XDG_DATA_HOME/godot" && ln -s "$HOME/.local/share/godot/export_templates" "$XDG_DATA_HOME/godot/export_templates"
```

Вариант Б (`user://`) пересборки не требует, если игра уже собрана с расширением.

## 4. Включить в игре

Настройки → «Ветер над рельефом» → «Нейросеть (экспериментально)». Остальные значения — «Расчёт по рельефу»
(решатель на GPU) и «Упрощённый». Выбор действует со следующей загрузки места. В `configs/atmosphere.json` это
`air_model.enabled = "auto"` и `air_model.engine = "nn"`; потоков ORT — `air_model.nn_threads` (по умолчанию 4).

## 5. Что видно в журнале

Строки печатает игра на этапе «Рассчитываем ветер». Журнал — вывод в терминал при запуске игры оттуда; Godot
по умолчанию пишет его и в файл `user://logs/godot.log` (то есть `~/.local/share/Deltaplan/logs/godot.log` на Linux,
`%APPDATA%\Deltaplan\logs\godot.log` на Windows; в этой ветке путь запуском не проверялся).

- Работает — `air_model: поле (нейросеть model.onnx, П2 v4) <час> ч, <ветер> м/с с <откуда>°: … с, k …; … мс: вход …, карты …, сеть …, поле …`
  (в начале — имя файла сети и версия П2; в конце — разбивка времени по стадиям).
- Не работает — `air_model: analytic (нейросеть: <причина>)`, и игра летит на упрощённой модели ветра. Причины: нет
  расширения `AirOnnx` (не собрано), нет файла по порядку поиска из шага 2, формат файла ≠ O1, ошибка ORT, NaN в
  выходе, а также общие отказы (нет слоя рельефа, поле задано `--air-field=`).

## 6. Быстрая проверка без игры

Загрузка места с `engine = nn` без окна и без GPU: печатает строку `air_model` и время этапов.

```bash
tools/air_onnx/nn_load_probe.sh <model.onnx> [место] [час] [ветер м/с] [откуда °]
```

Нужно собранное расширение (шаг 3). Скрипт сам берёт временный профиль Godot.

## 7. Чего пока нет

- Окон 100/50 м нет — один уровень 400 м (область 38,4 × 38,4 км вокруг места).
- Сеть обучена мало; качество ветра на ней — предмет оценки пилота, а не гарантия.
- Windows-сборка собирается из Linux и не проверялась запуском (wine нет); если DLL не загрузятся, `load` вернёт
  ошибку, а игра пойдёт на упрощённой модели.
- macOS: расширение не собирается, сеть там не работает (игра на упрощённой модели); способ — `native/air_onnx/README.md`.
- Сеть первого пилота (4 карты) формат O1 проходит, но для П-2 нужна сеть с 9 картами.
