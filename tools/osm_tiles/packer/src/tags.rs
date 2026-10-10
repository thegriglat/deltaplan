//! Отбор объектов по тегам и классы (O3): дороги, дома, потоки для пилота.
//! Приоритеты — как эталон `build_tiles20.py` / `build_pilot20.py`.

use crate::pb::Kind;

/// Набор тегов объекта (маленький, поиск перебором).
pub struct Tags<'a>(pub Vec<(&'a str, &'a str)>);

impl<'a> Tags<'a> {
    #[inline]
    pub fn get(&self, k: &str) -> Option<&'a str> {
        self.0.iter().find(|t| t.0 == k).map(|t| t.1)
    }
    #[inline]
    pub fn is(&self, k: &str, v: &str) -> bool {
        self.get(k) == Some(v)
    }
}

/// `num(s)` O3: первое слово, `,` → `.`, без хвоста `m`; не число (или не конечное) → `None`.
pub fn num(s: Option<&str>) -> Option<f64> {
    let s = s?;
    let w = s.split_whitespace().next()?;
    let w = w.replace(',', ".");
    let w = w.trim_end_matches('m');
    let w = w.replace('_', "");
    let v: f64 = w.parse().ok()?;
    if v.is_finite() {
        Some(v)
    } else {
        None
    }
}

/// «Истинное» число (как `if x:` в эталоне): есть и не 0.
#[inline]
fn truthy(v: Option<f64>) -> Option<f64> {
    v.filter(|x| *x != 0.0)
}

const ROAD_CLASSES: [&str; 14] = [
    "motorway", "trunk", "primary", "secondary", "tertiary", "motorway_link", "trunk_link", "primary_link",
    "secondary_link", "tertiary_link", "unclassified", "residential", "living_street", "road",
];

const BLD_TYPES: [&str; 26] = [
    "yes", "house", "apartments", "residential", "commercial", "industrial", "retail", "garage", "garages", "shed",
    "detached", "terrace", "church", "school", "roof", "office", "hotel", "warehouse", "farm", "barn", "hut",
    "cabin", "service", "public", "civic", "construction",
];

const AERIALWAY: [&str; 12] = [
    "cable_car", "gondola", "chair_lift", "mixed_lift", "drag_lift", "t-bar", "j-bar", "platter", "rope_tow",
    "magic_carpet", "zip_line", "goods",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct RoadAttr {
    pub kind: Kind,
    pub cls: u32,
    pub width_dm: Option<u32>,
    pub lanes: Option<u32>,
    pub tunnel: bool,
    pub bridge: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct LineAttr {
    pub kind: Kind,
    pub cls: u32,
    pub flags: u8,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct BldAttr {
    pub typ: u32,
    pub hq: u32,
    pub lv: bool,
}

/// Что берётся из пути (или отношения-мультиполигона: только `bld` и `aero_area`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct Feat {
    pub road: Option<RoadAttr>,
    pub line: Option<LineAttr>,
    pub bld: Option<BldAttr>,
    /// Класс кольца aeroway (4, 5, 6).
    pub aero_area: Option<u32>,
}

impl Feat {
    pub fn any(&self) -> bool {
        self.road.is_some() || self.line.is_some() || self.bld.is_some() || self.aero_area.is_some()
    }
}

fn tunnel_bridge(t: &Tags) -> (bool, bool) {
    let tunnel = matches!(t.get("tunnel"), Some("yes" | "building_passage" | "culvert"));
    let bridge = matches!(t.get("bridge"), Some(v) if v != "no");
    (tunnel, bridge)
}

pub fn road(t: &Tags) -> Option<RoadAttr> {
    let h = t.get("highway")?;
    let (kind, cls) = if h == "track" {
        let c = match t.get("tracktype") {
            Some("grade1") => 1,
            Some("grade2") => 2,
            Some("grade3") => 3,
            Some("grade4") => 4,
            Some("grade5") => 5,
            _ => 0,
        };
        (Kind::Track, c)
    } else {
        (Kind::Roads, ROAD_CLASSES.iter().position(|c| *c == h)? as u32)
    };
    let w = truthy(num(t.get("width")));
    let lanes = truthy(num(t.get("lanes")));
    let (tunnel, bridge) = tunnel_bridge(t);
    Some(RoadAttr {
        kind,
        cls,
        width_dm: w.map(|w| crate::geom::rint(w * 10.0).max(0) as u32),
        lanes: lanes.map(|l| (l.trunc().max(0.0)) as u32),
        tunnel,
        bridge,
    })
}

/// Линейный поток для пилота (приоритет эталона: ЛЭП → канатка → ВПП → река/канал → ж/д).
pub fn pilot_line(t: &Tags) -> Option<LineAttr> {
    if let Some(p @ ("line" | "minor_line")) = t.get("power") {
        let m = (p == "minor_line") as u32;
        return Some(LineAttr { kind: Kind::Powerline, cls: m, flags: m as u8 });
    }
    if let Some(a) = t.get("aerialway") {
        if a != "pylon" && a != "station" {
            let cls = AERIALWAY.iter().position(|c| *c == a).unwrap_or(12) as u32;
            return Some(LineAttr { kind: Kind::Aerialway, cls, flags: 0 });
        }
    }
    if t.is("aeroway", "runway") {
        return Some(LineAttr { kind: Kind::Aeroway, cls: 3, flags: 0 });
    }
    if let Some(w @ ("river" | "canal")) = t.get("waterway") {
        let named = t.get("name").map_or(false, |n| !n.is_empty()) as u8;
        let kind = if w == "river" { Kind::River } else { Kind::Canal };
        return Some(LineAttr { kind, cls: 0, flags: named });
    }
    if let Some(r @ ("rail" | "narrow_gauge")) = t.get("railway") {
        let (tunnel, bridge) = tunnel_bridge(t);
        let flags = ((tunnel as u8) << 3) | ((bridge as u8) << 4);
        return Some(LineAttr { kind: Kind::Rail, cls: (r == "narrow_gauge") as u32, flags });
    }
    None
}

pub fn building(t: &Tags) -> Option<BldAttr> {
    let b = t.get("building")?;
    if b == "no" {
        return None;
    }
    let typ = BLD_TYPES.iter().position(|c| *c == b).unwrap_or(26) as u32;
    let h = truthy(num(t.get("height")));
    let lev = truthy(num(t.get("building:levels")));
    let v = h.or(lev.map(|l| l * 3.0)).unwrap_or(0.0);
    let hq = crate::geom::rint(v * 2.0).max(0) as u32;
    Some(BldAttr { typ, hq, lv: h.is_none() && lev.is_some() })
}

pub fn aero_area(t: &Tags) -> Option<u32> {
    match t.get("aeroway")? {
        "aerodrome" => Some(4),
        "airstrip" => Some(5),
        "helipad" => Some(6),
        _ => None,
    }
}

/// Признаки пути. `closed` — замкнутый путь из ≥ 4 узлов (площадь, как у osmium).
pub fn way_feat(t: &Tags, closed: bool) -> Feat {
    let area_ok = closed && !t.is("area", "no");
    Feat {
        road: road(t),
        line: pilot_line(t),
        bld: if area_ok { building(t) } else { None },
        aero_area: if area_ok { aero_area(t) } else { None },
    }
}

/// Признаки отношения: только `type=multipolygon`.
pub fn rel_feat(t: &Tags) -> Feat {
    if !t.is("type", "multipolygon") {
        return Feat::default();
    }
    Feat { road: None, line: None, bld: building(t), aero_area: aero_area(t) }
}

/// Точечный объект узла: (поток, класс, флаги, h, имя). Приоритет эталона.
pub fn node_point(t: &Tags) -> Option<(Kind, u32, u8, u32, Option<String>)> {
    let hpos = |v: Option<f64>| crate::geom::rint(v.unwrap_or(0.0)).max(0) as u32;
    let comm = t.is("tower:type", "communication") as u8;
    if t.is("power", "tower") {
        return Some((Kind::PowerTower, 0, 0, 0, None));
    }
    if t.is("power", "generator") && t.is("generator:source", "wind") {
        return Some((Kind::Vertical, 3, comm, hpos(num(t.get("height"))), None));
    }
    let name = t.get("name").filter(|n| !n.is_empty()).map(str::to_string);
    if t.is("natural", "peak") {
        return Some((Kind::Peak, 0, name.is_some() as u8, hpos(num(t.get("ele"))), name));
    }
    let saddle = t.is("natural", "saddle");
    if saddle || t.is("mountain_pass", "yes") {
        return Some((Kind::Pass, (!saddle) as u32, name.is_some() as u8, hpos(num(t.get("ele"))), name));
    }
    if let Some(m @ ("mast" | "tower" | "chimney")) = t.get("man_made") {
        let cls = match m {
            "mast" => 0,
            "tower" => 1,
            _ => 2,
        };
        return Some((Kind::Vertical, cls, comm, hpos(num(t.get("height"))), None));
    }
    match t.get("aeroway") {
        Some("aerodrome") => Some((Kind::Aeroway, 0, 0, 0, None)),
        Some("airstrip") => Some((Kind::Aeroway, 1, 0, 0, None)),
        Some("helipad") => Some((Kind::Aeroway, 2, 0, 0, None)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nums() {
        assert_eq!(num(Some("12,5 m")), Some(12.5));
        assert_eq!(num(Some("7m")), Some(7.0));
        assert_eq!(num(Some("abc")), None);
        assert_eq!(num(Some("")), None);
        assert_eq!(num(Some("nan")), None);
    }

    #[test]
    fn classes() {
        let t = Tags(vec![("highway", "track"), ("tracktype", "grade3"), ("width", "2.55")]);
        let r = road(&t).unwrap();
        assert_eq!((r.kind, r.cls, r.width_dm), (Kind::Track, 3, Some(26)));
        assert!(road(&Tags(vec![("highway", "service")])).is_none());
        let b = building(&Tags(vec![("building", "barn"), ("building:levels", "2")])).unwrap();
        assert_eq!((b.typ, b.hq, b.lv), (19, 12, true));
        assert!(building(&Tags(vec![("building", "no")])).is_none());
        let p = node_point(&Tags(vec![("natural", "peak"), ("ele", "-3"), ("name", "X")])).unwrap();
        assert_eq!((p.0, p.2, p.3), (Kind::Peak, 1, 0));
        let p = node_point(&Tags(vec![("power", "tower"), ("natural", "peak")])).unwrap();
        assert_eq!(p.0, Kind::PowerTower);
        let l = pilot_line(&Tags(vec![("railway", "rail"), ("waterway", "river")])).unwrap();
        assert_eq!(l.kind, Kind::River);
    }
}
