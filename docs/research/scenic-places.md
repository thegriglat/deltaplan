---
type: "research"
status: "active"
module: "scenic-places"
area: "world"
updated: "2026-11-05"
summary: "Каталог красивых мест: 236 мест в 29 странах, метод отбора, проверка по рельефу (checked 236, failed 0), её пределы"
related: ["docs/contracts/scenic-places.md", "docs/plan/scenic-places.md", "docs/research/scenic-places-table.md"]
conclusion: "236 природных мест в 29 странах (5–10 на страну) прошли проверку SCP-К2: min запас высоты 0 м, min перепад у вида 101 м; видимость вида и рельеф игры проверка не знает."
data: "data/places/scenic_places.json; tools/places/scenic/*.json; проверка — tools/places/check_scenic_places.py (Terrarium z11, кэш ~/.cache/dp-places)"
applied_in: "кнопка «Красивые места» в «Настройках полёта» (SCP-К3); каталог data/places/scenic_places.json"
---

# Красивые места

## Что это и для чего

Витрина для игрока: в «Настройках полёта» кнопка «Красивые места» открывает список мест мира и ставит пилота в воздух у выбранного. Только природные пейзажи (горы, каньоны, озёра, побережья, вулканы, ледники, долины, фьорды, пустыни, острова) — решение пользователя 2026-11-05. Каталог — `data/places/scenic_places.json`, собирается `python3 tools/places/build_scenic_places.py` из региональных списков `tools/places/scenic/*.json` (Европа и север Азии — 80, Америки — 56, Азия, Океания и Африка — 100): 236 мест, 29 стран. Формат — SCP-К1 v2, `docs/contracts/scenic-places.md`.

## Как выбирали и проверяли

- Место (`lat`, `lon`) — точка старта в воздухе; вид (`view_lat`, `view_lon`) — координаты объекта из шапки статьи Википедии (API prop=coordinates), без правок.
- Старт подбирался перебором: 4–12 км до вида, курс на вид (допуск 30°), высота над землёй `agl_m` 50…1000 м (предел старта ASM-К1).
- Проверка SCP-К2 (`python3 tools/places/check_scenic_places.py data/places/scenic_places.json`) по Terrarium z11: вид не дальше 15 км и не дальше 30° от курса; от старта по курсу 5 км планирования 1:10 не должны упираться в землю — запас высоты над рельефом не менее 50 м при качестве 10 (минимум по всем местам в таблице ниже даёт «запас», он считается к максимуму рельефа на пути, порог — неотрицательный); перепад высот в радиусе 5 км у вида не менее 100 м (чтобы вид не был плоским).
- Итог: `checked 236, failed 0`; минимальный запас высоты 0 м (us/mount-hood), минимальный перепад у вида 101 м (cl/general-carrera-lake). Страна — 5…10 мест (проверяется там же).

## Чего проверка не знает

- Видимости вида глазами: объект может быть за гребнем, в тени, в дымке; смотрели только геометрию.
- Рельеф в игре — Copernicus 25 м, а не Terrarium z11 (около 70 м на этих широтах): гребни и обрывы в игре резче, малый запас может превратиться в касание земли.
- Точка в шапке статьи — не всегда вершина (центр массива, озера, парка).
- Места с запасом высоты менее 10 м (старт почти на пределе планирования): ar/nahuel-huapi-lake 7, ar/perito-moreno-glacier 4, ar/tronador 5, bo/huayna-potosi 4, bo/laguna-colorada 6, br/pedra-da-gavea 8, br/pico-da-neblina 8, br/pico-das-agulhas-negras 4, cl/general-carrera-lake 5, cl/osorno-volcano 8, cl/torres-del-paine 5, mx/nevado-de-toluca 7, us/mount-hood 0 (м). Первые восемь из Америк отмечены в отчёте SCP-2, остальные пять — по итоговой проверке. Порог не ослаблялся.

## Таблица мест

Таблица всех мест для просмотра (страна, место, тип, чем красиво, координаты старта, курс, высота, ссылка на карту) — в `docs/research/scenic-places-table.md`: она больше 40 КБ. Получена `check_scenic_places.py data/places/scenic_places.json --table …`.
