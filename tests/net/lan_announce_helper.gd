extends SceneTree
## Второй процесс для tests/net/test_lan_discovery.gd: объявляет одну зону через LanDiscovery,
## пока его не убьют (не дольше --seconds). Запуск:
##   godot --headless --path . --script res://tests/net/lan_announce_helper.gd -- \
##     --port=47123 --dest=127.0.0.1 --code=4721 --version=0.7.1 --seconds=20
## Когда объявление ушло — печатает в stdout строку "announcing".

const LAN_DISCOVERY := preload("res://scripts/net/lan_discovery.gd")

var _deadline_ms := 0


func _initialize() -> void:
	var args := {"port": "8081", "dest": "127.0.0.1", "code": "4721", "version": "0.7.1"}
	args["seconds"] = "20"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			args[a.substr(2, a.find("=") - 2)] = a.substr(a.find("=") + 1)
	var lan: Node = LAN_DISCOVERY.new()
	lan.port = int(args.port)
	lan.broadcast_address = args.dest
	root.add_child(lan)
	var info := {
		"code": args.code,
		"host_name": "Помощник",
		"port": 8080,
		"game_version": args.version,
		"pilots_count": 2,
	}
	lan.start_announcing(func() -> Array: return [info])
	print("announcing")
	_deadline_ms = Time.get_ticks_msec() + int(float(args.seconds) * 1000.0)


func _process(_delta: float) -> bool:
	return Time.get_ticks_msec() > _deadline_ms
