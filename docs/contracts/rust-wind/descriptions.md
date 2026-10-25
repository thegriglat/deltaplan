---
type: "contract"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-26"
summary: "W6 rust-wind: описания — ядра подъёма, облака, растр облаков, гребни волн; поля, шаги, инвариант найденного ядра."
related: ["docs/contracts/rust-wind.md", "docs/plan/rust-wind.md"]
contracts: [{"id": "W6", "version": 3}]
---

# W6. Описания — найденное, а не заданное (v3)

Часть `docs/contracts/rust-wind.md` (версия — там, заголовок W6). Менять — только координатор.
Владелец — RW-2 (из текущего кода), RW-10/RW-11 (из крейта). Потребители — `cloud_layer.gd`, `bird_flock.gd`, `thermal_signs.gd`, `bot_pilots.gd`, `easter_eggs/group.gd`, `debug_overlays.gd`, `terrain_wind.gd`, `atmo_fingerprint.gd`, `dust_devils.gd`.
Описания — плоские `PackedFloat32Array` с шагом; поля — по смещениям-константам фасада. Целые (id, флаги, сид) — точные в f32 до 2²⁴. У формульной модели описание — её список; у живой — поиск в поле. Инвариант (T6, v3): у ядра подъёма **без флага Cb и с `w ≥ 1,5 м/с`** средний `vy` по `sample_many` в круге `0,5·radius` на высоте `(y_src + top)/2` больше среднего `vy` в кольце `2–3·radius` на той же высоте (ядро — местный избыток подъёма; фон — волна, опускание, сток — может быть любым). Слабые ядра (`w < 1,5 м/с`: зарождение, распад) отдаются, но их подъём на фоне может быть неразличим (RW-2: 8 из 92 ядер с `w` 0,06–1,41 м/с) — потребители, которым нужен заметный подъём, фильтруют по `w`. **Охват (v3):** ядра отдаются там, где реализация держит детализацию — вокруг фокусов (у `gd` — активные термики `ThermalField` в радиусе физики ~6 км от фокуса); дальше ядра могут отсутствовать. Ядра Cb (бит 2) под инвариант не подпадают: под ними нисходящий поток ливня (RW-1: −1,3…−2,5 м/с на оси при `w` 3–4 м/с).

- **Ядра подъёма** `cores(center: Vector3, radius: float) -> PackedFloat32Array`, `CORE_STRIDE = 15`, ядра с осью ближе `radius` к `center` по горизонтали:
  `0 id` (целое в `[0, 2²⁴)`, стабильно, пока ядро живо; v2 — реализация `gd` берёт хеш `& 0xFFFFFF`; фикстуры W8 v1 сняты с 32-битным хешем, не точным в f32, — сверка ядер по ближайшему) · `1 flags` (бит 0 — статическое, 1 — есть облако, 2 — грозовое Cb) · `2 x`, `3 z` (м, ось у земли сейчас, со сносом) · `4 y_src` (м MSL, земля у оси) · `5 top` (м MSL, верх) · `6 w` (м/с, пиковый подъём сейчас, с огибающей жизни) · `7 radius` (м, у верха) · `8 lean_x`, `9 lean_z` (наклон оси, м/м высоты: ось на высоте y — `(x, z) + lean·(y − y_src)`) · `10 age_s` · `11 life_s` (ожидаемая жизнь; живой воздух — NaN) · `12 stage` (0..3 непрерывно: 0–1 рост, 1–2 зрелость, 2–3 распад) · `13 vis_seed` (сид для отрисовки) · `14 storm` (0..1, сила грозы у Cb, иначе 0).
- **Облака** `clouds(center, radius) -> PackedFloat32Array`, `CLOUD_STRIDE = 10`:
  `0 id` · `1 core_id` (−1 — нет) · `2 x`, `3 z` (м, центр сейчас) · `4 base_msl`, `5 top_msl` · `6 radius` (м) · `7 growth` 0..1 · `8 decay` 0..1 · `9 flags` (бит 2 — Cb). Сейчас — `cloud_phys.visible_clouds(...)` (`cloud_physics.gd:431`) + геометрия.
- **Растр облаков** `cloud_raster() -> Dictionary` — `{version: int, nx, ny: int, dx: float, x0, z0: float (W1; сейчас CloudField x0/y0 — пересчитать в оси W1), base_msl: float, time_s: float, cover, depth, stage, activity, bg_cover, bg_depth: PackedFloat32Array (nx·ny, строка — к +Z)}`; `cloud_raster_version() -> int` — растёт при обновлении (вместо `field_version`/`signature()`/`poll()`). Нет поля облаков — `{version: 0}`.
- **Гребни волн** `wave_crests(center: Vector2 (x, z), radius, min_eta, spacing) -> PackedFloat32Array`, `CREST_STRIDE = 4`: `0 x`, `1 z`, `2 eta`, `3 crest` — как `wave_field.gd:136`; волн нет — пусто.
- **База облаков** — `cloudbase_msl()` (W2).
- Логика выбора и отрисовки облаков (`cloud_phys.model.select/merge_winners/stage`) — сторона Godot или крейт — решает RW-11 первым шагом (разбор границы); недостающие поля добавляются W6 v2, до этого `cloud_layer.gd` в RW-3 переводится на то, что есть, без потери вида — иначе `<ID> blocked` с перечнем полей.
- Запись во внутренности (`atmosphere_preview.gd` правит `t_birth`, `cloud_depth` и т. п.) не поддерживается: превью пользуется `set_static_thermals`, `set_conditions` и `start_at`.

