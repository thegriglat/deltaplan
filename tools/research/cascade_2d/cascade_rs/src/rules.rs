//! Face-splitting rules: how a parent face flux is shared between its two sub-faces and how the
//! four inner faces of a parent cell follow from the mass balance of the four children.
//!
//! Everything here is a pure function of the parent field (faces, neighbours along the face,
//! cell values) and of the geometry, so the same call gives the same bits in the full-field mode
//! and in the point-by-point mode.

use crate::geo::Geo;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

pub const G: f64 = 9.81;
/// Reference potential temperature for buoyancy, K.
pub const THETA0: f64 = 300.0;
const KAPPA: f64 = 0.4;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub enum Variant {
    V0,
    V1,
    V2,
    V3,
    V3h,
}

impl Variant {
    pub fn parse(s: &str) -> Option<Variant> {
        Some(match s {
            "V0" => Variant::V0,
            "V1" => Variant::V1,
            "V2" => Variant::V2,
            "V3" => Variant::V3,
            "V3h" => Variant::V3h,
            _ => return None,
        })
    }
    pub fn name(self) -> &'static str {
        match self {
            Variant::V0 => "V0",
            Variant::V1 => "V1",
            Variant::V2 => "V2",
            Variant::V3 => "V3",
            Variant::V3h => "V3h",
        }
    }
    /// V0 and V1 know nothing about the terrain of the finer levels.
    pub fn inherits_geometry(self) -> bool {
        self <= Variant::V1
    }
    fn slope(self) -> bool {
        self >= Variant::V1
    }
    fn stab_heat(self) -> bool {
        self >= Variant::V3
    }
    fn hash(self) -> bool {
        self == Variant::V3h
    }
    pub const ALL: [Variant; 5] = [
        Variant::V0,
        Variant::V1,
        Variant::V2,
        Variant::V3,
        Variant::V3h,
    ];
}

/// Physical constants of the rules (justification in README).
#[derive(Clone, Debug)]
pub struct Cfg {
    /// Override of the background Brunt-Vaisala frequency, 1/s (default: from the case `gam`).
    pub n_bg: Option<f64>,
    /// Relaxation time of theta' (case `params.tau_cool`), s.
    pub tau_cool: f64,
    /// Roughness length (case `params.z0`), m.
    pub z0: f64,
    /// Froude number below which the flow does not climb (blocking, Fr ~ 0.8-1.1).
    pub fr_c: f64,
    /// Strength of the heat rule: share of |w| moved to the warmer sub-face at full contrast.
    pub heat_c: f64,
    /// Temperature contrast of a full effect, K.
    pub theta_s: f64,
    /// Hash amplitude on the coarsest descent step.
    pub delta0: f64,
    /// Mixing length cap, m.
    pub lambda: f64,
}

impl Default for Cfg {
    fn default() -> Self {
        Cfg {
            n_bg: None,
            tau_cool: 7200.0,
            z0: 0.1,
            fr_c: 1.0,
            heat_c: 0.5,
            theta_s: 0.5,
            delta0: 0.1,
            lambda: 40.0,
        }
    }
}

/// Counters of rule activations (order-independent integer sums).
#[derive(Default)]
pub struct Diag {
    pub faces: AtomicU64,
    /// Open parent face, every sub-face closed, flux lost.
    pub lost: AtomicU64,
    /// Wall parent face with an open sub-face (flux stays zero).
    pub wall_open: AtomicU64,
    /// Open parent face where one sub-face is closed (all flux to the other).
    pub one_closed: AtomicU64,
    /// Froude rule reduced an upward shift.
    pub fr_active: AtomicU64,
    /// Heat rule moved flux (|T| > 0.05).
    pub heat_active: AtomicU64,
    /// Parent cells whose children fall apart into several components.
    pub multi_comp: AtomicU64,
}

impl Diag {
    pub fn summary(&self) -> String {
        let g = |a: &AtomicU64| a.load(Ordering::Relaxed);
        format!(
            "faces={} lost_flux_faces={} wall_parent_open_sub={} one_sub_closed={} froude_clipped={} heat_shifted={} split_cells={}",
            g(&self.faces),
            g(&self.lost),
            g(&self.wall_open),
            g(&self.one_closed),
            g(&self.fr_active),
            g(&self.heat_active),
            g(&self.multi_comp)
        )
    }
}

/// Values of the parent level the rules read.
pub trait Src {
    fn u(&self, k: usize, i: usize) -> f32;
    fn w(&self, k: usize, i: usize) -> f32;
    fn th(&self, k: usize, i: usize) -> f32;
}

/// Inner faces of a parent cell (velocities of the child level).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Internal {
    /// x face between the two lower children.
    pub ub: f32,
    /// x face between the two upper children.
    pub ut: f32,
    /// z face between the two left children.
    pub wl: f32,
    /// z face between the two right children.
    pub wr: f32,
}

/// One descent step: parent geometry, child geometry and variant.
#[derive(Clone)]
pub struct Ctx {
    pub var: Variant,
    pub seed: u64,
    /// Level index of the child (1 for 400 -> 200).
    pub n: u32,
    pub pg: Arc<Geo>,
    pub cg: Arc<Geo>,
    pub cfg: Arc<Cfg>,
    pub diag: Arc<Diag>,
}

fn wall_zero() -> bool {
    static F: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *F.get_or_init(|| std::env::var_os("CASCADE_WALL_ZERO").is_some())
}

/// Diagnostic only (`CASCADE_WALL_NOLIMIT=1`): at the lowest air face the slope is `u - 0` (the wall as
/// the neighbour one cell below) without the limiter - what linear interpolation of the coarse field does.
fn diag_wall_nolimit() -> bool {
    static F: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *F.get_or_init(|| std::env::var_os("CASCADE_WALL_NOLIMIT").is_some())
}

fn minmod(a: f64, b: f64) -> f64 {
    if a * b <= 0.0 {
        0.0
    } else if a > 0.0 {
        a.min(b)
    } else {
        a.max(b)
    }
}

fn mix(z: u64) -> u64 {
    let mut z = z.wrapping_add(0x9E37_79B9_7F4A_7C15);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

/// Uniform number in [-1, 1) from (seed, level, kind, position) of a face.
pub fn face_hash(seed: u64, level: u32, kind: u64, k: usize, i: usize) -> f64 {
    let h = mix(mix(mix(mix(seed ^ level as u64) ^ kind) ^ k as u64) ^ i as u64);
    (h >> 11) as f64 / (1u64 << 53) as f64 * 2.0 - 1.0
}

impl Ctx {
    /// Child row of parent row `k`, half `s` (may be -1: no such child).
    pub fn crow(k: usize, s: usize) -> i64 {
        2 * k as i64 + s as i64 - 1
    }

    // ---- reading helpers -------------------------------------------------------------------

    /// Limited slope of a profile at index `n` from neighbours `n-1`, `n+1` (`open(m)`: the face
    /// `m` exists and carries flux). Both neighbours open: centred minmod. Exactly one open
    /// (wall or edge on the other side): one-sided slope from the two interior faces on the open
    /// side, with the same limiter; no wall value (zero) is substituted. None open: 0.
    /// `CASCADE_WALL_ZERO=1` restores the original rule (zero slope at a wall) for the "before" series.
    pub(crate) fn limited_slope(n: usize, len: usize, open: &dyn Fn(i64) -> bool, val: &dyn Fn(usize) -> f64) -> f64 {
        let lo = n > 0 && open(n as i64 - 1);
        let hi = n + 1 < len && open(n as i64 + 1);
        let v0 = val(n);
        match (lo, hi) {
            (true, true) => minmod(v0 - val(n - 1), val(n + 1) - v0),
            _ if wall_zero() => 0.0,
            (false, true) if diag_wall_nolimit() => v0, // diagnostic: wall value 0 one cell below, no limiter
            (false, true) => {
                let a = val(n + 1) - v0;
                let b = if n + 2 < len && open(n as i64 + 2) { val(n + 2) - val(n + 1) } else { a };
                minmod(a, b)
            }
            (true, false) => {
                let a = v0 - val(n - 1);
                let b = if n >= 2 && open(n as i64 - 2) { val(n - 1) - val(n - 2) } else { a };
                minmod(a, b)
            }
            (false, false) => 0.0,
        }
    }

    fn slope_u(&self, s: &dyn Src, k: usize, i: usize) -> f64 {
        let g = &self.pg;
        Self::limited_slope(k, g.nz, &|m| g.u_open(m, i as i64), &|m| s.u(m, i) as f64)
    }

    fn slope_w(&self, s: &dyn Src, k: usize, i: usize) -> f64 {
        let g = &self.pg;
        Self::limited_slope(i, g.nx, &|m| g.w_open(k as i64, m), &|m| s.w(k, m) as f64)
    }

    /// N^2 of a parent cell: background plus the vertical gradient of theta'.
    pub(crate) fn n2(&self, s: &dyn Src, k: usize, i: usize) -> f64 {
        let g = &self.pg;
        let t = |kk: usize| s.th(kk, i) as f64;
        let up = g.air(k as i64 + 1, i as i64);
        let dn = k > 0 && g.air(k as i64 - 1, i as i64);
        let d = match (dn, up) {
            (true, true) => (t(k + 1) - t(k - 1)) / (2.0 * g.dz),
            (false, true) => (t(k + 1) - t(k)) / g.dz,
            (true, false) => (t(k) - t(k - 1)) / g.dz,
            _ => 0.0,
        };
        let gam = match self.cfg.n_bg {
            Some(n) => n * n * THETA0 / G,
            None => g.gam[k],
        };
        (G / THETA0 * (gam + d)).max(0.0)
    }

    /// Mean N^2 of the air cells next to an x face.
    fn n2_xface(&self, s: &dyn Src, k: usize, i: usize) -> f64 {
        let g = &self.pg;
        let (mut sum, mut n) = (0.0, 0.0);
        for ii in [i as i64 - 1, i as i64] {
            if g.air(k as i64, ii) {
                sum += self.n2(s, k, ii as usize);
                n += 1.0;
            }
        }
        if n > 0.0 { sum / n } else { 0.0 }
    }

    fn n2_zface(&self, s: &dyn Src, k: usize, i: usize) -> f64 {
        let g = &self.pg;
        let (mut sum, mut n) = (0.0, 0.0);
        for kk in [k as i64 - 1, k as i64] {
            if g.air(kk, i as i64) {
                sum += self.n2(s, kk as usize, i);
                n += 1.0;
            }
        }
        if n > 0.0 { sum / n } else { 0.0 }
    }

    /// Reduction factor of vertical displacement: min(1, Fr/Fr_c), Fr = U/(N dz) of the parent.
    fn fr_factor(&self, n2: f64, speed: f64) -> f64 {
        if n2 <= 0.0 {
            return 1.0;
        }
        let fr = speed / (n2.sqrt() * self.pg.dz);
        (fr / self.cfg.fr_c).min(1.0)
    }

    /// Turbulent velocity scale u*_m = l |dU/dz| / (1 + 5 Ri) from the shear of the parent.
    fn ustar(&self, shear: f64, n2: f64, z_agl: f64) -> f64 {
        let z = z_agl.max(self.cfg.z0);
        let l = 1.0 / (1.0 / (KAPPA * z) + 1.0 / self.cfg.lambda);
        let ri = if shear > 1e-9 {
            n2 / (shear * shear)
        } else {
            0.0
        };
        l * shear / (1.0 + 5.0 * ri)
    }

    fn sigma_w(us: f64) -> f64 {
        1.25 * us
    }

    fn sigma_u(us: f64, z_agl: f64) -> f64 {
        let h_ft = z_agl.max(0.0) / 0.3048;
        1.25 * us * (0.177 + 0.000_823 * h_ft).powf(-0.4)
    }

    fn delta_n(&self) -> f64 {
        self.cfg.delta0 * 2f64.powf(-(self.n as f64) / 3.0)
    }

    fn hcol_x(&self, i: usize) -> f64 {
        let g = &self.pg;
        let (mut s, mut n) = (0.0, 0.0);
        for ii in [i as i64 - 1, i as i64] {
            if ii >= 0 && (ii as usize) < g.nx {
                s += g.h[ii as usize] as f64;
                n += 1.0;
            }
        }
        s / n
    }

    // ---- face splitting --------------------------------------------------------------------

    /// Sub-face velocities (lower, upper) of the parent x face `(k, i)`; mean = parent velocity.
    pub fn split_x(&self, s: &dyn Src, k: usize, i: usize) -> (f32, f32) {
        self.split_x_d(s, k, i, false)
    }

    pub fn split_x_d(&self, s: &dyn Src, k: usize, i: usize, count: bool) -> (f32, f32) {
        let (pg, cg) = (&self.pg, &self.cg);
        let (ki, ii) = (k as i64, i as i64);
        let ol = cg.u_open(Self::crow(k, 0), 2 * ii);
        let oh = cg.u_open(Self::crow(k, 1), 2 * ii);
        if count {
            self.diag.faces.fetch_add(1, Ordering::Relaxed);
        }
        if !pg.u_open(ki, ii) {
            // Wall of the parent: no flux, sub-faces stay closed in the flux sense (minimal rule).
            if count && (ol || oh) {
                self.diag.wall_open.fetch_add(1, Ordering::Relaxed);
            }
            return (0.0, 0.0);
        }
        let u = s.u(k, i) as f64;
        match (ol, oh) {
            (false, false) => {
                if count && u != 0.0 {
                    self.diag.lost.fetch_add(1, Ordering::Relaxed);
                }
                (0.0, 0.0)
            }
            (false, true) => {
                if count {
                    self.diag.one_closed.fetch_add(1, Ordering::Relaxed);
                }
                (0.0, (2.0 * u) as f32)
            }
            (true, false) => {
                if count {
                    self.diag.one_closed.fetch_add(1, Ordering::Relaxed);
                }
                ((2.0 * u) as f32, 0.0)
            }
            (true, true) => {
                let mut d = if self.var.slope() {
                    0.25 * self.slope_u(s, k, i)
                } else {
                    0.0
                };
                if self.var.stab_heat() && d * u > 0.0 {
                    let gfac = self.fr_factor(self.n2_xface(s, k, i), u.abs());
                    if gfac < 1.0 {
                        if count {
                            self.diag.fr_active.fetch_add(1, Ordering::Relaxed);
                        }
                        d *= gfac;
                    }
                }
                if self.var.hash() {
                    d += 2.0
                        * self.delta_n()
                        * self.sigma_x(s, k, i)
                        * face_hash(self.seed, self.n, 0, k, i);
                }
                let lo = (u - d) as f32;
                (lo, (2.0 * u - lo as f64) as f32)
            }
        }
    }

    fn sigma_x(&self, s: &dyn Src, k: usize, i: usize) -> f64 {
        let g = &self.pg;
        let u0 = s.u(k, i) as f64;
        let dn = k > 0 && g.u_open(k as i64 - 1, i as i64);
        let up = k + 1 < g.nz && g.u_open(k as i64 + 1, i as i64);
        let shear = match (dn, up) {
            (true, true) => (s.u(k + 1, i) as f64 - s.u(k - 1, i) as f64).abs() / (2.0 * g.dz),
            (false, true) => (s.u(k + 1, i) as f64 - u0).abs() / g.dz,
            (true, false) => (u0 - s.u(k - 1, i) as f64).abs() / g.dz,
            _ => 0.0,
        };
        let z_agl = g.z0 + (k as f64 + 0.5) * g.dz - self.hcol_x(i);
        let us = self.ustar(shear, self.n2_xface(s, k, i), z_agl);
        Self::sigma_u(us, z_agl)
    }

    fn sigma_z(&self, s: &dyn Src, k: usize, i: usize) -> f64 {
        let g = &self.pg;
        let uc = |kk: usize| 0.5 * (s.u(kk, i) as f64 + s.u(kk, i + 1) as f64);
        let shear =
            if k >= 1 && k < g.nz && g.air(k as i64 - 1, i as i64) && g.air(k as i64, i as i64) {
                (uc(k) - uc(k - 1)).abs() / g.dz
            } else {
                0.0
            };
        let z_agl = g.z0 + k as f64 * g.dz - g.h[i] as f64;
        let us = self.ustar(shear, self.n2_zface(s, k, i), z_agl);
        Self::sigma_w(us)
    }

    /// Theta' of a child cell: parent value, in V3 plus the local heating relative to the mean
    /// heating of the parent's air children (relaxation balance theta' = tau Q).
    pub fn child_th(&self, s: &dyn Src, k: usize, i: usize, sr: usize, sc: usize) -> f32 {
        let t = s.th(k, i) as f64;
        if !self.var.stab_heat() || !self.pg.air(k as i64, i as i64) {
            return t as f32;
        }
        let cg = &self.cg;
        let (mut sum, mut n) = (0.0, 0.0);
        for a in 0..2 {
            for b in 0..2 {
                let (r, c) = (Self::crow(k, a), 2 * i as i64 + b as i64);
                if cg.air(r, c) {
                    sum += cg.q_at(r, c);
                    n += 1.0;
                }
            }
        }
        let (r, c) = (Self::crow(k, sr), (2 * i + sc) as i64);
        if n == 0.0 || !cg.air(r, c) {
            return t as f32;
        }
        (t + self.cfg.tau_cool * (cg.q_at(r, c) - sum / n)) as f32
    }

    /// Mean child theta' on the two sides of the sub-face column `c` of parent z face `(k, i)`.
    fn theta_zsub(&self, s: &dyn Src, k: usize, i: usize, c: usize) -> f64 {
        let cg = &self.cg;
        let (mut sum, mut n) = (0.0, 0.0);
        if k >= 1 && cg.air(Self::crow(k - 1, 1), (2 * i + c) as i64) {
            sum += self.child_th(s, k - 1, i, 1, c) as f64;
            n += 1.0;
        }
        if k < self.pg.nz && cg.air(Self::crow(k, 0), (2 * i + c) as i64) {
            sum += self.child_th(s, k, i, 0, c) as f64;
            n += 1.0;
        }
        if n > 0.0 { sum / n } else { 0.0 }
    }

    /// Sub-face velocities (left, right) of the parent z face `(k, i)`.
    pub fn split_z(&self, s: &dyn Src, k: usize, i: usize) -> (f32, f32) {
        self.split_z_d(s, k, i, false)
    }

    pub fn split_z_d(&self, s: &dyn Src, k: usize, i: usize, count: bool) -> (f32, f32) {
        let (pg, cg) = (&self.pg, &self.cg);
        let fz = 2 * k as i64 - 1;
        let ol = cg.w_open(fz, 2 * i as i64);
        let or = cg.w_open(fz, 2 * i as i64 + 1);
        if count {
            self.diag.faces.fetch_add(1, Ordering::Relaxed);
        }
        if !pg.w_open(k as i64, i as i64) {
            if count && (ol || or) {
                self.diag.wall_open.fetch_add(1, Ordering::Relaxed);
            }
            return (0.0, 0.0);
        }
        let w = s.w(k, i) as f64;
        match (ol, or) {
            (false, false) => {
                if count && w != 0.0 {
                    self.diag.lost.fetch_add(1, Ordering::Relaxed);
                }
                (0.0, 0.0)
            }
            (false, true) => {
                if count {
                    self.diag.one_closed.fetch_add(1, Ordering::Relaxed);
                }
                (0.0, (2.0 * w) as f32)
            }
            (true, false) => {
                if count {
                    self.diag.one_closed.fetch_add(1, Ordering::Relaxed);
                }
                ((2.0 * w) as f32, 0.0)
            }
            (true, true) => {
                let mut d = if self.var.slope() {
                    0.25 * self.slope_w(s, k, i)
                } else {
                    0.0
                };
                if self.var.stab_heat() {
                    // Flux goes to the warmer sub-face: rising air up, sinking air on the cold side.
                    let t = ((self.theta_zsub(s, k, i, 1) - self.theta_zsub(s, k, i, 0))
                        / self.cfg.theta_s)
                        .clamp(-1.0, 1.0);
                    if t.abs() > 0.05 && count {
                        self.diag.heat_active.fetch_add(1, Ordering::Relaxed);
                    }
                    d += self.cfg.heat_c * w.abs() * t;
                }
                if self.var.hash() {
                    d += 2.0
                        * self.delta_n()
                        * self.sigma_z(s, k, i)
                        * face_hash(self.seed, self.n, 1, k, i);
                }
                // Keep both sub-faces in the direction of the parent flux (share in [0, 1]).
                let d = d.clamp(-w.abs(), w.abs());
                let left = (w - d) as f32;
                (left, (2.0 * w - left as f64) as f32)
            }
        }
    }

    // ---- inner faces -----------------------------------------------------------------------

    /// Inner faces of parent cell `(k, i)` from the mass balance of the four children.
    ///
    /// Children 0..4 are (lower-left, lower-right, upper-left, upper-right). Edges: 0 = x face
    /// between 0 and 1, 1 = x face between 2 and 3, 2 = z face between 0 and 2, 3 = z face
    /// between 1 and 3. Every connected group of air children gets the same divergence (the mean
    /// of its outer net flux per area, i.e. the parent's own divergence for a whole cell), so the
    /// balance is exact; one free circulation remains when all four edges are open.
    pub fn internal(&self, s: &dyn Src, k: usize, i: usize) -> Internal {
        self.internal_d(s, k, i, false)
    }

    pub fn internal_d(&self, s: &dyn Src, k: usize, i: usize, count: bool) -> Internal {
        let (pg, cg) = (&self.pg, &self.cg);
        if !pg.air(k as i64, i as i64) {
            return Internal::default();
        }
        let (ki, ii) = (k as i64, 2 * i as i64);
        let air = [
            cg.air(Self::crow(k, 0), ii),
            cg.air(Self::crow(k, 0), ii + 1),
            cg.air(Self::crow(k, 1), ii),
            cg.air(Self::crow(k, 1), ii + 1),
        ];
        let open = [
            air[0] && air[1] && cg.u_open(Self::crow(k, 0), ii + 1),
            air[2] && air[3] && cg.u_open(Self::crow(k, 1), ii + 1),
            air[0] && air[2] && cg.w_open(2 * ki, ii),
            air[1] && air[3] && cg.w_open(2 * ki, ii + 1),
        ];
        if !open.iter().any(|&o| o) {
            return Internal::default();
        }
        let (ul_lo, ul_hi) = self.split_x(s, k, i);
        let (ur_lo, ur_hi) = self.split_x(s, k, i + 1);
        let (wb_l, wb_r) = self.split_z(s, k, i);
        let (wt_l, wt_r) = self.split_z(s, k + 1, i);
        let lx = cg.dz; // length of an x face of a child
        let lz = cg.dx; // length of a z face of a child
        let ext = [
            -(ul_lo as f64) * lx - wb_l as f64 * lz,
            ur_lo as f64 * lx - wb_r as f64 * lz,
            -(ul_hi as f64) * lx + wt_l as f64 * lz,
            ur_hi as f64 * lx + wt_r as f64 * lz,
        ];
        const FROM: [usize; 4] = [0, 2, 0, 1];
        const TO: [usize; 4] = [1, 3, 2, 3];
        // connected groups (union-find on 4 nodes), spanning forest, extra (cycle) edge
        let mut comp = [0usize, 1, 2, 3];
        fn find(c: &mut [usize; 4], mut x: usize) -> usize {
            while c[x] != x {
                c[x] = c[c[x]];
                x = c[x];
            }
            x
        }
        let mut tree = [false; 4];
        let mut extra: Option<usize> = None;
        for e in 0..4 {
            if !open[e] {
                continue;
            }
            let (a, b) = (find(&mut comp, FROM[e]), find(&mut comp, TO[e]));
            if a == b {
                extra = Some(e);
            } else {
                comp[a] = b;
                tree[e] = true;
            }
        }
        let root: Vec<usize> = (0..4).map(|n| find(&mut comp, n)).collect();
        // required inner outflux per node
        let mut need = [0.0f64; 4];
        let mut roots_seen = 0;
        for n in 0..4 {
            if !air[n] {
                continue;
            }
            let (mut sum, mut cnt) = (0.0, 0.0);
            for m in 0..4 {
                if air[m] && root[m] == root[n] {
                    sum += ext[m];
                    cnt += 1.0;
                }
            }
            need[n] = sum / cnt - ext[n];
            if root[n] == n {
                roots_seen += 1;
            }
        }
        if count && roots_seen > 1 {
            self.diag.multi_comp.fetch_add(1, Ordering::Relaxed);
        }
        // leaf stripping on the spanning forest
        let mut flux = [0.0f64; 4];
        let mut done = [false; 4];
        loop {
            let mut changed = false;
            for n in 0..4 {
                if !air[n] {
                    continue;
                }
                let inc: Vec<usize> = (0..4)
                    .filter(|&e| tree[e] && (FROM[e] == n || TO[e] == n))
                    .collect();
                let free: Vec<usize> = inc.iter().copied().filter(|&e| !done[e]).collect();
                if free.len() != 1 {
                    continue;
                }
                let mut rest = need[n];
                for &e in &inc {
                    if done[e] {
                        rest -= if FROM[e] == n { flux[e] } else { -flux[e] };
                    }
                }
                let e = free[0];
                flux[e] = if FROM[e] == n { rest } else { -rest };
                done[e] = true;
                changed = true;
            }
            if !changed {
                break;
            }
        }
        let len = [lx, lx, lz, lz];
        if extra.is_some() {
            // Circulation: pick the one closest (least squares in velocity) to the velocities
            // interpolated from the outer sub-faces (V0: closest to zero).
            let mut tv = if self.var.slope() {
                [
                    0.5 * (ul_lo as f64 + ur_lo as f64),
                    0.5 * (ul_hi as f64 + ur_hi as f64),
                    0.5 * (wb_l as f64 + wt_l as f64),
                    0.5 * (wb_r as f64 + wt_r as f64),
                ]
            } else {
                [0.0; 4]
            };
            if self.var.stab_heat() {
                let speed = (0.5 * (s.u(k, i) as f64 + s.u(k, i + 1) as f64)).abs();
                let gfac = self.fr_factor(self.n2(s, k, i), speed);
                tv[2] *= gfac;
                tv[3] *= gfac;
            }
            const SIG: [f64; 4] = [1.0, -1.0, -1.0, 1.0];
            let (mut num, mut den) = (0.0, 0.0);
            for e in 0..4 {
                num += SIG[e] * (tv[e] - flux[e] / len[e]) / len[e];
                den += 1.0 / (len[e] * len[e]);
            }
            let phi = num / den;
            for e in 0..4 {
                flux[e] += SIG[e] * phi;
            }
        }
        let v = |e: usize| {
            if open[e] {
                (flux[e] / len[e]) as f32
            } else {
                0.0
            }
        };
        Internal {
            ub: v(0),
            ut: v(1),
            wl: v(2),
            wr: v(3),
        }
    }
}
