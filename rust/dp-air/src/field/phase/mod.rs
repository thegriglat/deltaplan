//! Фазы поля масштаба 1 (P10) в Rust: подготовка по столбцам ([`prepare`]) и классификатор
//! механизмов ([`classifier`]): веса A, B, C, D, F, G, H (Σ = 1), маски заморозки колонн для
//! Пикара (W11), карта ω. Механизмы A/B/D/H (RW-6l) и F/G, сборка тёплого старта (RW-6m) —
//! поверх [`prepare::Prepared`].
pub mod classifier;
pub mod config;
pub mod prepare;
