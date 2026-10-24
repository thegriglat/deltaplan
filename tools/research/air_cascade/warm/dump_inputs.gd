extends Node
## PR-3: вход решателя Онгудая 400 м на заданный час — тем же кодом, что игра (AirPlace.domain_case):
## AirPlace.context/day/gamma/surface_flux + AirCase.set_inflow/set_zi_terrain. Слоя рельефа Онгудая в
## копиях нет, поэтому hc берётся из фикстуры (tests/atmosphere/fixtures/air_model/picard/ongudai_d400_h12),
## поверхность — как у domain_case без снимка (surface = null: класс NONE, m_norm, воды нет).
##
##   .dpcli/dpcli lock cpu PR-3 --no-tmux -- timeout 600 env XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD") \
##     godot --headless --path . res://tools/research/air_cascade/warm/dump_inputs.tscn -- \
##     --hours=12,12.25 --u10=3 --out=$HOME/data/air_cascade/ongudai/warm_inputs
##
## Выход: <out>/inputs_h<ЧЧММ>.json (hour, t_max, d-сводка, z_i, gam[nz+2], H[ny·nx] с нулём — «mech» не
## нужен, alpha/max_profile/cls/sun_elev на U10, z_i_col min/max/mean, sun az/el классов).

const FIX := "res://tests/atmosphere/fixtures/air_model/picard/ongudai_d400_h12"


func _arg(name: String, dflt: String) -> String:
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("--" + name + "="):
			return String(a).substr(name.length() + 3)
	return dflt


func _ready() -> void:
	var out_dir := _arg("out", "")
	var u10 := float(_arg("u10", "3"))
	var wdir := 150.0
	var m: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIX + ".json"))
	var all := FileAccess.get_file_as_bytes(FIX + ".bin").to_float32_array()
	var o: Array = m.arrays.hc
	var hc := PackedFloat64Array(Array(all.slice(int(o[0]), int(o[0]) + int(o[1]))))
	var o2: Array = m.arrays.H
	var h_fix := all.slice(int(o2[0]), int(o2[0]) + int(o2[1]))
	var nx := int(m.nx)
	var ny := int(m.ny)
	var nz := int(m.nz)
	var dx := float(m.dx)
	var cfg := WeatherModel.config()
	# контекст — как AirPlace.context (дата, широта, долгота, пояс, долина/среднее места из фикстуры)
	var ctx: Dictionary = m.ctx.duplicate()
	var t_max := WeatherModel.typical_max_c(int(ctx.month), int(ctx.day), cfg, ctx)
	var res := {}
	for hs in _arg("hours", "12,12.25").split(","):
		var hour := float(hs)
		var d := AirPlace.day(ctx, hour, t_max, "clear", cfg)
		var cells := AirPlace.cell_surface(null, null, null, float(m.x0), float(m.y0), dx, nx, ny)
		var heat := AirPlace.surface_flux(hc, dx, nx, ny, d, ctx, cfg, cells, u10, t_max)
		var c := AirCase.new()
		c.set_grid(dx, nx, ny, float(m.dz), float(m.z_bot), nz, float(m.x0), float(m.y0))
		c.hc = hc
		c.wdir = wdir
		c.z_i = d.z_i
		c.set_zi_terrain(float(ctx.get("valley_msl_m", 0.0)))
		c.set_inflow(u10, 1.0, ctx, hour, float(d.cover))
		c.gam.resize(nz + 2)
		for k in nz + 2:
			c.gam[k] = AirPlace.gamma(d, c.zc(k))
		var zc_min := INF
		var zc_max := -INF
		var zc_sum := 0.0
		for v in c.z_i_col:
			zc_min = minf(zc_min, v)
			zc_max = maxf(zc_max, v)
			zc_sum += v
		var hmax := -INF
		var hmin := INF
		var hsum := 0.0
		var dfix := 0.0
		for q in heat.size():
			hmax = maxf(hmax, heat[q])
			hmin = minf(hmin, heat[q])
			hsum += heat[q]
			dfix = maxf(dfix, absf(heat[q] - h_fix[q]))
		var dsum := {}
		for k in ["hour", "t", "cap", "z_i", "theta_s", "heat", "sky_heat", "cover"]:
			dsum[k] = d[k] if not is_inf(float(d[k])) else null
		var rec := {
			hour = hour,
			u10 = u10,
			t_max = t_max,
			day = dsum,
			z_i = d.z_i,
			z_i_col = {min = zc_min, max = zc_max, mean = zc_sum / c.z_i_col.size(), alpha = c.zi_alpha},
			alpha = c.p.alpha,
			max_profile = c.p.max_profile,
			z0 = c.p.z0,
			sun_elev = WindProfile.sun_elevation(ctx, hour),
			stab_class = WindProfile.stability_class(u10, WindProfile.sun_elevation(ctx, hour), float(d.cover)),
			H_min = hmin,
			H_max = hmax,
			H_mean = hsum / heat.size(),
			H_vs_fixture_max_abs = dfix,
			gam = Array(c.gam),
			H = Array(heat),
		}
		res[hs] = rec
		print("h=", hour, " t=", d.t, " z_i=", d.z_i, " H[", hmin, ", ", hmax, "] mean ", rec.H_mean,
			" |H-fixtureH|max ", dfix, " alpha ", c.p.alpha, " max_profile ", c.p.max_profile)
		if out_dir != "":
			DirAccess.make_dir_recursive_absolute(out_dir)
			var tag := "%02d%02d" % [floori(hour), roundi((hour - floorf(hour)) * 60.0)]
			var f := FileAccess.open("%s/inputs_h%s.json.tmp" % [out_dir, tag], FileAccess.WRITE)
			f.store_string(JSON.stringify(rec))
			f.close()
			DirAccess.rename_absolute("%s/inputs_h%s.json.tmp" % [out_dir, tag], "%s/inputs_h%s.json" % [out_dir, tag])
	get_tree().quit(0)
