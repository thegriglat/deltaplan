extends TestCase
## Контрактные тесты модуля perf (docs/contracts/perf.md): test_pf_k2_ — PF-К2 (буфер облаков, качество), test_pf_k4_ — PF-К4 (сборка источников термиков в рабочем потоке).

const DOC := "res://docs/contracts/perf.md"
const FIELDS := {
	"shadow_map_px": TYPE_INT, "shadow_steps": TYPE_INT, "coarse_steps": TYPE_INT,
	"max_iterations": TYPE_INT, "fine_step_per_m": TYPE_FLOAT, "fine_step_min_m": TYPE_FLOAT,
	"light_steps": TYPE_INT, "detail": TYPE_BOOL, "lowres_scale": TYPE_FLOAT, "max_buffer_px": TYPE_INT,
}


func _presets() -> Dictionary:
	var j: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://configs/atmosphere.json"))
	return j.clouds.quality_presets


func test_pf_k2_version_in_doc() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	var at := text.find("## PF-К2.")
	check(at >= 0 and text.substr(at, text.find("\n", at) - at).contains("версия 2"), "PF-К2 v2 в документе")


func test_pf_k2_preset_fields() -> void:
	var presets := _presets()
	for q in ["low", "medium", "high"]:
		check(presets.has(q), "пресет %s" % q)
		if not presets.has(q):
			continue
		for f in FIELDS:
			check(presets[q].has(f), "%s.%s есть" % [q, f])
			if not presets[q].has(f):
				continue
			var v: Variant = presets[q][f]
			var t := typeof(v)
			var ok: bool = t == FIELDS[f] or (FIELDS[f] == TYPE_FLOAT and t == TYPE_INT) or (FIELDS[f] == TYPE_INT and t == TYPE_FLOAT and v == floorf(v))
			check(ok, "%s.%s нужного типа" % [q, f])
		var s: float = float(presets[q].lowres_scale)
		check(s > 0.0 and s <= 1.0, "%s.lowres_scale в (0,1]" % q)
		check(int(presets[q].max_buffer_px) >= 0, "%s.max_buffer_px >= 0" % q)


func test_pf_k2_buffer_size_formula() -> void:
	var presets := _presets()
	for q in ["low", "medium", "high"]:
		var s: float = float(presets[q].lowres_scale)
		var mx: int = int(presets[q].max_buffer_px)
		for full in [Vector2i(1920, 1080), Vector2i(3024, 1964), Vector2i(3840, 2160), Vector2i(1, 1)]:
			var b := CloudCompositorEffect.buffer_size(full, s, mx)
			check(b.x >= 1 and b.y >= 1, "%s %s: размер >= 1" % [q, full])
			if mx > 0:
				check(b.x * b.y <= mx + b.x + b.y + 1, "%s %s: площадь %d <= предел %d (+округление)" % [q, full, b.x * b.y, mx])
			var area := float(full.x) * float(full.y)
			if full.x >= 1920 and mx > 0 and area * s * s > mx:
				var k := sqrt(mx / area)
				check(b == Vector2i(ceili(full.x * k), ceili(full.y * k)), "%s %s: по формуле" % [q, full])
		# 1920x1080: предел не срабатывает для low/medium
		var f := Vector2i(1920, 1080)
		if q != "high":
			check(CloudCompositorEffect.buffer_size(f, s, mx) == CloudCompositorEffect.buffer_size(f, s, 0), "%s: на 1080p предел не срабатывает" % q)
	check(CloudCompositorEffect.buffer_size(Vector2i(1920, 1080), 0.5, 0) == Vector2i(960, 540), "0 — без предела")
	var big := CloudCompositorEffect.buffer_size(Vector2i(3024, 1964), 0.5, 240000)
	check(big.x * big.y <= 240000 + big.x + big.y, "3024x1964 ограничен")
	check(absf(float(big.x) / big.y - 3024.0 / 1964.0) < 0.01, "пропорции сохранены")



const AT := preload("res://tests/atmosphere/test_air_thermals.gd")


func _signature(src: AirThermals) -> Dictionary:
	return {
		sig = src.grid_sig,
		mask = src.mask_bytes(),
		col = src.col,
		pos = src.pos,
		w0 = src.w0,
		top = src.top,
		drift = src.drift,
		radius = src.radius,
		ring = src.ring,
	}


func _field_atmo(async_build: bool) -> Atmosphere:
	var f := AT._flat(AT._sun_half, AT._conv_line)
	var a := AT._atmo(f)
	a.field.air_async = async_build
	a.set_air_field(f, 0.0)
	return a


func test_pf_k4_thread_equals_sync() -> void:
	var s := _field_atmo(false)
	s.field._update_air()
	check(s.field.air_src != null and s.field.air_src.count() > 0, "синхронная сборка дала источники")
	var t := _field_atmo(true)
	t.field._update_air()  # первых источников нет — ждёт сам (загрузка места)
	t.field.air_wait()
	check(not t.field.air_building(), "после air_wait сборок нет")
	check(t.field.air_src != null, "поточная сборка принята")
	if s.field.air_src == null or t.field.air_src == null:
		return
	var a := _signature(s.field.air_src)
	var b := _signature(t.field.air_src)
	check(a.sig == b.sig and a.sig != "", "grid_sig тот же")
	check(a.mask == b.mask and not a.mask.is_empty(), "mask_bytes байт в байт")
	for k: String in ["col", "pos", "w0", "top", "drift", "radius", "ring"]:
		check(a[k] == b[k], "массив %s тот же" % k)
	s.free()
	t.free()


func test_pf_k4_old_source_until_ready_and_stale_dropped() -> void:
	var a := _field_atmo(true)
	a.field._update_air()
	a.field.air_wait()
	var old := a.field.air_src
	check(old != null, "первый источник готов")
	var mask := a.field.air_sources_mask()
	# смена маски ведущего — новый ключ; затем ещё одна — первая сборка устареет
	var m2: PackedByteArray = mask.mask.duplicate()
	m2[0] = m2[0] ^ 1
	a.field.set_air_forced(String(mask.sig), m2)
	a.field._update_air()
	check(a.field.air_building(), "сборка идёт")
	check(a.field.air_src == old, "пока идёт — прежний air_src")
	var m3: PackedByteArray = mask.mask.duplicate()
	m3[1] = m3[1] ^ 2
	a.field.set_air_forced(String(mask.sig), m3)
	a.field._update_air()
	check(a.field._air_jobs.size() == 1, "одна сборка за раз, устаревшие не копятся")
	a.field.air_wait()
	check(not a.field.air_building(), "задач не осталось")
	check(a.field.air_src != null and a.field.air_src != old, "подменён целиком")
	if a.field.air_src != null:
		var ref := AirThermals.new()
		var cfg: Dictionary = AT._cfg()
		check(ref.build(a.field.air.levels[0], cfg, m3), "эталон собран")
		check(a.field.air_src.mask_bytes() == ref.mask_bytes(), "принята сборка последней маски, не устаревшей")
	a.free()


func test_pf_k4_free_while_building() -> void:
	var a := _field_atmo(true)
	a.field._update_air()
	var mask := a.field.air_sources_mask()
	var m2: PackedByteArray = mask.mask.duplicate()
	m2[0] = m2[0] ^ 1
	a.field.set_air_forced(String(mask.sig), m2)
	a.field._update_air()
	check(a.field.air_building(), "сборка запущена")
	a.free()
	check(true, "освобождено без зависания")


func test_pf_k4_swap_keeps_thermals_deterministic() -> void:
	var a := _field_atmo(true)
	a.field._update_air()
	var mask := a.field.air_sources_mask()
	a.start_at(3000.0)
	var m2: PackedByteArray = mask.mask.duplicate()
	m2[1] = m2[1] ^ 4
	a.field.set_air_forced(String(mask.sig), m2)
	a.field._update_air()
	a.field.air_wait()
	a.refresh_now()
	var b := _field_atmo(false)
	b.field.set_air_forced(String(mask.sig), m2)
	b.start_at(3000.0)
	b.refresh_now()
	var ia: Array = a.field.thermals.keys()
	var ib: Array = b.field.thermals.keys()
	ia.sort()
	ib.sort()
	check(ia == ib and not ia.is_empty(), "те же термики (%d / %d)" % [ia.size(), ib.size()])
	a.free()
	b.free()



func test_pf_k4_version_in_doc() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	var at := text.find("## PF-К4.")
	check(at >= 0 and text.substr(at, text.find("\n", at) - at).contains("версия 2"), "PF-К4 v2 в документе")


## v2: при подмене на поле того же охвата циклы клеток сетки, решённые до подмены, не пересматриваются
## (в т. ч. посчитанные с тенью прежних источников), а новые после подмены — как у свежего поля.
func test_pf_k4_swap_grid_cycles_before_same_after_like_fresh() -> void:
	var a := _field_atmo(true)
	a.field._update_air()
	var mask := a.field.air_sources_mask()
	a.start_at(3000.0)
	a.refresh_now()
	var before := {}
	for id in a.field.thermals:
		var th: AtmoThermal = a.field.thermals[id]
		if th.cell.x < ThermalField._AIR_IA:
			before[id] = th
	var empties_before: Dictionary = a.field._empty_cycles.duplicate()
	var air_ids_before: Dictionary = a.field._air_ids.duplicate()
	var m2: PackedByteArray = mask.mask.duplicate()
	m2[1] = m2[1] ^ 4
	a.field.set_air_forced(String(mask.sig), m2)
	a.field._update_air()
	a.field.air_wait()
	var kept := 0
	for id in before:
		if a.field.thermals.has(id) and a.field.thermals[id] == before[id]:
			kept += 1
	check(kept == before.size(), "решённые до подмены термики сетки те же (%d / %d)" % [kept, before.size()])
	var lost := 0
	for id in empties_before:
		if not air_ids_before.has(id) and not a.field._empty_cycles.has(id):
			lost += 1
	check(lost == 0, "решённые пустые циклы сетки не забыты (%d)" % lost)
	# новые циклы после подмены — как у свежего поля с теми же источниками
	var t1 := 3000.0 + 4000.0
	a.step(4000.0)
	a.refresh_now()
	var b := _field_atmo(false)
	b.field.set_air_forced(String(mask.sig), m2)
	b.start_at(t1)
	b.refresh_now()
	var fresh_n := 0
	var same_n := 0
	for id in b.field.thermals:
		var tb: AtmoThermal = b.field.thermals[id]
		if tb.cell.x >= ThermalField._AIR_IA or tb.t_birth < 3000.0 + 200.0:
			continue
		fresh_n += 1
		if a.field.thermals.has(id) and is_equal_approx(a.field.thermals[id].strength, tb.strength):
			same_n += 1
	check(fresh_n > 0 and same_n == fresh_n, "новые термики сетки как у свежего поля (%d / %d)" % [same_n, fresh_n])
	a.free()
	b.free()
