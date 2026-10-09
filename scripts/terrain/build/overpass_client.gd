class_name OverpassClient
extends RefCounted
## Клиент Overpass API для стадии OSM (OA-К3, OA-4, OA-9): запросы по слоям (как QUERIES в
## tools/osm/fetch_osm.py), последовательно; зеркала по очереди; при 429/504 (и 500 с признаком
## таймаута/нагрузки) — одна повторная попытка после паузы; ответ с remark "runtime error" — отказ
## зеркала. Слои roads/buildings при полном отказе запрашиваются четырьмя тайлами квадрата.

const LAYERS: Array[String] = ["roads", "buildings", "power", "water", "places", "landuse"]
const TILED: Array[String] = ["roads", "buildings"]
const LAYER_BODIES := {
	"roads": 'way["highway"]({bbox});',
	"buildings": 'way["building"]({bbox});',
	"power": 'way["power"~"^(line|minor_line)$"]({bbox});node["power"~"^(tower|pole)$"]({bbox});',
	"water": ('way["waterway"~"^(river|stream|canal)$"]({bbox});'
		+ 'way["natural"="water"]({bbox});relation["natural"="water"]({bbox});'),
	"places": 'node["place"~"^(city|town|village|hamlet|suburb|isolated_dwelling)$"]({bbox});',
	"landuse": ('way["landuse"~"^(meadow|grass|farmland)$"]({bbox});'
		+ 'way["barrier"~"^(fence|wall)$"]({bbox});'),
}
const MAXSIZE := 536870912

## Шов для тестов: Callable(url: String, headers: PackedStringArray, body: String) -> Array в формате
## request_completed [result, код, заголовки, тело]. Пусто — реальный HTTP.
var http_hook: Callable = Callable()
## Пауза перед повтором при 429/504, с (Retry-After важнее, но не больше max_retry_after_s).
var retry_pause_s: float = 8.0
## Попыток на зеркало при 429/504: живой Overpass часто даёт 504 ("open64: 0 Success" диспетчера) на первом
## запросе и отвечает на повторный (проверено OA-9), поэтому повторов больше одного, пауза растёт.
var max_attempts: int = 5
var max_retry_after_s: float = 30.0
## Пауза между слоями, с (вежливость к серверу, как time.sleep(2) в Python).
var layer_pause_s: float = 3.0
## Перед запросом спрашивать у сервера свободные слоты (/api/status) и ждать не дольше max_slot_wait_s.
var use_status: bool = true
var max_slot_wait_s: float = 60.0
## Последняя ошибка (по зеркалам).
var last_error: String = ""
## Статистика по запросам слоёв: [{layer, bytes, seconds, requests, mirror, tiles}].
var stats: Array = []


## Overpass QL одного слоя. bbox = [юг, запад, север, восток].
static func build_query(layer: String, bbox: Array, timeout_s: int) -> String:
	var b := ",".join(PackedStringArray([
		"%.5f" % float(bbox[0]), "%.5f" % float(bbox[1]), "%.5f" % float(bbox[2]), "%.5f" % float(bbox[3])]))
	var body: String = LAYER_BODIES[layer]
	return "[out:json][timeout:%d][maxsize:%d];(%s);out body geom;" % [timeout_s, MAXSIZE, body.replace("{bbox}", b)]


static func tiles(bbox: Array) -> Array:
	var mlat := (float(bbox[0]) + float(bbox[2])) / 2.0
	var mlon := (float(bbox[1]) + float(bbox[3])) / 2.0
	return [[bbox[0], bbox[1], mlat, mlon], [bbox[0], mlon, mlat, bbox[3]],
		[mlat, bbox[1], bbox[2], mlon], [mlat, mlon, bbox[2], bbox[3]]]


## Все слои квадрата. Возвращает массив тел ответов (JSON, байты) или пустой массив, если слой не удалось получить
## (причина в last_error и ctx.log_lines). ctx.net_requests растёт на каждый отправленный запрос.
func fetch_all(ctx: LocationBuildContext, urls: Array, bbox: Array, timeout_s: int, user_agent: String) -> Array:
	var bodies: Array = []
	stats = []
	for li in LAYERS.size():
		var layer := LAYERS[li]
		if li > 0:
			await _pause(ctx, layer_pause_s)
		if ctx.cancelled:
			last_error = "cancelled"
			return []
		ctx.report("osm", 0.02 + 0.38 * float(li) / LAYERS.size())
		var t0 := Time.get_ticks_msec()
		var n0 := ctx.net_requests
		var got: Array = await _fetch_layer(ctx, urls, layer, bbox, timeout_s, user_agent)
		var tiles_used := 1
		if got.is_empty() and layer in TILED and not ctx.cancelled:
			ctx.log_line("osm: слой %s не получен целиком — запрос четырьмя тайлами" % layer)
			tiles_used = 4
			for tb: Array in tiles(bbox):
				await _pause(ctx, layer_pause_s)
				var part: Array = await _fetch_layer(ctx, urls, layer, tb, timeout_s, user_agent)
				if part.is_empty():
					got = []
					break
				got.append_array(part)
		if got.is_empty():
			ctx.log_line("osm: слой %s недоступен (%s)" % [layer, last_error])
			return []
		var size := 0
		for b: PackedByteArray in got:
			size += b.size()
		stats.append({"layer": layer, "bytes": size, "seconds": (Time.get_ticks_msec() - t0) / 1000.0,
			"requests": ctx.net_requests - n0, "tiles": tiles_used})
		bodies.append_array(got)
	return bodies


## Один слой/область: по зеркалам. Возвращает [тело] или [].
func _fetch_layer(ctx: LocationBuildContext, urls: Array, layer: String, bbox: Array, timeout_s: int, ua: String) -> Array:
	var headers := PackedStringArray([
		"User-Agent: " + ua, "Content-Type: application/x-www-form-urlencoded", "Accept: application/json"])
	var form := "data=" + build_query(layer, bbox, timeout_s).uri_encode()
	for u in urls:
		var url := String(u)
		for attempt in max_attempts:
			if ctx.cancelled:
				return []
			if use_status:
				await _wait_slot(ctx, url, headers)
			ctx.net_requests += 1
			var res: Array
			if http_hook.is_valid():
				res = await http_hook.call(url, headers, form)
			else:
				res = await _http(ctx.host, url, headers, form, float(timeout_s + 30),
					HTTPClient.METHOD_POST, "overpass %s попытка %d/%d" % [layer, attempt + 1, max_attempts])
			var code := int(res[1])
			var body: PackedByteArray = res[3]
			if int(res[0]) == HTTPRequest.RESULT_SUCCESS and code == 200:
				if not _has_runtime_error(body):
					return [body]
				last_error = "%s [%s]: runtime error в ответе (remark)" % [url, layer]
				ctx.log_line("Overpass " + last_error)
				break
			last_error = "%s [%s]: result=%d http=%d %s" % [url, layer, int(res[0]), code,
				body.slice(0, 160).get_string_from_utf8().replace("\n", " ").strip_edges()]
			ctx.log_line("Overpass " + last_error)
			if attempt < max_attempts - 1 and int(res[0]) == HTTPRequest.RESULT_SUCCESS and _retryable(code, body):
				await _pause(ctx, _retry_delay(res[2]) * float(attempt + 1))
				continue
			break
	return []


## Статус сервера (…/status): ждать, пока освободится слот запроса. Ошибки статуса игнорируются.
func _wait_slot(ctx: LocationBuildContext, url: String, headers: PackedStringArray) -> void:
	if not url.ends_with("/interpreter"):
		return
	var status_url := url.trim_suffix("interpreter") + "status"
	ctx.net_requests += 1
	var res: Array
	if http_hook.is_valid():
		res = await http_hook.call(status_url, headers, "")
	else:
		res = await _http(ctx.host, status_url, headers, "", 20.0, HTTPClient.METHOD_GET, "overpass status")
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS or int(res[1]) != 200:
		return
	var wait := slot_wait_s((res[3] as PackedByteArray).get_string_from_utf8())
	if wait > 0.0:
		ctx.log_line("Overpass %s: слотов нет, жду %.0f с" % [url, minf(wait, max_slot_wait_s)])
		await _pause(ctx, minf(wait, max_slot_wait_s))


## Секунды до свободного слота по тексту /api/status (0 — слот есть или текст непонятен).
static func slot_wait_s(text: String) -> float:
	if text.find("slots available now") >= 0 or text.find("Slot available after") < 0:
		return 0.0
	var re := RegEx.create_from_string("in (\\d+) seconds")
	var best := -1.0
	for m in re.search_all(text):
		var v := float(m.get_string(1))
		if best < 0.0 or v < best:
			best = v
	return best + 1.0 if best >= 0.0 else 0.0


static func _retryable(code: int, body: PackedByteArray) -> bool:
	if code == 429 or code == 504:
		return true
	if code == 500:
		var t := body.slice(0, mini(body.size(), 2000)).get_string_from_utf8().to_lower()
		return t.find("timeout") >= 0 or t.find("timed out") >= 0 or t.find("busy") >= 0 or t.find("rate") >= 0 \
			or t.find("load") >= 0
	return false


func _retry_delay(headers: PackedStringArray) -> float:
	for h in headers:
		if h.to_lower().begins_with("retry-after:"):
			var v := h.substr(12).strip_edges()
			if v.is_valid_int():
				return clampf(float(v), 0.0, max_retry_after_s)
	return retry_pause_s


func _pause(ctx: LocationBuildContext, seconds: float) -> void:
	if seconds <= 0.0:
		return
	if ctx.host != null and ctx.host.is_inside_tree():
		await ctx.host.get_tree().create_timer(seconds).timeout


## Overpass при нехватке времени/памяти отвечает 200 с "remark": "runtime error…" и неполным списком.
static func _has_runtime_error(body: PackedByteArray) -> bool:
	var head := body.slice(0, mini(body.size(), 600)).get_string_from_utf8()
	return head.find("runtime error") >= 0


func _http(host: Node, url: String, headers: PackedStringArray, form: String, timeout_s: float,
		method := HTTPClient.METHOD_POST, label := "overpass") -> Array:
	return await HttpLog.fetch(host, url, headers, label, method, form, timeout_s)
