//! Класс `DpAir` (W3, gdext) поверх `dp-air`. Модель по умолчанию — `Formula` (RW-7b).
//!
//! Вход — срезы массивов Godot без копирования; выход — запись прямо в `Packed*Array` результата
//! (одно выделение, ноль промежуточных `Vec` в горячем пути `sample_many`).
//! Рабочие потоки Rust объекты Godot не трогают.

pub mod bridge;
pub mod weather;

use bridge::Bridge;
use dp_air::{Cloud, Core, Crest, ObjRecord};
use godot::prelude::*;
use weather::WeatherBridge;

struct DpAirExt;

#[gdextension]
unsafe impl ExtensionLibrary for DpAirExt {
    /// Последняя ступень выгрузки: потоки крейта (в т.ч. запись кеша поля после отмены задачи)
    /// не должны исполнять код библиотеки, пока Godot её выгружает (RW-28, иначе SIGSEGV).
    fn on_stage_deinit(stage: InitStage) {
        if stage == InitStage::Core && !dp_air::join_background(std::time::Duration::from_secs(30))
        {
            godot_warn!("dp_air: фоновые задачи не закончились за 30 с при выходе");
        }
    }
}

// Cast срезов Vector3/Vector2 в [f32; N] опирается на раскладку gdext (repr(C), f32).
const _: () = {
    assert!(size_of::<Vector3>() == 12 && align_of::<Vector3>() == 4);
    assert!(size_of::<Vector2>() == 8 && align_of::<Vector2>() == 4);
};

fn v3s(v: &[Vector3]) -> &[[f32; 3]] {
    // SAFETY: Vector3 — repr(C) { x, y, z: f32 }, размер и выравнивание проверены const-assert.
    unsafe { std::slice::from_raw_parts(v.as_ptr().cast(), v.len()) }
}

fn v2s(v: &[Vector2]) -> &[[f32; 2]] {
    // SAFETY: Vector2 - repr(C) { x, y: f32 }, размер и выравнивание проверены const-assert.
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
    objects: Vec<ObjRecord>,
    gust: Vec<f32>,
    base: Base<RefCounted>,
}

#[godot_api]
impl DpAir {
    #[constant]
    pub const WIND_API_VERSION: i64 = 6;
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
    #[constant]
    pub const OBJ_STRIDE: i64 = 22;
    #[constant]
    pub const WAVE_INFO_SIZE: i64 = 2;

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
    /// Номер прогона решателя в задаче поля, с 1 (W3 v8; 0 — нет этапа с итерациями).
    #[func]
    fn run(&self) -> i64 {
        self.bridge.run()
    }
    /// Прогонов по текущему плану (W3 v8; `>= run`).
    #[func]
    fn runs(&self) -> i64 {
        self.bridge.runs()
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
    /// Общая погода (W3 v9, W12) до `load_place`; `null` или неготовая — `BAD_INPUT`.
    #[func]
    fn attach_weather(&mut self, w: Option<Gd<DpWeather>>) -> i64 {
        let arc = w.and_then(|w| w.bind().inner.arc());
        self.bridge.attach_weather(arc)
    }
    /// Контекст загруженного места (json, W3 v9); места нет — `{}`.
    #[func]
    fn place_context(&self) -> GString {
        gs(self.bridge.place_context())
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
        packed(&self.bridge.cores(c, radius as f32, &mut self.cores))
    }
    /// Облака, шаг `CLOUD_STRIDE`.
    #[func]
    fn clouds(&mut self, center: Vector3, radius: f64) -> PackedFloat32Array {
        let c = [center.x, center.y, center.z];
        packed(&self.bridge.clouds(c, radius as f32, &mut self.clouds))
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
        packed(&r)
    }
    /// Объекты-облака W6 v4, шаг `OBJ_STRIDE`; `radius < 0` - без ограничения, `t` не конечно -
    /// текущее время.
    #[func]
    fn cloud_objects(&mut self, center: Vector3, radius: f64, t: f64) -> PackedFloat32Array {
        let c = [center.x, center.y, center.z];
        packed(
            &self
                .bridge
                .cloud_objects(c, radius as f32, t, &mut self.objects),
        )
    }
    /// `[enabled, wavelength_m]`.
    #[func]
    fn wave_info(&self) -> PackedFloat32Array {
        packed(&self.bridge.wave_info())
    }
    /// Порыв у поверхности на точку (`xz` - x, z мира) и момент; длина - минимум длин.
    #[func]
    fn surface_gust_many(
        &mut self,
        xz: PackedVector2Array,
        t: PackedFloat64Array,
    ) -> PackedFloat32Array {
        let pts = v2s(xz.as_slice());
        self.bridge
            .surface_gust_many(pts, t.as_slice(), &mut self.gust);
        packed(&self.gust)
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

/// Погода (W12 v2): чистые функции над `Arc<Weather>`; словари — json-строкой.
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct DpWeather {
    inner: WeatherBridge,
    base: Base<RefCounted>,
}

#[godot_api]
impl DpWeather {
    /// Конфиги как у `DpAir.configure`, сетки (`hh1`, `hh2`, `hh5`, `hh6`) распакованными байтами.
    #[func]
    fn configure(
        &mut self,
        configs_json: PackedStringArray,
        grid_names: PackedStringArray,
        grid_bytes: Array<PackedByteArray>,
    ) -> i64 {
        let bytes: Vec<PackedByteArray> = grid_bytes.iter_shared().collect();
        let slices: Vec<&[u8]> = bytes.iter().map(|b| b.as_slice()).collect();
        self.inner
            .configure(&strings(&configs_json), &strings(&grid_names), &slices)
    }
    #[func]
    fn typical_max_c(&self, month: i64, day: i64, lat: f64, lon: f64, valley_msl_m: f64) -> f64 {
        self.inner.typical_max_c(month, day, lat, lon, valley_msl_m)
    }
    #[func]
    fn diurnal_state(&self, t_max: f64, hour: f64, ctx_json: GString) -> GString {
        gs(self.inner.diurnal_state(t_max, hour, &ctx_json.to_string()))
    }
    #[func]
    fn sunrise_h(&self, t_max: f64, ctx_json: GString) -> f64 {
        self.inner.sunrise_h(t_max, &ctx_json.to_string())
    }
    #[func]
    fn sunset_h(&self, t_max: f64, ctx_json: GString) -> f64 {
        self.inner.sunset_h(t_max, &ctx_json.to_string())
    }
    /// `[cover, sky_heat]`; до `configure` - пусто.
    #[func]
    fn sky_params(&self, sky: GString) -> PackedFloat32Array {
        packed(&self.inner.sky_params(&sky.to_string()))
    }
    #[func]
    fn derive(&self, forecast_json: GString, ctx_json: GString, hour: f64) -> GString {
        gs(self
            .inner
            .derive(&forecast_json.to_string(), &ctx_json.to_string(), hour))
    }
    #[func]
    fn air_temp_c(&self, hour: f64, t_max: f64, z: f64, ctx_json: GString) -> f64 {
        self.inner.air_temp_c(hour, t_max, z, &ctx_json.to_string())
    }
    #[func]
    fn water_temp_c(&self, month: i64, day: i64, z: f64, ctx_json: GString) -> f64 {
        self.inner
            .water_temp_c(month, day, z, &ctx_json.to_string())
    }
    #[func]
    fn temp_at_altitude(&self, weather_json: GString, alt_msl: f64, month: i64, day: i64) -> f64 {
        self.inner
            .temp_at_altitude(&weather_json.to_string(), alt_msl, month, day)
    }
    #[func]
    fn climate_cell(&self, lat: f64, lon: f64, month: i64, day: i64) -> GString {
        gs(self.inner.climate_cell(lat, lon, month, day))
    }
    #[func]
    fn reference_context(&self) -> GString {
        gs(self.inner.reference_context())
    }
    #[func]
    fn quantum_h(&self) -> f64 {
        self.inner.quantum_h()
    }
    #[func]
    fn hour_at(&self, start_hour: f64, speed: f64, t: f64) -> f64 {
        self.inner.hour_at(start_hour, speed, t)
    }
    #[func]
    fn valley_of(&self, samples: PackedFloat32Array, percentile: f64) -> f64 {
        self.inner.valley_of(samples.as_slice(), percentile)
    }
}
