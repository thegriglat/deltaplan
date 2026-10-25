extends Node
## RW-6i: дамп поля воздуха (WindField, AirFieldSet) — эталон GDScript для
## rust/dp-air/tests/wind_field.rs. Тот же путь, что игра (AirPicardJob._build_field):
## WindField.from_mac по состояниям Пикара (heat — решение с нагревом, mech — без нагрева, w_mech)
## и типам клеток R1, затем опрос ~2000 точек и сценарий подмены AirFieldSet.
##
## Входы (вне git, ~/data/air_cascade; каталог — $DP_AIR_DATA):
##   ongudai/ongudai_d400_u3_heat.{json,bin} — случай R1 (hc, cell, gam, z_i), Онгудай 400 м, U10 = 3;
##   rw6i/u3_{heat,mech}.{json,bin} — состояния R4 picard_rs (picard solve … --tol-scale 5
##   --save-state), см. dump_wind_field.sh (пересчитывает, если нет).
## Область дампа — вырез n × n клеток (CROP_*) из 96 × 96 с ореолом (файлы ≤ 3 МБ). Поток тепла,
## карта z0 и z_i по столбцам — детерминированная синтетика (в игре их даёт AirPlace); они
## пишутся в дамп, Rust читает те же числа. Рельеф «настоящей земли» под точкой (ground_h) —
## рельеф сетки плюс гладкая добавка либо NaN (рельеф сетки), пишется в дамп.
##
## Запуск (CPU, Godot — под замком):
##   .dpcli/dpcli lock cpu rw6i --no-tmux -- tools/research/rust_wind/dump_wind_field.sh
##   tools/research/rust_wind/dump_wind_field.sh --verify    # пересъёмка и побитное сравнение
## Выход: <out>/field.json + field.bin (f32 LE подряд; arrays: имя → [смещение, длина]).

const DEFAULT_OUT := "res://rust/dp-air/tests/data/wind_field"
const HALO_DIMS := [98, 98, 52]  # (NX, NY, NZ) R1 и R4 с ореолом
const CROP_I0 := 48
const CROP_J0 := 32
const CROP_N := 24
## Уровень B — вырез из A (клеток от края A).
const B_OFF := 6
const B_N := 12
const N_POINTS := 2000
const N_SET_POINTS := 48
const Z_I_ALPHA := 0.33

## Сценарии подмены: set — уровни (A, B), blend_s; adv — секунды; sample — снимок опроса.
const OPS := [
	{op = "set", levels = ["A"], blend = 0.0},
	{op = "sample"},
	{op = "set", levels = ["B", "A"], blend = 60.0},
	{op = "sample"},
	{op = "adv", dt = 10.0},
	{op = "sample"},
	{op = "adv", dt = 20.0},
	{op = "sample"},
	{op = "set", levels = ["A"], blend = 45.0},
	{op = "sample"},
	{op = "adv", dt = 10.0},
	{op = "sample"},
	{op = "adv", dt = 35.0},
	{op = "sample"},
	{op = "set", levels = [], blend = 20.0},
	{op = "sample"},
	{op = "adv", dt = 10.0},
	{op = "sample"},
	{op = "adv", dt = 15.0},
	{op = "sample"},
	{op = "set", levels = ["B"], blend = 0.0},
	{op = "sample"},
	# цепочка подмен: снимки, отбрасывание лёгких долей (MAX_OLD = 3, OLD_MIN_W)
	{op = "set", levels = ["A"], blend = 30.0},
	{op = "adv", dt = 6.0},
	{op = "set", levels = ["B", "A"], blend = 30.0},
	{op = "adv", dt = 4.0},
	{op = "set", levels = ["B"], blend = 30.0},
	{op = "adv", dt = 5.0},
	{op = "set", levels = [], blend = 30.0},
	{op = "adv", dt = 3.0},
	{op = "set", levels = ["A"], blend = 30.0},
	{op = "sample"},
	{op = "adv", dt = 9.0},
	{op = "sample"},
	{op = "adv", dt = 40.0},
	{op = "sample"},
]

var _out := ""
var _data := ""
var _arrays := {}
var _blob := PackedFloat32Array()
var _seed := 12345


func _ready() -> void:
	_out = ProjectSettings.globalize_path(DEFAULT_OUT)
	_data = OS.get_environment("DP_AIR_DATA")
	if _data.is_empty():
		_data = OS.get_environment("HOME") + "/data/air_cascade"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--data="):
			_data = a.substr(7)
	DirAccess.make_dir_recursive_absolute(_out)
	var ok := _run()
	get_tree().quit(0 if ok else 1)


func _run() -> bool:
	var r1 := _load_bin(_data + "/ongudai/ongudai_d400_u3_heat")
	var st_h := _load_bin(_data + "/rw6i/u3_heat")
	var st_m := _load_bin(_data + "/rw6i/u3_mech")
	if r1.is_empty() or st_h.is_empty() or st_m.is_empty():
		push_error("dump_wind_field: нет входных данных в %s (dump_wind_field.sh их пересчитывает)" % _data)
		return false
	var m1: Dictionary = r1.meta
	var n := CROP_N
	var nz := int(m1.nz)
	var dx := float(m1.dx)
	var arr1: Dictionary = r1.arr
	var hc_full: PackedFloat32Array = arr1.hc
	var gam_full: PackedFloat32Array = arr1.gam
	var gam := gam_full.slice(1, 1 + nz)
	var z_i := float(m1.case_params.z_i)
	# вход a: вырезы с ореолом
	var cell_h := _crop_halo(arr1.cell, CROP_I0, CROP_J0, n)
	var heat_u := _crop_halo(st_h.arr.u, CROP_I0, CROP_J0, n)
	var heat_v := _crop_halo(st_h.arr.v, CROP_I0, CROP_J0, n)
	var heat_w := _crop_halo(st_h.arr.w, CROP_I0, CROP_J0, n)
	var heat_th := _crop_halo(st_h.arr.th, CROP_I0, CROP_J0, n)
	var mech_w := _crop_halo(st_m.arr.w, CROP_I0, CROP_J0, n)
	var hc := PackedFloat32Array()
	hc.resize(n * n)
	for j in n:
		for i in n:
			hc[j * n + i] = hc_full[(CROP_J0 + j) * 96 + CROP_I0 + i]
	var hc_mean := 0.0
	for q in hc.size():
		hc_mean += hc[q]
	hc_mean /= hc.size()
	var z0 := PackedFloat32Array()
	var heat := PackedFloat32Array()
	var zic := PackedFloat32Array()
	for q in n * n:
		z0.append(0.05 * (1.0 + 3.0 * (0.5 + 0.5 * sin(0.5 * (q % n)) * cos(0.4 * (q / n)))))
		heat.append(120.0 + 200.0 * sin(0.37 * (q % n)) * cos(0.21 * (q / n)))
		zic.append(z_i + Z_I_ALPHA * (hc[q] - hc_mean))
	var grid := {
		dx = dx,
		dz = float(m1.dz),
		x0 = float(m1.x0) + CROP_I0 * dx,
		y0 = float(m1.y0) + CROP_J0 * dx,
		z_bot = float(m1.z_bot),
		nx = n,
		ny = n,
		nz = nz,
	}
	var meta := grid.duplicate()
	meta.z0 = z0
	meta.gam = gam
	meta.heat = heat
	meta.z_i = z_i
	meta.z_i_col = zic
	var fa := WindField.from_mac(
		meta, heat_u, heat_v, heat_w, mech_w, heat_th, cell_h, hc
	)
	if fa == null:
		return false
	fa.clamp_values(40.0, 10.0)
	# уровень B: вырез из A (поля A по массивам) — те же числа, другая сетка
	var fb := _crop_level(fa, B_OFF, B_N, meta, gam, z0, heat, zic)
	# вариант без метаданных: z0 числом, нет gam, нет нагрева
	var plain := grid.duplicate()
	var fc := WindField.from_mac(plain, heat_u, heat_v, heat_w, mech_w, heat_th, cell_h, hc)
	fc.clamp_values(40.0, 10.0)
	_add("heat_u", heat_u)
	_add("heat_v", heat_v)
	_add("heat_w", heat_w)
	_add("heat_th", heat_th)
	_add("mech_w", mech_w)
	_add("cell", cell_h)
	_add("hc", hc)
	_add("z0", z0)
	_add("heat", heat)
	_add("z_i_col", zic)
	_add("gam", gam)
	# сырые массивы A: u, v, w_mech подряд на клетку → раздельно
	var vel := fa.raw_vel()
	var ru := PackedFloat32Array()
	var rv := PackedFloat32Array()
	var rw := PackedFloat32Array()
	for c in vel.size() / 3:
		ru.append(vel[c * 3])
		rv.append(vel[c * 3 + 1])
		rw.append(vel[c * 3 + 2])
	_add("raw_u", ru)
	_add("raw_v", rv)
	_add("raw_w_mech", rw)
	_add("raw_w_conv", fa.raw_w_conv())
	_add("raw_theta", fa.raw_theta())
	var k1 := PackedFloat32Array()
	for q in fa.raw_k1():
		k1.append(q)
	_add("raw_k1", k1)
	var cols := _columns(fa)
	for key: String in cols:
		_add("col_" + key, cols[key])
	# опрос точек
	var pts := _make_points(fa, N_POINTS)
	_add("pts", pts.pos)
	_add("pts_ground", pts.ground)
	var res := _query(fa, pts.pos, pts.ground)
	for key: String in res:
		_add("a_" + key, res[key])
	var sub := _subset(pts)
	_add("sub_pos", sub.pos)
	_add("sub_ground", sub.ground)
	var resb := _query(fb, sub.pos, sub.ground)
	for key: String in resb:
		_add("b_" + key, resb[key])
	var resc := _query(fc, sub.pos, sub.ground)
	for key: String in resc:
		_add("c_" + key, resc[key])
	var cc := _columns(fc)
	for key: String in cc:
		_add("c_col_" + key, cc[key])
	# подмена
	var set_res := _run_ops(fa, fb, sub)
	for key: String in set_res:
		_add("set_" + key, set_res[key])
	var doc := {
		format = "dp-wind-field-dump",
		version = 1,
		desc = "RW-6i: эталон GDScript (WindField, AirFieldSet) на вырезе Онгудая 400 м, U10 = 3, 12:00",
		grid = grid,
		limits = [40.0, 10.0],
		edge_cells = 5.0,
		z_i = z_i,
		crop = {i0 = CROP_I0, j0 = CROP_J0, n = n},
		b = {off = B_OFF, n = B_N},
		n_points = N_POINTS,
		n_sub = N_SET_POINTS,
		t_size = WindField.T_SIZE,
		ops = OPS,
		arrays = _arrays,
	}
	return _write(doc)


## Файл R1/R4: {meta, arr} (arr — массивы по имени); пусто — нет файла.
func _load_bin(base: String) -> Dictionary:
	if not FileAccess.file_exists(base + ".json") or not FileAccess.file_exists(base + ".bin"):
		return {}
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(base + ".json"))
	var all := FileAccess.get_file_as_bytes(base + ".bin").to_float32_array()
	var arr := {}
	for name: String in meta.arrays:
		var ol: Array = meta.arrays[name]
		arr[name] = all.slice(int(ol[0]), int(ol[0]) + int(ol[1]))
	return {meta = meta, arr = arr}


## Вырез n × n клеток с ореолом из массива (NZ, NY, NX) = HALO_DIMS (старый ореол — i0, j0).
func _crop_halo(a: PackedFloat32Array, i0: int, j0: int, n: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var nxh: int = HALO_DIMS[0]
	var nyh: int = HALO_DIMS[1]
	var nzh: int = HALO_DIMS[2]
	for k in nzh:
		for j in n + 2:
			for i in n + 2:
				out.append(a[(k * nyh + j0 + j) * nxh + i0 + i])
	return out


## Уровень B — вырез off, n из A: массивы A по клеткам (u, v, w_mech, w_conv, θ′, hc).
func _crop_level(
	fa: WindField, off: int, n: int, meta: Dictionary, gam: PackedFloat32Array,
	z0: PackedFloat32Array, heat: PackedFloat32Array, zic: PackedFloat32Array
) -> WindField:
	var na := fa.nx
	var nz := fa.nz
	var vel := fa.raw_vel()
	var wc := fa.raw_w_conv()
	var th := fa.raw_theta()
	var hcA := fa.raw_hc()
	var u := PackedFloat32Array()
	var v := PackedFloat32Array()
	var wm := PackedFloat32Array()
	var wcc := PackedFloat32Array()
	var tt := PackedFloat32Array()
	for k in nz:
		for j in n:
			for i in n:
				var c := (k * na + off + j) * na + off + i
				u.append(vel[c * 3])
				v.append(vel[c * 3 + 1])
				wm.append(vel[c * 3 + 2])
				wcc.append(wc[c])
				tt.append(th[c])
	var hcb := PackedFloat32Array()
	var z0b := PackedFloat32Array()
	var hb := PackedFloat32Array()
	var zb := PackedFloat32Array()
	for j in n:
		for i in n:
			var q := (off + j) * na + off + i
			hcb.append(hcA[q])
			z0b.append(z0[q])
			hb.append(heat[q])
			zb.append(zic[q])
	var m := meta.duplicate()
	m.nx = n
	m.ny = n
	m.x0 = float(meta.x0) + off * float(meta.dx)
	m.y0 = float(meta.y0) + off * float(meta.dx)
	m.z0 = z0b
	m.heat = hb
	m.z_i_col = zb
	return WindField.from_arrays(m, u, v, wm, wcc, tt, hcb)


func _columns(f: WindField) -> Dictionary:
	var out := {}
	var names := ["ustar", "uout", "aout", "desc", "wstar", "hmix"]
	for nm in names:
		out[nm] = PackedFloat32Array()
	for j in f.ny:
		for i in f.nx:
			# столбцы через turb_at в центре столбца (билинейные веса — 1 в узле), на высоте
			# выше рельефа; прямой доступ к массивам столбцов в GD закрыт
			var p := Vector3(
				f.x0 + (i + 0.5) * f.dx, f.raw_hc()[j * f.nx + i] + 10.0, -(f.y0 + (j + 0.5) * f.dx)
			)
			var t := f.turb_at(p, NAN)
			out.ustar.append(t[WindField.T_USTAR])
			out.uout.append(t[WindField.T_UOUT])
			out.aout.append(t[WindField.T_AOUT])
			out.desc.append(t[WindField.T_DESC])
			out.wstar.append(t[WindField.T_WSTAR])
			out.hmix.append(t[WindField.T_HMIX])
	return out


func _rand() -> float:
	_seed = (_seed * 1103515245 + 12345) & 0x7fffffff
	return float(_seed >> 8) / float(1 << 23)


## Точки опроса и высота настоящей земли под ними (NaN — рельеф сетки).
func _make_points(f: WindField, count: int) -> Dictionary:
	_seed = 12345
	var pos := PackedFloat32Array()
	var ground := PackedFloat32Array()
	var x_lo := f.x0
	var x_hi := f.x0 + f.nx * f.dx
	var y_lo := f.y0
	var y_hi := f.y0 + f.ny * f.dx
	var top := f.z_bot + f.nz * f.dz
	var agls := [1.0, 5.0, 20.0, 50.0]
	# крутые и низкие столбцы
	var hcs := f.raw_hc()
	var steep: Array = []
	var low: Array = []
	for j in range(1, f.ny - 1):
		for i in range(1, f.nx - 1):
			var c := j * f.nx + i
			var g := absf(hcs[c + 1] - hcs[c - 1]) + absf(hcs[c + f.nx] - hcs[c - f.nx])
			steep.append([g, c])
			low.append([hcs[c], c])
	steep.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	low.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for q in count:
		var x := 0.0
		var y_g := 0.0  # y мира (север)
		var agl := 0.0
		var abs_y := NAN
		var cat := q % 20
		if cat < 6:
			# у земли: 1, 5, 20, 50 м над рельефом внутри области
			x = lerpf(x_lo + f.dx, x_hi - f.dx, _rand())
			y_g = lerpf(y_lo + f.dx, y_hi - f.dx, _rand())
			agl = agls[q % 4]
		elif cat < 9:
			var c: int = steep[int(_rand() * 40)][1]
			x = f.x0 + ((c % f.nx) + _rand()) * f.dx
			y_g = f.y0 + ((c / f.nx) + _rand()) * f.dx
			agl = _rand() * 300.0
		elif cat < 11:
			var c: int = low[int(_rand() * 40)][1]
			x = f.x0 + ((c % f.nx) + _rand()) * f.dx
			y_g = f.y0 + ((c / f.nx) + _rand()) * f.dx
			agl = _rand() * 400.0
		elif cat < 15:
			# полоса края (от −½ до 6 клеток от границы), любая из сторон и верх
			var side := int(_rand() * 4)
			var d := lerpf(-0.5, 6.0, _rand()) * f.dx
			x = lerpf(x_lo, x_hi, _rand())
			y_g = lerpf(y_lo, y_hi, _rand())
			match side:
				0:
					x = x_lo + d
				1:
					x = x_hi - d
				2:
					y_g = y_lo + d
				_:
					y_g = y_hi - d
			agl = _rand() * 500.0
		elif cat < 17:
			# верх полосы и над z_i
			x = lerpf(x_lo, x_hi, _rand())
			y_g = lerpf(y_lo, y_hi, _rand())
			abs_y = lerpf(2800.0, top + 300.0, _rand())
		elif cat < 18:
			# снаружи
			x = lerpf(x_lo - 3.0 * f.dx, x_hi + 3.0 * f.dx, _rand())
			y_g = lerpf(y_lo - 3.0 * f.dx, y_hi + 3.0 * f.dx, _rand())
			abs_y = lerpf(f.z_bot, top, _rand())
		else:
			x = lerpf(x_lo, x_hi, _rand())
			y_g = lerpf(y_lo, y_hi, _rand())
			agl = _rand() * 1500.0
		var z := -y_g
		# настоящая земля: рельеф сетки + гладкая добавка (чётные точки) либо NaN
		var hg := f.ground_height(x, z)
		var gh := NAN
		var h := hg
		if q % 2 == 0:
			gh = hg + 25.0 * sin(x * 0.013) * cos(z * 0.017)
			h = gh
		var y := h + agl if is_nan(abs_y) else abs_y
		pos.append(x)
		pos.append(y)
		pos.append(z)
		ground.append(gh)
	return {pos = pos, ground = ground}


func _subset(pts: Dictionary) -> Dictionary:
	var pos := PackedFloat32Array()
	var ground := PackedFloat32Array()
	var n: int = pts.ground.size()
	var step: int = n / N_SET_POINTS
	for q in N_SET_POINTS:
		var s: int = q * step + 1
		for c in 3:
			pos.append(pts.pos[s * 3 + c])
		ground.append(pts.ground[s])
	return {pos = pos, ground = ground}


## Опрос уровня: vel (3), theta, wconv, edge, contains, turb (T_SIZE) на точку.
func _query(f: WindField, pos: PackedFloat32Array, ground: PackedFloat32Array) -> Dictionary:
	var out := {
		vel = PackedFloat32Array(),
		theta = PackedFloat32Array(),
		wconv = PackedFloat32Array(),
		edge = PackedFloat32Array(),
		inside = PackedFloat32Array(),
		turb = PackedFloat32Array(),
	}
	for q in ground.size():
		var p := Vector3(pos[q * 3], pos[q * 3 + 1], pos[q * 3 + 2])
		var g := ground[q]
		var v := f.sample(p, g)
		out.vel.append(v.x)
		out.vel.append(v.y)
		out.vel.append(v.z)
		out.theta.append(f.sample_theta(p, g))
		out.wconv.append(f.sample_w_conv(p, g))
		out.edge.append(f.edge_weight(p))
		out.inside.append(1.0 if f.contains(p) else 0.0)
		out.turb.append_array(f.turb_at(p, g))
	return out


## Сценарий OPS: на каждый sample — vec4, θ (2), w_conv (2), turb (T_SIZE + 1), dx, blend.
func _run_ops(fa: WindField, fb: WindField, sub: Dictionary) -> Dictionary:
	var fs := AirFieldSet.new()
	var vel := PackedFloat32Array()
	var th := PackedFloat32Array()
	var wc := PackedFloat32Array()
	var tb := PackedFloat32Array()
	var dxs := PackedFloat32Array()
	var bl := PackedFloat32Array()
	var by_name := {"A": fa, "B": fb}
	for op: Dictionary in OPS:
		match op.op:
			"set":
				var lv: Array[WindField] = []
				for nm: String in op.levels:
					lv.append(by_name[nm])
				fs.set_field(lv, float(op.blend))
			"adv":
				fs.advance(float(op.dt))
			"sample":
				bl.append(fs.blend_fraction())
				for q in sub.ground.size():
					var p := Vector3(sub.pos[q * 3], sub.pos[q * 3 + 1], sub.pos[q * 3 + 2])
					var g: float = sub.ground[q]
					var v := fs.sample(p, g)
					vel.append_array(PackedFloat32Array([v.x, v.y, v.z, v.w]))
					var t := fs.sample_theta(p, g)
					th.append_array(PackedFloat32Array([t.x, t.y]))
					var c := fs.sample_w_conv(p, g)
					wc.append_array(PackedFloat32Array([c.x, c.y]))
					tb.append_array(fs.sample_turb(p, g))
					dxs.append(fs.sample_dx(p, g))
	return {vel = vel, theta = th, wconv = wc, turb = tb, dx = dxs, blend = bl}


func _add(name: String, a: PackedFloat32Array) -> void:
	_arrays[name] = [_blob.size(), a.size()]
	_blob.append_array(a)


## Запись через временные файлы и переименование (json — последним).
func _write(doc: Dictionary) -> bool:
	var bin := _out + "/field.bin"
	var js := _out + "/field.json"
	var f := FileAccess.open(bin + ".tmp", FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(_blob.to_byte_array())
	f.close()
	var j := FileAccess.open(js + ".tmp", FileAccess.WRITE)
	if j == null:
		return false
	j.store_string(JSON.stringify(doc, "\t"))
	j.close()
	DirAccess.rename_absolute(bin + ".tmp", bin)
	DirAccess.rename_absolute(js + ".tmp", js)
	return true
