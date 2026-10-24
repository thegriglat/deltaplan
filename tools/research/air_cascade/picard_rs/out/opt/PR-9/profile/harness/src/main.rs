//! PR-4: повтор отдельной фазы/направления прогонки на разогретом поле — для счётчиков perf по направлениям.
//! usage: prof_harness <mode> <reps> [threads]; mode: dir0|dir1|dir2 (3 компоненты импульса, один проход направления),
//! mom|heat|proj|kupd|bmom|bheat. Разогрев: 15 внешних итераций.
use picard_rs::case::{Case, Consts};
use picard_rs::lines::sweep;
use picard_rs::solver::Picard;
use std::time::Instant;

fn main() -> anyhow::Result<()> {
    let mut a: Vec<String> = std::env::args().collect();
    // «solve» первым аргументом — только чтобы замок cpu дал вес 18 слотов по маске карточки
    if a.get(1).map(String::as_str) == Some("solve") {
        a.remove(1);
    }
    let mode = a[1].as_str();
    let reps: usize = a[2].parse()?;
    let th: usize = a.get(3).map(|s| s.parse().unwrap()).unwrap_or(8);
    let case = std::env::var("PROF_CASE").unwrap();
    let c = Case::load(std::path::Path::new(&case))?;
    let pool = rayon::ThreadPoolBuilder::new().num_threads(th).build()?;
    pool.install(|| -> anyhow::Result<()> {
        let mut s = Picard::new(Consts::from_case(&c)?);
        s.init_background();
        for _ in 0..15 {
            s.outer_step();
        }
        let shape = (s.k.nzh, s.k.nyh, s.k.nxh);
        let t = Instant::now();
        for _ in 0..reps {
            match mode {
                "dir0" | "dir1" | "dir2" => {
                    let d = (mode.as_bytes()[3] - b'0') as usize;
                    sweep(&s.cu, &mut s.f.u, &mut s.sc, shape, &[d]);
                    sweep(&s.cv, &mut s.f.v, &mut s.sc, shape, &[d]);
                    sweep(&s.cw, &mut s.f.w, &mut s.sc, shape, &[d]);
                }
                "mom" => s.mom_step(),
                "heat" => s.heat_step(),
                "proj" => s.project(s.k.vcycles, true),
                "kupd" => s.update_k(),
                "bmom" => s.build_all_mom(),
                "bheat" => {
                    s.build_heat_d();
                    s.build_heat_t();
                }
                _ => panic!("mode"),
            }
        }
        println!("{mode} reps {reps} threads {th}: {:.3} ms/rep", t.elapsed().as_secs_f64() * 1e3 / reps.max(1) as f64);
        Ok(())
    })
}
