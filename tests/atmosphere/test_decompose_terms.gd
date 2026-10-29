extends TestCase
## W7 на реализации gd: слагаемые decompose — инварианты (total = sample FULL побитно, Σ vel =
## total.xyz ± 1e-4, имена — T_NAMES, одинаковой длины) на синтетическом месте в точках
## у земли, подветер, под и над базой облаков, у термиков. Без GPU и без поля Пикара: аналитика,
## термики, гроза, волна. Помощники (синтетическое место, запуск до READY) — из контрактных тестов.

const C := preload("res://tests/contracts/test_rust_wind_contracts.gd")
const CENTER := Vector3(1500.0, 0.0, -2500.0)
const TOL := 1.0e-4
## Слагаемые W7 в порядке реализации (rust/dp-air/src/terms/decompose.rs).
const T_NAMES := ["field", "analytic", "ridge", "thermal", "storm", "wave", "cloud", "turb", "gust"]

var _h = C.new()


func _grid_points(a: Node) -> PackedVector3Array:
	var pl: AirPlaceData = C._synthetic()
	var base := float(a.cloudbase_msl())
	var out := PackedVector3Array()
	for agl in [3.0, 50.0, 300.0, 1200.0]:
		for k in 12:
			var ang := TAU * k / 12.0
			var r := 300.0 + 150.0 * (k % 5)
			var x := CENTER.x + cos(ang) * r
			var z := CENTER.z + sin(ang) * r
			out.append(Vector3(x, pl.height_at(x, z) + agl, z))
	for dh in [-150.0, 50.0, 400.0]:
		out.append(Vector3(CENTER.x, base + dh, CENTER.z))
	return out


func _check_all(a: Node, label: String, seen: Dictionary) -> void:
	a.advance_to(1800.0)
	var names := T_NAMES
	for p in _grid_points(a):
		var d: Dictionary = a.decompose(p)
		check((d.names as PackedStringArray) == PackedStringArray(names), "%s: имена" % label)
		var vel: PackedVector3Array = d.vel
		var sg: PackedFloat32Array = d.sigma
		check(vel.size() == names.size() and sg.size() == names.size(), "%s: длины" % label)
		var sum := Vector3.ZERO
		for i in vel.size():
			sum += vel[i]
			if vel[i].length() > 1.0e-6:
				seen[names[i]] = true
			check(is_finite(vel[i].x + vel[i].y + vel[i].z) and sg[i] >= 0.0, "%s: конечно" % label)
		var tot: Vector4 = d.total
		check(tot == a.sample(p), "%s: total = sample(FULL) побитно %s" % [label, p])
		var err := (sum - Vector3(tot.x, tot.y, tot.z)).length()
		check(err <= TOL, "%s: Σ vel = total.xyz, ошибка %s в %s" % [label, err, p])
		# повторный вызов — те же числа (запись слагаемых не влияет на расчёт)
		check((a.decompose(p).total as Vector4) == tot, "%s: повторный total" % label)


func test_invariants_calm_day() -> void:
	var seen := {}
	var a: Node = _h._up("gd")
	_check_all(a, "medium", seen)
	check(seen.has("analytic"), "analytic ненулевое")
	check(seen.has("thermal"), "thermal ненулевое")
	check(seen.has("gust"), "gust ненулевое (аналитика без поля)")
	a.free()


func test_invariants_storm_and_wave() -> void:
	for name in ["storm", "wave"]:
		var preset: Dictionary = Config.get_config("weather/%s" % name).duplicate(true)
		var a: Node = _h._up("gd", preset)
		var seen := {}
		_check_all(a, name, seen)
		a.free()


func test_names_fixed() -> void:
	for n in ["field", "analytic", "ridge", "thermal", "storm", "wave", "cloud", "turb", "gust"]:
		check(n in T_NAMES, "имя %s" % n)
	check(T_NAMES.size() == 9, "девять слагаемых")


func test_nan_point() -> void:
	var a: Node = _h._up("gd")
	var d: Dictionary = a.decompose(Vector3(NAN, 0, 0))
	check((d.total as Vector4) == Vector4() and (d.vel as PackedVector3Array).size() == 9, "NaN: нули, длина 9")
	a.free()
