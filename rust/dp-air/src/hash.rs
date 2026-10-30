//! Хеш целочисленных векторов 2D/3D: murmur3 по компонентам, затем `fmix32`.

/// Начальное значение murmur3 (константа формата, значения хешей зафиксированы эталоном).
const SEED: u32 = 0x7F07C65;

#[inline]
fn murmur_one(k: u32, mut h: u32) -> u32 {
    let mut k = k.wrapping_mul(0xcc9e_2d51);
    k = k.rotate_left(15);
    k = k.wrapping_mul(0x1b87_3593);
    h ^= k;
    h = h.rotate_left(13);
    h.wrapping_mul(5).wrapping_add(0xe654_6b64)
}

#[inline]
fn fmix32(mut h: u32) -> u32 {
    h ^= h >> 16;
    h = h.wrapping_mul(0x85eb_ca6b);
    h ^= h >> 13;
    h = h.wrapping_mul(0xc2b2_ae35);
    h ^ (h >> 16)
}

/// `hash(Vector2i(x, y))`.
pub fn hash_v2i(x: i32, y: i32) -> u32 {
    fmix32(murmur_one(y as u32, murmur_one(x as u32, SEED)))
}

/// `hash(Vector3i(x, y, z))`.
pub fn hash_v3i(x: i32, y: i32, z: i32) -> u32 {
    fmix32(murmur_one(
        z as u32,
        murmur_one(y as u32, murmur_one(x as u32, SEED)),
    ))
}
