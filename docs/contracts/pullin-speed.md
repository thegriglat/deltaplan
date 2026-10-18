---
type: "contract"
status: "active"
module: "pullin-speed"
area: "flight"
updated: "2026-10-19"
summary: "Стыки модуля pullin-speed: входные данные «Маятника» только на чтение (VM-К0) и итоговый research-документ VM-1 для шлюза Q1 (VM-К1)."
related: ["docs/plan/pullin-speed.md", "docs/contracts/pendulum.md", "docs/research/pendulum_pitch.md", "docs/research/pendulum/prototype.md"]
contracts: [{"id": "VM-К0", "version": 1}, {"id": "VM-К1", "version": 2}]
---
# Контракты модуля pullin-speed

План — `docs/plan/pullin-speed.md`. Менять — только координатор модуля: версия +1, что изменилось,
уведомить потребителей (`task note`), их правка в том же шаге.

## VM-К0. Входные данные «Маятника» — только чтение (v1)
Владелец: модуль pendulum (закрыт). Потребители: VM-1.
- Модель и конфиг — `docs/contracts/pendulum.md` PD-К1 v4, PD-К2 v7 (блок `pendulum` в `configs/wings/*.json`,
  `configs/pendulum.json`). В волне 1 не меняются.
- Ход рук: `scripts/flight/pendulum/pilot_arms.gd` — `shift_x_pull` (умолчание 0,45 м, к носу, «на себя»),
  `shift_x_push` 0,3 м, `shift_y_max` 0,45 м; значения из `arms.shift_x_pull_m` и т. д.
  (`scripts/flight/pendulum/pendulum_model.gd`, умолчания около строки 38, предел — около строки 1040).
- Готовые замеры: `docs/research/pendulum_pitch.md` («После правки рук»: 44,6 / 56,6 / 59,9 км/ч),
  `docs/research/pendulum/prototype.md` (таблица крыльев, подвеска 0,4–0,9 км/ч на см),
  `docs/guide/flight/polar-table.md`, `docs/guide/models/wings.md`, `docs/guide/flight/pendulum.md`,
  `docs/research/pendulum/pilot-answers-game-check.md` (подвеска ЦМ +2–3 см), прототип `tools/research/pendulum/`,
  скрипт `tools/research/pendulum_pitch/`.

## VM-К1. Итог разбора VM-1 (v2)
v2 (2026-10-19): добавлен раздел `## VG` (решение пользователя: оценить VG в VM-1).
Владелец: VM-1. Потребители: координатор (шлюз Q1), волна 2.

Файл `docs/research/pendulum/pullin-speed.md`, frontmatter по правилам docs (`type: research`, `module: pullin-speed`,
`area: flight`, `summary` — вывод с числами ≤ 140 символов). Обязательные разделы второго уровня, в этом порядке
(заголовок начинается ровно так):
1. `## Паспортная Vmax` — что измеряет DHV/производитель (режим, VG, поза, ход трапеции), источники с URL.
2. `## VG` — сколько даёт VG по данным: пары Vmax VG 0 / VG full (DHV, производители, с URL), что VG меняет
   физически (натяжение паруса, крутка, Cm0, CL_α), закроет ли он разрыв по классам; нет пар — так и написать.
3. `## Ход рук` — какой ход и угол крыла к стропе нужны в модели для паспортной Vmax; откуда 0,45 м; сколько
   км/ч даёт 0,45 м по классам.
4. `## Точка подвески` — таблица по всем крыльям с блоком `pendulum` в `configs/wings/`: подвеска в модели,
   паспорт / «ЦМ + 2–3 см», Vmax модели на полном «на себя», паспортная Vmax, вклад смещения подвески (км/ч на см).
5. `## Прочие вклады` — Cm0/центровка паруса, CL_α полос (4,5 без взаимной индукции), сопротивление пилота:
   оценка вклада каждого в км/ч.
6. `## Причина` — строка `Класс: физика` | `Класс: граница модели` | `Класс: ошибка модели` (одна или несколько
   через `; ` с долями) и обоснование числами.
7. `## Варианты правки` — каждый вариант: что меняется, ожидаемый эффект в км/ч по классам, риск (устойчивость Kn,
   трим, посадка), нужна ли новая модель полос (тогда — пометка «шлюз»).
8. `## Воспроизведение` — команды, которыми получены новые числа; ссылки на данные в `tools/research/pullin_speed/`.

Числа — только из готовых документов (со ссылкой `путь#раздел`) или из новых прогонов, сохранённых в
`tools/research/pullin_speed/` (скрипт + таблица csv/json + README с frontmatter). Нет данных — так и написать.

Контрактный тест — проверки карточки VM-1 `vm-k1-sections` и `vm-k1-class`.
