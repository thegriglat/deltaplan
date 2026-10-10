//! Крейт osmtiles: сетка O1, контейнер O2, кодек O3, упаковщик и склейка O4, CLI O5, сводка O6, манифест O7.
pub mod codec;
pub mod cover;
pub mod finalize;
pub mod geom;
pub mod grid;
pub mod manifest;
pub mod pack;
pub mod runinfo;
pub mod sample;
pub mod stats;
pub mod tags;
pub mod tilebuild;

/// Сгенерированные prost-типы схемы `tools/osm_tiles/proto/osm_tiles.proto`.
pub mod pb {
    include!(concat!(env!("OUT_DIR"), "/deltaplan.osmtiles.rs"));
}

pub type Result<T> = std::result::Result<T, String>;
