# T05. Волны порывов по траве и ниве без скачков (VR-17)

**Цель:** пятна порывов плавно «бегут» по ветру и не прыгают при смене ветра; сила рисунка — от реальной порывистости атмосферы.

**Контекст:** docs/terrain.md («Ветер на земле»), scripts/terrain/terrain_wind.gd, terrain_wind.gdshaderinc,
docs/plan/README.md (группа 5, рекомендация 2), docs/atmosphere.md (`air_velocity_at`, `mean_wind_at`).
**Владения:** `scripts/terrain/{terrain_wind.gd, terrain_wind.gdshaderinc, terrain.gd}`, `configs/world.json` (wind_visual),
`tests/terrain/test_wind.gd` (новый), `docs/terrain.md`.

## Шаги
1. Смещение рисунка копить на CPU: `offset += dir · speed · dt` → uniform (вместо `TIME · wind` в шейдере).
2. Порывистость = |air_velocity_at − mean_wind_at| у земли под камерой, сглаженная экспонентой (τ из конфига) → амплитуда пятен.
3. API: `Terrain.set_wind_sources(mean_fn, thermals_fn, air_fn := Callable())` — без `air_fn` как раньше
   (подключение в игре — группа «Сцена игры»); травинки и деревья получают те же uniform через include.
4. Превью: `--gusts` (подать `air_fn` из фейковой порывистости) для проверки.

## Критерий приёмки
- Тест: ветер повернули на 90° за 1 с — смещение рисунка за кадр ≤ 1,5·speed·dt (нет скачка); амплитуда ↑ при порывистости ↑.
- Тест: без `air_fn` поведение и uniform как до карточки.
- Ролик 5 с (кадры каждые 0,2 с) с 50 и 300 м в Онгудае для пользователя/пилота (VR-17 «видно подход термика?»).
- GPU «рельеф» — не выше предыдущего замера + 0,05 мс; тесты `tests/terrain` зелёные.

**Зависимости:** T02–T04 закрыты (общие terrain.gd, world.json, docs). **Модель:** sonnet. **Размер:** S.
