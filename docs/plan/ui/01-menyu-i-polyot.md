# 11-01. Меню «фото + кнопки», «Полёт…» с выбором старта на карте, «Управление»
**Цель:** закрыть «в работе» TODO: простое меню (FR-27), выбор старта на карте (FR-17), «Полёт…» (FR-34), «Управление».
**Контекст:** REQUIREMENTS.md (FR-17, FR-27, FR-34), docs/game.md («Как добавить экран»), scripts/ui/start_menu.gd,
scripts/ui/flight_setup_screen.gd, scripts/ui/controls_screen.gd, scripts/ui/ui_kit.gd.
**Владения:** `scripts/ui/start_menu.gd`, `scripts/ui/flight_setup_screen.gd`, `scripts/ui/controls_screen.gd`,
`scripts/ui/ui_kit.gd`, соответствующие `scenes/ui/*.tscn`, `configs/ui.json` (ключи menu*/setup*/map*), новый
`tests/ui/test_menu_setup.gd`, `docs/screenshots/ui/`. Не трогать `scripts/game/*` (FlightSettings — только читать).
**Шаги:**
1. Главное меню: фоновое фото (из `configs/ui.json`), кнопки по центру вертикально: «Лететь», «Полёт…»,
   «Управление», «Настройки», «Об игре», «Выход». «Лететь» — последний выбор (UserSettings).
2. «Полёт…»: крыло, масса, погода, ветер, место, старт списком и на карте; выбранная точка карты → ближайший склон
   (StartPlacement), подпись «старт: …»; все 4 локации из `configs/locations/`. Режима «задание/тренировка» НЕТ.
3. «Управление»: таблица клавиш из `configs/controls.json` (W+Shift разбег, мышь, 1–5, C, Esc, геймпад).
4. Все строки через tr(), ключи в `locale/ui.csv` (только ru; en — вне объёма).
5. Скриншоты 1920×1080 и 1280×720: меню, «Полёт…», карта, «Управление».
**КРИТЕРИЙ ПРИЁМКИ:** `test_menu_setup.gd` ≥ 6 проверок (6 кнопок в порядке FR-27; `fly_requested` с выбранными
крылом/массой/местом; выбор на карте даёт site или latlon; 4 локации в списке; «Управление» содержит все действия
InputMap; нет строк без tr()). 8 скриншотов с чек-листом в `docs/screenshots/ui/README.md` (ничего не обрезано,
текст читаем, кнопки по центру). tests/game/test_ui.gd зелёный; `tools/check.sh` зелёный.
**Зависимости:** нет (волна 1). **Модель:** sonnet. **Размер:** M.
