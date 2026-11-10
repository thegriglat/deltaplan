extends Node
## Полёт за гребнем без игрока (LT-14): настоящая игра (scenes/main.tscn, «Маятник», воздух dp-air с полем),
## автопилот игры держит курс, мы ведём его по ветру через гребень (линия разреза a50_focus, как стенд LT-2)
## и держим высоту над гребнем. Не игровой код; одна сцена для обоих кодов (прежний и LTM v1) и для замера кадра.
##
##   godot --headless --path . res://tools/research/lee_turb/flight/lee_pass.tscn -- \
##     --code=new --seed=1 --out=<csv> [--passes=<c>:<h>:<x1/x2>,...] [--repeat=2]
##   godot --path . ... -- --frame=1 --passes=50:0:2 --repeat=3 --out=<csv>       (окно, замок GPU)
## Проход «c:h:ячейки»: через гребень на c м выше него, дальше плавно (x/H 0,3…1,0) на h м над гребнем и держит;
## ячейки — удаления x/H через «/», по которым пишутся строки.
##
## Место — Онгудай, гребень a50_focus (tools/research/lee_turb/stand/ridges.json: crest_x/z/msl, H, dir),
## погода — пресет strong по прогнозу игры: 27 км/ч с 151°, 26 °C, ясно, 12 ч (как поле случая ongudai_strong).
## Проход начинается за LEAD_M м наветреннее гребня, идёт по ветру до 4,8 H за гребнем; высота держится
## воздушной скоростью автопилота (быстрее — ниже). Ячейка (x/H, h): отсчёты, где удаление за гребнем в пределах
## ±CELL_DX·H и высота в пределах ±CELL_DH от заданной; строка csv — одна ячейка одного прохода.
## Ниже гребня при x/H = 0,5 лететь нельзя: рельеф там на 11 м ниже гребня (плато), поэтому перелёт — на +50/+100.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const CREST := Vector2(7198.6, 276.6)
const CREST_MSL := 1878.3
const H := 255.2
## Куда дует ветер (x, z игры), единичный; вдоль гребня (поперёк ветра) — P.
const DIR := Vector2(-0.48481, -0.87462)
const WIND_FROM := 151.0
## Базовая воздушная скорость прохода, м/с (трим sport 9,8; ветер у гребня 9…13 м/с, по ветру).
const V_BASE := 15.0
const TIMEOUT_WALL_S := 7200.0
const WARM_S := 10.0
const DW_THR := 2.0
var HZ := Engine.physics_ticks_per_second
var DT := 1.0 / float(Engine.physics_ticks_per_second)
## Ячейка отсчётов вокруг заданных высоты и удаления: ±CELL_DH м по высоте, ±CELL_DX·H по удалению.
const CELL_DH := 35.0
const CELL_DX := 0.5
const LEAD_M := 600.0
const END_XH := 4.8

var _main: Node
var _game: Game
var _air: Node
var _o := {}
var _dts := PackedFloat64Array()
var _t_last := 0
var _sampling := false
var _skip_until_ms := 0
var _unready := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and "=" in a:
			var kv := a.substr(2).split("=", true, 1)
			_o[kv[0]] = kv[1]
	get_tree().create_timer(TIMEOUT_WALL_S, true).timeout.connect(_fail.bind("таймаут"))
	var seed_i := int(_o.get("seed", "1"))
	var args := PackedStringArray(
		[
			"--autostart", "--autopilot", "--location=ongudai", "--seed=%d" % seed_i,
			"--temp=26", "--wind=7.5", "--from=%d" % int(WIND_FROM), "--sky=clear", "--hour=12", "--bots=0",
			"--air-start=0,300",
		]
	)
	_main = MAIN_SCENE.instantiate()
	_main.set("opts", LaunchOptions.parse(args))
	add_child(_main)
	for i in 60000:
		if int(_main.get("state")) == 2:
			break
		await get_tree().process_frame
	if int(_main.get("state")) != 2:
		_fail("не долетели до FLYING")
		return
	_game = _main.get_node("Game")
	_air = _game.air
	var frame_mode := _o.has("frame")
	if frame_mode:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
		_game.camera.set_mode("chase")
	var rows: Array = []
	var passes: Array = []
	for tok in String(_o.get("passes", "50:50:0.5/2/4,40:0:2/4,30:-50:2/4")).split(","):
		var kv := tok.split(":")
		var cells: Array = []
		for x in kv[2].split("/"):
			cells.append(float(x))
		passes.append([float(kv[0]), float(kv[1]), cells])
	var repeat := int(_o.get("repeat", "1"))
	_sampling = frame_mode
	for rep in repeat:
		for p in passes:
			var got := await _pass(float(p[0]), float(p[1]), p[2], seed_i, rep)
			if got.size() == 1 and got[0].has("fatal"):
				return
			rows.append_array(got)
	_sampling = false
	_write(rows, frame_mode)
	await _quit(0)


func _process(_dt: float) -> void:
	var now := Time.get_ticks_usec()
	if _sampling and _t_last > 0 and Time.get_ticks_msec() > _skip_until_ms:
		_dts.append((now - _t_last) / 1000.0)
	_t_last = now


static func _hdg(v: Vector2) -> float:
	return fposmod(rad_to_deg(atan2(v.x, -v.y)), 360.0)


## Целевая высота MSL на удалении x_lee (м за гребнем): c над гребнем до 0,3 H, плавно до h к 1,0 H.
static func _alt_target(x_lee: float, c: float, h: float) -> float:
	var k := smoothstep(0.3 * H, 1.0 * H, x_lee)
	return CREST_MSL + lerpf(c, h, k)


## Один проход; возвращает строки ячеек. [{"fatal": true}] — ошибка (уже вызван _fail).
func _pass(c_rel: float, h_rel: float, cells: Array, seed_i: int, rep: int) -> Array:
	var along_dir := Vector2(-DIR.y, DIR.x)  # вдоль гребня (поперёк ветра), курс ≈ 61°
	var hdg_dir := _hdg(DIR)
	var gl := _game.glider
	var ap := _game.autopilot
	var start := CREST - DIR * LEAD_M
	var alt0 := CREST_MSL + c_rel
	ap.max_bank_deg = 20.0
	# телепорт; затем ждём воздух (окна поля вокруг нового фокуса) и ставим заново
	for pass_i in 2:
		gl.reset_in_air(Vector3(start.x, alt0, start.y), hdg_dir, V_BASE)
		ap.hold_heading_deg = hdg_dir
		ap.reset()
		var t0 := Time.get_ticks_msec()
		while pass_i == 0 and not bool(_air.call("is_ready")):
			_air.call("pump", 4000)
			await get_tree().physics_frame
			if Time.get_ticks_msec() - t0 > 1800000:
				_fail("воздух не готов")
				return [{"fatal": true}]
		for k in HZ / 2:
			await get_tree().physics_frame
	_skip_until_ms = Time.get_ticks_msec() + int(WARM_S * 1000.0)
	_unready = 0
	var xs := PackedFloat64Array()  # удаление за гребнем, м
	var alts := PackedFloat64Array()
	var wx := PackedFloat64Array()
	var wy := PackedFloat64Array()
	var wz := PackedFloat64Array()
	var bank := PackedFloat64Array()
	var pitch := PackedFloat64Array()
	var vy := PackedFloat64Array()
	var nlf := PackedFloat64Array()
	var sig_model := PackedFloat64Array()
	var sig_turb := PackedFloat64Array()
	var agl := PackedFloat64Array()
	var tas := PackedFloat64Array()
	var lat := PackedFloat64Array()
	var landed := 0
	var t_pass := 0.0
	var names := PackedStringArray()
	var i_turb := -1
	var n_frames := 0
	var last_sig := 0.0
	while true:
		await get_tree().physics_frame
		n_frames += 1
		if int(_main.get("state")) != 2:
			landed = 1
			print("lee_pass: state=%d после %.1f с" % [int(_main.get("state")), t_pass])
			break
		var t: Telemetry = gl.get_telemetry()
		if t.phase != "flying":
			landed = 1
			print("lee_pass: фаза %s после %.1f с, agl %.0f, высота %.0f" % [t.phase, t_pass, t.altitude_agl, t.altitude_msl])
			break
		t_pass += DT
		var p2 := Vector2(t.position.x, t.position.z)
		var x_lee := (p2 - CREST).dot(DIR)
		var lat_m := (p2 - CREST).dot(along_dir)
		var alt_t := _alt_target(x_lee, c_rel, h_rel)
		# линия разреза: правее линии (лат > 0) — довернуть влево; высота — воздушной скоростью
		ap._heading = wrapf(hdg_dir - clampf(lat_m * 0.1, -20.0, 20.0), 0.0, 360.0)
		ap.hold_airspeed_ms = clampf(V_BASE + 0.2 * (t.altitude_msl - alt_t), 11.0, 24.0)
		if not bool(_air.call("is_ready")):
			_unready += 1
		if _o.has("verbose") and n_frames % (5 * HZ) == 0:
			print("lee_pass: t=%.0f x=%.0f lat=%.0f alt=%.0f(%.0f) agl=%.0f tas=%.1f hdg=%.0f bank=%.0f gs=%.1f wind=%.1f из %.0f° w=%.1f" % [t_pass, x_lee, lat_m, t.altitude_msl, alt_t, t.altitude_agl, t.airspeed, t.heading_deg, t.bank_deg, t.groundspeed, Vector2(t.air_velocity.x - t.velocity.x, t.air_velocity.z - t.velocity.z).length(), fposmod(rad_to_deg(atan2(t.velocity.x - t.air_velocity.x, -(t.velocity.z - t.air_velocity.z))) + 180.0, 360.0), t.velocity.y - t.air_velocity.y])
		if t.altitude_agl < 12.0:
			landed = 1
			print("lee_pass: прервано у земли на %.0f с (x=%.0f, agl %.0f)" % [t_pass, x_lee, t.altitude_agl])
			break
		if x_lee > END_XH * H or t_pass > 150.0:
			break
		var s: Vector4 = _air.call("sample", t.position)
		xs.append(x_lee)
		alts.append(t.altitude_msl)
		wx.append(s.x)
		wy.append(s.y)
		wz.append(s.z)
		bank.append(t.bank_deg)
		pitch.append(t.pitch_deg)
		vy.append(t.velocity.y)
		nlf.append(t.load_factor)
		sig_model.append(s.w)
		agl.append(t.altitude_agl)
		tas.append(t.airspeed)
		lat.append(lat_m)
		if n_frames % (HZ / 10) == 0:
			var d: Dictionary = _air.call("decompose", t.position)
			if names.is_empty():
				names = d.names
				i_turb = names.find("turb")
				print("lee_pass: слагаемые ", names)
			last_sig = float((d.sigma as PackedFloat32Array)[i_turb]) if i_turb >= 0 else 0.0
		sig_turb.append(last_sig)
	var out: Array = []
	if _o.has("frame"):
		return [{"frames": true}]
	# ускорение крыла по вертикали — разность vy за 0,1 с; |Δw| воздуха у крыла за 1 с (до накопления — -1)
	var azs := PackedFloat64Array()
	var dws := PackedFloat64Array()
	for i in xs.size():
		azs.append((vy[i] - vy[i - HZ / 10]) / 0.1 if i >= HZ / 10 else NAN)
		dws.append(absf(wy[i] - wy[i - HZ]) if i >= HZ else -1.0)
	for xh in cells:
		var h_cell := (c_rel if (xh * H) < 0.3 * H else h_rel)
		var alt_cell := CREST_MSL + h_cell
		var idx: Array = []
		for i in xs.size():
			# дальняя ячейка (x/H ≥ 3): крыло к ней уже просело под заданную высоту — окно сдвинуто вниз (−75…+20 м)
			var da: float = alts[i] - alt_cell
			var in_alt: bool = (da >= -75.0 and da <= 20.0) if xh >= 3.0 else absf(da) <= CELL_DH
			if absf(xs[i] - xh * H) <= CELL_DX * H and in_alt:
				idx.append(i)
		var sub := func(a: PackedFloat64Array) -> PackedFloat64Array:
			var r := PackedFloat64Array()
			for i in idx:
				r.append(a[i])
			return r
		var altsub: PackedFloat64Array = sub.call(alts)
		var row := _stats(
			h_cell, xh, seed_i, rep, sub.call(wx), sub.call(wy), sub.call(wz), sub.call(bank), sub.call(pitch),
			sub.call(azs), sub.call(dws), sub.call(nlf), sub.call(sig_model), sub.call(sig_turb), altsub, sub.call(xs), sub.call(agl),
			sub.call(tas), landed
		)
		print("lee_pass: ячейка h=%+.0f x/H=%.1f seed=%d rep=%d n=%d σw=%.2f unready=%d landed=%d" % [h_cell, xh, seed_i, rep, idx.size(), row.get("sigma_w_ms", -1.0), _unready, landed])
		out.append(row)
	return out


static func _mean(a: PackedFloat64Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return s / a.size()


## σ после вычитания линейного тренда по индексу (медленный пространственный ход среднего).
static func _sd_detr(a: PackedFloat64Array) -> float:
	var n := a.size()
	if n < 8:
		return 0.0
	var mx := (n - 1) * 0.5
	var my := _mean(a)
	var sxy := 0.0
	var sxx := 0.0
	for i in n:
		sxy += (i - mx) * (a[i] - my)
		sxx += (i - mx) * (i - mx)
	var k := sxy / sxx
	var ss := 0.0
	for i in n:
		var r := a[i] - my - k * (i - mx)
		ss += r * r
	return sqrt(ss / n)


func _stats(
	h_rel: float, x_h: float, seed_i: int, rep: int,
	wx: PackedFloat64Array, wy: PackedFloat64Array, wz: PackedFloat64Array, bank: PackedFloat64Array,
	pitch: PackedFloat64Array, az_in: PackedFloat64Array, dw: PackedFloat64Array, nlf: PackedFloat64Array,
	sig_model: PackedFloat64Array, sig_turb: PackedFloat64Array, alt: PackedFloat64Array,
	xs: PackedFloat64Array, agl: PackedFloat64Array, tas: PackedFloat64Array, landed: int
) -> Dictionary:
	var n := wx.size()
	var r := {
		"code": String(_o.get("code", "new")), "height_rel_crest_m": h_rel, "x_over_h": x_h, "seed": seed_i,
		"rep": rep, "n": n, "landed": landed, "air_unready_frames": _unready,
	}
	if n < HZ:
		return r
	# оси среднего ветра ячейки: u — вдоль, v — поперёк (влево +), w — вертикаль
	var wh := Vector2(_mean(wx), _mean(wz))
	var ux := wh.normalized() if wh.length() > 0.1 else DIR
	var vx := Vector2(-ux.y, ux.x)
	var u := PackedFloat64Array()
	var v := PackedFloat64Array()
	u.resize(n)
	v.resize(n)
	for i in n:
		u[i] = wx[i] * ux.x + wz[i] * ux.y
		v[i] = wx[i] * vx.x + wz[i] * vx.y
	var az := PackedFloat64Array()
	var az_max := 0.0
	for a in az_in:
		if not is_nan(a):
			az.append(a)
			az_max = maxf(az_max, absf(a))
	var big := 0
	var cnt := 0
	for d in dw:
		if d >= 0.0:
			cnt += 1
			if d > DW_THR:
				big += 1
	var hr := PackedFloat64Array()
	for a in alt:
		hr.append(a - CREST_MSL)
	r["mean_wind_ms"] = snappedf(wh.length(), 0.01)
	r["mean_h_rel_crest_m"] = snappedf(_mean(hr), 0.1)
	r["mean_x_over_h"] = snappedf(_mean(xs) / H, 0.01)
	r["mean_agl_m"] = snappedf(_mean(agl), 0.1)
	r["mean_tas_ms"] = snappedf(_mean(tas), 0.01)
	r["sigma_u_ms"] = snappedf(_sd_detr(u), 0.001)
	r["sigma_v_ms"] = snappedf(_sd_detr(v), 0.001)
	r["sigma_w_ms"] = snappedf(_sd_detr(wy), 0.001)
	r["az_max_abs_ms2"] = snappedf(az_max, 0.01)
	r["az_sigma_ms2"] = snappedf(_sd_detr(az), 0.001)
	r["n_sigma"] = snappedf(_sd_detr(nlf), 0.0001)
	r["roll_sigma_deg"] = snappedf(_sd_detr(bank), 0.001)
	r["pitch_sigma_deg"] = snappedf(_sd_detr(pitch), 0.001)
	r["frac_dw_gt2"] = snappedf(float(big) / maxf(cnt, 1), 0.0001)
	r["sigma_model_mean_ms"] = snappedf(_mean(sig_model), 0.001)
	r["sigma_turb_term_mean_ms"] = snappedf(_mean(sig_turb), 0.001)
	return r


func _write(rows: Array, frame_mode: bool) -> void:
	var out := String(_o.get("out", ""))
	var text := ""
	if frame_mode:
		var a := _dts.duplicate()
		a.sort()
		var med := 0.0
		var p95 := 0.0
		var hitch := 0
		var sum := 0.0
		for d in a:
			sum += d
			if d > 50.0:
				hitch += 1
		if not a.is_empty():
			med = a[a.size() / 2]
			p95 = a[clampi(int(ceil(0.95 * a.size())) - 1, 0, a.size() - 1)]
		text = "code,median_ms,p95_ms,n,mean_ms,max_ms,hitch_50ms,unready_frames\n"
		text += "%s,%.3f,%.3f,%d,%.3f,%.3f,%d,%d\n" % [String(_o.get("code", "new")), med, p95, a.size(), sum / maxf(a.size(), 1), a[a.size() - 1] if not a.is_empty() else 0.0, hitch, _unready]
	else:
		var cols := PackedStringArray(
			[
				"code", "height_rel_crest_m", "x_over_h", "seed", "rep", "n", "landed", "air_unready_frames", "mean_wind_ms",
				"mean_h_rel_crest_m", "mean_x_over_h", "mean_agl_m", "mean_tas_ms", "sigma_u_ms", "sigma_v_ms", "sigma_w_ms",
				"az_max_abs_ms2", "az_sigma_ms2", "n_sigma", "roll_sigma_deg", "pitch_sigma_deg", "frac_dw_gt2",
				"sigma_model_mean_ms", "sigma_turb_term_mean_ms",
			]
		)
		text = ",".join(cols) + "\n"
		for row in rows:
			var parts := PackedStringArray()
			for c in cols:
				parts.append(str(row[c]) if row.has(c) else "")
			text += ",".join(parts) + "\n"
	print(text)
	if out != "":
		var tmp := out + ".tmp"
		var f := FileAccess.open(tmp, FileAccess.WRITE)
		f.store_string(text)
		f.close()
		DirAccess.rename_absolute(tmp, out)


func _fail(why: String) -> void:
	print("lee_pass: FAIL (%s)" % why)
	await _quit(1)


func _quit(code: int) -> void:
	if is_instance_valid(_main):
		_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1, true).timeout
	get_tree().quit(code)
