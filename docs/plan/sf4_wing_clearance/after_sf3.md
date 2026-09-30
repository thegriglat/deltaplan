# Зазор крыла над рельефом после SF-3 + SF-4

Прогон: `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/flight/wing_clearance_run.tscn -- --csv=res://docs/plan/sf4_wing_clearance/after_sf3.csv --loc-wings=sport,magic` (синтетика — все крылья, старты локаций — sport и magic). Штиль. Худшее крыло по (старт, фаза). «По рисуемой сетке» — против рельефа, как его рисуют треугольники (только локации).

Все старты локаций, крен 0, стоит/шагом/разбег с нейтральной трапецией: наименьший зазор по рисуемой сетке 0,58 м (altai/sinyukha_west, разбег) — ≥ 0, рельеф не трогаем.
Отрицательный зазор — только (а) косой склон / разворот поперёк склона (разбег с зажатой A по дуге уходит поперёк склона — верхняя консоль в склоне, правда жизни), (б) после отрыва с зажатой A — крен от ввода в воздухе 39°.

| старт | фаза | уклон по курсу/поперёк, ° | крен | тангаж | зазор, м (часть, худшее крыло) | по рисуемой сетке |
|---|---|---|---|---|---|---|
| ровно | стоит | 0 / 0 | 0.0 | 16.0 | 0.64 frame target | — |
| ровно | стоит, трапеция от себя (нос вверх) | 0 / 0 | 0.0 | 37.0 | 0.55 tips magic | — |
| ровно | стоит, трапеция на себя (нос вниз) | 0 / 0 | 0.0 | -4.0 | 0.35 frame target | — |
| ровно | стоит, A (поворот на месте) | 0 / 0 | 0.0 | 16.0 | 0.64 frame target | — |
| ровно | разбег, A (дуга) | 0 / 0 | 0.2 | 16.0 | 0.64 frame target | — |
| ровно | шагом | 0 / 0 | 0.0 | 16.0 | 0.64 frame target | — |
| ровно | разбег | 0 / 0 | 0.0 | 16.0 | 0.64 frame target | — |
| склон 20° по курсу | стоит | -20 / 0 | 0.0 | -4.0 | 0.68 frame target | — |
| склон 20° по курсу | стоит, трапеция от себя (нос вверх) | -20 / 0 | 0.0 | 17.0 | 0.58 tips magic | — |
| склон 20° по курсу | стоит, трапеция на себя (нос вниз) | -20 / 0 | 0.0 | -24.0 | 0.37 frame target | — |
| склон 20° по курсу | стоит, A (поворот на месте) | 0 / -20 | 0.0 | 11.8 | -0.29 tips combat | — |
| склон 20° по курсу | разбег, A (дуга) | 6 / 19 | 0.2 | 27.6 | -0.56 tips combat | — |
| склон 20° по курсу | шагом | -20 / 0 | 0.0 | -4.0 | 0.68 frame target | — |
| склон 20° по курсу | разбег | -20 / 0 | 0.0 | -4.0 | 0.68 frame target | — |
| склон 20° по курсу | после отрыва ≤1,5 с | -20 / 0 | 0.0 | -4.1 | 0.68 frame target | — |
| косой 15° (правая вверх) | стоит | 0 / 15 | 0.0 | 17.0 | 0.03 tips combat | — |
| косой 15° (правая вверх) | стоит, трапеция от себя (нос вверх) | 0 / 15 | 0.0 | 37.0 | -0.83 tips magic | — |
| косой 15° (правая вверх) | стоит, трапеция на себя (нос вниз) | 0 / 15 | 0.0 | -4.0 | 0.12 frame target | — |
| косой 15° (правая вверх) | стоит, A (поворот на месте) | -2 / 15 | 0.0 | 16.3 | -0.02 tips combat | — |
| косой 15° (правая вверх) | разбег, A (дуга) | -2 / 15 | 0.0 | 16.3 | -0.02 tips combat | — |
| косой 15° (правая вверх) | после отрыва ≤1,5 с (A зажата — крен ввода в воздухе) | -13 / -8 | -50.6 | -0.9 | -3.35 tips target | — |
| косой 15° (правая вверх) | шагом | 0 / 15 | 0.0 | 17.0 | 0.03 tips combat | — |
| косой 15° (правая вверх) | разбег | 0 / 15 | 0.0 | 17.0 | 0.03 tips combat | — |
| altai/sinyukha_west | стоит | -15 / 0 | 0.0 | -1.9 | 0.72 frame sport | 0.69 |
| altai/sinyukha_west | стоит, трапеция от себя (нос вверх) | -15 / 0 | 0.0 | 18.1 | 0.94 frame sport | 0.91 |
| altai/sinyukha_west | стоит, трапеция на себя (нос вниз) | -15 / 0 | 0.0 | -21.9 | 0.42 frame sport | 0.39 |
| altai/sinyukha_west | стоит, A (поворот на месте) | -4 / -14 | 0.0 | 3.8 | 0.47 frame magic | 0.47 |
| altai/sinyukha_west | разбег, A (дуга) | -5 / -14 | 0.2 | 10.3 | 0.22 tips sport | -0.23 |
| altai/sinyukha_west | шагом | -20 / -1 | -0.0 | -3.0 | 0.72 frame sport | 0.70 |
| altai/sinyukha_west | разбег | -27 / -11 | 0.0 | -10.2 | 0.59 tips sport | 0.58 |
| altai/sinyukha_west | после отрыва ≤1,5 с | -23 / -10 | 0.0 | -1.0 | 0.98 frame magic | 0.97 |
| altai/sinyukha_east | стоит | -16 / -1 | 0.0 | -3.6 | 0.72 frame sport | 0.72 |
| altai/sinyukha_east | стоит, трапеция от себя (нос вверх) | -16 / -1 | 0.0 | 16.4 | 0.92 frame sport | 0.92 |
| altai/sinyukha_east | стоит, трапеция на себя (нос вниз) | -16 / -1 | 0.0 | -23.6 | 0.41 frame sport | 0.41 |
| altai/sinyukha_east | стоит, A (поворот на месте) | -7 / -15 | 0.0 | 2.0 | 0.42 frame magic | 0.42 |
| altai/sinyukha_east | разбег, A (дуга) | -2 / -22 | 0.2 | 12.6 | -0.56 tips sport | -1.04 |
| altai/sinyukha_east | шагом | -17 / -1 | 0.0 | -3.6 | 0.72 frame sport | 0.72 |
| altai/sinyukha_east | разбег | -17 / -1 | 0.0 | -3.7 | 0.72 frame sport | 0.72 |
| altai/sinyukha_east | после отрыва ≤1,5 с | -27 / 2 | -0.0 | -6.0 | 0.96 frame magic | 0.96 |
| altai/tugaya_south | стоит | -12 / 1 | 0.0 | 1.2 | 0.68 frame magic | 0.68 |
| altai/tugaya_south | стоит, трапеция от себя (нос вверх) | -12 / 1 | 0.0 | 21.2 | 0.89 frame sport | 0.89 |
| altai/tugaya_south | стоит, трапеция на себя (нос вниз) | -12 / 1 | 0.0 | -18.8 | 0.38 frame sport | 0.38 |
| altai/tugaya_south | стоит, A (поворот на месте) | 3 / -12 | 0.0 | 12.9 | 0.47 frame magic | 0.48 |
| altai/tugaya_south | разбег, A (дуга) | 2 / -21 | 0.2 | 17.1 | -0.47 tips sport | -0.34 |
| altai/tugaya_south | шагом | -13 / 1 | 0.0 | 1.2 | 0.68 frame magic | 0.68 |
| altai/tugaya_south | разбег | -10 / -4 | 0.0 | 7.1 | 0.66 frame sport | 0.68 |
| altai/tugaya_south | после отрыва ≤1,5 с (A зажата — крен ввода в воздухе) | -7 / -17 | -39.5 | 1.0 | -3.41 tips magic | -3.22 |
| altai/tugaya_south | после отрыва ≤1,5 с | -15 / 3 | -0.0 | 0.1 | 0.67 frame magic | 0.94 |
| ongudai/kayancha_south | стоит | -17 / 1 | 0.0 | -1.8 | 0.72 frame sport | 0.72 |
| ongudai/kayancha_south | стоит, трапеция от себя (нос вверх) | -17 / 1 | 0.0 | 18.2 | 0.73 tips magic | 0.73 |
| ongudai/kayancha_south | стоит, трапеция на себя (нос вниз) | -17 / 1 | 0.0 | -21.8 | 0.41 frame sport | 0.41 |
| ongudai/kayancha_south | стоит, A (поворот на месте) | 0 / -17 | 0.0 | 11.2 | 0.32 tips sport | 0.30 |
| ongudai/kayancha_south | разбег, A (дуга) | -1 / -19 | 0.2 | 14.8 | -0.21 tips sport | -0.23 |
| ongudai/kayancha_south | шагом | -17 / 1 | 0.0 | -1.8 | 0.72 frame sport | 0.72 |
| ongudai/kayancha_south | разбег | -17 / 1 | -0.0 | -1.8 | 0.72 frame sport | 0.72 |
| ongudai/kayancha_south | после отрыва ≤1,5 с | -23 / -1 | 0.0 | -5.7 | 0.77 frame magic | 0.79 |
| askarovo/biyagoda_west | стоит | -20 / 0 | 0.0 | -4.8 | 0.74 frame sport | 0.74 |
| askarovo/biyagoda_west | стоит, трапеция от себя (нос вверх) | -20 / 0 | 0.0 | 15.2 | 0.81 tips magic | 0.71 |
| askarovo/biyagoda_west | стоит, трапеция на себя (нос вниз) | -20 / 0 | 0.0 | -24.8 | 0.42 frame sport | 0.42 |
| askarovo/biyagoda_west | стоит, A (поворот на месте) | 1 / -20 | 0.0 | 11.2 | 0.01 tips sport | 0.01 |
| askarovo/biyagoda_west | разбег, A (дуга) | -1 / -21 | 0.2 | 13.9 | -0.41 tips sport | -0.71 |
| askarovo/biyagoda_west | шагом | -20 / 0 | 0.0 | -4.8 | 0.74 frame sport | 0.74 |
| askarovo/biyagoda_west | разбег | -24 / -2 | 0.0 | -6.5 | 0.74 frame sport | 0.70 |
| askarovo/biyagoda_west | после отрыва ≤1,5 с | -23 / -1 | -0.0 | -5.9 | 0.75 frame magic | 0.69 |
| askarovo/biyagoda_east | стоит | -14 / 0 | 0.0 | 1.9 | 0.69 frame sport | 0.69 |
| askarovo/biyagoda_east | стоит, трапеция от себя (нос вверх) | -14 / 0 | 0.0 | 21.9 | 0.90 tips magic | 0.83 |
| askarovo/biyagoda_east | стоит, трапеция на себя (нос вниз) | -14 / 0 | 0.0 | -18.1 | 0.40 frame sport | 0.39 |
| askarovo/biyagoda_east | стоит, A (поворот на месте) | -2 / -14 | 0.0 | 9.1 | 0.43 tips sport | 0.43 |
| askarovo/biyagoda_east | разбег, A (дуга) | -5 / -14 | 0.2 | 13.0 | 0.14 tips sport | 0.14 |
| askarovo/biyagoda_east | шагом | -14 / 0 | 0.0 | 1.9 | 0.69 frame sport | 0.69 |
| askarovo/biyagoda_east | разбег | -17 / -8 | -0.0 | -0.1 | 0.64 frame sport | 0.60 |
| askarovo/biyagoda_east | после отрыва ≤1,5 с | -16 / -3 | 0.0 | -0.3 | 0.67 frame magic | 0.67 |
| askarovo/biyagoda_south_west | стоит | -18 / 0 | 0.0 | -2.3 | 0.72 frame sport | 0.72 |
| askarovo/biyagoda_south_west | стоит, трапеция от себя (нос вверх) | -18 / 0 | 0.0 | 17.7 | 0.76 tips magic | 0.65 |
| askarovo/biyagoda_south_west | стоит, трапеция на себя (нос вниз) | -18 / 0 | 0.0 | -22.3 | 0.41 frame sport | 0.41 |
| askarovo/biyagoda_south_west | стоит, A (поворот на месте) | -0 / -18 | 0.0 | 12.0 | 0.14 tips sport | 0.12 |
| askarovo/biyagoda_south_west | разбег, A (дуга) | -1 / -20 | 0.2 | 14.2 | -0.35 tips sport | -0.42 |
| askarovo/biyagoda_south_west | шагом | -18 / 0 | 0.0 | -2.3 | 0.72 frame sport | 0.72 |
| askarovo/biyagoda_south_west | разбег | -18 / 0 | -0.0 | -2.3 | 0.72 frame sport | 0.72 |
| askarovo/biyagoda_south_west | после отрыва ≤1,5 с | -21 / 1 | -0.0 | -4.4 | 0.74 frame magic | 0.72 |
| aushkul/aushtau_east | стоит | -19 / 2 | 0.0 | -3.1 | 0.72 frame sport | 0.72 |
| aushkul/aushtau_east | стоит, трапеция от себя (нос вверх) | -19 / 2 | 0.0 | 16.9 | 0.62 tips magic | 0.59 |
| aushkul/aushtau_east | стоит, трапеция на себя (нос вниз) | -19 / 2 | 0.0 | -23.1 | 0.41 frame sport | 0.41 |
| aushkul/aushtau_east | стоит, A (поворот на месте) | 2 / -19 | 0.0 | 12.2 | -0.03 tips sport | -0.04 |
| aushkul/aushtau_east | разбег, A (дуга) | -1 / -20 | 0.2 | 14.0 | -0.36 tips sport | -0.54 |
| aushkul/aushtau_east | шагом | -19 / 2 | 0.0 | -3.1 | 0.72 frame sport | 0.72 |
| aushkul/aushtau_east | разбег | -19 / 2 | 0.0 | -3.1 | 0.72 frame sport | 0.72 |
| aushkul/aushtau_east | после отрыва ≤1,5 с | -21 / 1 | -0.0 | -4.8 | 0.74 frame magic | 0.70 |
| aushkul/aushtau_south | стоит | -17 / -1 | 0.0 | -0.0 | 0.72 frame sport | 0.71 |
| aushkul/aushtau_south | стоит, трапеция от себя (нос вверх) | -17 / -1 | 0.0 | 20.0 | 0.85 tips magic | 0.76 |
| aushkul/aushtau_south | стоит, трапеция на себя (нос вниз) | -17 / -1 | 0.0 | -20.0 | 0.42 frame sport | 0.41 |
| aushkul/aushtau_south | стоит, A (поворот на месте) | -6 / -17 | 0.0 | 5.4 | 0.23 tips sport | 0.23 |
| aushkul/aushtau_south | разбег, A (дуга) | -1 / -23 | 0.2 | 13.7 | -0.65 tips sport | -0.65 |
| aushkul/aushtau_south | шагом | -19 / 0 | -0.0 | -2.1 | 0.70 frame sport | 0.70 |
| aushkul/aushtau_south | разбег | -22 / 6 | -0.0 | -4.8 | 0.69 frame sport | 0.62 |
| aushkul/aushtau_south | после отрыва ≤1,5 с (A зажата — крен ввода в воздухе) | -2 / -23 | -38.8 | 3.7 | -3.95 tips magic | -3.96 |
| aushkul/aushtau_south | после отрыва ≤1,5 с | -19 / 4 | -0.0 | -2.9 | 0.69 frame magic | 0.68 |
| aushkul/ridge_west | стоит | -14 / -1 | 0.0 | -0.4 | 0.69 frame sport | 0.69 |
| aushkul/ridge_west | стоит, трапеция от себя (нос вверх) | -14 / -1 | 0.0 | 19.6 | 0.91 frame sport | 0.91 |
| aushkul/ridge_west | стоит, трапеция на себя (нос вниз) | -14 / -1 | 0.0 | -20.4 | 0.39 frame sport | 0.39 |
| aushkul/ridge_west | стоит, A (поворот на месте) | -2 / -14 | 0.0 | 9.4 | 0.49 frame magic | 0.49 |
| aushkul/ridge_west | разбег, A (дуга) | -4 / -19 | 0.2 | 12.9 | -0.27 tips sport | -0.27 |
| aushkul/ridge_west | шагом | -14 / -1 | 0.0 | -0.4 | 0.69 frame sport | 0.69 |
| aushkul/ridge_west | разбег | -16 / 6 | 0.0 | 0.7 | 0.66 frame sport | 0.70 |
| aushkul/ridge_west | после отрыва ≤1,5 с | -17 / -1 | -0.0 | -0.8 | 0.71 frame magic | 0.71 |
