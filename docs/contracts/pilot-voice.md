---
type: contract
status: "closed"
module: pilot-voice
area: game
updated: "2026-11-06"
summary: "Реплики пилота: ситуации, вид, пасхалки (PV-К1), configs/pilot_voice.json (PV-К2), файлы голосов (PV-К3), логика и подключение (PV-К4)."
related: ["docs/plan/pilot-voice.md", "docs/guide/instruments.md", "docs/guide/game/menus-settings.md"]
contracts: [{"id": "PV-К1", "version": 3}, {"id": "PV-К2", "version": 3}, {"id": "PV-К3", "version": 1}, {"id": "PV-К4", "version": 3}]
---
# Контракты модуля pilot-voice

План — `docs/plan/pilot-voice.md`. Менять — только через координатора (версия +1, что изменилось, уведомить потребителей).
Контрактный тест — `tests/contracts/test_pilot_voice_contracts.gd` (headless, без звука и GPU): строки «## PV-К<n>. … (v<n>)»
этого файла; что `configs/pilot_voice.json` содержит ровно ситуации PV-К1 с полями PV-К2 и числом реплик из таблицы;
форма классов PV-К4; путь файла PV-К3.

История: v1 (2026-11-05) — 16 ситуаций; v2 (2026-11-05, Q1) — PV-К1 + `view` и реплики на пасхалки `egg_<id>`, `high` без пересечения с `view`;
PV-К2 + `params` пасхалок; PV-К4 + `watch_eggs`, `egg_in_view`, `EasterEgg.voice_anchor`;
v3 (2026-11-05, вопрос PVO-2) — заблокированное `gap_s` условие не тратит паузу и не ждёт в очереди; в очередь — только события, `max_wait_s` 8; `watch_eggs` повторяет `egg_seen`.
Тексты реплик (2026-11-06, без смены версий) — разговорные, RU и EN написаны отдельно, не переводом; немного ругани и юмора.

Принцип: пилот говорит то, что почувствовал бы сам, **по данным, которые есть у игрока** — отфильтрованный вариометр
(то, что пищит и показывает прибор), воздушная скорость, перегрузка, высота над землёй, касание, облако вокруг, события задачи.
Скрытые данные поля ветра (где термик, его сила впереди) — не входы.

## PV-К1. Ситуации и реплики (v3)

Владелец — координатор; потребители — PVO-2 (игра), генерация голосов (PVO-3). Тексты — в `configs/pilot_voice.json` (PV-К2),
здесь — источник. Приоритет: 3 — срочное, 2 — событие, 1 — фон. `chance` — вероятность сказать, когда условие сработало
(реплики редкие и не механические). Все времена — секунды реального времени при скорости времени ×1.

Обозначения входов (PV-К4): `v` — вариометр прибора `Vario.vario_ms` (отфильтрованный, м/с), `V` — воздушная скорость (м/с),
`n` — перегрузка `load_factor`, `bank` — крен, `agl` — высота над землёй, `gain` — высота над точкой отрыва (`altitude_msl` − высота при отрыве),
`cloud` — `CloudWhiteout.amount` 0..1, `stalled` — сваливание. «В полёте» — `phase == "flying"`.

| id | Условие (значения по умолчанию — `params`) | Пр. | Пауза, с | chance | Реплики RU | Реплики EN | Тон (для синтеза) |
|---|---|---|---|---|---|---|---|
| `takeoff` | событие отрыва; сказать через `delay_s` 1,0; раз за полёт | 2 | — | 0,7 | Пошёл! · Ну, с богом. · Поехали, родной. | Here we go! · Okay, don't screw this up. · Off we go, baby. | азарт, выдох |
| `thermal_found` | в полёте; `v ≥ 1,0` непрерывно `hold_s` 3; перед этим `quiet_s` 20 подряд `v < 0,5` | 1 | 90 | 0,6 | О, есть. · Тянет, тянет… · Ага, попался! | Ooh, something here. · Come on, come on… · Gotcha! | неуверенная радость, вполголоса |
| `thermal_strong` | в полёте; `v ≥ 3,0` непрерывно `hold_s` 4 | 1 | 180 | 0,7 | Ух, как прёт! · Вот это лифт! · Ха, лифт на небо! | Whoa, it's ripping! · Now that's a climb! · Elevator going up! | восторг |
| `thermal_lost` | в полёте; было `in_s` 30 со средним `v ≥ 0,8`, затем `v ≤ −1,0` непрерывно `hold_s` 5 | 1 | 120 | 0,6 | Потерял. · Ну и где он? · Всё, кончился. | Lost it. · Where'd it go? · Aaand it's gone. | разочарование |
| `sink` | в полёте; `v ≤ −3,0` непрерывно `hold_s` 3; не `stalled`; `V ≤ max_airspeed_ms` 15 (не пикирование) | 1 | 90 | 0,7 | Вот чёрт… · Сыплемся, блин. · Ну и дыра, ёлки. | Oh, come on… · Sinking like a brick. · Crap, crap, crap. | досада |
| `turbulence` | в полёте, `agl > 10`; за `window_s` 8 — не меньше `peaks` 3 выбросов `abs(n − 1/cos(bank)) ≥ 0,4` | 1 | 150 | 0,6 | Ох, болтает. · Тише, тише, родной… · Ну и трясёт. | Bumpy… · Easy, easy, baby… · Jeez, rough one. | напряжение |
| `stall` | в полёте, `agl > 5`; `stalled` непрерывно `hold_s` 0,5 | 3 | 20 | 1,0 | Твою ж мать! · Скорость, скорость! · Держу, держу, блин… | Holy shit! · Speed, speed! · Hang on, hang on… | испуг, резко |
| `fast` | в полёте; `V ≥ 22` (≈ 80 км/ч) непрерывно `hold_s` 3 | 1 | 180 | 0,6 | Ух, свистит! · Ну, понеслась! | Whoa, fast! · Yeehaw! | азарт |
| `low` | в полёте; `agl < 80` при `v < 0`, после того как с прошлого раза было `agl ≥ rearm_agl` 200 | 1 | 120 | 0,7 | Низковато. · Так, пора садиться. · Так, куда тут сесть-то? | Getting low. · Okay, time to land. · Where the hell do I land? | озабоченно |
| `high` | в полёте; `gain` впервые за полёт перешёл ступень `step_m` 300 (300, 600, 900 …) | 1 | 120 | 0,5 | Хорошо забрался. · Ого, высоко. · Ещё бы чуть-чуть… | Nice height. · Whoa, way up. · Bit more, come on… | спокойная радость |
| `view` | в полёте, `agl ≥ min_agl_m` 150; `abs(v) < v_calm_ms` 1,0 и ни одной реплики `calm_s` 60 подряд | 1 | 300 | 0,3 | Вот это вид… · Ради этого и летаем. · Эх, хорошо… | What a view… · This is why we fly. · Ahh, this is it. | тихо, любуясь |
| `cloud` | в полёте; `cloud ≥ 0,6` непрерывно `hold_s` 1 | 2 | 120 | 0,8 | Ничего не видно! · Блин, в облако влез. | Can't see a damn thing! · Crap, I'm in the cloud. | тревога |
| `turnpoint` | событие «точка маршрута взята» (`TaskTracker.turnpoint_reached`) | 2 | 10 | 1,0 | Есть точка! · Взял. | Got the turnpoint. · Got it. | довольно |
| `goal` | событие «гол» (`TaskTracker.goal_reached`) | 2 | — | 1,0 | Долетел! · Да! Да! Есть! | Made it! · Yes! Yes! Yes! | ликование |
| `landing_soft` | касание с `grade == "soft"`; через `delay_s` 0,6; раз за полёт | 2 | — | 0,7 | Мягко. · Как по маслу. · Красота. | Nice and soft. · Like butter. · Sweet. | облегчение |
| `landing_hard` | касание с `grade == "hard"`; через `delay_s` 0,6; раз за полёт | 3 | — | 1,0 | Ох… ноги. · Ну, жёстко. · Ай, блин. | Ow… my legs. · Well, that hurt. · Oof. | боль, кряхтение |
| `crash` | касание/столкновение с `grade == "crash"`; через `delay_s` 0,8; раз за полёт | 3 | — | 1,0 | Ох-х… · Ну приехали… | Ugh… · Well, shit… | стон |

**Пасхалки** (Q1, 2026-11-05): нейтральная реплика, когда пилот заметил пасхалку — событие `egg_seen {id}` (PV-К4): точка
`voice_anchor` пасхалки в конусе взгляда камеры `cone_deg` 30° (полуугол), не дальше `max_dist_m`, не закрыта рельефом, непрерывно `hold_s` 1,5.
Ситуация — `egg_<id>`; приоритет 1, раз за полёт на каждую, пауза 300 (своя), общие правила — как у фона.
Без реплик: `probe` (проба каркаса), `bar_charm` (всегда на трапеции), `start_dog` (на разбеге пилоту не до того).

| id | Пасхалка | `max_dist_m` | chance | Реплики RU | Реплики EN | Тон |
|---|---|---|---|---|---|---|
| `egg_an2` | Ан-2 | 1500 | 0,8 | О, Ан-2! · Кукурузник шпарит. | Oh, a plane! · Hey, a biplane. | удивление |
| `egg_airliner` | лайнер со следом | 15000 | 0,4 | Лайнер. · Кто-то в отпуск полетел… | Airliner. · Someone's off on holiday… | спокойно |
| `egg_gloria` | глория | 3000 | 0,9 | О, глория! · Ух ты, я святой! | Oh, a glory! · Whoa, I've got a halo! | восхищение |
| `egg_balloon` | воздушный шар | 2000 | 0,8 | О, шар! · Ну, этим торопиться некуда. | Oh, a balloon! · No rush for those guys. | радость |
| `egg_balloon_festival` | фестиваль шаров | 4000 | 0,9 | Сколько шаров! · Ого, тут целый праздник! | Look at all those balloons! · Whoa, it's a party! | восторг |
| `egg_uaz` | УАЗик | 800 | 0,8 | О, буханка! · За мной едут, что ли? | Oh, a car. · Is that my ride? | удивление |
| `egg_people` | люди у лагеря | 150 | 0,7 | Машут! · Привет, земляне! | They're waving! · Hello, earthlings! | весело |
| `egg_herds` | стадо, отара | 400 | 0,6 | Живность внизу. · Пасутся себе… | Animals down there. · Just grazing… | спокойно |
| `egg_group` | чужая группа на дальнем склоне | 4000 | 0,7 | Там тоже летают. · О, наши! | Others over there. · Oh, my people! | интерес |
| `egg_eagle` | орёл | 150 | 1,0 | Ух ты, орёл! · Орёл! Отвали! | Whoa, an eagle! · Back off, buddy! | восторг, вполголоса |
| `egg_crop_circles` | круги на поле | 1500 | 0,8 | Это что, круги? · Инопланетяне, не иначе. | Are those… crop circles? · Aliens. Definitely aliens. | недоумение |
| `egg_hay_bales` | рулоны сена | 500 | 0,3 | О, рулоны. · Это уже осень, что ли? | Hay bales. · Is it autumn already? | спокойно |
| `egg_geese` | клин гусей | 600 | 0,9 | Гуси! · Ребята, подвиньтесь. | Geese! · Hey guys, move over. | радость |

Общие правила (PV-К2 `rules`):
- одна реплика за раз; после конца реплики следующая — не раньше `gap_s` по приоритету новой: 1 → 20 с, 2 → 5 с, 3 → 2 с;
- срочная (3) прерывает звучащую фоновую (1);
- ситуация по данным полёта (условие держится — `sink`, `thermal_*`, `turbulence`, `stall`, `fast`, `low`, `high`, `view`, `cloud`),
  сработавшая, пока звучит реплика или не прошёл `gap_s`, **не ставится в очередь и не тратит** паузу, «раз за полёт», ступень `high`:
  она проверяется снова на каждом `update` и скажется, когда станет можно, если условие ещё держится;
- событие (`takeoff`, `landing_*`, `crash`, `turnpoint`, `goal`, `egg_<id>`) в это время ждёт в очереди (одно на ситуацию, порядок —
  приоритет, затем время) не дольше `max_wait_s` 8 с; не дождалось — отбрасывается **без** траты паузы и «раз за полёт»;
- фоновые (1) — не раньше `quiet_after_takeoff_s` 8 с после отрыва;
- вариант — случайный, не совпадает с последним сказанным в этой ситуации (при 3 вариантах — с двумя последними);
- `chance` разыгрывается в момент, когда реплику можно сказать; не выпал — ситуация уходит на свою паузу (и «раз за полёт») так же, как если бы реплика прозвучала;
- реплик нет: голос «выкл», скорость времени ≠ ×1, пауза игры, буксир, осмотр (`inspect_mode`), дельталёт (v1 — только дельтаплан),
  сетевая игра (`net != null`, решение 2026-11-05: только одиночная игра, сеть не трогаем), фон меню.

## PV-К2. configs/pilot_voice.json (v3)

Владелец — PVO-2; потребители — `PilotVoiceLogic`, генерация голосов (PVO-3, читает `lines` и `tone`). Слой настроек — как у всех
конфигов (`Config`); игрок меняет только `voice` патчем `UserSettings.save_patch("pilot_voice", {"voice": …})`.

```json
{
  "voice": "male",
  "voices": ["male", "female"],
  "bus": "Voice",
  "volume_db": 0.0,
  "dir": "res://assets/sounds/voice",
  "rules": {"gap_s": {"1": 20.0, "2": 5.0, "3": 2.0}, "max_wait_s": 8.0, "quiet_after_takeoff_s": 8.0},
  "situations": {
    "sink": {
      "priority": 1, "cooldown_s": 90.0, "chance": 0.7,
      "params": {"v_ms": -3.0, "hold_s": 3.0, "max_airspeed_ms": 15.0},
      "lines": [
        {"ru": "Вот чёрт…", "en": "Oh, come on…", "tone": "досада"}
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

## PV-К4. Логика, узел, подключение (v3)

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
func watch_eggs(camera: Camera3D, eggs: Array, dt: float) -> void   # живые EasterEgg; ≤ 4 Гц; видна hold_s → logic.event("egg_seen");
                                                 #   пока видна и её egg_<id> не сказана — повторять event раз в hold_s
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
