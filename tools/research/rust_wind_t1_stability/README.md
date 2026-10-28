---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-29"
summary: "RW-6z: команды воспроизведения опыта устойчивости открытых полей T1 (варианты CHUNK и возмущения), определения R и классов клеток"
conclusion: "Опыт: base/chunk1000/pert_u10/pert_t × 6 полей; сырьё ~430 МБ вне репозитория; итог — results.json и docs/research/rust-wind-t1-stability.md"
data: "tools/research/rust_wind_t1_stability/results.json"
applied_in: "RW-6z"
related: ["docs/research/rust-wind-t1-stability.md"]
---

# RW-6z: устойчивость открытых полей T1

Вывод и таблицы — `docs/research/rust-wind-t1-stability.md`. Числа — `results.json` (runs, diffs, fields).

## Что
Крейт (`dp-air` `Formula`, как `t1_field()` в `rust/dp-air/tests/acceptance.rs`: место острова, условия из `key.weather`, фокус `key.start`, `tol_scale` 1, `air.deterministic`, 8 потоков, кеш и запечённое выключены) считает 6 полей в вариантах base, chunk1000 (`CHUNK` 1000 в `rust/picard_rs/src/util.rs`, `chunk1000.patch`, правка только на время прогона), pert_u10 (U10·(1+1e-6)), pert_t (T + 1e-6·(T+273,15)). Сравнения base_vs_gpu (запечённое поле, `parse_baked`), `<вариант>_vs_base`, по классам клеток picard / mech / all / conv_both / nonconv и каналам u, v, w_mech, w_conv, theta. Допуск — T1 (по файлу эталона).

U10 и Fr — из `PhaseStats` крейта (`u10`, `fr` = U_a/(N·max(relief,1 м)), `n_bv`) по масках фаз области; N, relief считает `rust/dp-air/src/field/phase/prepare.rs`. Fr = 1000 — N = 0, не определён. U10 файла — `levels[].meta.u10` запечённого json.

Диагностика в `rust/dp-air/src`: `div_rms` в `PassReport`, `WinReport`, `PairSolved` (только чтение невязок решателя; физика не менялась).

## Воспроизведение (Linux, 8 потоков; машина разработчика)
```
export RW6Z_RAW=$HOME/data/rw6z          # сырьё ~430 МБ, не в репозитории
for v in base pert_u10 pert_t; do   # каждый под замком cpu
  .dpcli/dpcli job --lock cpu start rw6z-$v 3600 env RW6Z_VARIANT=$v RW6Z_RAW=$RW6Z_RAW \
    cargo test --release --manifest-path rust/Cargo.toml -p dp-air --test t1_stability stab_run -- --ignored --nocapture
done
git apply tools/research/rust_wind_t1_stability/chunk1000.patch   # затем тот же запуск с v=chunk1000
git apply -R tools/research/rust_wind_t1_stability/chunk1000.patch # откат (git diff feature/rust-wind -- rust/picard_rs пуст)
.dpcli/dpcli job --lock cpu start rw6z-cmp 3000 env RW6Z_RAW=$RW6Z_RAW RW6Z_DIFFS=$RW6Z_RAW/diffs.jsonl \
  cargo test --release --manifest-path rust/Cargo.toml -p dp-air --test t1_stability stab_compare -- --ignored --nocapture
python3 tools/research/rust_wind_t1_stability/summarize.py $RW6Z_RAW/diffs.jsonl tools/research/rust_wind_t1_stability/results.json
```
Время: поле 12–53 с на вариант (≈3–6 мин на вариант), сведение 30 с. `run_variant.sh`/`run_all.sh` — обёртки (под замком cpu получают вес 1 слот, 8 потоков идут на одном ядре; запускать командой cargo напрямую).

## Определения
- R = max_{уровень,канал,вариант∈{chunk1000,pert_u10}} x_tol(picard) / max x_tol(base_vs_gpu, picard). `x_tol` = max|Δ| / допуск канала.
- verdict: R ≥ 0,1 instability; R < 0,01 port_error; между mixed; нет picard-клеток (область заморожена) — по механизмам (base_vs_gpu mech > 1× — port_error); mech > 1× при R ≥ 0,1 → mixed.
- mech: колонна области в маске `freeze` (для `w_mech` — `freeze_mech`); клетки окон — по колонне области под ними. conv_both/nonconv: по статусу решений уровня крейта; статус GPU — «нет данных» (в запечённых файлах не записывается; как получить — в докe).
- `hspeed`: |Δ(u,v)| — max, rms, доли клеток в 10/20 % u0 и местной |U| (пол 0,1 м/с), доля внутри огибающей вариантов (у крейта огибающая ~1e-5 м/с, неинформативна).
- Источники: `docs/research/air_phase/order-and-picard.md` §4.1, §5.2–5.3. Данные: запечённые поля `data/locations/*/air` — собственные, лицензий сторонних нет.
