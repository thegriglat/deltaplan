class_name EggStartDog
extends EasterEgg
## Собака у стартового лагеря — минимальная версия DOG-1 для кадров модели и клипов: стоит у лагеря
## и показывает клипы (ходовые — на месте). Поведение (погоня за бегущим, бровка, лай) — DOG-2,
## контракт DOG-K4 (docs/contracts/start-dog.md). Модель — DOG-K2, лай — DOG-K3.
## Клип показа: переменная окружения DP_DOG_CLIP (кадры tools/shots/start_dog_clips.sh), иначе
## cfg.showcase_clip; "" — все клипы по очереди по showcase_s.
## Место: 3 м от центра лагеря в сторону пилота, боком к нему; лагеря нет — 6 м сбоку от пилота;
## кадры (DP_DOG_CLIP задана) — shot_side_m сбоку от пилота (лагерь со старта бывает не виден).

const MODEL := "res://assets/easter_eggs/start_dog/dog.glb"
const CLIPS: PackedStringArray = ["gallop", "trot", "walk", "idle", "bark", "lie", "sit", "sniff"]

var _cfg: Dictionary = {}
var _ap: AnimationPlayer
var _fixed := ""
var _clip := ""


## Условия: не ночь.
static func can_appear(ctx: EggContext, cfg: Dictionary) -> bool:
	return ctx.sun_elev_deg > float(cfg.get("min_sun_deg", -6.0))


func begin(ctx: EggContext, cfg: Dictionary, _rng: RandomNumberGenerator, _t0: float) -> void:
	_cfg = cfg
	var pilot := Vector2(ctx.pilot_pos.x, ctx.pilot_pos.z)
	var home := pilot + Vector2(float(cfg.get("pilot_side_m", 6.0)), 0.0)
	var camp: Array[Dictionary] = ctx.place.camp() if ctx.place != null else []
	var shot := OS.get_environment("DP_DOG_CLIP") != ""  # кадры: у пилота (лагерь бывает за бровкой)
	if shot:
		home = pilot + Vector2(float(cfg.get("shot_side_m", 5.0)), 0.0)
	elif not camp.is_empty():
		var c2 := Vector2.ZERO
		for t in camp:
			c2 += Vector2(t.position.x, t.position.z)
		c2 /= float(camp.size())
		var to_pilot := pilot - c2
		var dir := to_pilot.normalized() if to_pilot.length() > 0.1 else Vector2.RIGHT
		home = c2 + dir * float(cfg.get("camp_offset_m", 3.0))
	position = Vector3(home.x, ctx.height_at.call(home.x, home.y), home.y)
	# боком к пилоту: вперёд (−Z модели) ⟂ направлению на пилота
	var d := pilot - home
	var fwd := Vector2(-d.y, d.x).normalized() if d.length() > 0.1 else Vector2(0.0, -1.0)
	rotation.y = atan2(-fwd.x, -fwd.y)
	var ps: PackedScene = load(MODEL) if ResourceLoader.exists(MODEL) else null
	if ps == null:
		return
	var model := ps.instantiate()
	add_child(model)
	_ap = model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	_fixed = OS.get_environment("DP_DOG_CLIP")
	if _fixed == "":
		_fixed = String(cfg.get("showcase_clip", ""))


## Клип в момент t: заданный или по очереди.
func clip_at(t: float) -> String:
	if _fixed != "":
		return _fixed
	var k := int(floor(maxf(t - t0, 0.0) / float(_cfg.get("showcase_s", 4.0))))
	return CLIPS[k % CLIPS.size()]


func update(ctx: EggContext) -> bool:
	var c := clip_at(ctx.t)
	if _ap != null and c != _clip and _ap.has_animation(c):
		_ap.play(c, 0.2)
		_clip = c
	return true
