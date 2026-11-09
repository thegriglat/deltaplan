---
type: "contract"
status: "active"
module: "thermal-bubble"
area: "air"
updated: "2026-11-09"
summary: "Стыки thermal-bubble: шаблон пузыря bubble.py (TB1), профиль для сверки (TB2), сводки (TB3), шаблон в dp-air за флагом (TB4)."
related: ["docs/plan/thermal-bubble.md", "docs/guide/air-model/thermals.md"]
contracts: [{"id": "TB1", "version": 4}, {"id": "TB2", "version": 1}, {"id": "TB3", "version": 2}, {"id": "TB4", "version": 2}]
---
# Контракты модуля thermal-bubble

Владелец всех стыков — координатор модуля; меняет только он (версия +1, потребителям — `task note`).
Контрактный тест (numpy + stdlib, системный `python3`):
- `python3 tools/research/thermal_bubble/contract/check_contract.py tb1` — API и инварианты шаблона (TB1);
- `python3 tools/research/thermal_bubble/contract/check_contract.py tb2` — порт нынешнего профиля (TB2);
- `python3 tools/research/thermal_bubble/contract/check_contract.py <файл.json>` — сводки TB3 по полю `format`;
- `python3 tools/research/thermal_bubble/contract/check_contract.py tb4` — имена стыка TB4 в `rust/dp-air` (флаг, поле, модуль, тесты).

Общее: СИ (м, с, м/с); прототип — правая система **x на восток, y на север, z вверх**, земля — плоскость z = 0
(в игре ось y вверх; перевод осей — забота стенда TB-3). Поле термика — Буссинеск,
несжимаемое: ∇·v = 0 (поле игры — то же приближение у слоя термиков).

## TB1 v4 — шаблон пузыря `tools/research/thermal_bubble/bubble.py`
Владелец — TB-1; потребители — TB-2 (сверка, разрезы), TB-3 (порт в Rust, цена), TB-4 (вывод). Только numpy.

```python
PARAMS: dict[str, dict]      # числа из литературы; у каждого: value: float, unit: str,
                             # source: str (автор, год, где — непусто), reliability: "high"|"medium"|"low"
                             # обязательные ключи: "alpha_thermal" (dR/dz головы), "C_thermal"
                             # (коэффициент скорости подъёма головы), "alpha_plume" (вовлечение шлейфа);
                             # v3: "core_flux_fraction" (доля потока плавучести водосбора, которую несёт
                             # ядро, 0..1) и "hill_shell" (толщина оболочки сглаживания края головы, доля R)

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
# v3:
def from_strength(x: float, y: float, t0: float, w0: float, zl: float, tau: float, env: Env) -> Source
def kbar(zl: float, tau: float, env: Env, w0: float) -> float   # v4: + w0
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
  v3: F0 = core_flux_fraction · (w*³/z_l) · z_l²/8,5 — ядро несёт измеренную долю, не весь поток водосбора.
- v3, ядро по измерениям (Q1, 2026-11-09): `alpha_thermal` и `core_flux_fraction` — из измерений ядер в слое
  конвекции (Lenschow–Stephens 1980, Аллен 2006, Young 1988 и др. из `literature.md`), не лабораторные и не под
  нынешнюю модель; лабораторное α (Скорер/Тёрнер) — отдельным ключом для справки. Определение радиуса ядра — то же,
  что у эталона; как сведено — в README.
- v3, сглаживание края головы (Q1 п. 6): излом w на сфере Хилла (r = R) сглажен в оболочке толщиной
  `hill_shell`·R (≈ 0,2) — сглаживается функция тока Стокса ψ (тогда ∇·v = 0 и замкнутость массы сохраняются),
  не скорость.
- v3, `from_strength`: источник для термика игры по его силе `w0` (м/с, «сила ядра на пике», `AtmoThermal.strength`),
  толщине столба `zl = top − высота источника` и времени работы источника `tau` (= t_grow + t_mature термика):
  F0 подобран так, что максимум w на оси за жизнь пузыря = w0 (подбор по F0 — шлейф ∝ F0^⅓, голова иначе, точной степени нет; отн. ошибка ≤ 2 %). Остальное — как `from_game`.
- v3, `kbar`: K̄ шаблона, м² — средний по жизни (t0…конец) и по столбу 0…zl поток вверх (∫ max(w, 0) dA по
  горизонтальному сечению, только положительная область головы и шлейфа) одного пузыря `from_strength(…, w0, zl, tau)`,
  делённый на w0 (v4: поток растёт с силой нелинейно — жизнь и подобие зависят от F0, ревью TB-5; в игре w0 = w* столба); то же определение, что K̄ в `rust/dp-air/src/terms/thermal_air/columns.rs`
  (CORE_FLUX·π·r²·shape.mean·life_mean — средний поток ядра на 1 м/с пика). > 0, конечно.

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
10. v3, гладкость края головы: голова без шлейфа (как в п. 7) на t0 + 0,5·tau, линии через центр — по экватору
   (z = zc) и по оси, ±2R, шаг h = 0,005R: max|w(x+h) − 2w(x) + w(x−h)|/h · R/U ≤ 1,2 (излом Хилла v2 даёт ≈ 7,5; v4: порог 1,2 — при смешении ψ квинтикой оболочка 0,2R даёт ≈ 1,0, решение Q1 «~0,2R» сохраняется).
11. v3, PARAMS: есть `core_flux_fraction` (0 < value ≤ 1) и `hill_shell` (0 < value < 1).
12. v3, `from_strength`: при w0 = 2 и 4 м/с (zl 1400, tau 690) максимум w на оси (z от 1 м до zi, шаг 5 м; моменты
   шагом 10 с до конца жизни) — w0 с отн. ошибкой ≤ 2 %.
13. v4, `kbar(1400, 690, env, 2.5)` > 0 и конечно.

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

## TB3 v2 — сводки сверки, цены и LES `tools/research/thermal_bubble/out/*.json`
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

v2: `les.json` (пишет TB-6; читатели — сверка и итог) — `{"format": "tb-les", "version": 1, "rows": [...], "searched": [str]}`;
строка rows: `{"quantity": str, "unit": str, "literature": float|null, "lit_range": [lo, hi]|null, "source": str, "note": str,
"reliability": "high"|"medium"|"low"}`; обязательные quantity: `inflow_ground_over_wstar`, `outflow_top_over_wstar`,
`ring_sink_min_over_wstar`, `rise_speed_over_wstar`. Нет числа — null и причина в note.

## TB4 v2 — шаблон пузыря в `dp-air` за флагом
Владелец — координатор; пишут TB-7 (инфраструктура, порт TB1 v2), TB-8 (порт TB1 v3, K̄); потребители — сумма ветра
(`rust/dp-air/src/terms/sum.rs`), «между» (`terms/thermal_air`, TB-8). В игру по умолчанию не включается (Q1 п. 2).

- **Флаг:** `ThermalCfg.bubble_template: bool`, ключ json `/thermal/bubble_template` (там же, где читает
  `ThermalCfg::from_json`), по умолчанию `false`. В конфиги игры (`data/`, `scripts/`) не добавлять.
- **Флаг выключен — побитно прежнее:** `sum` (`[vx, vy, vz, σ]`), `ThermalOut.{w, mask, sigma}`, `cores`, «между» —
  те же биты, что до модуля (тест — фикстура, записанная на базе до правок).
- **`ThermalOut`** + поле `uh: [f64; 2]` — горизонтальная скорость термика в осях игры (x, z), м/с; флаг выкл — `[0, 0]`.
  `sum.rs`: `v[0] += fade·uh[0]`, `v[2] += fade·uh[1]` (тот же `fade`, что у w термика); `rec` `T_THERMAL` — `[fade·uh[0], w_th, fade·uh[1]]`.
- **Модуль `rust/dp-air/src/terms/thermal/bubble.rs`** (`pub mod bubble` в `thermal/mod.rs`):
  - порт `bubble.py` (`state`, `velocity` одного пузыря в его осесимметричной системе: (ρ, z над землёй) → (u_ρ, w),
    с отражениями от земли и крышки) — аналитика, только для сборки таблиц и тестов;
  - `BubbleTable` — (u_ρ, w) `f32` на сетке (ρ, z), шаг у оси ≤ 5 м (дальше от оси может расти), ρ до радиуса влияния
    (|v| < 1 % пика), z от 0 до zi; билинейная интерполяция; вне таблицы — 0.
- **Термик игры → пузырь** (СИ; z прототипа = высота над `src[1]`, ось прототипа x ↔ x игры, y ↔ z игры):
  земля — плоскость `src[1]`, крышка zi = `top − src[1]`; t0 = `t_birth`; tau = `t_grow + t_mature`;
  F0: TB-7 — `from_game` с w* = `strength`, zl = zi (временно); TB-8 — `from_strength(w0 = strength, zl, tau)`.
  Вертикаль (zc, R, U, Q, F0, zb) — `state` при ветре 0; центр по горизонтали — `src + phase(t).drift` (снос игры).
  Нет состояния (`state` → None) — вклада нет.
- **Опрос при флаге:** `ThermalField.sample` для термиков из бакетов: w и `uh` — сумма таблиц пузырей (вместо w
  профиля Гедеона), `mask` и `sigma` — как без флага (из нынешнего профиля). Запас бакета — не меньше радиуса таблицы.
  «Между» — TB-7 без изменений; TB-8 — с K̄ шаблона (`kbar`) при флаге.
- **Таблицы:** строятся при сборке набора (`State::build`, фон) для `active` термиков, ключ — `id`; между обновлениями
  таблица на t сборки сдвигается: по горизонтали — снос игры на момент опроса, по вертикали — на U·(t − t_сборки).
  Детерминизм: один вход — одни биты (порядок суммы не зависит от потоков).
- **Тесты** (`rust/dp-air/tests/thermal_bubble_embed.rs`): `flag_off_bitwise` (фикстура до правок,
  `rust/dp-air/tests/data/thermal_bubble_off.json`), `port_vs_python` (аналитика против
  `tools/research/thermal_bubble/out/bench_fixture.json`, отн. ≤ 1e-5), `table_accuracy` (печатает строку
  `table_max_rel=<x>` — max|Δv| таблицы против аналитики / пик |v| на сцене и в точках фикстуры), `flag_on_sum`
  (флаг вкл: у термика есть приток к оси у земли и растекание у верха — знаки `uh`, сумма конечна).

**v2 (ревью TB-7, 2026-11-09; пишет TB-8):**
- Порт — TB1 v4 (`bubble.py` после TB-5: ядро по измерениям, оболочка ψ, `from_strength`); F0 — `from_strength(w0 = strength, zl, tau)`.
- Радиус пузырей: ключ `/thermal/bubble_radius_m` (`ThermalCfg.bubble_radius_m`, по умолчанию 2000 м) — таблицы строятся
  только для динамических термиков, чей круг влияния (радиус таблицы + снос·margin) задевает круг `bubble_radius_m`
  вокруг любого фокуса. Дальше — как без флага (профиль Гедеона): граница модели, пилот её не видит.
- Динамический термик внутри радиуса пузырей: w и `uh` — только из таблицы; нет состояния, `r_max = 0` или таблица ещё
  не собрана (родился в интервале обновления) — вклада нет (не профиль Гедеона). `mask`, `sigma` — как без флага.
- Статичные термики (`is_static`, `statics.rs`: постоянная сила, нет жизни) — при флаге как без флага (профиль Гедеона).
- Кеш таблиц по `id` между обновлениями (`Arc`); пересборка — когда устарела (правило — в TB-8: по изменению zc/R/стадии),
  ошибка устаревания входит в `table_max_rel`. Цена: печать `build_ms_per_s=` — среднее время сборки таблиц на 1 с
  игры на сцене плотности Аллена (n_A = 8,5/z_l², z_l 1400) с фокусом, летящим 15 м/с; порог ≤ 100 мс/с (≤ 10 % ядра).
- «Между» при флаге: в `terms/thermal_air` K̄ столба — `kbar(zl, tau, env, w0 = w*)` шаблона (таблица по zl, считается
  один раз), без флага — побитно прежнее.
- Тесты v2 (в `tests/thermal_bubble_embed.rs`): прежние + `bubble_cache_budget` (печатает `build_ms_per_s=`),
  `no_table_no_w` (динамический без таблицы внутри радиуса — w = 0, uh = 0; статичный — как без флага),
  `port_vs_python` — против фикстуры v4 `tools/research/thermal_bubble/out/embed_fixture.json` (пишет `embed_fixture.py`; `bench_fixture.json` — v2 для бенча, не менять).
- K̄ шаблона в Rust — таблица констант по (zl, w*) `rust/dp-air/src/terms/thermal/bubble_kbar.rs`, сгенерирована из `bubble.kbar` скриптом `tools/research/thermal_bubble/kbar_table.py` (tau — среднее grow_s + mature_s `ThermalCfg::default`); билинейно, вне таблицы — край.
