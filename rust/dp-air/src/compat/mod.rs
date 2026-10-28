//! Совместимость с движком Godot 4.7.2 (RW-8c): шум `FastNoiseLite`, `RandomNumberGenerator` (PCG32)
//! и `hash()` векторов. Побитно (шум — до 1e-6) сверяется с дампом из Godot
//! (`tools/wind_fixtures/compat_dump.sh`, тест `tests/godot_compat.rs`). Без зависимости от Godot.

pub mod hash;
pub mod noise;
pub mod rng;
