---
type: "guide"
status: "active"
module: ""
updated: "2026-10-03"
summary: "Как смотреть документацию в Obsidian: корень репозитория как vault, настройки ссылок, frontmatter как свойства."
related: ["docs/INDEX.md"]
---
# Obsidian как просмотрщик документации

Необязательно: удобный просмотр md, граф ссылок и таблица свойств. Правка файлов — как обычно (git); `.obsidian/` в `.gitignore`.

1. Obsidian → «Открыть папку как хранилище» → корень репозитория `deltaplan/`.
2. Настройки → «Файлы и ссылки»: включить **Use Markdown links** (ссылки как в репозитории, а не `[[вики]]`), **New link format → Absolute path in vault**, «Автоматически обновлять внутренние ссылки» включить.
3. Frontmatter показывается как **свойства** (`type`, `status`, `module`, `updated`, `summary`): базы и поиск по `type:guide` работают без настройки.
4. Точка входа — `docs/INDEX.md`; выводы — `docs/registry/findings.md`. Архив `docs/archive/` можно скрыть: «Файлы и ссылки → Исключённые файлы» → `docs/archive`.
