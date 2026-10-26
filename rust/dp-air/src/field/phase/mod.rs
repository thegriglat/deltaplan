//! Фазы поля масштаба 1 (P10) в Rust: подготовка по столбцам ([`prepare`]), классификатор
//! механизмов ([`classifier`]): веса A, B, C, D, F, G, H (Σ = 1), маски заморозки колонн для
//! Пикара (W11), карта ω; поля механизмов A ([`linear`]), B ([`bubble`]), D ([`layers`]), H
//! ([`calm`]) и их сборка в точке ([`mech`]). F/G и сборка тёплого старта (RW-6m) — поверх
//! [`prepare::Prepared`] и [`mech::MechFields`].
pub mod bubble;
pub mod calm;
pub mod classifier;
pub mod config;
pub mod layers;
pub mod linear;
pub mod mech;
pub mod prepare;
