class_name WristInstruments
extends Node
## Наручные приборы пилота (PH-7; PH-К2, PH-К3, PH-К4, PH-К5): часы на левой кисти (время суток игры,
## SunClock.hour — только чтение) и компас (картушка по реальному курсу, жидкостный
## компас с инерцией) на правой. Ремешок с прибором — кольцо на месте запястья вплотную к срезу
## перчатки (манжеты нет, предплечья от первого лица не видно), жёстко за костью кисти; слой по
## умолчанию — видны всем камерам, в том числе кабинной.
## Параметры — configs/ui.json → clock.enabled (часы), compass.* (компас).

const WATCH_PATH := "res://assets/models/watch.glb"
const COMPASS_PATH := "res://assets/models/wrist_compass.glb"
## Размеры моделей ремешка (с пряжкой; tools/blender/watch.json, wrist_compass.json): ширина вдоль
## кисти, высота эллипса кольца по оси циферблата, зазор до среза перчатки, м.
const STRAP_W_M := 0.025
const RING_H_M := 0.046
const STRAP_GAP_M := 0.001

var clock: SunClock  ## источник времени (Game.sky.clock); null — часы скрыты (чужой пилот)
var watch: Node3D  ## корень модели часов
var compass: Node3D  ## корень модели компаса
var card_angle := 0.0  ## текущий угол картушки (rotation.z), рад
var card_rate := 0.0  ## угловая скорость картушки, рад/с
var _hour_hand: Node3D
var _minute_hand: Node3D
var _card: Node3D
var _target := 0.0  ## последний уверенный угол на север, рад
var _snap := true
var _clock_on := true
var _compass_on := true
var _period_s := 1.5
var _zeta := 0.6
var _min_proj := 0.12


## Прикрепить приборы к модели пилота pm. openings — срезы перчаток от PilotGloveCut.cut(): прибор
## с ремешком встаёт на кость кисти вплотную к срезу (кольцо вокруг запястья позади перчатки,
## циферблатом на тыл кисти), жёстко за кистью. Нет среза или кисти — прежнее крепление к пустышкам
## WristL/WristR модели. false — крепить некуда.
func attach(pm: Node3D, openings: Dictionary = {}) -> bool:
	var wl := _mount(pm, "L", openings)
	var wr := _mount(pm, "R", openings)
	if wl == null or wr == null:
		return false
	watch = _load(WATCH_PATH)
	compass = _load(COMPASS_PATH)
	if watch != null:
		watch.name = "Watch"
		wl.add_child(watch)
		_hour_hand = watch.find_child("HourHand", true, false) as Node3D
		_minute_hand = watch.find_child("MinuteHand", true, false) as Node3D
	if compass != null:
		compass.name = "WristCompass"
		wr.add_child(compass)
		_card = compass.find_child("Card", true, false) as Node3D
	reload()
	return watch != null or compass != null


## Точка крепления прибора на руке side ("L"/"R"). Базис — оси кисти: +Y прибора вдоль кисти к
## пальцам, −Z — на тыл (у левой кости тыл — +Z, у правой — −Z), начало — на тыльной точке ремешка:
## центр кольца (срез по X/Z кости) на оси запястья, кольцо отстоит от среза на зазор.
func _mount(pm: Node3D, side: String, openings: Dictionary) -> Node3D:
	var grip := pm.find_child("Hand" + side, true, false) as Node3D
	if grip == null or not openings.has(side):
		return pm.find_child("Wrist" + side, true, false) as Node3D
	var o: Dictionary = openings[side]
	var dorsal := 1.0 if side == "L" else -1.0
	var b := Basis(Vector3(-1, 0, 0), Vector3.UP, Vector3(0, 0, -1)) if side == "L" else Basis.IDENTITY
	var c: Vector3 = o.center
	c.y = float(o.y) - STRAP_W_M * 0.5 - STRAP_GAP_M
	var m := Node3D.new()
	m.name = "WristMount" + side
	# начало модели — на тыльной поверхности кольца: от центра кольца на половину высоты к тылу
	var at := c + Vector3(0, 0, dorsal) * RING_H_M * 0.5
	m.transform = grip.transform.affine_inverse() * Transform3D(b, at)
	grip.add_child(m)
	return m


func _load(path: String) -> Node3D:
	if not ResourceLoader.exists(path):
		push_warning("WristInstruments: нет модели %s" % path)
		return null
	var ps := load(path) as PackedScene
	return ps.instantiate() as Node3D if ps != null else null


## Перечитать configs/ui.json (флажки «Часы»/«Компас», параметры картушки).
func reload() -> void:
	_clock_on = bool(Config.value("ui", "clock.enabled", true))
	_compass_on = bool(Config.value("ui", "compass.enabled", true))
	_period_s = maxf(0.1, float(Config.value("ui", "compass.period_s", 1.5)))
	_zeta = maxf(0.0, float(Config.value("ui", "compass.zeta", 0.6)))
	_min_proj = clampf(float(Config.value("ui", "compass.min_projection", 0.12)), 0.0, 0.9)
	_apply_visibility()


func _apply_visibility() -> void:
	if watch != null:
		watch.visible = _clock_on and clock != null
	if compass != null:
		compass.visible = _compass_on


func set_clock(c: SunClock) -> void:
	clock = c
	_apply_visibility()
	update_hands()


func is_watch_shown() -> bool:
	return watch != null and watch.visible


func is_compass_shown() -> bool:
	return compass != null and compass.visible


func _process(dt: float) -> void:
	update_hands()
	update_compass(dt)


## Стрелки: часовая 2π·fmod(h,12)/12, минутная 2π·fmod(h·60,60)/60 (PH-К4).
func update_hands() -> void:
	if clock == null or watch == null or not watch.visible:
		return
	set_hands(clock.hour)


func set_hands(hour: float) -> void:
	if _hour_hand != null:
		_hour_hand.rotation.z = TAU * fmod(hour, 12.0) / 12.0
	if _minute_hand != null:
		_minute_hand.rotation.z = TAU * fmod(hour * 60.0, 60.0) / 60.0


## Угол от +Y пустышки до проекции севера (−Z мира) на плоскость циферблата, положительный — по
## часовой для смотрящего (+Y → −X). proj — длина проекции (0..1) в out[1]. Чистая функция.
static func north_angle(wrist_basis: Basis) -> Vector2:
	var b := wrist_basis.orthonormalized()
	var n_local := b.inverse() * Vector3(0, 0, -1)
	var px := n_local.x
	var py := n_local.y
	return Vector2(atan2(-px, py), sqrt(px * px + py * py))


## Шаг картушки: демпфированный осциллятор вокруг угла на север; при почти вертикальном
## циферблате (проекция мала) картушка держит прежнюю цель.
func update_compass(dt: float) -> void:
	if _card == null or compass == null or not compass.visible or dt <= 0.0:
		return
	var parent := compass.get_parent() as Node3D
	if parent == null or not parent.is_inside_tree():
		return
	var na := north_angle(parent.global_transform.basis)
	if na.y >= _min_proj:
		_target = na.x
		if _snap:
			card_angle = _target
			card_rate = 0.0
			_snap = false
	step_card(dt)
	_card.rotation.z = card_angle


## Один шаг осциллятора к _target (подшаги ≤ 1/60 с — устойчиво при любом dt кадра).
func step_card(dt: float) -> void:
	var w := TAU / _period_s
	var n := maxi(1, ceili(dt * 60.0))
	var h := dt / float(n)
	for _i in n:
		var err := wrapf(_target - card_angle, -PI, PI)
		card_rate += (w * w * err - 2.0 * _zeta * w * card_rate) * h
		card_angle += card_rate * h
	card_angle = wrapf(card_angle, -PI, PI)


func set_target(a: float) -> void:
	_target = a
	_snap = false
