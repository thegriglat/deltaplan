---
type: "contract"
status: "active"
module: "site-i18n"
updated: "2026-10-05"
summary: "Контракты модуля site-i18n: языки и URL-схема сайта (en в корне, ru под /ru/), файлы переводов по суффиксу, ключи i18n, ссылки между языками, правила английских текстов, генератор крыльев на два языка."
related: ["docs/plan/site-i18n.md", "tools/site/check_i18n.py"]
contracts: [{"id": "SI-К1", "version": 2}, {"id": "SI-К2", "version": 1}, {"id": "SI-К3", "version": 2}, {"id": "SI-К4", "version": 3}, {"id": "SI-К5", "version": 1}, {"id": "SI-К6", "version": 1}]
---
# Контракты модуля site-i18n

План — `docs/plan/site-i18n.md`. Менять — только через координатора (версия +1, что изменилось, уведомить потребителей).

История: v3 SI-К4 и v2 SI-К3 (05.10) — явные id якорей между страницами; подписи галереи en из `captions`. v2 SI-К1/SI-К4 (05.10, по SI-1) — `label` вместо `languageName`, монтирования через `sites.matrix` вместо устаревшего `lang`, редирект Hugo `/en/` допустим, сборка проверяется без `--quiet`.
Контрактный тест — `python3 tools/site/check_i18n.py [--only=K1,…] [--pages=префикс,…] [--allow-missing]`
(K1…K5 ↔ SI-К1…SI-К5; без сети; собирает сайт `hugo` во временный каталог, ~4 с).

## SI-К1. Языки и URL-схема (v2)
Владелец: SI-1. Потребители: все задачи, README, скилл new-release, `.github/workflows/pages.yml`.
- `site/hugo.toml`: `defaultContentLanguage = 'en'`, `defaultContentLanguageInSubdir = false`;
  `[languages.en]` (weight 1, `label = 'English'`, locale `en-US`) и `[languages.ru]` (weight 2, `label = 'Русский'`, locale `ru-RU`); других языков нет; `contentDir` у языков не задаётся.
- Адреса: en — корень `https://thegriglat.github.io/deltaplan/<путь>/`, ru — `https://thegriglat.github.io/deltaplan/ru/<путь>/`; `<путь>` у перевода тот же, что у оригинала (имя файла без суффикса языка). Каталога `/en/` нет, кроме того, что Hugo пишет всегда: `/en/index.html` (редирект на корень) и `/en/sitemap.xml`.
- Параметры, зависящие от языка (`description`, `BookDateFormat`: en `Jan 2, 2006`, ru `02.01.2006`), — в `[languages.<lang>.params]`; общие (`repoBlob`, `repoMap`, `itch`, …) — в `[params]`.
- Документы репозитория, подключённые монтированием (`../docs/**`, `../tools/research/**` → `content/…`), — **только русские**: у каждого такого монтирования `[module.mounts.sites.matrix] languages = ['ru']` (`lang` устарел в Hugo 0.153 и даёт WARN); в en-сайте их страниц нет (адреса только `/ru/docs/…`, `/ru/plans/…`, `/ru/research/…`). Решение координатора 05.10: это рабочие документы (~3,5 МБ), правятся ежедневно, перевод устареет.
- `.github/workflows/pages.yml` собирает оба языка одной командой `hugo --minify` (без изменений адреса публикации).

## SI-К2. Файлы содержимого по языкам (v1)
Владелец: SI-1 (переименование), SI-2 (крылья). Потребители: задачи перевода, скилл new-release, `gen_wings.py`.
- Перевод — **по суффиксу имени файла** рядом с оригиналом: каждая страница `site/content/<база>.md` становится `<база>.ru.md` (русский текст как был) и получает `<база>.en.md` (английский). Бандлы: `index.ru.md`/`index.en.md`, `_index.ru.md`/`_index.en.md`.
- Ресурсы бандла (скриншоты, `devlog.txt`, `devlog.md` старых версий, картинки) — **один экземпляр, без суффикса**, общий для языков; имена файлов не переводятся и не переименовываются.
- Файл `.md` без суффикса языка в `site/content` запрещён (кроме `releases/*/devlog.md` — ресурс).
- Frontmatter перевода: те же ключи, что у ru; переводятся `title`, `linkTitle`, `description`, подписи; **совпадают** `weight`, `date`, `cover`, `type`, `layout`, `bookHidden`, `bookCollapseSection`, `bookFlatSection` (проверяет K2).
- Дата записи дневника — по-прежнему из имени файла (`2026-10-04.ru.md` / `2026-10-04.en.md`).

## SI-К3. Строки интерфейса (v2)
Владелец: SI-1. Потребители: шаблоны, шорткоды.
- `site/i18n/en.yaml` и `site/i18n/ru.yaml` — один и тот же набор `id` (проверяет K3). Ключи темы hugo-book, которые переопределяем (`Edit this page`, `Search`, …), — в обоих файлах; свои ключи — с префиксом `dp` в lowerCamelCase (`dpDevlogItch`, `dpInRussian`, …).
- В `site/layouts/**` нет кириллицы вне комментариев шаблона/HTML — все видимые строки через `i18n` (или из frontmatter/параметров языка).
- Шорткоды, перечисляющие страницы (`releases`, `latest-release`, `children`, `gallery`, …), работают в текущем языке.
- `gallery`: подпись и `alt` картинки — из карты `captions` во frontmatter страницы (`captions: {"01_имя.jpg": "English caption", …}`, ключ — имя файла ресурса без каталога), если ключа нет — из имени файла, как раньше. У en-страниц с `{{< gallery >}}` карта `captions` есть для каждой картинки галереи; у ru-страниц не нужна.

## SI-К4. Ссылки и картинки между языками (v3)
Владелец: SI-1 (`site/layouts/_partials/repo/resolve.html`, `_markup/render-link.html`, `render-image.html`). Потребители: все страницы.
- Ссылки в markdown пишутся одинаково в ru и en (те же цели: `/mechanics/flight/`, относительные пути к файлам репозитория, `../../docs/guide/x.md`). Резолвер ищет страницу **в языке страницы**, если нет — **в другом языке** (документы репозитория → ru) и ведёт на её адрес; такой межъязыковой ссылке на en-странице добавляется пометка `i18n "dpInRussian"` (англ. « (in Russian)»). Файл репозитория без страницы — как раньше (картинка/HTML публикуется, иначе GitHub).
- Якоря в ссылках на **другие** страницы сайта (`/mechanics/bots/#…`, `/#…`) — явные латинские id у заголовка цели, одинаковые в ru и en: `## Очередь на старт {#start-queue}` / `## Start queue {#start-queue}`; ссылка — `/mechanics/bots/#start-queue` в обоих языках. Якоря внутри страницы (`#…` без пути) — автоматические, по своему языку. Проверка — `check_i18n.py --only=K4 --fragments` (итог модуля).
- Картинки бандла — одни для обоих языков; `![подпись](screenshots/01_….jpg)` работает из `index.en.md` и `index.ru.md`.
- Переключатель языка — в меню темы (partial `docs/languages`), ведёт на перевод страницы, при его отсутствии — на главную другого языка; `<link rel="alternate" hreflang>` — у переведённых страниц.
- Инвариант (K4): `hugo` (без `--quiet`) без WARN/ERROR, в т. ч. предупреждений об устаревшем; во всех собранных страницах обоих языков нет битых внутренних ссылок и картинок; `/index.html` — `lang="en…"`, `/ru/index.html` — `lang="ru…"`.

## SI-К5. Английский текст (v1)
Владелец: задачи перевода. Потребители: читатели сайта.
- Только факты русского оригинала: ничего не добавлять и не убирать, числа и единицы — как в оригинале (десятичная запятая → точка), ссылки и картинки — те же. Структура (заголовки, таблицы, списки, шорткоды) — та же.
- Названия пунктов меню и кнопок игры — как в английском интерфейсе игры: `locale/ui.csv` (колонка `en` по русской строке).
- Термины: дельтаплан — hang glider; крыло — wing; трапеция — control frame; база трапеции — basebar; стойки — uprights; киль — keel; поперечина — crossbar (жёсткая/плавающая — fixed/floating); мачтовое/безмачтовое — kingposted/topless; учебное — trainer; подвеска — hang point; термик — thermal; динамический поток у склона — ridge lift; вариометр — variometer; решатель — solver; нейросеть ветра — wind neural network; рельеф — terrain; пилот — pilot.
- Публичные тексты: про родителей автора — только «the author's parents are hang glider pilots»; иначе «a pilot»; пасхалки не упоминать; семейного и личного нет (K5 ищет mom/mother/dad/father/easter egg).
- Инвариант (K5): в тексте статьи собранной en-страницы кириллица — не больше 3 % букв (собственные имена латиницей; ссылки на русские документы — с пометкой SI-К4).

## SI-К6. Генератор страниц крыльев на два языка (v1)
Владелец: SI-2 (`tools/site/gen_wings.py`). Потребители: `site/content/wings/**`, `tools/site/check_contracts.py` (C2).
- Пишет `wings/<group>/<id>.ru.md` (как раньше) и `wings/<group>/<id>.en.md` (те же числа, источники, отметки происхождения — по-английски: passport / analog / estimate); в `wings/_index.{ru,en}.md` и `wings/<group>/_index.{ru,en}.md` меняет только блок GEN_BEGIN/GEN_END, ручной текст вне блока — у переводчика.
- Названия крыльев и групп в en — из `locale/ui.csv` (колонка `en`), в ru — как раньше.
- `python3 tools/site/gen_wings.py --check` — код 0 на обоих языках; `tools/site/check_contracts.py --only=C2` проходит.
