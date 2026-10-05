# Иконки ачивок Steam (SA-7)

Пакетная детерминированная генерация иконок 256×256 (открыта `<API>.jpg`, закрыта `<API>_locked.jpg`) на локальной NVIDIA. Контракт — SA-К4 v3 (`docs/contracts/steam-assets.md`). **На момент записи модель не скачивалась и GPU не запускался**: проверен только режим `--dry` и Pillow-часть (уменьшение, закрытая версия).

## Выбор модели

Требование пользователя (05.10.2026): лицензия разрешает коммерческое использование результата (игра продаётся в Steam); 12 ГБ VRAM (RTX 4070 SUPER); пиктограммы читаются в 64 px, без букв.

| Кандидат | Лицензия (первоисточник) | Выходы в коммерческих целях | 12 ГБ VRAM | Пиктограммы |
|---|---|---|---|---|
| **FLUX.1-schnell** (`black-forest-labs/FLUX.1-schnell`) | Apache-2.0 — [карточка](https://huggingface.co/black-forest-labs/FLUX.1-schnell), поле `license: apache-2.0` (HF API) | да, без ограничений Apache-2.0 | 12 млрд параметров: bf16 ≈ 24 ГБ, поэтому transformer и T5 в nf4 (bitsandbytes) + выгрузка на CPU ≈ 8–10 ГБ (оценка, не измерено) | лучшая из кандидатов: чистые формы, хорошо слушается длинных промптов; 4 шага |
| SDXL base 1.0 (`stabilityai/stable-diffusion-xl-base-1.0`) | CreativeML Open RAIL++-M — [текст](https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/blob/main/LICENSE.md) | да; Лицензиар не претендует на права на выходы (раздел «The Output You Generate»), но есть список запрещённых применений, который надо передавать дальше | fp16 ≈ 7 ГБ, без квантования | хуже следует «простым плоским» промптам, больше мусора; запасной вариант |
| SD 3.5 Large/Medium | Stability AI Community License — [текст](https://stability.ai/community-license-agreement) | да до 1 млн USD годовой выручки организации, выше — платная лицензия и регистрация | Large — с квантованием, Medium — влезает | хорошее, но условие по выручке и регистрация — лишний риск |
| FLUX.1-dev | FLUX.1 [dev] Non-Commercial License | **нет** (для выходов есть оговорка, но модель для коммерческих целей не лицензирована) | — | исключена по условию задачи |

**Выбор — FLUX.1-schnell**: чистая Apache-2.0 без порогов и списков, лучшее качество плоских пиктограмм. Модель на Hugging Face с автоматическим доступом (`gated: auto`): нужна учётная запись HF, один раз принять условия на странице модели и `huggingface-cli login` (токен чтения). Запасной вариант без логина — SDXL base 1.0 (ревизия `462165984030d82259a11f4367a4eed129e94a7b`); для него скрипт пришлось бы дописать (другой pipeline, есть настоящий negative) — не делалось.

Закреплено: repo `black-forest-labs/FLUX.1-schnell`, ревизия `741f7c3ce8b383c54771c7003378a50191e9efe9` (последняя на 05.10.2026, `lastModified` 2024-08-16) — в `prompts.json → model`.

Лицензия самих картинок: сгенерированные иконки — наши, права Лицензиара на выходы Apache-2.0 не предъявляет; ASSETS.md фиксирует модель и ревизию.

## Стиль

Единый общий промпт `style` (плоский векторный значок на круглой эмблеме, толстый контур, 4 цвета: тёмно-синий, голубой, оранжевый, кремовый; один крупный символ по центру; без текста, букв, цифр, логотипов; крыло — обобщённый неподписанный треугольный дельтаплан без узнаваемой марки) + `subject` каждой ачивки. У каждой иконки свой `seed`. FLUX.1-schnell — дистиллированная модель без CFG: `guidance=0.0`, поле `negative` контракта хранится в файле, но моделью не используется (запрет текста и логотипов держится на позитивном промпте). Тема — только дельтапланеризм. Сразу после первого запуска стиль смотрит пользователь; промпты правятся в `prompts.json`, перегенерация — `--force`.

## Установка и запуск (позже, когда GPU свободен)

```bash
cd tools/store/achievements
uv sync                       # версии закреплены в pyproject.toml / uv.lock (~10 ГБ с torch+CUDA)
huggingface-cli login         # один раз, см. выше
cd ../../..
flock /tmp/heat_ca_gpu.lock tools/store/achievements/.venv/bin/python tools/store/achievement_icons.py \
  --config configs/achievements.json --prompts tools/store/achievements/prompts.json \
  --out steam/store/achievements
```

Модель скачивается при первом запуске (~34 ГБ в кэш HF, один раз; можно заранее `huggingface-cli download black-forest-labs/FLUX.1-schnell --revision 741f7c3c…`). Исходные PNG 1024×1024 кэшируются в `tools/store/achievements/.cache/` (в git нет), ключ кэша зависит от ревизии, промпта, seed, размера, шагов; повторный запуск без изменений модель не грузит. Опции: `--only ACH_X` (повтор), `--force`, `--cache DIR`. Результат: `<API>.jpg`, `<API>_locked.jpg`, `manifest.json`. Закрытая версия — из открытой 256×256 Pillow: оттенки серого × яркость 0,55; модель не нужна.

## Проверка без GPU

```bash
python3 tools/store/achievement_icons.py --config tools/store/achievements/fixture_achievements.json \
  --prompts tools/store/achievements/prompts.json --out /tmp/sa7_icons --dry     # ICONS PLAN ok=38 missing=0
python3 tools/store/achievement_icons.py --config tools/store/achievements/fixture_missing.json \
  --prompts tools/store/achievements/prompts.json --out /tmp/sa7_icons --dry     # missing=1, код 1
```

## Файлы

- `prompts.json` — модель, стиль, 38 промптов по финальному `configs/achievements.json` модуля steam (коммит ba0145fa); скрытые ачивки — нейтральные короткие subject.
- `fixture_achievements.json` — подставной конфиг формата S6 (18 ачивок; `name`/`desc` en — наши краткие формулировки, `rule` — заглушка). `fixture_missing.json` — он же + `ACH_TEST_NO_PROMPT`.
- Финальный `configs/achievements.json` — модуль steam (38 ачивок); новые ачивки → дописать `icons` в `prompts.json` (`--dry` покажет `missing`).

## Границы и неизвестное

Версии зависимостей разрешены `uv lock` (разрешаются без конфликтов), но реальный запуск на GPU не выполнялся: API `diffusers`/`bitsandbytes` для nf4 FLUX, расход VRAM и качество пиктограмм в 64 px не проверены. При нехватке VRAM — `pipe.enable_sequential_cpu_offload()` вместо `enable_model_cpu_offload()`. Детерминизм: seed на CPU-генераторе, одна и та же связка версий и GPU даёт те же картинки; между разными GPU/версиями возможны небольшие отличия.
