---
type: "research"
status: "active"
module: "crash-reports"
area: "release"
updated: "2026-10-23"
summary: "Скрипты и черновик манифеста CR-4: сводка отчётов и itch.toml с двумя действиями запуска."
related: ["docs/research/crash-reports/cr-4.md"]
contracts: []
conclusion: "см. docs/research/crash-reports/cr-4.md"
data: ""
applied_in: "не применено"
---
# CR-4: драйвер рендера Windows
- `summarize_reports.py` — сводка полей отчётов (данные в `~/.cache/dp-crash-reports/`, вне репо): `python3 -I summarize_reports.py ~/.cache/dp-crash-reports`
- `itch.toml.draft` — черновик манифеста с двумя действиями (не применён).
- Источники: исходники Godot 4.7-stable (`main/main.cpp:2383-2392`, `platform/windows/display_server_windows.cpp:7863-7945`, `doc/classes/ProjectSettings.xml`), документация itch (manifest-actions). Лицензии: Godot — MIT, документация itch — только цитирование ссылкой.
