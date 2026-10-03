---
title: Архив планов
weight: 99
description: "Планы и журналы закрытых работ Deltaplan, по модулям; выводы из них — в реестре выводов."
---

# Архив планов и журналов

Здесь — планы и журналы работ, которые закрыты: исполнители отчитались, результат принят и влит в игру. Документы подключены как есть (папка `docs/archive/plan/`), без правок; в обычный поиск по документации репозитория они не входят. Итоги — числа, решения и границы моделей — собраны в [реестре выводов](/research/findings/), и читать архив целиком обычно не нужно: заходите сюда, когда нужно узнать, как принималось конкретное решение.

## Модель воздуха

Журнал и планы волн калибровки и правок решателя поля ветра (сентябрь–октябрь 2026).

- [Журнал модуля](/docs/archive/plan/air-model-progress.md) — решения, итог отбора Морриса, разбор на шлюзе, закрытие модуля.
- [Базовые цифры до модели воздуха](/docs/archive/plan/air-model-baseline.md) (AM-00) — время вызова, FPS, точка отсчёта «до/после».
- [Разведка перед А2](/docs/archive/plan/air-model-a2pre.md) — сходимость и цена решателя на новых параметрах.
- [А1: структурные правки решателя](/docs/archive/plan/air-model-a1.md) — число Прандтля, выхолаживание, высота слоя.
- [А3: схема и переключатели](/docs/archive/plan/air-model-a3.md) — выбор по литературе.
- [А4: Perdigão, лес и границы применимости](/docs/archive/plan/air-model-a4.md).
- [Б1: совместная калибровка Askervein и Perdigão](/docs/archive/plan/air-model-b1.md) и [Б2: α и λ в игре](/docs/archive/plan/air-model-b2.md).

## Воздух у старта и физика взлёта

- [Воздух у старта](/docs/archive/plan/air-start.md) и [журнал](/docs/archive/plan/air-start-progress.md) — жалоба пилота «сдувает»; два прохода поля.
- [Проверка физики крыльев](/docs/archive/plan/wing-physics-check.md) и [журнал](/docs/archive/plan/wing-physics-check-progress.md) — паспорта DHV против поляр.
- [Управление крылом на земле](/docs/archive/plan/control-fix.md) и [журнал](/docs/archive/plan/control-fix-progress.md); разбег: [до/после исправления предела бега](/docs/archive/plan/cf1_start/README.md).
- [Исправления старта](/docs/archive/plan/start-fixes.md) и [журнал](/docs/archive/plan/start-fixes-progress.md); [зазор крыла над рельефом](/docs/archive/plan/sf4_wing_clearance/after_sf3.md).
- [Срывы взлёта в сильный день](/docs/archive/plan/flight/01-vzlet-v-silnyj-veter.md).

## Крылья и модели

- [3D-модели и конфиги крыльев по паспортам](/docs/archive/plan/wings-models3d.md) и [журнал](/docs/archive/plan/wings-models3d-progress.md); [журнал паспортов](/docs/archive/plan/wings-passports-progress.md).
- [Поза «стоя» на старте и вариометр 90-х](/docs/archive/plan/models/01-poza-stoya-i-variometr.md).

## Интерфейс, сайт, сборка

- [Управление в интерфейсе](/docs/archive/plan/ui-controls.md) и [журнал](/docs/archive/plan/ui-controls-progress.md).
- [Обновление сайта](/docs/archive/plan/site-update.md) и [журнал](/docs/archive/plan/site-update-progress.md).
- Группа «Интерфейс»: [меню и полёт](/docs/archive/plan/ui/01-menyu-i-polyot.md), [пауза, настройки, итог](/docs/archive/plan/ui/02-pauza-nastrojki-itog.md).
- Группа «Сборка»: [Linux и проверка](/docs/archive/plan/build/01-sborka-linux-proverka.md), [матрица стабильности](/docs/archive/plan/build/02-stabilnost-matrica.md), [замеры FPS и загрузки](/docs/archive/plan/build/03-zamery-fps-zagruzka.md).

## Старые группы задач

Карточки первых дней проекта по областям кода:

- Атмосфера: [бот-маршрутник](/docs/archive/plan/atmosphere/01-xc-bot.md), [эталоны реальных XC-полётов](/docs/archive/plan/atmosphere/02-etalony-zamer.md), [калибровка пресетов по проходимости](/docs/archive/plan/atmosphere/03-kalibrovka.md), [слова пилота и тесты](/docs/archive/plan/atmosphere/04-slova-pilota-testy.md), [склон на стартах](/docs/archive/plan/atmosphere/05-sklon-na-startah.md), [волна и роторы](/docs/archive/plan/atmosphere/06-volna-proverka.md), [центровка термика ботом](/docs/archive/plan/atmosphere/07-centrovka-bota.md).
- Рельеф: [стенд, кадры, замер GPU](/docs/archive/plan/terrain/01-stend-kadry-zamery.md), [лес и кромка 10 м](/docs/archive/plan/terrain/02-les-kromka-10m.md), [реки и озёра из OSM](/docs/archive/plan/terrain/03-reki-ozyora-osm.md), [дымка и контраст](/docs/archive/plan/terrain/04-dymka-kontrast.md), [волны порывов по траве](/docs/archive/plan/terrain/05-veter-volny-poryvov.md), [бюджет GPU (отложено)](/docs/archive/plan/terrain/06-byudzhet-gpu-relefa.md).
- Растительность: [настройки травинок](/docs/archive/plan/vegetation/01-nastrojki-travinki.md), [деревья по маске и дальний тон](/docs/archive/plan/vegetation/02-derevya-po-maske-dalnij-ton.md).
- Объекты мира: [провода, заборы, батчинг](/docs/archive/plan/world_objects/01-provoda-zabory-batching.md).
- Задания и тренировки — [отложены](/docs/archive/plan/tasks/README.md): логика готова, в игру не подключена.
