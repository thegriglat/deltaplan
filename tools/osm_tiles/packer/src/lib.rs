//! Крейт osmtiles: сетка O1, контейнер O2, кодек O3, манифест O7, покрытие O5, сводка O6.
pub mod codec;
pub mod cover;
pub mod grid;
pub mod manifest;
pub mod sample;
pub mod stats;

/// Сгенерированные prost-типы схемы `tools/osm_tiles/proto/osm_tiles.proto`.
pub mod pb {
    include!(concat!(env!("OUT_DIR"), "/deltaplan.osmtiles.rs"));
}

pub type Result<T> = std::result::Result<T, String>;
