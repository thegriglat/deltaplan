//! Класс `DpAir` (W3, gdext) поверх `dp-air`. Сейчас модель — `Calm` (RW-4b); `Formula` — RW-6…12.
//!
//! Вход — срезы массивов Godot без копирования; выход — запись прямо в `Packed*Array` результата
//! (одно выделение, ноль промежуточных `Vec` в горячем пути `sample_many`).
//! Рабочие потоки Rust объекты Godot не трогают.

pub mod bridge;

use bridge::Bridge;
use dp_air::{Cloud, Core, Crest};
use godot::prelude::*;

struct DpAirExt;

#[gdextension]
unsafe impl ExtensionLibrary for DpAirExt {}

// Cast срезов Vector3/Vector2 в [f32; N] опирается на раскладку gdext (repr(C), f32).
const _: () = {
    assert!(size_of::<Vector3>() == 12 && align_of::<Vector3>() == 4);
    assert!(size_of::<Vector2>() == 8 && align_of::<Vector2>() == 4);
};

fn v3s(v: &[Vector3]) -> &[[f32; 3]] {
    // SAFETY: Vector3 — repr(C) { x, y, z: f32 }, размер и выравнивание проверены const-assert.
    unsafe { std::slice::from_raw_parts(v.as_ptr().cast(), v.len()) }
}

fn strings(a: &PackedStringArray) -> Vec<String> {
    a.as_slice().iter().map(|s| s.to_string()).collect()
}

fn gs(s: impl AsRef<str>) -> GString {
    GString::from(s.as_ref())
}

fn packed(v: &[f32]) -> PackedFloat32Array {
    PackedFloat32Array::from(v)
}

fn packed_n<const N: usize>(n: usize, fill: impl FnOnce(&mut [[f32; N]])) -> PackedFloat32Array {
    let mut out = PackedFloat32Array::new();
    out.resize(n * N);
    let (chunks, _) = out.as_mut_slice().as_chunks_mut::<N>();
    fill(chunks);
    out
}

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct DpAir {
    bridge: Bridge,
    cores: Vec<Core>,
    clouds: Vec<Cloud>,
    crests: Vec<Crest>,
    base: Base<RefCounted>,
}

#[godot_api]
impl DpAir {
    #[constant]
    pub const WIND_API_VERSION: i64 = 3;
    #[constant]
    pub const STATE_EMPTY: i64 = 0;
    #[constant]
    pub const STATE_LOADING: i64 = 1;
    #[constant]
    pub const STATE_READY: i64 = 2;
    #[constant]
    pub const STATE_FAILED: i64 = 3;
    #[constant]
    pub const OK: i64 = 0;
    #[constant]
    pub const BAD_INPUT: i64 = 1;
    #[constant]
    pub const NO_PLACE: i64 = 2;
    #[constant]
    pub const NOT_READY: i64 = 3;
    #[constant]
    pub const SAMPLE_FULL: i64 = 0;
    #[constant]
    pub const SAMPLE_MEAN: i64 = 1;
    #[constant]
    pub const CORE_STRIDE: i64 = 15;
    #[constant]
    pub const CLOUD_STRIDE: i64 = 10;
    #[constant]
    pub const CREST_STRIDE: i64 = 4;

    #[func]
    fn api_version(&self) -> i64 {
        bridge::WIND_API_VERSION
    }
    #[func]
    fn last_error(&self) -> GString {
        gs(self.bridge.last_error())
    }
    #[func]
    fn state(&self) -> i64 {
        self.bridge.state()
    }
    #[func]
    fn progress(&self) -> f64 {
        self.bridge.progress()
    }
    #[func]
    fn time_s(&self) -> f64 {
        self.bridge.time_s()
    }
    /// Идентификатор этапа подготовки воздуха (W4 v4; `""` — нет).
    #[func]
    fn stage(&self) -> GString {
        gs(self.bridge.stage())
    }
    /// Итерации решателя в текущем этапе (W3 v3).
    #[func]
    fn iters(&self) -> i64 {
        self.bridge.iters()
    }
    /// Причина состояния FAILED (или пусто).
    #[func]
    fn status_reason(&self) -> GString {
        gs(self.bridge.status_reason())
    }

    #[func]
    fn configure(&mut self, configs_json: PackedStringArray, seed: i64) -> i64 {
        self.bridge.configure(&strings(&configs_json), seed)
    }
    #[func]
    fn load_place(
        &mut self,
        header_json: GString,
        heights: PackedFloat32Array,
        water: PackedByteArray,
        surface_cls: PackedByteArray,
        surface_moist: PackedFloat32Array,
    ) -> i64 {
        self.bridge.load_place(
            &header_json.to_string(),
            heights.as_slice(),
            water.as_slice(),
            surface_cls.as_slice(),
            surface_moist.as_slice(),
        )
    }
    /// Запечённое поле места (TI-К3 v3): `header_json` и тело `.bin` как есть; сразу после
    /// `load_place`, до READY. Коды W1.
    #[func]
    fn add_baked_field(&mut self, header_json: GString, data: PackedByteArray) -> i64 {
        self.bridge
            .add_baked_field(&header_json.to_string(), data.as_slice())
    }
    /// Режим поля (W3 v4): `false` — поле снято, расчётов нет; `true` — вернуть фоном. Коды W1.
    #[func]
    fn set_field_enabled(&mut self, on: bool) -> i64 {
        self.bridge.set_field_enabled(on)
    }
    /// Переходное (W3 v4): закрепить снимок последней подачи поля; номер подачи (`0` — поля нет).
    #[func]
    fn field_export(&mut self) -> i64 {
        self.bridge.field_export()
    }
    /// Номер последней подачи поля без закрепления.
    #[func]
    fn field_version(&self) -> i64 {
        self.bridge.field_version()
    }
    /// Заголовок закреплённого снимка (TI-К3 v3 + `field_version`, `blend_s`, `blend_t0`); нет — `""`.
    #[func]
    fn field_export_header(&self) -> GString {
        gs(self.bridge.field_export_header())
    }
    /// Тело закреплённого снимка (zstd); нет — пусто.
    #[func]
    fn field_export_data(&self) -> PackedByteArray {
        PackedByteArray::from(self.bridge.field_export_data())
    }
    /// Каталог кеша полей (абсолютный путь); пусто — без кеша. Коды W1.
    #[func]
    fn set_cache_dir(&mut self, path: GString) -> i64 {
        self.bridge.set_cache_dir(&path.to_string())
    }
    #[func]
    fn unload_place(&mut self) {
        self.bridge.unload_place();
    }
    #[func]
    fn set_conditions(&mut self, json: GString) -> i64 {
        self.bridge.set_conditions(&json.to_string())
    }
    #[func]
    fn set_sun_direction(&mut self, to_sun: Vector3) {
        self.bridge
            .set_sun_direction([to_sun.x, to_sun.y, to_sun.z]);
    }
    #[func]
    fn set_static_thermals(&mut self, list: PackedFloat32Array, mode: i64) -> i64 {
        self.bridge.set_static_thermals(list.as_slice(), mode)
    }
    #[func]
    fn set_focuses(&mut self, points: PackedVector3Array, weights: PackedFloat32Array) -> i64 {
        self.bridge
            .set_focuses(v3s(points.as_slice()), weights.as_slice())
    }
    #[func]
    fn advance_to(&mut self, t: f64) -> i64 {
        self.bridge.advance_to(t)
    }
    #[func]
    fn start_at(&mut self, t: f64) -> i64 {
        self.bridge.start_at(t)
    }

    /// `[vx, vy, vz, σ]` на точку, длина 4N.
    #[func]
    fn sample_many(&self, points: PackedVector3Array, mode: i64) -> PackedFloat32Array {
        let pts = v3s(points.as_slice());
        packed_n::<4>(pts.len(), |out| self.bridge.sample_many(pts, mode, out))
    }
    #[func]
    fn sample(&self, pos: Vector3, mode: i64) -> Vector4 {
        let mut out = [[0.0f32; 4]; 1];
        self.bridge
            .sample_many(&[[pos.x, pos.y, pos.z]], mode, &mut out);
        Vector4::new(out[0][0], out[0][1], out[0][2], out[0][3])
    }
    #[func]
    fn cloud_density_many(&self, points: PackedVector3Array) -> PackedFloat32Array {
        let pts = v3s(points.as_slice());
        packed_n::<1>(pts.len(), |out| {
            self.bridge.cloud_density_many(pts, out.as_flattened_mut());
        })
    }
    #[func]
    fn cloudbase_msl(&self) -> f64 {
        f64::from(self.bridge.cloudbase_msl())
    }
    /// `[u, v]` на высоту, длина 2N.
    #[func]
    fn background_wind(&self, heights: PackedFloat32Array) -> PackedFloat32Array {
        let h = heights.as_slice();
        packed_n::<2>(h.len(), |out| self.bridge.background_wind(h, out))
    }
    #[func]
    fn weather_json(&self) -> GString {
        gs(self.bridge.weather_json())
    }
    /// Растёт при каждой смене погоды.
    #[func]
    fn weather_version(&self) -> i64 {
        self.bridge.weather_versions().0
    }
    /// Растёт при полной перестройке.
    #[func]
    fn weather_rebuild_version(&self) -> i64 {
        self.bridge.weather_versions().1
    }
    #[func]
    fn sun_state(&self) -> Vector4 {
        let s = self.bridge.sun_state();
        Vector4::new(s[0], s[1], s[2], s[3])
    }

    /// Ядра подъёма, шаг `CORE_STRIDE`.
    #[func]
    fn cores(&mut self, center: Vector3, radius: f64) -> PackedFloat32Array {
        let c = [center.x, center.y, center.z];
        packed(self.bridge.cores(c, radius as f32, &mut self.cores))
    }
    /// Облака, шаг `CLOUD_STRIDE`.
    #[func]
    fn clouds(&mut self, center: Vector3, radius: f64) -> PackedFloat32Array {
        let c = [center.x, center.y, center.z];
        packed(self.bridge.clouds(c, radius as f32, &mut self.clouds))
    }
    /// Гребни волн, шаг `CREST_STRIDE`; `center` — (x, z).
    #[func]
    fn wave_crests(
        &mut self,
        center: Vector2,
        radius: f64,
        min_eta: f64,
        spacing: f64,
    ) -> PackedFloat32Array {
        let r = self.bridge.wave_crests(
            [center.x, center.y],
            radius as f32,
            min_eta as f32,
            spacing as f32,
            &mut self.crests,
        );
        packed(r)
    }

    #[func]
    fn cloud_raster_header(&self) -> GString {
        gs(self.bridge.cloud_raster_header())
    }
    #[func]
    fn cloud_raster_channel(&self, name: GString) -> PackedFloat32Array {
        packed(&self.bridge.cloud_raster_channel(&name.to_string()))
    }
    #[func]
    fn debug_raster_names(&self) -> PackedStringArray {
        self.bridge
            .debug_raster_names()
            .iter()
            .map(|s| GString::from(s.as_str()))
            .collect()
    }
    #[func]
    fn debug_raster_header(&self, name: GString) -> GString {
        gs(self.bridge.debug_raster_header(&name.to_string()))
    }
    #[func]
    fn debug_raster_data(&self, name: GString) -> PackedFloat32Array {
        packed(&self.bridge.debug_raster_data(&name.to_string()))
    }
    /// По слагаемым `[vx, vy, vz, σ]`, затем `total`: длина `4 · (n + 1)`.
    #[func]
    fn decompose(&self, pos: Vector3) -> PackedFloat32Array {
        packed(&self.bridge.decompose([pos.x, pos.y, pos.z]))
    }
    #[func]
    fn decompose_names(&self) -> PackedStringArray {
        self.bridge
            .decompose_names()
            .iter()
            .map(|s| GString::from(s.as_str()))
            .collect()
    }
}
