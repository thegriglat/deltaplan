---
type: "contract"
status: "active"
module: "docs-rework"
area: "process"
updated: "2026-10-15"
summary: "Схема документации Deltaplan под dpcli: каталоги docs/, frontmatter (type, status, area), список area, правила разбиения и архива."
related: ["docs/plan/docs-rework.md", ".claude/workflow.md"]
contracts: [{id: "D1", version: 1}, {id: "D2", version: 1}, {id: "D3", version: 1}, {id: "D4", version: 1}]
---

# Контракты docs-rework

Владелец — координатор docs-rework. Потребители — все исполнители модуля, `dpcli docs check|index`, сайт (Hugo mounts в `site/hugo.toml`). Проверка — `.dpcli/dpcli docs check` без ошибок.

## D1. Каталоги docs/ (v1)

| Где | Что | status |
|---|---|---|
| `docs/INDEX.md`, `docs/registry/{research,contracts}.md` | генерирует `dpcli docs index`; руками не править, в задачах не коммитить (собирает координатор в конце) | active |
| `docs/guide/` | как устроена игра **сейчас** — только код, который есть в `main` | active |
| `docs/plan/<м>.md` | живые модули: в работе, идея, отложено | active, idea, postponed |
| `docs/plan/<м>/` | журналы dp/dpcli всех модулей (module.json, tasks/, events.jsonl, decisions.jsonl) — данные, не трогать, кроме `area` в module.json командой `dpcli module init <м> --area <a>` | — |
| `docs/contracts/<м>.md` | стыки живых модулей и действующего кода в main (у сданного модуля — `closed`, стык описывает код как есть) | active, closed |
| `docs/research/`, `tools/research/<тема>/{README,summary}.md` | исследования и эксперименты, в т.ч. отрицательные (материал для статьи — не удалять) | active — вывод применён в игре; closed — завершено; superseded — опровергнуто или заменено |
| `docs/registry/findings.md` | выводы закрытых работ: раздел `## <модуль>`, пункт — одна строка с числами и ссылкой `путь#раздел` | active |
| `docs/archive/` | планы и progress-журналы завершённых и влитых работ (как сейчас) | closed |
| `docs/archive/rejected/` | отклонённое, брошенное, заменённое другим подходом: планы, контракты, гайды | superseded |
| `docs/archive/README.md` | две таблицы: «Влито» (модуль — что в игре — ссылка) и «Отклонено» (модуль — почему — что вместо — ссылка) | — |
| `docs/models/`, `docs/screenshots/`, `docs/.obsidian/` | данные/картинки, не документы | — |

Правила переноса: только `git mv` (история), ничего ценного не удалять; ссылки на перенесённый файл чинить во всех `docs/**/*.md`, `tools/research/**/*.md`, `site/content/**`. `docs/archive/**` в `docs check` не входит.

## D2. Frontmatter (v1)

YAML между `---`, значения — JSON-строки/списки (читают dpcli, Hugo, Obsidian):

```
type: "guide|plan|contract|research|reference|journal|registry"
status: "active|idea|postponed|closed|superseded"
module: "<модуль>"          # имя модуля = имя плана/каталога журнала; у общего документа — ""
area: "<area>"             # D3; обязательно у plan и contract модуля, у guide — желательно
updated: "ГГГГ-ММ-ДД"
summary: "≤140 символов, одна строка: вывод или назначение (не пересказ заголовка, не TODO)"
related: ["путь", …]
# research: conclusion, data, applied_in;  contract: contracts: [{id, version}]
```

- Отклонённое (`superseded`): `summary` начинается с «Отклонено: <почему>»; первая строка тела — `> Отклонено ГГГГ-ММ-ДД: <почему>. Вместо — <ссылка>.` (дата и источник — из журнала решений или CHANGELOG, не выдумывать).
- `status` ставится по коду и git (слито ли в main, есть ли код), а не по тексту документа.

## D3. Area (v1)

Ключ `areas` в `dpcli.yml`; порядок разделов INDEX.md:

| area | что |
|---|---|
| `air` | модель воздуха и атмосферы: ветер, термики, решатели, нейросети/фазы ветра |
| `flight` | крыло, пилот, трапеция, управление, физика полёта, маятник, модели крыльев |
| `world` | рельеф, OSM, места, объекты и вид мира |
| `game` | UI, HUD, старт, камера, меню, QoL, доработки по отзывам |
| `perf` | производительность |
| `net` | сетевая игра |
| `release` | сборки, выпуск, Steam/itch, сайт |
| `process` | процесс разработки: документация, dpcli, агенты |

## D4. Разбиение больших документов (v1)

Лимит — 40 КБ (`docs.max_kb`, ошибка). Документ больше — разбить по смыслу:
- `docs/<кат>/<имя>.md` остаётся входом (оглавление, суть, ссылки на части; ≤ 40 КБ, обычно ≤ 10 КБ) — входящие ссылки на него не ломаются;
- части — `docs/<кат>/<имя>/<часть>.md` (kebab-case по смыслу раздела), у каждой свой frontmatter (тот же `module`, `area`, `type`; `related` — вход), summary — вывод части;
- якоря `<имя>.md#раздел`, на которые ссылаются другие документы, — перенаправить на часть;
- текст не сокращать ради лимита (исследования — материал для статьи); выбрасывать можно только дубли.
- Файлы, подключённые к сайту (D1 и `site/hugo.toml` mounts), после разбиения должны собираться `hugo --minify` в `site/`; раздел про пасхалки (`guide/world-objects.md`, `contracts/easter-eggs.md`) на сайт не попадает — исключение в mounts сохранить и для частей.
