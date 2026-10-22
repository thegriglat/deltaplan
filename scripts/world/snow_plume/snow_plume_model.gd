class_name SnowPlumeModel
extends RefCounted
## Модель снежных флагов (SNW-К1/К3/К4 v1, docs/contracts/snow-plume.md): рельеф, снег, ветер, температура
## -> список источников шлейфа. Без узлов сцены; вызывать update() каждый кадр из главного потока.
## Числа DEFAULTS — по К4 v2 и SNW-1 (Li & Pomeroy 1997); игра берёт их из configs/snow_plume.json.

const DEFAULTS := {
	"radius_m": 6000.0, "max_emitters": 24, "update_s": 0.5, "max_wind_samples": 200,
	"scan_step_m": 50.0, "scan_points_per_frame": 1000, "rescan_m": 1000.0, "rescan_dir_deg": 10.0, "dir_tolerance_k": 2.0,
	"fetch_m": 300.0, "lee_slope_deg": 15.0, "spacing_m": 150.0, "snow_min": 0.5,
	"start_agl_m": 3.0, "min_agl_m": 3.0, "path_points": 6, "path_dt_s": 5.0, "span_ms": 8.0,
	"threshold": {"a": 9.43, "b": 0.18, "c": 0.0033, "wet_t_c": 0.0, "wet_u10_ms": 9.9},
}
## Точки снега на наветренном отрезке (доли fetch_m от гребня против ветра).
const SNOW_FRACS := [0.2, 0.5, 0.8]
## Вызовов height_fn/snow_fn на одну точку сетки в худшем случае (3 высоты + 2 высоты + 3 снега).
const POINT_CALLS_MAX := 8
## Источник отбрасывается, если местный ветер повернут от направления скана сильнее,
## чем dir_tolerance_k·rescan_dir_deg (геометрия гребня к нему уже не относится).
## Температура, если temp_fn не задан: порог при −10 °C (сухой снег).
const FALLBACK_T_C := -10.0

var _cfg: Dictionary
var _height_fn: Callable
var _snow_fn: Callable
var _wind_fn: Callable
var _temp_fn: Callable

var _list: Array = []
var _t_since := 1.0e9
var _wind_calls := 0
var _cur_dir := Vector2.ZERO  # последний замеренный ветер у камеры (единичный), ZERO — нет ветра

# готовый скан
var _cands: Array = []  # {ix, iz, pos: Vector3, snow}
var _scan_center := Vector2(1.0e12, 1.0e12)
var _scan_dir := Vector2.ZERO
var _have_scan := false
# скан в работе
var _scanning := false
var _s_center := Vector2.ZERO
var _s_dir := Vector2.ZERO
var _s_ix := 0
var _s_iz := 0
var _s_ix0 := 0
var _s_ix1 := 0
var _s_iz1 := 0
var _s_found: Array = []
var _scan_count := 0
var _scan_calls_last := 0


func _init(cfg: Dictionary, height_fn: Callable, snow_fn: Callable, wind_fn: Callable, temp_fn: Callable) -> void:
	_cfg = DEFAULTS.duplicate(true)
	for k: String in cfg:
		if k == "threshold" and cfg[k] is Dictionary:
			(_cfg.threshold as Dictionary).merge(cfg[k], true)
		else:
			_cfg[k] = cfg[k]
	_height_fn = height_fn
	_snow_fn = snow_fn
	_wind_fn = wind_fn
	_temp_fn = temp_fn if temp_fn.is_valid() else func(_h: float) -> float: return FALLBACK_T_C


# ---------------- SNW-К1 ----------------


## Порог скорости ветра на 10 м над снегом, м/с: a + b·t + c·t² (сухой снег, t <= wet_t_c), иначе wet_u10_ms.
static func threshold_u10(t_c: float, cfg: Dictionary) -> float:
	var th: Dictionary = cfg.get("threshold", DEFAULTS.threshold)
	if t_c > float(th.get("wet_t_c", 0.0)):
		return float(th.get("wet_u10_ms", 12.0))
	return float(th.get("a", 9.0)) + float(th.get("b", 0.0)) * t_c + float(th.get("c", 0.0)) * t_c * t_c


## Сила шлейфа 0..1: (u10 − u_t) / span_ms.
static func intensity(u10: float, u_t: float, cfg: Dictionary) -> float:
	if u10 <= u_t:
		return 0.0
	return clampf((u10 - u_t) / maxf(float(cfg.get("span_ms", 8.0)), 1e-6), 0.0, 1.0)


# ---------------- SNW-К3 ----------------


func wind_calls_last() -> int:
	return _wind_calls


## Число начатых сканов гребней (для тестов и отладки).
func scan_count() -> int:
	return _scan_count


## Вызовов height_fn/snow_fn в последнем кадре скана.
func scan_calls_last() -> int:
	return _scan_calls_last


func update(cam: Vector3, dt: float) -> Array:
	_scan_step()
	_t_since += dt
	if _t_since < float(_cfg.update_s):
		return _list
	_t_since = 0.0
	_refresh(cam)
	return _list


func _refresh(cam: Vector3) -> void:
	_wind_calls = 0
	var cam2 := Vector2(cam.x, cam.z)
	var w0: Vector3 = _wind_fn.call(Vector3(cam.x, _height_fn.call(cam.x, cam.z) + 10.0, cam.z))
	_wind_calls += 1
	var w2 := Vector2(w0.x, w0.z)
	_cur_dir = w2.normalized() if w2.length() > 1e-3 else Vector2.ZERO
	if _cur_dir == Vector2.ZERO:
		_list = []
		return
	_maybe_start_scan(cam2)
	_build_list(cam)


func _maybe_start_scan(cam2: Vector2) -> void:
	var ref_c := _s_center if _scanning else _scan_center
	var ref_d := _s_dir if _scanning else _scan_dir
	var need := not (_scanning or _have_scan)
	if not need:
		need = cam2.distance_to(ref_c) > float(_cfg.rescan_m)
	if not need:
		need = rad_to_deg(absf(ref_d.angle_to(_cur_dir))) > float(_cfg.rescan_dir_deg)
	if not need:
		return
	var s := float(_cfg.scan_step_m)
	var r := float(_cfg.radius_m)
	_scanning = true
	_s_center = cam2
	_s_dir = _cur_dir
	_s_ix0 = int(floor((cam2.x - r) / s))
	_s_ix1 = int(ceil((cam2.x + r) / s))
	_s_iz = int(floor((cam2.y - r) / s))
	_s_iz1 = int(ceil((cam2.y + r) / s))
	_s_ix = _s_ix0
	_s_found = []
	_scan_count += 1


## Один кадр скана: не больше scan_points_per_frame вызовов height_fn/snow_fn.
func _scan_step() -> void:
	_scan_calls_last = 0
	if not _scanning:
		return
	var budget := int(_cfg.scan_points_per_frame)
	var s := float(_cfg.scan_step_m)
	var r2 := float(_cfg.radius_m) * float(_cfg.radius_m)
	var d := _s_dir
	var fetch := float(_cfg.fetch_m)
	var tan_lee := tan(deg_to_rad(float(_cfg.lee_slope_deg)))
	var snow_min := float(_cfg.snow_min)
	var calls := 0
	while _s_iz <= _s_iz1:
		if calls + POINT_CALLS_MAX > budget and calls > 0:
			break
		var x := float(_s_ix) * s
		var z := float(_s_iz) * s
		var ix := _s_ix
		var iz := _s_iz
		_s_ix += 1
		if _s_ix > _s_ix1:
			_s_ix = _s_ix0
			_s_iz += 1
		if Vector2(x, z).distance_squared_to(_s_center) > r2:
			continue
		var h0: float = _height_fn.call(x, z)
		var hw: float = _height_fn.call(x - d.x * s, z - d.y * s)
		calls += 2
		if hw >= h0:
			continue
		var hl: float = _height_fn.call(x + d.x * s, z + d.y * s)
		calls += 1
		if hl > h0:
			continue
		var h_up: float = _height_fn.call(x - d.x * fetch, z - d.y * fetch)
		var h_dn: float = _height_fn.call(x + d.x * fetch, z + d.y * fetch)
		calls += 2
		if h_up >= h0 or (h0 - h_dn) < tan_lee * fetch:
			continue
		var sn := 0.0
		for f: float in SNOW_FRACS:
			sn += float(_snow_fn.call(x - d.x * fetch * f, z - d.y * fetch * f))
			calls += 1
		sn /= float(SNOW_FRACS.size())
		if sn < snow_min:
			continue
		_s_found.append({"ix": ix, "iz": iz, "pos": Vector3(x, h0, z), "snow": sn})
	_scan_calls_last = calls
	if _s_iz > _s_iz1:
		_finish_scan()


func _finish_scan() -> void:
	# прореживание: жадно в порядке сетки (iz, ix) — детерминированно, id стабильны
	var sp := maxf(float(_cfg.spacing_m), 1.0)
	var grid := {}
	var kept: Array = []
	for c: Dictionary in _s_found:
		var p: Vector3 = c.pos
		var gx := int(floor(p.x / sp))
		var gz := int(floor(p.z / sp))
		var ok := true
		for j in range(gz - 1, gz + 2):
			for i in range(gx - 1, gx + 2):
				for q: Vector3 in grid.get(Vector2i(i, j), []):
					if Vector2(q.x - p.x, q.z - p.z).length() < sp:
						ok = false
		if ok:
			var key := Vector2i(gx, gz)
			if not grid.has(key):
				grid[key] = []
			grid[key].append(p)
			kept.append(c)
	_cands = kept
	_scan_center = _s_center
	_scan_dir = _s_dir
	_have_scan = true
	_scanning = false
	_s_found = []


func _build_list(cam: Vector3) -> void:
	var cam2 := Vector2(cam.x, cam.z)
	var r := float(_cfg.radius_m)
	var near: Array = []
	for c: Dictionary in _cands:
		var p: Vector3 = c.pos
		var dist := Vector2(p.x, p.z).distance_to(cam2)
		if dist <= r:
			near.append([dist, c])
	near.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var out: Array = []
	var max_n := int(_cfg.max_emitters)
	var max_w := int(_cfg.max_wind_samples)
	var np := clampi(int(_cfg.path_points), 2, 8)
	var dt_p := float(_cfg.path_dt_s)
	var min_agl := float(_cfg.min_agl_m)
	var tol := cos(deg_to_rad(float(_cfg.rescan_dir_deg) * float(_cfg.dir_tolerance_k)))
	for e: Array in near:
		if out.size() >= max_n or _wind_calls >= max_w:
			break
		var c: Dictionary = e[1]
		var pos: Vector3 = c.pos
		var wv: Vector3 = _wind_fn.call(pos + Vector3(0.0, 10.0, 0.0))
		_wind_calls += 1
		var w2 := Vector2(wv.x, wv.z)
		var u10 := w2.length()
		if u10 < 1e-3:
			continue
		var u_t := threshold_u10(float(_temp_fn.call(pos.y)), _cfg)
		var inten := intensity(u10, u_t, _cfg)
		if inten <= 0.0:
			continue
		var wd := w2 / u10
		if wd.dot(_scan_dir) < tol:
			continue
		if _wind_calls + np > max_w:
			break
		var path := PackedVector3Array()
		var vel := PackedVector3Array()
		var q := pos + Vector3(0.0, float(_cfg.start_agl_m), 0.0)
		for i in np:
			q.y = maxf(q.y, float(_height_fn.call(q.x, q.z)) + min_agl)
			var v: Vector3 = _wind_fn.call(q)
			_wind_calls += 1
			path.append(q)
			vel.append(v)
			q = q + v * dt_p
		out.append({
			"id": (int(c.ix) * 73856093) ^ (int(c.iz) * 19349663),
			"pos": pos, "dir": Vector3(wd.x, 0.0, wd.y), "u10": u10, "u_t": u_t,
			"intensity": inten, "snow": float(c.snow), "width_m": float(_cfg.spacing_m),
			"path": path, "vel": vel, "path_dt": dt_p,
		})
	_list = out
