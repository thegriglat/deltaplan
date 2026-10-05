extends Node
## SteamPresence (контракт S3): Activity → Rich Presence Steam. Не чаще раза в секунду, только
## изменившиеся ключи. Steam неактивен — ни одного обращения (всё через SteamService.api()).
## Лобби сообщает ST-8: set_lobby(id), 0 — лобби нет.

const MIN_INTERVAL_S := 1.0
const MODES := ["menu", "loading", "launch", "flying", "landed", "paused"]

## Подмена в тестах (по умолчанию — автозагрузки).
var service: Node = null
var activity: Node = null

var _lobby := 0
var _dirty := true
var _clock := 0.0
var _last_send := -1000.0
var _sent: Dictionary = {}


func _ready() -> void:
	if activity == null:
		activity = get_node_or_null("/root/Activity")
	if activity != null:
		activity.changed.connect(_mark_dirty)


func _svc() -> Node:
	return service if service != null else get_node_or_null("/root/SteamService")


func set_lobby(lobby_id: int) -> void:
	if lobby_id != _lobby:
		_lobby = lobby_id
		_dirty = true


func _mark_dirty() -> void:
	_dirty = true


func _process(delta: float) -> void:
	_clock += delta
	flush(_clock)


## Отправить изменившиеся ключи, если пора. now_s — часы (в тестах свои). Возвращает число вызовов Steam.
func flush(now_s: float) -> int:
	if not _dirty:
		return 0
	var svc := _svc()
	if svc == null or not svc.is_active():
		return 0
	if now_s - _last_send < MIN_INTERVAL_S:
		return 0
	_dirty = false
	_last_send = now_s
	var api: Object = svc.api()
	var calls := 0
	var keys := build_keys(activity.state() if activity != null else {}, _lobby)
	for k: String in keys:
		var v: String = keys[k]
		if _sent.get(k, "") != v:  # ключ, которого не было, пустым не шлём
			api.call("setRichPresence", k, v)
			_sent[k] = v
			calls += 1
	return calls


func _exit_tree() -> void:
	var svc := _svc()
	if svc != null and svc.is_active() and not _sent.is_empty():
		svc.api().call("clearRichPresence")


## Состояние Activity → ключи Steam (пустая строка — ключ очищен).
static func build_keys(st: Dictionary, lobby: int) -> Dictionary:
	var mode := String(st.get("mode", "menu"))
	if mode not in MODES:
		mode = "menu"
	var token := "#St_" + mode.capitalize() + ("_Net" if bool(st.get("net", false)) else "")
	var peers := int(st.get("peers", 0))
	return {
		"steam_display": token,
		"place": String(st.get("place", "")),
		"alt": str(int(st.get("alt_msl", 0))),  # подстановки %alt%/%peers% всегда заданы: без ключа Steam текст не покажет
		"peers": str(peers),
		"steam_player_group": str(lobby) if lobby != 0 else "",
		"steam_player_group_size": str(peers) if lobby != 0 else "",
		"connect": "+connect_lobby %d" % lobby if lobby != 0 else "",
	}
