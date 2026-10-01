extends Node
## SP-3 (docs/plan/air-speed.md): эталон выходов CPU-подготовки входа решателя (контракт S1,
## docs/air_speed_contracts.md) и замер её разбивки по частям.
##
##   # эталон (фикстура для tests/atmosphere/test_air_prep_ref.gd) — из кода, против которого сверяем:
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/atmosphere/air_prep_ref.tscn -- --gen
##   # разбивка времени (медиана из --reps повторов, область 400 м и окна 100/50 м Онгудая 12:00):
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/atmosphere/air_prep_ref.tscn -- --bench [--reps=5]
##   # поле после решателя (GPU, не headless): --solve=<папка> сохраняет, --compare=<папка> сверяет
##   # (итерации, max|Δ| u, v, w, θ′, w_mech) — область и окна 100/50 м Онгудая, область и окно Аушкуля:
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 320x240 \
##     res://tools/atmosphere/air_prep_ref.tscn -- --solve=/tmp/prep_old   (затем --compare=/tmp/prep_old)
##
## Случаи (CASES): область 400 м и окна 100/50 м Онгудая (12:00, 3 м/с со 150°), область Онгудая
## в 9:00, область и окно 100 м Аушкуля (озеро — доля воды) в 12:00. Для каждого — оба решения,
## как их готовит игра: с нагревом (prepare) и без (without_heat().prepare; у окна — prepare_pair).

const FIX_DIR := "res://tests/atmosphere/fixtures/air_model/prep/"
const SOLAR_U := 3.0
const SOLAR_DIR := 150.0

## kind: "d" — область AirPlace.domain_case, "w" — окно AirWindowCase.window_at (угол x0, y0).
const CASES := [
	{name = "ongudai_d400_h12", loc = "ongudai", kind = "d", dx = 400.0, hour = 12.0},
	{
		name = "ongudai_w100_h12",
		loc = "ongudai",
		kind = "w",
		dx = 100.0,
		hour = 12.0,
		x0 = 4025.0,
		y0 = -3525.0
	},
	{
		name = "ongudai_w50_h12",
		loc = "ongudai",
		kind = "w",
		dx = 50.0,
		hour = 12.0,
		x0 = 5625.0,
		y0 = -1925.0
	},
	{name = "ongudai_d400_h9", loc = "ongudai", kind = "d", dx = 400.0, hour = 9.0},
	{name = "aushkul_d400_h12", loc = "aushkul", kind = "d", dx = 400.0, hour = 12.0},
	{
		name = "aushkul_w100_h12",
		loc = "aushkul",
		kind = "w",
		dx = 100.0,
		hour = 12.0,
		x0 = -3200.0,
		y0 = -3200.0
	},
]

static var _places := {}


## Место как у игры (AirRuntime.place_of): слой detail, маска воды (распакованная копия), loc.
static func place(loc_id: String) -> Dictionary:
	if _places.has(loc_id):
		return _places[loc_id]
	var dir := "res://data/terrain/%s" % loc_id
	var meta: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(dir.path_join("meta.json"))
	)
	var out := {}
	for info: Dictionary in meta.layers:
		if String(info.id) != "detail":
			continue
		var l := HeightLayer.load_from_file(dir.path_join(String(info.file)), info)
		var img: Image = null
		if info.has("water_file"):
			var tex := load(dir.path_join(String(info.water_file))) as Texture2D
			img = tex.get_image().duplicate() if tex != null else null
			if img != null and img.is_compressed():
				img.decompress()
		var loc: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string("res://configs/locations/%s.json" % loc_id)
		)
		loc.id = loc_id
		out = {detail = l, water = img, loc = loc}
	_places[loc_id] = out
	return out


## Случай и его решение без нагрева, оба подготовлены (как AirRuntime.PreparedCase / AirClipmap).
static func build(cs: Dictionary) -> Array:
	var pl := place(String(cs.loc))
	var c: AirCase
	if cs.kind == "d":
		c = AirPlace.domain_case(
			pl.detail, pl.water, pl.loc, cs.dx, cs.hour, SOLAR_U, SOLAR_DIR
		)
		if c == null or not c.prepare():
			return []
	else:
		var ctx := AirPlace.context(pl.detail, pl.loc, WeatherModel.config())
		var w := AirWindowCase.window_at(
			pl.detail, pl.water, pl.loc, cs.dx, cs.x0, cs.y0, cs.hour, SOLAR_U, SOLAR_DIR,
			NAN, "clear", true, ctx
		)
		if w == null or not w.prepare_pair():
			return []
		c = w
	var m := c.without_heat()
	if not m.prepare():
		return []
	return [c, m]


## Доля воды по клеткам случая (тот же вызов, что в domain_case / window_at).
static func water_of(cs: Dictionary, c: AirCase) -> PackedFloat64Array:
	var pl := place(String(cs.loc))
	return AirPlace.water_fraction(pl.water, pl.detail, c.x0, c.y0, c.dx, c.nx, c.ny)


## Массивы и числа пары (c, m) — то, что сверяет тест (S1).
static func snapshot(cs: Dictionary, c: AirCase, m: AirCase) -> Dictionary:
	var arr := {
		hc = c.hc,
		water = water_of(cs, c),
		heat = c.heat,
		gam = c.gam,
	}
	var num := {
		nx = c.nx, ny = c.ny, nz = c.nz, dz = c.dz, z_bot = c.z_bot, x0 = c.x0, y0 = c.y0, z_i = c.z_i
	}
	for pair in [["h_", c], ["m_", m]]:
		var pre: String = pair[0]
		var x: AirCase = pair[1]
		arr[pre + "col"] = x.col
		arr[pre + "lev"] = x.lev
		arr[pre + "prm"] = x.prm
		arr[pre + "heat_used"] = x.heat_used
		arr[pre + "h_bl"] = x.h_bl
		num[pre + "n_unk"] = Array(x.n_unk)
		num[pre + "n_fluid"] = x.n_fluid
		num[pre + "fixed_scale"] = x.fixed_scale
	return {arrays = arr, nums = num}


## Запись: <name>.json (числа, раскладка) + <name>.bin (сжатый zstd, f64/f32 подряд).
static func save(path: String, snap: Dictionary) -> int:
	var buf := PackedByteArray()
	var lay := {}
	for k: String in snap.arrays:
		var a: Variant = snap.arrays[k]
		var bytes: PackedByteArray
		var dt := "f64"
		if a is PackedFloat32Array:
			bytes = (a as PackedFloat32Array).to_byte_array()
			dt = "f32"
		else:
			bytes = (a as PackedFloat64Array).to_byte_array()
		lay[k] = [buf.size(), bytes.size(), dt]
		buf.append_array(bytes)
	var meta: Dictionary = snap.nums.duplicate()
	meta.arrays = lay
	meta.source = "tools/atmosphere/air_prep_ref.gd --gen"
	var f := FileAccess.open(path + ".json", FileAccess.WRITE)
	f.store_string(JSON.stringify(meta, "\t", true, true))
	f.close()
	var fb := FileAccess.open_compressed(path + ".bin", FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	fb.store_buffer(buf)
	fb.close()
	return FileAccess.get_file_as_bytes(path + ".bin").size()


static func load_ref(path: String) -> Dictionary:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path + ".json"))
	var fb := FileAccess.open_compressed(path + ".bin", FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	var buf := fb.get_buffer(fb.get_length())
	fb.close()
	var data := {}
	for k: String in meta.arrays:
		var o: Array = meta.arrays[k]
		var b := buf.slice(int(o[0]), int(o[0]) + int(o[1]))
		data[k] = b.to_float32_array() if String(o[2]) == "f32" else b.to_float64_array()
	meta.data = data
	return meta


func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if args.has("gen"):
		_gen()
	if args.has("bench"):
		_bench(int(args.get("reps", "5")))
	var code := 0
	if args.has("solve") or args.has("compare"):
		code = _solve(String(args.get("solve", args.get("compare"))), args.has("compare"))
	get_tree().quit(code)


func _gen() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FIX_DIR))
	for cs: Dictionary in CASES:
		var pr := build(cs)
		if pr.is_empty():
			push_error("air_prep_ref: случай %s не построен" % cs.name)
			continue
		var snap := snapshot(cs, pr[0], pr[1])
		var sz := save(FIX_DIR + String(cs.name), snap)
		var wsum := 0.0
		for v in snap.arrays.water:
			wsum += v
		print(
			"%s: %d КБ; n_unk %s / %s, fixed_scale %.6f / %.6f, вода Σ %.1f клеток"
			% [
				cs.name, sz / 1024, snap.nums.h_n_unk, snap.nums.m_n_unk,
				snap.nums.h_fixed_scale, snap.nums.m_fixed_scale, wsum
			]
		)


static func _med(a: Array) -> float:
	var b := a.duplicate()
	b.sort()
	return b[b.size() / 2]


## Разбивка подготовки по частям (мс, медиана из reps). Части считаются отдельными вызовами тех же
## функций с теми же входами; «итого» — цельные вызовы, как в игре.
func _bench(reps: int) -> void:
	var cfg := WeatherModel.config()
	print("water format: ", place("ongudai").water.get_format())
	for cs: Dictionary in CASES.slice(0, 3):
		var pl := place(String(cs.loc))
		var t := {}
		var add := func(k: String, us: int) -> void:
			if not t.has(k):
				t[k] = []
			t[k].append(us / 1000.0)
		for r in reps:
			var t0 := Time.get_ticks_usec()
			var ctx := AirPlace.context(pl.detail, pl.loc, cfg)
			add.call("context", Time.get_ticks_usec() - t0)
			var n := roundi(AirPlace.DOMAIN_L / cs.dx) if cs.kind == "d" else AirWindowCase.N_WINDOW
			var x0: float = -AirPlace.DOMAIN_L / 2.0 if cs.kind == "d" else cs.x0
			var y0: float = -AirPlace.DOMAIN_L / 2.0 if cs.kind == "d" else cs.y0
			t0 = Time.get_ticks_usec()
			var hc := AirPlace.block_mean(pl.detail, x0, y0, cs.dx, n, n)
			add.call("block_mean", Time.get_ticks_usec() - t0)
			t0 = Time.get_ticks_usec()
			var wf := AirPlace.water_fraction(pl.water, pl.detail, x0, y0, cs.dx, n, n)
			add.call("water_fraction", Time.get_ticks_usec() - t0)
			var t_max := WeatherModel.typical_max_c(int(ctx.month), int(ctx.day), cfg)
			t0 = Time.get_ticks_usec()
			var d := AirPlace.day(ctx, cs.hour, t_max, "clear", cfg)
			add.call("day", Time.get_ticks_usec() - t0)
			t0 = Time.get_ticks_usec()
			AirPlace.solar_flux(hc, cs.dx, n, n, d, ctx, cfg, wf)
			add.call("solar_flux", Time.get_ticks_usec() - t0)
			# цельный вход, как в игре
			t0 = Time.get_ticks_usec()
			var c: AirCase
			if cs.kind == "d":
				c = AirPlace.domain_case(
					pl.detail, pl.water, pl.loc, cs.dx, cs.hour, SOLAR_U, SOLAR_DIR
				)
			else:
				c = AirWindowCase.window_at(
					pl.detail, pl.water, pl.loc, cs.dx, cs.x0, cs.y0, cs.hour, SOLAR_U,
					SOLAR_DIR, NAN, "clear", true, ctx
				)
			add.call("ВХОД итого", Time.get_ticks_usec() - t0)
			t0 = Time.get_ticks_usec()
			c.prepare()
			add.call("prepare нагрев", Time.get_ticks_usec() - t0)
			var m := c.without_heat()
			t0 = Time.get_ticks_usec()
			m.prepare()
			add.call("prepare без", Time.get_ticks_usec() - t0)
			# части prepare на тех же входах
			var sig := float(c.p.k_smooth_m) / c.dx
			t0 = Time.get_ticks_usec()
			AirCase.gauss2d(c.hc, c.nx, c.ny, sig)
			add.call("  gauss2d (×1)", Time.get_ticks_usec() - t0)
			var nyx := c.nx_h * c.ny_h
			var kf := PackedInt32Array()
			kf.resize(nyx)
			for q in nyx:
				kf[q] = int(c.col[nyx + q])
			t0 = Time.get_ticks_usec()
			c._count_unknowns(kf)
			add.call("  _count_unknowns", Time.get_ticks_usec() - t0)
			var hk := PackedFloat64Array()
			hk.resize(c.nx * c.ny)
			for q in hk.size():
				hk[q] = c.heat_used[q] / AirCase.RHO_CP
			var c2 := c.without_heat()
			c2._hs = c._hs
			t0 = Time.get_ticks_usec()
			c2._closure(hk, true)
			add.call("  _closure (гаусс H)", Time.get_ticks_usec() - t0)
			add.call(
				"ПОДГОТОВКА итого",
				int((t["ВХОД итого"][r] + t["prepare нагрев"][r] + t["prepare без"][r]) * 1000.0)
			)
		var line := "%s (reps %d):" % [cs.name, reps]
		for k: String in t:
			line += "\n  %-22s %8.1f мс" % [k, _med(t[k])]
		print(line)


const FIELDS := ["u", "v", "w", "th", "um", "vm", "wmech", "thm"]
## Цепочки решения: область, окна — вложенно (родитель — предыдущий в цепочке), как в игре.
const SOLVE := [
	["ongudai_d400_h12", "ongudai_w100_h12", "ongudai_w50_h12"],
	["aushkul_d400_h12", "aushkul_w100_h12"],
]


static func _case_by_name(nm: String) -> Dictionary:
	for cs: Dictionary in CASES:
		if cs.name == nm:
			return cs
	return {}


## Решить цепочки SOLVE на GPU (run_blocking) из подготовки нынешнего кода; сохранить поля в dir
## или сверить с сохранёнными там. 0 — сошлось с допусками S1 (итерации те же, |Δu,v,w,w_mech| ≤
## 1e-3 м/с, |Δθ′| ≤ 1e-4 К).
func _solve(dir: String, cmp: bool) -> int:
	DirAccess.make_dir_recursive_absolute(dir)
	var fails := 0
	for chain: Array in SOLVE:
		var pd := {}
		for nm: String in chain:
			var cs := _case_by_name(nm)
			var pr := build(cs)
			var job: AirPicardJob
			if cs.kind == "d":
				job = AirPicardJob.new()
			else:
				job = AirWindowJob.new()
				job.parent = pd
			job.case = pr[0]
			job.mech = true
			var t0 := Time.get_ticks_usec()
			if not job.start() or not job.run_blocking():
				push_error("air_prep_ref: %s не решено (%s)" % [nm, job.error])
				return 1
			var t_ms := (Time.get_ticks_usec() - t0) / 1000.0
			var iters := []
			for r: Dictionary in job.results:
				iters.append(int(r.iters))
			var cur := {}
			for f: String in FIELDS:
				cur[f] = job.download(f)
			pd = job.parent_data()
			job.release()
			var base := dir.path_join(nm)
			if not cmp:
				var fb := FileAccess.open(base + ".bin", FileAccess.WRITE)
				for f: String in FIELDS:
					fb.store_buffer(cur[f].to_byte_array())
				fb.close()
				var fj := FileAccess.open(base + ".json", FileAccess.WRITE)
				fj.store_string(JSON.stringify({iters = iters, n = cur.u.size()}))
				fj.close()
				print("%s: решено за %.0f мс, итерации %s — сохранено" % [nm, t_ms, iters])
				continue
			var ref: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(base + ".json"))
			var all := FileAccess.get_file_as_bytes(base + ".bin").to_float32_array()
			var n := int(ref.n)
			var same_it := Array(ref.iters).map(func(v): return int(v)) == iters
			var line := "%s: %.0f мс, итерации %s (было %s)" % [nm, t_ms, iters, ref.iters]
			var bitwise := true
			for fi in FIELDS.size():
				var f: String = FIELDS[fi]
				var a: PackedFloat32Array = cur[f]
				var b := all.slice(fi * n, (fi + 1) * n)
				var e := 0.0
				for q in n:
					e = maxf(e, absf(a[q] - b[q]))
				bitwise = bitwise and a == b
				var tol := 1e-4 if f.begins_with("th") else 1e-3
				line += ", max|Δ%s| %.3e" % [f, e]
				if e > tol:
					fails += 1
			if not same_it:
				fails += 1
			print(line + (", побитно" if bitwise else ""))
	print("СВЕРКА: %s" % ("ok" if fails == 0 else "%d нарушений" % fails) if cmp else "")
	return 0 if fails == 0 else 1
