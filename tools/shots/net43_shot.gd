extends Node
## Очередь на старт (NET-43) на настоящих экземплярах игры: главная сцена под этим скриптом, её
## флаги (--net-host, --net-join, --autopilot, --bots…) — как есть.
## Свои флаги:
##   --n43-out=<папка> --n43-tag=<имя>   куда класть кадры (<tag>_queue_1.png …)
##   --n43-humans=<N>    ведущий: автопилот включается, только когда в зоне N живых пилотов и
##                       все они в очереди, и ещё через --n43-wait секунд (все дошли до мест)
##   --n43-wait=<с>      (по умолчанию 20)
##   --n43-shots=<с,с,…> кадры очереди со стороны старта: через столько секунд после «все
##                       в очереди + wait» (0 — перед включением автопилота)
##   --n43-end=<с>       выйти через столько секунд полёта (реальных)
## Лог: «N43 …» — очередь зоны раз в 2 с, кадры.

const MAIN_SCENE := preload("res://scenes/main.tscn")

var _out := ""
var _tag := "n43"
var _humans := 0
var _wait_s := 20.0
var _shots: Array[float] = [0.0]
var _end_s := INF
var _main: Node
var _game: Game
var _t := 0.0
var _ready_t := -1.0
var _log_t := 0.0
var _n := 0
var _busy := false
var _pilot_on := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"n43-out":
				_out = v
			"n43-tag":
				_tag = v
			"n43-humans":
				_humans = int(v)
			"n43-wait":
				_wait_s = float(v)
			"n43-shots":
				_shots.clear()
				for t in v.split(","):
					_shots.append(float(t))
			"n43-end":
				_end_s = float(v)
	if _out != "":
		DirAccess.make_dir_recursive_absolute(_out)
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	_game = _main.get("game")


func _process(dt: float) -> void:
	if _main.get("state") != 2 and _main.get("state") != 4:
		return
	_t += dt
	if _t - _log_t >= 2.0:
		_log_t = _t
		print("N43 t=%.0f очередь %s я %s" % [_t, NetZone.queue, NetZone.my_id])
	if _busy:
		return
	if _t >= _end_s:
		_busy = true
		_main.call("_quit", 0)
		return
	if _humans > 0:
		_drive()


## Ведущий: ждать всех в очереди, снимать кадры, включить автопилот.
func _drive() -> void:
	if _ready_t < 0.0:
		var live := 0
		for id: String in NetZone.queue:
			if not id.begins_with("bot-") and _game.net.queue_status(id) == "wait":
				live += 1
		if NetZone.peers.size() >= _humans and live >= _humans:
			_ready_t = _t + _wait_s
			print("N43: все %d в очереди t=%.0f" % [_humans, _t])
		return
	var since := _t - _ready_t
	if since < 0.0:
		return
	if not _shots.is_empty() and since >= _shots[0]:
		_shots.pop_front()
		_n += 1
		_shot_queue("%s_queue_%d.png" % [_tag, _n])
	elif not _pilot_on:
		_pilot_on = true
		_game.autopilot = Autopilot.new()
		print("N43: автопилот ведущего включён t=%.0f" % _t)


## Кадр очереди: свободная камера впереди старта, чуть сбоку и выше, смотрит назад на места.
func _shot_queue(file_name: String) -> void:
	_busy = true
	var st: Dictionary = _game.get_start()
	var h := deg_to_rad(float(st.heading_deg))
	var fwd := Vector3(sin(h), 0.0, -cos(h))
	var right := Vector3(-fwd.z, 0.0, fwd.x)
	var cam := _game.camera
	cam.set_mode("free")
	await get_tree().process_frame
	# Все места очереди в кадре: смотрим на их середину спереди-сбоку и сверху.
	var n := maxi(NetZone.queue.size(), 1)
	var c := Vector3.ZERO
	for k in n:
		c += _game.net.queue.spot(k).position / float(n)
	var r := 10.0
	for k in n:
		r = maxf(r, (_game.net.queue.spot(k).position as Vector3).distance_to(c))
	cam.global_position = c + fwd * (r * 1.3 + 12.0) + right * r * 0.5 + Vector3.UP * (r * 0.5 + 6.0)
	var d := c - cam.global_position
	cam.set("_free_rot", Vector2(atan2(-d.x, -d.z), atan2(d.y, Vector2(d.x, d.z).length())))
	for i in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := _out.path_join(file_name)
	print("N43: кадр %s (%s) очередь %s" % [path, error_string(img.save_png(path)), NetZone.queue])
	cam.set_mode("chase")
	_busy = false
