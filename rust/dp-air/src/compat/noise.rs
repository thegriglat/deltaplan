//! `FastNoiseLite` Godot (Jordan Peck, MIT): OpenSimplex2S 3D (`TYPE_SIMPLEX_SMOOTH`), фракталы
//! NONE и FBM. Арифметика — f32, как в Godot (`real_t` обычной сборки).

const PRIME_X: i32 = 501_125_321;
const PRIME_Y: i32 = 1_136_930_381;
const PRIME_Z: i32 = 1_720_413_743;

#[rustfmt::skip]
const GRAD3: [f32; 256] = {
    const A: [f32; 16] = [0.,1.,1.,0., 0.,-1.,1.,0., 0.,1.,-1.,0., 0.,-1.,-1.,0.];
    const B: [f32; 16] = [1.,0.,1.,0., -1.,0.,1.,0., 1.,0.,-1.,0., -1.,0.,-1.,0.];
    const C: [f32; 16] = [1.,1.,0.,0., -1.,1.,0.,0., 1.,-1.,0.,0., -1.,-1.,0.,0.];
    const D: [f32; 16] = [1.,1.,0.,0., 0.,-1.,1.,0., -1.,1.,0.,0., 0.,-1.,-1.,0.];
    let mut t = [0.0f32; 256];
    let mut line = 0;
    while line < 16 {
        let src = if line == 15 { D } else if line % 3 == 0 { A } else if line % 3 == 1 { B } else { C };
        let mut i = 0;
        while i < 16 {
            t[line * 16 + i] = src[i];
            i += 1;
        }
        line += 1;
    }
    t
};

/// Фрактал Godot (`fractal_type`).
#[derive(Clone, Copy, Debug)]
pub enum Fractal {
    None,
    Fbm {
        octaves: i32,
        gain: f32,
        lacunarity: f32,
        weighted_strength: f32,
    },
}

#[derive(Clone, Debug)]
pub struct FastNoise {
    seed: i32,
    kind: Fractal,
    frequency: f32,
    bounding: f32,
}

#[inline]
fn hash(seed: i32, x: i32, y: i32, z: i32) -> i32 {
    (seed ^ x ^ y ^ z).wrapping_mul(0x27d4_eb2d)
}

#[inline]
fn grad(seed: i32, xp: i32, yp: i32, zp: i32, xd: f32, yd: f32, zd: f32) -> f32 {
    let mut h = hash(seed, xp, yp, zp);
    h ^= h >> 15;
    let h = (h & (63 << 2)) as usize;
    xd * GRAD3[h] + yd * GRAD3[h | 1] + zd * GRAD3[h | 2]
}

#[inline]
fn floor_i(f: f32) -> i32 {
    if f >= 0.0 { f as i32 } else { f as i32 - 1 }
}

/// Квадрат радиуса влияния узла OpenSimplex2S 3D (подобран по дампу Godot: 3/4).
const RSQ: f32 = 3.0 / 4.0;
/// Множитель поворота 3D (`R3`).
const R3: f32 = 2.0 / 3.0;

fn simplex2s(seed: i32, x: f32, y: f32, z: f32) -> f32 {
    let i0 = floor_i(x);
    let j0 = floor_i(y);
    let k0 = floor_i(z);
    let xi = x - i0 as f32;
    let yi = y - j0 as f32;
    let zi = z - k0 as f32;
    let i = i0.wrapping_mul(PRIME_X);
    let j = j0.wrapping_mul(PRIME_Y);
    let k = k0.wrapping_mul(PRIME_Z);
    let seed2 = seed.wrapping_add(1_293_373);

    let xn = (-0.5f32 - xi) as i32;
    let yn = (-0.5f32 - yi) as i32;
    let zn = (-0.5f32 - zi) as i32;

    let x0 = xi + xn as f32;
    let y0 = yi + yn as f32;
    let z0 = zi + zn as f32;
    let a0 = RSQ - x0 * x0 - y0 * y0 - z0 * z0;
    let mut value = (a0 * a0)
        * (a0 * a0)
        * grad(
            seed,
            i.wrapping_add(xn & PRIME_X),
            j.wrapping_add(yn & PRIME_Y),
            k.wrapping_add(zn & PRIME_Z),
            x0,
            y0,
            z0,
        );

    let x1 = xi - 0.5;
    let y1 = yi - 0.5;
    let z1 = zi - 0.5;
    let a1 = RSQ - x1 * x1 - y1 * y1 - z1 * z1;
    value += (a1 * a1)
        * (a1 * a1)
        * grad(
            seed2,
            i.wrapping_add(PRIME_X),
            j.wrapping_add(PRIME_Y),
            k.wrapping_add(PRIME_Z),
            x1,
            y1,
            z1,
        );

    let xaf0 = (((xn | 1) << 1) as f32) * x1;
    let yaf0 = (((yn | 1) << 1) as f32) * y1;
    let zaf0 = (((zn | 1) << 1) as f32) * z1;
    let xaf1 = ((-2 - (xn << 2)) as f32) * x1 - 1.0;
    let yaf1 = ((-2 - (yn << 2)) as f32) * y1 - 1.0;
    let zaf1 = ((-2 - (zn << 2)) as f32) * z1 - 1.0;

    let mut skip5 = false;
    let a2 = xaf0 + a0;
    if a2 > 0.0 {
        let x2 = x0 - (xn | 1) as f32;
        value += (a2 * a2)
            * (a2 * a2)
            * grad(
                seed,
                i.wrapping_add(!xn & PRIME_X),
                j.wrapping_add(yn & PRIME_Y),
                k.wrapping_add(zn & PRIME_Z),
                x2,
                y0,
                z0,
            );
    } else {
        let a3 = yaf0 + zaf0 + a0;
        if a3 > 0.0 {
            let y3 = y0 - (yn | 1) as f32;
            let z3 = z0 - (zn | 1) as f32;
            value += (a3 * a3)
                * (a3 * a3)
                * grad(
                    seed,
                    i.wrapping_add(xn & PRIME_X),
                    j.wrapping_add(!yn & PRIME_Y),
                    k.wrapping_add(!zn & PRIME_Z),
                    x0,
                    y3,
                    z3,
                );
        }
        let a4 = xaf1 + a1;
        if a4 > 0.0 {
            let x4 = (xn | 1) as f32 + x1;
            value += (a4 * a4)
                * (a4 * a4)
                * grad(
                    seed2,
                    i.wrapping_add(xn & (PRIME_X.wrapping_mul(2))),
                    j.wrapping_add(PRIME_Y),
                    k.wrapping_add(PRIME_Z),
                    x4,
                    y1,
                    z1,
                );
            skip5 = true;
        }
    }

    let mut skip9 = false;
    let a6 = yaf0 + a0;
    if a6 > 0.0 {
        let y6 = y0 - (yn | 1) as f32;
        value += (a6 * a6)
            * (a6 * a6)
            * grad(
                seed,
                i.wrapping_add(xn & PRIME_X),
                j.wrapping_add(!yn & PRIME_Y),
                k.wrapping_add(zn & PRIME_Z),
                x0,
                y6,
                z0,
            );
    } else {
        let a7 = xaf0 + zaf0 + a0;
        if a7 > 0.0 {
            let x7 = x0 - (xn | 1) as f32;
            let z7 = z0 - (zn | 1) as f32;
            value += (a7 * a7)
                * (a7 * a7)
                * grad(
                    seed,
                    i.wrapping_add(!xn & PRIME_X),
                    j.wrapping_add(yn & PRIME_Y),
                    k.wrapping_add(!zn & PRIME_Z),
                    x7,
                    y0,
                    z7,
                );
        }
        let a8 = yaf1 + a1;
        if a8 > 0.0 {
            let y8 = (yn | 1) as f32 + y1;
            value += (a8 * a8)
                * (a8 * a8)
                * grad(
                    seed2,
                    i.wrapping_add(PRIME_X),
                    j.wrapping_add(yn & (PRIME_Y << 1)),
                    k.wrapping_add(PRIME_Z),
                    x1,
                    y8,
                    z1,
                );
            skip9 = true;
        }
    }

    let mut skip_d = false;
    let aa = zaf0 + a0;
    if aa > 0.0 {
        let za = z0 - (zn | 1) as f32;
        value += (aa * aa)
            * (aa * aa)
            * grad(
                seed,
                i.wrapping_add(xn & PRIME_X),
                j.wrapping_add(yn & PRIME_Y),
                k.wrapping_add(!zn & PRIME_Z),
                x0,
                y0,
                za,
            );
    } else {
        let ab = xaf0 + yaf0 + a0;
        if ab > 0.0 {
            let xb = x0 - (xn | 1) as f32;
            let yb = y0 - (yn | 1) as f32;
            value += (ab * ab)
                * (ab * ab)
                * grad(
                    seed,
                    i.wrapping_add(!xn & PRIME_X),
                    j.wrapping_add(!yn & PRIME_Y),
                    k.wrapping_add(zn & PRIME_Z),
                    xb,
                    yb,
                    z0,
                );
        }
        let ac = zaf1 + a1;
        if ac > 0.0 {
            let zc = (zn | 1) as f32 + z1;
            value += (ac * ac)
                * (ac * ac)
                * grad(
                    seed2,
                    i.wrapping_add(PRIME_X),
                    j.wrapping_add(PRIME_Y),
                    k.wrapping_add(zn & (PRIME_Z << 1)),
                    x1,
                    y1,
                    zc,
                );
            skip_d = true;
        }
    }

    if !skip5 {
        let a5 = yaf1 + zaf1 + a1;
        if a5 > 0.0 {
            let y5 = (yn | 1) as f32 + y1;
            let z5 = (zn | 1) as f32 + z1;
            value += (a5 * a5)
                * (a5 * a5)
                * grad(
                    seed2,
                    i.wrapping_add(PRIME_X),
                    j.wrapping_add(yn & (PRIME_Y << 1)),
                    k.wrapping_add(zn & (PRIME_Z << 1)),
                    x1,
                    y5,
                    z5,
                );
        }
    }
    if !skip9 {
        let a9 = xaf1 + zaf1 + a1;
        if a9 > 0.0 {
            let x9 = (xn | 1) as f32 + x1;
            let z9 = (zn | 1) as f32 + z1;
            value += (a9 * a9)
                * (a9 * a9)
                * grad(
                    seed2,
                    i.wrapping_add(xn & (PRIME_X.wrapping_mul(2))),
                    j.wrapping_add(PRIME_Y),
                    k.wrapping_add(zn & (PRIME_Z << 1)),
                    x9,
                    y1,
                    z9,
                );
        }
    }
    if !skip_d {
        let ad = xaf1 + yaf1 + a1;
        if ad > 0.0 {
            let xd = (xn | 1) as f32 + x1;
            let yd = (yn | 1) as f32 + y1;
            value += (ad * ad)
                * (ad * ad)
                * grad(
                    seed2,
                    i.wrapping_add(xn & (PRIME_X << 1)),
                    j.wrapping_add(yn & (PRIME_Y << 1)),
                    k.wrapping_add(PRIME_Z),
                    xd,
                    yd,
                    z1,
                );
        }
    }
    value * 9.046_026
}

impl FastNoise {
    pub fn new(seed: i32, kind: Fractal, frequency: f32) -> Self {
        let bounding = match kind {
            Fractal::None => 1.0,
            Fractal::Fbm { octaves, gain, .. } => {
                let g = gain.abs();
                let mut amp = g;
                let mut total = 1.0f32;
                for _ in 1..octaves {
                    total += amp;
                    amp *= g;
                }
                1.0 / total
            }
        };
        FastNoise {
            seed,
            kind,
            frequency,
            bounding,
        }
    }

    /// `get_noise_3d(x, y, z)`: координаты — f32, как у `real_t` Godot.
    pub fn get3(&self, x: f32, y: f32, z: f32) -> f32 {
        let (mut x, mut y, mut z) = (x * self.frequency, y * self.frequency, z * self.frequency);
        // поворот 3D по умолчанию для OpenSimplex2(S): r = (x+y+z)*2/3; p = r - p
        let r = (x + y + z) * R3;
        x = r - x;
        y = r - y;
        z = r - z;
        match self.kind {
            Fractal::None => simplex2s(self.seed, x, y, z),
            Fractal::Fbm {
                octaves,
                gain,
                lacunarity,
                weighted_strength,
            } => {
                let mut seed = self.seed;
                let mut sum = 0.0f32;
                let mut amp = self.bounding;
                for _ in 0..octaves {
                    let n = simplex2s(seed, x, y, z);
                    seed = seed.wrapping_add(1);
                    sum += n * amp;
                    amp *= lerp(1.0, ((n + 1.0).min(2.0)) * 0.5, weighted_strength);
                    x *= lacunarity;
                    y *= lacunarity;
                    z *= lacunarity;
                    amp *= gain;
                }
                sum
            }
        }
    }
}

#[inline]
fn lerp(a: f32, b: f32, t: f32) -> f32 {
    a + t * (b - a)
}
