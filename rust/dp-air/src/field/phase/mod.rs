//! Фазы поля масштаба 1 (P10) в Rust: подготовка по столбцам ([`prepare`]), классификатор
//! механизмов ([`classifier`]): веса A, B, C, D, F, G, H (Σ = 1), маски заморозки колонн для
//! Пикара (W11), карта ω; поля механизмов A ([`linear`]), B ([`bubble`]), D ([`layers`]), H
//! ([`calm`]) и их сборка в точке ([`mech`]); F ([`convection`]), сток G ([`drainage`]) и сборка тёплого старта, полей заморозки и
//! статистики ([`assembly`]).
pub mod assembly;
pub mod bubble;
pub mod calm;
pub mod classifier;
pub mod config;
pub mod convection;
pub mod drainage;
pub mod layers;
pub mod linear;
pub mod mech;
pub mod prepare;
