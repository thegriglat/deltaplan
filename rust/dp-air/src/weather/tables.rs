//! Таблицы `weather_model.json`: `lerp_table`, `interp_rows`, чтение чисел и массивов.
use serde_json::{Map, Value};

use crate::field::sun::lerp;

/// Число по пути (`def`, если нет).
pub(crate) fn num(v: &Value, path: &[&str], def: f64) -> f64 {
    crate::field::surface_heat::num(v, path, def)
}

/// Массив чисел (нечисла — 0); нет — пусто.
pub(crate) fn nums(v: Option<&Value>) -> Vec<f64> {
    match v.and_then(Value::as_array) {
        Some(a) => a.iter().map(|x| x.as_f64().unwrap_or(0.0)).collect(),
        None => Vec::new(),
    }
}

/// `SunClock._seg`: (индекс левого узла, доля) кусочно-линейной интерполяции.
fn seg(xs: &[f64], x: f64) -> (usize, f64) {
    let n = xs.len();
    if n < 2 || x <= xs[0] {
        return (0, 0.0);
    }
    for i in 0..n - 1 {
        let (a, b) = (xs[i], xs[i + 1]);
        if x <= b {
            // GD: Vector2(i, доля) хранит f32
            return (i, ((x - a) / (b - a).max(1e-6)) as f32 as f64);
        }
    }
    (n - 1, 0.0)
}

/// Кусочно-линейная интерполяция таблицы `xs -> ys` (края зажаты; `WeatherModel.lerp_table`).
pub fn lerp_table(xs: &[f64], ys: &[f64], x: f64) -> f64 {
    if ys.is_empty() {
        return 0.0;
    }
    let (s, f) = seg(xs, x);
    let i = s.min(ys.len() - 1);
    let j = (i + 1).min(ys.len() - 1);
    lerp(ys[i], ys[j], f)
}

/// Строки `[{key: x, поле: число | [числа]}]` -> поля, линейно по `x` (края зажаты;
/// `WeatherModel.interp_rows`). Нет строк — пусто.
pub fn interp_rows(rows: &[Value], key: &str, x: f64) -> Map<String, Value> {
    let n = rows.len();
    let mut out = Map::new();
    if n == 0 {
        return out;
    }
    let k = |i: usize| rows[i].get(key).and_then(Value::as_f64).unwrap_or(0.0);
    let mut i = 0;
    let mut f = 0.0;
    if x <= k(0) {
    } else if x >= k(n - 1) {
        i = n - 1;
    } else {
        while i < n - 1 && x > k(i + 1) {
            i += 1;
        }
        f = (x - k(i)) / (k(i + 1) - k(i)).max(1.0e-6);
    }
    let r0 = rows[i].as_object().cloned().unwrap_or_default();
    let r1 = rows[(i + 1).min(n - 1)]
        .as_object()
        .cloned()
        .unwrap_or_default();
    let fl = |v: &Value| v.as_f64().unwrap_or(0.0);
    for (name, v0) in &r0 {
        let v1 = r1.get(name).unwrap_or(v0);
        let val = match v0.as_array() {
            Some(a0) => Value::Array(
                a0.iter()
                    .enumerate()
                    .map(|(e, x0)| num_value(lerp(fl(x0), v1.get(e).map_or(fl(x0), fl), f)))
                    .collect(),
            ),
            None => num_value(lerp(fl(v0), fl(v1), f)),
        };
        out.insert(name.clone(), val);
    }
    out
}

/// Число json; нечисло (NaN, inf) — `null`, как в дампе GD.
pub(crate) fn num_value(x: f64) -> Value {
    serde_json::Number::from_f64(x).map_or(Value::Null, Value::Number)
}
