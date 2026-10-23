---
type: "research"
status: "active"
module: "crash-reports"
area: "release"
updated: "2026-10-23"
summary: "Скрипты CR-1: воспроизведение пустого RID и агрегаты отчётов группы A"
related: ["docs/research/crash-reports/cr-1.md"]
conclusion: "см. docs/research/crash-reports/cr-1.md"
data: "summary.json"
applied_in: "не применено"
---
# CR-1: диагноз группы A (issues #4-#10)
Документ: docs/research/crash-reports/cr-1.md.
- repro_invalid_buffer.gd: пустой RID буфера -> сообщения buffer_update / uniform_set_create (Vulkan, окно).
  Запуск: XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD") godot --path . --script tools/research/crash-reports/cr-1/repro_invalid_buffer.gd (под .dpcli/dpcli lock cpu).
- analyze_reports.py: агрегаты по сырым отчётам из ~/.cache/dp-crash-reports/ (вне репозитория) -> summary.json (только числа/коды ошибок).
Источники: репозиторий отчётов (приватный), код на коммите cd1a8be7 (v1.5.18). Данных сторонних лицензий нет.
