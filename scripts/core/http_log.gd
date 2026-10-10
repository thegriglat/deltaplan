class_name HttpLog
extends RefCounted
## Единая обёртка сетевых запросов игры: HTTPRequest + строка в лог (print → user://logs/godot.log и лог
## в папке игры). Две строки на запрос:
##   HTTP > #12 GET example.org/api/tile [dem tile 1/5]
##   HTTP < #12 200 48213B 1.42s [dem tile 1/5]
##   HTTP < #12 ошибка result=2 (RESULT_CANT_CONNECT) http=0 0B 0.05s [...]
## Секреты: query-часть URL и заголовки в лог не попадают (только хост+путь); тело обрезается.

const BODY_MAX := 80

static var _seq: int = 0


## Запрос под узлом host. Возвращает Array как request_completed: [result, код, заголовки, тело].
## label — короткая метка («dem tile 1/5», «dem tile»); track — массив, куда кладётся HTTPRequest
## (для отмены владельцем). При ошибке отправки/без узла — [RESULT_CANT_CONNECT, 0, [], []].
static func fetch(host: Node, url: String, headers: PackedStringArray, label: String = "",
		method: int = HTTPClient.METHOD_GET, body: String = "", timeout_s: float = 30.0,
		track: Array = []) -> Array:
	_seq += 1
	var id := _seq
	var t0 := Time.get_ticks_msec()
	log_start(id, method, url, label, body)
	var res: Array
	if host == null or not host.is_inside_tree():
		res = [HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray()]
		log_end(id, res, t0, label, "нет узла в дереве")
		return res
	var req := HTTPRequest.new()
	req.timeout = timeout_s
	req.use_threads = true  # TLS и чтение ответа — не в главном потоке
	host.add_child(req)
	track.append(req)
	var err := req.request(url, headers, method, body)
	if err != OK:
		track.erase(req)
		req.queue_free()
		res = [HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray()]
		log_end(id, res, t0, label, "request() " + error_string(err))
		return res
	res = await req.request_completed
	track.erase(req)
	if is_instance_valid(req):
		req.queue_free()
	log_end(id, res, t0, label)
	return res


static func log_start(id: int, method: int, url: String, label: String, body: String = "") -> void:
	var s := "HTTP > #%d %s %s" % [id, _method_name(method), short_url(url)]
	if label != "":
		s += " [%s]" % label
	if body != "":
		s += " body=%dB \"%s\"" % [body.length(), summarize_body(body)]
	print(s)


static func log_end(id: int, res: Array, t0_msec: int, label: String = "", note: String = "") -> void:
	var secs := (Time.get_ticks_msec() - t0_msec) / 1000.0
	var result := int(res[0])
	var code := int(res[1])
	var size := (res[3] as PackedByteArray).size() if res.size() > 3 else 0
	var s := "HTTP < #%d " % id
	if result == HTTPRequest.RESULT_SUCCESS:
		s += "%d %dB %.2fs" % [code, size, secs]
	else:
		s += "ошибка result=%d (%s) http=%d %dB %.2fs" % [result, result_name(result), code, size, secs]
	if label != "":
		s += " [%s]" % label
	if note != "":
		s += " " + note
	print(s)


## Хост+путь без схемы, query и userinfo (токены/ключи в URL не попадают в лог).
static func short_url(url: String) -> String:
	var s := url
	var i := s.find("://")
	if i >= 0:
		s = s.substr(i + 3)
	for sep in ["?", "#"]:
		var q := s.find(sep)
		if q >= 0:
			s = s.substr(0, q)
	var at := s.find("@")
	if at >= 0 and at < s.find("/"):
		s = s.substr(at + 1)
	return s


## Тело запроса: форма data=… — раскодировать и обрезать, прочее — обрезать; ключи маскируются.
static func summarize_body(body: String) -> String:
	var s := body
	if s.begins_with("data="):
		s = s.substr(5).uri_decode()
	s = s.replace("\n", " ")
	var rx := RegEx.create_from_string("(?i)(token|key|secret|password|apikey)=[^&\\s]+")
	s = rx.sub(s, "$1=***", true)
	if s.length() > BODY_MAX:
		s = s.substr(0, BODY_MAX) + "…"
	return s


static func result_name(r: int) -> String:
	var names := ["SUCCESS", "CHUNKED_BODY_SIZE_MISMATCH", "CANT_CONNECT", "CANT_RESOLVE", "CONNECTION_ERROR",
		"TLS_HANDSHAKE_ERROR", "NO_RESPONSE", "BODY_SIZE_LIMIT_EXCEEDED", "BODY_DECOMPRESS_FAILED",
		"REQUEST_FAILED", "DOWNLOAD_FILE_CANT_OPEN", "DOWNLOAD_FILE_WRITE_ERROR", "REDIRECT_LIMIT_REACHED",
		"TIMEOUT"]
	return names[r] if r >= 0 and r < names.size() else "?"


static func _method_name(m: int) -> String:
	var names := ["GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS", "TRACE", "CONNECT", "PATCH"]
	return names[m] if m >= 0 and m < names.size() else str(m)
