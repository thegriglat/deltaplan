class_name NetUiFakeBackend
extends NetUiBackend
## Подставной клиент сети для тестов и скриншотов экрана «Сетевая игра».
## outcome — чем кончится подключение: "ok" (зона code_value, пилоты fake_peers)
## или вид ошибки из NetUiBackend.ERROR_KINDS. auto_resolve = false — подключение «висит»,
## пока не вызвать resolve() (для кадра «Подключение…»).

var outcome := "ok"
var auto_resolve := true
var code_value := "4721"
## Пилоты зоны (вместе с собой: is_me = true), порядок — порядок подключения.
var fake_peers: Array = [
	{"id": "3", "name": "Папа", "join_order": 1, "is_leader": true, "is_me": false},
	{"id": "7", "name": "Мама", "join_order": 2, "is_leader": false, "is_me": false},
	{"id": "9", "name": "Alex", "join_order": 3, "is_leader": false, "is_me": true},
]

var last_address := ""
var last_name := ""
var last_code := ""
var created := false

## Счётчик вызовов stop_nearby (тесты release_to_flight, NET-40/К3).
var stop_nearby_calls := 0

## Зоны «рядом» (NET-53), подменяется тестами/скриншотами через set_nearby().
var fake_nearby: Array = []

var _busy := false
var _in_zone := false
var _params: FlightSettings


func connect_and_create(address: String, name: String, zone_params: FlightSettings) -> void:
	_start(address, name, "")
	created = true
	_params = zone_params.duplicate() if zone_params != null else FlightSettings.defaults()


func connect_and_join(address: String, name: String, zone_code: String) -> void:
	_start(address, name, zone_code)
	created = false
	_params = FlightSettings.defaults()


## Закончить подключение исходом outcome.
func resolve() -> void:
	if not _busy:
		return
	_busy = false
	if outcome == "ok":
		_in_zone = true
		zone_joined.emit(code_value if created or last_code == "" else last_code)
		peers_changed.emit()
	else:
		failed.emit(outcome)
	state_changed.emit()


## Связь пропала уже в зоне.
func drop() -> void:
	_busy = false
	_in_zone = false
	failed.emit("disconnected")
	state_changed.emit()


## Подменить список пилотов (кто-то пришёл/ушёл/сменился ведущий).
func set_peers(list: Array) -> void:
	fake_peers = list
	peers_changed.emit()


func leave() -> void:
	var was := _busy or _in_zone
	_busy = false
	_in_zone = false
	if was:
		state_changed.emit()


func code() -> String:
	if not _in_zone:
		return ""
	return code_value if created or last_code == "" else last_code


func peers() -> Array:
	return fake_peers if _in_zone else []


func is_busy() -> bool:
	return _busy


func zone_settings() -> FlightSettings:
	return _params if _in_zone else null


func nearby() -> Array:
	return fake_nearby


## Подменить список зон рядом (появилась/пропала/сменился состав).
func set_nearby(list: Array) -> void:
	fake_nearby = list
	nearby_changed.emit()


func stop_nearby() -> void:
	stop_nearby_calls += 1


func _start(address: String, name: String, zone_code: String) -> void:
	last_address = address
	last_name = name
	last_code = zone_code
	_busy = true
	_in_zone = false
	state_changed.emit()
	if auto_resolve:
		resolve.call_deferred()
