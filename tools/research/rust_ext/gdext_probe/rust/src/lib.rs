use godot::prelude::*;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

struct ProbeExt;

#[gdextension]
unsafe impl ExtensionLibrary for ProbeExt {}

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
struct Probe {
    done: Arc<AtomicBool>,
    result: Arc<Mutex<Option<f32>>>,
    base: Base<RefCounted>,
}

#[godot_api]
impl Probe {
    #[func]
    fn add(&self, a: i64, b: i64) -> i64 {
        a + b
    }

    #[func]
    fn sum(&self, v: PackedFloat32Array) -> f32 {
        v.as_slice().iter().sum()
    }

    /// Фоновый расчёт ~`ms` мс в потоке Rust.
    #[func]
    fn start(&mut self, ms: i64) {
        self.done.store(false, Ordering::SeqCst);
        *self.result.lock().unwrap() = None;
        let done = self.done.clone();
        let res = self.result.clone();
        std::thread::spawn(move || {
            let t = std::time::Instant::now();
            let mut x = 0.0f64;
            let mut n = 0u64;
            while t.elapsed().as_millis() < ms as u128 {
                for i in 0..10000 {
                    x += ((i as f64) * 1e-3).sin();
                }
                n += 1;
            }
            *res.lock().unwrap() = Some((x + n as f64) as f32);
            done.store(true, Ordering::SeqCst);
        });
    }

    #[func]
    fn is_done(&self) -> bool {
        self.done.load(Ordering::SeqCst)
    }

    #[func]
    fn take_result(&self) -> f32 {
        self.result.lock().unwrap().take().unwrap_or(f32::NAN)
    }
}
