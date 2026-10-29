---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-29"
summary: "RW-6u: эталон training_island/landing_hill, перепечатанный CPU-путём фаз (f64) на c591b1026; сравнение с крейтом по классам W8 v2"
conclusion: "Крейт против нового эталона: max |Δ| 0,0024 м/с, все клетки класса mech, вне допуска 0; против GPU-поля игры: до 1,47 м/с, 46-92 % клеток u вне допуска mech"
data: "tools/research/rust_wind_t1_ref/compare_results.json"
applied_in: "RW-6u"
related: ["docs/research/rust-wind-t1-audit-landing-hill.md", "docs/contracts/rust-wind/fixtures-tolerances.md", "tests/fixtures/wind/baked/README.md"]
---

# RW-6u: эталон T1 landing_hill

Что и как — `tests/fixtures/wind/baked/README.md`. Здесь:
- `ref_c591b1026.patch` — правки копии ревизии `c591b1026` на время печати (CPU-фазы, статус решателя, центр места);
- `run.sh` — копия ревизии, патч, печать под `lock cpu`;
- `compare.py` — крейт (сырьё `stab_run` RW-6z: `<сырьё>/base/<loc>__<site>/{meta.json,masks.bin,<уровень>.f32}`) против любого `.json/.bin` по классам W8 v2;
- `compare_results.json` — числа (по уровню, классу, каналу: n, max, rms, n вне допуска v2).

Сырьё крейта: `RW6Z_VARIANT=base RW6Z_RAW=<папка> RW6Z_FIELDS=training_island/landing_hill cargo test --release -p dp-air --test t1_stability stab_run -- --ignored`
(на время опыта путь запечённого поля в `t1_stability.rs` подменён на `tests/fixtures/wind/baked/training_island`; правка не коммитилась).
Сравнение: `python3 compare.py <сырьё>/base/training_island__landing_hill tests/fixtures/wind/baked/training_island/landing_hill.json`.
