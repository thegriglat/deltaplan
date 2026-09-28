---
name: new-release
description: Выпуск новой версии Deltaplan — версия в проекте, CHANGELOG, папка releases/<версия> с devlog (plain text для itch.io), сборка Linux и Windows, git-тег, заливка на itch.io через butler. Использовать, когда пользователь просит «выпустить/собрать версию X.Y.Z», «new-release», «залить новую версию».
---

# new-release — выпуск версии Deltaplan

Аргумент: номер версии `X.Y.Z` (например `/new-release 0.8.0`). Если не указан — предложи следующий по изменениям с последнего тега (новые возможности → minor, только исправления → patch) и спроси подтверждение одним вопросом.

Работай в `/home/greg/deltaplan` (ветка `main`). Godot всегда с временным профилем `XDG_DATA_HOME=$(mktemp -d)`. Коммиты — только свои файлы: `git commit -m "..." -- <пути>`, сообщения на русском, с строкой Claude-Session, если её требует система.

## 0. Проверки перед выпуском
- `git status --short` — рабочая копия чистая (кроме служебных `.uid`); чужие незакоммиченные правки агентов — спроси пользователя, не включай молча.
- В корне нет временных файлов агентов: `override.cfg`, `tmp_*/`, `.full_test_out.log`, `prof_tmp_*` (Godot упакует их в сборку). `tools/` из экспорта исключена.
- Последний тег: `git describe --tags --abbrev=0` (теги вида `vX.Y.Z`).

## 1. Версия
- `project.godot` → `config/version="X.Y.Z"`.

## 2. CHANGELOG.md
- Раздел `## В работе` → новый раздел `## <ДД.ММ.ГГГГ> — сборка X.Y.Z` сразу под ним; «В работе» оставить пустым.
- Сверить с `git log <последний тег>..HEAD --oneline`: всё заметное для пилота есть в разделе (функциональные изменения, не список коммитов, по-русски). Недостающее — дописать.

## 3. releases/X.Y.Z/
- `releases/X.Y.Z/devlog.txt` — текст девлога для itch.io **на английском**, **простой текст** (визуальный редактор itch ломает Markdown-списки):
  - первая строка — заголовок: `Deltaplan X.Y.Z — <коротко о главном>`;
  - пустая строка, затем 1–2 абзаца о главном;
  - описание — **ключевые изменения с последнего тега** (по CHANGELOG и `git log`), по-английски, для пилотов;
  - **каждый список обрамлён строками `===` сверху и снизу** (пользователь удалит их при вставке), пункты — строки с `- `;
  - без Markdown (`**`, `#`, ссылок в скобках); без упоминания родителей и семьи — только «для пилотов» (правило публичных текстов);
  - в конце — «Known issues», если есть, тоже списком в `===`.
- `releases/X.Y.Z/screenshots/` — ключевые кадры принятых за версию изменений (JPEG q88 через `magick`, номера и русские названия по порядку). Если кадры уже лежат в `releases/next/` или в другой заготовке — перенести.
- Бинарники в `releases/` не класть. `releases/.gdignore` уже есть.

Пример `devlog.txt`:
```
Deltaplan 0.8.0 — flying together

You can now fly with friends in one sky ...

===
- Network play: create a zone, share a 4-digit code
- Catch up: press = and fly next to a friend
===

Known issues:
===
- ...
===
```

## 4. Коммит версии
`git commit -m "Версия X.Y.Z; CHANGELOG и releases/X.Y.Z" -- project.godot CHANGELOG.md releases/X.Y.Z` (и `git add releases/X.Y.Z` перед этим).

## 5. Сборка
- `tools/build.sh all --release` (нужен дисплей: Shader Baker запекает шейдеры только при экспорте с окном; без дисплея — предупреждение и сборка без запекания). Проверить вывод: «готово: build/linux/…», «готово: build/windows/…».
- `data/build_info.json` → коммит без `+` (иначе была незакоммиченная правка — вернуться к шагу 0).
- Smoke Linux: `XDG_DATA_HOME=$(mktemp -d) build/linux/deltaplan.x86_64 --headless -- --smoke | grep smoke` — все 9 крыльев, 4 места, `terrain data=true`, `about … ok=true`, «300 шагов … фаза flying».
- Архивы: `unzip -l build/deltaplan-windows.zip | grep -v configs/` — только `deltaplan.exe` + `deltaplan.pck` (нет `*.console.exe`, временных файлов); то же для Linux.

## 6. Тег
`git tag -a vX.Y.Z <коммит сборки> -m "Deltaplan X.Y.Z"` — на коммит из шага 4 (тот, из которого собрано). Пушить (`git push`, `--tags`) — только если пользователь попросит.

## 7. itch.io (butler)
- Цель: `thegriglat/deltaplan`, каналы `linux`, `windows`; заливать **каталоги**, не zip (сохраняется бит исполнимости):
  ```
  butler push build/linux thegriglat/deltaplan:linux --userversion X.Y.Z
  butler push build/windows thegriglat/deltaplan:windows --userversion X.Y.Z
  ```
- Дождаться обработки: `butler status thegriglat/deltaplan` — у обоих каналов `✓` и версия `X.Y.Z` (ожидать циклом с `sleep 10`, пока есть `•`).
- Это публикация — выполнять только по явной просьбе выпустить версию (вызов скилла ею и является).

## 8. Отчёт пользователю
Коротко: версия, коммит и тег, размеры архивов, итог smoke, статус каналов itch, путь `releases/X.Y.Z/devlog.txt` (напомнить: убрать строки `===` при вставке), что вошло в версию (3–5 пунктов).
