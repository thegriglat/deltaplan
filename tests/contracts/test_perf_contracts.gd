extends TestCase
## Контрактные тесты модуля perf (docs/contracts/perf.md). Метод — по контракту: префикс test_pf_k4_ —
## PF-К4 (сборка источников термиков в рабочем потоке), test_pf_k2_ — PF-К2 (PF-4).

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


## Сборка в потоке и синхронная на одном поле — те же источники байт в байт (маска, подпись).
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


## Пока сборка идёт, air_src — прежний объект; готовая подменяет его целиком; устаревшая
## (ключ сменился, пока считалась) отбрасывается.
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
	a.field.air_wait()
	check(not a.field.air_building(), "задач не осталось")
	check(a.field.air_src != null and a.field.air_src != old, "подменён целиком")
	if a.field.air_src != null:
		var ref := AirThermals.new()
		var cfg: Dictionary = AT._cfg()
		check(ref.build(a.field.air.levels[0], cfg, m3), "эталон собран")
		check(a.field.air_src.mask_bytes() == ref.mask_bytes(), "принята сборка последней маски, не устаревшей")
	a.free()


## Выход из места/игры: освобождение поля при идущей сборке не оставляет задачу.
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


## Подмена источников на поле с тем же охватом (кеши сетки остаются) даёт те же термики, что
## свежее поле с теми же источниками.
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
