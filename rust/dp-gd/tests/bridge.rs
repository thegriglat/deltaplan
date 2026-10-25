//! Разбор входа и коды W1 в границе `DpAir` — без запуска Godot.
use dp_gd::bridge::*;

const HEADER: &str = r#"{"version":1,"loc":{"id":"t","center_lat":50.0,"center_lon":86.0,
"utc_offset_h":7.0,"month":7,"day":1},"grid":{"origin_x":-100,"origin_z":-100,"spacing":50,
"width":4,"height":4},"surface_classes":{"grass":1},"start_sites":[]}"#;

fn loaded() -> Bridge {
    let mut b = Bridge::default();
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
fn api_version_is_1() {
    assert_eq!(WIND_API_VERSION, 1);
    assert_eq!(WIND_API_VERSION, i64::from(dp_air::API_VERSION));
}

#[test]
fn load_place_checks_lengths_and_nan() {
    let mut b = Bridge::default();
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
    let mut b = Bridge::default();
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
    let mut b = Bridge::default();
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
    let mut b = Bridge::default();
    let cfg = r#"{"air":{"threads":2},"seed":7}"#;
    assert_eq!(b.configure(&["atmosphere".into(), cfg.into()], -1), OK);
    let n = init_pool(5);
    assert!(n >= 1);
    assert_eq!(init_pool(1), n, "pool size is fixed after first init");
}
