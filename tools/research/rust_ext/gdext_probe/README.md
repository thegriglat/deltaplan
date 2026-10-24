---
type: "research"
status: "closed"
module: "rust-ext"
area: "perf"
updated: "2026-10-24"
summary: "Проба gdext 0.5.5 (godot-rust) на Godot 4.7.2 Linux: класс Probe, PackedFloat32Array и фоновый поток Rust с опросом из GDScript"
conclusion: "gdext 0.5.5 с api-4-7 работает на Godot 4.7.2 Linux (debug и release); фоновый поток Rust + опрос is_done из GDScript не блокирует главный поток"
data: ""
applied_in: ""
related: ["docs/plan/rust-ext.md"]
---

# gdext_probe — проба Rust + godot-rust с Godot 4.7.2

Минимальная проверка (план `docs/plan/rust-ext.md`, раздел «Проба gdext»): класс `Probe` (`RefCounted`) с `add`, `sum(PackedFloat32Array)`
и фоновым потоком Rust (`start(ms)` / `is_done()` / `take_result()`). `godot/` — отдельный минимальный проект, не игра.
`rust/target/` не коммитится. Запуск: `./run.sh [debug|release]`. Результат — в плане.
