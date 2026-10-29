//! Режим `air_model.enabled = off` (`atmosphere.gd` `_update_air_mode` 700): упрощённый профиль
//! ветра версии 0.8.0 (`wind_profile_simple`: α = 0,14, предел ×1,8, опорная высота 10 м), без
//! зависимости от часа и облачности, и ветер только аналитикой (поля нет — `a = 0`).
//!
//! Профиль — `WindModel::set_simple_profile` (каркас, `terms::frame`); здесь — чтение режима из
//! конфига и применение к `Terms`. Подключение к `Formula::set_field_enabled` — шаг RW-12z
//! (`formula.rs` задачей не правится): оттуда зовут `Terms::set_air_off(!on)`.
use crate::Configs;
use crate::terms::{Terms, named_json};

/// `air_model.enabled == "off"` в конфиге.
pub fn config_is_off(c: &Configs) -> bool {
    named_json(c, "atmosphere")
        .and_then(|v| {
            v.pointer("/air_model/enabled")
                .and_then(serde_json::Value::as_str)
                .map(|s| s == "off")
        })
        .unwrap_or(false)
}

/// Включить или выключить упрощённый профиль (`_update_air_mode`).
pub fn apply(t: &mut Terms, off: bool) {
    t.air_off = off;
    if off != t.wind.is_simple() {
        t.wind.set_simple_profile(off, None);
    }
}
