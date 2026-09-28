extends Node
## Кадры «догнать» (NET-42) на настоящих экземплярах игры: главная сцена под этим скриптом, её
## флаги (--net-host, --net-join, --air-start, --camera…) — как есть.
## Свои флаги:
##   --n42-out=<папка> --n42-tag=<имя>   куда класть кадры (<tag>_tow_1.png …, <tag>_menu.png)
##   --n42-tow=<с,с,…>   кадры буксира через столько секунд от его начала (по умолчанию 0.4,4,7)
##   --n42-arrive=<с>    кадр через столько секунд после прибытия (по умолчанию 1.5)
##   --n42-menu=<с>      через столько секунд после прибытия — открыть меню `=` и снять
##   --n42-end=<с>       выйти через столько секунд полёта (реальных)
## Лог: «N42 …» — начало/конец буксира, расстояние до цели.
## Пример (второй экземпляр — вошедший, ведущий в воздухе):
##   godot --path . res://tools/shots/net42_shot.tscn -- --net-join=1234 --camera=chase \
##     --n42-out=/tmp/n42 --n42-tag=join --n42-menu=3 --n42-end=60

const MAIN_SCENE := preload("res://scenes/main.tscn")

var _out := ""
var _tag := "n42"
var _tow_shots: Array[float] = [0.4, 4.0, 7.0]
var _arrive_s := 1.5
var _menu_s := -1.0
var _end_s := INF
var _main: Node
var _game: Game
var _t := 0.0
var _tow_t0 := -1.0
var _arrived_t := -1.0
var _pending: Array[float] = []
var _n := 0
var _busy := false
var _arrive_done := false
var _menu_done := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"n42-out":
				_out = v
			"n42-tag":
				_tag = v
			"n42-tow":
				_tow_shots.clear()
				for t in v.split(","):
					_tow_shots.append(float(t))
			"n42-arrive":
				_arrive_s = float(v)
			"n42-menu":
				_menu_s = float(v)
			"n42-end":
				_end_s = float(v)
	if _out != "":
		DirAccess.make_dir_recursive_absolute(_out)
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	_game = _main.get("game")
	_game.catch_up_started.connect(_on_started)
	_game.catch_up_ended.connect(_on_ended)


func _on_started() -> void:
	_tow_t0 = _t
	_pending = _tow_shots.duplicate()
	print("N42: буксир поехал t=%.1f от %s" % [_t, _game.glider.model.position])


func _on_ended(state: String) -> void:
	_arrived_t = _t
	print("N42: буксир кончился (%s) t=%.1f, %.1f с" % [state, _t, _t - _tow_t0])


func _process(dt: float) -> void:
	if _main.get("state") != 2 and _main.get("state") != 3:
		return
	_t += dt
	if _busy:
		return
	if _game.is_towing() and _t - _tow_t0 >= 0.0:
		var r := _game.tow.last
		if not _pending.is_empty() and _t - _tow_t0 >= _pending[0]:
			_pending.pop_front()
			_n += 1
			print(
				(
					"N42: кадр буксира %d, %s, %.0f км/ч, до цели %.0f м"
					% [_n, r.state, float(r.speed) * 3.6, float(r.target_distance)]
				)
			)
			_shot("%s_tow_%d.png" % [_tag, _n])
			return
	if _arrived_t >= 0.0 and not _arrive_done and _t - _arrived_t >= _arrive_s:
		_arrive_done = true
		print("N42: прибытие, до ведущего %.1f м" % _dist_to_leader())
		_shot("%s_arrive.png" % _tag)
		return
	if _arrived_t >= 0.0 and _menu_s >= 0.0 and not _menu_done and _t - _arrived_t >= _menu_s:
		_menu_done = true
		_main.call("open_catch_up_menu")
		_shot_later("%s_menu.png" % _tag, 0.6)
		return
	if _t >= _end_s:
		_busy = true
		_main.call("_quit", 0)


func _dist_to_leader() -> float:
	if _game.net == null or _game.net.remote == null:
		return -1.0
	var p := _game.net.remote.get_pilot(NetZone.leader_id)
	return _game.glider.model.position.distance_to(p.position) if p != null else -1.0


func _shot_later(file_name: String, delay_s: float) -> void:
	_busy = true
	await get_tree().create_timer(delay_s, true).timeout
	_busy = false
	_shot(file_name)


func _shot(file_name: String) -> void:
	_busy = true
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := _out.path_join(file_name)
	print("N42: кадр %s (%s)" % [path, error_string(img.save_png(path))])
	_busy = false
