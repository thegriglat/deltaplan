extends RefCounted
## Общее для тестов облаков: поле облачности с одним заданным облаком над началом координат.


## Одно облако над (0, 0) — блок 3 × 3 столбцов (ширина ≈ 1,2 км): покрытие, мощность (м над основанием), стадия −1..1,
## активность 0..1. Поле больше не шагается (входы отключены), физика читает заданное.
static func force_cloud(
	a: Atmosphere, cover: float, depth: float, stage: float, activity: float
) -> void:
	var cp := a.cloud_phys
	cp.wait_field()
	cp.inputs_fn = Callable()
	var f := cp.field
	f.setup_grid(21, 21, 400.0, -4200.0, -4200.0)
	f.base_msl = a.get_cloudbase_msl()
	f.bg_cover = 0.0
	f.bg_depth = 0.0
	f.time = a.time_s
	for j in range(9, 12):
		for i in range(9, 12):
			var c := j * 21 + i
			f.cover[c] = cover
			f.depth[c] = depth
			f.stage[c] = stage
			f.activity[c] = activity
	cp._field_count = 1
	a.field.update_time(a.time_s)
