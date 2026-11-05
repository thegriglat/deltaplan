---
type: contract
status: active
module: pilot-voice
area: game
updated: 2026-11-05
summary: "Реплики пилота: ситуации, вид, пасхалки (PV-К1), configs/pilot_voice.json (PV-К2), файлы голосов (PV-К3), логика и подключение (PV-К4)."
related: ["docs/plan/pilot-voice.md", "docs/guide/instruments.md", "docs/guide/game/menus-settings.md"]
contracts: [{"id": "PV-К1", "version": 2}, {"id": "PV-К2", "version": 2}, {"id": "PV-К3", "version": 1}, {"id": "PV-К4", "version": 2}]
---
# Контракты модуля pilot-voice

План — `docs/plan/pilot-voice.md`. Менять — только через координатора (версия +1, что изменилось, уведомить потребителей).
Контрактный тест — `tests/contracts/test_pilot_voice_contracts.gd` (headless, без звука и GPU): строки «## PV-К<n>. … (v<n>)»
этого файла; что `configs/pilot_voice.json` содержит ровно ситуации PV-К1 с полями PV-К2 и числом реплик из таблицы;
форма классов PV-К4; путь файла PV-К3.

История: v1 (2026-11-05) — 16 ситуаций; v2 (2026-11-05, Q1) — PV-К1 + `view` и реплики на пасхалки `egg_<id>`, `high` без пересечения с `view`;
PV-К2 + `params` пасхалок; PV-К4 + `watch_eggs`, `egg_in_view`, `EasterEgg.voice_anchor`.

Принцип: пилот говорит то, что почувствовал бы сам, **по данным, которые есть у игрока** — отфильтрованный вариометр
(то, что пищит и показывает прибор), воздушная скорость, перегрузка, высота над землёй, касание, облако вокруг, события задачи.
Скрытые данные поля ветра (где термик, его сила впереди) — не входы.

## PV-К1. Ситуации и реплики (v2)

Владелец — координатор; потребители — PVO-2 (игра), генерация голосов (PVO-3). Тексты — в `configs/pilot_voice.json` (PV-К2),
здесь — источник. Приоритет: 3 — срочное, 2 — событие, 1 — фон. `chance` — вероятность сказать, когда условие сработало
(реплики редкие и не механические). Все времена — секунды реального времени при скорости времени ×1.

Обозначения входов (PV-К4): `v` — вариометр прибора `Vario.vario_ms` (отфильтрованный, м/с), `V` — воздушная скорость (м/с),
`n` — перегрузка `load_factor`, `bank` — крен, `agl` — высота над землёй, `gain` — высота над точкой отрыва (`altitude_msl` − высота при отрыве),
`cloud` — `CloudWhiteout.amount` 0..1, `stalled` — сваливание. «В полёте» — `phase == "flying"`.

| id | Условие (значения по умолчанию — `params`) | Пр. | Пауза, с | chance | Реплики RU | Реплики EN | Тон (для синтеза) |
|---|---|---|---|---|---|---|---|
| `takeoff` | событие отрыва; сказать через `delay_s` 1,0; раз за полёт | 2 | — | 0,7 | Пошёл! · Летим! · Ну, поехали. | Here we go! · Airborne! · Okay, flying. | азарт, выдох |
| `thermal_found` | в полёте; `v ≥ 1,0` непрерывно `hold_s` 3; перед этим `quiet_s` 20 подряд `v < 0,5` | 1 | 90 | 0,6 | Вроде нашёл. · О, тянет… · Есть, пошло вверх. | I think I've got something. · Ooh, it's pulling… · There we go, going up. | неуверенная радость, вполголоса |
| `thermal_strong` | в полёте; `v ≥ 3,0` непрерывно `hold_s` 4 | 1 | 180 | 0,7 | Ух, как несёт! · Вот это термик! · Хорошо пошло! | Wow, it's really pulling! · Now that's a thermal! · Going up nicely! | восторг |
| `thermal_lost` | в полёте; было `in_s` 30 со средним `v ≥ 0,8`, затем `v ≤ −1,0` непрерывно `hold_s` 5 | 1 | 120 | 0,6 | Потерял… · Куда делся? · Всё, кончился. | Lost it… · Where'd it go? · That's it, it's gone. | разочарование |
| `sink` | в полёте; `v ≤ −3,0` непрерывно `hold_s` 3; не `stalled`; `V ≤ max_airspeed_ms` 15 (не пикирование) | 1 | 90 | 0,7 | Вот чёрт… · Сыплемся… · Ну и провал. | Oh, damn… · We're dropping… · What a sink. | досада |
| `turbulence` | в полёте, `agl > 10`; за `window_s` 8 — не меньше `peaks` 3 выбросов `abs(n − 1/cos(bank)) ≥ 0,4` | 1 | 150 | 0,6 | Ох, болтает. · Тише, тише… · Ну и трясёт. | Bumpy… · Easy, easy… · Rough air. | напряжение |
| `stall` | в полёте, `agl > 5`; `stalled` непрерывно `hold_s` 0,5 | 3 | 20 | 1,0 | Ой-ой! · Скорость! · Держу, держу… | Whoa! · Speed! · Hold it, hold it… | испуг, резко |
| `fast` | в полёте; `V ≥ 22` (≈ 80 км/ч) непрерывно `hold_s` 3 | 1 | 180 | 0,6 | Ух, свистит! · Быстро идём. | The wind's howling! · We're flying fast. | азарт |
| `low` | в полёте; `agl < 80` при `v < 0`, после того как с прошлого раза было `agl ≥ rearm_agl` 200 | 1 | 120 | 0,7 | Низковато. · Пора садиться. · Где тут сесть? | Getting low. · Time to land. · Where do I put down? | озабоченно |
| `high` | в полёте; `gain` впервые за полёт перешёл ступень `step_m` 300 (300, 600, 900 …) | 1 | 120 | 0,5 | Хорошо забрался. · Вот это высота. · Ещё бы повыше. | Good height. · Now that's high. · A bit higher would be nice. | спокойная радость |
| `view` | в полёте, `agl ≥ min_agl_m` 150; `abs(v) < v_calm_ms` 1,0 и ни одной реплики `calm_s` 60 подряд | 1 | 300 | 0,3 | Вот это вид… · Красиво тут. · Хорошо летим… | What a view… · Beautiful up here. · This is nice… | тихо, любуясь |
| `cloud` | в полёте; `cloud ≥ 0,6` непрерывно `hold_s` 1 | 2 | 120 | 0,8 | Ничего не видно! · Влез в облако… | Can't see a thing! · I'm in the cloud… | тревога |
| `turnpoint` | событие «точка маршрута взята» (`TaskTracker.turnpoint_reached`) | 2 | 10 | 1,0 | Есть точка! · Взял. | Got the turnpoint! · Got it. | довольно |
| `goal` | событие «гол» (`TaskTracker.goal_reached`) | 2 | — | 1,0 | Есть гол! Долетел! · Да! Долетел. | Goal! Made it! · Yes! Made it. | ликование |
| `landing_soft` | касание с `grade == "soft"`; через `delay_s` 0,6; раз за полёт | 2 | — | 0,7 | Мягко. · Ну вот и всё. · Красота. | Nice and soft. · And that's it. · Lovely. | облегчение |
| `landing_hard` | касание с `grade == "hard"`; через `delay_s` 0,6; раз за полёт | 3 | — | 1,0 | Ох… ноги. · Жёстко вышло. · Ай. | Ouch… my legs. · That was hard. · Oof. | боль, кряхтение |
| `crash` | касание/столкновение с `grade == "crash"`; через `delay_s` 0,8; раз за полёт | 3 | — | 1,0 | Ох-х… · Ну вот… | Ugh… · Oh no… | стон |

**Пасхалки** (Q1, 2026-11-05): нейтральная реплика, когда пилот заметил пасхалку — событие `egg_seen {id}` (PV-К4): точка
`voice_anchor` пасхалки в конусе взгляда камеры `cone_deg` 30° (полуугол), не дальше `max_dist_m`, не закрыта рельефом, непрерывно `hold_s` 1,5.
Ситуация — `egg_<id>`; приоритет 1, раз за полёт на каждую, пауза 300 (своя), общие правила — как у фона.
Без реплик: `probe` (проба каркаса), `bar_charm` (всегда на трапеции), `start_dog` (на разбеге пилоту не до того).

| id | Пасхалка | `max_dist_m` | chance | Реплики RU | Реплики EN | Тон |
|---|---|---|---|---|---|---|
| `egg_an2` | Ан-2 | 1500 | 0,8 | О, кукурузник! · Ан-2 летит. | Oh, a biplane! · There goes an An-2. | удивление |
| `egg_airliner` | лайнер со следом | 15000 | 0,4 | Лайнер высоко… · Кто-то в отпуск полетел. | An airliner up high… · Someone's off on holiday. | спокойно |
| `egg_gloria` | глория | 3000 | 0,9 | Глория! · Ух ты, кольца вокруг тени! | A glory! · Wow, rings around my shadow! | восхищение |
| `egg_balloon` | воздушный шар | 2000 | 0,8 | О, шар! · Воздушный шар летит. | Oh, a balloon! · There's a hot-air balloon. | радость |
| `egg_balloon_festival` | фестиваль шаров | 4000 | 0,9 | Сколько шаров! · Ого, фестиваль! | So many balloons! · Wow, a balloon festival! | восторг |
| `egg_uaz` | УАЗик | 800 | 0,8 | О, машина! · Буханка пылит. | Oh, a car! · Look at that van kicking up dust. | удивление |
| `egg_people` | люди у лагеря | 150 | 0,7 | Машут! · Привет, наши! | They're waving! · Hi, everyone! | весело |
| `egg_herds` | стадо, отара | 400 | 0,6 | Стадо внизу. · Пасутся… | A herd down there. · Grazing away… | спокойно |
| `egg_group` | чужая группа на дальнем склоне | 4000 | 0,7 | Там тоже летают. · О, ещё группа! | Others are flying over there. · Oh, another group! | интерес |
| `egg_eagle` | орёл | 150 | 1,0 | Ух ты, орёл! · Орёл рядом! | Whoa, an eagle! · An eagle right beside me! | восторг, вполголоса |
| `egg_crop_circles` | круги на поле | 1500 | 0,8 | Это что, круги на поле? · Ну и узор… | Are those crop circles? · What a pattern… | недоумение |
| `egg_hay_bales` | рулоны сена | 500 | 0,3 | Сено уже скатали. · Рулоны на поле. | They've baled the hay. · Hay bales in the field. | спокойно |
| `egg_geese` | клин гусей | 600 | 0,9 | Гуси летят! · Клин… | Geese! · Look at that V… | радость |

Общие правила (PV-К2 `rules`):
- одна реплика за раз; после конца реплики следующая — не раньше `gap_s` по приоритету новой: 1 → 20 с, 2 → 5 с, 3 → 2 с;
- срочная (3) прерывает звучащую фоновую (1); остальные ждут; ожидающая реплика старше `max_wait_s` 3 с — отбрасывается;
- фоновые (1) — не раньше `quiet_after_takeoff_s` 8 с после отрыва;
- вариант — случайный, не совпадает с последним сказанным в этой ситуации (при 3 вариантах — с двумя последними);
- `chance` не выпал — ситуация уходит на свою паузу так же, как если бы реплика прозвучала;
- реплик нет: голос «выкл», скорость времени ≠ ×1, пауза игры, буксир, осмотр (`inspect_mode`), дельталёт (v1 — только дельтаплан),
  сетевая игра (`net != null`, решение 2026-11-05: только одиночная игра, сеть не трогаем), фон меню.

## PV-К2. configs/pilot_voice.json (v2)

Владелец — PVO-2; потребители — `PilotVoiceLogic`, генерация голосов (PVO-3, читает `lines` и `tone`). Слой настроек — как у всех
конфигов (`Config`); игрок меняет только `voice` патчем `UserSettings.save_patch("pilot_voice", {"voice": …})`.

```json
{
  "voice": "male",
  "voices": ["male", "female"],
  "bus": "Voice",
  "volume_db": 0.0,
  "dir": "res://assets/sounds/voice",
  "rules": {"gap_s": {"1": 20.0, "2": 5.0, "3": 2.0}, "max_wait_s": 3.0, "quiet_after_takeoff_s": 8.0},
  "situations": {
    "sink": {
      "priority": 1, "cooldown_s": 90.0, "chance": 0.7,
      "params": {"v_ms": -3.0, "hold_s": 3.0, "max_airspeed_ms": 15.0},
      "lines": [
        {"ru": "Вот чёрт…", "en": "Oh, damn…", "tone": "досада"}
      ]
    }
  }
}
```
- `voice`: `"male"` | `"female"` | `"off"`; по умолчанию `"male"`; неизвестное значение = `"off"`.
- `situations`: ключи — ровно `id` из PV-К1; `priority` int 1..3; `cooldown_s` float ≥ 0 (в таблице «—» = 0, ограничение «раз за полёт» —
  в логике); `chance` 0..1; `params` — числа из столбца «Условие» (имена — как в таблице: `hold_s`, `quiet_s`, `in_s`, `window_s`, `peaks`,
  `delay_s`, `rearm_agl`, `step_m`, `max_airspeed_ms`, пороги — `v_ms`, `v_quiet_ms`, `v_in_ms`, `v_out_ms`, `n_dev`, `agl_m`, `min_agl_m`,
  `airspeed_ms`, `cloud`, `v_calm_ms`, `calm_s`; у `egg_<id>` — `max_dist_m`, `cone_deg`, `hold_s`); `lines` — массив, порядок задаёт номер файла (PV-К3), `ru`/`en`/`tone` — непустые строки.
- Пороги в логике — только из `params`, не константами в коде.

## PV-К3. Файлы голосов (v1)

Владелец — PVO-3 (генерация); потребитель — `PilotVoice`.
- Путь: `<dir>/<voice>/<lang>/<id>_<k>.ogg`, `voice` ∈ `voices`, `lang` ∈ {`ru`, `en`}, `k` = индекс в `lines` + 1
  (пример: `res://assets/sounds/voice/female/ru/sink_2.ogg`). `PilotVoice.line_path(voice, lang, line_id) -> String`.
- Формат: Ogg Vorbis, моно, 44 100 Гц; громкость −20 LUFS ± 1 (интегральная, на реплику), пик ≤ −3 dBFS; тишина в начале и конце ≤ 80 мс;
  без музыки, эха, шума. Импорт Godot — без зацикливания; `.ogg.import` коммитятся вместе с файлами.
- Язык: `TranslationServer.get_locale()` начинается с `ru` → `ru`, иначе `en`.
- Файла нет — реплика молча пропускается (без ошибки в лог), ситуация уходит на паузу.
- Лицензия: модель синтеза и голос разрешают распространение в открытой игре (itch.io, Steam), голос — не копия реального человека;
  запись в `assets/sounds/LICENSES.md` и `ASSETS.md`.

## PV-К4. Логика, узел, подключение (v2)

Владелец — PVO-2; потребитель — `Game`, тесты.

```gdscript
class_name PilotVoiceLogic extends RefCounted   # scripts/audio/pilot_voice_logic.gd, без нод
func setup(cfg: Dictionary, rng_seed: int = 0) -> void   # cfg — configs/pilot_voice.json целиком
func reset() -> void                             # новый полёт: паузы, «раз за полёт», ступени high, история вариантов
func event(name: String, data := {}) -> void     # "took_off" {altitude_msl}; "landed" {grade}; "turnpoint"; "goal";
                                                 #   "egg_seen" {id} → ситуация egg_<id>, нет такой — игнор
func update(dt: float, s: Dictionary) -> String  # вернуть line_id ("sink_2") — начать сейчас; "" — молчать
#   s: phase String, vario_ms float, airspeed_ms float, load_factor float, bank_deg float,
#      altitude_agl float, altitude_msl float, stalled bool, cloud float 0..1
func line_finished() -> void                     # реплика доиграла (отсюда считается gap_s)
func is_interrupting(line_id: String) -> bool    # новая реплика прерывает звучащую (PV-К1, приоритет 3 над 1)

class_name PilotVoice extends Node               # scripts/audio/pilot_voice.gd: AudioStreamPlayer на шине Voice
func set_voice(voice: String) -> void            # "male" | "female" | "off"
func on_event(name: String, data := {}) -> void
func update(t: Telemetry, vario_ms: float, cloud: float, dt: float) -> void
static func line_path(voice: String, lang: String, line_id: String) -> String
func watch_eggs(camera: Camera3D, eggs: Array, dt: float) -> void   # живые EasterEgg; ≤ 4 Гц; hold_s → logic.event("egg_seen")
static func egg_in_view(cam: Transform3D, point: Vector3, cone_deg: float, max_dist_m: float) -> bool  # без рельефа

# scripts/world_objects/easter_egg.gd (база пасхалок), только чтение, физику и картинку не меняет (К7 пасхалок зелёный):
func voice_anchor(from: Vector3) -> Vector3      # видимая точка пасхалки, ближайшая к from; по умолчанию global_position
```
- Шина `Voice` (Master ← Voice) — в `scenes/audio/bus_layout.tres` и в `AudioBuses.create_missing_buses`.
- `Game`: `update` — в `_on_telemetry` с `_sound_vario().vario_ms` и `_whiteout.amount`; события — из `took_off`, `_on_landed`,
  столкновения (grade crash) и сигналов `TaskTracker`; `reset` — при новом полёте; правила «реплик нет» PV-К1 — здесь.
- Пасхалки: `Game` зовёт `watch_eggs(camera, eggs.active(), dt)`; закрытие рельефом — 16 точек отрезка камера → точка
  выше `Terrain.height_at(x, z)` (иначе не видно). Пасхалки, у которых начало узла не на объекте (машины, стада, шары фестиваля, рулоны,
  гуси, круги) — переопределяют `voice_anchor`.
- Настройка: вкладка «Звук» → «Голос пилота»: Мужской / Женский / Выкл (`locale/ui.csv`); применяется сразу (`Game.apply_user_settings`).
