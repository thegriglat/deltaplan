extends Node
## Второй процесс для tests/net/test_host_busy.gd: пилот подключается к серверу и входит в
## зону по коду, пока его не убьют (не дольше --seconds). Сцена, а не --script: нужны
## автозагрузки (Config и др.). Запуск:
##   godot --headless --path . res://tests/net/join_helper.tscn -- \
##     --addr=127.0.0.1:8080 --code=4721 --out=/tmp/join.txt --seconds=40
## В --out построчно (сразу на диск): "connected <unix>", "joined <unix> <число пилотов>",
## "error <код>", "left <unix>". В user:// ничего не пишет.

const NET_CLIENT := preload("res://scripts/net/net_client.gd")
const NET_ZONE := preload("res://scripts/net/net_zone.gd")

var _deadline_ms := 0
var _out: FileAccess


func _ready() -> void:
	var args := {"addr": "127.0.0.1:8080", "code": "", "out": "", "seconds": "40"}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			args[a.substr(2, a.find("=") - 2)] = a.substr(a.find("=") + 1)
	_out = FileAccess.open(args.out, FileAccess.WRITE)
	var client: Node = NET_CLIENT.new()
	add_child(client)
	var zone: Node = NET_ZONE.new()
	zone.setup(client)
	add_child(zone)
	var code: String = args.code
	client.connected.connect(
		func(_r: bool) -> void:
			_line("connected %.3f" % Time.get_unix_time_from_system())
			zone.join_zone(code)
	)
	client.error.connect(func(c: String, _t: String) -> void: _line("error " + c))
	zone.zone_error.connect(func(c: String, _t: String) -> void: _line("error " + c))
	zone.zone_entered.connect(
		func(_c: String) -> void:
			_line("joined %.3f %d" % [Time.get_unix_time_from_system(), zone.peers.size()])
	)
	zone.zone_left.connect(func() -> void: _line("left %.3f" % Time.get_unix_time_from_system()))
	client.connect_to_server(args.addr, "Помощник")
	_deadline_ms = Time.get_ticks_msec() + int(float(args.seconds) * 1000.0)


func _line(s: String) -> void:
	if _out != null:
		_out.store_line(s)
		_out.flush()


func _process(_delta: float) -> void:
	if Time.get_ticks_msec() > _deadline_ms:
		get_tree().quit()
