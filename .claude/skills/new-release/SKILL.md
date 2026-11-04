---
name: new-release
description: Выпуск новой версии Deltaplan — версия в проекте, CHANGELOG, страница версии на сайте site/content/releases/<версия> (index.en.md + index.ru.md, devlog — plain text для itch.io; без скриншотов), сборка Linux и Windows (macOS с rust-wind не собирается — только по решению пользователя), git-тег, заливка на itch.io через butler. Использовать, когда пользователь просит «выпустить/собрать версию X.Y.Z», «new-release», «залить новую версию».
---

# new-release — выпуск версии Deltaplan

Аргумент: номер версии `X.Y.Z` (например `/new-release 0.8.0`). Если не указан — предложи следующий по изменениям с последнего тега (новые возможности → minor, только исправления → patch) и спроси подтверждение одним вопросом.

Работай в `/home/greg/deltaplan` (ветка `main`). Godot всегда с временным профилем `XDG_DATA_HOME=$(mktemp -d)`. Коммиты — только свои файлы: `git commit -m "..." -- <пути>`, сообщения на русском.

## 0. Проверки перед выпуском
- `git status --short` — рабочая копия чистая (кроме служебных `.uid`); чужие незакоммиченные правки агентов — спроси пользователя, не включай молча.
- Нет незакрытых задач в модулях, что идут в выпуск: `.dpcli/dpcli status` (сводка задач, веток, вопросов пользователю).
- В корне нет временных файлов агентов: `override.cfg`, `tmp_*/`, `.full_test_out.log`, `prof_tmp_*` (Godot упакует их в сборку). `tools/` из экспорта исключена.
- Последний тег: `git describe --tags --abbrev=0` (теги вида `vX.Y.Z`).

## 1. Версия
- `project.godot` → `config/version="X.Y.Z"`.

## 2. CHANGELOG.md
- Раздел `## В работе` → новый раздел `## <ДД.ММ.ГГГГ> — сборка X.Y.Z` сразу под ним; «В работе» оставить пустым.
- Сверить с `git log <последний тег>..HEAD --oneline`: всё заметное для пилота есть в разделе (функциональные изменения, не список коммитов, по-русски). Недостающее — дописать.

## 3. site/content/releases/X.Y.Z/ — страница версии на сайте
Папка — page bundle сайта (Hugo, `site/`); сайт двуязычный: английский — основной (корень), русский — под `/ru/`. В бандле два файла страницы: `index.en.md` (английский, основной) и `index.ru.md` (русский, шаблон ниже; английский — тот же по структуре, текст по-английски). `devlog.txt` (один, английский, plain text для itch) общий для обоих языков, без суффикса. **Скриншотов у страниц версий нет** (решение пользователя 2026-11-02): ни `screenshots/`, ни `cover`, ни галереи.
- `site/content/releases/X.Y.Z/index.ru.md` (и парный `index.en.md`) — страница версии:
  ```
  ---
  title: "Deltaplan X.Y.Z"
  date: ГГГГ-ММ-ДД            # дата сборки, как в разделе CHANGELOG
  description: "Одна фраза о главном"
  ---

  # Deltaplan X.Y.Z — <коротко о главном>

  ДД.ММ.ГГГГ · [Скачать на itch.io](https://thegriglat.itch.io/deltaplan)

  ## Что вошло
  <из нового раздела CHANGELOG.md, по-русски, для пилотов>

  [Текст девлога для itch.io (англ.)](/site/content/releases/X.Y.Z/devlog.txt)
  ```
  Без упоминания родителей и семьи (публичный текст).
- `site/content/releases/X.Y.Z/devlog.txt` — текст девлога для itch.io **на английском**, **простой текст** (визуальный редактор itch ломает Markdown-списки):
  - первая строка — заголовок: `Deltaplan X.Y.Z — <коротко о главном>`;
  - пустая строка, затем 1–2 абзаца о главном;
  - описание — **ключевые изменения с последнего тега** (по CHANGELOG и `git log`), по-английски, для пилотов;
  - списки — строки с `- `; заголовок группы — строка с двоеточием (`Gliders:`), сразу за ним пункты; **без разделителей `===`** и других обрамлений вокруг списков (старые devlog 0.8.0 — не образец);
  - без Markdown (`**`, `#`, ссылок в скобках); без упоминания родителей и семьи — только «для пилотов» (правило публичных текстов);
  - в конце — «Known issues», если есть, тоже списком.
- Бинарники в `site/` не класть. Godot папку `site/` не импортирует (`site/.gdignore`) и в экспорт не берёт (`export_presets.cfg` → `site/*`).
- Проверка сайта: `cd site && ~/.local/bin/hugo --renderToMemory 2>&1 | grep -E "WARN|ERROR"` — пусто; и `python3 tools/site/check_i18n.py` (контрактный тест двуязычности) — без ошибок.

Пример `devlog.txt`:
```
Deltaplan 0.8.0 — flying together

You can now fly with friends in one sky ...

- Network play: create a zone, share a 4-digit code
- Catch up: press = and fly next to a friend

Known issues:
- ...
```

## 4. Коммит версии
`git commit -m "Версия X.Y.Z; CHANGELOG и страница версии" -- project.godot CHANGELOG.md site/content/releases/X.Y.Z` (и `git add site/content/releases/X.Y.Z` перед этим; в папке оба файла — `index.en.md` и `index.ru.md`). После пуша в main сайт пересобирается сам (`.github/workflows/pages.yml`); пушить — только по просьбе.

## 5. Сборка
- Запекать поля не нужно: с rust-wind (2026-10-30) ветер считает крейт dp-air при загрузке места, запечённых полей нет.
- macOS не собирать и не заливать молча: расширение dp-air под macOS не собирается, Mac-пользователи остаются на последней GPU-версии. Спросить пользователя; по умолчанию канал `mac` на itch не трогать.
- `tools/build.sh linux --release` и `tools/build.sh windows --release` (нужен дисплей: Shader Baker запекает шейдеры только при экспорте с окном; без дисплея — предупреждение и сборка без запекания). Проверить вывод: «готово: build/linux/…», «готово: build/windows/…»; рядом с бинарником — библиотека dp_air (`libdp_air_release.so` / `dp_air_release.dll`).
- `data/build_info.json` → коммит без `+` (иначе была незакоммиченная правка — вернуться к шагу 0).
- Smoke Linux — с прогретым кэшем ветра: у smoke сторож 90 с, а первый расчёт ветра Онгудая ≈ 280 с (не регрессия). Сначала `P=$(mktemp -d); XDG_DATA_HOME=$P timeout 400 build/linux/deltaplan.x86_64 --headless -- --autostart --autopilot | grep -E "READY|game:"` (дождаться `READY`), затем `XDG_DATA_HOME=$P build/linux/deltaplan.x86_64 --headless -- --smoke | grep smoke` — все крылья из configs/wings, 4 места, `terrain data=true`, `about … ok=true`, «300 шагов … фаза flying».
- Каталоги (zip не делаются, butler заливает каталоги): `find build/windows -not -path "*/configs/*"` — только `deltaplan.exe` + `deltaplan.pck` + `dp_air_release.dll` (нет `*.console.exe`, временных файлов); то же для `build/linux` (`deltaplan.x86_64`, `deltaplan.pck`, `libdp_air_release.so`).

## 6. Тег
`git tag -a vX.Y.Z <коммит сборки> -m "Deltaplan X.Y.Z"` — на коммит из шага 4 (тот, из которого собрано). Пушить (`git push`, `--tags`) — только если пользователь попросит.

## 7. itch.io (butler)
- Цель: `thegriglat/deltaplan`, каналы `linux`, `windows` (`mac` — только по решению пользователя, см. шаг 5); заливать **каталоги**, не zip (сохраняется бит исполнимости):
  ```
  butler push build/linux thegriglat/deltaplan:linux --userversion X.Y.Z
  butler push build/windows thegriglat/deltaplan:windows --userversion X.Y.Z
  ```
- Дождаться обработки: `butler status thegriglat/deltaplan` — у залитых каналов (linux, windows) `✓` и версия `X.Y.Z` (ожидать циклом с `sleep 10`, пока есть `•`).
- Это публикация — выполнять только по явной просьбе выпустить версию (вызов скилла ею и является).

## 8. Отчёт пользователю
Коротко: версия, коммит и тег, размеры каталогов (`du -sh build/{linux,windows}`), итог smoke, статус каналов itch, путь `site/content/releases/X.Y.Z/devlog.txt` и страницы версии после пуша: en https://thegriglat.github.io/deltaplan/releases/X.Y.Z/ и ru https://thegriglat.github.io/deltaplan/ru/releases/X.Y.Z/, что вошло в версию (3–5 пунктов).
