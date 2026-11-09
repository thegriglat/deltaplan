//! Подготовка модели по случаю: configure → load_place → set_conditions → set_static_thermals →
//! set_focuses → start_at(t) и ожидание Ready.
use crate::sha1::sha1_hex;
use dp_air::fixtures::{Case, read_case, read_place};
use dp_air::{AirModel, Calm, Configs, Formula, Place, State};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// Единственное место выбора модели. `formula` — детерминированный режим (W1 v2): стенд ждёт
/// фон на игровых моментах, ответ не зависит от скорости машины.
pub fn make_model(name: &str) -> Result<Box<dyn AirModel>, String> {
    match name {
        "calm" => Ok(Box::new(Calm::new())),
        "formula" => Ok(Box::new(Formula::new().with_deterministic(true))),
        other => Err(format!("unknown model '{other}' (known: calm, formula)")),
    }
}

/// Все `*.json` каталога, включая подкаталоги: имя — путь от каталога через `/` (`weather/weak.json`),
/// по имени.
pub fn load_configs(dir: &Path) -> Result<Configs, String> {
    let mut files = Vec::new();
    collect_configs(dir, "", &mut files)?;
    files.sort();
    Ok(Configs::new(files))
}

fn collect_configs(
    dir: &Path,
    prefix: &str,
    files: &mut Vec<(String, String)>,
) -> Result<(), String> {
    let rd = std::fs::read_dir(dir).map_err(|e| format!("configs '{}': {e}", dir.display()))?;
    for ent in rd {
        let p = ent.map_err(|e| e.to_string())?.path();
        let name = format!("{prefix}{}", p.file_name().unwrap().to_string_lossy());
        if p.is_dir() {
            collect_configs(&p, &format!("{name}/"), files)?;
        } else if p.extension().is_some_and(|e| e == "json") && p.is_file() {
            let text =
                std::fs::read_to_string(&p).map_err(|e| format!("'{}': {e}", p.display()))?;
            files.push((name.trim_end_matches(".json").to_string(), text));
        }
    }
    Ok(())
}

/// Предупреждения о расхождении sha1 конфигов с записанным в случае.
pub fn config_warnings(case: &Case, cfg: &Configs) -> Vec<String> {
    let mut out = Vec::new();
    for (name, want) in &case.configs_sha1 {
        let found = cfg
            .files
            .iter()
            .find(|(n, _)| n == name.strip_suffix(".json").unwrap_or(name));
        match found {
            None => out.push(format!(
                "config '{name}' from the case is not in configs dir"
            )),
            Some((n, text)) => {
                let got = sha1_hex(text.as_bytes());
                if !got.eq_ignore_ascii_case(want) {
                    out.push(format!("config '{n}': sha1 {got}, case has {want}"));
                }
            }
        }
    }
    out
}

pub struct Session {
    pub model: Box<dyn AirModel>,
    pub case: Case,
    pub case_path: PathBuf,
    pub timeout: Duration,
}

pub struct OpenArgs<'a> {
    pub case: &'a Path,
    pub place: Option<&'a Path>,
    pub model: &'a str,
    pub configs: &'a Path,
    pub timeout_s: f64,
}

fn s<T, E: std::fmt::Display>(r: Result<T, E>) -> Result<T, String> {
    r.map_err(|e| e.to_string())
}

pub fn open(a: &OpenArgs) -> Result<Session, String> {
    let (model, case, _, _) = prepare(a, make_model(a.model)?)?;
    Ok(Session {
        model,
        case,
        case_path: a.case.to_path_buf(),
        timeout: Duration::from_secs_f64(a.timeout_s.max(0.0)),
    })
}

/// Конкретная `Formula` (детерминированная) по случаю: для подкоманд, которым нужен её журнал.
pub fn open_formula(a: &OpenArgs) -> Result<(Formula, Case), String> {
    let (model, case, _, _) = prepare(a, Box::new(Formula::new().with_deterministic(true)))?;
    Ok((*model, case))
}

/// Подготовка модели `m` по случаю (configure → load_place → … → set_focuses); отдаёт модель, случай,
/// конфиги и второй экземпляр места (для потребителей, которым нужны рельеф и ctx слагаемых).
pub fn prepare<M: AirModel + ?Sized>(
    a: &OpenArgs,
    mut model: Box<M>,
) -> Result<(Box<M>, Case, Configs, Place), String> {
    let case = s(read_case(a.case))?;
    let place_path = a
        .place
        .map(Path::to_path_buf)
        .unwrap_or_else(|| case.place_path(a.case));
    let place = s(read_place(&place_path))?;
    let place2 = s(read_place(&place_path))?;
    let cfg = load_configs(a.configs)?;
    for w in config_warnings(&case, &cfg) {
        eprintln!("warning: {w}");
    }
    s(model.configure(&cfg, case.seed))?;
    s(model.load_place(place))?;
    s(model.set_conditions(&case.conditions))?;
    s(model.set_static_thermals(&case.static_thermals, case.static_mode))?;
    s(model.set_focuses(&case.focuses))?;
    Ok((model, case, cfg, place2))
}

/// `start_at(t)` и ожидание Ready (опрос `status`).
pub fn go_to_model<M: AirModel + ?Sized>(
    model: &mut M,
    t: f64,
    timeout: Duration,
) -> Result<(), String> {
    s(model.start_at(t))?;
    let t0 = Instant::now();
    loop {
        let st = model.status();
        match st.state {
            State::Ready => return Ok(()),
            State::Failed => return Err(format!("model failed: {}", st.reason)),
            _ => {}
        }
        if t0.elapsed() > timeout {
            return Err(format!(
                "timeout waiting for Ready at t={t} (progress {:.2})",
                st.progress
            ));
        }
        std::thread::sleep(Duration::from_millis(1));
    }
}

impl Session {
    /// `start_at(t)` и ожидание Ready (таймаут — ключом).
    pub fn go_to(&mut self, t: f64) -> Result<(), String> {
        go_to_model(self.model.as_mut(), t, self.timeout)
    }
}
