class_name GroundField
extends RefCounted
## Кеш рельефа для атмосферы: сетка узлов с (высота, dh/dx, dh/dz, линия тени против ветра).
## Считается кусками по запросу и заранее вокруг пилота. Между узлами — билинейная интерполяция,
## поэтому поля гладкие и консоли крыла получают плавно разный поток.
## Линия тени: s = max_i (h(p − ŵ·d_i) − d_i·tan θ) — если пилот ниже неё, он в подветренной зоне.

const _KEY_OFFSET := 1 << 20
const _KEY_MUL := 1 << 21

var has_ground: bool = false
var height_fn: Callable
var sun_fn: Callable

var _cell: float = 30.0
var _inv_cell: float = 1.0 / 30.0
var _n: int = 16  ## клеток в куске
var _stride: int = 17  ## узлов в строке куска (n + 1, перекрытие для интерполяции)
var _max_chunks: int = 400
var _prefetch_r: float = 700.0

## Ветер: куда дует (x, z) — для линии тени.
var _wind_dir: Vector2 = Vector2(0, 1)
var _dists: PackedFloat32Array = PackedFloat32Array()
var _tan_shadow: float = 0.2

var _chunks: Dictionary = {}
var _last_key: int = -1
var _last_data: PackedFloat32Array


func setup(ground_cfg: Dictionary, lee_cfg: Dictionary) -> void:
	_cell = float(ground_cfg.cell_m)
	_inv_cell = 1.0 / _cell
	_n = int(ground_cfg.chunk_cells)
	_stride = _n + 1
	_max_chunks = int(ground_cfg.max_chunks)
	_prefetch_r = float(ground_cfg.prefetch_radius_m)
	_dists = PackedFloat32Array(lee_cfg.upwind_distances_m)
	_tan_shadow = tan(deg_to_rad(float(lee_cfg.shadow_angle_deg)))
	clear()


func set_functions(h_fn: Callable, s_fn: Callable) -> void:
	height_fn = h_fn
	sun_fn = s_fn
	has_ground = h_fn.is_valid()
	clear()


func set_wind_dir(d: Vector2) -> void:
	if d.length_squared() < 1.0e-6:
		return
	_wind_dir = d.normalized()
	clear()


func clear() -> void:
	_chunks.clear()
	_last_key = -1


func height(x: float, z: float) -> float:
	return float(height_fn.call(x, z)) if has_ground else 0.0


func sun(x: float, z: float) -> float:
	return clampf(float(sun_fn.call(x, z)), 0.0, 1.0) if sun_fn.is_valid() else 1.0


## (высота, dh/dx, dh/dz, линия тени) в точке — билинейно по сетке.
func sample(x: float, z: float) -> Vector4:
	if not has_ground:
		return Vector4(0.0, 0.0, 0.0, -1.0e9)
	var fx := x * _inv_cell
	var fz := z * _inv_cell
	var ix := floori(fx)
	var iz := floori(fz)
	var cx := floori(float(ix) / _n)
	var cz := floori(float(iz) / _n)
	var key := (cx + _KEY_OFFSET) * _KEY_MUL + (cz + _KEY_OFFSET)
	var d: PackedFloat32Array
	if key == _last_key:
		d = _last_data
	else:
		d = _chunks.get(key, PackedFloat32Array())
		if d.is_empty():
			d = _build_chunk(cx, cz)
			_store(key, d)
		_last_key = key
		_last_data = d
	var lx := ix - cx * _n
	var lz := iz - cz * _n
	var tx := fx - ix
	var tz := fz - iz
	var i00 := (lz * _stride + lx) * 4
	var i10 := i00 + 4
	var i01 := i00 + _stride * 4
	var i11 := i01 + 4
	var w00 := (1.0 - tx) * (1.0 - tz)
	var w10 := tx * (1.0 - tz)
	var w01 := (1.0 - tx) * tz
	var w11 := tx * tz
	return Vector4(
		d[i00] * w00 + d[i10] * w10 + d[i01] * w01 + d[i11] * w11,
		d[i00 + 1] * w00 + d[i10 + 1] * w10 + d[i01 + 1] * w01 + d[i11 + 1] * w11,
		d[i00 + 2] * w00 + d[i10 + 2] * w10 + d[i01 + 2] * w01 + d[i11 + 2] * w11,
		d[i00 + 3] * w00 + d[i10 + 3] * w10 + d[i01 + 3] * w01 + d[i11 + 3] * w11
	)


## Досчитать один недостающий кусок рядом с точкой (вызывается из step, чтобы не было рывков).
## Возвращает true, если что-то посчиталось.
func prefetch(pos: Vector3) -> bool:
	if not has_ground:
		return false
	var chunk_m := _cell * _n
	var r := int(ceil(_prefetch_r / chunk_m))
	var ccx := floori(pos.x / chunk_m)
	var ccz := floori(pos.z / chunk_m)
	# От ближних к дальним.
	for ring in r + 1:
		for dz in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				if maxi(absi(dx), absi(dz)) != ring:
					continue
				var key := (ccx + dx + _KEY_OFFSET) * _KEY_MUL + (ccz + dz + _KEY_OFFSET)
				if not _chunks.has(key):
					_store(key, _build_chunk(ccx + dx, ccz + dz))
					return true
	return false


func chunk_count() -> int:
	return _chunks.size()


func _store(key: int, d: PackedFloat32Array) -> void:
	if _chunks.size() >= _max_chunks:
		_chunks.clear()
		_last_key = -1
	_chunks[key] = d


func _build_chunk(cx: int, cz: int) -> PackedFloat32Array:
	# Высоты узлов с полем в один узел для центральных разностей.
	var m := _stride + 2
	var hs := PackedFloat32Array()
	hs.resize(m * m)
	var x0 := (cx * _n - 1) * _cell
	var z0 := (cz * _n - 1) * _cell
	for j in m:
		for i in m:
			hs[j * m + i] = float(height_fn.call(x0 + i * _cell, z0 + j * _cell))
	var out := PackedFloat32Array()
	out.resize(_stride * _stride * 4)
	var inv2c := 0.5 / _cell
	for j in _stride:
		for i in _stride:
			var hi := (j + 1) * m + (i + 1)
			var h := hs[hi]
			var wx := x0 + (i + 1) * _cell
			var wz := z0 + (j + 1) * _cell
			var shadow := -1.0e9
			for dist in _dists:
				var hu := (
					float(height_fn.call(wx - _wind_dir.x * dist, wz - _wind_dir.y * dist))
					- dist * _tan_shadow
				)
				shadow = maxf(shadow, hu)
			var o := (j * _stride + i) * 4
			out[o] = h
			out[o + 1] = (hs[hi + 1] - hs[hi - 1]) * inv2c
			out[o + 2] = (hs[hi + m] - hs[hi - m]) * inv2c
			out[o + 3] = shadow
	return out


## Средняя высота земли по сетке вокруг (x, z) — отсчёт для кромки облаков.
func mean_height(cx: float, cz: float, radius: float, samples: int) -> float:
	if not has_ground:
		return 0.0
	var sum := 0.0
	var cnt := 0
	for j in samples:
		for i in samples:
			var u := (float(i) / maxi(samples - 1, 1)) * 2.0 - 1.0
			var v := (float(j) / maxi(samples - 1, 1)) * 2.0 - 1.0
			if u * u + v * v > 1.0:
				continue
			sum += height(cx + u * radius, cz + v * radius)
			cnt += 1
	return sum / maxi(cnt, 1)
