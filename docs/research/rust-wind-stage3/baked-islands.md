---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-29"
summary: "RW-P11: 8 запечённых полей островов крейт читает, но на ветке отвергает все по model_hash."
conclusion: "Файлы можно удалять: на ветке они всегда отвергаются по model_hash (50e249bed5ee6b3c в файлах ≠ 7da6a196ca606f39 сейчас), поле считает Rust. Читаются и data_hash/ключ в порядке — отказ только по хешу кода GD-модели."
data: "rust/dp-air/tests/baked_islands_probe.rs"
applied_in: ""
related: ["docs/research/rust-wind-stage3/rw12z.md"]
---

# Запечённые поля островов: принимает ли их крейт (RW-P11)

## Вопрос

Передаёт ли фасад `data/locations/{training_island,volcano_island}/air/*` в `DpAir.add_baked_field` и принимает ли их крейт (`baked_lookup`: `model_hash`, `data_hash`, ключ) при входе на стартовые места, или всегда отвергает и считает поле.

## Путь файла (по коду)

1. `air_place_data.gd:fill_crate_inputs` читает для каждого старта места `<id>.json` + `.bin` и кладёт в `baked`; `header.model_hash = AirBakedField.model_hash()`, `header.data_hash = place_hash(...)`.
2. `atmosphere.gd:1009` — `dp.add_baked_field(header_json, data)` для каждого файла (код 0 — принят). Фасад передаёт все 8 файлов.
3. Крейт: `BakedEntry::new` (формат `dp-air-baked` v1) → при старте `runtime.rs:pick_baked` → `baked_lookup` (причины отказа по порядку: нет погоды → нет файла → **`model_hash`** → условия → `key`).

## Замер (факт)

`model_hash` в ключе игры — хеш **исходников** `scripts/atmosphere/air_model/*.gd|glsl` + четырёх конфигов (`AirBakedField.model_hash()`). Снят `godot --headless` на ветке (копия RW-P11, HEAD feature/rust-wind): `model_hash = 7da6a196ca606f39`, `data_hash`: training_island `a49fb9ea1b803627`, volcano_island `4a94276e1be0fdf8`. Файлы запечены 2026-10-24 (d6df90c8b) с `model_hash = 50e249bed5ee6b3c`. Исходники модели менялись после: 837ca673d, 752144918 (RW-6j), 937b26828 (RW-6v), b5b2669bf (RW-7b), 8f344ef31 (RW-P3).

Тест `rust/dp-air/tests/baked_islands_probe.rs` (cargo, 1 с): для каждого файла — приём, разбор, `baked_lookup` с хешем файла и условиями из `key.weather`, затем с текущим хешем.

| файл | add_baked_field / parse | data_hash = текущему | остальной ключ, условия | при текущем model_hash |
|---|---|---|---|---|
| training_island/landing_hill | принят | да | сошлись | **отвергнут**: модель воздуха другой версии (50e2… ≠ 7da6…) |
| training_island/lee_bowl | принят | да | сошлись | отвергнут (тот же хеш) |
| training_island/ridge_west | принят | да | сошлись | отвергнут |
| training_island/thermal_plain | принят | да | сошлись | отвергнут |
| volcano_island/crater_ridge | принят | да | сошлись | отвергнут |
| volcano_island/east_cliffs | принят | да | сошлись | отвергнут |
| volcano_island/plateau_landing | принят | да | сошлись | отвергнут |
| volcano_island/thermal_slope | принят | да | сошлись | отвергнут |

Итог: на ветке все 8 файлов читаются, но ни один не используется — всегда считается поле Rust. Единственная причина — `model_hash`.

## Следствия

- Удаление `data/locations/*/air` (~45 МБ) ничего не меняет в играх на ветке: поле уже считается, а не берётся из файла. В логе остаются строки «запечённое поле не принято / отказ» — исчезнут с удалением.
- Совпасть хеш не сможет и в будущем: он считается по GD-исходникам модели, а RW-12z/RW-13 их убирает (без исходников и `data/air_model_hash.txt` `model_hash()` пуст → `pick_baked`: «у места нет model_hash»). Перепекать нечем — `bake_air.gd` удалён (RW-P10). Кроме того, файлы — результат GPU-решателя, а Rust-поле считает Пикар (другая модель): совпадение с ними не критерий.
- Если файлы удалять — вместе с `BakedEntry`/`add_baked_field`/`parse_baked`/`baked_lookup` в крейте, `fill_crate_inputs.baked` и `place_hash`/`model_hash` в фасаде, тестами `tests/baked.rs` (решение пользователя о пекании 2026-10-29).

## Границы

- Условия запроса в тесте взяты из `key.weather` и `key` самого файла, а не из `configs/locations/*` (набор погоды старта). Расхождение конфига со старой погодой дало бы ещё один отказ (условия/ключ), но уже после хеша — на вывод «отвергаются» не влияет.
- Текущий `model_hash` зависит и от конфигов; снят на этой копии, без пользовательского профиля (`_model_config` его не берёт). В экспорте без исходников хеш брался бы из `data/air_model_hash.txt` (его нет).
- Полная игра с загрузкой места не запускалась: приём в `add_baked_field` и логика `pick_baked` проверены тестом крейта и чтением кода.

## Воспроизведение

```
godot --headless --path . --import   # один раз в свежей копии
godot --headless --path . --script <скрипт с print(AirBakedField.model_hash(), place_hash(dir))>
cd rust && cargo test -p dp-air --test baked_islands_probe -- --nocapture
```
