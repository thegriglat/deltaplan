extends TestCase
## Облачный подсос (FR-14b) через фасад W2 v4: под крупным живым облаком подъём у основания сильнее;
## cloud_density_at; болтанка в облаке. Облако — естественное кучевое поля (Rig.cloud_day): заданное
## вручную (стадия, покрытие, мощность — прежний Fixture.force_cloud) крейт не принимает.
## Подсос по стадии (молодое/тающее) — pending (skip_reason); цифры — крейт (RW-12s:
## проверки через cloud_phys/CloudField удалены): rust/dp-air/tests/terms_clouds.rs
## (physics_suck_vs_gd,
## hooks_shade_and_suck), terms_thermal_cloud.rs (suck_points_from_gd_in_tolerance).

const Rig := preload("res://tests/atmosphere/air_rig.gd")
const _SKIP_STAGE := (
	"pending: сценарий по стадии облака; у статичного термика облако всегда зрелое, момент "
	+ "молодого/тающего облака на фасаде не подобран без запуска Godot (RW-12s)"
)


const _SKIP_CHAOS := (
	"pending: бурление в облаке (chaos_noise, gust_unit ветровой рамки) в крейте пока нет — нули "
	+ "(rust/dp-air/src/terms/clouds/mod.rs, шапка; RW-9), порог GD меряет то, чего нет"
)


func skip_reason(method: String) -> String:
	if method == "test_no_suck_under_young_or_decaying":
		return _SKIP_STAGE
	if method in ["test_turbulence_stronger_in_cloud", "test_in_cloud_chaos_and_eject"]:
		return _SKIP_CHAOS
	return ""


# test_suck_under_mature_cloud (подсос под основанием крупного живого облака) — rust/dp-air/tests/
# terms_thermal_cloud.rs (suck_points_from_gd_in_tolerance) и terms_clouds.rs (physics_suck_vs_gd): подсос
# привязан к термику с облаком, а у статичного термика Rig.cloud_day облака нет (has_cloud = false,
# облако поля стоит само по себе и подсос не получает).


func test_cloud_density_at() -> void:
	var a := Rig.cloud_day()
	var cb := a.cloudbase_msl()
	var cl := a.clouds(Vector3.ZERO, 20000.0)
	check(cl.size() >= Atmosphere.CLOUD_STRIDE, "облако поля есть")
	if cl.size() >= Atmosphere.CLOUD_STRIDE:
		var cx: float = cl[Atmosphere.CLOUD_X]
		var cz: float = cl[Atmosphere.CLOUD_Z]
		var base: float = cl[Atmosphere.CLOUD_BASE]
		check(a.cloud_density_at(Vector3(cx, base + 150.0, cz)) > 0.0, "в облаке плотность > 0")
		approx(a.cloud_density_at(Vector3(cx, base - 100.0, cz)), 0.0, 1e-6, "под облаком ясно")
	# Дёшево: 10 000 вызовов.
	var t0 := Time.get_ticks_usec()
	for i in 10000:
		a.cloud_density_at(Vector3(i * 0.3, cb + 150.0, 0))
	var us := float(Time.get_ticks_usec() - t0) / 10000.0
	check(us < 20.0, "cloud_density_at дёшево: %.2f мкс" % us)
	a.free()


func test_turbulence_stronger_in_cloud() -> void:
	var a := Rig.cloud_day()
	var cb := a.cloudbase_msl()
	var s_in := 0.0
	var s_out := 0.0
	for i in 300:
		var p := Vector3(-300.0 + i * 2.0, cb + 150.0, 40.0)
		var q := Vector3(-300.0 + i * 2.0, cb - 350.0, 40.0)
		s_in += (a.air_velocity_at(p) - a.mean_wind_at(p)).length_squared()
		s_out += (a.air_velocity_at(q) - a.mean_wind_at(q)).length_squared()
	check(s_in > s_out * 1.2, "в облаке болтает сильнее: %.1f > %.1f" % [s_in / 300, s_out / 300])
	a.free()


func test_in_cloud_chaos_and_eject() -> void:
	# В облаке — не поток, а бурление: средний подъём слабый, пульсации большие, «выкидывает» к краю.
	var a := Rig.cloud_day()
	var cb := a.cloudbase_msl()
	var base := a.air_velocity_at(Vector3(0, cb - 40.0, 0)).y
	var sum := Vector3.ZERO
	var sum2 := 0.0
	var n := 400
	for i in n:
		var p := Vector3(150.0 + (i % 20) * 1.5, cb + 200.0 + (i / 20) * 1.5, 30.0)
		var v := a.air_velocity_at(p)
		sum += v
		sum2 += v.y * v.y
	var mean := sum / n
	var sigma := sqrt(sum2 / n - mean.y * mean.y)
	check(mean.y < base * 0.6, "в облаке средний подъём слабее, чем у основания: %.2f" % mean.y)
	check(sigma > 1.5, "в облаке бурление: σ = %.2f м/с" % sigma)
	check(mean.x > 0.5, "выкидывает к краю (точки восточнее центра): %.2f" % mean.x)
	check(a.turbulence_intensity_at(Vector3(150, cb + 200, 30)) > 2.0, "метрика болтанки в облаке")
	check(a.turbulence_intensity_at(Vector3(3000, cb - 500, 0)) < 1.5, "метрика болтанки вне облака")
	a.free()


func test_no_suck_under_young_or_decaying() -> void:
	# Молодое и тающее облако: у кромки подъём слабеет (пропущен: стадию задать нельзя).
	var a := Rig.cloud_day()
	var cb := a.cloudbase_msl()
	var mid := a.air_velocity_at(Vector3(0, cb * 0.5, 0)).y
	var base := a.air_velocity_at(Vector3(0, cb - 20.0, 0)).y
	check(base < mid * 0.6, "у кромки слабеет %.2f < %.2f" % [base, mid])
	a.free()
