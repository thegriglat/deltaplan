class_name PilotAnimator
extends RefCounted
## Анимации пилота по фазе полёта (configs/game.json → pilot_animation, контракт —
## docs/models.md → «Пилот»): stand ⇄ walk → run → отрыв → run_air → climb_in → prone →
## у земли climb_out → flare → касание → stand. Одноразовые анимации идут очередью.
## Нет AnimationPlayer или нужной анимации — ничего не делает.

var player: AnimationPlayer

var _cfg: Dictionary = {}
var _current := ""
var _queue: PackedStringArray = []
var _air_state := ""  ## "", "up" (взлёт → кокон), "down" (из кокона к посадке)
var _air_time := 0.0
var _elapsed := 0.0  ## сколько играет текущая анимация, с (по времени симуляции)


## root — визуал планера (после Glider.setup модель пересоздаётся — звать снова).
func bind(root: Node, cfg: Dictionary) -> void:
	_cfg = cfg
	_current = ""
	_queue.clear()
	_air_state = ""
	_air_time = 0.0
	player = null
	if root != null:
		var found := root.find_children("*", "AnimationPlayer", true, false)
		if not found.is_empty():
			player = found[0] as AnimationPlayer
	if player != null:
		for a: String in _cfg.get("looped", []):
			if player.has_animation(a):
				player.get_animation(a).loop_mode = Animation.LOOP_LINEAR
	_play(String(_cfg.get("by_phase", {}).get("standing", "stand")))


## Каждый шаг: фаза, высота над землёй, вертикальная скорость, сила выравнивания 0..1.
func update(phase: String, agl: float, vario: float, flare_amount: float, dt: float) -> void:
	if phase != "flying":
		_air_state = ""
		_air_time = 0.0
		_queue.clear()
		var a := String(_cfg.get("by_phase", {}).get(phase, ""))
		if a != "":
			_play(a)
		return
	_air_time += dt
	_elapsed += dt
	var flare := flare_amount > float(_cfg.get("flare_threshold", 0.3))
	var low := (
		agl < float(_cfg.get("climb_out_agl_m", 15.0))
		and vario < 0.0
		and _air_time > float(_cfg.get("min_air_time_s", 10.0))
	)
	if _air_state == "":
		_air_state = "up"
		_start_sequence(_cfg.get("takeoff_sequence", ["prone"]))
	elif _air_state == "up" and (flare or low):
		_air_state = "down"
		_start_sequence(_cfg.get("landing_sequence", ["flare"]))
	elif _air_state == "down" and not flare and agl > float(_cfg.get("climb_in_agl_m", 30.0)):
		_air_state = "up"
		_start_sequence(PackedStringArray(["climb_in", "prone"]))
	_advance_queue()


## Что играет сейчас (для тестов и отладки).
func current() -> String:
	return _current


func _start_sequence(seq: Array) -> void:
	_queue = PackedStringArray()
	for a: String in seq:
		if player != null and player.has_animation(a):
			_queue.append(a)
	if not _queue.is_empty():
		_play(_queue[0])
		_queue.remove_at(0)


## Одноразовая анимация доиграла (по времени симуляции) — следующая из очереди.
func _advance_queue() -> void:
	if _queue.is_empty() or player == null or not player.has_animation(_current):
		return
	if _elapsed >= player.get_animation(_current).length:
		_play(_queue[0])
		_queue.remove_at(0)


func _play(anim: String) -> void:
	if player == null or anim == "" or anim == _current or not player.has_animation(anim):
		return
	_current = anim
	_elapsed = 0.0
	player.play(anim, float(_cfg.get("blend_s", 0.3)))
