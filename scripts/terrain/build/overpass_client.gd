class_name OverpassClient
extends RefCounted
## Клиент Overpass API для стадии OSM (OA-К3, OA-4): один объединённый запрос на квадрат,
## зеркала по очереди (каждое — один раз, без циклов повторов), User-Agent, таймаут.
## Те же слои, что QUERIES в tools/osm/fetch_osm.py.

const LAYER_BODIES: Array[String] = [
	'way["highway"]({bbox});',
	'way["building"]({bbox});',
	'way["power"~"^(line|minor_line)$"]({bbox});node["power"~"^(tower|pole)$"]({bbox});',
	('way["waterway"~"^(river|stream|canal)$"]({bbox});'
		+ 'way["natural"="water"]({bbox});relation["natural"="water"]({bbox});'),
	'node["place"~"^(city|town|village|hamlet|suburb|isolated_dwelling)$"]({bbox});',
	('way["landuse"~"^(meadow|grass|farmland)$"]({bbox});'
		+ 'way["barrier"~"^(fence|wall)$"]({bbox});'),
]

## Шов для тестов: Callable(url: String, headers: PackedStringArray, body: String) -> Array в формате
## request_completed [result, код, заголовки, тело]. Пусто — реальный HTTP.
var http_hook: Callable = Callable()
## Последняя ошибка (по зеркалам).
var last_error: String = ""
## Какое зеркало ответило.
var used_url: String = ""


## Overpass QL: все слои одним запросом. bbox = [юг, запад, север, восток].
static func build_query(bbox: Array, timeout_s: int) -> String:
	var b := ",".join(PackedStringArray([
		"%.5f" % float(bbox[0]), "%.5f" % float(bbox[1]), "%.5f" % float(bbox[2]), "%.5f" % float(bbox[3])]))
	var body := ""
	for part in LAYER_BODIES:
		body += part.replace("{bbox}", b)
	return "[out:json][timeout:%d];(%s);out body geom;" % [timeout_s, body]


## Запрос к зеркалам по очереди. Возвращает тело ответа (JSON, байты); пусто — все зеркала отказали
## (причина в last_error). ctx.net_requests растёт на каждый отправленный запрос.
func fetch(ctx: LocationBuildContext, urls: Array, query: String, timeout_s: float, user_agent: String) -> PackedByteArray:
	var headers := PackedStringArray([
		"User-Agent: " + user_agent, "Content-Type: application/x-www-form-urlencoded", "Accept: application/json"])
	var form := "data=" + query.uri_encode()
	last_error = ""
	for u in urls:
		if ctx.cancelled:
			last_error = "cancelled"
			return PackedByteArray()
		var url := String(u)
		ctx.net_requests += 1
		var res: Array
		if http_hook.is_valid():
			res = await http_hook.call(url, headers, form)
		else:
			res = await _http(ctx.host, url, headers, form, timeout_s)
		var code := int(res[1])
		if int(res[0]) != HTTPRequest.RESULT_SUCCESS or code != 200:
			last_error = "%s: result=%d http=%d" % [url, int(res[0]), code]
			ctx.log_line("Overpass " + last_error)
			continue
		var body: PackedByteArray = res[3]
		if _has_runtime_error(body):
			last_error = "%s: runtime error в ответе (remark)" % url
			ctx.log_line("Overpass " + last_error)
			continue
		used_url = url
		return body
	return PackedByteArray()


## Overpass при нехватке времени/памяти отвечает 200 с "remark": "runtime error…" и неполным списком.
static func _has_runtime_error(body: PackedByteArray) -> bool:
	# remark стоит в начале ответа, до "elements"; смотрим только голову.
	var head := body.slice(0, mini(body.size(), 600)).get_string_from_utf8()
	return head.find("runtime error") >= 0 or (head.find('"remark"') >= 0 and head.find("timed out") >= 0)


func _http(host: Node, url: String, headers: PackedStringArray, form: String, timeout_s: float) -> Array:
	if host == null or not host.is_inside_tree():
		return [HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray()]
	var req := HTTPRequest.new()
	req.timeout = timeout_s
	req.use_threads = true
	host.add_child(req)
	if req.request(url, headers, HTTPClient.METHOD_POST, form) != OK:
		req.queue_free()
		return [HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray()]
	var res: Array = await req.request_completed
	req.queue_free()
	return res
