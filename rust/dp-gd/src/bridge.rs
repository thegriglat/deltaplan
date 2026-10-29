//! Логика `DpAir` без типов Godot (W3): разбор входа, коды W1, `last_error`, пул rayon.
//! Класс gdext в `lib.rs` только переводит типы Godot в срезы и обратно, поэтому всё здесь
//! проверяется `cargo test` без запуска Godot.
use dp_air::{
    AirModel, Cloud, Conditions, Configs, Core, Crest, FieldExport, Focus, OBJ_STRIDE, ObjRecord,
    Place, PlaceHeader, SampleMode, as_f32s,
};
use std::sync::{Arc, OnceLock};

pub const WIND_API_VERSION: i64 = 5;
pub const OK: i64 = 0;
pub const BAD_INPUT: i64 = 1;
pub const NO_PLACE: i64 = 2;
pub const SAMPLE_MEAN: i64 = 1;

static POOL: OnceLock<usize> = OnceLock::new();

/// Один пул rayon на процесс: размер берётся из первого `configure` (`air.threads`;
/// 0 или нет ключа — все ядра минус одно, не меньше одного). Возвращает размер пула.
pub fn init_pool(threads: usize) -> usize {
    *POOL.get_or_init(|| {
        let n = if threads == 0 {
            std::thread::available_parallelism()
                .map_or(1, |v| v.get().saturating_sub(1))
                .max(1)
        } else {
            threads
        };
        // Глобальный пул мог создать кто-то раньше (тесты) — тогда остаётся его размер.
        let _ = rayon::ThreadPoolBuilder::new()
            .num_threads(n)
            .thread_name(|i| format!("dp-air-{i}"))
            .build_global();
        rayon::current_num_threads()
    })
}

pub struct Bridge {
    model: Box<dyn AirModel>,
    last_error: String,
    seed_default: u64,
    /// Закреплённый снимок поля (`field_export`, W3 v4) до следующего `field_export`.
    export: Option<FieldExport>,
}

impl Default for Bridge {
    fn default() -> Self {
        Self::new(Box::new(dp_air::Formula::new()))
    }
}

fn finite3(p: &[f32; 3]) -> bool {
    p.iter().all(|v| v.is_finite())
}

impl Bridge {
    pub fn new(model: Box<dyn AirModel>) -> Self {
        Bridge {
            model,
            last_error: String::new(),
            seed_default: 0,
            export: None,
        }
    }

    pub fn last_error(&self) -> &str {
        &self.last_error
    }

    fn fail(&mut self, code: i64, msg: impl Into<String>) -> i64 {
        self.last_error = msg.into();
        code
    }

    fn done(&mut self, r: Result<(), dp_air::Error>) -> i64 {
        match r {
            Ok(()) => {
                self.last_error.clear();
                OK
            }
            Err(e) => {
                let code = i64::from(e.code.as_int());
                self.fail(code, e.msg)
            }
        }
    }

    /// `pairs` — имя, текст, имя, текст… Сид `< 0` — из `seed` конфига `atmosphere`.
    pub fn configure(&mut self, pairs: &[String], seed: i64) -> i64 {
        if !pairs.len().is_multiple_of(2) {
            return self.fail(
                BAD_INPUT,
                "configure: pairs must be name, text, name, text...",
            );
        }
        let cfg = Configs::new(
            pairs
                .chunks_exact(2)
                .map(|c| (c[0].clone(), c[1].clone()))
                .collect(),
        );
        let parsed = match cfg.parse() {
            Ok(p) => p,
            Err(e) => return self.done(Err(e)),
        };
        let atmo = parsed
            .iter()
            .find(|(n, _)| *n == "atmosphere")
            .map(|(_, v)| v);
        let threads = atmo
            .and_then(|v| v.pointer("/air/threads"))
            .and_then(|v| v.as_u64())
            .unwrap_or(0) as usize;
        let cfg_seed = atmo.and_then(|v| v.get("seed")).and_then(|v| v.as_u64());
        drop(parsed);
        init_pool(threads);
        if let Some(s) = cfg_seed {
            self.seed_default = s;
        }
        let seed = u64::try_from(seed).unwrap_or(self.seed_default);
        let r = self.model.configure(&cfg, seed);
        self.done(r)
    }

    pub fn load_place(
        &mut self,
        header_json: &str,
        heights: &[f32],
        water: &[u8],
        cls: &[u8],
        moist: &[f32],
    ) -> i64 {
        let place = PlaceHeader::from_json(header_json).and_then(|h| {
            Place::new(
                h,
                heights.to_vec(),
                water.to_vec(),
                cls.to_vec(),
                moist.to_vec(),
            )
        });
        let r = place.and_then(|p| self.model.load_place(p));
        self.done(r)
    }

    /// W3 v2: каталог кеша полей; пусто — без кеша.
    pub fn set_cache_dir(&mut self, path: &str) -> i64 {
        let r = self.model.set_cache_dir(path);
        self.done(r)
    }

    /// W3 v4: закрепляет снимок последней подачи поля; возвращает его номер (`0` — поля нет).
    pub fn field_export(&mut self) -> i64 {
        let e = self.model.field_export();
        let v = e.version as i64;
        self.export = Some(e);
        v
    }

    /// Номер последней подачи без закрепления.
    pub fn field_version(&self) -> i64 {
        self.model.field_version() as i64
    }

    /// Заголовок закреплённого снимка: нет снимка или поля — `""`.
    pub fn field_export_header(&self) -> String {
        self.export
            .as_ref()
            .map_or_else(String::new, |e| e.header_json.clone())
    }

    /// Тело закреплённого снимка; нет — пусто.
    pub fn field_export_data(&self) -> &[u8] {
        self.export.as_ref().map_or(&[], |e| e.data.as_slice())
    }

    pub fn unload_place(&mut self) {
        self.model.unload_place();
    }

    pub fn set_conditions(&mut self, json: &str) -> i64 {
        let r = Conditions::from_json(json).and_then(|c| self.model.set_conditions(&c));
        self.done(r)
    }

    /// Нулевой или не конечный вектор — «солнце не задано» (реализация считает сама).
    pub fn set_sun_direction(&mut self, to_sun: [f32; 3]) {
        let ok = finite3(&to_sun) && to_sun.iter().any(|v| *v != 0.0);
        self.model.set_sun_direction(ok.then_some(to_sun));
    }

    pub fn set_static_thermals(&mut self, list: &[f32], mode: i64) -> i64 {
        if !(0..=2).contains(&mode) {
            return self.fail(
                BAD_INPUT,
                format!("set_static_thermals: mode {mode} not in 0..2"),
            );
        }
        if !list.len().is_multiple_of(4) {
            return self.fail(
                BAD_INPUT,
                format!(
                    "set_static_thermals: length {} is not a multiple of 4",
                    list.len()
                ),
            );
        }
        let v: Vec<[f32; 4]> = list
            .chunks_exact(4)
            .map(|c| [c[0], c[1], c[2], c[3]])
            .collect();
        let r = self.model.set_static_thermals(&v, mode as u8);
        self.done(r)
    }

    pub fn set_focuses(&mut self, points: &[[f32; 3]], weights: &[f32]) -> i64 {
        if points.len() != weights.len() {
            return self.fail(
                BAD_INPUT,
                format!(
                    "set_focuses: {} points, {} weights",
                    points.len(),
                    weights.len()
                ),
            );
        }
        let f: Vec<Focus> = points
            .iter()
            .zip(weights)
            .map(|(p, w)| Focus {
                pos: *p,
                weight: *w,
            })
            .collect();
        let r = self.model.set_focuses(&f);
        self.done(r)
    }

    pub fn advance_to(&mut self, t: f64) -> i64 {
        let r = self.model.advance_to(t);
        self.done(r)
    }

    pub fn start_at(&mut self, t: f64) -> i64 {
        let r = self.model.start_at(t);
        self.done(r)
    }

    pub fn state(&self) -> i64 {
        i64::from(self.model.status().state.as_int())
    }

    pub fn progress(&self) -> f64 {
        f64::from(self.model.status().progress)
    }

    pub fn time_s(&self) -> f64 {
        self.model.status().time_s
    }

    pub fn status_reason(&self) -> String {
        self.model.status().reason
    }

    /// Идентификатор этапа задачи поля (`""` — нет).
    pub fn stage(&self) -> String {
        self.model.status().stage
    }

    /// Итерации решателя в текущем этапе.
    pub fn iters(&self) -> i64 {
        i64::from(self.model.status().iters)
    }

    pub fn sample_many(&self, pts: &[[f32; 3]], mode: i64, out: &mut [[f32; 4]]) {
        let m = if mode == SAMPLE_MEAN {
            SampleMode::Mean
        } else {
            SampleMode::Full
        };
        self.model.sample_many(pts, m, out);
    }

    pub fn cloud_density_many(&self, pts: &[[f32; 3]], out: &mut [f32]) {
        self.model.cloud_density_many(pts, out);
    }

    pub fn background_wind(&self, heights: &[f32], out: &mut [[f32; 2]]) {
        self.model.background_wind(heights, out);
    }

    pub fn cloudbase_msl(&self) -> f32 {
        self.model.cloudbase_msl()
    }

    pub fn weather_json(&self) -> String {
        self.model.weather_json()
    }

    /// (мягкая версия, версия перестройки); в int Godot — без потерь до 2^63.
    pub fn weather_versions(&self) -> (i64, i64) {
        let (a, b) = self.model.weather_version();
        (a.min(i64::MAX as u64) as i64, b.min(i64::MAX as u64) as i64)
    }

    pub fn sun_state(&self) -> [f32; 4] {
        self.model.sun_state()
    }

    /// Описания W6 плоским массивом (`CORE_STRIDE` = 15 и т. д.) в переданный буфер.
    pub fn cores<'a>(&self, center: [f32; 3], radius: f32, buf: &'a mut Vec<Core>) -> &'a [f32] {
        self.model.cores(center, radius, buf);
        as_f32s(buf)
    }

    pub fn clouds<'a>(&self, center: [f32; 3], radius: f32, buf: &'a mut Vec<Cloud>) -> &'a [f32] {
        self.model.clouds(center, radius, buf);
        as_f32s(buf)
    }

    pub fn wave_crests<'a>(
        &self,
        center: [f32; 2],
        radius: f32,
        min_eta: f32,
        spacing: f32,
        buf: &'a mut Vec<Crest>,
    ) -> &'a [f32] {
        self.model
            .wave_crests(center, radius, min_eta, spacing, buf);
        as_f32s(buf)
    }

    /// Объекты-облака W6 v4, шаг `OBJ_STRIDE`: `radius < 0` - без ограничения, `t` не конечно -
    /// текущее время модели; центр или радиус не числа - пусто.
    pub fn cloud_objects<'a>(
        &self,
        center: [f32; 3],
        radius: f32,
        t: f64,
        buf: &'a mut Vec<ObjRecord>,
    ) -> &'a [f32] {
        if !finite3(&center) || radius.is_nan() {
            buf.clear();
            return &[];
        }
        let t = if t.is_finite() { t } else { self.time_s() };
        self.model.cloud_objects(center, radius, t, buf);
        obj_f32s(buf)
    }

    /// `[enabled, wavelength_m]`; нечисло в ответе модели - 0.
    ///
    /// ```
    /// let b = dp_gd::bridge::Bridge::new(Box::new(dp_air::Calm::new()));
    /// assert_eq!(b.wave_info(), [0.0, 0.0]);
    /// ```
    pub fn wave_info(&self) -> [f32; 2] {
        self.model
            .wave_info()
            .map(|v| if v.is_finite() { v } else { 0.0 })
    }

    /// Порыв у поверхности: длина результата - минимум длин `xz` и `t`; нечисловой вход
    /// (точка или момент) даёт 0. Входы - срезы без копирования.
    pub fn surface_gust_many(&self, xz: &[[f32; 2]], t: &[f64], out: &mut Vec<f32>) {
        let n = xz.len().min(t.len());
        out.clear();
        out.resize(n, 0.0);
        self.model.surface_gust_many(&xz[..n], &t[..n], out);
        for ((o, p), &ti) in out.iter_mut().zip(xz).zip(t) {
            if !(p[0].is_finite() && p[1].is_finite() && ti.is_finite() && o.is_finite()) {
                *o = 0.0;
            }
        }
    }

    /// Заголовок растра облаков (json): `{version, nx, ny, dx, x0, z0, base_msl, time_s, layers}`;
    /// нет растра — `{"version":0}`.
    pub fn cloud_raster_header(&self) -> String {
        raster_header(self.model.cloud_raster())
    }

    pub fn cloud_raster_channel(&self, name: &str) -> Vec<f32> {
        layer(self.model.cloud_raster(), name)
    }

    pub fn debug_raster_names(&self) -> Vec<String> {
        self.model.debug_raster_names()
    }

    pub fn debug_raster_header(&self, name: &str) -> String {
        raster_header(self.model.debug_raster(name))
    }

    pub fn debug_raster_data(&self, name: &str) -> Vec<f32> {
        layer(self.model.debug_raster(name), "data")
    }

    pub fn decompose_names(&self) -> Vec<String> {
        self.model.decompose([0.0; 3]).names
    }

    /// По слагаемым `[vx, vy, vz, σ]` подряд, затем `total` (всего `4 · (n + 1)` чисел).
    pub fn decompose(&self, p: [f32; 3]) -> Vec<f32> {
        let d = self.model.decompose(p);
        let mut v = Vec::with_capacity(4 * (d.names.len() + 1));
        for (vel, s) in d.vel.iter().zip(&d.sigma) {
            v.extend_from_slice(vel);
            v.push(*s);
        }
        v.resize(4 * d.names.len(), 0.0);
        v.extend_from_slice(&d.total);
        v
    }
}

fn raster_header(r: Option<Arc<dp_air::Raster>>) -> String {
    match r {
        None => r#"{"version":0}"#.into(),
        Some(r) => serde_json::json!({
            "version": r.version, "nx": r.nx, "ny": r.ny, "dx": r.dx, "x0": r.x0, "z0": r.z0,
            "base_msl": json_num(r.base_msl as f64), "time_s": json_num(r.time_s),
            "layers": r.layers.iter().map(|(n, _)| n.as_str()).collect::<Vec<_>>(),
        })
        .to_string(),
    }
}

/// NaN (у отладочных растров `base_msl`/`time_s`) в json — `null`.
fn json_num(v: f64) -> serde_json::Value {
    serde_json::Number::from_f64(v).map_or(serde_json::Value::Null, Into::into)
}

fn layer(r: Option<Arc<dp_air::Raster>>, name: &str) -> Vec<f32> {
    r.and_then(|r| {
        r.layers
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, d)| d.clone())
    })
    .unwrap_or_default()
}

/// Записи объектов как плоский `&[f32]` без копирования.
fn obj_f32s(v: &[ObjRecord]) -> &[f32] {
    const { assert!(size_of::<ObjRecord>() == OBJ_STRIDE * 4 && align_of::<ObjRecord>() == 4) };
    // SAFETY: ObjRecord - repr(C) из 22 f32 без отступов (const-assert здесь и в dp-air).
    unsafe { std::slice::from_raw_parts(v.as_ptr().cast::<f32>(), v.len() * OBJ_STRIDE) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use dp_air::Formula;

    const HEADER: &str = r#"{"version":1,"loc":{"id":"training_island","center_lat":43.2,
"center_lon":34.0,"utc_offset_h":2.0,"month":7,"day":15},"grid":{"origin_x":-100,"origin_z":-100,
"spacing":50,"width":4,"height":4},"surface_classes":{"grass":1},"start_sites":[],
"model_hash":"50e249bed5ee6b3c"}"#;

    /// W3 v2: код `set_cache_dir` и `header.model_hash` через `load_place` до
    /// трейта (`Formula`); `Calm` принимает молча.
    #[test]
    fn cache_dir_reaches_the_model() {
        let mut b = Bridge::new(Box::new(Formula::new()));
        assert_eq!(b.set_cache_dir("/tmp/dp-air-cache"), OK);
        assert_eq!(b.set_cache_dir(""), OK);
        assert_eq!(b.configure(&["wind".into(), "{}".into()], 1), OK);
        let n = 16;
        assert_eq!(
            b.load_place(
                HEADER,
                &vec![10.0; n],
                &vec![0; n],
                &vec![1; n],
                &vec![0.5; n]
            ),
            OK
        );
        let mut calm = Bridge::new(Box::new(dp_air::Calm::new()));
        assert_eq!(calm.set_cache_dir("/x"), OK);
    }

    /// W3 v4: выдача поля через мост (`Calm` — пусто, Ok).
    #[test]
    fn field_export_bridge() {
        let mut calm = Bridge::new(Box::new(dp_air::Calm::new()));
        assert_eq!(calm.field_version(), 0);
        assert_eq!(calm.field_export(), 0);
        assert_eq!(calm.field_export_header(), "");
        assert!(calm.field_export_data().is_empty());
        let mut f = Bridge::new(Box::new(Formula::new()));
        assert_eq!(f.field_export(), 0);
    }
}
