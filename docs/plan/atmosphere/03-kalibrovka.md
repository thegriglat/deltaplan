# 03. Калибровка пресетов по проходимости маршрута + регрессионный тест

**Цель:** подогнать `configs/weather/*` и `configs/atmosphere.json` так, чтобы в средний и сильный день маршрут
проходился на всех 4 локациях, а статистика попадала в коридоры реальных XC (02); закрепить тестом.

**Контекст:** отчёт 02 (docs/atmosphere.md, docs/research/xc_reference.md), `configs/weather/{weak,medium,strong}.json`,
`configs/atmosphere.json`, `scripts/atmosphere/thermal_field.gd`, `tools/atmosphere/xc_matrix.sh`.

**Владения:** `configs/weather/{weak,medium,strong}.json`, `configs/atmosphere.json` (секции thermal/turbulence),
`scripts/atmosphere/thermal_field.gd` (только если параметром не решить), `tests/atmosphere/test_xc_regression.gd`.
Веса поверхности `world.json → surface.thermal` — группа 4: если нужны правки — карточка там, не править.

**Шаги:**
1. По отчёту 02 выбрать рычаги: `thermal_spacing_m`, `thermal_duty`, `thermal_strength_ms`, `thermal_radius_m`,
   `background_sink_ms`, `source_frequency_exponent`, `cloudbase_agl_m`, `dry_thermal_fraction`. Менять по одному,
   прогонять подматрицу (1 локация, 3 сида), затем полную.
2. Не ломать требования: ядро 0,5–5 м/с (FR-11), фон ≈ −0,5 (FR-15), слабый день остаётся трудным, +8 редкость (04).
3. `test_xc_regression.gd` (фильтр `xc`, не в общем быстром прогоне): 2 локации × medium/strong × 3 сида × 20 км.
4. Записать итоговые числа и причину каждой правки в docs/atmosphere.md (раздел из 02).

**Критерий приёмки:**
- medium и strong: на каждой из 4 локаций ≥ 4 из 5 сидов проходят 40 км без посадки (без `--clouds`; с `--clouds` —
  маршрутная скорость выше на ≥ 10 %: облака полезны, как в жизни).
- weak: проходят ≤ 2 из 5 (слабый день — вызов, не прогулка).
- ≥ 4 из 6 метрик 02 в коридоре эталона для medium и strong (медиана по сидам); остальные — с объяснением.
- Все прежние тесты `--filter=atmosphere` зелёные; тест 04 зелёный.

**Зависимости:** 02; после 04 (04 правит физику, 03 — числа последним). **Модель:** opus. **Размер:** M.
