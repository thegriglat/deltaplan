class_name AirNnField
extends RefCounted
## Поле ветра сетью (контракты O5, O6 docs/contracts/air-onnx.md): поиск и проверка файла сети,
## один прогон «случай области → WindField». Всё статическое, без сцены — зовётся из рабочего
## потока (AirRuntime): AirPlace.domain_case → AirNnInput (строка, страж) → AirNnPrep (карты, числа,
## to_physical) → AirOnnx.run → сборка WindField на сетке решателя (13 AGL → центры клеток по высоте).

const NX := 96
const DX := 400.0
## Выше верхнего AGL сети: отклонение от притока линейно гаснет к нулю на этой высоте над землёй.
const A_TOP := 2000.0
const A_ZERO := 3000.0
const DEFAULT_PATH := "res://data/air_nn/model.onnx"
const USER_PATH := "user://air_nn/model.onnx"
const CMD_MODEL := "--air-nn-model="


## Путь к файлу сети по O6: --air-nn-model= → user://air_nn/model.onnx → air_model.nn_model.
## Заданный в командной строке, но отсутствующий — отказ (не молчаливая подмена). → {path, why}.
static func resolve_path(cfg: Dictionary) -> Dictionary:
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with(CMD_MODEL):
			var p := String(a).trim_prefix(CMD_MODEL)
			if FileAccess.file_exists(p):
				return {path = p, why = ""}
			return {path = p, why = "нет файла сети %s" % p}
	if FileAccess.file_exists(USER_PATH):
		return {path = USER_PATH, why = ""}
	var d := String(cfg.get("nn_model", DEFAULT_PATH))
	if FileAccess.file_exists(d):
		return {path = d, why = ""}
	return {path = d, why = "нет файла сети (%s)" % d}


## Класс расширения есть: "" — да, иначе причина.
static func extension_why() -> String:
	return "" if ClassDB.class_exists("AirOnnx") else "нет расширения AirOnnx (native/air_onnx/build.sh)"


## Загрузка и проверка формата O1. → {onnx, n_maps, p2, domain: Dictionary, why, load_ms}.
static func open(path: String, threads: int) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var why := extension_why()
	if why != "":
		return {why = why}
	var nn: Object = ClassDB.instantiate("AirOnnx")
	nn.call("set_intra_op_threads", threads)
	var rc := int(nn.call("load", path))
	if rc != 0:
		return {why = "не загрузилась (код %d: %s)" % [rc, String(nn.call("last_error"))]}
	var ins: PackedStringArray = nn.call("input_names")
	var outs: PackedStringArray = nn.call("output_names")
	var sm: PackedInt64Array = nn.call("input_shape", "maps")
	var sn: PackedInt64Array = nn.call("input_shape", "nums")
	var so: PackedInt64Array = nn.call("output_shape", "out")
	var bad := ""
	if ins.size() != 2 or not ("maps" in ins) or not ("nums" in ins) or outs != PackedStringArray(["out"]):
		bad = "входы %s, выходы %s" % [ins, outs]
	elif sm.size() != 4 or sm[0] != 1 or sm[2] != NX or sm[3] != NX or not (int(sm[1]) in [4, 9]):
		bad = "maps %s" % [sm]
	elif sn != PackedInt64Array([1, 18]):
		bad = "nums %s" % [sn]
	elif so != PackedInt64Array([1, 91, NX, NX]):
		bad = "out %s" % [so]
	if bad != "":
		return {why = "формат %s ≠ O1" % bad}
	var n_maps := int(sm[1])
	var md: Dictionary = nn.call("metadata")
	var p2 := "2" if n_maps == 4 else "4"
	if md.has("deltaplan.p2_version") and String(md["deltaplan.p2_version"]) != p2:
		return {why = "формат: p2_version %s при %d картах ≠ O1" % [md["deltaplan.p2_version"], n_maps]}
	if md.has("deltaplan.map_names"):
		var want := ",".join(PackedStringArray(AirNnPrep.MAP_NAMES.slice(0, n_maps)))
		if String(md["deltaplan.map_names"]) != want:
			return {why = "формат: map_names %s ≠ O1" % md["deltaplan.map_names"]}
	if md.has("deltaplan.film_names") and String(md["deltaplan.film_names"]) != ",".join(
		PackedStringArray(AirNnPrep.FILM_NAMES)
	):
		return {why = "формат: film_names ≠ O1"}
	var domain := {}
	if md.has("deltaplan.domain"):
		var j: Variant = JSON.parse_string(String(md["deltaplan.domain"]))
		if j is Dictionary:
			domain = j
	return {
		onnx = nn,
		path = path,
		n_maps = n_maps,
		p2 = p2,
		domain = domain,
		why = "",
		load_ms = (Time.get_ticks_usec() - t0) / 1000.0,
	}


## Прогон одного прохода (рабочий поток): место → поле. model — результат open() (или кеш);
## c — {hour, u10, wdir, t_max, sky}; k — множитель притока.
## → {field: WindField, ms: {input, prep, net, build, load?}, clamped: Array, why: String}
static func run_pass(
	model: Dictionary, place: Dictionary, c: Dictionary, k: float, cfg: Dictionary
) -> Dictionary:
	var ms := {}
	var t := Time.get_ticks_usec()
	var case := AirPlace.domain_case(
		place.detail, place.get("water"), place.loc, DX,
		float(c.hour), float(c.u10), float(c.wdir),
		float(c.get("t_max", NAN)), String(c.get("sky", "clear")), true, k
	)
	if case == null:
		return {why = "область вне слоя рельефа"}
	if case.nx != NX or case.ny != NX:
		return {why = "область %d × %d, сети нужно %d × %d" % [case.nx, case.ny, NX, NX]}
	var cond := AirNnInput.cond_for(
		place.detail, place.loc, float(c.hour), float(c.get("t_max", NAN)), String(c.get("sky", "clear"))
	)
	var row := AirNnInput.row_from_case(case, cond)
	var domain := AirNnInput.default_domain()
	var md_dom: Dictionary = model.get("domain", {})
	for key: String in md_dom:
		domain[key] = md_dom[key]
	var g := AirNnInput.guard(row, domain)
	ms.input = _ms_since(t)
	# --- вход сети: карты — по настоящему повороту, числа FiLM — по зажатой строке
	t = Time.get_ticks_usec()
	var n_maps: int = model.n_maps
	var meta := AirNnPrep.case_meta(row, row.hc)
	var meta_g := AirNnPrep.case_meta(g.row, row.hc)
	var maps := AirNnPrep.maps(row.hc, row.heat, meta, n_maps, DX)
	var nums := AirNnPrep.film(g.row, meta_g)
	ms.prep = _ms_since(t)
	# --- сеть
	t = Time.get_ticks_usec()
	var nn: Object = model.onnx
	var res: Dictionary = nn.call("run", {"maps": maps, "nums": nums})
	if not res.has("out"):
		return {why = "ошибка ORT: %s" % String(nn.call("last_error"))}
	var out: PackedFloat32Array = res.out
	if out.size() != 91 * NX * NX:
		return {why = "выход сети %d ≠ %d" % [out.size(), 91 * NX * NX]}
	for x: float in out:  # NaN/∞ — отказ
		if not is_finite(x):
			return {why = "NaN в выходе сети"}
	ms.net = _ms_since(t)
	# --- поле
	t = Time.get_ticks_usec()
	var phys := AirNnPrep.to_physical(out, meta, NX, NX)
	var f := assemble(
		case, phys, meta,
		float(cfg.get("max_speed_ms", 40.0)), float(cfg.get("max_w_ms", 10.0))
	)
	if f == null:
		return {why = "поле не собралось"}
	ms.build = _ms_since(t)
	return {
		field = f, ms = ms, clamped = g.clamped, n_maps = n_maps,
		u10 = float(row.U10), dir = float(row.wdir),
	}


static func _ms_since(t_us: int) -> float:
	return (Time.get_ticks_usec() - t_us) / 1000.0


## WindField на сетке решателя этого случая (dz, z_bot, nz из AirCase) из выхода to_physical
## (m: u, v, w без нагрева; h: u, v, w, θ′ с нагревом; по 13 AGL). Правила O5.
static func assemble(
	case: AirCase, phys: Dictionary, meta: Dictionary, max_speed: float, max_w: float
) -> WindField:
	var nx := case.nx
	var ny := case.ny
	var nz := case.nz
	var nn := nx * ny
	var na := AirNnPrep.AGL.size()
	var m: PackedFloat32Array = phys.m
	var h: PackedFloat32Array = phys.h
	var agl := PackedFloat32Array()
	for a in na:
		agl.append(float(AirNnPrep.AGL[a]))
	var u := PackedFloat32Array()
	var v := PackedFloat32Array()
	var wm := PackedFloat32Array()
	var wc := PackedFloat32Array()
	var th := PackedFloat32Array()
	var n := nz * nn
	u.resize(n)
	v.resize(n)
	wm.resize(n)
	wc.resize(n)
	th.resize(n)
	var a_in: float = meta["alpha"]
	var mp: float = meta["mp"]
	var u10: float = meta["U10"]
	var wd := deg_to_rad(case.wdir)
	var ex := -sin(wd)
	var ey := -cos(wd)
	# значения канала c на уровнях a для столбца p: buf[(c·na + a)·nn + p]
	var hc := case.hc
	for p in nn:
		var hp := hc[p]
		# величины 13 уровней столбца — один раз
		var hu := PackedFloat32Array()
		var hv := PackedFloat32Array()
		var hw := PackedFloat32Array()
		var mw := PackedFloat32Array()
		var ht := PackedFloat32Array()
		hu.resize(na)
		hv.resize(na)
		hw.resize(na)
		mw.resize(na)
		ht.resize(na)
		for a in na:
			hu[a] = h[a * nn + p]
			hv[a] = h[(na + a) * nn + p]
			hw[a] = h[(2 * na + a) * nn + p]
			ht[a] = h[(3 * na + a) * nn + p]
			mw[a] = m[(2 * na + a) * nn + p]
		var ub_top := AirNnPrep.ubg(A_TOP, a_in, mp, u10)
		var du_top := hu[na - 1] - ub_top * ex
		var dv_top := hv[na - 1] - ub_top * ey
		var dw_h := hw[na - 1]
		var dw_m := mw[na - 1]
		var dt_top := ht[na - 1]
		for kk in nz:
			var a_m := case.z_bot + (kk + 0.5) * case.dz - hp
			var q := kk * nn + p
			if a_m < 0.0:
				continue  # земля: нули
			if a_m <= A_TOP:
				var x := 0.0
				var lo := 0
				if a_m > agl[0]:
					# ближайшая пара AGL
					lo = 0
					while lo < na - 2 and a_m > agl[lo + 1]:
						lo += 1
					x = (a_m - agl[lo]) / (agl[lo + 1] - agl[lo])
				var hi := mini(lo + 1, na - 1)
				u[q] = lerpf(hu[lo], hu[hi], x)
				v[q] = lerpf(hv[lo], hv[hi], x)
				var wh := lerpf(hw[lo], hw[hi], x)
				var wmm := lerpf(mw[lo], mw[hi], x)
				wm[q] = wmm
				wc[q] = wh - wmm
				th[q] = lerpf(ht[lo], ht[hi], x)
			else:
				var ub := AirNnPrep.ubg(a_m, a_in, mp, u10)
				var f := clampf((A_ZERO - a_m) / (A_ZERO - A_TOP), 0.0, 1.0)
				u[q] = ub * ex + du_top * f
				v[q] = ub * ey + dv_top * f
				wm[q] = dw_m * f
				wc[q] = (dw_h - dw_m) * f
				th[q] = dt_top * f
	var mt := case.meta()
	mt.heat = AirCase.to_f32(AirNnInput.tapered_heat(case))
	var hc32 := AirCase.to_f32(hc)
	var fld := WindField.from_arrays(mt, u, v, wm, wc, th, hc32, max_speed, max_w)
	return fld
