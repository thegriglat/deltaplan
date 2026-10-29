//! Генератор PCG32 (O'Neill): `randf()`, `randf_range()`, `randi()`.

const MULT: u64 = 6_364_136_223_846_793_005;
const INC: u64 = 1_442_695_040_888_963_407;

#[derive(Clone, Debug)]
pub struct Pcg32 {
    state: u64,
    inc: u64,
}

impl Pcg32 {
    /// Сид `s` (знаковый сид — `s as u64`).
    pub fn from_seed(seed: u64) -> Self {
        let mut r = Pcg32 {
            state: 0,
            inc: (INC << 1) | 1,
        };
        r.randi();
        r.state = r.state.wrapping_add(seed);
        r.randi();
        r
    }

    pub fn randi(&mut self) -> u32 {
        let old = self.state;
        self.state = old.wrapping_mul(MULT).wrapping_add(self.inc);
        let xorshifted = (((old >> 18) ^ old) >> 27) as u32;
        let rot = (old >> 59) as u32;
        xorshifted.rotate_right(rot)
    }

    pub fn randf(&mut self) -> f32 {
        let proto = self.randi();
        if proto == 0 {
            return 0.0;
        }
        // ldexp((float)(rand() | 0x80000001), -32 - countl_zero(proto))
        let m = (self.randi() | 0x8000_0001) as f32;
        m * f32::from_bits((127 - 32 - proto.leading_zeros()) << 23)
    }

    pub fn randf_range(&mut self, a: f32, b: f32) -> f32 {
        self.randf() * (b - a) + a
    }
}
