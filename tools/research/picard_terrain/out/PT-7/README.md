# PT-7: разведка пути срезанных клеток в поле игры

Документ: `docs/research/picard_terrain_game.md`. Здесь — расчёты размеров и сдвига типов клеток по растрам мест игры
(`tests/fixtures/wind/places`, лицензии данных — как у этих фикстур, новых данных нет).

Воспроизведение (из корня репозитория, только numpy):

    PL=tests/fixtures/wind/places; O=tools/research/picard_terrain/out/PT-7
    for s in levels work types_shift; do python3 -I $O/$s.py $PL ongudai synthetic training_island volcano_island > $O/$s.json; done

- `levels.py` — область по правилам `domain_for`/`build_domain_input` (nx, nz, число клеток, столбцы с перепадом > dz).
- `work.py` — число смешанных слоёв и выборок `vf` (оценка стоимости долей, 17 точек на ребро).
- `types_shift.py` — реплика правил PT6 v1 (`vf`, `vf_min` = 0,05, трапеции) на растре места: сдвиг `kf` и `hc_type − hc`.
  Это расчёт скриптом, не код PT-8; блочное среднее по узлам 25 м.
