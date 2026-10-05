---
type: "plan"
status: "active"
module: "site-i18n"
updated: "2026-10-05"
summary: "Сайт проекта на двух языках: en — основной (корень), ru — /ru/; перевод страниц site/content, переключатель языка, README и скилл выпуска."
related: ["docs/contracts/site-i18n.md", "tools/site/check_i18n.py", ".claude/skills/new-release/SKILL.md"]
---
# План: сайт на en и ru (site-i18n)

Ветка `feature/site-i18n`, копия `~/deltaplan-site-i18n`, код задач SI. Контракты — `docs/contracts/site-i18n.md`, тест — `tools/site/check_i18n.py`.

## Решения пользователя (не обсуждаются)
- Языки — только en и ru; **en — основной**: `defaultContentLanguage = en`, en по корневому адресу, ru — под `/ru/`.
- Английский перевод содержимого сайта по фактам русских страниц, ничего не выдумывать; русские тексты сохраняются; devlog.txt для itch (англ.) — один, не ломать.
- README — ссылки на обе версии сайта, ссылки на разделы поправить.
- Скилл new-release: страница версии сразу на двух языках (en основной, ru), devlog.txt один английский.
- Перевод: каждую страницу (или пачку мелких) — отдельный `dp-writer` на Sonnet с пустым контекстом, короткое задание; параллельно.

## Решения координатора
- Документы репозитория, подключённые на сайт монтированием (docs/guide, docs/contracts, docs/plan, docs/archive/plan, docs/research, tools/research — ~3,5 МБ рабочих текстов, правятся ежедневно) — **не переводятся**, только в ru-версии; ссылки на них с en-страниц ведут в ru с пометкой «(in Russian)». Переводятся страницы `site/content` (разделы, механики, подходы, исследования/планы-оглавления, крылья, версии, дневник).
- Перевод по суффиксу файла (`x.ru.md`/`x.en.md` рядом): ресурсы бандлов (скриншоты) общие, без дублирования.

## Задачи
- **SI-1** (dp-engineer) — инфраструктура: `hugo.toml` (языки, параметры по языкам, `lang='ru'` у монтирований документов), `git mv` страниц `site/content/**.md` → `.ru.md` (кроме `wings/` — SI-2), `site/i18n/en.yaml` + `ru.yaml`, строки шаблонов/шорткодов через i18n, шорткоды по текущему языку, резолвер ссылок с переходом в другой язык и пометкой, переключатель языка. Приёмка: `check_i18n.py --only=K1,K3,K4`.
- **SI-2** (dp-engineer, после SI-1) — `gen_wings.py` на два языка (SI-К6), `wings/**` → `.ru.md` + сгенерированные `.en.md`; `_index.en.md` групп — копия ru с английским GEN-блоком (ручной текст переводит SI-23). Приёмка: `gen_wings.py --check`, `check_contracts.py --only=C2`, `check_i18n.py --only=K2,K4,K5 --pages=wings/ --allow-missing`.
- **SI-3…SI-23** (dp-writer, после SI-1; по странице/пачке) — `<база>.en.md` по SI-К5. Приёмка: `check_i18n.py --only=K2,K4,K5 --pages=<свои>`.
  SI-3 главная + `docs/_index` + `research/docs/_index` + `mechanics/_index`; SI-4 `approaches`; SI-5 `research/_index`; SI-6 `plans/_index` + `plans/archive/_index`;
  SI-7…SI-17 механики: flight, air-model, multiplayer, terrain, instruments, weather, slope-wind, bots, visual-cues, thermals, clouds;
  SI-18 версии (`releases/_index` + все `releases/*/index`); SI-19 дневник `_index`, 09-27, 09-28, 09-29; SI-20 дневник 10-02; SI-21 10-03; SI-22 10-04;
  SI-23 ручной текст `wings/_index` и `wings/<group>/_index` (после SI-2).
- **SI-24** (dp-writer) — README (ссылки на en и ru, разделы), скилл `.claude/skills/new-release/SKILL.md` (страница версии на двух языках по SI-К2, адреса по SI-К1), CHANGELOG.
- Итог модуля — `check_i18n.py` целиком (все K, без `--allow-missing`) на ветке модуля.

## Волны
1. SI-1. 2. SI-2 + переводчики (до ~4–5 одновременно), SI-24. 3. SI-23 после SI-2. 4. Итоговая проверка.

## Риски
- Параллельные модули, трогающие `site/content` или `gen_wings.py` (wind-limits), — конфликт переименований при слиянии в main; главная сессия делает `dp sync` перед слиянием.
- Новые страницы в main после ответвления (дневник, версия) — без en-перевода; итоговая проверка их покажет.
