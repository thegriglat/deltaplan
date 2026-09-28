class_name NetTestServer
extends RefCounted
## Локальный Go-сервер сетевой игры для тестов (NET-30, NET-31, NET-32).
##
##   if not NetTestServer.available():
##       check(NetTestServer.build_error == "", NetTestServer.build_error)  # сборка упала
##       print("SKIP: ", NetTestServer.skip_reason)
##       return
##   var srv := NetTestServer.new()
##   if not srv.start():             # собирает бинарник (один раз за прогон), порт, /healthz
##       check(false, srv.last_error)
##   client.connect_to_server(srv.address, "Пилот")   # "127.0.0.1:<порт>"
##   srv.stop()                      # убить процесс (обрыв для клиентов)
##   srv.start(srv.port)             # поднять снова на том же порту
##
## Сборка: go -C server build -o <temp>/deltaplan-server ./cmd/deltaplan-server; запуск:
## deltaplan-server -addr 127.0.0.1:<порт>, лог — <temp>/server-<порт>.log. start() и stop()
## синхронные (ждут /healthz / завершения процесса, до нескольких секунд).
## Нет go или исходников сервера → available() = false, тест печатает SKIP и проходит.

const SERVER_DIR := "res://server"
const PORT_MIN := 20000
const PORT_MAX := 40000
const START_TRIES := 5
const HEALTH_TIMEOUT_MS := 5000

## Причина, по которой сервер недоступен (для SKIP).
static var skip_reason := ""
## Go есть, но сборка упала — это не SKIP, а падение теста.
static var build_error := ""
static var _binary := ""
static var _checked := false

var port := 0
var address := ""
var pid := -1
var last_error := ""


## Есть go и исходники; бинарник собран (сборка — при первом вызове за прогон).
static func available() -> bool:
	if not _checked:
		_checked = true
		_binary = _build()
	return _binary != ""


## Запустить сервер. port_hint > 0 — именно этот порт (перезапуск), иначе случайный свободный.
func start(port_hint: int = 0) -> bool:
	if not available():
		last_error = "server unavailable: " + skip_reason
		return false
	stop()
	var tries := 1 if port_hint > 0 else START_TRIES
	for i in tries:
		var p := port_hint if port_hint > 0 else randi_range(PORT_MIN, PORT_MAX)
		if _start_on(p):
			return true
	return false


## Убить процесс сервера (клиенты видят обрыв соединения).
func stop() -> void:
	if pid <= 0:
		return
	# OS.kill на Linux/macOS — SIGKILL и waitpid: по возврату процесса уже нет
	OS.kill(pid)
	pid = -1


func is_running() -> bool:
	return pid > 0 and OS.is_process_running(pid)


func _start_on(p: int) -> bool:
	var dir := _binary.get_base_dir()
	var log_path := dir.path_join("server-%d.log" % p)
	var args := ["-addr", "127.0.0.1:%d" % p]
	if OS.get_name() == "Windows":
		pid = OS.create_process(_binary, args)
	else:
		# через sh только ради перенаправления лога; exec — pid остаётся тем же
		var cmd := "exec '%s' %s > '%s' 2>&1" % [_binary, " ".join(args), log_path]
		pid = OS.create_process("sh", ["-c", cmd])
	if pid <= 0:
		last_error = "create_process failed"
		return false
	var deadline := Time.get_ticks_msec() + HEALTH_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		if not OS.is_process_running(pid):
			last_error = "server exited on port %d (log: %s)" % [p, log_path]
			pid = -1
			return false
		if _healthz(p):
			port = p
			address = "127.0.0.1:%d" % p
			return true
		OS.delay_msec(50)
	last_error = "no /healthz on port %d within %d ms (log: %s)" % [p, HEALTH_TIMEOUT_MS, log_path]
	stop()
	return false


## GET /healthz → 200.
static func _healthz(p: int) -> bool:
	var http := HTTPClient.new()
	if http.connect_to_host("127.0.0.1", p) != OK:
		return false
	var deadline := Time.get_ticks_msec() + 500
	var requested := false
	while Time.get_ticks_msec() < deadline:
		http.poll()
		var st := http.get_status()
		if st in [
			HTTPClient.STATUS_CANT_CONNECT,
			HTTPClient.STATUS_CANT_RESOLVE,
			HTTPClient.STATUS_CONNECTION_ERROR,
		]:
			return false
		if not requested and st == HTTPClient.STATUS_CONNECTED:
			if http.request(HTTPClient.METHOD_GET, "/healthz", []) != OK:
				return false
			requested = true
		elif requested and http.has_response():
			return http.get_response_code() == 200
		OS.delay_msec(5)
	return false


## Собрать бинарник во временную папку; "" и skip_reason, если нельзя.
static func _build() -> String:
	var src := ProjectSettings.globalize_path(SERVER_DIR)
	if not DirAccess.dir_exists_absolute(src.path_join("cmd/deltaplan-server")):
		skip_reason = "no server sources at %s/cmd/deltaplan-server" % src
		return ""
	var go := _find_go()
	if go == "":
		skip_reason = "go not found"
		return ""
	var dir := OS.get_temp_dir().path_join("deltaplan-net-test-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(dir)
	var bin := dir.path_join("deltaplan-server" + (".exe" if OS.get_name() == "Windows" else ""))
	var out := []
	var code := OS.execute(go, ["-C", src, "build", "-o", bin, "./cmd/deltaplan-server"], out, true)
	if code != 0:
		build_error = "go build failed (%d): %s" % [code, "".join(out)]
		return ""
	return bin


static func _find_go() -> String:
	for cand in ["go", "/usr/local/go/bin/go", OS.get_environment("HOME").path_join("go/bin/go")]:
		var out := []
		if OS.execute(cand, ["version"], out, true) == 0:
			return cand
	return ""
