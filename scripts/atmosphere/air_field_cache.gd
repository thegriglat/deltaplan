class_name AirFieldCache
extends RefCounted
## Кеш поля воздуха на диске (FL-К1, docs/contracts/fast-load.md): поле, посчитанное при загрузке
## места, ложится в user://air_cache записью формата TI-К3 v3 (AirBakedField: <имя>.json — заголовок,
## <имя>.bin — float16 + zstd); при повторе места, старта и условий AirRuntime.load_field берёт его
## вместо расчёта. <имя> — первые 16 hex sha256 канонического JSON ключа (ключи по алфавиту).
## Размер — LRU по index.json, предел — atmosphere.json → air_cache.max_mb (0 — выключен).
##
## Лежит вне scripts/atmosphere/air_model/: файлы той папки входят в AirBakedField.code_hash().
## Потоки (PF-К4): store/load_record — в рабочем потоке (сцену не трогают), index.json — под общим
## замком; lookup/touch — на главном потоке (заголовок — несколько КБ).

## Номер формата кеша в ключе (key.format).
const FORMAT := 1
const DEFAULT_DIR := "user://air_cache"
const INDEX_FILE := "index.json"
const INDEX_VERSION := 1
const BYTES_PER_MB := 1048576
## Округление ключа (FL-К1): ветер 0,01 м/с, направление 0,1°, температура 0,1 °C, координаты
## места 1e-6°, старт 0,01 м.
const U10_ROUND := 0.01
const WDIR_ROUND := 0.1
const TMAX_ROUND := 0.1
const LATLON_ROUND := 1.0e-6
const START_ROUND_M := 0.01
## Запись без ответа «нет записи» — обычный промах, без строки в лог.
const MISS := "нет записи"

## Папка кеша (тесты подменяют).
var dir := DEFAULT_DIR
## Предел суммы записей, байт; 0 — кеш выключен.
var max_bytes: int = 200 * BYTES_PER_MB

## Замок index.json и списка пишущихся записей (одна папка на процесс).
static var _mutex := Mutex.new()
## Имена записей, что сейчас пишутся (их временные и непарные файлы не трогать).
static var _writing := {}
## Последнее выданное used (строго растёт: два касания в одну миллисекунду различимы).
static var _last_used := 0.0


## Кеш по конфигу: air_cache.max_mb (слои Config, в т. ч. машинный user://local/configs).
static func from_config() -> AirFieldCache:
	var c := AirFieldCache.new()
	var mb := float(Config.value("atmosphere", "air_cache.max_mb", 200.0))
	c.max_bytes = int(maxf(mb, 0.0) * BYTES_PER_MB)
	return c


func enabled() -> bool:
	return max_bytes > 0


# ---------------------------------------------------------------- ключ


## Ключ записи (FL-К1). place — loc.id встроенного места или LocationCache.key_for точки; start —
## центр окон (x, z; NAN — окон нет); cond — AirRuntime.conditions_of; step_min — срок пересчёта
## (час округляется до начала срока). extra — прочие входы поля (их список — в AirRuntime.cache_key).
static func make_key(
	place: String,
	center_lat: float,
	center_lon: float,
	data_hash: String,
	start: Vector3,
	domain_dx: float,
	window_dx: Array,
	month: int,
	day: int,
	cond: Dictionary,
	step_min: float,
	extra: Dictionary = {}
) -> Dictionary:
	var t_max := float(cond.get("t_max", NAN))
	var key := {
		"format": FORMAT,
		"place": place,
		"center": [snappedf(center_lat, LATLON_ROUND), snappedf(center_lon, LATLON_ROUND)],
		"data_hash": data_hash,
		"start": null if is_nan(start.x) else [snappedf(start.x, START_ROUND_M), snappedf(start.z, START_ROUND_M)],
		"domain_dx": domain_dx,
		"window_dx": window_dx.duplicate(),
		"month": month,
		"day": day,
		"cond":
		{
			"hour": AirRuntime.slot_hour(float(cond.get("hour", 0.0)), step_min),
			"u10": snappedf(float(cond.get("u10", 0.0)), U10_ROUND),
			"wdir": fposmod(snappedf(float(cond.get("wdir", 0.0)), WDIR_ROUND), 360.0),
			"t_max": null if is_nan(t_max) else snappedf(t_max, TMAX_ROUND),
			"sky": String(cond.get("sky", "clear")),
			"wind_ref": String(cond.get("wind_ref", "start")),
		},
	}
	for k: String in extra:
		key[k] = extra[k]
	return key


## Имя записи: первые 16 hex sha256 канонического JSON ключа (ключи словарей по алфавиту).
static func name_of(key: Dictionary) -> String:
	return JSON.stringify(key, "", true).sha256_text().substr(0, 16)


func path_of(rec_name: String) -> String:
	return dir.path_join(rec_name + ".json")


# ---------------------------------------------------------------- чтение


## Есть ли годная запись для key: {name, path, header, reason ("" — есть; MISS — нет записи)}. Чужой
## model_hash, нечитаемый заголовок, несовпавший key → запись удаляется (push_warning), промах.
func lookup(key: Dictionary) -> Dictionary:
	var rec := name_of(key)
	var out := {name = rec, path = path_of(rec), header = {}, reason = ""}
	if not enabled():
		out.reason = "кеш выключен"
		return out
	var base := dir.path_join(rec)
	if not FileAccess.file_exists(base + ".json"):
		out.reason = MISS
		return out
	var h := AirBakedField.read_header(base)
	var why := ""
	if h.is_empty():
		why = "заголовок не читается"
	elif int(h.get("cache", 0)) != FORMAT:
		why = "не запись кеша"
	elif not AirBakedField.model_hash_ok(h):
		why = "модель воздуха другой версии (хеш %s ≠ %s)" % [h.get("model_hash", "?"), AirBakedField.model_hash()]
	else:
		var d := AirBakedField.key_diff(h.get("key"), key)
		if d != "":
			why = "key не совпал (%s)" % d
	if why != "":
		push_warning("AirFieldCache: запись %s — %s, удалена" % [rec, why])
		remove(rec)
		out.reason = why
		return out
	out.header = h
	return out


## Набор уровней записи, найденной lookup (рабочий поток допустим). null — тело не читается: запись
## удаляется (push_warning).
func load_record(look: Dictionary) -> AirFieldSet:
	var fs := AirBakedField.load_file(String(look.path))
	if fs == null:
		push_warning("AirFieldCache: запись %s не читается — удалена" % look.name)
		remove(String(look.name))
	return fs


## Поле по ключу целиком (lookup + load_record); null — промах.
func load_key(key: Dictionary) -> AirFieldSet:
	var look := lookup(key)
	if look.reason != "":
		return null
	var fs := load_record(look)
	if fs != null:
		touch(String(look.name))
	return fs


## Попадание: used записи — сейчас.
func touch(rec_name: String) -> void:
	_mutex.lock()
	var idx := _index()
	var ent: Variant = (idx.entries as Dictionary).get(rec_name)
	if ent is Dictionary:
		ent["used"] = _now()
		_write_index(idx)
	_mutex.unlock()


# ---------------------------------------------------------------- запись


## Снимок уровней для записи в рабочем потоке: новые WindField с теми же массивами (PackedArray —
## копия при записи, поданное поле не меняется) и копией meta. Главный поток, доли миллисекунды.
static func snapshot(levels: Array) -> AirFieldSet:
	var out: Array[WindField] = []
	for f: WindField in levels:
		var s := WindField.new()
		s.dx = f.dx
		s.dz = f.dz
		s.x0 = f.x0
		s.y0 = f.y0
		s.z_bot = f.z_bot
		s.nx = f.nx
		s.ny = f.ny
		s.nz = f.nz
		s.meta = f.meta.duplicate(true)
		s._vel = f._vel
		s._wconv = f._wconv
		s._theta = f._theta
		s._hc = f._hc
		out.append(s)
	var fs := AirFieldSet.new()
	fs.levels = out
	return fs


## Записать набор (рабочий поток): тело и заголовок TI-К3 (временный файл + переименование), затем
## index.json и вытеснение сверх предела. header_extra — в заголовок (status, inflow_k, …). true —
## записано.
func store(fs: AirFieldSet, key: Dictionary, header_extra: Dictionary = {}) -> bool:
	if not enabled() or fs == null or fs.levels.is_empty():
		return false
	var mh := AirBakedField.model_hash()
	if mh == "":
		return false  # хеша кода нет — запись всё равно не взялась бы
	var rec := name_of(key)
	_mutex.lock()
	if _writing.has(rec):
		_mutex.unlock()
		return false
	_writing[rec] = true
	_mutex.unlock()
	var header := {
		"location": String(key.get("place", "")),
		"site": "",
		"key": key,
		"model_hash": mh,
		"cache": FORMAT,
	}
	header.merge(header_extra, false)
	DirAccess.make_dir_recursive_absolute(dir)
	var ok := AirBakedField.save(fs, header, path_of(rec))
	_mutex.lock()
	_writing.erase(rec)
	var idx := _index()
	if ok:
		idx.entries[rec] = {"bytes": _record_bytes(rec), "used": _now()}
		_evict(idx)
	else:
		for ext in [".json", ".bin", ".json.tmp", ".bin.tmp"]:
			DirAccess.remove_absolute(dir.path_join(rec + ext))
	_write_index(idx)
	_mutex.unlock()
	return ok


## Удалить запись (файлы и строку индекса).
func remove(rec_name: String) -> void:
	_mutex.lock()
	_remove_files(rec_name)
	var idx := _index()
	(idx.entries as Dictionary).erase(rec_name)
	_write_index(idx)
	_mutex.unlock()


## Записи индекса (копия): {<имя>: {bytes, used}}; индекс сверяется с папкой.
func entries() -> Dictionary:
	_mutex.lock()
	var idx := _index()
	_write_index(idx)
	_mutex.unlock()
	return (idx.entries as Dictionary).duplicate(true)


## Сумма bytes записей.
func total_bytes() -> int:
	var n := 0
	for e: Dictionary in entries().values():
		n += int(e.bytes)
	return n


# ---------------------------------------------------------------- индекс (под замком)


func _now() -> float:
	var t := Time.get_unix_time_from_system()
	_last_used = maxf(t, _last_used + 0.001)
	return _last_used


func _record_bytes(rec_name: String) -> int:
	return _file_size(dir.path_join(rec_name + ".json")) + _file_size(dir.path_join(rec_name + ".bin"))


static func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_length() if f != null else 0


func _remove_files(rec_name: String) -> void:
	for ext in [".json", ".bin", ".json.tmp", ".bin.tmp"]:
		var p := dir.path_join(rec_name + ext)
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


## index.json, сверенный с папкой: нет или испорчен — восстановить по файлам (used = время
## изменения); строки без файлов — убрать; пары без строки — добавить; файлы без пары и временные —
## удалить (кроме пишущихся сейчас).
func _index() -> Dictionary:
	var entries := {}
	var ipath := dir.path_join(INDEX_FILE)
	var broken := false
	if FileAccess.file_exists(ipath):
		var parser := JSON.new()
		var js: Variant = null
		if parser.parse(FileAccess.get_file_as_string(ipath)) == OK:
			js = parser.data
		if js is Dictionary and int((js as Dictionary).get("version", -1)) == INDEX_VERSION and js.get("entries") is Dictionary:
			for k: Variant in js.entries:
				var e: Variant = js.entries[k]
				if e is Dictionary and (e.get("bytes") is float or e.get("bytes") is int) and (e.get("used") is float or e.get("used") is int):
					entries[String(k)] = {"bytes": int(e.bytes), "used": float(e.used)}
				else:
					broken = true
		else:
			broken = true
	var jsons := {}
	var bins := {}
	var files := DirAccess.get_files_at(dir) if DirAccess.dir_exists_absolute(dir) else PackedStringArray()
	for f in files:
		var busy := _writing.has(f.get_slice(".", 0))
		if f == INDEX_FILE:
			continue
		if f.ends_with(".tmp"):
			if not busy:
				DirAccess.remove_absolute(dir.path_join(f))
		elif f.ends_with(".json"):
			jsons[f.get_basename()] = true
		elif f.ends_with(".bin"):
			bins[f.get_basename()] = true
		elif not busy:
			DirAccess.remove_absolute(dir.path_join(f))
	for n: String in jsons.keys() + bins.keys():
		if jsons.has(n) and bins.has(n):
			continue
		if not _writing.has(n):
			_remove_files(n)
	for n: String in entries.keys():
		if not (jsons.has(n) and bins.has(n)):
			entries.erase(n)
	for n: String in jsons:
		if bins.has(n) and not entries.has(n):
			var mt := FileAccess.get_modified_time(dir.path_join(n + ".json"))
			entries[n] = {"bytes": _record_bytes(n), "used": float(mt)}
	if broken:
		push_warning("AirFieldCache: %s испорчен — восстановлен по файлам (%d записей)" % [ipath, entries.size()])
	return {"version": INDEX_VERSION, "entries": entries}


## Пока сумма bytes больше предела — удалить запись с наименьшим used.
func _evict(idx: Dictionary) -> void:
	var ents: Dictionary = idx.entries
	var total := 0
	for e: Dictionary in ents.values():
		total += int(e.bytes)
	while total > max_bytes and not ents.is_empty():
		var oldest := ""
		var t := INF
		for n: String in ents:
			if float(ents[n].used) < t:
				t = float(ents[n].used)
				oldest = n
		total -= int(ents[oldest].bytes)
		ents.erase(oldest)
		_remove_files(oldest)
		print("air_cache: вытеснена запись %s (предел %d МБ)" % [oldest, max_bytes / BYTES_PER_MB])


func _write_index(idx: Dictionary) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var p := dir.path_join(INDEX_FILE)
	var tmp := p + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("AirFieldCache: не записать %s (%s)" % [tmp, error_string(FileAccess.get_open_error())])
		return
	f.store_string(JSON.stringify(idx, "\t", true))
	f.close()
	if DirAccess.rename_absolute(tmp, p) != OK:
		push_warning("AirFieldCache: не переименовать %s" % tmp)
