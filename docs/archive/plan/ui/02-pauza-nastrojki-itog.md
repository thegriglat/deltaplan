# 11-02. Пауза, настройки (с вариометром 90-х), «Об игре», итог свободного полёта
**Цель:** закрыть «в работе» TODO этапа 4 по экранам: пауза/настройки (FR-27, FR-33, NFR-6), FR-25a (выбор звука
вариометра 90-х), «Об игре» (FR-27a), итог полёта без рекордов.
**Контекст:** REQUIREMENTS.md (FR-25a, FR-27, FR-27a, FR-33, NFR-6), scripts/ui/pause_menu.gd, scripts/ui/settings_panel.gd,
scripts/ui/about_screen.gd, scripts/ui/result_screen.gd, docs/guide/instruments.md (`set_sound_settings`).
**Владения:** `scripts/ui/pause_menu.gd`, `scripts/ui/settings_panel.gd`, `scripts/ui/about_screen.gd`,
`scripts/ui/assets_credits.gd`, `scripts/ui/result_screen.gd`, их `scenes/ui/*.tscn`, `locale/ui.csv`, новый
`tests/ui/test_screens.gd`. Не трогать `scripts/game/*`.
**Шаги:**
1. Пауза: «Продолжить», «Заново», «Настройки», «Управление», «В меню».
2. Настройки: громкости по шинам, чувствительность/инверсия/режим мыши, пресет графики, звук вариометра
   (XC Tracer / classic_90s) и показ вариометра 90-х на стойке — сохранение в `user://configs` через
   `UserSettings.save_patch`, применение без перезапуска (сигнал наружу, применяет Game).
3. «Об игре»: все записи ASSETS.md (CC-BY авторы, Copernicus/Terrarium, OFL), прокрутка.
4. Итог: заголовок по оценке посадки; время, дистанция, след, набор, макс. высота (если есть в info — см. docs/guide/game.md,
   карточка 12-03; нет поля — строку не показывать); кнопки «Заново», «Продолжить», «В меню».
5. Скриншоты: пауза, настройки, «Об игре», итог (мягкая посадка и авария).
**КРИТЕРИЙ ПРИЁМКИ:** `test_screens.gd` ≥ 6 проверок (сохранение настроек и чтение после перезагрузки панели; выбор
classic_90s пишет ключ; «Об игре» содержит каждого автора из ASSETS.md; `lines_for` без поля не падает; кнопки итога
эмитят 3 сигнала; нет строк без tr()). 5 скриншотов с чек-листом в `docs/screenshots/ui/README.md`. `tools/check.sh` зелёный.
**Зависимости:** нет (волна 1); строка макс. высоты — после 12-03. **Модель:** sonnet. **Размер:** M.
