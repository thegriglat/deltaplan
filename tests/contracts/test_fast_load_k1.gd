extends TestCase
## Контракт FL-К1 (docs/contracts/fast-load.md): кеш поля воздуха на диске — имя записи (sha256[:16]
## канонического ключа), ключ и его округление, запись → чтение в формате TI-К3 (float16, ≤ 0,01 м/с),
## чужой model_hash / испорченный .bin / испорченный index.json, LRU по used, max_mb = 0 — выключен,
## публичное AirRuntime (cache_ready, cache_enabled), настройка — машинный ключ.

const K3 := preload("res://tests/contracts/test_training_island_k3.gd")
const DIR := "user://fl_k1_cache"
const TOL_MS := 0.01


func _cache(max_mb: float = 200.0) -> AirFieldCache:
	var c := AirFieldCache.new()
	c.dir = DIR
	c.max_bytes = int(max_mb * AirFieldCache.BYTES_PER_MB)
	return c


func _clean() -> void:
	if not DirAccess.dir_exists_absolute(DIR):
		return
	for f in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(DIR.path_join(f))


static func cond(u10: float = 3.0) -> Dictionary:
	return {hour = 12.2, u10 = u10, wdir = 150.04, t_max = 25.03, sky = "clear", wind_ref = "start"}


static func key(u10: float = 3.0) -> Dictionary:
	return AirFieldCache.make_key(
		"ongudai", 50.75, 86.15, "0123456789abcdef", Vector3(120.004, 900.0, -310.5), 400.0,
		[100.0, 50.0], 7, 15, cond(u10), 15.0, {"utc": 7.0, "surface": ""}
	)


func _err(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.size() != b.size():
		return INF
	var e := 0.0
	for q in a.size():
		e = maxf(e, absf(a[q] - b[q]))
	return e


func test_k1_key_and_name() -> void:
	var k := key()
	for f in ["format", "place", "center", "data_hash", "start", "domain_dx", "window_dx", "month", "day", "cond"]:
		check(k.has(f), "ключ: поле %s" % f)
	for f in ["hour", "u10", "wdir", "t_max", "sky", "wind_ref"]:
		check((k.cond as Dictionary).has(f), "ключ: cond.%s" % f)
	check(int(k.format) == 1, "format = 1")
	check(is_equal_approx(float(k.cond.hour), 12.0), "час — начало срока 15 мин: %s" % k.cond.hour)
	check(is_equal_approx(float(k.cond.wdir), 150.0), "направление — 0,1°: %s" % k.cond.wdir)
	check(is_equal_approx(float(k.cond.t_max), 25.0), "температура — 0,1 °C: %s" % k.cond.t_max)
	check(k.start == [120.0, -310.5], "старт — x, z, 0,01 м: %s" % [k.start])
	var nm := AirFieldCache.name_of(k)
	check(nm == JSON.stringify(k, "", true).sha256_text().substr(0, 16), "имя = sha256[:16] канонического JSON")
	check(nm.length() == 16, "16 hex")
	# порядок ключей словаря не важен
	var shuffled := {}
	var names := k.keys()
	names.reverse()
	for n: String in names:
		shuffled[n] = k[n]
	check(AirFieldCache.name_of(shuffled) == nm, "имя не зависит от порядка ключей")
	check(AirFieldCache.name_of(key(3.004)) == nm, "u10 округляется до 0,01 м/с")
	check(AirFieldCache.name_of(key(3.02)) != nm, "другой ветер — другая запись")
	var c2 := cond()
	c2.hour = 12.3  # 12:18 — следующий срок
	var k2 := AirFieldCache.make_key(
		"ongudai", 50.75, 86.15, "0123456789abcdef", Vector3(120.004, 900.0, -310.5), 400.0,
		[100.0, 50.0], 7, 15, c2, 15.0, {"utc": 7.0, "surface": ""}
	)
	check(AirFieldCache.name_of(k2) != nm, "другой срок — другая запись")
	var c3 := cond()
	c3.t_max = NAN
	var k3 := AirFieldCache.make_key("x", 0, 0, "h", Vector3(NAN, NAN, NAN), 400.0, [], 0, 0, c3, 15.0)
	check(k3.start == null and k3.cond.t_max == null, "NAN → null (JSON)")


func test_k1_roundtrip() -> void:
	_clean()
	var c := _cache()
	var src := K3.synthetic_set()
	check(c.store(src, key(), {status = "not_converged", inflow_k = 0.85}), "запись")
	var nm := AirFieldCache.name_of(key())
	check(FileAccess.file_exists(DIR.path_join(nm + ".json")), "<имя>.json")
	check(FileAccess.file_exists(DIR.path_join(nm + ".bin")), "<имя>.bin")
	check(not FileAccess.file_exists(DIR.path_join(nm + ".bin.tmp")), "временных файлов нет")
	var h := AirBakedField.read_header(DIR.path_join(nm))
	check(h.get("format") == AirBakedField.FORMAT and int(h.get("version", 0)) == AirBakedField.VERSION, "формат TI-К3")
	check(int(h.get("cache", 0)) == 1, "cache: 1")
	check(h.get("status") == "not_converged", "status")
	check(String(h.get("model_hash", "")) == AirBakedField.model_hash(), "model_hash")
	check(AirBakedField.key_diff(h.get("key"), key()) == "", "key в заголовке")
	var ix: Variant = JSON.parse_string(FileAccess.get_file_as_string(DIR.path_join("index.json")))
	check(ix is Dictionary and int(ix.version) == 1 and (ix.entries as Dictionary).has(nm), "index.json: запись")
	if ix is Dictionary and (ix.entries as Dictionary).has(nm):
		var e: Dictionary = ix.entries[nm]
		var bytes := AirFieldCache._file_size(DIR.path_join(nm + ".json")) + AirFieldCache._file_size(DIR.path_join(nm + ".bin"))
		check(int(e.bytes) == bytes, "bytes = размер .json + .bin")
		check(float(e.used) > 1.0e9, "used — unix, с")
	var look := c.lookup(key())
	check(look.reason == "", "lookup: попадание (%s)" % look.reason)
	check(c.lookup(key(4.0)).reason == AirFieldCache.MISS, "другой ключ — промах")
	var got := c.load_key(key())
	check(got != null and got.levels.size() == src.levels.size(), "чтение: те же уровни")
	if got == null:
		return
	for q in src.levels.size():
		var a: WindField = src.levels[q]
		var b: WindField = got.levels[q]
		var e := maxf(_err(a._vel, b._vel), _err(a._wconv, b._wconv))
		check(e <= TOL_MS, "уровень %d: |Δu,v,w| %.5f ≤ %.2f м/с" % [q, e, TOL_MS])
		check(_err(a._theta, b._theta) <= 0.01, "уровень %d: θ в пределах float16" % q)
		check(a._hc == b._hc, "уровень %d: рельеф побитно" % q)
	_clean()


func test_k1_foreign_model_hash() -> void:
	_clean()
	var c := _cache()
	check(c.store(K3.synthetic_set(), key(), {status = "ok"}), "запись")
	var nm := AirFieldCache.name_of(key())
	var hp := DIR.path_join(nm + ".json")
	var h: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(hp))
	h.model_hash = "0000000000000000"
	var f := FileAccess.open(hp, FileAccess.WRITE)
	f.store_string(JSON.stringify(h))
	f.close()
	check(c.lookup(key()).reason != "", "чужой model_hash — промах")
	check(not FileAccess.file_exists(hp) and not FileAccess.file_exists(DIR.path_join(nm + ".bin")), "запись удалена")
	check(not c.entries().has(nm), "строка индекса удалена")
	_clean()


func test_k1_corrupt_bin() -> void:
	_clean()
	var c := _cache()
	check(c.store(K3.synthetic_set(), key(), {status = "ok"}), "запись")
	var nm := AirFieldCache.name_of(key())
	var f := FileAccess.open(DIR.path_join(nm + ".bin"), FileAccess.WRITE)
	f.store_string("не zstd")
	f.close()
	check(c.load_key(key()) == null, "испорченный .bin — промах без падения")
	check(not FileAccess.file_exists(DIR.path_join(nm + ".json")), "запись удалена")
	# испорченный заголовок
	check(c.store(K3.synthetic_set(), key(), {status = "ok"}), "запись снова")
	f = FileAccess.open(DIR.path_join(nm + ".json"), FileAccess.WRITE)
	f.store_string("{не json")
	f.close()
	check(c.lookup(key()).reason != "", "испорченный заголовок — промах")
	check(not FileAccess.file_exists(DIR.path_join(nm + ".bin")), "запись удалена")
	_clean()


func test_k1_lru() -> void:
	_clean()
	var probe := _cache()
	check(probe.store(K3.synthetic_set(), key(1.0), {status = "ok"}), "запись A")
	var one := probe.total_bytes()
	check(one > 0, "размер записи: %d байт" % one)
	_clean()
	var c := _cache()
	c.max_bytes = int(2.5 * one)  # предел — на 2 записи
	var a := AirFieldCache.name_of(key(1.0))
	var b := AirFieldCache.name_of(key(2.0))
	var d := AirFieldCache.name_of(key(3.0))
	check(c.store(K3.synthetic_set(), key(1.0), {status = "ok"}), "A")
	check(c.store(K3.synthetic_set(), key(2.0), {status = "ok"}), "B")
	var used_a := float(c.entries()[a].used)
	check(c.load_key(key(1.0)) != null, "попадание A")
	check(float(c.entries()[a].used) > used_a, "попадание обновило used")
	check(c.store(K3.synthetic_set(), key(3.0), {status = "ok"}), "C")
	var e := c.entries()
	check(e.has(a) and e.has(d), "A (использована) и C (новая) остались: %s" % [e.keys()])
	check(not e.has(b), "B — самая давно использованная — вытеснена")
	check(not FileAccess.file_exists(DIR.path_join(b + ".bin")), "файлы B удалены")
	check(c.total_bytes() <= c.max_bytes, "сумма в пределе")
	_clean()


func test_k1_index_rebuilt() -> void:
	_clean()
	var c := _cache()
	check(c.store(K3.synthetic_set(), key(1.0), {status = "ok"}), "A")
	check(c.store(K3.synthetic_set(), key(2.0), {status = "ok"}), "B")
	var f := FileAccess.open(DIR.path_join("index.json"), FileAccess.WRITE)
	f.store_string("[мусор")
	f.close()
	# мусор: временный файл и тело без заголовка
	for n in ["zzzz.bin.tmp", "ffffffffffffffff.bin"]:
		f = FileAccess.open(DIR.path_join(n), FileAccess.WRITE)
		f.store_string("x")
		f.close()
	var e := c.entries()
	check(e.size() == 2, "индекс восстановлен по файлам: %s" % [e.keys()])
	for n in [AirFieldCache.name_of(key(1.0)), AirFieldCache.name_of(key(2.0))]:
		check(e.has(n) and int(e[n].bytes) > 0 and float(e[n].used) > 0.0, "запись %s: bytes, used" % n)
	check(not FileAccess.file_exists(DIR.path_join("zzzz.bin.tmp")), "временный файл удалён")
	check(not FileAccess.file_exists(DIR.path_join("ffffffffffffffff.bin")), "файл без пары удалён")
	var ix: Variant = JSON.parse_string(FileAccess.get_file_as_string(DIR.path_join("index.json")))
	check(ix is Dictionary and int(ix.version) == 1, "index.json снова целый")
	check(c.load_key(key(1.0)) != null, "запись читается")
	_clean()


func test_k1_disabled() -> void:
	_clean()
	var c := _cache(0.0)
	check(not c.enabled(), "max_mb = 0 — выключен")
	check(not c.store(K3.synthetic_set(), key(), {status = "ok"}), "не пишет")
	check(not FileAccess.file_exists(DIR.path_join(AirFieldCache.name_of(key()) + ".json")), "файлов нет")
	var on := _cache()
	check(on.store(K3.synthetic_set(), key(), {status = "ok"}), "запись включённым")
	check(c.lookup(key()).reason != "" and c.load_key(key()) == null, "выключенный не читает")
	_clean()


func test_k1_public_api() -> void:
	var rt := AirRuntime.new()
	check("cache_enabled" in rt and rt.cache_enabled == true, "AirRuntime.cache_enabled := true")
	check(rt.has_method("cache_ready"), "AirRuntime.cache_ready()")
	rt.free()
	check(AirFieldCache.DEFAULT_DIR == "user://air_cache", "место user://air_cache")
	check(int(Config.value("atmosphere", "air_cache.max_mb", -1)) >= 0, "air_cache.max_mb в конфиге")
	var res: Dictionary = AirBakedField._model_config("atmosphere")
	check(int((res.get("air_cache", {}) as Dictionary).get("max_mb", -1)) == 200, "по умолчанию 200 МБ")
	check(UserSettings.is_local_key("atmosphere.air_cache.max_mb"), "машинный ключ (LOCAL_KEYS)")
	var src := FileAccess.get_file_as_string("res://scripts/atmosphere/air_field_cache.gd")
	check(src.contains("class_name AirFieldCache"), "AirFieldCache — scripts/atmosphere/air_field_cache.gd")
	check(not FileAccess.file_exists("res://scripts/atmosphere/air_model/air_field_cache.gd"), "не в air_model/ (code_hash)")
