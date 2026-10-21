---
type: "contract"
status: "active"
module: "tow"
area: "flight"
updated: "2026-10-22"
summary: "Контракт TW-К8 модуля tow: модели Blender winch, release, drogue, dolly — узлы, бюджеты треугольников, оси, материалы."
related: ["docs/contracts/tow.md", "docs/guide/models.md"]
contracts: []
---
# Контракты модуля tow — модели (TW-К8)

Вынесено из `docs/contracts/tow.md` (лимит 40 КБ); версия — там же.

## TW-К8 v3. Модели `winch`, `release`, `drogue`, `dolly`
Владелец — TW-11; потребители — TW-10 (размещение и крепление). Контрактный тест — `tests/contracts/test_tow_k8.gd`
(или раздел `scenes/models_preview/check_models.gd`). Основание — `docs/research/tow/models.md`.

- `winch`: `tools/blender/build_tow_winch.py` (+ JSON параметров рядом) → `assets/models/world/tow_winch.glb`
  (+ `assets/source/world/tow_winch.blend`); узлы `tow_winch_LOD0`, `tow_winch_LOD1`, `tow_winch_LOD2`; треугольники
  ≤1500 / ≤200 / ≤40; начало — на земле в центре рамы; −Z модели — к пилоту (направление троса); узел
  `tow_winch_rope_out` (Marker/пустышка) — точка выхода троса (направляющая), м; вершинные цвета, без текстур.
- `release`: `tools/blender/build_tow_release.py` → `assets/models/world/tow_release.glb`; узлы `tow_release_LOD0`,
  `tow_release_LOD1`; ≤300 / ≤40; уздечка, кольцо-замок, ручка отцепа; узлы `tow_release_attach` (точка на подвеске
  пилота) и `tow_release_rope` (точка троса); масштаб — метры, как пилот; вершинные цвета.
- `drogue` (v2, решение пользователя 2026-10-22: купол — модель Blender, не процедурный; в коде только трос): владелец — TW-12;
  `tools/blender/build_tow_drogue.py` (+ JSON параметров) → `assets/models/world/tow_drogue.glb`
  (+ `assets/source/world/tow_drogue.blend`); узлы `tow_drogue_LOD0`, `tow_drogue_LOD1`, `tow_drogue_LOD2`; треугольники
  ≤150 / ≤60 / ≤16; купол жёсткий (раскрытый), стропы сходятся в узел `tow_drogue_attach` (точка на тросе) в начале
  координат; купол — по +Z от `tow_drogue_attach`, −Z модели — направление движения троса (игра ставит −Z по скорости
  конца троса, TW-10); размеры — из `docs/research/tow/kinds.md` (с источником) или оценка с пометкой в JSON; вершинные цвета.
- `dolly` (v3, решение пользователя 2026-10-22: старт аэробуксировки с тележки): владелец — TW-15;
  `tools/blender/build_tow_dolly.py` (+ JSON) → `assets/models/world/tow_dolly.glb` (+ `assets/source/world/tow_dolly.blend`);
  узлы `tow_dolly_LOD0`, `tow_dolly_LOD1`, `tow_dolly_LOD2`; треугольники ≤800 / ≤200 / ≤40; начало — на земле под
  центром тележки, −Z — вперёд по ходу; ложемент киля под углом `keel_angle_deg` ≈18° к земле, перекладина для штанги
  ниже 45 см от земли, колёса диаметром ≥10″ (BHPA §2.7.4 G, `docs/research/tow/kinds-bhpa.md`); узлы `tow_dolly_keel`
  (точка опоры киля) и `tow_dolly_bar` (опора штанги) — по ним игра ставит крыло (TW-10); размеры — в JSON с источником.
- Материалы — ≤ 3 на модель, повторно `Hardware`, как `build_start_gear.py`. `python3 tools/check_textures.py` — 0.
- **Инварианты теста:** все glb (`winch`, `release`, `drogue`, `dolly`) грузятся; узлы с указанными именами есть; треугольников LOD0 не больше бюджета.
- v3 (2026-10-22): добавлен `dolly`.
- v2 (2026-10-22): добавлен `drogue`; `winch`/`release` без изменений.
