extends Node
## SR-1: доходит ли ввод мыши до трапеции в штопоре (docs/contracts/spin-recovery.md, SR-К1, SR-К2).
## Сценарий SR-К1 (виражи → срыв → штопор → выход) двумя путями:
##   variant game  — настоящая игра (scenes/main.tscn): события мыши через Viewport.push_input →
##                   InputController._mouse_offset → ControlInput → Glider → PendulumModel → руки;
##                   настройки мыши по умолчанию (configs/controls.json, mouse.*);
##   variant model — те же команды прямым ControlInput в PendulumModel (как test_pendulum_spin.gd).
## Вариант model_f1000 — то же, что model, но предел усилия рук 1000 Н вместо 300 (arms.force_max): упирается ли выход в усилие.
## Режимы: release (мышь больше не двигается; в модели ввод 0), release_center (одно событие — мышь
## в центр), standard (по Жеглову). Пробы отклика: probe_pitch / probe_rollp / probe_rolln (шаг ввода
## в штопоре в t_rec0), probe_vm12 (на себя → 0 → движение; отпускание рук VM-12), trim_* (то же в
## прямом полёте на триме). Код игры не правится.
## Запуск: см. README.md рядом. Вывод: <out>/raw_runs.jsonl, <out>/traces/*.csv.

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const MAIN_SCENE := preload("res://scenes/main.tscn")
const DT := 1.0 / 120.0
const RAMP_S := 10.0
const AFTER_S := 6.0
const AGL_M := 3000.0  ## запас высоты над рельефом в игре, м (штопор + выход ≈ 100 с)
const THIN := 4  ## трассы csv — каждый 4-й шаг (1/30 с)
const COLS := [
	"t", "cmd_p", "cmd_r", "off_x", "off_y", "in_p", "in_r", "tgt_x", "tgt_y", "f_x", "f_y",
	"rel_x", "rel_y", "nx", "ny", "rel_on", "pull_lim", "bank", "yaw", "v", "ns", "z"
]


## Сторона сценария: игра (мышь) или модель напрямую.
class Back:
	var m: PendulumModel
	var game: Game = null
	var ic: InputController = null
	var vp: Viewport = null
	var wing := ""
	var fmax := -1.0  ## > 0 — предел усилия рук вместо игрового (вариант model_f1000), Н
	var inp := ControlInput.new()
	var last_in_p := 0.0
	var last_in_r := 0.0

	## Команда (pitch, roll) в долях хода; NAN — «не двигать» (для игры: мышь стоит как есть).
	func drive(p: float, r: float) -> void:
		if game == null:
			if not is_nan(p):
				inp.pitch = p
			if not is_nan(r):
				inp.roll = r
			m.step(1.0 / 120.0, inp, Callable(), Callable())
			last_in_p = inp.pitch
			last_in_r = inp.roll
			return
		# обратная функция InputController: pitch = −offset.y, roll = offset.x (roll_input = body)
		var cur: Vector2 = ic._mouse_offset
		var tx := cur.x if is_nan(r) else clampf(r, -1.0, 1.0)
		var ty := cur.y if is_nan(p) else clampf(-p, -1.0, 1.0)
		var d := Vector2(tx, ty) - cur
		if d.length() > 1.0e-9:
			var h := vp.get_visible_rect().size.y * 0.5
			var k := float(ic._cfg.mouse.bar_sensitivity) / maxf(h, 1.0)
			var ev := InputEventMouseMotion.new()
			var c := vp.get_visible_rect().size * 0.5
			ev.position = c
			ev.global_position = c
			ev.relative = d / k
			vp.push_input(ev)
		game.tick(1.0 / 120.0)
		m = game.glider.model
		last_in_p = ic.control.pitch
		last_in_r = ic.control.roll

	func offset() -> Vector2:
		return ic._mouse_offset if ic != null else Vector2(NAN, NAN)


var out_dir := ""
var _mains: Dictionary = {}  # wing -> main
var _rows: Array = []
var _trace_dir := ""
var _raw: FileAccess = null


func _ready() -> void:
	Locations.fixtures_root = "res://tests/fixtures/locations"
	var wings: PackedStringArray = ["sport", "laminar", "training"]
	var variants: PackedStringArray = ["game", "model", "model_f1000"]
	var only_modes := PackedStringArray()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
		elif a.begins_with("--wings="):
			wings = a.substr(8).split(",")
		elif a.begins_with("--variants="):
			variants = a.substr(11).split(",")
		elif a.begins_with("--modes="):
			only_modes = a.substr(8).split(",")
	if out_dir == "":
		push_error("нужен --out=<каталог>")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out_dir + "/traces")
	_trace_dir = out_dir + "/traces"
	_raw = FileAccess.open(out_dir + "/raw_runs.jsonl", FileAccess.WRITE)
	for w in wings:
		for v in variants:
			await _do_wing(w, v, only_modes)
		if _mains.has(w):
			await _close(_mains[w])
			_mains.erase(w)
	_raw.close()
	print("SR1 DONE")
	get_tree().quit(0)


func _do_wing(w: String, variant: String, only_modes: PackedStringArray) -> void:
	var b: Back = await _make_back(w, variant)
	if b == null:
		return
	# ---- прямой полёт на триме: эталон отклика
	var trim := {}
	for tm in ["trim_pitch", "trim_rollp", "trim_rolln"]:
		if not only_modes.is_empty() and not ("probes" in only_modes):
			continue
		var r := _scenario(b, w, variant, tm)
		trim[tm] = r.probe
		_emit(r)
	var spin_modes := ["probe_pitch", "probe_rollp", "probe_rolln", "probe_vm12", "release",
		"release_center", "standard"]
	var lost := {}
	var rows_wing: Array = []
	for md in spin_modes:
		if not only_modes.is_empty():
			var is_probe: bool = md.begins_with("probe")
			if not (md in only_modes or ("probes" in only_modes and is_probe)):
				continue
		var ref_key := ""
		match md:
			"probe_pitch", "standard":
				ref_key = "trim_pitch"
			"probe_rollp":
				ref_key = "trim_rollp"
			"probe_rolln":
				ref_key = "trim_rolln"
		var r := _scenario(b, w, variant, md, trim.get(ref_key, {}))
		rows_wing.append(r)
		if md.begins_with("probe_") and md != "probe_vm12":
			lost[md] = r.probe
	# вердикт по крылу: первое непустое звено среди проб (тангаж, крен +, крен −)
	var verdict := ""
	for md in ["probe_pitch", "probe_rollp", "probe_rolln"]:
		if lost.has(md) and verdict == "" and String(lost[md].get("lost", "")) != "":
			verdict = String(lost[md].lost)
	for r in rows_wing:
		r.row.extra.input_lost_at = verdict
		_emit(r)
	# trim-строки: вердикт тот же
	print("SR1 %s/%s verdict input_lost_at=%s" % [variant, w, verdict])


func _emit(r: Dictionary) -> void:
	if not r.row.extra.has("input_lost_at"):
		r.row.extra["input_lost_at"] = ""
	_raw.store_line(JSON.stringify(_clean(r.row)))
	_raw.flush()
	var v: String = r.row.variant
	var md: String = r.row.mode
	if r.has("trace_name") and (v == "game" or md in ["standard", "release"]) \
			and not (v != "game" and md.begins_with("trim_")):
		_write_trace(r.trace_name, r.rec)
	print("SR1 row %s/%s/%s rec=%s t=%.1f loss=%s resp=%s" % [r.row.variant, r.row.wing, r.row.mode,
		r.row.recovered, r.row.get("recover_s") if r.row.get("recover_s") != null else -1.0,
		str(r.row.get("loss_m")), str(r.row.extra.get("resp_ratio"))])


# ------------------------------------------------------------------ сторона

func _make_back(w: String, variant: String) -> Back:
	var b := Back.new()
	b.wing = w
	b.vp = get_viewport()
	if variant.begins_with("model"):
		b.m = S.make(w)
		if variant == "model_f1000":
			b.fmax = 1000.0
		return b
	var main: Node = _mains.get(w)
	if main == null:
		main = await _open(w)
		if main == null:
			return null
		_mains[w] = main
	var game: Game = main.get_node("Game")
	b.game = game
	b.ic = game.input_controller
	b.m = game.glider.model
	return b


func _open(w: String) -> Node:
	var wcfg := Config.get_config("wings/" + w)
	var args := ["--autostart", "--air-start=600,150", "--wing=" + w, "--bots=0", "--no-overlay",
		"--mass=%s" % str(float(wcfg.pilot_mass_ref_kg))]
	var main: Node = MAIN_SCENE.instantiate()
	main.set("opts", LaunchOptions.parse(PackedStringArray(args)))
	add_child(main)
	for i in 1800:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	if main.get("state") != 2:
		push_error("игра не в полёте: " + w)
		await _close(main)
		return null
	var game: Game = main.get_node("Game")
	game.set_physics_process(false)  # шаги — вручную; узел не выключаем (иначе нет _unhandled_input)
	return main


func _close(main: Node) -> void:
	main.queue_free()
	for i in 2:
		await get_tree().process_frame


## Новый прогон с чистого старта: игра — restart() в воздухе, штиль, ρ const; модель — S.make.
func _restart(b: Back) -> void:
	if b.game == null:
		b.m = S.make(b.wing)
		if b.fmax > 0.0:
			b.m.arms.force_max = b.fmax
		S.reset(b.m)
		b.inp = ControlInput.new()
		return
	var game := b.game
	game.air_start_agl_m = AGL_M
	b.m._alt_dep = false  # ρ постоянная (SR-К1), как в S.make
	game.glider.set_air_fn(func(_p: Vector3) -> Vector3: return Vector3.ZERO)  # штиль и в restart()
	game.restart()
	b.ic.set_mouse_captured(true)
	b.ic.roll_input = "body"
	b.m = game.glider.model


# ------------------------------------------------------------------ запись шага

func _new_rec() -> Dictionary:
	var r := {}
	for c in COLS:
		r[c] = PackedFloat64Array()
	return r


func _sample(b: Back, rec: Dictionary, t: float, cp: float, cr: float, ns: int, yr: float) -> void:
	var m := b.m
	var a := m.arms
	var rel := S.rel_b(m)
	var off := b.offset()
	var vals := [
		t, cp, cr, off.x, off.y, b.last_in_p, b.last_in_r, a.target_b.x, a.target_b.y,
		a.force_b.x, a.force_b.y, rel.x, rel.y, a.neutral_rel.x, a.neutral_rel.y,
		1.0 if a._rel_on else 0.0, a.pull_limit, rad_to_deg(m.bank), rad_to_deg(yr),
		S.airspeed(m) * 3.6, float(ns), m.position.y
	]
	for i in COLS.size():
		rec[COLS[i]].append(vals[i])


# ------------------------------------------------------------------ сценарий

func _yaw_rate(m: PendulumModel, prev: float) -> float:
	return wrapf(m.heading - prev, -PI, PI) / DT


func _strips(m: PendulumModel) -> Vector2i:
	var h := m.strips.n / 2
	var nr := 0
	var nl := 0
	for j in h:
		if m.strips.blend[j] > 0.01:
			nr += 1
		if m.strips.blend[j + h] > 0.01:
			nl += 1
	return Vector2i(nr, nl)


## Прямой полёт на триме: 8 с нейтрали, затем шаг ввода (trim_pitch: −1; trim_rollp/rolln: ±1), 3 с.
func _trim_run(b: Back, w: String, variant: String, mode: String) -> Dictionary:
	_restart(b)
	var m := b.m
	var rec := _new_rec()
	var yr_prev := 0.0
	var hd := m.heading
	var trim_kmh := S.airspeed(m) * 3.6
	var cp := 0.0
	var cr := 0.0
	var k0 := 0
	var t0 := m.time_s
	for i in int(round(11.0 / DT)):
		var t := m.time_s - t0
		if t >= 8.0:
			if k0 == 0:
				k0 = (rec["t"] as PackedFloat64Array).size() - 1
			match mode:
				"trim_pitch":
					cp = -1.0
				"trim_rollp":
					cr = 1.0
				"trim_rolln":
					cr = -1.0
		b.drive(cp, cr)
		var yr := _yaw_rate(b.m, hd)
		hd = b.m.heading
		_sample(b, rec, b.m.time_s - t0, cp, cr, _strips(b.m).x + _strips(b.m).y, yr)
		yr_prev = yr
	var axis := "x" if mode == "trim_pitch" else "y"
	var pr := _analyse(b, rec, k0, axis, cp, cr, {})
	var row := _row(w, variant, mode, trim_kmh)
	row.extra["resp_ratio"] = 1.0
	row.extra["probe"] = pr
	return {"row": row, "probe": pr, "rec": rec, "trace_name": "%s_%s_%s" % [variant, w, mode]}


func _row(w: String, variant: String, mode: String, trim_kmh: float) -> Dictionary:
	return {
		"contract": "SR-К2 v1", "task": "SR-1", "wing": w, "variant": variant, "mode": mode,
		"dt": DT, "trim_kmh": trim_kmh, "first": "", "spin_yaw_dps": null,
		"spin_bank_max_deg": null, "spin_sink_max_ms": null, "recovered": false, "recover_s": null,
		"loss_m": null, "after_bank_max_deg": null, "after_stall_s": null, "finite": true,
		"extra": {"resp_ratio": null, "input_lost_at": ""}
	}


func _scenario(b: Back, w: String, variant: String, mode: String, ref: Dictionary = {}) -> Dictionary:
	if mode.begins_with("trim_"):
		return _trim_run(b, w, variant, mode)
	_restart(b)
	var m := b.m
	var game_path := b.game != null
	var trim_kmh := S.airspeed(m) * 3.6
	var hb := S.BankHold.new(deg_to_rad(30.0), 6.0, 2.5, 1.0)
	var rec := _new_rec()
	var t0 := m.time_s
	var hd := m.heading
	var row := _row(w, variant, mode, trim_kmh)
	var ex: Dictionary = row.extra
	var cp := 0.0
	var cr := 0.0
	# вираж 14 с
	for i in int(round(14.0 / DT)):
		cr = hb.roll(b.m)
		b.drive(0.0, cr)
		var yr := _yaw_rate(b.m, hd)
		hd = b.m.heading
		_sample(b, rec, b.m.time_s - t0, 0.0, cr, 0, yr)
	var t14 := b.m.time_s
	t0 = b.m.time_s
	var phase := 0
	var t_st := 0.0
	var roll_frz := 0.0
	var pitch_hold := 0.0
	var h0 := 0.0
	var yaw_sum := 0.0
	var n_yaw := 0
	var yaw_turn := 0.0
	var sink_turn := 0.0
	var bank_max := -INF
	var sink_max := 0.0
	var t_rec0 := 0.0
	var k0 := -1
	var pulling := true
	var rec_since := NAN
	var h_rec := 0.0
	var t_done := NAN
	var yr_prev := 0.0
	var after_bank := 0.0
	var after_stall := 0.0
	var k_done := -1
	var probe_len := 0.0
	match mode:
		"probe_pitch", "probe_rollp", "probe_rolln":
			probe_len = 3.0
		"probe_vm12":
			probe_len = 7.0
	var finite := true
	var recovered := false
	var recover_s := NAN
	var loss_m := NAN
	var max_i := int(round(160.0 / DT))
	for i in max_i:
		var t := b.m.time_s - t0
		var tr := b.m.time_s - t_rec0
		if phase == 0:
			cp = clampf(t / RAMP_S, 0.0, 1.0)
			cr = hb.roll(b.m)
		elif phase == 1:
			cp = clampf(t / RAMP_S, 0.0, 1.0)
			cr = roll_frz
		else:
			hb.target = 0.0
			var rb := hb.roll(b.m)  # интеграл BankHold копится и в «на себя», как в тесте
			cr = rb
			match mode:
				"release":
					cp = NAN if game_path else 0.0
					cr = NAN if game_path else 0.0
				"release_center":
					cp = 0.0
					cr = 0.0
				"standard":
					if pulling:
						cp = -1.0
						cr = -signf(yr_prev)
					else:
						cp = clampf(-2.0 * (S.airspeed(b.m) * 3.6 - trim_kmh) / trim_kmh, -1.0, 0.0)
				"probe_pitch":
					cp = -1.0
					cr = roll_frz
				"probe_rollp":
					cp = pitch_hold
					cr = 1.0
				"probe_rolln":
					cp = pitch_hold
					cr = -1.0
				"probe_vm12":
					cr = roll_frz
					if tr < 1.5:
						cp = -1.0
					elif tr < 3.5:
						cp = 0.0
					else:
						cp = -0.5
		b.drive(cp, cr)
		var mm := b.m
		if not S.finite(mm):
			finite = false
			break
		var yr := _yaw_rate(mm, hd)
		yr_prev = yr
		hd = mm.heading
		var ns := _strips(mm)
		var nr := ns.x
		var nl := ns.y
		var half := mm.strips.n / 2
		_sample(b, rec, mm.time_s - t14, cp if not is_nan(cp) else b.last_in_p,
			cr if not is_nan(cr) else b.last_in_r, nr + nl, yr)
		if phase == 0:
			if t > 1.0 and t < 2.0:
				yaw_turn += yr * DT
				sink_turn = maxf(sink_turn, -mm.velocity.y)
			if nr + nl > 0:
				phase = 1
				t_st = t
				roll_frz = cr
				pitch_hold = cp
				h0 = mm.position.y
				row.first = "обе" if nr > 0 and nl > 0 else ("внутренняя" if nr > 0 else "внешняя")
				ex["bank0_deg"] = rad_to_deg(mm.bank)
				ex["pitch_at_stall"] = cp
				ex["t_stall_s"] = mm.time_s - t14
				ex["h_stall_m"] = h0
				ex["off_at_stall"] = [b.offset().x, b.offset().y]
			elif t > 60.0:
				break  # срыва нет
		elif phase == 1:
			bank_max = maxf(bank_max, rad_to_deg(mm.bank))
			sink_max = maxf(sink_max, -mm.velocity.y)
			yaw_sum += yr
			n_yaw += 1
			pitch_hold = cp
			if t - t_st >= AFTER_S:
				phase = 2
				t_rec0 = mm.time_s
				k0 = (rec["t"] as PackedFloat64Array).size() - 1
				row.spin_yaw_dps = rad_to_deg(yaw_sum / n_yaw)
				row.spin_bank_max_deg = bank_max
				row.spin_sink_max_ms = sink_max
				ex["yaw_turn_dps"] = rad_to_deg(yaw_turn)
				ex["off_at_rec0"] = [b.offset().x, b.offset().y]
				ex["in_at_rec0"] = [b.last_in_p, b.last_in_r]
				ex["srcs"] = "SR-К1"
		elif phase == 2:
			var trr := mm.time_s - t_rec0
			if probe_len > 0.0:
				if trr >= probe_len:
					break
				continue
			if pulling and mode == "standard" and trr >= 1.0 \
					and (trr >= 10.0 or (nr + nl == 0 and absf(yr) < deg_to_rad(45.0))):
				pulling = false
				ex["pull_s"] = trr
			if absf(rad_to_deg(mm.bank)) < 15.0 and absf(rad_to_deg(yr)) < 20.0 and nr + nl == 0:
				if is_nan(rec_since):
					rec_since = mm.time_s
					h_rec = mm.position.y
				elif mm.time_s - rec_since >= 3.0:
					recover_s = rec_since - t_rec0
					loss_m = h0 - h_rec
					recovered = true
					t_done = mm.time_s
					k_done = (rec["t"] as PackedFloat64Array).size() - 1
					phase = 3
			else:
				rec_since = NAN
			if trr >= 60.0 and phase == 2:
				break
		else:
			after_bank = maxf(after_bank, absf(rad_to_deg(mm.bank)))
			if nr + nl > half:
				after_stall += DT
			if mm.time_s - t_done >= 20.0:
				break
	row.finite = finite
	row.recovered = recovered
	if recovered:
		row.recover_s = recover_s
		row.loss_m = loss_m
		row.after_bank_max_deg = after_bank
		row.after_stall_s = after_stall
	var out := {"row": row, "rec": rec, "probe": {},
		"trace_name": "%s_%s_%s" % [variant, w, mode]}
	if k0 >= 0:
		# статистика рук с t_rec0 до конца выхода/пробы
		var kend: int = k_done if k_done >= 0 else (rec["t"] as PackedFloat64Array).size() - 1
		var fmax := b.m.arms.force_max
		var n_on := 0
		var n_sat := 0
		for k in range(k0 + 1, kend + 1):
			if rec["rel_on"][k] > 0.5:
				n_on += 1
			if Vector2(rec["f_x"][k], rec["f_y"][k]).length() >= 0.98 * fmax:
				n_sat += 1
		var nn := maxi(kend - k0, 1)
		ex["rel_on_frac"] = float(n_on) / nn
		ex["force_sat_frac"] = float(n_sat) / nn
		ex["window_s"] = (kend - k0) * DT
		match mode:
			"probe_pitch", "standard":
				var pr := _analyse(b, rec, k0, "x", -1.0, NAN, ref)
				out.probe = pr
				ex["resp_ratio"] = pr.get("resp_ratio")
				ex["probe"] = pr
			"probe_rollp":
				var pr := _analyse(b, rec, k0, "y", pitch_hold, 1.0, ref)
				out.probe = pr
				ex["resp_ratio"] = pr.get("resp_ratio")
				ex["probe"] = pr
			"probe_rolln":
				var pr := _analyse(b, rec, k0, "y", pitch_hold, -1.0, ref)
				out.probe = pr
				ex["resp_ratio"] = pr.get("resp_ratio")
				ex["probe"] = pr
			"probe_vm12":
				ex["vm12"] = _vm12(rec, k0)
	return out


# ------------------------------------------------------------------ анализ звеньев

## Отклик на шаг ввода в кадре k0 (последний кадр до шага). axis "x" — тангаж (ход вдоль киля),
## "y" — крен (поперёк). ref — те же числа на триме ({frac1, t63}).
func _analyse(b: Back, rec: Dictionary, k0: int, axis: String, cmd_p: float, cmd_r: float,
		ref: Dictionary) -> Dictionary:
	var rel: PackedFloat64Array = rec["rel_" + axis]
	var tgt: PackedFloat64Array = rec["tgt_" + axis]
	var n := rel.size()
	var K := int(round(1.0 / DT))
	var K3 := int(round(3.0 / DT))
	if k0 < 0 or k0 + K >= n:
		return {}
	var x0 := rel[k0]
	var tg := tgt[k0 + 12]
	var span := tg - x0
	var pr := {"axis": axis, "x0_m": x0, "target_m": tg, "span_m": span}
	var frac1 := (rel[k0 + K] - x0) / span if absf(span) > 0.03 else NAN
	var t63 := NAN
	if absf(span) > 0.03:
		for i in range(1, mini(K3, n - k0 - 1) + 1):
			if (rel[k0 + i] - x0) / span >= 0.63:
				t63 = i * DT
				break
	pr["frac1"] = frac1
	pr["t63_s"] = t63
	pr["stroke1_m"] = rel[k0 + K] - x0
	pr["stroke05_m"] = rel[k0 + K / 2] - x0
	pr["stroke3_m"] = rel[mini(k0 + K3, n - 1)] - x0
	var smax := 0.0
	for i in range(1, mini(K3, n - k0 - 1) + 1):
		if absf(rel[k0 + i] - x0) > absf(smax):
			smax = rel[k0 + i] - x0
	pr["stroke_max_m"] = smax
	var fmax := b.m.arms.force_max
	var n_sat := 0
	var n_on := 0
	var fpk := 0.0
	for i in range(1, K + 1):
		var f := Vector2(rec["f_x"][k0 + i], rec["f_y"][k0 + i]).length()
		fpk = maxf(fpk, f)
		if f >= 0.98 * fmax:
			n_sat += 1
		if rec["rel_on"][k0 + i] > 0.5:
			n_on += 1
	pr["force_peak_n"] = fpk
	pr["force_sat_frac"] = float(n_sat) / K
	pr["rel_on_frac"] = float(n_on) / K
	# звенья: ожидание против факта (в первые 0,1 с)
	var oi := "off_y" if axis == "x" else "off_x"
	var ii := "in_p" if axis == "x" else "in_r"
	var off: PackedFloat64Array = rec[oi]
	var inn: PackedFloat64Array = rec[ii]
	var dz := float(Config.get_config("controls").mouse.bar_deadzone)
	var off_exp := (-cmd_p if axis == "x" else cmd_r)
	var d_exp := off_exp - off[k0] if b.game != null else 0.0
	var d_obs := off[k0 + 12] - off[k0] if b.game != null else 0.0
	var in_cmd := cmd_p if axis == "x" else cmd_r
	pr["off_before"] = off[k0] if b.game != null else null
	pr["off_after"] = off[k0 + 12] if b.game != null else null
	pr["in_after"] = inn[k0 + 12]
	pr["in_cmd"] = in_cmd
	pr["pull_limit_m"] = rec["pull_lim"][k0 + 12]
	var lost := ""
	var resp_ratio := NAN
	var ok_resp := false
	if not ref.is_empty() and absf(float(ref.get("stroke1_m", 0.0))) > 0.05:
		# ход за 1 с в штопоре / на триме (с учётом знака: тот же ход = +)
		resp_ratio = pr["stroke1_m"] / float(ref.stroke1_m)
		pr["resp_ratio_frac"] = frac1 / float(ref.frac1) if not is_nan(frac1) else NAN
		var rt63 := float(ref.get("t63_s", NAN))
		ok_resp = resp_ratio >= 0.5 and not is_nan(t63) and (is_nan(rt63) or t63 <= 3.0 * rt63)
	pr["resp_ratio"] = resp_ratio
	if ref.is_empty():
		pr["lost"] = ""
		return pr
	# ожидаемая цель по шагу руки: neutral + (−pitch·ход) / (+roll·shift_y_max)
	var a := b.m.arms
	var nb: float = rec["n" + axis][k0 + 12]
	var inv: float = inn[k0 + 12]
	var exp_t: float
	if axis == "x":
		exp_t = nb - inv * (a.shift_x_push if inv > 0.0 else rec["pull_lim"][k0 + 12])
	else:
		exp_t = nb + inv * a.shift_y_max
	pr["target_expected_m"] = exp_t
	if not ok_resp:
		if b.game != null and absf(d_exp) > 0.05 and absf(d_obs) < 0.01:
			lost = "event"
		elif b.game != null and absf(d_exp) > 0.05 and absf(d_obs - d_exp) > 0.1 * absf(d_exp) + 0.02:
			lost = "offset"
		elif b.game != null and absf(inn[k0 + 12] - (in_cmd if absf(in_cmd) > dz else 0.0)) > 0.05:
			lost = "inp"
		else:
			if absf(tgt[k0 + 12] - exp_t) > 0.03:
				lost = "arms_target"
			elif pr.force_sat_frac > 0.5 or (axis == "x" and pr.rel_on_frac > 0.5):
				lost = "arms_force"
			else:
				lost = "bar"
	pr["lost"] = lost
	return pr


## VM-12 в штопоре: «на себя» 1,5 с → ввод 0 (2 с) → ввод −0,5. Когда руки отпустили и взяли снова.
func _vm12(rec: Dictionary, k0: int) -> Dictionary:
	var ro: PackedFloat64Array = rec["rel_on"]
	var n := ro.size()
	var first_on := NAN
	var last_on_before_move := NAN
	var off_after_move := NAN
	var t_move := 3.5
	for i in range(k0 + 1, n):
		var tr := (i - k0) * DT
		if ro[i] > 0.5 and is_nan(first_on):
			first_on = tr
		if tr <= t_move and ro[i] > 0.5:
			last_on_before_move = tr
		if tr > t_move and ro[i] < 0.5 and is_nan(off_after_move):
			off_after_move = tr
	var fx_zero := 0
	var cnt := 0
	for i in range(k0 + 1, n):
		var tr := (i - k0) * DT
		if tr > 1.6 and tr <= 3.5:
			cnt += 1
			if absf(rec["f_x"][i]) < 1.0e-6:
				fx_zero += 1
	return {
		"released_at_s": first_on, "released_until_s": last_on_before_move,
		"regrip_after_move_s": off_after_move - t_move if not is_nan(off_after_move) else NAN,
		"f_x_zero_frac_in_0_window": float(fx_zero) / maxi(cnt, 1),
		"note": "tr: 0–1,5 с pitch −1; 1,5–3,5 с pitch 0; ≥3,5 с pitch −0,5"
	}


# ------------------------------------------------------------------ вывод

func _clean(v: Variant) -> Variant:
	if v is float:
		return null if (is_nan(v) or is_inf(v)) else v
	if v is Dictionary:
		var d := {}
		for k in v:
			d[k] = _clean(v[k])
		return d
	if v is Array:
		var a := []
		for x in v:
			a.append(_clean(x))
		return a
	return v


func _write_trace(name: String, rec: Dictionary) -> void:
	var f := FileAccess.open("%s/%s.csv" % [_trace_dir, name], FileAccess.WRITE)
	f.store_line(",".join(COLS))
	var n := (rec["t"] as PackedFloat64Array).size()
	for i in range(0, n, THIN):
		var cells := PackedStringArray()
		for c in COLS:
			cells.append("%.3f" % rec[c][i])
		f.store_line(",".join(cells))
	f.close()
