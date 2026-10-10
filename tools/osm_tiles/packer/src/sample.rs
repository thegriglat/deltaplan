//! Образец `sample_v1.dpt` (все 14 потоков, по 2–3 объекта, крайние случаи) — пишет Rust.

use crate::codec::*;
use crate::grid::Band;
use crate::pb::Kind;

fn g(kind: Kind, objs: Vec<Obj>) -> StreamData {
    StreamData { kind, objects: Objects::Generic(objs), ids: vec![] }
}

fn o(cls: u32, flags: u8, h: u32, pts: &[Pt]) -> Obj {
    Obj { cls, flags, h, pts: pts.to_vec() }
}

/// Тайл-образец (Словения, j = 252, i = 755). `fragment` — вариант-фрагмент: флаг, `ids`, zstd 3.
pub fn sample_tile(fragment: bool) -> Tile {
    let (j, i) = (252, 755);
    let roads = vec![
        Road { cls: 3, width_dm: Some(65), lanes: Some(2), tunnel: false, bridge: true,
               pts: vec![(0, 1200), (350, 1180), (700, 1250), (20000, 1300)] },
        Road { cls: 11, width_dm: None, lanes: None, tunnel: true, bridge: false,
               pts: vec![(15000, 20010), (14980, 19900), (14990, 19750)] }, // назад: отрицательные дельты
        Road { cls: 4, width_dm: None, lanes: Some(1), tunnel: false, bridge: false,
               pts: vec![(100, 100), (90, 80)] },
    ];
    let track = vec![
        Road { cls: 2, pts: vec![(5000, 5000), (5100, 4900), (5300, 5200)], ..Default::default() },
        Road { cls: 0, pts: vec![(-30, 100), (40, -50)], ..Default::default() },
    ];
    let buildings = vec![
        Building { x: 120, y: 80, w2: 16, l2: 24, angle: 0, hq: 0, lv: false, typ: 1 },
        Building { x: 4000, y: 3100, w2: 20, l2: 61, angle: 37, hq: 14, lv: false, typ: 2 },
        Building { x: 3900, y: 12000, w2: 13, l2: 30, angle: 179, hq: 12, lv: true, typ: 26 }, // x назад
    ];
    let powerline = vec![
        o(0, 0, 0, &[(0, 15000), (5000, 15200), (10000, 14800), (20100, 14900)]),
        o(1, 1, 0, &[(8000, 100), (8100, -40)]),
    ];
    let power_tower = vec![o(0, 0, 0, &[(5000, 15200)]), o(0, 0, 0, &[(10000, 14800)])];
    let aerialway = vec![
        o(2, 0, 0, &[(9000, 9000), (9500, 10200), (9900, 11400)]),
        o(1, 0, 0, &[(2000, 2000), (2100, 2600)]),
    ];
    let aeroway = vec![
        o(0, 0, 0, &[(12000, 6000)]),
        o(3, 0, 0, &[(11800, 5900), (12400, 6150)]),
        o(4, 0, 0, &[(11700, 5800), (12500, 5800), (12500, 6200), (11700, 6200)]), // кольцо аэродрома
    ];
    let vertical = vec![
        o(0, 1, 42, &[(3000, 18000)]),
        o(2, 0, 120, &[(7000, 7000)]),
        o(3, 0, 0, &[(16000, 3000)]),
    ];
    let rail = vec![
        o(0, 0, 0, &[(0, 7000), (10000, 7300), (20000, 7100)]),
        o(1, 8, 0, &[(500, 7050), (700, 7040)]),
    ];
    let peak = vec![o(0, 1, 2864, &[(10000, 10000)]), o(0, 0, 1500, &[(2000, 19000)]), o(0, 1, 1999, &[(19000, 500)])];
    let pass = vec![o(1, 1, 1611, &[(6000, 6000)]), o(0, 0, 900, &[(14000, 14000)])];
    let names = vec!["Триглав".to_string(), "Vršič".to_string(), "Перевал Мојстрана".to_string()];
    let river = vec![o(0, 1, 0, &[(0, 3000), (4000, 2800), (9000, 3300), (20000, 2900)]), o(0, 0, 0, &[(100, 100), (60, 40)])];
    let canal = vec![o(0, 1, 0, &[(14000, 0), (14100, 9000)]), o(0, 0, 0, &[(1, 1), (2, 2)])];

    let mut streams = vec![
        StreamData { kind: Kind::Roads, objects: Objects::Roads(roads), ids: vec![] },
        StreamData { kind: Kind::Track, objects: Objects::Roads(track), ids: vec![] },
        StreamData { kind: Kind::Buildings, objects: Objects::Buildings(buildings), ids: vec![] },
        g(Kind::Powerline, powerline),
        g(Kind::PowerTower, power_tower),
        g(Kind::Aerialway, aerialway),
        g(Kind::Aeroway, aeroway),
        g(Kind::Vertical, vertical),
        g(Kind::Rail, rail),
        g(Kind::Peak, peak),
        g(Kind::Pass, pass),
        StreamData { kind: Kind::Names, objects: Objects::Names(names), ids: vec![] },
        g(Kind::River, river),
        g(Kind::Canal, canal),
    ];
    if fragment {
        // ключи id*4 + тип (узел 0, путь 1, отношение 2); порядок не по возрастанию — отрицательные дельты
        for (k, s) in streams.iter_mut().enumerate() {
            s.ids = (0..s.objects.len() as i64).map(|q| 1000 * (14 - k as i64) * 4 + (q * 7 % 3) + 4 * q * 3 - 40).collect();
        }
    }
    Tile {
        fragment,
        j,
        i,
        n: Band::new(j).n,
        osm_timestamp: 1_760_000_000,
        sources: vec!["slovenia".to_string()],
        streams,
    }
}
