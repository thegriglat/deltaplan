---
type: "research"
status: "closed"
module: "steam-assets"
updated: "2026-10-05"
summary: "Команды воспроизведения аудита лицензий сборки SA-1: настоящий экспорт, разбор PCK, сверка с эмуляцией, сводки."
related: ["docs/research/steam_license_audit.md", "tools/release/build_inventory.py"]
conclusion: ""
data: "tools/research/steam_license/"
applied_in: ""
---
# steam_license: аудит лицензий сборки (SA-1)

Документ с выводами - `docs/research/steam_license_audit.md`. Основной инструмент - `tools/release/build_inventory.py` (контракт SA-К1).
Лицензии данных: сюда входят только скрипты и небольшие результаты сверки (наши, MIT); сторонние файлы не копируются.

Все команды - из корня рабочей копии проекта (Godot 4.7.2 в PATH; шаблоны экспорта в `~/.local/share/godot/export_templates`;
`addons/air_onnx/bin/` и `air_onnx.gdextension` - из основной копии, они не в git).

```bash
tools/research/steam_license/run_pack.sh       # настоящий --export-pack Linux и Windows -> build/inv_check_<preset>.pck (≈ 1,5 мин; временный XDG_DATA_HOME)
tools/research/steam_license/run_export.sh     # настоящий --export-debug всех пресетов -> build/exp_check/ (что лежит рядом с exe)
python3 tools/research/steam_license/pck_list.py build/inv_check_Linux.pck build/pck_linux.json   # список файлов .pck (формат Godot 4.7)
unzip -o -q build/exp_check/macos/deltaplan.zip 'Deltaplan.app/Contents/Resources/Deltaplan.pck' -d build/exp_check/macos_x
python3 tools/research/steam_license/compare_pck.py Linux build/inv_check_Linux.pck   # сверка с эмуляцией -> compare_Linux.json (расхождений 0)
python3 tools/release/build_inventory.py --preset all --out build/inventory [--check] [--mode release]
python3 tools/research/steam_license/summarize.py build/inventory/Linux.json            # таблица групп
tools/research/steam_license/find_nc_texts.sh > tools/research/steam_license/nc_texts.txt # тексты «некоммерческий»
```

Файлы: `compare_Linux.json`, `compare_Windows.json`, `compare_macOS.json` - результат сверки эмуляции с настоящим экспортом; `nc_texts.txt` - тексты
«некоммерческий» на 05.10.2026; `inventory_summary_<preset>.md` - таблицы групп.
