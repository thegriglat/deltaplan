use clap::{Args, Parser, Subcommand};
use dp_air::{AirModel, Formula};
use dp_stand::compare::{self, Options};
use dp_stand::lee::{self, LeeCtx, LeeSpec};
use dp_stand::ops::{self, Plane, SliceSpec};
use dp_stand::setup;
mod timing;
use dp_stand::setup::{OpenArgs, Session, open};
use serde_json::json;
use std::path::PathBuf;
use std::process::ExitCode;

const DEFAULT_CONFIGS: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../configs");

/// Стенд без Godot: ветер модели dp-air по месту, условиям и моменту случая W8.
#[derive(Parser)]
#[command(name = "dp-stand", version)]
struct Cli {
    #[command(flatten)]
    common: Common,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Args)]
struct Common {
    /// cases/<имя>.json (условия, момент, точки)
    #[arg(long, global = true)]
    case: Option<PathBuf>,
    /// places/<имя>.json; по умолчанию — ../places/<place>.json от случая
    #[arg(long, global = true)]
    place: Option<PathBuf>,
    /// Модель: calm | formula
    #[arg(long, global = true, default_value = "calm")]
    model: String,
    /// Каталог конфигов; sha1 сверяется с configs_sha1 случая (расхождение — предупреждение)
    #[arg(long, global = true, default_value = DEFAULT_CONFIGS)]
    configs: PathBuf,
    /// Таймаут ожидания Ready, с
    #[arg(long, global = true, default_value_t = 60.0)]
    timeout: f64,
    /// Момент, с (по умолчанию: sample/compare — все моменты случая; остальное — первый)
    #[arg(long, global = true)]
    time: Option<f64>,
}

#[derive(Subcommand)]
enum Cmd {
    /// Ветер в точках случая или --points "x,y,z;x,y,z" -> csv
    Sample {
        #[arg(long)]
        points: Option<String>,
        /// full | mean
        #[arg(long, default_value = "mean")]
        mode: String,
    },
    /// Разрез: horizontal (xz на высоте --y) или vertical (линия --from..--to, высоты --y0..--y1)
    Slice {
        #[arg(long, default_value = "horizontal")]
        kind: String,
        /// Шаг сетки, м
        #[arg(long)]
        step: f32,
        /// x0,x1 (horizontal)
        #[arg(long)]
        x: Option<String>,
        /// z0,z1 (horizontal)
        #[arg(long)]
        z: Option<String>,
        /// Высота MSL (horizontal)
        #[arg(long)]
        y: Option<f32>,
        /// x,z начала линии (vertical)
        #[arg(long)]
        from: Option<String>,
        /// x,z конца линии (vertical)
        #[arg(long)]
        to: Option<String>,
        /// y0,y1 MSL (vertical)
        #[arg(long)]
        ys: Option<String>,
        #[arg(long, default_value = "mean")]
        mode: String,
        /// Префикс выхода: <out>.json + <out>.bin
        #[arg(long)]
        out: String,
    },
    /// Статистики по разрезу (--slice <x.json>) или коробке (--min x,y,z --max x,y,z --step s)
    Stats {
        #[arg(long)]
        slice: Option<PathBuf>,
        #[arg(long)]
        min: Option<String>,
        #[arg(long)]
        max: Option<String>,
        #[arg(long)]
        step: Option<f32>,
        #[arg(long, default_value = "mean")]
        mode: String,
    },
    /// Разложение скорости в точке (W7) -> json
    Decompose {
        /// x,y,z
        #[arg(long)]
        point: String,
    },
    /// Разрез болтанки поля за гребнем (LTS v1): csv в stdout
    Lee {
        /// x,z начала линии (игра, горизонталь)
        #[arg(long)]
        from: String,
        /// x,z конца линии
        #[arg(long)]
        to: String,
        /// y0,y1 — высоты MSL
        #[arg(long)]
        ys: String,
        /// Шаг вдоль линии, м
        #[arg(long)]
        step: f32,
        /// Шаг по высоте, м (по умолчанию --step)
        #[arg(long)]
        dy: Option<f32>,
        /// Каталог кеша полей (`set_cache_dir`): повторный прогон того же случая без решателя
        #[arg(long)]
        cache: Option<PathBuf>,
        /// Диагностика вне контракта (relief, lee аналитики, …) в этот csv
        #[arg(long)]
        extra: Option<PathBuf>,
    },
    /// Сверка модели с .bin/.desc.json случая по допускам W8; exit 1, если есть точка вне допуска
    Compare {
        /// Сверять и слагаемые по terms случая
        #[arg(long)]
        terms: bool,
        /// Шум заменён: FULL не сравнивается
        #[arg(long)]
        noise_replaced: bool,
        /// Сколько нарушений печатать
        #[arg(long, default_value_t = 20)]
        max_violations: usize,
    },
    /// Журнал задачи поля (JobReport) на каждый момент, json по строке; только --model formula
    Timing {
        /// Потоков rayon (по умолчанию - как у стенда)
        #[arg(long)]
        threads: Option<usize>,
    },
}

fn session(c: &Common) -> Result<Session, String> {
    let case = c.case.as_deref().ok_or("--case is required")?;
    open(&OpenArgs {
        case,
        place: c.place.as_deref(),
        model: &c.model,
        configs: &c.configs,
        timeout_s: c.timeout,
    })
}

fn pair(s: &str) -> Result<[f32; 2], String> {
    ops::parse_floats::<2>(s)
}

fn req<'a>(v: &'a Option<String>, name: &str) -> Result<&'a str, String> {
    v.as_deref().ok_or_else(|| format!("--{name} is required"))
}

fn times(sess: &Session, c: &Common, all: bool) -> Vec<f64> {
    match (c.time, all) {
        (Some(t), _) => vec![t],
        (None, true) => sess.case.times_s.clone(),
        (None, false) => vec![sess.case.times_s[0]],
    }
}

fn run(cli: Cli) -> Result<ExitCode, String> {
    let c = &cli.common;
    match cli.cmd {
        Cmd::Sample { points, mode } => {
            let mode = ops::parse_mode(&mode)?;
            let mut sess = session(c)?;
            let pts = match points {
                Some(p) => ops::parse_points(&p)?,
                None => sess.case.points.clone(),
            };
            let mut out = vec![[0.0f32; 4]; pts.len()];
            println!("t,x,y,z,vx,vy,vz,sigma");
            for t in times(&sess, c, true) {
                sess.go_to(t)?;
                ops::sample_slice(sess.model.as_ref(), &pts, mode, &mut out);
                for (p, v) in pts.iter().zip(&out) {
                    println!(
                        "{t},{},{},{},{},{},{},{}",
                        p[0], p[1], p[2], v[0], v[1], v[2], v[3]
                    );
                }
            }
        }
        Cmd::Slice {
            kind,
            step,
            x,
            z,
            y,
            from,
            to,
            ys,
            mode,
            out,
        } => {
            let mode = ops::parse_mode(&mode)?;
            let plane = match kind.as_str() {
                "horizontal" => Plane::Horizontal {
                    x: pair(req(&x, "x")?)?,
                    z: pair(req(&z, "z")?)?,
                    y: y.ok_or("--y is required")?,
                },
                "vertical" => Plane::Vertical {
                    from: pair(req(&from, "from")?)?,
                    to: pair(req(&to, "to")?)?,
                    y: pair(req(&ys, "ys")?)?,
                },
                o => return Err(format!("kind must be horizontal|vertical, got '{o}'")),
            };
            let spec = SliceSpec { plane, step };
            spec.validate()?;
            let mut sess = session(c)?;
            let t = times(&sess, c, false)[0];
            sess.go_to(t)?;
            let data = spec.sample(sess.model.as_ref(), mode);
            ops::write_slice(&out, &spec, mode, t, &c.model, &data)?;
            let (nx, ny) = spec.size();
            eprintln!("wrote {out}.json and {out}.bin ({nx}x{ny})");
        }
        Cmd::Stats {
            slice,
            min,
            max,
            step,
            mode,
        } => {
            let data = if let Some(p) = slice {
                ops::read_slice(&p)?.1
            } else {
                let mode = ops::parse_mode(&mode)?;
                let lo = ops::parse_floats::<3>(req(&min, "min")?)?;
                let hi = ops::parse_floats::<3>(req(&max, "max")?)?;
                let mut sess = session(c)?;
                let t = times(&sess, c, false)[0];
                sess.go_to(t)?;
                ops::sample_box(
                    sess.model.as_ref(),
                    mode,
                    lo,
                    hi,
                    step.ok_or("--step is required")?,
                )?
            };
            println!(
                "{}",
                serde_json::to_string_pretty(&ops::stats(&data).to_json()).unwrap()
            );
        }
        Cmd::Decompose { point } => {
            let p = ops::parse_floats::<3>(&point)?;
            let mut sess = session(c)?;
            let t = times(&sess, c, false)[0];
            sess.go_to(t)?;
            let d = sess.model.decompose(p);
            let sum = d
                .vel
                .iter()
                .fold([0.0f32; 3], |a, v| [a[0] + v[0], a[1] + v[1], a[2] + v[2]]);
            let j = json!({
                "time_s": t, "point": p, "names": d.names, "vel": d.vel,
                "sigma": d.sigma, "total": d.total, "sum_vel": sum,
            });
            println!("{}", serde_json::to_string_pretty(&j).unwrap());
        }
        Cmd::Lee {
            from,
            to,
            ys,
            step,
            dy,
            cache,
            extra,
        } => {
            let spec = LeeSpec {
                from: pair(&from)?,
                to: pair(&to)?,
                ys: pair(&ys)?,
                step,
                dy: dy.unwrap_or(step),
            };
            spec.validate()?;
            let case = c.case.as_deref().ok_or("--case is required")?;
            let a = OpenArgs {
                case,
                place: c.place.as_deref(),
                model: "formula",
                configs: &c.configs,
                timeout_s: c.timeout,
            };
            if c.model != "formula" {
                return Err("lee needs --model formula (field and terms)".into());
            }
            let f = Box::new(Formula::new().with_deterministic(true));
            let mut f = f;
            if let Some(dir) = &cache {
                std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
                let abs = std::fs::canonicalize(dir).map_err(|e| e.to_string())?;
                f.set_cache_dir(&abs.to_string_lossy())
                    .map_err(|e| e.to_string())?;
            }
            let (mut f, case_d, cfgs, place) = setup::prepare(&a, f)?;
            let t = c.time.unwrap_or(case_d.times_s[0]);
            setup::go_to_model(f.as_mut(), t, std::time::Duration::from_secs_f64(c.timeout))?;
            let lc = LeeCtx::new(&f, &cfgs, case_d.seed, t)?;
            for (i, d) in lc.level_info().iter().enumerate() {
                eprintln!("level {i}: {d}");
            }
            let rows = lee::run(&f, &lc, &place, &spec);
            if let Some(p) = &extra {
                std::fs::write(p, lee::render_extra(&rows)).map_err(|e| e.to_string())?;
            }
            let name = case
                .file_stem()
                .map_or(String::new(), |s| s.to_string_lossy().into_owned());
            let header = format!(
                "# lts v1 case={name} time={t} git={} model={}",
                git_hash(),
                c.model
            );
            print!("{}", lee::render(&header, &rows));
        }
        Cmd::Timing { threads } => {
            if c.model != "formula" {
                return Err("timing needs --model formula".into());
            }
            if let Some(n) = threads {
                rayon::ThreadPoolBuilder::new()
                    .num_threads(n)
                    .build_global()
                    .map_err(|e| e.to_string())?;
            }
            let case = c.case.as_deref().ok_or("--case is required")?;
            timing::run(
                &OpenArgs {
                    case,
                    place: c.place.as_deref(),
                    model: &c.model,
                    configs: &c.configs,
                    timeout_s: c.timeout,
                },
                c.time,
            )?;
        }
        Cmd::Compare {
            terms,
            noise_replaced,
            max_violations,
        } => {
            let mut sess = session(c)?;
            let rep = compare::run(
                &mut sess,
                &Options {
                    terms,
                    noise_replaced,
                },
            )?;
            print!("{}", rep.render(max_violations));
            if !rep.passed() {
                return Ok(ExitCode::from(1));
            }
        }
    }
    Ok(ExitCode::SUCCESS)
}

fn git_hash() -> String {
    std::process::Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map_or_else(
            || "unknown".into(),
            |o| String::from_utf8_lossy(&o.stdout).trim().to_string(),
        )
}

fn main() -> ExitCode {
    match run(Cli::parse()) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("dp-stand: {e}");
            ExitCode::from(2)
        }
    }
}
