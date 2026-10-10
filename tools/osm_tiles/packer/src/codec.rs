//! O2 (контейнер) и O3 (кодировка потоков).
//!
//! API для упаковщика: собрать [`Tile`] из структур объектов по потокам и вызвать [`encode_tile`];
//! обратно — [`decode_tile`]. Порядок объектов (O3) задаёт вызывающий; здесь только [`morton`]
//! и [`line_len_m`] как помощники. Фрагмент (O4): `Tile.fragment = true` и `StreamData.ids`
//! (ключи `id*4 + тип`, по записи на объект/часть).

use crate::pb::{self, Kind};
use crate::Result;
use prost::Message;
use serde_json::{json, Value};

pub const MAGIC: &[u8; 4] = b"DPOT";
pub const CONTAINER_VERSION: u16 = 1;
pub const FORMAT_VERSION: u32 = 1;
pub const MAX_RAW_LEN: u32 = 64 << 20;
pub const LEVEL_FINAL: i32 = 19;
pub const LEVEL_FRAGMENT: i32 = 3;

pub type Pt = (i64, i64);

/// ROADS / TRACK.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct Road {
    pub cls: u32,
    pub width_dm: Option<u32>,
    pub lanes: Option<u32>,
    pub tunnel: bool,
    pub bridge: bool,
    pub pts: Vec<Pt>,
}

/// BUILDINGS: ориентированный прямоугольник (центр, м; стороны и высота в полуметрах).
#[derive(Clone, Debug, PartialEq, Default)]
pub struct Building {
    pub x: i64,
    pub y: i64,
    pub w2: u32,
    pub l2: u32,
    pub angle: u32,
    pub hq: u32,
    pub lv: bool,
    pub typ: u32,
}

/// Общая запись потоков «для пилота» (powerline, power_tower, aerialway, aeroway, vertical, rail, peak, pass, river, canal).
#[derive(Clone, Debug, PartialEq, Default)]
pub struct Obj {
    pub cls: u32,
    pub flags: u8,
    pub h: u32,
    pub pts: Vec<Pt>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Objects {
    Roads(Vec<Road>),
    Buildings(Vec<Building>),
    Generic(Vec<Obj>),
    Names(Vec<String>),
}

impl Objects {
    pub fn empty_for(kind: Kind) -> Objects {
        match kind {
            Kind::Roads | Kind::Track => Objects::Roads(vec![]),
            Kind::Buildings => Objects::Buildings(vec![]),
            Kind::Names => Objects::Names(vec![]),
            _ => Objects::Generic(vec![]),
        }
    }
    pub fn len(&self) -> usize {
        match self {
            Objects::Roads(v) => v.len(),
            Objects::Buildings(v) => v.len(),
            Objects::Generic(v) => v.len(),
            Objects::Names(v) => v.len(),
        }
    }
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct StreamData {
    pub kind: Kind,
    pub objects: Objects,
    /// Только во фрагментах: ключ `id*4 + тип` на каждый объект (O4); иначе пусто.
    pub ids: Vec<i64>,
}

#[derive(Clone, Debug, PartialEq, Default)]
pub struct Tile {
    pub fragment: bool,
    pub j: i32,
    pub i: u32,
    pub n: u32,
    pub osm_timestamp: i64,
    pub sources: Vec<String>,
    pub streams: Vec<StreamData>,
}

impl Tile {
    pub fn stream(&self, kind: Kind) -> Option<&StreamData> {
        self.streams.iter().find(|s| s.kind == kind)
    }
}

pub const ALL_KINDS: [Kind; 14] = [
    Kind::Roads, Kind::Track, Kind::Buildings, Kind::Powerline, Kind::PowerTower, Kind::Aerialway,
    Kind::Aeroway, Kind::Vertical, Kind::Rail, Kind::Peak, Kind::Pass, Kind::Names, Kind::River, Kind::Canal,
];

pub fn kind_name(k: Kind) -> &'static str {
    match k {
        Kind::Unspecified => "unspecified",
        Kind::Roads => "roads",
        Kind::Track => "track",
        Kind::Buildings => "buildings",
        Kind::Powerline => "powerline",
        Kind::PowerTower => "power_tower",
        Kind::Aerialway => "aerialway",
        Kind::Aeroway => "aeroway",
        Kind::Vertical => "vertical",
        Kind::Rail => "rail",
        Kind::Peak => "peak",
        Kind::Pass => "pass",
        Kind::Names => "names",
        Kind::River => "river",
        Kind::Canal => "canal",
    }
}

// ---------------------------------------------------------------- примитивы

pub fn put_varint(out: &mut Vec<u8>, mut v: u64) {
    while v >= 0x80 {
        out.push((v as u8 & 0x7f) | 0x80);
        v >>= 7;
    }
    out.push(v as u8);
}

pub fn zz(v: i64) -> u64 {
    ((v << 1) ^ (v >> 63)) as u64
}

pub fn unzz(u: u64) -> i64 {
    ((u >> 1) as i64) ^ -((u & 1) as i64)
}

pub struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    pub fn new(buf: &'a [u8]) -> Self {
        Reader { buf, pos: 0 }
    }
    pub fn varint(&mut self) -> Result<u64> {
        let mut v = 0u64;
        let mut shift = 0;
        loop {
            let b = *self.buf.get(self.pos).ok_or("конец данных в varint")?;
            self.pos += 1;
            if shift >= 64 {
                return Err("varint длиннее 10 байт".into());
            }
            v |= ((b & 0x7f) as u64) << shift;
            if b & 0x80 == 0 {
                return Ok(v);
            }
            shift += 7;
        }
    }
    pub fn u32(&mut self) -> Result<u32> {
        u32::try_from(self.varint()?).map_err(|_| "значение не помещается в u32".to_string())
    }
    pub fn byte(&mut self) -> Result<u8> {
        let b = *self.buf.get(self.pos).ok_or("конец данных")?;
        self.pos += 1;
        Ok(b)
    }
    pub fn bytes(&mut self, n: usize) -> Result<&'a [u8]> {
        if self.pos + n > self.buf.len() {
            return Err("конец данных в строке".into());
        }
        let s = &self.buf[self.pos..self.pos + n];
        self.pos += n;
        Ok(s)
    }
    pub fn done(&self) -> bool {
        self.pos == self.buf.len()
    }
}

fn put_points(out: &mut Vec<u8>, pts: &[Pt], last: &mut Pt) {
    for &(x, y) in pts {
        put_varint(out, zz(x - last.0));
        put_varint(out, zz(y - last.1));
        *last = (x, y);
    }
}

fn read_points(r: &mut Reader, n: usize, last: &mut Pt) -> Result<Vec<Pt>> {
    let mut v = Vec::with_capacity(n.min(1 << 20));
    for _ in 0..n {
        last.0 += unzz(r.varint()?);
        last.1 += unzz(r.varint()?);
        v.push(*last);
    }
    Ok(v)
}

// ---------------------------------------------------------------- потоки O3

/// Кодирует `data` потока.
pub fn encode_objects(objects: &Objects) -> Vec<u8> {
    let mut out = Vec::new();
    let mut last: Pt = (0, 0);
    match objects {
        Objects::Roads(v) => {
            for r in v {
                put_varint(&mut out, r.cls as u64);
                let fl = (r.width_dm.is_some() as u8) | ((r.lanes.is_some() as u8) << 1)
                    | ((r.tunnel as u8) << 3) | ((r.bridge as u8) << 4);
                out.push(fl);
                if let Some(w) = r.width_dm {
                    put_varint(&mut out, w as u64);
                }
                if let Some(l) = r.lanes {
                    put_varint(&mut out, l as u64);
                }
                put_varint(&mut out, r.pts.len() as u64);
                put_points(&mut out, &r.pts, &mut last);
            }
        }
        Objects::Buildings(v) => {
            for b in v {
                put_varint(&mut out, zz(b.x - last.0));
                put_varint(&mut out, zz(b.y - last.1));
                last = (b.x, b.y);
                put_varint(&mut out, b.w2 as u64);
                put_varint(&mut out, b.l2 as u64);
                put_varint(&mut out, b.angle as u64);
                put_varint(&mut out, b.hq as u64 * 2 + b.lv as u64);
                put_varint(&mut out, b.typ as u64);
            }
        }
        Objects::Generic(v) => {
            for o in v {
                put_varint(&mut out, o.cls as u64);
                out.push(o.flags);
                put_varint(&mut out, o.h as u64);
                put_varint(&mut out, o.pts.len() as u64);
                put_points(&mut out, &o.pts, &mut last);
            }
        }
        Objects::Names(v) => {
            for s in v {
                put_varint(&mut out, s.len() as u64);
                out.extend_from_slice(s.as_bytes());
            }
        }
    }
    out
}

pub fn decode_objects(kind: Kind, count: usize, data: &[u8]) -> Result<Objects> {
    let mut r = Reader::new(data);
    let mut last: Pt = (0, 0);
    let objs = match kind {
        Kind::Roads | Kind::Track => {
            let mut v = Vec::new();
            for _ in 0..count {
                let cls = r.u32()?;
                let fl = r.byte()?;
                let width_dm = if fl & 1 != 0 { Some(r.u32()?) } else { None };
                let lanes = if fl & 2 != 0 { Some(r.u32()?) } else { None };
                let np = r.varint()? as usize;
                let pts = read_points(&mut r, np, &mut last)?;
                v.push(Road { cls, width_dm, lanes, tunnel: fl & 8 != 0, bridge: fl & 16 != 0, pts });
            }
            Objects::Roads(v)
        }
        Kind::Buildings => {
            let mut v = Vec::new();
            for _ in 0..count {
                last.0 += unzz(r.varint()?);
                last.1 += unzz(r.varint()?);
                let w2 = r.u32()?;
                let l2 = r.u32()?;
                let angle = r.u32()?;
                let hl = r.varint()?;
                let typ = r.u32()?;
                v.push(Building { x: last.0, y: last.1, w2, l2, angle, hq: (hl >> 1) as u32, lv: hl & 1 != 0, typ });
            }
            Objects::Buildings(v)
        }
        Kind::Names => {
            let mut v = Vec::new();
            for _ in 0..count {
                let n = r.varint()? as usize;
                let b = r.bytes(n)?;
                v.push(String::from_utf8(b.to_vec()).map_err(|_| "имя не UTF-8".to_string())?);
            }
            Objects::Names(v)
        }
        Kind::Unspecified => return Err("kind = UNSPECIFIED".into()),
        _ => {
            let mut v = Vec::new();
            for _ in 0..count {
                let cls = r.u32()?;
                let flags = r.byte()?;
                let h = r.u32()?;
                let np = r.varint()? as usize;
                let pts = read_points(&mut r, np, &mut last)?;
                v.push(Obj { cls, flags, h, pts });
            }
            Objects::Generic(v)
        }
    };
    if !r.done() {
        return Err(format!("поток {}: лишние байты после {count} объектов", kind_name(kind)));
    }
    Ok(objs)
}

fn encode_ids(ids: &[i64]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut prev = 0i64;
    for &k in ids {
        put_varint(&mut out, zz(k - prev));
        prev = k;
    }
    out
}

fn decode_ids(count: usize, data: &[u8]) -> Result<Vec<i64>> {
    let mut r = Reader::new(data);
    let mut prev = 0i64;
    let mut v = Vec::new();
    for _ in 0..count {
        prev += unzz(r.varint()?);
        v.push(prev);
    }
    if !r.done() {
        return Err("лишние байты в ids".into());
    }
    Ok(v)
}

// ---------------------------------------------------------------- тайл ↔ protobuf ↔ файл

/// Структуры → protobuf (без контейнера). Потоки сортируются по kind, пустые не пишутся.
pub fn tile_to_pb(t: &Tile) -> Result<pb::OsmTile> {
    let mut streams: Vec<&StreamData> = t.streams.iter().filter(|s| !s.objects.is_empty()).collect();
    streams.sort_by_key(|s| s.kind as i32);
    let mut out = Vec::new();
    for (k, s) in streams.iter().enumerate() {
        if k > 0 && streams[k - 1].kind == s.kind {
            return Err(format!("поток {} повторяется", kind_name(s.kind)));
        }
        let ok = matches!(
            (&s.objects, s.kind),
            (Objects::Roads(_), Kind::Roads | Kind::Track)
                | (Objects::Buildings(_), Kind::Buildings)
                | (Objects::Names(_), Kind::Names)
        ) || (matches!(s.objects, Objects::Generic(_))
            && !matches!(s.kind, Kind::Roads | Kind::Track | Kind::Buildings | Kind::Names | Kind::Unspecified));
        if !ok {
            return Err(format!("тип объектов не подходит потоку {}", kind_name(s.kind)));
        }
        if t.fragment && s.ids.len() != s.objects.len() {
            return Err(format!("фрагмент: ids потока {} не по числу объектов", kind_name(s.kind)));
        }
        if !t.fragment && !s.ids.is_empty() {
            return Err("ids только во фрагментах".into());
        }
        out.push(pb::Stream {
            kind: s.kind as i32,
            count: s.objects.len() as u32,
            data: encode_objects(&s.objects),
            ids: encode_ids(&s.ids),
        });
    }
    Ok(pb::OsmTile {
        format_version: FORMAT_VERSION,
        j: t.j,
        i: t.i,
        n: t.n,
        osm_timestamp: t.osm_timestamp,
        sources: t.sources.clone(),
        streams: out,
    })
}

pub fn tile_from_pb(p: &pb::OsmTile, fragment: bool) -> Result<Tile> {
    if p.format_version != FORMAT_VERSION {
        return Err(format!("format_version {} не поддерживается", p.format_version));
    }
    let mut streams = Vec::new();
    for s in &p.streams {
        let Ok(kind) = Kind::try_from(s.kind) else { continue }; // неизвестный kind — пропуск
        if kind == Kind::Unspecified {
            continue;
        }
        let objects = decode_objects(kind, s.count as usize, &s.data)?;
        let ids = if fragment { decode_ids(s.count as usize, &s.ids)? } else { vec![] };
        streams.push(StreamData { kind, objects, ids });
    }
    Ok(Tile { fragment, j: p.j, i: p.i, n: p.n, osm_timestamp: p.osm_timestamp, sources: p.sources.clone(), streams })
}

/// Тайл → файл O2. Уровень zstd: 19 (итог) или 3 (фрагмент), если не задан.
pub fn encode_tile(t: &Tile, level: Option<i32>) -> Result<Vec<u8>> {
    let raw = tile_to_pb(t)?.encode_to_vec();
    if raw.len() as u64 > MAX_RAW_LEN as u64 {
        return Err("protobuf длиннее 64 МиБ".into());
    }
    let level = level.unwrap_or(if t.fragment { LEVEL_FRAGMENT } else { LEVEL_FINAL });
    let mut c = zstd::bulk::Compressor::new(level).map_err(|e| e.to_string())?;
    c.set_parameter(zstd::zstd_safe::CParameter::ChecksumFlag(true)).map_err(|e| e.to_string())?;
    c.set_parameter(zstd::zstd_safe::CParameter::NbWorkers(0)).map_err(|e| e.to_string())?;
    let frame = c.compress(&raw).map_err(|e| e.to_string())?;
    let mut out = Vec::with_capacity(16 + frame.len());
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&CONTAINER_VERSION.to_le_bytes());
    out.extend_from_slice(&(t.fragment as u16).to_le_bytes());
    out.extend_from_slice(&(raw.len() as u32).to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(&frame);
    Ok(out)
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Header {
    pub version: u16,
    pub flags: u16,
    pub raw_len: u32,
}

/// Проверка заголовка O2 и распаковка: (заголовок, protobuf).
pub fn open_container(file: &[u8]) -> Result<(Header, Vec<u8>)> {
    if file.len() < 16 {
        return Err("файл короче заголовка".into());
    }
    if &file[0..4] != MAGIC {
        return Err("нет магии DPOT".into());
    }
    let version = u16::from_le_bytes([file[4], file[5]]);
    let flags = u16::from_le_bytes([file[6], file[7]]);
    let raw_len = u32::from_le_bytes(file[8..12].try_into().unwrap());
    let reserved = u32::from_le_bytes(file[12..16].try_into().unwrap());
    if version != CONTAINER_VERSION {
        return Err(format!("версия контейнера {version} не поддерживается"));
    }
    if flags & !1 != 0 || reserved != 0 {
        return Err("неизвестные флаги или резерв ≠ 0".into());
    }
    if raw_len > MAX_RAW_LEN {
        return Err("raw_len > 64 МиБ".into());
    }
    let raw = zstd::bulk::decompress(&file[16..], raw_len as usize).map_err(|e| format!("zstd: {e}"))?;
    if raw.len() != raw_len as usize {
        return Err("длина после распаковки ≠ raw_len".into());
    }
    Ok((Header { version, flags, raw_len }, raw))
}

pub fn decode_tile(file: &[u8]) -> Result<Tile> {
    let (h, raw) = open_container(file)?;
    let p = pb::OsmTile::decode(raw.as_slice()).map_err(|e| format!("protobuf: {e}"))?;
    tile_from_pb(&p, h.flags & 1 != 0)
}

// ---------------------------------------------------------------- помощники упаковщика

/// Порядок Мортона домов (O3.BUILDINGS): `min(max(x,0)>>6, 1023)`, x — чётные биты.
pub fn morton(x: i64, y: i64) -> u32 {
    let cx = ((x.max(0) >> 6).min(1023)) as u32;
    let cy = ((y.max(0) >> 6).min(1023)) as u32;
    let mut m = 0u32;
    for b in 0..10 {
        m |= ((cx >> b) & 1) << (2 * b);
        m |= ((cy >> b) & 1) << (2 * b + 1);
    }
    m
}

/// Длина ломаной, м.
pub fn line_len_m(pts: &[Pt]) -> f64 {
    pts.windows(2)
        .map(|w| {
            let dx = (w[1].0 - w[0].0) as f64;
            let dy = (w[1].1 - w[0].1) as f64;
            (dx * dx + dy * dy).sqrt()
        })
        .sum()
}

// ---------------------------------------------------------------- JSON (dump)

fn pts_json(p: &[Pt]) -> Value {
    Value::Array(p.iter().map(|&(x, y)| json!([x, y])).collect())
}

pub fn objects_json(o: &Objects) -> Value {
    match o {
        Objects::Roads(v) => Value::Array(
            v.iter()
                .map(|r| {
                    json!({"cls": r.cls, "width_dm": r.width_dm, "lanes": r.lanes,
                           "tunnel": r.tunnel, "bridge": r.bridge, "pts": pts_json(&r.pts)})
                })
                .collect(),
        ),
        Objects::Buildings(v) => Value::Array(
            v.iter()
                .map(|b| {
                    json!({"x": b.x, "y": b.y, "w2": b.w2, "l2": b.l2, "angle": b.angle,
                           "hq": b.hq, "lv": b.lv, "type": b.typ})
                })
                .collect(),
        ),
        Objects::Generic(v) => Value::Array(
            v.iter().map(|o| json!({"cls": o.cls, "flags": o.flags, "h": o.h, "pts": pts_json(&o.pts)})).collect(),
        ),
        Objects::Names(v) => json!(v),
    }
}

pub fn tile_json(t: &Tile, h: &Header) -> Value {
    let streams: Vec<Value> = t
        .streams
        .iter()
        .map(|s| {
            json!({"kind": kind_name(s.kind), "count": s.objects.len(),
                   "objects": objects_json(&s.objects), "ids": s.ids})
        })
        .collect();
    json!({
        "header": {"magic": "DPOT", "version": h.version, "flags": h.flags, "raw_len": h.raw_len},
        "format_version": FORMAT_VERSION, "j": t.j, "i": t.i, "n": t.n,
        "osm_timestamp": t.osm_timestamp, "sources": t.sources, "streams": streams,
    })
}

/// Файл O2 → канонический JSON (ключи по алфавиту, потоки по возрастанию kind).
pub fn dump_json(file: &[u8]) -> Result<Value> {
    let (h, raw) = open_container(file)?;
    let p = pb::OsmTile::decode(raw.as_slice()).map_err(|e| format!("protobuf: {e}"))?;
    let t = tile_from_pb(&p, h.flags & 1 != 0)?;
    Ok(tile_json(&t, &h))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn varint_zz() {
        for v in [0i64, 1, -1, 63, -64, 1 << 40, -(1 << 40), i64::MAX, i64::MIN] {
            assert_eq!(unzz(zz(v)), v);
        }
        let mut b = vec![];
        put_varint(&mut b, 300);
        assert_eq!(b, [0xac, 0x02]);
    }

    #[test]
    fn morton_order() {
        assert_eq!(morton(0, 0), 0);
        assert_eq!(morton(64, 0), 1);
        assert_eq!(morton(0, 64), 2);
        assert_eq!(morton(128, 0), 4);
        assert_eq!(morton(-5, 1_000_000), morton(0, 1023 << 6));
    }

    #[test]
    fn corrupt_rejected() {
        assert!(decode_tile(b"nope").is_err());
        let t = crate::sample::sample_tile(false);
        let mut f = encode_tile(&t, None).unwrap();
        let n = f.len();
        f[n - 1] ^= 0xff; // контрольная сумма кадра
        assert!(decode_tile(&f).is_err());
    }
}
