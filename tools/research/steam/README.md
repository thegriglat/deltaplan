---
type: "research"
status: "closed"
module: "steam"
updated: "2026-10-05"
summary: "ST-1: прототип загрузки GodotSteam GDExtension 4.22.1 в Godot 4.7.2 headless — скрипты, команды воспроизведения, лицензии"
related: []
conclusion: "см. docs/research/steam_godotsteam.md"
data: "tools/research/steam/"
applied_in: "—"
---
# ST-1: прототип GodotSteam (GDExtension) вне игры

Итоги и выводы — `docs/research/steam_godotsteam.md`. Здесь — воспроизводимые скрипты. Бинарники GodotSteam
в git не коммитятся: `fetch_godotsteam.sh` скачивает закреплённую версию в `addons/godotsteam/` (кеш архива —
`~/.cache/deltaplan/`).

## Что закреплено

| | |
|---|---|
| Пакет | GodotSteam GDExtension **4.22.1** (Steamworks SDK 1.65, Godot 4.4+) |
| Архив | https://codeberg.org/godotsteam/godotsteam/releases/download/v4.22.1-gde/godotsteam-4.22.1-gdextension-plugin-4.4.zip |
| sha256 | `2b12b3499434c50da16104a0d22b725aee15cc5cd41223c1cea825bae59bfa8f` (27 290 405 байт) |
| Лицензия GodotSteam | MIT (`addons/godotsteam/license.md` в архиве), © GP Garcia, Chris Ridenour и участники |
| Лицензия Steamworks SDK | `libsteam_api.so` / `steam_api64.dll` / `libsteam_api.dylib` — распространяемые библиотеки Valve, условия — Steamworks SDK Access Agreement (принимается при регистрации в Steamworks); в публичные репозитории и в сборки не для Steam не класть |
| Репозиторий | https://codeberg.org/godotsteam/godotsteam (GitHub-зеркало переехало на Codeberg), ветка `gdextension` |

## Команды

```bash
cd /home/greg/deltaplan-steam-ST-1          # или любая копия
bash tools/research/steam/fetch_godotsteam.sh [корень_проекта]   # addons/godotsteam/ (идемпотентно)
bash tools/research/steam/probe.sh          # варианты A/B/(D)/E/C, строки STEAM_PROBE ...; выход 0 если ничего не упало
bash tools/research/steam/live.sh [сек]     # живая проверка на App ID 480 (нужен запущенный клиент Steam; ждёт сек секунд)
bash tools/research/steam/export_check.sh   # экспорт Linux x3 (steam/plain/noexcl) + состав Windows и macOS, запуск Linux-сборок
godot --headless -s dump_api.gd -- out=api_dump.json   # (в проекте с расширением) выгрузка методов/сигналов/констант
```

`probe.sh`, `live.sh`, `export_check.sh` работают во временном каталоге (`mktemp`), `XDG_DATA_HOME` временный, профиль
пилота не трогается. Шаблоны экспорта берутся из `~/.local/share/godot/export_templates` (переопределить —
`GODOT_TEMPLATES`).

## Файлы

- `fetch_godotsteam.sh` — скачивание с проверкой sha256.
- `probe.sh`, `probe.gd` — прототип: безопасная проверка наличия синглтона `Steam`, `steamInitEx`.
- `live.sh`, `live_check.gd` — проверки при запущенном клиенте на App ID 480 (Rich Presence, Cloud, лобби, Networking Messages «себе»; ачивки и статистика только читаются).
- `export_check.sh`, `probe_node.gd` — как включать/исключать расширение из экспортов.
- `dump_api.gd`, `api_dump.json` — список методов (798), сигналов (188), констант (2003) расширения, снят из загруженного `Steam`; точные сигнатуры для контрактов.
- `out/` — выводы запусков (probe.txt, probe_with_client.txt, live.txt, export_check.txt); ник и Steam ID вырезаны.

## Известные особенности (проверено)

- Первый `godot --headless --import` свежего проекта с расширением завершается SIGABRT при выходе (импорт при этом
  выполнен и `.godot/extension_list.cfg` записан); повторный запуск чистый. Без `extension_list.cfg` (нет импорта)
  `Engine.has_singleton("Steam")` ложно даже при наличии аддона. Для CI: импортировать дважды.
- Расширение инертно без клиента: `steamInitEx` возвращает `status=2`, ничего не падает.
