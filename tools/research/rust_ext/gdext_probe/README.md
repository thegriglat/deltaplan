# gdext_probe — проба Rust + godot-rust с Godot 4.7.2

Минимальная проверка (план `docs/plan/rust-ext.md`, раздел «Проба gdext»): класс `Probe` (`RefCounted`) с `add`, `sum(PackedFloat32Array)`
и фоновым потоком Rust (`start(ms)` / `is_done()` / `take_result()`). `godot/` — отдельный минимальный проект, не игра.
`rust/target/` не коммитится. Запуск: `./run.sh [debug|release]`. Результат — в плане.
