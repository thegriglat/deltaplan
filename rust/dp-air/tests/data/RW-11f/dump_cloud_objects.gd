extends "res://tools/wind_fixtures/gen_fixtures.gd"
## RW-11f: дамп записей объектов-облаков W6 v4 (22 поля) из ThermalField/CloudModel/StormField GD
## на опорной ревизии c591b1026 (headless, синтетическое место).
## Запуск (копия на c591b1026): tools/wind_fixtures/dump_cloud_objects.tscn -- --out=<файл.json> [--only=имя,имя]
## Для каждого случая и момента атмосферы TIMES (новая атмосфера со start_at(t), как в эталонах W8)
## пишет записи на моменты t, t - 10, t - 60 (прошлые моменты окна истории CloudLayer):
## все термики набора с has_cloud и stage.x >= 0, по возрастанию id. Поля - как в контракте W6 v4;
## full_id - полный id (сопоставление), id записи без маски (маску и уникальность проверяет Rust).

const CASES_DUMP := ["synth_storm", "synth_medium"]
const BACK_S := [0.0, 10.0, 60.0]


func _ready() -> void:
	var out := ""
	var only: PackedStringArray = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--only="):
			only = a.substr(7).split(",")
	if out == "":
		push_error("dump_cloud_objects: нужен --out=<файл>")
		get_tree().quit(2)
		return
	Locations.fixtures_root = "res://tests/fixtures/locations"
	var rev: Array = []
	if OS.execute("git", ["-C", ProjectSettings.globalize_path("res://"), "rev-parse", "--short", "HEAD"], rev) == 0:
		_git_rev = String(rev[0]).strip_edges()
	await get_tree().process_frame
	var res := {}
	for c in CASES:
		var name := String(c.name)
		if not CASES_DUMP.has(name) or (not only.is_empty() and not only.has(name)):
			continue
		var ctx := _synthetic_ctx()
		var weather := _weather_of(c)
		var moments := []
		for t in TIMES:
			var a := _make_atmo(c, ctx, weather)
			a.start_at(t)
			var f: Vector3 = ctx.focus
			var shots := []
			for back in BACK_S:
				shots.append({t = t - back, records = _records(a, t - back)})
			moments.append({t = t, focus = [f.x, f.z], shots = shots})
		res[name] = moments
	var fa := FileAccess.open(out, FileAccess.WRITE)
	fa.store_string(JSON.stringify({
		task = "RW-11f", reference_revision = _git_rev, cases = res,
		fields = ["id", "flags", "cx", "cz", "base_msl", "growth", "decay", "activity", "rx", "rz",
			"depth", "spread", "vis_seed", "life_t0", "life_t1", "src_x", "src_z", "drift_vx",
			"drift_vz", "drift_t0", "storm_t0", "storm_k"],
	}))
	fa.close()
	get_tree().quit(0)


func _records(a: Atmosphere, t: float) -> Array:
	var out := []
	var ids: Array = a.field.thermals.keys()
	ids.sort()
	var model: CloudModel = a.cloud_phys.model
	for id: int in ids:
		var th: AtmoThermal = a.field.thermals[id]
		if not th.has_cloud:
			continue
		var st := model.stage(th, t)
		if st.x < 0.0:
			continue
		var c := model.center(th, t)
		var sz := model.size(th, st)
		var w := Vector3(-1.0e30, 0.0, 1.0e30)
		if not th.is_static:
			w = model._life_window(th)
		var flags := (1 if th.is_static else 0) | (4 if th.is_cb else 0)
		var s0 := 0.0
		var sk := 0.0
		if th.is_cb:
			s0 = a.storm.storm_start(th)
			sk = a.storm.intensity(th, t)
		var dv := Vector2.ZERO if th.is_static else th.drift_vel
		var dt0 := 1.0e30 if th.is_static else th.drift_start()
		out.append({
			full_id = id,
			rec = [
				id, flags, c.x, c.y, th.top, st.x, st.y, st.z, sz.x, sz.y, sz.z, sz.w,
				th.noise_seed % 9973, w.x, w.z, th.src.x, th.src.z, dv.x, dv.y, dt0, s0, sk,
			],
		})
	return out
