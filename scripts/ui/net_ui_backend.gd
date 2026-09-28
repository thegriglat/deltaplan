class_name NetUiBackend
extends RefCounted
## Тонкая прослойка между экраном «Сетевая игра» (NetScreen) и клиентом сети (scripts/net/).
## Экран знает только этот интерфейс; настоящий клиент подключается адаптером
## (NetUiClientBackend), для тестов и скриншотов — NetUiFakeBackend.
## Сам этот класс — «сети нет»: любое подключение сразу кончается ошибкой "unreachable".

## Идёт подключение / в зоне / ничего — поменялось (экран перерисовывается по is_busy/in_zone).
signal state_changed
## Ошибка: "unreachable", "zone_not_found", "version_mismatch", "zone_full",
## "disconnected" (связь пропала уже в зоне), "bad_message".
signal failed(kind: String)
## Вошли в зону (создали или присоединились): код зоны — строка.
signal zone_joined(code: String)
## Изменился список пилотов в зоне (кто-то пришёл, ушёл, сменился ведущий).
signal peers_changed

const ERROR_KINDS: PackedStringArray = [
	"unreachable",
	"zone_not_found",
	"version_mismatch",
	"zone_full",
	"disconnected",
	"bad_message",
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


func _fail_later(kind: String) -> void:
	failed.emit(kind)
	state_changed.emit()
