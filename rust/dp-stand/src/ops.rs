//! Опросы: точки, разрезы, статистики. Плоские массивы, обход подряд, rayon по пачкам точек.
use dp_air::{AirModel, SampleMode};
use rayon::prelude::*;
use serde_json::{Value, json};
use std::path::Path;

const CHUNK: usize = 2048;

pub fn parse_mode(s: &str) -> Result<SampleMode, String> {
    match s {
        "full" => Ok(SampleMode::Full),
        "mean" => Ok(SampleMode::Mean),
        o => Err(format!("mode must be full|mean, got '{o}'")),
    }
}

pub fn mode_name(m: SampleMode) -> &'static str {
    match m {
        SampleMode::Full => "full",
        SampleMode::Mean => "mean",
    }
}

/// `x,y,z;x,y,z`.
pub fn parse_points(s: &str) -> Result<Vec<[f32; 3]>, String> {
    s.split(';')
        .filter(|p| !p.trim().is_empty())
        .map(|p| {
            let v = parse_floats::<3>(p)?;
            Ok(v)
        })
        .collect()
}

pub fn parse_floats<const N: usize>(s: &str) -> Result<[f32; N], String> {
    let v: Vec<f32> = s
        .split(',')
        .map(|x| x.trim().parse::<f32>().map_err(|e| format!("'{x}': {e}")))
        .collect::<Result<_, _>>()?;
    <[f32; N]>::try_from(v).map_err(|v| format!("expected {N} numbers, got {}", v.len()))
}

/// Пачки точек из слайса: параллельно, без копий.
pub fn sample_slice(
    model: &dyn AirModel,
    pts: &[[f32; 3]],
    mode: SampleMode,
    out: &mut [[f32; 4]],
) {
    pts.par_chunks(CHUNK)
        .zip(out.par_chunks_mut(CHUNK))
        .for_each(|(p, o)| model.sample_many(p, mode, o));
}

/// Точки по индексу `0..out.len()` без промежуточного массива точек.
pub fn sample_indexed<F>(model: &dyn AirModel, mode: SampleMode, out: &mut [[f32; 4]], point: F)
where
    F: Fn(usize) -> [f32; 3] + Sync,
{
    out.par_chunks_mut(CHUNK).enumerate().for_each(|(c, o)| {
        let mut buf = [[0.0f32; 3]; CHUNK];
        let base = c * CHUNK;
        for (k, b) in buf.iter_mut().take(o.len()).enumerate() {
            *b = point(base + k);
        }
        model.sample_many(&buf[..o.len()], mode, o);
    });
}

// ---------------------------------------------------------------- разрез

/// Плоскость: горизонтальная (xz на высоте MSL) или вертикальная по линии.
#[derive(Clone, Debug, PartialEq)]
pub enum Plane {
    Horizontal {
        x: [f32; 2],
        z: [f32; 2],
        y: f32,
    },
    Vertical {
        from: [f32; 2],
        to: [f32; 2],
        y: [f32; 2],
    },
}

#[derive(Clone, Debug, PartialEq)]
pub struct SliceSpec {
    pub plane: Plane,
    pub step: f32,
}

fn count(len: f32, step: f32) -> usize {
    (len / step + 1e-4).floor() as usize + 1
}

impl SliceSpec {
    pub fn validate(&self) -> Result<(), String> {
        if !(self.step.is_finite() && self.step > 0.0) {
            return Err("step must be > 0".into());
        }
        let ok = match &self.plane {
            Plane::Horizontal { x, z, y } => {
                x[1] >= x[0]
                    && z[1] >= z[0]
                    && [x[0], x[1], z[0], z[1], *y].iter().all(|v| v.is_finite())
            }
            Plane::Vertical { from, to, y } => {
                y[1] >= y[0]
                    && [from[0], from[1], to[0], to[1], y[0], y[1]]
                        .iter()
                        .all(|v| v.is_finite())
            }
        };
        if !ok {
            return Err("slice bounds must be finite and ordered (min <= max)".into());
        }
        let (nx, ny) = self.size();
        if nx * ny > 100_000_000 {
            return Err(format!("slice too large: {nx}x{ny}"));
        }
        Ok(())
    }

    /// (узлов по первой оси, по второй).
    pub fn size(&self) -> (usize, usize) {
        match &self.plane {
            Plane::Horizontal { x, z, .. } => {
                (count(x[1] - x[0], self.step), count(z[1] - z[0], self.step))
            }
            Plane::Vertical { from, to, y } => {
                let len = (to[0] - from[0]).hypot(to[1] - from[1]);
                (count(len, self.step), count(y[1] - y[0], self.step))
            }
        }
    }

    /// Точка узла `(i, j)`.
    pub fn point(&self, i: usize, j: usize) -> [f32; 3] {
        let st = self.step;
        match &self.plane {
            Plane::Horizontal { x, z, y } => [x[0] + i as f32 * st, *y, z[0] + j as f32 * st],
            Plane::Vertical { from, to, y } => {
                let len = (to[0] - from[0]).hypot(to[1] - from[1]);
                let s = (i as f32 * st).min(len);
                let u = if len > 0.0 { s / len } else { 0.0 };
                [
                    from[0] + (to[0] - from[0]) * u,
                    y[0] + j as f32 * st,
                    from[1] + (to[1] - from[1]) * u,
                ]
            }
        }
    }

    pub fn sample(&self, model: &dyn AirModel, mode: SampleMode) -> Vec<[f32; 4]> {
        let (nx, ny) = self.size();
        let mut out = vec![[0.0f32; 4]; nx * ny];
        sample_indexed(model, mode, &mut out, |k| self.point(k % nx, k / nx));
        out
    }

    pub fn header(&self, mode: SampleMode, time_s: f64, model: &str, data: &str) -> Value {
        let (nx, ny) = self.size();
        let geometry = match &self.plane {
            Plane::Horizontal { x, z, y } => {
                json!({"kind": "horizontal", "x": x, "z": z, "y": y})
            }
            Plane::Vertical { from, to, y } => {
                json!({"kind": "vertical", "from": from, "to": to, "y": y})
            }
        };
        json!({
            "version": 1, "nx": nx, "ny": ny, "step": self.step, "geometry": geometry,
            "mode": mode_name(mode), "time_s": time_s, "model": model,
            "layout": "f32 LE [ny][nx][4] (vx, vy, vz, sigma), index j*nx+i", "data": data,
        })
    }
}

/// Запись во временный файл и переименование.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = std::path::PathBuf::from(tmp);
    std::fs::write(&tmp, bytes).map_err(|e| format!("'{}': {e}", tmp.display()))?;
    std::fs::rename(&tmp, path).map_err(|e| format!("'{}': {e}", path.display()))
}

pub fn f32_bytes(v: &[[f32; 4]]) -> Vec<u8> {
    v.iter().flatten().flat_map(|x| x.to_le_bytes()).collect()
}

/// `<prefix>.json` + `<prefix>.bin`.
pub fn write_slice(
    prefix: &str,
    spec: &SliceSpec,
    mode: SampleMode,
    time_s: f64,
    model: &str,
    data: &[[f32; 4]],
) -> Result<(), String> {
    let bin = format!("{prefix}.bin");
    let name = Path::new(&bin)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    write_atomic(Path::new(&bin), &f32_bytes(data))?;
    let h = spec.header(mode, time_s, model, &name);
    write_atomic(
        Path::new(&format!("{prefix}.json")),
        serde_json::to_string_pretty(&h).unwrap().as_bytes(),
    )
}

/// Читает `.json` + `.bin` разреза.
pub fn read_slice(json: &Path) -> Result<(Value, Vec<[f32; 4]>), String> {
    let text = std::fs::read_to_string(json).map_err(|e| format!("'{}': {e}", json.display()))?;
    let h: Value = serde_json::from_str(&text).map_err(|e| format!("slice header: {e}"))?;
    let g = |k: &str| h.get(k).and_then(Value::as_u64).map(|v| v as usize);
    let (nx, ny) = (
        g("nx").ok_or("slice header: no nx")?,
        g("ny").ok_or("slice header: no ny")?,
    );
    let data = h
        .get("data")
        .and_then(Value::as_str)
        .ok_or("slice header: no data")?;
    let bp = json.with_file_name(data);
    let bytes = std::fs::read(&bp).map_err(|e| format!("'{}': {e}", bp.display()))?;
    if bytes.len() != nx * ny * 16 {
        return Err(format!(
            "slice .bin has {} bytes, {nx}x{ny} needs {}",
            bytes.len(),
            nx * ny * 16
        ));
    }
    let f: Vec<f32> = bytes
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect();
    let v = f
        .chunks_exact(4)
        .map(|c| [c[0], c[1], c[2], c[3]])
        .collect();
    Ok((h, v))
}

// ---------------------------------------------------------------- статистики

#[derive(Clone, Debug, PartialEq)]
pub struct Stats {
    pub n: usize,
    /// vx, vy, vz, σ
    pub mean: [f64; 4],
    pub std: [f64; 4],
    /// квантили vy: 5, 50, 95 %
    pub vy_q: [f32; 3],
    pub max_abs_vy: f32,
}

pub fn stats(v: &[[f32; 4]]) -> Stats {
    let n = v.len();
    let nf = n.max(1) as f64;
    let (s, s2) = v
        .par_iter()
        .fold(
            || ([0.0f64; 4], [0.0f64; 4]),
            |(mut s, mut s2), p| {
                for k in 0..4 {
                    let x = p[k] as f64;
                    s[k] += x;
                    s2[k] += x * x;
                }
                (s, s2)
            },
        )
        .reduce(
            || ([0.0; 4], [0.0; 4]),
            |a, b| {
                let mut s = a.0;
                let mut s2 = a.1;
                for k in 0..4 {
                    s[k] += b.0[k];
                    s2[k] += b.1[k];
                }
                (s, s2)
            },
        );
    let mean = s.map(|x| x / nf);
    let std = [0, 1, 2, 3].map(|k| (s2[k] / nf - mean[k] * mean[k]).max(0.0).sqrt());
    let mut vy: Vec<f32> = v.iter().map(|p| p[1]).collect();
    vy.sort_unstable_by(f32::total_cmp);
    let q = |f: f64| {
        if vy.is_empty() {
            0.0
        } else {
            vy[((vy.len() - 1) as f64 * f).round() as usize]
        }
    };
    Stats {
        n,
        mean,
        std,
        vy_q: [q(0.05), q(0.5), q(0.95)],
        max_abs_vy: vy.iter().fold(0.0f32, |m, x| m.max(x.abs())),
    }
}

impl Stats {
    pub fn to_json(&self) -> Value {
        json!({
            "n": self.n,
            "mean": {"vx": self.mean[0], "vy": self.mean[1], "vz": self.mean[2], "sigma": self.mean[3]},
            "std": {"vx": self.std[0], "vy": self.std[1], "vz": self.std[2], "sigma": self.std[3]},
            "vy_quantiles": {"q05": self.vy_q[0], "q50": self.vy_q[1], "q95": self.vy_q[2]},
            "max_abs_vy": self.max_abs_vy,
        })
    }
}

/// Коробка: узлы `lo + i*step` по каждой оси; возвращает значения и число узлов.
pub fn sample_box(
    model: &dyn AirModel,
    mode: SampleMode,
    lo: [f32; 3],
    hi: [f32; 3],
    step: f32,
) -> Result<Vec<[f32; 4]>, String> {
    if !(step.is_finite() && step > 0.0)
        || (0..3).any(|a| hi[a].is_nan() || lo[a].is_nan() || hi[a] < lo[a])
    {
        return Err("box: step > 0 and min <= max required".into());
    }
    let n = [0, 1, 2].map(|a| count(hi[a] - lo[a], step));
    let total = n[0]
        .checked_mul(n[1])
        .and_then(|v| v.checked_mul(n[2]))
        .filter(|&t| t <= 100_000_000)
        .ok_or("box too large")?;
    let mut out = vec![[0.0f32; 4]; total];
    sample_indexed(model, mode, &mut out, |k| {
        let (i, r) = (k % n[0], k / n[0]);
        [
            lo[0] + i as f32 * step,
            lo[1] + (r % n[1]) as f32 * step,
            lo[2] + (r / n[1]) as f32 * step,
        ]
    });
    Ok(out)
}
