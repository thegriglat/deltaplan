//! O4: склейка фрагментов (`finalize::merge_tile`) и порядок O3 (`tilebuild`).

use osmtiles::codec::{decode_tile, encode_tile, Building, Obj, Objects, Road};
use osmtiles::finalize::merge_tile;
use osmtiles::pb::Kind;
use osmtiles::tilebuild::{build_tile, Data, Item};

fn road(key: i64, part: u32, pts: Vec<(i64, i64)>) -> Item {
    Item { kind: Kind::Roads, key, part, data: Data::Road(Road { cls: 2, pts, ..Default::default() }), name: None }
}

fn peak(id: i64, name: &str) -> Item {
    let o = Obj { cls: 0, flags: (!name.is_empty()) as u8, h: 1000, pts: vec![(id, id)] };
    Item { kind: Kind::Peak, key: id * 4, part: 0, data: Data::Gen(o), name: (!name.is_empty()).then(|| name.to_string()) }
}

fn frag(region: &str, items: Vec<Item>) -> (String, Vec<u8>) {
    let t = build_tile(255, 750, items, true, 100, vec![region.into()]);
    (region.to_string(), encode_tile(&t, None).unwrap())
}

#[test]
fn merge_dedup_and_order() {
    // путь 7 (ключ 29): в «a» обрезан (3 точки), в «b» полный (4) — берётся «b»;
    // путь 5 (ключ 21): поровну точек — берётся «a» (раньше по алфавиту)
    let a = frag("a", vec![
        road(29, 0, vec![(0, 0), (1, 1), (2, 2)]),
        road(21, 0, vec![(5, 5), (6, 6)]),
        peak(3, "Триглав"),
    ]);
    let b = frag("b", vec![
        road(29, 0, vec![(0, 0), (1, 1), (2, 2), (3, 3)]),
        road(21, 0, vec![(9, 9), (8, 8)]),
        peak(2, ""),
        peak(4, "Стол"),
    ]);
    let (data, n) = merge_tile(255, 750, &[b.clone(), a.clone()]).unwrap().unwrap();
    assert_eq!(n, 5);
    let t = decode_tile(&data).unwrap();
    assert!(!t.fragment);
    assert_eq!(t.sources, vec!["a", "b"]);
    assert_eq!(t.osm_timestamp, 100);
    let Objects::Roads(r) = &t.stream(Kind::Roads).unwrap().objects else { panic!() };
    assert_eq!(r.len(), 2);
    assert_eq!(r[0].pts, vec![(5, 5), (6, 6)]); // путь 5 раньше пути 7, из «a»
    assert_eq!(r[1].pts.len(), 4);
    let Objects::Names(nm) = &t.stream(Kind::Names).unwrap().objects else { panic!() };
    assert_eq!(nm, &vec!["Триглав".to_string(), "Стол".to_string()]);
    assert!(t.streams.iter().all(|s| s.ids.is_empty()));
    // порядок входа не важен — побайтно то же
    let (d2, _) = merge_tile(255, 750, &[a, b]).unwrap().unwrap();
    assert_eq!(data, d2);
}

#[test]
fn buildings_morton_then_id() {
    let mk = |key: i64, x: i64, y: i64| Item {
        kind: Kind::Buildings,
        key,
        part: 0,
        data: Data::Bld(Building { x, y, w2: 10, l2: 20, ..Default::default() }),
        name: None,
    };
    let t = build_tile(255, 750, vec![mk(4 * 9 + 1, 200, 0), mk(4 * 8 + 1, 10, 10), mk(4 * 7 + 2, 20, 20)], false, 0, vec![]);
    let Objects::Buildings(b) = &t.stream(Kind::Buildings).unwrap().objects else { panic!() };
    assert_eq!(b.iter().map(|b| b.x).collect::<Vec<_>>(), vec![20, 10, 200]);
}

#[test]
fn empty_merge() {
    assert!(merge_tile(1, 1, &[]).unwrap().is_none());
}
