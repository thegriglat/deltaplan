---
type: contract
status: "active"
module: cloud-look
area: world
updated: "2026-10-23"
summary: "Стыки cloud-look: стенд кадров меню (CLK-К1), границы правки отрисовки облаков (CLK-К2), цена прохода облаков (CLK-К3)."
related: ["docs/plan/cloud-look.md", "docs/contracts/cloud-field.md", "docs/contracts/perf.md", "docs/contracts/haze-humidity.md", "docs/guide/atmosphere/clouds.md"]
contracts: [{"id": "CLK-К1", "version": 1}, {"id": "CLK-К2", "version": 1}, {"id": "CLK-К3", "version": 1}]
---
# Контракты cloud-look

## CLK-К1 v1 — стенд кадров меню
- Владелец: координатор. Потребители: все задачи модуля (кадры «до/после»), итоговые кадры для пользователя.
- Кадры — `tools/shots/menu_art.py --only=<номера> --size=<ШxВ> --out=<каталог>`, всегда под замком:
  `.dpcli/dpcli lock cpu <имя> -- python3 tools/shots/menu_art.py …` (долгий прогон — `.dpcli/dpcli job --lock cpu start …`).
  Номера проверки модуля: 06, 09, 12, 17, 26, 30, 34, 35, 37 (решение пользователя 2026-10-23). 40–45 (тени) не снимать.
- `tools/shots/menu_art.json` и `tools/shots/menu_background.json` не меняются (сюжеты, ракурсы, свет, номера);
  sha256 `menu_art.json` = `b0a066f1789bb1452145d9f6dbf224c62ad809d18f44367f8ea313da612dcb44`.
- Кадры «до» в 4K — `/home/greg/deltaplan/build/shots-menu4k/NN_*.png` (main 78e5267b2, = база модуля).
- Итерации задачи — 1920×1080 (`--size=1920x1080`, JPEG): кадр «до» той же ширины снимается из своей копии до правок
  (размер буфера облаков зависит от разрешения, PF-К2 — 4K-кадры с 1080p не сравнивать). Итог задачи — 3840×2160 только
  своих номеров.
- Кадры задачи — `/home/greg/deltaplan/build/screenshots/cloud-look/<ID>/` (`before_1080/`, `after_1080/`, `after_4k/`),
  в git не идут.
- Итог модуля (последняя задача): все 9 номеров 3840×2160 с ветки модуля → `/home/greg/deltaplan/build/screenshots/cloud-look/after_4k/`
  и пары «до | после» рядом `…/cloud-look/compare/NN.jpg` (JPEG q88, ширина 3840, каждая половина 1920×1080).
- Контрактный тест `tests/contracts/test_cloud_look_contracts.gd`: sha256 `menu_art.json` равен записанному.

## CLK-К2 v1 — границы правки отрисовки облаков
- Владельцы: свет — CLK-1, форма/плотность — CLK-2, дальнее поле — CLK-3, перистые — CLK-4, экспозиция — CLK-5.
- Неизменно (правка — только шлюз, план §5): поле облачности CLF-К1…К6 (`scripts/atmosphere/cloud_field*.gd`, `cloud_physics.gd`,
  `cloud_model.gd`, физика термиков, `CloudField.density_at/shade_at`), формат текстуры поля CLF-К2 и имена `cf_rect`, `cf_base`, `cf_edge`;
  модель атмосферы и солнца haze-humidity: таблица пропускания `SunTransmission` и смысл `cloud_sun_l(y)` (HH4: `sun_toa·T/T_ref`),
  `sky_k`, `time.light.*`, дымка по влажности; тени облаков (`cloud_shadow_map.*`, `scripts/terrain/cloud_shadow.gdshaderinc`) —
  пункт 9 вне модуля, но тень берёт ту же плотность (`cloud_common.gdshaderinc`) — правка плотности не должна ломать тесты теней.
- PF-К2 (поля пресетов качества, `buffer_size`) — поля и формула не меняются; значения пресетов — только с замером CLK-К3 и
  строкой в отчёте.
- Общие файлы — по блокам: в `scripts/atmosphere/cloud_common.gdshaderinc` CLK-1 правит свет (`cloud_hg`, `cloud_light`,
  `cloud_sun_*`, вычисление света/пропускания к солнцу и неба внутри `cloud_march_part`), CLK-2 — форму и плотность
  (`cloud_init_towers`, `cloud_towers`, `cloud_top_at`, `cloud_envelope`, `cloud_density_raw`, `cloud_density`, `cloud_lod`,
  `cf_threshold`, `cf_qv`, шаг основного луча в `cloud_march_part`); в `cloud_raymarch_cs.gdshaderinc` (`field_march`) — так же.
  Новые uniform-ы и ключи — рядом с родственными (`configs/atmosphere.json → clouds.*`), не в конец файла. Правка чужого блока —
  сообщение координатору `<ID> contract: …`, не молча.
- Число шагов луча и выборок света сверх нынешних пресетов — только с замером CLK-К3 в отчёте.

## CLK-К3 v1 — цена прохода облаков
- Владелец: координатор (замер — итоговая задача модуля; задача, добавившая шаги/выборки, — свой замер).
- Метод — как CLF-7 (`docs/perf/frame_profile/cloud-field.md` → «Как мерили»): `tools/bench/frame_profile.sh` под
  `.dpcli/dpcli lock gpu`, 1920×1080, пресеты medium и high, Онгудай, `--hour=12 --temp=30 --wind=3 --world-t=5400 --air-start`,
  `SKIP_FLY=1`; величина — медиана прохода «Process Post Transparent Compositor Effects» и GPU кадра.
- База — `feature/cloud-look` на старте модуля (f2721ef86 = main 78e5267b2 + план), против — ветка задачи/модуля, тот же стенд подряд.
- Порог: проход облаков на high ≤ база + max(0,3 мс; 30 %); больше — шлюз (план §5), не «оптимизация на глаз».
