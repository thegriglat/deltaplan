//! RW-6q: история решателя при отмене до первой итерации несёт NaN-невязки (ревью RW-6t) — стенд
//! не падает и не сравнивает их: сессия `formula`, у которой первая загрузка отменена на старте
//! (`start_at` второй раз сразу после первого), доходит до `Ready`; сверка с фикстурой идёт до конца,
//! числа отчёта конечны, текст отчёта собирается.
use dp_stand::compare::{self, Options};
use dp_stand::setup::{OpenArgs, open};
use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn copy_dir(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for e in fs::read_dir(from).unwrap() {
        let p = e.unwrap().path();
        let dst = to.join(p.file_name().unwrap());
        if p.is_dir() {
            copy_dir(&p, &dst);
        } else {
            fs::copy(&p, &dst).unwrap();
        }
    }
}

/// Конфиги игры с малой областью и грубым критерием (проверка идёт на dev).
fn small_configs() -> PathBuf {
    let d = std::env::temp_dir().join(format!("dp-stand-nan-{}", std::process::id()));
    let _ = fs::remove_dir_all(&d);
    copy_dir(&repo().join("configs"), &d);
    let f = d.join("atmosphere.json");
    let mut v: Value = serde_json::from_str(&fs::read_to_string(&f).unwrap()).unwrap();
    v["air"]["domain_l_m"] = json!(7200.0);
    v["air"]["threads"] = json!(2);
    v["air"]["tol_scale"] = json!(5.0);
    v["air"]["timeout_s"] = json!(600.0);
    v["air_model"]["edge_blend_cells"] = json!(1.0);
    fs::write(&f, serde_json::to_string(&v).unwrap()).unwrap();
    d
}

#[test]
fn restarted_load_does_not_break_the_stand_or_compare_nan() {
    let configs = small_configs();
    let case = repo().join("tests/fixtures/wind/cases/synth_medium.json");
    let mut sess = open(&OpenArgs {
        case: &case,
        place: None,
        model: "formula",
        configs: &configs,
        timeout_s: 600.0,
    })
    .unwrap();
    // первая загрузка отменяется до первой итерации решателя
    sess.model.start_at(1.0).unwrap();
    sess.model.start_at(2.0).unwrap();
    sess.model.unload_place();
    let place =
        dp_air::fixtures::read_place(&repo().join("tests/fixtures/wind/places/synthetic.json"))
            .unwrap();
    sess.model.load_place(place).unwrap();
    sess.model.start_at(3.0).unwrap();
    let rep = compare::run(
        &mut sess,
        &Options {
            terms: true,
            noise_replaced: false,
        },
    )
    .expect("сверка идёт до конца");
    for r in &rep.rows {
        assert!(r.max_abs.is_finite(), "{}: max_abs {}", r.name, r.max_abs);
        assert!(
            r.max_ratio.is_finite(),
            "{}: max_ratio {}",
            r.name,
            r.max_ratio
        );
    }
    assert!(
        rep.violations.iter().all(|v| v.delta.is_finite()),
        "в нарушениях нет NaN"
    );
    let text = rep.render(5);
    assert!(!text.contains("NaN"), "{text}");
    let _ = fs::remove_dir_all(&configs);
}
