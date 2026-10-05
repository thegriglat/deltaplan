class_name NetUiBackend
extends RefCounted
## Тонкая прослойка между экраном «Сетевая игра» (NetScreen) и клиентом сети (scripts/net/).
## Экран знает только этот интерфейс; настоящий клиент подключается адаптером
## (NetUiClientBackend), для тестов и скриншотов — NetUiFakeBackend.
## Сам этот класс — «сети нет»: любое подключение сразу кончается ошибкой "unreachable".

## Идёт подключение / в зоне / ничего — поменялось (экран перерисовывается по is_busy/in_zone).
signal state_changed
## Ошибка: "unreachable", "zone_not_found", "version_mismatch", "zone_full",
## "disconnected" (связь пропала уже в зоне), "bad_message", "port_busy" и "server_failed"
## (NET-22: встроенный сервер — порт занят / не запустился).
signal failed(kind: String)
## Вошли в зону (создали или присоединились): код зоны — строка.
signal zone_joined(code: String)
## Изменился список пилотов в зоне (кто-то пришёл, ушёл, сменился ведущий).
signal peers_changed
## Изменился список зон рядом (NET-23: появилась/пропала/обновилась).
signal nearby_changed
## Изменился список «Друзья в игре» (S5, только при активном Steam).
signal friends_changed

const ERROR_KINDS: PackedStringArray = [
	"unreachable",
	"zone_not_found",
	"version_mismatch",
	"zone_full",
	"disconnected",
	"bad_message",
	"port_busy",
	"server_failed",
]


## Подключиться к серверу address ("IP:порт" или имя) и создать зону с параметрами zone_params.
func connect_and_create(_address: String, _name: String, _zone_params: FlightSettings) -> void:
	_fail_later.call_deferred("unreachable")


## Подключиться и войти в зону по коду.
func connect_and_join(_address: String, _name: String, _code: String) -> void:
	_fail_later.call_deferred("unreachable")


## Выйти из зоны и отключиться (и отменить подключение, если оно ещё идёт).
func leave() -> void:
	pass


## Код текущей зоны ("" — не в зоне).
func code() -> String:
	return ""


## Пилоты зоны по порядку подключения: {id, name, join_order, is_leader, is_me}.
func peers() -> Array:
	return []


## Идёт подключение (ещё не в зоне и не ошибка).
func is_busy() -> bool:
	return false


## Параметры полёта зоны (место, время, погода; крыло и масса — свои); null — не в зоне.
func zone_settings() -> FlightSettings:
	return null


## Зоны рядом в локальной сети (NET-23): {code, host_name, address, port, game_version,
## pilots_count, same_version}. same_version = false — другая версия игры, войти нельзя.
## Пропадают через ~3 с без объявлений (обновляет источник данных, не экран).
func nearby() -> Array:
	return []


## Экран «Сетевая игра» открылся/закрылся — слушать/не слушать зоны рядом (NET-23).
## Сам этот класс — «сети нет»: список рядом всегда пуст, слушать нечего.
func start_nearby() -> void:
	pass


func stop_nearby() -> void:
	pass


# ---------------------------------------------------------------- Steam (контракт S5)
# Сам этот класс — Steam неактивен: пусто/false, вход в лобби — "unreachable".


## Steam активен: показывать «Пригласить друзей» и «Друзья в игре».
func steam_available() -> bool:
	return false


## Оверлей Steam «Пригласить друзей» в лобби текущей зоны.
func invite_friends() -> void:
	pass


## Зоны друзей Steam: {lobby_id, friend_name, zone_code, place, same_version}.
func friends_zones() -> Array:
	return []


## Вступить в лобби друга и войти в его зону (как connect_and_join, адрес и код — из лобби).
func connect_and_join_lobby(_lobby_id: int, _name: String) -> void:
	_fail_later.call_deferred("unreachable")


func _fail_later(kind: String) -> void:
	failed.emit(kind)
	state_changed.emit()
