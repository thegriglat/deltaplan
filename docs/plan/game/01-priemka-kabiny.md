---
type: "plan"
status: "closed"
module: ""
updated: "2026-10-03"
summary: "12-01. Приёмка кабины по фиксированным кадрам (VR-11, FR-25a, VR-6)"
related: []
---
# 12-01. Приёмка кабины по фиксированным кадрам (VR-11, FR-25a, VR-6)
**Цель:** вид из кабины соответствует VR-11 и реальным фото; найденное исправлено в папках группы 12.
**Контекст:** REQUIREMENTS.md (VR-11, FR-21, FR-25a, FR-31), docs/guide/models.md (раздел «Вид от первого лица», 3 фото
Wikimedia: «Deltaplane_au_départ», «Hang_glider_start_hill_aug2004», «Fluegelkamera»), scripts/game/camera_rig.gd,
scripts/game/pilot_animator.gd, scripts/game/game.gd (`_hide_from_cockpit`, `_mount_instrument`), configs/camera.json.
**Владения:** `scripts/game/camera_rig.gd`, `scripts/game/pilot_animator.gd`, `scripts/game/game.gd` (только
`_hide_from_cockpit`, `_mount_instrument`, `_setup_glider`), `configs/camera.json`, ключи `cockpit*`/`mounted_instruments`
в `configs/game.json`, новые `tools/shots/cockpit.sh`, `tests/game/test_cockpit.gd`, `docs/screenshots/cockpit/`.
**Шаги:**
1. `tools/shots/cockpit.sh`: для каждого крыла (3) на Онгудае снять кадры через `--screenshot --camera --look --autopilot`:
   F вперёд (0,0) в полёте; DS вниз (0,−70) стоя на старте; DF вниз (0,−60) в полёте; U вверх (0,+55); B сзади (`chase`);
   плюс TS «тень крыла» — chase на высоте < 50 м над ровной посадкой. Всего 18 кадров, имена `<wing>_<кадр>.png`.
2. Сравнить с чек-листом ниже и с 3 фото; записать таблицу «кадр — пункт — ✔/✘ — что делать» в
   `docs/screenshots/cockpit/README.md`.
3. Исправить своё (смещение/наклон головы, FOV, скрытие шлема/головы, фаза анимации, крепление приборов,
   `cast_shadows` у визуала в игре). Дефекты моделей/приборов (форма рук, шрифт планшета) — не чинить, а
   записать в README как запрос группам 7/8 с кадром-доказательством.
4. `tests/game/test_cockpit.gd`: при look (0,0) в полёте в frustum камеры не попадает AABB трапеции/рук/паруса;
   при (0,−60) попадают `InstrumentMount` и `VarioMount`; при (0,+55) — парус; у визуала крыла тень включена.
**Чек-лист (КРИТЕРИЙ ПРИЁМКИ):** F — горизонт, земля, облака; ни рук, ни трапеции, ни паруса в кадре. DS — грудь,
подвеска, ноги/ботинки между стойками, руки на стойках, базовая штанга с планшетом (как pov_down.png). DF — руки на
штанге, планшет занимает ≥ 12 % высоты кадра, цифры высоты/вариометра читаются на 1920×1080; вариометр 90-х на
стойке виден. U — парус с латами, без дыр/мерцания. B — пилот лёжа в коконе, поза `prone`. TS — тень крыла на земле
видна. Все ✔ (или ✘ только с записанным запросом группе 7/8); `test_cockpit.gd` зелёный; `tools/check.sh` зелёный.
**Зависимости:** нет (волна 1). **Модель:** opus. **Размер:** M.
