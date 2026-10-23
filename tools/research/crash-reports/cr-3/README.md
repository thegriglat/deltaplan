---
type: "research"
status: "active"
module: "crash-reports"
area: "release"
updated: "2026-10-23"
summary: "Скрипт повторной загрузки точки для CR-3 и источники данных."
conclusion: "см. docs/research/crash-reports/cr-3.md"
data: ""
applied_in: ""
---
# CR-3: проверка загрузки точки (стадия trees)
Запуск (из корня копии, под замком CPU): `.dpcli/dpcli lock cpu cr3 -- tools/research/crash-reports/cr-3/repro.sh [lat,lon]`.
Координаты берутся из `~/.cache/dp-crash-reports/cr3_latlon.txt` (вне репозитория). Сырые отчёты: `~/.cache/dp-crash-reports/` (приватный репозиторий thegriglat/deltaplan-reports, issue #3).
Данные в процессе загрузки: Terrarium (AWS), ESA WorldCover (CC BY 4.0), тайлы OSM (ODbL) — в репозиторий не сохраняются.
