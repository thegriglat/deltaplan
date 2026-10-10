//! Замеры стадий: время, процессорное время всех потоков (`getrusage`), пик RSS.

use serde_json::{json, Map, Value};
use std::time::Instant;

fn rusage() -> libc::rusage {
    unsafe {
        let mut u: libc::rusage = std::mem::zeroed();
        libc::getrusage(libc::RUSAGE_SELF, &mut u);
        u
    }
}

/// Процессорное время процесса (user + sys), с.
pub fn cpu_s() -> f64 {
    let u = rusage();
    let tv = |t: libc::timeval| t.tv_sec as f64 + t.tv_usec as f64 * 1e-6;
    tv(u.ru_utime) + tv(u.ru_stime)
}

/// Пик RSS процесса, МБ.
pub fn peak_rss_mb() -> f64 {
    rusage().ru_maxrss as f64 / 1024.0
}

pub struct Stages {
    t0: Instant,
    cur: Option<(String, Instant, f64)>,
    pub done: Vec<(String, f64, f64)>,
}

impl Stages {
    pub fn new() -> Self {
        Stages { t0: Instant::now(), cur: None, done: vec![] }
    }
    pub fn start(&mut self, name: &str) {
        self.finish();
        eprintln!("osmtiles: стадия {name}…");
        self.cur = Some((name.to_string(), Instant::now(), cpu_s()));
    }
    pub fn finish(&mut self) {
        if let Some((n, t, c)) = self.cur.take() {
            let wall = t.elapsed().as_secs_f64();
            let cores = if wall > 0.0 { (cpu_s() - c) / wall } else { 0.0 };
            eprintln!("osmtiles: стадия {n}: {wall:.2} с, ядер {cores:.1}, пик RSS {:.0} МБ", peak_rss_mb());
            self.done.push((n, wall, cores));
        }
    }
    pub fn total_s(&self) -> f64 {
        self.t0.elapsed().as_secs_f64()
    }
    fn r(x: f64, k: f64) -> f64 {
        (x * k).round() / k
    }
    /// `{seconds, cpu_cores_avg}` — словари по стадиям.
    pub fn json(&self) -> (Value, Value) {
        let mut s = Map::new();
        let mut c = Map::new();
        for (n, w, k) in &self.done {
            s.insert(n.clone(), json!(Self::r(*w, 1000.0)));
            c.insert(n.clone(), json!(Self::r(*k, 100.0)));
        }
        (Value::Object(s), Value::Object(c))
    }
}

impl Default for Stages {
    fn default() -> Self {
        Self::new()
    }
}

/// Динамическая раздача задач по потокам пула `rayon` в заданном порядке (тяжёлые — первыми):
/// каждый поток берёт следующую задачу из общего счётчика. Результаты — в порядке задач.
pub fn run_queue<T: Sync, R: Send>(jobs: &[T], f: impl Fn(&T) -> R + Sync) -> Vec<R> {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Mutex;
    let next = AtomicUsize::new(0);
    let out: Mutex<Vec<(usize, R)>> = Mutex::new(Vec::with_capacity(jobs.len()));
    let nt = rayon::current_num_threads().max(1);
    rayon::scope(|s| {
        for _ in 0..nt {
            s.spawn(|_| loop {
                let k = next.fetch_add(1, Ordering::Relaxed);
                if k >= jobs.len() {
                    break;
                }
                let r = f(&jobs[k]);
                out.lock().unwrap().push((k, r));
            });
        }
    });
    let mut v = out.into_inner().unwrap();
    v.sort_by_key(|x| x.0);
    v.into_iter().map(|x| x.1).collect()
}
