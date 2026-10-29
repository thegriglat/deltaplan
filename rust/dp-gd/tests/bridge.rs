//! Разбор входа и коды W1 в границе `DpAir` — без запуска Godot.
use dp_gd::bridge::*;

const HEADER: &str = r#"{"version":1,"loc":{"id":"t","center_lat":50.0,"center_lon":86.0,
"utc_offset_h":7.0,"month":7,"day":1},"grid":{"origin_x":-100,"origin_z":-100,"spacing":50,
"width":4,"height":4},"surface_classes":{"grass":1},"start_sites":[]}"#;

fn loaded() -> Bridge {
    let mut b = Bridge::new(Box::new(dp_air::Calm::new()));
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
    b
}

#[test]
fn api_version_is_4() {
    assert_eq!(WIND_API_VERSION, 5);
    assert_eq!(WIND_API_VERSION, i64::from(dp_air::API_VERSION));
}

#[test]
fn stage_and_iters_are_empty_without_a_job() {
    let b = Bridge::new(Box::new(dp_air::Calm::new()));
    assert_eq!((b.stage().as_str(), b.iters()), ("", 0));
}

#[test]
fn load_place_checks_lengths_and_nan() {
    let mut b = Bridge::new(Box::new(dp_air::Calm::new()));
    let ok = (
        vec![1.0f32; 16],
        vec![0u8; 16],
        vec![1u8; 16],
        vec![0.5f32; 16],
    );
    assert_eq!(b.load_place("{bad", &ok.0, &ok.1, &ok.2, &ok.3), BAD_INPUT);
    assert!(!b.last_error().is_empty());
    assert_eq!(
        b.load_place(HEADER, &ok.0[..15], &ok.1, &ok.2, &ok.3),
        BAD_INPUT
    );
    let mut h = ok.0.clone();
    h[3] = f32::NAN;
    assert_eq!(b.load_place(HEADER, &h, &ok.1, &ok.2, &ok.3), BAD_INPUT);
    assert_eq!(b.state(), 0, "bad input keeps EMPTY");
    assert_eq!(b.load_place(HEADER, &ok.0, &ok.1, &ok.2, &ok.3), OK);
    assert_eq!(b.last_error(), "");
    assert_eq!(b.state(), 2);
}

#[test]
fn array_lengths_are_checked() {
    let mut b = loaded();
    assert_eq!(b.set_static_thermals(&[1.0, 2.0, 3.0], 0), BAD_INPUT);
    assert_eq!(b.set_static_thermals(&[1.0, 2.0, 3.0, 4.0], 3), BAD_INPUT);
    assert_eq!(
        b.set_static_thermals(&[1.0, 2.0, f32::NAN, 4.0], 1),
        BAD_INPUT
    );
    assert_eq!(b.set_static_thermals(&[1.0, 2.0, 3.0, 4.0], 2), OK);
    assert_eq!(b.set_focuses(&[[0.0; 3]; 2], &[1.0]), BAD_INPUT);
    assert_eq!(b.set_focuses(&[[f32::NAN; 3]], &[1.0]), BAD_INPUT);
    assert_eq!(b.set_focuses(&[[0.0; 3]], &[1.0]), OK);
    assert_eq!(b.configure(&["only_name".into()], 1), BAD_INPUT);
    assert_eq!(b.configure(&["wind".into(), "{x".into()], 1), BAD_INPUT);
    assert_eq!(b.configure(&["wind".into(), "{}".into()], 1), OK);
}

#[test]
fn time_codes_and_no_place() {
    let mut b = Bridge::new(Box::new(dp_air::Calm::new()));
    assert_eq!(b.advance_to(1.0), NO_PLACE);
    assert_eq!(b.start_at(1.0), NO_PLACE);
    let mut b = loaded();
    assert_eq!(b.advance_to(f64::NAN), BAD_INPUT);
    assert_eq!(b.advance_to(-1.0), BAD_INPUT);
    assert_eq!(b.advance_to(2.0), OK);
    assert_eq!(b.advance_to(1.0), BAD_INPUT);
    assert_eq!(b.time_s(), 2.0);
    b.unload_place();
    assert_eq!(b.state(), 0);
    assert_eq!(b.advance_to(3.0), NO_PLACE);
}

#[test]
fn conditions_and_sun() {
    let mut b = Bridge::new(Box::new(dp_air::Calm::new()));
    assert_eq!(b.set_conditions("{}"), BAD_INPUT);
    assert_eq!(
        b.set_conditions(r#"{"preset":"weather/medium","start_hour":12,"speed":1}"#),
        OK
    );
    b.set_sun_direction([0.0; 3]);
    b.set_sun_direction([f32::NAN, 0.0, 1.0]);
    b.set_sun_direction([0.0, 1.0, 0.0]);
}

#[test]
fn queries_fill_exact_lengths_and_calm_is_zero() {
    let b = loaded();
    let pts = [[0.0, 100.0, 0.0], [f32::NAN, 0.0, 0.0], [5.0, 5.0, 5.0]];
    let mut out = [[1.0f32; 4]; 3];
    b.sample_many(&pts, 0, &mut out);
    assert!(out.iter().flatten().all(|v| *v == 0.0));
    b.sample_many(&[], SAMPLE_MEAN, &mut []);
    let mut bw = [[1.0f32; 2]; 2];
    b.background_wind(&[10.0, 20.0], &mut bw);
    assert_eq!(bw, [[0.0; 2]; 2]);
    let (mut cores, mut clouds, mut crests) = (vec![Default::default(); 2], vec![], vec![]);
    assert!(b.cores([0.0; 3], 1e3, &mut cores).is_empty());
    assert!(b.clouds([0.0; 3], 1e3, &mut clouds).is_empty());
    assert!(
        b.wave_crests([0.0; 2], 1e3, 0.0, 1.0, &mut crests)
            .is_empty()
    );
    assert_eq!(b.cloud_raster_header(), r#"{"version":0}"#);
    assert!(b.cloud_raster_channel("cover").is_empty());
    assert!(b.debug_raster_names().is_empty());
    assert_eq!(b.decompose([0.0; 3]), vec![0.0; 4]);
    assert_eq!(b.weather_versions(), (0, 0));
    assert_eq!(b.weather_json(), "{}");
}

#[test]
fn pool_is_created_once_with_config_threads() {
    let mut b = Bridge::new(Box::new(dp_air::Calm::new()));
    let cfg = r#"{"air":{"threads":2},"seed":7}"#;
    assert_eq!(b.configure(&["atmosphere".into(), cfg.into()], -1), OK);
    let n = init_pool(5);
    assert!(n >= 1);
    assert_eq!(init_pool(1), n, "pool size is fixed after first init");
}

/// Модель с ответами W4 v6 для проверки разбора: два облака, волна, порыв = x + t; остальное -
/// `Calm`.
struct Objs(dp_air::Calm);

impl dp_air::AirModel for Objs {
    fn configure(&mut self, c: &dp_air::Configs, s: u64) -> Result<(), dp_air::Error> {
        self.0.configure(c, s)
    }
    fn load_place(&mut self, p: dp_air::Place) -> Result<(), dp_air::Error> {
        self.0.load_place(p)
    }
    fn unload_place(&mut self) {
        self.0.unload_place();
    }
    fn set_conditions(&mut self, c: &dp_air::Conditions) -> Result<(), dp_air::Error> {
        self.0.set_conditions(c)
    }
    fn set_sun_direction(&mut self, d: Option<[f32; 3]>) {
        self.0.set_sun_direction(d);
    }
    fn set_static_thermals(&mut self, l: &[[f32; 4]], m: u8) -> Result<(), dp_air::Error> {
        self.0.set_static_thermals(l, m)
    }
    fn set_focuses(&mut self, f: &[dp_air::Focus]) -> Result<(), dp_air::Error> {
        self.0.set_focuses(f)
    }
    fn advance_to(&mut self, t: f64) -> Result<(), dp_air::Error> {
        self.0.advance_to(t)
    }
    fn start_at(&mut self, t: f64) -> Result<(), dp_air::Error> {
        self.0.start_at(t)
    }
    fn status(&self) -> dp_air::Status {
        dp_air::Status {
            time_s: 42.0,
            ..self.0.status()
        }
    }
    fn sample_many(&self, p: &[[f32; 3]], m: dp_air::SampleMode, o: &mut [[f32; 4]]) {
        self.0.sample_many(p, m, o);
    }
    fn cloud_density_many(&self, p: &[[f32; 3]], o: &mut [f32]) {
        self.0.cloud_density_many(p, o);
    }
    fn cloudbase_msl(&self) -> f32 {
        self.0.cloudbase_msl()
    }
    fn background_wind(&self, h: &[f32], o: &mut [[f32; 2]]) {
        self.0.background_wind(h, o);
    }
    fn weather_json(&self) -> String {
        self.0.weather_json()
    }
    fn weather_version(&self) -> (u64, u64) {
        self.0.weather_version()
    }
    fn sun_state(&self) -> [f32; 4] {
        self.0.sun_state()
    }
    fn cores(&self, c: [f32; 3], r: f32, o: &mut Vec<dp_air::Core>) {
        self.0.cores(c, r, o);
    }
    fn clouds(&self, c: [f32; 3], r: f32, o: &mut Vec<dp_air::Cloud>) {
        self.0.clouds(c, r, o);
    }
    fn cloud_raster(&self) -> Option<std::sync::Arc<dp_air::Raster>> {
        self.0.cloud_raster()
    }
    fn wave_crests(&self, c: [f32; 2], r: f32, e: f32, sp: f32, o: &mut Vec<dp_air::Crest>) {
        self.0.wave_crests(c, r, e, sp, o);
    }
    fn decompose(&self, p: [f32; 3]) -> dp_air::Decomposition {
        self.0.decompose(p)
    }
    fn debug_raster(&self, n: &str) -> Option<std::sync::Arc<dp_air::Raster>> {
        self.0.debug_raster(n)
    }
    fn debug_raster_names(&self) -> Vec<String> {
        self.0.debug_raster_names()
    }
    fn cloud_objects(&self, c: [f32; 3], r: f32, t: f64, out: &mut Vec<dp_air::ObjRecord>) {
        out.clear();
        for i in 0..2 {
            out.push(dp_air::ObjRecord {
                id: i as f32,
                cx: c[0] + i as f32,
                base_msl: if r < 0.0 { -1.0 } else { r },
                life_t0: t as f32,
                ..Default::default()
            });
        }
    }
    fn wave_info(&self) -> [f32; 2] {
        [1.0, f32::NAN]
    }
    fn surface_gust_many(&self, xz: &[[f32; 2]], t: &[f64], out: &mut [f32]) {
        for ((o, p), &ti) in out.iter_mut().zip(xz).zip(t) {
            *o = p[0] + ti as f32;
        }
    }
}

fn objs() -> Bridge {
    Bridge::new(Box::new(Objs(dp_air::Calm::new())))
}

#[test]
fn w3_v5_defaults_are_empty_and_zero() {
    let b = Bridge::new(Box::new(dp_air::Calm::new()));
    let mut buf = Vec::new();
    assert!(
        b.cloud_objects([0.0; 3], -1.0, f64::NAN, &mut buf)
            .is_empty()
    );
    assert_eq!(b.wave_info(), [0.0; 2]);
    let mut out = vec![9.0];
    b.surface_gust_many(&[[0.0; 2]; 3], &[0.0; 2], &mut out);
    assert_eq!(out, vec![0.0; 2]);
    b.surface_gust_many(&[], &[1.0], &mut out);
    assert!(out.is_empty());
}

#[test]
fn cloud_objects_flat_stride_and_args() {
    let b = objs();
    let mut buf = Vec::new();
    let f = b.cloud_objects([5.0, 0.0, 0.0], 100.0, 7.0, &mut buf);
    assert_eq!(f.len(), 2 * dp_air::OBJ_STRIDE);
    assert_eq!(f[0], 0.0);
    assert_eq!(f[2], 5.0, "cx первой записи");
    assert_eq!(f[dp_air::OBJ_STRIDE], 1.0, "id второй");
    assert_eq!(f[dp_air::OBJ_STRIDE + 2], 6.0);
    assert_eq!(f[4], 100.0, "radius передан как есть");
    assert_eq!(f[13], 7.0, "t передан");
    let f = b.cloud_objects([0.0; 3], -1.0, 1.0, &mut buf);
    assert_eq!(f[4], -1.0, "radius < 0 доходит до модели");
}

#[test]
fn cloud_objects_nonfinite_t_is_current_time_and_bad_args_are_empty() {
    let b = objs();
    let mut buf = Vec::new();
    for t in [f64::NAN, f64::INFINITY] {
        let f = b.cloud_objects([0.0; 3], 1.0, t, &mut buf);
        assert_eq!(f[13], 42.0, "t не конечно - текущее");
    }
    assert!(
        b.cloud_objects([f32::NAN, 0.0, 0.0], 1.0, 0.0, &mut buf)
            .is_empty()
    );
    assert!(
        b.cloud_objects([0.0; 3], f32::NAN, 0.0, &mut buf)
            .is_empty()
    );
    assert!(buf.is_empty());
}

#[test]
fn wave_info_nonfinite_is_zero() {
    assert_eq!(objs().wave_info(), [1.0, 0.0]);
}

#[test]
fn surface_gust_many_min_length_and_nonfinite_input() {
    let b = objs();
    let mut out = Vec::new();
    b.surface_gust_many(
        &[[1.0, 0.0], [2.0, 0.0], [3.0, 0.0]],
        &[10.0, 20.0],
        &mut out,
    );
    assert_eq!(out, vec![11.0, 22.0], "min длин");
    b.surface_gust_many(
        &[
            [1.0, 0.0],
            [f32::NAN, 0.0],
            [3.0, f32::INFINITY],
            [4.0, 0.0],
        ],
        &[10.0, 20.0, 30.0, f64::NAN],
        &mut out,
    );
    assert_eq!(out, vec![11.0, 0.0, 0.0, 0.0], "нечисловой вход - 0");
    b.surface_gust_many(&[[1.0, 0.0]], &[], &mut out);
    assert!(out.is_empty());
}
