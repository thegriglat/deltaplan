---
type: "registry"
status: "active"
module: "pilot-feedback-trim"
area: "flight"
updated: "2026-11-02"
summary: "Выводы pilot-feedback-trim: трим паспортный, раскачка после отрыва и после X — фугоида, дёрганье мышью — чувствительность."
related: ["docs/registry/findings.md", "docs/research/pilot-feedback-trim/longitudinal.md", "docs/research/pilot-feedback-trim/liftoff.md", "docs/research/pilot-feedback-trim/mouse.md"]
---
# Выводы: pilot-feedback-trim

- Трим на нейтрали паспортный: при эталонной массе скорость выше паспорта на +0,26…+0,39 км/ч у всех 48 крыльев; при массе 85 кг у 9 из 15 безмачтовых ниже паспорта на 0,1–1,3 км/ч (≤ 0,75 см подвески); вердикт по п. 1 — none — [longitudinal.md](/docs/research/pilot-feedback-trim/longitudinal.md#6-вывод-по-пунктам).
- Просьба сдвинуть подвеску на +2…+4 см — это скорость на +3…+7 км/ч выше паспорта, а не исправление ошибки; умолчание без решения о паспортных тримах не менять (инвариант PFT-К1) — [longitudinal.md](/docs/research/pilot-feedback-trim/longitudinal.md#6-вывод-по-пунктам).
- Регресса v1.5.15…v1.7.0 нет: трим идентичен на всех пяти тегах, меняется только чувствительность к подвеске (+60 % с VM-4) — [longitudinal.md](/docs/research/pilot-feedback-trim/longitudinal.md#5-регрессия-по-версиям-5-крыльев-outversions_tabletxt).
- X ≡ мгновенное отпускание штанги; фугоида безмачтовых слабо демпфирована (ζ 0,03–0,04, T ≈ 5,3 с, в рамках Cook); `keyboard.center_time_s` 0,2 → 2 с снижает размах θ за 10 с на 31–53 % и V на 17–32 %, затухание не меняет (вердикт по п. 2 — config, частично; полное решение — демпфирование тангажа, вне модуля) — [longitudinal.md](/docs/research/pilot-feedback-trim/longitudinal.md#6-вывод-по-пунктам).
- Раскачка после отрыва физична, ошибки перехода «ноги → подвеска» нет: положение пилота при передаче меняется на 1 мм, перелёт θ 0,3° из 4,3° (sport, склон 12°); размах — фугоида от ΔV и Δγ на передаче, прогон/оценка Ланчестера 1,07; вердикт none — [liftoff.md](/docs/research/pilot-feedback-trim/liftoff.md#коротко).
- У ww_t2c размах вдвое больше sport (V_амп 4,29 против 1,72 км/ч на склоне 12°) из-за ΔV на передаче +4,6 против +0,3 км/ч: нейтраль на разбеге 11,5° ниже α трима 12,58°; опция config `launch.alpha_neutral_deg` 11,5 → 14,0 даёт V_амп 4,3 → 2,2 км/ч — решает пользователь — [liftoff.md](/docs/research/pilot-feedback-trim/liftoff.md#4-почему-у-ww_t2c-вдвое-больше-чем-у-sport).
- Дёрганье мышью — config: ход до упора при ×1 (2500 отсч.) на 3200 DPI всего 2,0 см (1 мм = 5 % хода), на 800 DPI 7,9 см; предложение `mouse.bar_travel_px` 2500 → 4000 и `bar_sensitivity_range` [0,25; 4] → [0,1; 4] (проверка у пилотов — PFT-3); DPI пилотов ≈ 3200–3630 — оценка по их словам — [mouse.md](/docs/research/pilot-feedback-trim/mouse.md#1-dpi-пилотов-и-ход-до-упора).
- Отклик модели на штангу не быстрее норм: перекладка 45°→45° 3,6–4,7 с (HGMA ≤ 4 с, DHV и SHV 5 с), то есть на уровне предела, не быстрее; числовых норм для 30→30 не найдено — [mouse.md](/docs/research/pilot-feedback-trim/mouse.md#сравнение-с-нормами).
