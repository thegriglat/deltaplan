use clap::{Args, Parser, Subcommand};
use dp_stand::compare::{self, Options};
use dp_stand::ops::{self, Plane, SliceSpec};
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
    /// Модель: calm
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

fn main() -> ExitCode {
    match run(Cli::parse()) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("dp-stand: {e}");
            ExitCode::from(2)
        }
    }
}
