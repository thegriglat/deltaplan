---
type: contract
status: "active"
module: sail-texture
area: game
updated: "2026-11-05"
summary: "SLT-К1: хранение своей картинки паруса в user:// (SailTexture); SLT-К2: наложение на парус игрока (SailMaterial.set_custom)."
related: ["docs/plan/sail-texture.md", "docs/guide/models/wings.md", "docs/guide/models.md"]
contracts: [{"id": "SLT-К1", "version": 1}, {"id": "SLT-К2", "version": 1}]
---
# Контракты модуля sail-texture

Своя картинка паруса — только у игрока и только локально (решение 2026-11-05): по сети не передаётся,
вид ботов и чужих пилотов (`BotGlider`, `RemotePilots`, `bots.json → visual.sail_schemes`) не меняется.

## SLT-К1. Хранение картинки — версия 1

- Владелец: SLT-2. Потребители: `scripts/ui/flight_setup_screen.gd` (выбор, предпросмотр, сброс — SLT-2),
  `scripts/flight/glider.gd` (наложение — SLT-3, SLT-К2). Тест: `tests/contracts/test_sail_texture_contracts.gd`.
- Файл `scripts/game/sail_texture.gd`, `class_name SailTexture extends RefCounted`, только статические члены:
  - `const DEFAULT_PATH := "user://sail_texture.png"`; `static var path := DEFAULT_PATH` — тесты подменяют
    (свой каталог в `user://`), в конце возвращают `DEFAULT_PATH`.
  - `const MAX_FILE_BYTES := 20 * 1024 * 1024` — больше — отказ без чтения картинки.
  - `const MIN_SIDE_PX := 16`, `const MAX_INPUT_SIDE_PX := 16384` — меньшая сторона < MIN или большая > MAX_INPUT — отказ.
  - `const MAX_SIDE_PX := 2048` — сохранённая картинка: большая сторона ≤ 2048, пропорции исходные
    (уменьшение `Image.INTERPOLATE_LANCZOS`; меньше 2048 — не увеличивать).
  - `static func prepare(src_path: String) -> Dictionary` → `{"error": String, "image": Image}`:
    `src_path` — абсолютный путь в файловой системе (или `user://`/`res://`). Формат — по содержимому
    (сигнатура PNG `89 50 4E 47` / JPEG `FF D8 FF`), не по расширению. Успех: `error == ""`, `image` —
    `Image.FORMAT_RGBA8`, без мипмапов, уменьшенная до `MAX_SIDE_PX`. Отказ: `image == null`, `error` — ключ
    `locale/ui.csv`: `sail_tex_err_read` (нет файла / не читается), `sail_tex_err_format` (не PNG/JPEG или не
    декодируется), `sail_tex_err_too_big` (файл > MAX_FILE_BYTES или сторона > MAX_INPUT_SIDE_PX),
    `sail_tex_err_too_small` (сторона < MIN_SIDE_PX). Файл профиля не трогает.
  - `static func save(img: Image) -> bool` — PNG в `path` через временный `path + ".tmp"` и переименование;
    неудача — `false`, прежний файл цел. Каталог `path` создаёт сам.
  - `static func import_file(src_path: String) -> String` — `prepare` + `save`; `""` или ключ ошибки
    (`sail_tex_err_write` — не записалось). При ошибке прежний файл цел.
  - `static func has_custom() -> bool` — файл `path` есть.
  - `static func load_texture() -> ImageTexture` — картинка из `path` с мипмапами (`generate_mipmaps`);
    нет файла — `null` молча; файл битый — `null` и `push_warning`.
  - `static func clear() -> void` — удалить `path` (нет файла — ничего).
- Есть файл `path` — значит, своя картинка включена; отдельного ключа настроек нет. В Steam Cloud не входит
  (`steam/partner/auto_cloud.json` не меняется).
- Экран «Полёт…» (вкладка «Аппарат», под выбором модели крыла): «Выбрать…» (FileDialog: `FILE_MODE_OPEN_FILE`,
  `ACCESS_FILESYSTEM`, фильтры `*.png, *.jpg, *.jpeg`), «Родная» (сброс), предпросмотр, строка ошибки `tr(error)`.
  Выбор и сброс — отложенные, как всё на экране: «Готово» — `save(image)` или `clear()`; «Назад» — профиль без изменений.

## SLT-К2. Наложение на парус игрока — версия 1

- Владелец: SLT-3. Потребитель: `scripts/flight/glider.gd` (визуал игрока). Боты и чужие (`scripts/game/bot_glider.gd`,
  `scripts/game/remote_pilots.gd`) не вызывают. Тест: `tests/contracts/test_sail_texture_contracts.gd` (раздел К2).
- `SailMaterial.set_custom(mat: ShaderMaterial, tex: Texture2D) -> void` (`assets/shaders/sail/sail_material.gd`):
  `mat == null` — ничего; `tex == null` — родная текстура (как без вызова). Вызов — в `Glider` после `visual.build(...)`:
  `SailMaterial.set_custom(visual.sail_material, SailTexture.load_texture())`.
- `SailMaterial.apply(...)` дополнительно ставит uniform'ы аспекта обшивок из меша `Sail` (для всех крыльев, в т.ч. ботов —
  без своей картинки они ничего не меняют): `custom_aspect_top`, `custom_aspect_bottom` (float, размах / корневая хорда
  этой обшивки, м/м; обшивка — по UV1: верх `UV.y > 0.5`, низ `UV.y < 0.5`; карман киля не входит).
- Uniform'ы шейдера `assets/shaders/sail/sail.gdshader`: `custom_tex : source_color, filter_linear_mipmap_anisotropic`,
  `custom_on : float` (0 — родная, 1 — своя), `custom_img_aspect : float` (w/h картинки) — ставит `set_custom`.
- Раскладка (решение координатора 2026-11-05, по SLT-1 `tools/research/sail-texture/README.md`):
  - координаты обшивки по UV1 (как приходит в Godot): `s = UV.x` (0 — левая законцовка, −X модели);
    верх (`UV.y > 0.5`): `q = 2·(1 − UV.y)`; низ (`UV.y < 0.5`): `q = 2·(0.5 − UV.y)`; q = 0 — передняя кромка, 1 — задняя;
  - верх, взгляд сверху (нос вверху экрана): `(a, b) = (s, q)`; низ, взгляд снизу: `(a, b) = (1 − s, q)` —
    обе читаются снаружи не зеркально, верх картинки (b = 0) — у передней кромки;
  - вписать по центру с сохранением пропорций: `A` — аспект обшивки, `r = custom_img_aspect`;
    `A ≥ r`: `a' = (a − 0.5)·A/r + 0.5`, `b' = b`; `A < r`: `a' = a`, `b' = (b − 0.5)·r/A + 0.5`;
    вне `[0,1]²` — родная текстура;
  - смешение: `albedo = mix(родное, custom.rgb, custom.a · внутри)`; к своей картинке `albedo_tint`, `hue_shift_rad`,
    `sat_scale`, `value_scale` не применяются; нормали, просвечивание, анимация (UV2), тени — как с родной;
  - карман киля (8 моделей, вертикальная плоскость x = 0) — родная текстура (признак — по нормали/вершине, не по UV.x фрагмента).
- Проверка ориентации — по геометрии меша (какая законцовка у пилота справа, где нос), не по допущению; визуально —
  тестовая сборка Linux у главной сессии.
