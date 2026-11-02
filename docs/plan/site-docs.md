---
type: plan
status: "active"
module: site-docs
area: release
updated: "2026-11-02"
summary: "Документация сайта (site/content, ru и en) под main после 1.7.0 и pilot-feedback-trim: механики по коду, без удалённых механик."
related: ["docs/contracts/site-docs.md", "docs/contracts/site-i18n.md"]
---

# site-docs — документация сайта под текущий main (код задач SD)

## 1. Цель
Страницы сайта `site/content` (mechanics/, docs/, research/, wings/, approaches.*, _index.*; обе локали ru и en)
описывают игру такой, какая она в `main` (после rust-wind 1.7.0 и pilot-feedback-trim). Каждое утверждение — по коду
и `configs/`, не по старым страницам и не по `docs/guide` без сверки с кодом (часть guide устарела, напр. `air-model*.md`).

## 2. Решения пользователя (не обсуждаются)
Решение 2026-11-02 (`.dpcli/dpcli inbox site-docs`):
- Обновить механики: полёт и управление («Маятник» — единственная физика игрока, мышь/штанга, клавиша X, триммер),
  ветер и воздух (весь расчёт в Rust-крейте на процессоре), дельталёт, буксировка, термики и т. п.
- Удалённые механики не упоминать вообще (ни «было», ни «убрали»): нейросеть ветра (ONNX/air-synth), ветер на
  видеокарте (GPU-ветер), режимы крена weight_shift/rate для игрока и всё прочее, чего нет в `main`.
- Страницы прошлых версий `site/content/releases/<версия>` — исторические, не трогать.
- Публичные тексты: родители — только «родители автора — пилоты», иначе «пилот».
- От главной (2026-11-02): параллельно идёт `trike-fix` (тангаж дельталёта, упор подкоса, вид тележки, трава от винта) —
  страницы о дельталёте писать по `main`; пункты, которые `trike-fix` меняет, в текст не угадывать, а перечислить в отчёте.

## 3. Что известно
- Hugo 0.167 (`site/hugo.toml`); `docs/guide`, `docs/contracts`, `docs/research`, `registry/findings.md` подключены
  на сайт как есть (mounts, только ru). Сборка сейчас падает: frontmatter `docs/research/pilot-feedback-trim/mouse.md`
  (двоеточие в `summary` без кавычек) — K4 `tools/site/check_i18n.py`.
- Контрактный тест сайта — `tools/site/check_i18n.py` (SI-К1…К5, `--pages=` для своих страниц): пары переводов,
  сборка без WARN/ERROR, живые внутренние ссылки, кириллица в en.
- Страницы крыльев генерирует `tools/site/gen_wings.py`; `--check` падает на `trike_ixess15` (группа `tug`): нет
  раздела в `docs/research/glider_3d_tz.md`, нет рендера `docs/models/screenshots/glider_trike_ixess15/iso45.jpg`
  (рендер — `tools/blender/render_wings_site.sh <id>`, Blender есть).
- На сайте нет страницы про дельталёт и буксировку.
- `approaches.*` и `research/_index.*` — история пробованных подходов (нейросеть P1–P3, Пикар на GPU) — шлюз Q1.

## 4. Задачи
Все тексты — контракт SD-К1. Тип `dp-writer` (sonnet), если не указано иначе.
- **SD-1** (dp-mechanic) — сборка сайта: кавычки в frontmatter `docs/research/pilot-feedback-trim/*.md`, чтобы hugo
  собирался; другие причины падения — blocked. Приёмка: `check_i18n.py` 0.
- **SD-2** — полёт и управление: `mechanics/flight`, `mechanics/visual-cues`, `mechanics/motion-platform`.
- **SD-3** — игроку: `docs/player-guide`, `docs/training`, `docs/goals`, `docs/_index`, `mechanics/training-islands`,
  `mechanics/launch-camp`; управление дельталётом — по main, без ссылки на новую страницу (её даёт SD-10).
- **SD-4** — воздух, поле: `mechanics/air-model/_index`, `wind-phases`, `heuristic` (есть ли режим в main — по коду;
  нет — страницу удалить, ссылки на неё в своих файлах убрать; прочие ссылки — SD-10).
- **SD-5** — воздух, термики и болтанка: `mechanics/air-model/thermals`, `turbulence`.
- **SD-6** — погода, облака, рельеф: `mechanics/weather`, `mechanics/clouds`, `mechanics/terrain`.
- **SD-7** — приборы, боты, сеть: `mechanics/instruments`, `mechanics/bots`, `mechanics/multiplayer`.
- **SD-8** — новая страница `mechanics/trike/` (дельталёт игрока и буксировка за дельталётом), ru и en.
- **SD-9** (dp-engineer) — крылья: `gen_wings.py --check` 0 с крылом `trike_ixess15` (группа `tug`), рендер iso45.
- **SD-10** — после SD-2…SD-8 и Q1: `_index`, `mechanics/_index`, `approaches`, `research/_index`, перекрёстные
  ссылки (на `mechanics/trike/`, снятая `heuristic`), итоговый прогон проверок по всему сайту.

## 5. Волны
1. SD-1 (быстро, до остальных — от него зависит сборка в проверках) и шлюзы Q1/Q2.
2. SD-2…SD-9 параллельно (у каждой задачи свои файлы).
3. SD-10 → `site-docs done`.

## 6. Условия остановки (шлюз)
- Страница описывает то, чего в main нет, а убрать — значит снять раздел/страницу целиком сверх плана — шлюз.
- Код и `configs` противоречат друг другу или guide по существу так, что «как в игре» не определить — шлюз (не угадывать).
- Нужна правка кода игры или `docs/guide` — вне модуля, шлюз.
