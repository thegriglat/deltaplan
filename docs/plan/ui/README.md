# Группа 11 — Интерфейс (`ui/`)
Владения: `scripts/ui/`, `scenes/ui/`, `locale/`, `configs/ui.json`, `tests/ui/` (новая). Экраны наружу — только сигналы.
**Фокус:** UI сценария свободного полёта. Выбор режима задание/тренировка и рекорды на итоге — ОТЛОЖЕНО.

| Волна | Карточка | Модель | Размер | Владения |
|---|---|---|---|---|
| 1 | [01 Меню, «Полёт…», карта, «Управление»](01-menyu-i-polyot.md) | sonnet | M | start_menu, flight_setup_screen, controls_screen, ui_kit, ui.json |
| 1 | [02 Пауза, настройки, «Об игре», итог](02-pauza-nastrojki-itog.md) | sonnet | M | pause_menu, settings_panel, about_screen, assets_credits, result_screen, locale/ui.csv |

Обе карточки идут параллельно с game/01–02. `locale/ui.csv` — у 11-02; 11-01 присылает новые ключи списком
(или дописывает после 11-02). Вне объёма: выбор времени старта (VR-5), английский (NFR-4), «Как летать».
