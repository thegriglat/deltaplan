extends "res://tools/wind_fixtures/gen_fixtures.gd"
## RW-10f: эталоны thermal у облаков. Как gen_fixtures (случаи synth_* / ongudai_*, поле Онгудая читается из
## запечённого f16: --fields=<каталог с <случай>/field.json+field.bin>), но к обычным точкам добавлены
## точки у термиков с подсосом: на оси в 150 м под основанием, в 150 и 30 м под верхом термика, в середине потока в
## облаке (suck.y/2 над верхом) и со смещением 0,6 радиуса.
## Атмосфера после start_at(T) шагает ещё STEP_N по STEP_DT (как в игре): подсос термиков - из облаков,
## построенных после start_at (в самом start_at термики строятся раньше облаков, `refresh_now`).
## Запуск: run_cloud_cases.sh <копия на c591b1026> <вывод> <каталог полей> [случаи]

const SUCK_PICK := 6
const STEP_N := 16
const STEP_DT := 0.25


func _solve_field(c: Dictionary, _ctx: Dictionary, _weather: Dictionary) -> Array:
	var dir := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--fields="):
			dir = a.substr(9)
	var fs := AirBakedField.load_file(dir.path_join(String(c.name)).path_join("field.json"))
	if fs == null:
		push_error("gen_cloud_cases: нет поля %s" % c.name)
		return []
	var out: Array = []
	for f in fs.levels:
		out.append(f)
	return out


func _pick_points(
	c: Dictionary, ctx: Dictionary, atmos: Array[Atmosphere], pts: Array[Vector3], tags: Array[String]
) -> void:
	for a in atmos:
		for i in STEP_N:
			a.step(STEP_DT)
	var f: Vector3 = ctx.focus
	var mine_p: Array[Vector3] = []
	var mine_t: Array[String] = []
	for k in TIMES.size():
		var a := atmos[k]
		var t: float = TIMES[k] + STEP_N * STEP_DT
		var base := a.field.cloudbase_msl
		var cand: Array = []
		for id: int in a.field.thermals:
			var th: AtmoThermal = a.field.thermals[id]
			th.update_time(t)
			var ax := th.axis_at(th.src.y)
			if Vector2(ax.x - f.x, ax.y - f.z).length() > 5000.0:
				continue
			var sk := a.cloud_phys.suck(th, t)
			if sk.x > th.suck + 0.02:
				cand.append([sk.x - th.suck, id, sk.y])
		cand.sort_custom(func(p: Array, q: Array) -> bool: return p[0] > q[0] or (p[0] == q[0] and p[1] < q[1]))
		print("gen_cloud_cases: %s t=%d: термиков с подсосом %d" % [c.name, int(t), cand.size()])
		var used := 0
		for e: Array in cand:
			if used >= SUCK_PICK:
				break
			var th: AtmoThermal = a.field.thermals[int(e[1])]
			var ys: Array[float] = [base - 150.0, th.top - 150.0, th.top - 30.0]
			if float(e[2]) > 1.0:
				ys.append(th.top + 0.5 * float(e[2]))
			for y in ys:
				var ax := th.axis_at(y)
				mine_p.append(Vector3(ax.x, y, ax.y))
				mine_t.append("suck_k%d" % k)
				mine_p.append(Vector3(ax.x + 0.6 * th.radius, y, ax.y))
				mine_t.append("suck_k%d" % k)
			used += 1
	super._pick_points(c, ctx, atmos, pts, tags)
	pts.append_array(mine_p)
	tags.append_array(mine_t)
