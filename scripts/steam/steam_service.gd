extends Node
## SteamService (контракт S1, docs/contracts/steam.md): единственная точка доступа к GodotSteam.
## Расширения может не быть — синглтон берётся только здесь, через Object и .call()/.get();
## остальные скрипты scripts/steam/* получают его через api(). Неактивен — все вызовы пустые.

signal activated()

const CONFIG_PATH := "res://configs/steam.json"
const INIT_OK := 0

var _active := false
var _reason := "no_feature"
var _api: Object = null
var _app_id := 480
var _launch_lobby := 0


func _ready() -> void:
	configure(OS.get_cmdline_user_args(), OS.get_cmdline_args(), OS.has_feature("steam"),
			Engine.get_singleton("Steam") if Engine.has_singleton("Steam") else null)


## Решение об активации (S1.2). Параметры — вход «снаружи» (в _ready берутся из ОС),
## чтобы тесты могли подставить свой «синглтон». user_args — после «--», args — обычные.
func configure(user_args: PackedStringArray, args: PackedStringArray, steam_feature: bool,
		singleton: Object) -> void:
	_active = false
	_api = null
	_launch_lobby = _parse_lobby(args)
	var cfg := _read_config()
	_app_id = int(cfg.get("app_id", 480))
	var no_steam := user_args.has("--no-steam")
	if not (steam_feature or user_args.has("--steam")):
		_reason = "no_feature"
	elif no_steam or cfg.get("enabled", true) == false:
		_reason = "disabled"
	elif singleton == null:
		_reason = "no_extension"
	else:
		var res: Variant = singleton.call("steamInitEx", _app_id)
		var status := int(res.get("status", 1)) if res is Dictionary else 1
		if status == INIT_OK:
			_api = singleton
			_active = true
			_reason = ""
		else:
			var verbal := String(res.get("verbal", "")) if res is Dictionary else ""
			_reason = "init_failed: %s (status %d)" % [verbal, status]
	if _active:
		print("steam: active (app_id %d)" % _app_id)
		activated.emit()
	else:
		print("steam: inactive (%s)" % _reason)


func _process(_delta: float) -> void:
	if _active:
		_api.call("run_callbacks")


func is_active() -> bool:
	return _active


func inactive_reason() -> String:
	return _reason


func api() -> Object:
	return _api


func app_id() -> int:
	return _app_id


func steam_id() -> int:
	return int(_api.call("getSteamID")) if _active else 0


func persona_name() -> String:
	return String(_api.call("getPersonaName")) if _active else ""


func language() -> String:
	return String(_api.call("getCurrentGameLanguage")) if _active else ""


func launch_lobby_id() -> int:
	return _launch_lobby


## «+connect_lobby <id>» — обычные аргументы запуска (Steam), не пользовательские.
static func _parse_lobby(args: PackedStringArray) -> int:
	var i := args.find("+connect_lobby")
	if i < 0 or i + 1 >= args.size():
		return 0
	var s := args[i + 1]
	return int(s) if s.is_valid_int() and int(s) > 0 else 0


static func _read_config() -> Dictionary:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
	return data if data is Dictionary else {}
