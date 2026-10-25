---
type: "contract"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-26"
summary: "W11 rust-wind: решатель Пикара в крейте — R6 v3 + заморозка колонн, отмена, новые причины остановки; пустая маска — побитно R6 v3."
related: ["docs/contracts/rust-wind.md", "docs/contracts/picard-rs.md", "docs/research/rust-wind-field-path.md"]
contracts: [{"id": "W11", "version": 1}]
---

# W11. Решатель Пикара в крейте (v1)

Часть `docs/contracts/rust-wind.md` (версия — там, заголовок W11). Менять — только координатор. Расширяет `picard_rs::api` (R6 v3, `docs/contracts/picard-rs.md`; тот контракт закрыт и не правится — всё новое здесь). Владелец — RW-6g (заморозка, отмена), RW-6h (запасные правила). Потребители — RW-6j (оркестровка), RW-6n (окна), фазы RW-6k–6m (дают маски).
Эталон поведения — игровой GPU-путь: `scripts/atmosphere/air_model/air_picard_job.gd` (`_freeze`, `freeze_mask`/`freeze_mask_mech`, `freeze_field`/`freeze_field_mech`, `_use_freeze_mask`, `_pad_cols`, `all_frozen`, счёт неизвестных) и ядра `air_picard.glsl` (`K_FREEZE`, `K_RMASK`, `K_FIXROW`). Разбор — `docs/research/rust-wind-field-path.md`, «Карта фаз и заморозка колонн».

- `SolveOpts` (R6 v3) + поля (`Default` — `None`, поведение R6 v3 побитно):
  - `freeze: Option<Freeze>`; `pub struct Freeze { pub mask: Vec<u8>, pub field: Option<FrozenField> }`: `mask` — колонны `ny·nx` без ореола, строка — по `y` сетки случая, `1` — колонна заморожена; ореол — как `_pad_cols(edge = false)`. `FrozenField { u, v, w, th, thd: Vec<f32> }` — раскладка `State` (R4 v2); замороженные колонны держат эти значения (нет `field` — значения `init`, нет `init` — фон); итерации их не меняют.
  - `cancel: Option<std::sync::Arc<std::sync::atomic::AtomicBool>>` — проверяется после каждой итерации (и в подготовке); `true` → остановка не позже конца текущей итерации, отдаётся текущее поле (с finalize).
- Невязки, критерий сходимости и `residuals` — только по незамороженным колоннам (как счёт неизвестных игры).
- `StopReason` + `AllFrozen` (все колонны заморожены: решение не идёт, `iters = 0`, `state` = замороженное поле) и `Cancelled`.
- Неверная длина `mask`/`field` — `Err` с текстом, без паники.
- Инварианты (тест RW-6g): `freeze = None` и маска из нулей дают побитно R6 v3; T4 — дивергенция и невязка по незамороженным в критерии; замороженные колонны побитно равны `field`; отмена — не позже 1 итерации; результат не зависит от числа потоков (побитно).
- Запасные правила RW-6h (ω-откат, `late_mean`, `nonconv`, `max_outer`) — поля `SolveOpts` добавит W11 v2 при постановке RW-6h.
