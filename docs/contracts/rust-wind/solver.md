---
type: "contract"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-26"
summary: "W11 rust-wind: решатель Пикара в крейте — R6 v3 + заморозка колонн, отмена, новые причины остановки; пустая маска — побитно R6 v3."
related: ["docs/contracts/rust-wind.md", "docs/contracts/picard-rs.md", "docs/research/rust-wind-field-path.md"]
contracts: [{"id": "W11", "version": 7}]
---

# W11. Решатель Пикара в крейте (v7)

Часть `docs/contracts/rust-wind.md` (версия — там, заголовок W11). Менять — только координатор. Расширяет `picard_rs::api` (R6 v3, `docs/contracts/picard-rs.md`; тот контракт закрыт и не правится — всё новое здесь). Владелец — RW-6g (заморозка, отмена), RW-6h (запасные правила). Потребители — RW-6j (оркестровка), RW-6n (окна), фазы RW-6k–6m (дают маски).
Эталон поведения — игровой GPU-путь: `scripts/atmosphere/air_model/air_picard_job.gd` (`_freeze`, `freeze_mask`/`freeze_mask_mech`, `freeze_field`/`freeze_field_mech`, `_use_freeze_mask`, `_pad_cols`, `all_frozen`, счёт неизвестных) и ядра `air_picard.glsl` (`K_FREEZE`, `K_RMASK`, `K_FIXROW`). Разбор — `docs/research/rust-wind-field-path.md`, «Карта фаз и заморозка колонн».

- `SolveOpts` (R6 v3) + поля (`Default` — `None`, поведение R6 v3 побитно):
  - `freeze: Option<Freeze>`; `pub struct Freeze { pub mask: Vec<u8>, pub field: Option<FrozenField> }`: `mask` — колонны `ny·nx` без ореола, строка — по `y` сетки случая, `1` — колонна заморожена; ореол — как `_pad_cols(edge = false)`. `FrozenField { u, v, w, th, thd: Vec<f32> }` — раскладка `State` (R4 v2); замороженные колонны держат эти значения (нет `field` — значения `init`, нет `init` — фон); итерации их не меняют.
  - `cancel: Option<std::sync::Arc<std::sync::atomic::AtomicBool>>` — проверяется после каждой итерации (и в подготовке); `true` → остановка не позже конца текущей итерации, отдаётся текущее поле (с finalize).
- Невязки, критерий сходимости и `residuals` — только по незамороженным колоннам (как счёт неизвестных игры).
- `StopReason` + `AllFrozen` (все колонны заморожены: решение не идёт, `iters = 0`, `state` = замороженное поле) и `Cancelled`.
- Неверная длина `mask`/`field` — `Err` с текстом, без паники.
- Инварианты (тест RW-6g): `freeze = None` и маска из нулей дают побитно R6 v3; T4 — дивергенция и невязка по незамороженным в критерии; замороженные колонны побитно равны `field` до `finalize` (v2: `finalize` проецирует всё поле без маски, как игра, — в отдаваемом `state` u, v, w замороженных колонн после проекции, th и thd — побитно `field`); отмена — не позже 1 итерации; результат не зависит от числа потоков (побитно).
- **v3 — запасные правила (RW-6h; эталон — `air_picard_job.gd`: `omega_fallback`, `late_from`, `nonconv_mask/field`, `_setup_nonconv`, `max_outer = 3000`, P12 v2 в комментариях там же):** `SolveOpts.fallback: Option<Fallback>`; `pub struct Fallback { pub omega_after: usize, pub omega: f32, pub late_from: usize, pub nonconv: Option<NonConv> }`, `pub struct NonConv { pub mask: Vec<u8> /* ny·nx, 1 — колонна механизма H/D */, pub field: Option<FrozenField> /* нет — late_mean */ }`. Семантика — как в игре: после `omega_after` итераций без сходимости — ω := `omega` (`omega_fallback`, игра 300 / 0,5); с итерации `late_from` (игра 500; 0 — не копится) состояния копятся в среднее `late_mean`; упёрлись в `max_iters` (игра `max_outer` 3000) без сходимости — поле := `late_mean`, в колоннах `nonconv.mask` := `nonconv.field` (нет — `late_mean`), затем `finalize`. `Solved` + `omega_fallback_used: bool`, `nonconv_fallback: bool`, `nonconv_frac: f32`. `fallback = None` — побитно v2.
- v3: `cancel` взведён до старта при `AllFrozen` без `init` и `field` — отдаётся `AllFrozen` с фоном (поле заморозки по умолчанию), не нули (ревью RW-6g).
- **v4 — C_d стенки по столбцу (RW-6r; эталон — `air_picard.glsl:393`, плоскость `col` 12 из `AirCase.prepare`, SH-6):** `picard_rs::Case` + `cd_col: Option<Vec<f32>>` (столбцы `ny·nx` без ореола, строка — по `y` сетки случая); есть — импульс у стенки берёт C_d своего столбца, как игра; нет (файлы R1 и случаи без поля) — прежнее одно `cd`, побитно v3. `case_build` (RW-6e) заполняет `cd_col` из `PreparedPlanes` всегда. Пороги запасных правил (`omega_after`, `late_from`) отсчитываются от того же нуля, что в игре (без `pre_steps` холодного старта; ревью RW-6h).
- **v5 (ревью RW-6r, итог RW-6m):**
  - `cd_col` — плоскость `nyh·nxh` **с ореолом** (как в игре: `cd_col[idx % (nxh·nyh)]`, `air_picard.glsl:393`), не `ny·nx` — исправление текста v4.
  - Счёт итераций — как в игре для всех вызовов: `max_iters`, `omega_after`, `late_from` отсчитываются без `pre_steps` холодного старта; останов по `max_iters` — на ближайшей проверке сходимости сверху (`air_picard_job.gd:1013`), не посреди пачки. Побитное совпадение с R6 v3 сохраняется при `pre_steps = 0` и когда упора в `max_iters` нет.
  - `FrozenField.thd: Option<Vec<f32>>` (и тот же тип в `NonConv.field`): игра не передаёт канал θ′_d в поле заморозки и `nonconv` — `None` значит «θ′_d из `init`» (заморозка) и «θ′_d из `late_mean`» (`nonconv`), как в игре; `Some` — как раньше.
- **v6 (ревью RW-6j):** `cancel` проверяется и в подготовке решения (V-циклы фона холодного старта, сборка многосеточных уровней, `finalize`) — между шагами не дольше ~50 мс работы; отмена в подготовке — `Cancelled`, поле конечно (фон или нули). Нужно, чтобы `unload_place`/`Drop` (W3) укладывались в 1 с и на 2 потоках.
- **v7 (RW-6n, окна; эталон — `air_window_job.gd`, `air_window.glsl`, ядро `K_BC` `air_picard.glsl`):**
  - `picard_rs::Case.nest: Option<NestBc>`; `pub struct NestBc { pub ubw: Vec<f32>, pub thb: Vec<f32>, pub thbd: Option<Vec<f32>> }` — w на гранях и θ′/θ′_d в клетках от родителя, раскладка — как у `ubu`/`ubv` случая (с ореолом). С `nest`: грани w типа 2 закреплены значениями `ubw` (как u, v); θ′ и θ′_d в ореоле и в неизвестных-не-клетках — из `thb`/`thbd`, они же — цель зоны релаксации; граничное условие решателя ставит u, v, w, θ′, θ′_d на всех не-неизвестных гранях и клетках, как `K_BC`. `thbd = None` — канала θ′_d нет (`_no_thd`). `nest = None` — поведение v6 побитно (область).
  - `SolveOpts.init_cycles: Option<u32>` — только вместе с `init`: перед стартом p := 0, затем столько V-циклов (старт окна от родителя — `Some(30)`, `_rec_warm_init`); `None` — как v6 (4 V-цикла, p из `init`; тёплый сдвиг окна — так). Без `init` — `BadInput`/ошибка разбора опций.
