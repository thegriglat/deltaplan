# Дневник разработки (Hugo)

Простой блог на Hugo: одна запись — один день (или одно событие). Свой минимальный шаблон в `layouts/`, тем нет.

- Новая запись: `hugo new content posts/2026-09-30.md` (из папки `diary/`), заголовок и текст — Markdown.
- Посмотреть локально: `hugo server` (из `diary/`) → http://localhost:1313
- Собрать статику: `hugo` → `diary/public/` (не в git).

Hugo — `~/.local/bin/hugo` (extended). Godot папку не импортирует (`.gdignore`), в экспорт игры она не входит.
