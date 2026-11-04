---
type: "registry"
status: "active"
module: "pilot-handling"
area: "flight"
updated: "2026-11-04"
summary: "Выводы pilot-handling: «надувной» отклик — ввод, раскачка после X — фугоида, спираль — класс, темп руки 0,15 с."
related: ["docs/registry/findings.md", "docs/research/pilot-handling/feel.md", "docs/research/pilot-handling/lateral-x.md", "docs/guide/game/menus-settings.md", "docs/guide/game/cameras-input.md"]
---
# Выводы: pilot-handling

- Подпись ползунка «Чувствительность штанги» (PHD-1): «×N ≈ X см до упора (800 DPI)» и подсказка «вправо — резче (ход меньше), влево — плавнее»; см показываются только на Windows/X11 (сырые отсчёты), на Wayland/macOS — подсказка про ускорение ОС; диапазон и умолчание ×1 (4000 отсч., PFT-3) не менялись — [menus-settings.md](/docs/guide/game/menus-settings.md#настройки-пилота).
- «Надувной» отклик — ввод, а не инерции и демпфирование: Ixx системы 297–405 кг·м² (у Cook ≈ 235; без присоединённой массы Ixx sport 208), Clp −0,75…−0,86 (Cook −0,93), крен-мода λ 8,8–10 1/с по \|Lp\|/Ixx; 1 мм мыши при ×4 и 3200 DPI = 12,6–20 % хода (6–9 см смещения пилота), команда руки шла на сервопривод без фильтра — [feel.md](/docs/research/pilot-handling/feel.md#коротко).
- Мёртвая зона 2 % гасит дрожь на 800 DPI (1 мм при ×1 = 0,8 % хода) только около нейтрали штанги; при отклонённой штанге — нет — [feel.md](/docs/research/pilot-handling/feel.md#допущения-и-границы).
- Раскачка после X из виража — фугоида (ω 1,1–1,2 рад/с, ζ 0,02–0,05; β 0,3–0,9°), голландский шаг (ω 1,94–2,23, ζ 0,37–0,53) X не возбуждает; ступень, рампа 0,5–2 с и экспонента 0,2 с дают один конечный крен (±0,3°); Cnp в осях устойчивости +0,042…+0,057 ≈ Cook (+0,0568); вердикт item 3 — none — [lateral-x.md](/docs/research/pilot-handling/lateral-x.md#ответ-на-вопросы-карточки).
- Затягивание виража 30° после X до 52–65° у laminar/sport/icaro_mastr — неустойчивая спираль (λ +0,04…+0,08 1/с; у training −0,34), свойство классов (мачтовые и безмачтовые держат спираль, учебные выходят сами), а не раскачка и не дефект X — [lateral-x.md](/docs/research/pilot-handling/lateral-x.md#ответ-на-вопросы-карточки).
- Темп руки игрока `controls.json → hand.tau_s` 0,15 с (Q1/Q2 (а), PHD-4): фильтр первого порядка итоговых крена и тангажа штанги от мыши, клавиатуры, X и стика; отношение амплитуд дрожи 4 Гц / 0,5 Гц 0,83–0,89 → 0,23–0,25, перекладка 45→45 4,77 (training) / 4,39 с (sport); X идёт без рывка. Граница: руки модели (`pilot_arms`), боты, автопилот и дельталёт — без фильтра — [feel.md](/docs/research/pilot-handling/feel.md#5-проверка-предложения-фильтр-команды-руки).
- Падения тестов в копиях — окружение: набор из 16 упавших тестов (pilot_view, bar_mouse, mouse_bar_flight, pendulum_game, trike_anywhere) совпадает построчно на `main` и `feature/pilot-handling`, в feature новых нет; в логах одинаково `SCRIPT ERROR: Out of bounds get index` в `wing_strips.gd:403` (PHD-5, `build/dpcli/PHD-5/main_vs_feature.md` в основной копии) — [feel.md](/docs/research/pilot-handling/feel.md#допущения-и-границы).
