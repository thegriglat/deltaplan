---
type: "contract"
status: "active"
module: "thermal-bubble"
area: "air"
updated: "2026-11-09"
summary: "Стыки thermal-bubble: шаблон пузыря bubble.py (TB1), нынешний профиль для сверки (TB2), сводки сверки и цены опроса (TB3)."
related: ["docs/plan/thermal-bubble.md", "docs/guide/air-model/thermals.md"]
contracts: [{"id": "TB1", "version": 2}, {"id": "TB2", "version": 1}, {"id": "TB3", "version": 1}]
---
# Контракты модуля thermal-bubble

Владелец всех стыков — координатор модуля; меняет только он (версия +1, потребителям — `task note`).
Контрактный тест (numpy + stdlib, системный `python3`):
- `python3 tools/research/thermal_bubble/contract/check_contract.py tb1` — API и инварианты шаблона (TB1);
- `python3 tools/research/thermal_bubble/contract/check_contract.py tb2` — порт нынешнего профиля (TB2);
- `python3 tools/research/thermal_bubble/contract/check_contract.py <файл.json>` — сводки TB3 по полю `format`.

Общее: СИ (м, с, м/с); прототип — правая система **x на восток, y на север, z вверх**, земля — плоскость z = 0
(в игре ось y вверх; перевод осей — забота стенда TB-3). Поле термика — Буссинеск,
несжимаемое: ∇·v = 0 (поле игры — то же приближение у слоя термиков).

## TB1 v2 — шаблон пузыря `tools/research/thermal_bubble/bubble.py`
Владелец — TB-1; потребители — TB-2 (сверка, разрезы), TB-3 (порт в Rust, цена), TB-4 (вывод). Только numpy.

```python
PARAMS: dict[str, dict]      # числа из литературы; у каждого: value: float, unit: str,
                             # source: str (автор, год, где — непусто), reliability: "high"|"medium"|"low"
                             # обязательные ключи: "alpha_thermal" (dR/dz головы), "C_thermal"
                             # (коэффициент скорости подъёма головы), "alpha_plume" (вовлечение шлейфа)

@dataclass(frozen=True)
class Env:
    wind: tuple[float, float] = (0.0, 0.0)  # ветер поля, м/с, v1 — постоянный по высоте
    zi: float = 1400.0                      # верх слоя перемешивания (крышка), м
    g_theta: float = 9.81 / 300.0           # g/θ0, м/(с²·К)

@dataclass(frozen=True)
class Source:
    x: float; y: float   # точка источника на земле, м
    t0: float            # начало выпуска, с
    F0: float            # поток плавучести источника, пока он включён, м⁴/с³
    tau: float           # сколько источник включён, с; после t0 + tau голова отрывается (B = F0·tau)

@dataclass(frozen=True)
class State:
    xs: float; ys: float               # низ шлейфа, м; v2: = xc, yc (ось вертикальна, сносится вместе с головой)
    xc: float; yc: float; zc: float    # центр головы, м
    R: float                           # радиус головы, м, > 0
    U: float                           # скорость подъёма центра dzc/dt, м/с, ≥ 0
    Q: float                           # объёмный поток шлейфа в голову, м³/с; 0 — шлейфа нет
    F0: float                          # поток плавучести шлейфа, м⁴/с³; 0 — шлейфа нет
    zb: float                          # низ шлейфа, м (0, пока источник включён; после отрыва растёт)
    # лишние поля допустимы только с умолчаниями (State(...) с полями выше должен строиться)

def state(src: Source, env: Env, t: float) -> State | None
def velocity(p: np.ndarray, states: Sequence[State], env: Env, *,
             ground: bool = True, lid: bool = True) -> np.ndarray
def from_game(x: float, y: float, t0: float, wstar: float, zl: float, env: Env) -> Source
```

Поведение:
- `state`: `None` при t < t0 и после того, как пузыря нет (правило конца — у крышки/распад — TB-1, в README).
  Голова и шлейф сносятся ветром целиком: `xc = src.x + wind[0]·(t − t0)`, `yc = src.y + wind[1]·(t − t0)`;
  v2: весь пузырь (голова и шлейф) — осесимметричная структура с **вертикальной** осью в системе воздуха, сносится
  ветром целиком: `xs = xc`, `ys = yc` (наклонная ось v1 давала ложное горизонтальное возмущение вдоль оси —
  ревью TB-1, 2026-11-09). Низ шлейфа уходит от точки источника по ветру — граница модели. `zc` растёт с t
  до остановки у крышки, `R > 0`.
- v2: во времени поле непрерывно — без скачков при отрыве, касании крышки и конце (state → None, когда
  возмущение уже погасло).
- `velocity`: `p` формы (..., 3) = [x, y, z]; результат той же формы, float64 — **возмущение** в системе земли от
  всех пузырей (голова + шлейф + отражения), **без** ветра поля: полное поле = ветер поля + `velocity`.
  Точки z < 0 (и z > zi при `lid=True`) → 0. Линейно по `states`: сумма по пузырям.
  `ground=True` — отражение под плоскостью z = 0; `lid=True` — отражение над крышкой z = zi.
- Шлюз «не усложнять»: только аналитика (функция тока Стокса, отражения), без сеток и решателей.
- `from_game`: из входа игры (w*, толщина слоя z_l) — F0 и tau с обоснованием в README (например
  F0 = (w*³/z_l) · площадь водосбора одного ядра, Аллен n_A ≈ 8,5/z_l²; tau — жизнь термика игры).

Инварианты (контрактный тест `tb1`, Env(wind=(3, 0), zi=1400), Source = from_game(0, 0, 0, 2,5, 1400, env)):
1. PARAMS — обязательные ключи и поля.
2. `state` — None до t0; на 3 моментах в (t0, t0 + tau] — не None, R > 0, U ≥ 0, zc растёт, снос по ветру ≤ 1e-6 м;
   v2: xs = xc, ys = yc.
3. Линейность: velocity(p, [a, b]) = velocity(p, [a]) + velocity(p, [b]) (отн. 1e-9).
4. z < 0 → 0; |w(z = 0)| ≤ 1e-3·max|w| при ground; |w(z = zi)| ≤ 1e-3·max|w| при lid.
5. Масса: поток через замкнутую поверхность коробки (земля…крышка, ±4R вокруг источника и головы)
   |∮v·n dA| ≤ 1e-3·∮|v·n| dA (Гаусс–Лежандр 48×48 на грань).
6. Дивергенция в точке (центральные разности, h = 1e-4·R) на 4000 случайных точках коробки: p99 |∇·v|·R/U ≤ 1e-3.
7. Голова без шлейфа (State с Q = F0 = 0, zb = zc) на 20R по горизонтали от центра: |v| ≤ 1e-2·U.
8. v2, непрерывность во времени: шаг 2 с от t0 + 2 до конца жизни, точки — сетка разреза через ось (x, z) с
   шагом 0,25 R_max, движущаяся с ветром: max|v(t + 2) − v(t)| ≤ 0,25·max_t max|v|.
9. v2, конец жизни: состояние на последнем шаге 2 с перед `None` — max|v| ≤ 0,05·max_t max|v|; конец наступает
   (state → None) не позже t0 + 4·tau + 3600 с.

## TB2 v1 — нынешний профиль `tools/research/thermal_bubble/current.py`
Владелец — TB-2; потребители — TB-2, TB-4. Порт `rust/dp-air/src/terms/thermal/profile.rs::contribution`
(только w; без облачного подсоса и оторвавшегося низа — `suck = [0, 0]`, `ph.cut_h = −∞`, `ph.env = 1`):

```python
def current_w(p: np.ndarray, *, src=(x, y), top: float, R: float, w0: float, lean=(0.0, 0.0),
              drift=(0.0, 0.0), ring: float = -1.0, cfg: dict | None = None) -> np.ndarray   # (...,3) → (...)
```
- `dh = z − 0`, ось: `src + drift + lean·dh`; ξ = min(dh/top, 1); r = R·max(radius_min_factor,
  ξ^⅓(1 − 0,25ξ)/0,75); x² = d²/r²; отсечка x² > profile_cutoff_radii²; vert = min(1, (dh/ground_ramp_m)^⅓),
  у верха `top_taper_m` — smoothstep; g = (1 − x²)e^(−x²), при g < 0 — ×ring (ring < 0 → ring_sink_factor).
- Числа cfg — по умолчанию из `rust/dp-air/src/terms/thermal/cfg.rs` (`ThermalCfg::default`), имена ключей те же.
- Контрактный тест `tb2`: w на оси при ξ = 0,5 равна w0·vert; при x = 1 — 0; dh ≤ 0 → 0.

## TB3 v1 — сводки сверки и цены `tools/research/thermal_bubble/out/*.json`
Пишут: TB-2 (`compare.json`), TB-3 (`bench.json`); читатель — TB-4. Запись — временный файл и переименование.

`compare.json` — `{"format": "tb-compare", "version": 1, "case": {...вход: wstar, zi, wind...}, "rows": [...],
"div": {"p99_rel": float, "flux_rel": float}, "figures": [пути png]}`; строка rows:
`{"quantity": str, "unit": str, "bubble": float|null, "current": float|null, "literature": float|null,
"lit_range": [lo, hi]|null, "source": str, "note": str}`. Обязательные quantity: `w_core_max_over_wstar`,
`core_radius_over_zi`, `rise_speed_over_wstar`, `inflow_ground_over_wstar`, `outflow_top_over_wstar`,
`ring_sink_min_over_wstar`, `updraft_area_fraction`. Нет числа — null и причина в note.

`bench.json` — `{"format": "tb-bench", "version": 1, "machine": {"cpu": str}, "profile": "release",
"ns_per_point": {"current_contribution": float, "current_sample": float, "bubble_analytic": float,
"bubble_table": float|null}, "bubbles_per_point": float, "table_bytes": int|null, "port_max_rel_err": float}`
(ns на одну точку; `current_sample` — `State::sample` при той же плотности термиков; `port_max_rel_err` — порт Rust
против `bubble.velocity` на фикстуре точек).
