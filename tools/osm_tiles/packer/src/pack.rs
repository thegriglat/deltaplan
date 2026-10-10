//! `osmtiles pack` (O4, O5): выгрузка PBF региона → фрагменты тайлов.
//!
//! Проходы по PBF (блобы параллельно, `rayon`, файл отображён в память):
//! 1. `scan` — все блобы: точечные объекты узлов (с координатами), нужные пути (id, узлы, признаки),
//!    отношения-мультиполигоны домов/аэродромов; запоминается, в каких блобах есть узлы/пути.
//! 2. `members` — блобы с путями: узлы путей-членов отобранных отношений.
//! 3. `nodes` — блобы с узлами: координаты только нужных узлов (отсортированный список id → массив).
//! Затем `geometry` (объекты по тайлам, параллельно по путям/отношениям) и `encode` (по тайлам:
//! сортировка O3, кодирование, zstd 3, запись фрагмента). Свой индекс узлов вместо osmium: нужен
//! только список узлов отобранных путей, проходы параллельны, без промежуточных файлов.

use crate::codec::{encode_tile, Building, Obj, Road};
use crate::cover;
use crate::geom::{self, rint, P};
use crate::grid::{self, Band, DLAT};
use crate::pb::Kind;
use crate::runinfo::{peak_rss_mb, run_queue, Stages};
use crate::tags::{self, Feat, Tags};
use crate::tilebuild::{build_tile, Data, Item, T_NODE, T_REL, T_WAY};
use crate::Result;
use osmpbf::{BlobDecode, Mmap, MmapBlob, RelMemberType};
use rayon::prelude::*;
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

pub struct PackOpts {
    pub input: PathBuf,
    pub region: String,
    pub poly: Option<PathBuf>,
    pub frag_dir: PathBuf,
    pub report: Option<PathBuf>,
}

const B_NODES: u8 = 1;
const B_WAYS: u8 = 2;

struct PointRec {
    id: i64,
    lat: i32,
    lon: i32,
    kind: Kind,
    cls: u32,
    flags: u8,
    h: u32,
    name: Option<String>,
}

/// Пути одного блоба: id, признаки (номер в таблице блоба), узлы (плоский массив + смещения).
#[derive(Default)]
struct WayBuf {
    ids: Vec<i64>,
    fidx: Vec<u32>,
    ftab: Vec<Feat>,
    fmap: HashMap<Feat, u32>,
    offs: Vec<u32>,
    refs: Vec<i64>,
}

impl WayBuf {
    fn push(&mut self, id: i64, feat: Feat, refs: impl Iterator<Item = i64>) {
        let fi = match self.fmap.get(&feat) {
            Some(&k) => k,
            None => {
                let k = self.ftab.len() as u32;
                self.ftab.push(feat);
                self.fmap.insert(feat, k);
                k
            }
        };
        self.ids.push(id);
        self.fidx.push(fi);
        self.offs.push(self.refs.len() as u32);
        self.refs.extend(refs);
    }
    fn len(&self) -> usize {
        self.ids.len()
    }
    fn feat(&self, k: usize) -> &Feat {
        &self.ftab[self.fidx[k] as usize]
    }
    fn refs_of(&self, k: usize) -> &[i64] {
        let e = if k + 1 < self.offs.len() { self.offs[k + 1] as usize } else { self.refs.len() };
        &self.refs[self.offs[k] as usize..e]
    }
}

struct RelRec {
    id: i64,
    feat: Feat,
    ways: Vec<i64>,
}

#[derive(Default)]
struct ScanOut {
    kinds: u8,
    points: Vec<PointRec>,
    ways: WayBuf,
    rels: Vec<RelRec>,
    header_ts: Option<i64>,
}

fn decode<'a>(b: &'a MmapBlob<'a>) -> Result<BlobDecode<'a>> {
    b.decode().map_err(|e| format!("PBF: {e}"))
}

fn scan_blob(b: &MmapBlob) -> Result<ScanOut> {
    let mut o = ScanOut::default();
    let blk = match decode(b)? {
        BlobDecode::OsmData(blk) => blk,
        BlobDecode::OsmHeader(h) => {
            o.header_ts = h.osmosis_replication_timestamp();
            return Ok(o);
        }
        BlobDecode::Unknown(_) => return Ok(o),
    };
    for g in blk.groups() {
        for n in g.dense_nodes() {
            o.kinds |= B_NODES;
            let mut it = n.tags().peekable();
            if it.peek().is_none() {
                continue;
            }
            let t = Tags(it.collect());
            if let Some((kind, cls, flags, h, name)) = tags::node_point(&t) {
                o.points.push(PointRec { id: n.id(), lat: n.decimicro_lat(), lon: n.decimicro_lon(), kind, cls, flags, h, name });
            }
        }
        for n in g.nodes() {
            o.kinds |= B_NODES;
            let t = Tags(n.tags().collect());
            if t.0.is_empty() {
                continue;
            }
            if let Some((kind, cls, flags, h, name)) = tags::node_point(&t) {
                o.points.push(PointRec { id: n.id(), lat: n.decimicro_lat(), lon: n.decimicro_lon(), kind, cls, flags, h, name });
            }
        }
        for w in g.ways() {
            o.kinds |= B_WAYS;
            let t = Tags(w.tags().collect());
            if t.0.is_empty() {
                continue;
            }
            let raw = w.raw_refs();
            let closed = raw.len() >= 4 && {
                let (first, last) = (raw[0], raw.iter().sum::<i64>());
                first == last
            };
            let f = tags::way_feat(&t, closed);
            if f.any() {
                o.ways.push(w.id(), f, w.refs());
            }
        }
        for r in g.relations() {
            let t = Tags(r.tags().collect());
            let f = tags::rel_feat(&t);
            if f.any() {
                let ways = r.members().filter(|m| m.member_type == RelMemberType::Way).map(|m| m.member_id).collect();
                o.rels.push(RelRec { id: r.id(), feat: f, ways });
            }
        }
    }
    Ok(o)
}

fn members_blob(b: &MmapBlob, need: &[i64]) -> Result<WayBuf> {
    let mut o = WayBuf::default();
    if let BlobDecode::OsmData(blk) = decode(b)? {
        for g in blk.groups() {
            for w in g.ways() {
                if need.binary_search(&w.id()).is_ok() {
                    o.push(w.id(), Feat::default(), w.refs());
                }
            }
        }
    }
    Ok(o)
}

/// Указатель на начало куска объектов для раздачи по задачам (см. SAFETY в `pack`).
#[derive(Clone, Copy)]
struct SendPtr(*mut (TileKey, Item));
unsafe impl Send for SendPtr {}
unsafe impl Sync for SendPtr {}

const NO_LOC: u64 = 0x8000_0000_0000_0000;

#[inline]
fn pack_loc(lat: i32, lon: i32) -> u64 {
    ((lat as u32 as u64) << 32) | lon as u32 as u64
}

/// Поиск `id` в отсортированном `ids` начиная с `from` (галоп); возвращает (найден?, новая позиция).
#[inline]
fn gallop(ids: &[i64], from: usize, id: i64) -> (Option<usize>, usize) {
    if from >= ids.len() || ids[from] > id {
        // назад (файл не отсортирован) — обычный поиск
        return match ids.binary_search(&id) {
            Ok(k) => (Some(k), k),
            Err(k) => (None, k),
        };
    }
    let mut step = 1usize;
    let mut lo = from;
    let mut hi = from + 1;
    while hi < ids.len() && ids[hi] <= id {
        lo = hi;
        step *= 2;
        hi = from + step;
    }
    let hi = hi.min(ids.len());
    match ids[lo..hi].binary_search(&id) {
        Ok(k) => (Some(lo + k), lo + k),
        Err(k) => (None, lo + k),
    }
}

fn nodes_blob(b: &MmapBlob, ids: &[i64], locs: &[AtomicU64]) -> Result<()> {
    if let BlobDecode::OsmData(blk) = decode(b)? {
        let mut pos = 0usize;
        for g in blk.groups() {
            for n in g.dense_nodes() {
                let (k, p) = gallop(ids, pos, n.id());
                pos = p;
                if let Some(k) = k {
                    locs[k].store(pack_loc(n.decimicro_lat(), n.decimicro_lon()), Ordering::Relaxed);
                }
            }
            for n in g.nodes() {
                if let Ok(k) = ids.binary_search(&n.id()) {
                    locs[k].store(pack_loc(n.decimicro_lat(), n.decimicro_lon()), Ordering::Relaxed);
                }
            }
        }
    }
    Ok(())
}

/// Индекс координат нужных узлов.
struct NodeIndex {
    ids: Vec<i64>,
    locs: Vec<AtomicU64>,
}

impl NodeIndex {
    /// (lon, lat), градусы.
    #[inline]
    fn get(&self, id: i64) -> Option<P> {
        let k = self.ids.binary_search(&id).ok()?;
        let v = self.locs[k].load(Ordering::Relaxed);
        if v == NO_LOC {
            return None;
        }
        let lat = (v >> 32) as u32 as i32;
        let lon = v as u32 as i32;
        Some((lon as f64 / 1e7, lat as f64 / 1e7))
    }
    fn coords(&self, refs: &[i64]) -> Option<Vec<P>> {
        refs.iter().map(|&r| self.get(r)).collect()
    }
}

// ---------------------------------------------------------------- геометрия по тайлам

type TileKey = (i32, u32);

/// Счётчик частей объекта по тайлам.
#[derive(Default)]
struct Parts(Vec<(TileKey, u32)>);

impl Parts {
    fn next(&mut self, t: TileKey) -> u32 {
        if let Some(e) = self.0.iter_mut().find(|e| e.0 == t) {
            e.1 += 1;
            e.1
        } else {
            self.0.push((t, 0));
            0
        }
    }
}

struct Ctx<'a> {
    cover: Option<&'a HashSet<TileKey>>,
}

impl Ctx<'_> {
    fn ok(&self, t: TileKey) -> bool {
        self.cover.map_or(true, |c| c.contains(&t))
    }
}

/// Тайлы, задевающие прямоугольник (градусы), как `tiles_in_bbox` эталона.
fn tiles_in_bbox(x0: f64, y0: f64, x1: f64, y1: f64, out: &mut Vec<TileKey>) {
    for j in grid::band_of_lat(y0)..=grid::band_of_lat(y1) {
        let b = Band::new(j);
        let i0 = b.index_of(x0.clamp(-180.0, 180.0).min(179.999_999_999_9));
        let i1 = b.index_of(x1.clamp(-180.0, 180.0).min(179.999_999_999_9));
        let i1 = if x1 >= 180.0 { b.n - 1 } else { i1 };
        for i in i0..=i1 {
            out.push((j, i));
        }
    }
}

/// Линия (lon, lat) → части по тайлам: клип, ДП 1 м, округление, ≥ 2 точек.
fn line_parts(ll: &[P], mut emit: impl FnMut(TileKey, Vec<(i64, i64)>)) {
    // антимеридиан (O1): ребро с |Δlon| > 180° выбрасывается, линия режется
    let mut pieces: Vec<&[P]> = Vec::new();
    let mut s = 0;
    for k in 1..ll.len() {
        if (ll[k].0 - ll[k - 1].0).abs() > 180.0 {
            pieces.push(&ll[s..k]);
            s = k;
        }
    }
    pieces.push(&ll[s..]);
    for pc in pieces {
        if pc.len() < 2 {
            continue;
        }
        // отрезки → тайлы-кандидаты
        let mut cand: Vec<(TileKey, usize)> = Vec::new();
        let mut tl = Vec::new();
        for k in 0..pc.len() - 1 {
            let (a, b) = (pc[k], pc[k + 1]);
            tl.clear();
            tiles_in_bbox(a.0.min(b.0), a.1.min(b.1), a.0.max(b.0), a.1.max(b.1), &mut tl);
            cand.extend(tl.iter().map(|t| (*t, k)));
        }
        cand.sort_unstable();
        let mut g = 0;
        while g < cand.len() {
            let t = cand[g].0;
            let mut e = g;
            while e < cand.len() && cand[e].0 == t {
                e += 1;
            }
            let b = Band::new(t.0);
            let lon0 = b.lon0(t.1);
            let (w, h) = (b.dlon * b.kx, DLAT * b.ky);
            let proj = |p: P| ((p.0 - lon0) * b.kx, (p.1 - b.lat0) * b.ky);
            // серии подряд идущих отрезков
            let mut k = g;
            while k < e {
                let s0 = cand[k].1;
                let mut s1 = s0;
                while k + 1 < e && cand[k + 1].1 == s1 + 1 {
                    k += 1;
                    s1 += 1;
                }
                k += 1;
                let loc: Vec<P> = pc[s0..=s1 + 1].iter().map(|&p| proj(p)).collect();
                for part in geom::clip_line(&loc, 0.0, 0.0, w, h) {
                    let r = geom::round_dedup(&geom::simplify(&part, 1.0));
                    if r.len() >= 2 {
                        emit(t, r);
                    }
                }
            }
            g = e;
        }
    }
}

fn local_ring(r: &[P], t: TileKey) -> Vec<P> {
    let b = Band::new(t.0);
    let lon0 = b.lon0(t.1);
    r.iter().map(|p| ((p.0 - lon0) * b.kx, (p.1 - b.lat0) * b.ky)).collect()
}

/// Полигон (кольца в градусах, без повтора первой точки) → дом и/или кольцо aeroway.
fn polygon_items(outer: &[P], holes: &[Vec<P>], key: i64, f: &Feat, parts: &mut Parts, ctx: &Ctx, out: &mut Vec<(TileKey, Item)>) {
    if outer.len() < 3 {
        return;
    }
    let (_, c) = geom::polygon_centroid(outer, holes);
    let t = grid::tile_of(c.1, c.0);
    if !ctx.ok(t) {
        return;
    }
    let lo = local_ring(outer, t);
    if let Some(ba) = f.bld {
        let lh: Vec<Vec<P>> = holes.iter().map(|h| local_ring(h, t)).collect();
        let area = geom::ring_area(&lo).abs() - lh.iter().map(|h| geom::ring_area(h).abs()).sum::<f64>();
        if area >= 50.0 {
            if let Some((ctr, short, long, ang)) = geom::min_area_rect(&lo) {
                let b = Building {
                    x: rint(ctr.0),
                    y: rint(ctr.1),
                    w2: rint(short * 2.0).max(0) as u32,
                    l2: rint(long * 2.0).max(0) as u32,
                    angle: (rint(ang).rem_euclid(180)) as u32,
                    hq: ba.hq,
                    lv: ba.lv,
                    typ: ba.typ,
                };
                let part = parts.next((t.0, t.1 | 0x8000_0000));
                out.push((t, Item { kind: Kind::Buildings, key, part, data: Data::Bld(b), name: None }));
            }
        }
    }
    if let Some(cls) = f.aero_area {
        let mut ring = lo.clone();
        ring.push(lo[0]);
        let mut r = geom::round_dedup(&geom::simplify(&ring, 1.0));
        if r.len() > 1 && r.first() == r.last() {
            r.pop();
        }
        if r.len() >= 3 {
            let part = parts.next(t);
            out.push((t, Item { kind: Kind::Aeroway, key, part, data: Data::Gen(Obj { cls, flags: 0, h: 0, pts: r }), name: None }));
        }
    }
}

fn way_items(id: i64, f: &Feat, ll: &[P], ctx: &Ctx, out: &mut Vec<(TileKey, Item)>) {
    let key = id * 4 + T_WAY;
    if let Some(ra) = f.road {
        let mut parts = Parts::default();
        line_parts(ll, |t, pts| {
            if ctx.ok(t) {
                let part = parts.next(t);
                let r = Road { cls: ra.cls, width_dm: ra.width_dm, lanes: ra.lanes, tunnel: ra.tunnel, bridge: ra.bridge, pts };
                out.push((t, Item { kind: ra.kind, key, part, data: Data::Road(r), name: None }));
            }
        });
    }
    let mut parts = Parts::default();
    if let Some(la) = f.line {
        line_parts(ll, |t, pts| {
            if ctx.ok(t) {
                let part = parts.next(t);
                let o = Obj { cls: la.cls, flags: la.flags, h: 0, pts };
                out.push((t, Item { kind: la.kind, key, part, data: Data::Gen(o), name: None }));
            }
        });
    }
    if f.bld.is_some() || f.aero_area.is_some() {
        // замкнутый путь: кольцо без повтора
        let ring = &ll[..ll.len() - 1];
        polygon_items(ring, &[], key, f, &mut parts, ctx, out);
    }
}

fn point_item(p: &PointRec, ctx: &Ctx) -> Option<(TileKey, Item)> {
    let (lat, lon) = (p.lat as f64 / 1e7, p.lon as f64 / 1e7);
    let (j, i, x, y) = grid::project(lat, lon);
    if !ctx.ok((j, i)) {
        return None;
    }
    let o = Obj { cls: p.cls, flags: p.flags, h: p.h, pts: vec![(rint(x), rint(y))] };
    Some(((j, i), Item { kind: p.kind, key: p.id * 4 + T_NODE, part: 0, data: Data::Gen(o), name: p.name.clone() }))
}

// ---------------------------------------------------------------- запись

fn write_atomic(path: &Path, data: &[u8]) -> Result<()> {
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    std::fs::write(&tmp, data).map_err(|e| format!("{}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, path).map_err(|e| format!("{}: {e}", path.display()))
}

pub fn frag_path(frag_dir: &Path, j: i32, i: u32, region: &str) -> PathBuf {
    frag_dir.join(j.to_string()).join(i.to_string()).join(format!("{region}.frag"))
}

pub fn pack(o: &PackOpts) -> Result<()> {
    let mut st = Stages::new();
    let region = &o.region;
    if region.is_empty() || region.contains(['/', '\\', ' ']) {
        return Err(format!("недопустимый id региона «{region}»"));
    }
    std::fs::create_dir_all(&o.frag_dir).map_err(|e| format!("{}: {e}", o.frag_dir.display()))?;
    let pack_json = o.frag_dir.join(format!("{region}.pack.json"));
    // повторный запуск: удалить фрагменты прошлого прогона
    if let Ok(text) = std::fs::read_to_string(&pack_json) {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) {
            for t in v["tiles"].as_array().into_iter().flatten() {
                if let (Some(j), Some(i)) = (t[0].as_i64(), t[1].as_i64()) {
                    let _ = std::fs::remove_file(frag_path(&o.frag_dir, j as i32, i as u32, region));
                }
            }
        }
        let _ = std::fs::remove_file(&pack_json);
    }
    let cover_set: Option<HashSet<TileKey>> = match &o.poly {
        Some(p) => {
            let text = std::fs::read_to_string(p).map_err(|e| format!("{}: {e}", p.display()))?;
            Some(cover::cover(&cover::parse_poly(&text)?).into_iter().collect())
        }
        None => None,
    };
    let input_bytes = std::fs::metadata(&o.input).map_err(|e| format!("{}: {e}", o.input.display()))?.len();
    let mmap = unsafe { Mmap::from_path(&o.input) }.map_err(|e| format!("{}: {e}", o.input.display()))?;
    let blobs: Vec<MmapBlob> = mmap.blob_iter().collect::<std::result::Result<_, _>>().map_err(|e| format!("PBF: {e}"))?;

    // 1. scan
    st.start("scan");
    let scans: Vec<ScanOut> = blobs.par_iter().map(scan_blob).collect::<Result<_>>()?;
    let kinds: Vec<u8> = scans.iter().map(|s| s.kinds).collect();
    let osm_timestamp = scans.iter().find_map(|s| s.header_ts).unwrap_or(0);
    let mut points = Vec::new();
    let mut ways: Vec<WayBuf> = Vec::new();
    let mut rels = Vec::new();
    for s in scans {
        points.extend(s.points);
        if s.ways.len() > 0 {
            ways.push(s.ways);
        }
        rels.extend(s.rels);
    }
    eprintln!(
        "osmtiles: точек {}, путей {}, отношений {}, узлов в путях {}",
        points.len(),
        ways.iter().map(|w| w.len()).sum::<usize>(),
        rels.len(),
        ways.iter().map(|w| w.refs.len()).sum::<usize>()
    );

    // 2. members
    st.start("members");
    let mut need_w: Vec<i64> = rels.iter().flat_map(|r| r.ways.iter().copied()).collect();
    need_w.par_sort_unstable();
    need_w.dedup();
    let members: Vec<WayBuf> = if need_w.is_empty() {
        Vec::new()
    } else {
        blobs
            .par_iter()
            .enumerate()
            .filter(|(k, _)| kinds[*k] & B_WAYS != 0)
            .map(|(_, b)| members_blob(b, &need_w))
            .collect::<Result<_>>()?
    };
    let member_of: HashMap<i64, (usize, usize)> =
        members.iter().enumerate().flat_map(|(p, m)| m.ids.iter().enumerate().map(move |(k, id)| (*id, (p, k)))).collect();

    // 3. nodes
    st.start("nodes");
    let mut ids: Vec<i64> = ways.par_iter().chain(members.par_iter()).flat_map_iter(|w| w.refs.iter().copied()).collect();
    ids.par_sort_unstable();
    ids.dedup();
    ids.shrink_to_fit();
    let locs: Vec<AtomicU64> = (0..ids.len()).into_par_iter().map(|_| AtomicU64::new(NO_LOC)).collect();
    blobs
        .par_iter()
        .enumerate()
        .filter(|(k, _)| kinds[*k] & B_NODES != 0)
        .try_for_each(|(_, b)| nodes_blob(b, &ids, &locs))?;
    let idx = NodeIndex { ids, locs };
    drop(blobs);
    drop(mmap);

    // 4. geometry: объекты по тайлам кусками (по куску на задачу rayon), без общего массива
    st.start("geometry");
    let ctx = Ctx { cover: cover_set.as_ref() };
    let mut buckets: Vec<Vec<(TileKey, Item)>> = ways
        .par_iter()
        .flat_map(|w| (0..w.len()).into_par_iter().map(move |k| (w, k)))
        .fold(Vec::new, |mut out, (w, k)| {
            if let Some(ll) = idx.coords(w.refs_of(k)) {
                way_items(w.ids[k], w.feat(k), &ll, &ctx, &mut out);
            }
            out
        })
        .collect();
    let rel_buckets: Vec<Vec<(TileKey, Item)>> = rels
        .par_iter()
        .fold(Vec::new, |mut out, r| {
            let mut wl: Vec<&[i64]> = Vec::new();
            for w in &r.ways {
                match member_of.get(w) {
                    Some(&(p, k)) => wl.push(members[p].refs_of(k)),
                    None => return out, // неполное отношение — пропуск (как osmium)
                }
            }
            let Some(rings) = geom::assemble_rings(&wl) else { return out };
            let mut rc: Vec<Vec<P>> = Vec::new();
            for r in rings {
                let Some(mut c) = idx.coords(&r) else { return out };
                c.pop();
                rc.push(c);
            }
            let mut parts = Parts::default();
            for (outer, holes) in geom::rings_to_polygons(rc) {
                polygon_items(&outer, &holes, r.id * 4 + T_REL, &r.feat, &mut parts, &ctx, &mut out);
            }
            out
        })
        .collect();
    buckets.extend(rel_buckets);
    buckets.push(points.par_iter().filter_map(|p| point_item(p, &ctx)).collect());
    drop(ways);
    drop(members);
    drop(idx);
    // ссылки (тайл, кусок, номер) — сортируются вместо самих объектов
    let tk = |t: TileKey| (((t.0 + 1024) as u64) << 32) | t.1 as u64;
    let mut refs: Vec<(u64, u32, u32)> = buckets
        .par_iter()
        .enumerate()
        .flat_map_iter(|(c, v)| v.iter().enumerate().map(move |(k, x)| (tk(x.0), c as u32, k as u32)))
        .collect();
    eprintln!("osmtiles: объектов (частей) {}", refs.len());

    // 5. encode: по тайлу на задачу, тяжёлые — первыми
    st.start("encode");
    refs.par_sort_unstable_by_key(|r| r.0); // порядок внутри тайла задаёт build_tile
    let mut chunks: Vec<&[(u64, u32, u32)]> = refs.chunk_by(|a, b| a.0 == b.0).collect();
    chunks.par_sort_by_key(|c| (std::cmp::Reverse(c.len()), c[0].0));
    let base: Vec<SendPtr> = buckets.iter_mut().map(|v| SendPtr(v.as_mut_ptr())).collect();
    let mut written: Vec<(i32, u32, usize)> = run_queue(&chunks, |c| -> Result<(i32, u32, usize)> {
            let (j, i) = ((c[0].0 >> 32) as i32 - 1024, c[0].0 as u32);
            // SAFETY: каждая пара (кусок, номер) встречается в `refs` ровно один раз, поэтому задачи
            // берут разные элементы `buckets`; `buckets` не меняется и живёт дольше задач.
            let its: Vec<Item> = c
                .iter()
                .map(|&(_, b, k)| unsafe { std::mem::take(&mut (*base[b as usize].0.add(k as usize)).1) })
                .collect();
            let n = its.len();
            let tile = build_tile(j, i, its, true, osm_timestamp, vec![region.clone()]);
            let data = encode_tile(&tile, None)?;
            let p = frag_path(&o.frag_dir, j, i, region);
            std::fs::create_dir_all(p.parent().unwrap()).map_err(|e| e.to_string())?;
            write_atomic(&p, &data)?;
            Ok((j, i, n))
        })
        .into_iter()
        .collect::<Result<_>>()?;
    buckets.into_par_iter().for_each(drop);
    written.sort();
    st.finish();

    let (seconds, cores) = st.json();
    let rep = json!({
        "region": region,
        "input": o.input.display().to_string(),
        "input_bytes": input_bytes,
        "osm_timestamp": osm_timestamp,
        "tiles": written.iter().map(|(j, i, n)| json!([j, i, n])).collect::<Vec<_>>(),
        "seconds": seconds,
        "seconds_total": (st.total_s() * 1000.0).round() / 1000.0,
        "peak_rss_mb": peak_rss_mb().round(),
        "cpu_cores_avg": cores,
    });
    let text = serde_json::to_string_pretty(&rep).unwrap();
    write_atomic(&pack_json, text.as_bytes())?;
    if let Some(r) = &o.report {
        write_atomic(r, text.as_bytes())?;
    }
    eprintln!(
        "osmtiles: pack {region}: тайлов {}, объектов {}, {:.1} с, пик RSS {:.0} МБ",
        written.len(),
        written.iter().map(|t| t.2).sum::<usize>(),
        st.total_s(),
        peak_rss_mb()
    );
    Ok(())
}
