extends Node
## Проверка ботов сетевой зоны (NET-44) на настоящих экземплярах игры: главная сцена под
## управлением этого скрипта; флаги главной сцены (--net-join, --air-start, --bots…) — как есть.
## Свои флаги:
##   --n44-create=<IP:порт>  создать зону на внешнем сервере (Go) и лететь (смена ведущего есть
##                           только там; встроенный сервер закрывает зону с уходом создателя);
##                           число ботов — --bots, сид — --net-seed, код — в --net-code-file
##   --n44-out=<папка> --n44-tag=<имя>   куда класть лог и кадры
##   --n44-log=<с>           лог мест ботов раз в <с> времени зоны (по умолчанию 1)
##   --n44-shots=<t1,t2…>    кадры в моменты времени зоны (камера — у бота --n44-shot-bot)
##   --n44-shot-bot=<id>     у какого бота камера (по умолчанию bot-0)
##   --n44-leave=<с>         в это время зоны выйти из зоны и из игры (уход ведущего)
##   --n44-end=<с>           выйти из игры
## Лог (stdout): «N44 zt=… role=L|R id=… name=… pos=x,y,z vel=x,y,z phase=…» — у ведущего — свои
## боты (BotPilots), у остальных — то, что рисуется (NetPilots.sample); «N44J» — скачки: сдвиг
## за кадр минус скорость·кадр больше 1 м.
## Пример: godot --path . res://tools/shots/net44_shot.tscn -- --n44-create=127.0.0.1:9000 \
##   --bots=4 --air-start --net-name=Kolya --net-code-file=/tmp/code --n44-out=/tmp/n44 --n44-tag=a

const MAIN_SCENE := preload("res://scenes/main.tscn")
const CAM_OFFSET := Vector3(45.0, 20.0, 60.0)

var _create := ""
var _out := ""
var _tag := "n44"
var _log_s := 1.0
var _shots: Array[float] = []
var _shot_bot := "bot-0"
var _leave_at := INF
var _end_at := INF
var _main: Node
var _next_log := 0.0
var _prev := {}  ## id → позиция в прошлом кадре
var _jumps := 0
var _busy := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"n44-create":
				_create = v
			"n44-out":
				_out = v
			"n44-tag":
				_tag = v
			"n44-log":
				_log_s = float(v)
			"n44-shots":
				for t in v.split(","):
					_shots.append(float(t))
			"n44-shot-bot":
				_shot_bot = v
			"n44-leave":
				_leave_at = float(v)
			"n44-end":
				_end_at = float(v)
	if _out != "":
		DirAccess.make_dir_recursive_absolute(_out)
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	if _create != "":
		_create_zone()


func _create_zone() -> void:
	for i in 60:
		await get_tree().process_frame
	var opts: LaunchOptions = _main.get("opts")
	NetClient.connect_to_server(_create, opts.net_name)
	var t0 := Time.get_ticks_msec()
	while not NetClient.is_online and Time.get_ticks_msec() - t0 < 15000:
		await get_tree().process_frame
	print("N44: связь с %s — %s" % [_create, NetClient.is_online])
	NetZone.create_zone(_main.get("flight"), opts.net_seed, maxi(opts.bots, 0))
	t0 = Time.get_ticks_msec()
	while not NetZone.in_zone and Time.get_ticks_msec() - t0 < 15000:
		await get_tree().process_frame
	print("N44: зона %s (я %s, ведущий %s)" % [NetZone.code, NetZone.my_id, NetZone.leader_id])
	if opts.net_code_file != "":
		var f := FileAccess.open(opts.net_code_file, FileAccess.WRITE)
		f.store_string(NetZone.code)
		f.close()
	_main.call("_on_net_fly")


func _process(_dt: float) -> void:
	if not NetZone.in_zone or _busy:
		return
	var zt := NetZone.zone_time()
	var game: Game = _main.get("game")
	var nf := game.net if game != null else null
	if nf == null or nf.bots == null:
		return
	var rows := _bot_rows(nf.bots)
	_check_jumps(rows, zt)
	if zt >= _next_log and _log_s > 0.0:
		_next_log = floorf(zt / _log_s + 1.0) * _log_s
		for r: Dictionary in rows:
			print(
				(
					"N44 zt=%.3f role=%s id=%s name=%s pos=%.2f,%.2f,%.2f vel=%.2f,%.2f,%.2f phase=%s"
					% [
						zt,
						"L" if nf.bots.is_simulating() else "R",
						r.id,
						r.name,
						r.pos.x,
						r.pos.y,
						r.pos.z,
						r.vel.x,
						r.vel.y,
						r.vel.z,
						r.phase
					]
				)
			)
		print("N44C zt=%.3f bots=%d leader=%s" % [zt, rows.size(), NetZone.is_leader()])
	if not _shots.is_empty() and zt >= _shots[0]:
		var t: float = _shots.pop_front()
		_shot(game, rows, t)
	elif zt >= _leave_at:
		_busy = true
		print("N44: выхожу из зоны zt=%.3f, скачков %d" % [zt, _jumps])
		NetZone.leave_zone()
		_quit()
	elif zt >= _end_at:
		_busy = true
		print("N44: конец zt=%.3f, скачков %d" % [zt, _jumps])
		_quit()


## Боты, как их видит этот клиент: [{id, name, pos, vel, phase}].
func _bot_rows(nb: NetBots) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in nb.bot_ids():
		var a := nb.agent_for(id) if nb.is_simulating() else null
		if a != null:
			var t := a.telemetry()
			out.append(
				{
					"id": id,
					"name": a.pilot_name,
					"pos": t.position + t.velocity * a.acc_s,
					"vel": t.velocity,
					"phase":
					(
						"%s/%s/m%d/h%s/run%.0f/lo%.0f"
						% [
							NetBots.phase_of(a),
							a.state_name(),
							a.model.mode,
							a.queue_hold,
							a.run_at_s,
							nb.sim.player_liftoff_s
						]
					)
				}
			)
		else:
			var s := NetPilots.sample(id)
			if not s.is_empty():
				out.append({"id": id, "name": s.name, "pos": s.pos, "vel": s.vel, "phase": s.phase})
	return out


func _check_jumps(rows: Array[Dictionary], zt: float) -> void:
	var dt := get_process_delta_time()
	var now := {}
	for r in rows:
		now[r.id] = r.pos
		if _prev.has(r.id):
			var d: Vector3 = r.pos - _prev[r.id] - r.vel * dt
			if d.length() > 1.0:
				_jumps += 1
				print("N44J zt=%.3f id=%s jump=%.2f m" % [zt, r.id, d.length()])
	for id: String in _prev:
		if not now.has(id):
			print("N44J zt=%.3f id=%s пропал" % [zt, id])
	_prev = now


func _shot(game: Game, rows: Array[Dictionary], t: float) -> void:
	var target := Vector3.INF
	for r in rows:
		if r.id == _shot_bot:
			target = r.pos
	if target == Vector3.INF:
		print("N44: кадр %.0f — бота %s нет" % [t, _shot_bot])
		return
	_busy = true
	var prev_cam := get_viewport().get_camera_3d()
	var cam := Camera3D.new()
	cam.far = 20000.0
	game.add_child(cam)
	cam.global_position = target + CAM_OFFSET
	cam.look_at(target + Vector3.UP * 2.0)
	cam.current = true
	for i in 3:
		await get_tree().process_frame
	var path := "%s/%s_zt%03d.png" % [_out, _tag, int(t)]
	get_viewport().get_texture().get_image().save_png(path)
	print("N44: кадр %s (у %s)" % [path, _shot_bot])
	cam.queue_free()
	if prev_cam != null:
		prev_cam.current = true
	_prev = {}
	_busy = false


func _quit() -> void:
	for i in 10:
		await get_tree().process_frame
	get_tree().quit(0)
