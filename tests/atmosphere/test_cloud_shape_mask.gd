extends TestCase
## Маска отдельных кучевых слоя поля (CLK-2): текстура шума RGB (G — маска, B — её крупная часть),
## квантили суммы двух выборок G (CloudLayer.noise_quantiles) дают площадь под облаками = покрытие,
## константы нормировки в cloud_common.gdshaderinc согласованы с текстурой.

const TEX := "res://assets/textures/clouds/cloud_shape.png"
const SHADER := "res://scripts/atmosphere/cloud_common.gdshaderinc"


## Срезы из атласа PNG (16 × 8 срезов по 128²; как slices/horizontal в .import) — без рендерера.
func _slices() -> Array[Image]:
	var atlas := Image.load_from_file(ProjectSettings.globalize_path(TEX))
	var out: Array[Image] = []
	check(atlas != null, "атлас PNG читается")
	if atlas == null:
		return out
	atlas.convert(Image.FORMAT_RGB8)
	for z in 128:
		out.append(atlas.get_region(Rect2i((z % 16) * 128, (z / 16) * 128, 128, 128)))
	return out


static func _const(name: String) -> float:
	var f := FileAccess.open(SHADER, FileAccess.READ)
	var re := RegEx.create_from_string("const float %s = ([-0-9.]+);" % name)
	var m := re.search(f.get_as_text())
	return float(m.get_string(1)) if m != null else NAN


func test_channels_present() -> void:
	var sl := _slices()
	check(sl.size() == 128, "128 срезов (%d)" % sl.size())
	if sl.is_empty():
		return
	for ch in [1, 2]:
		var lo := 255
		var hi := 0
		for z in [0, 40, 80, 120]:
			var d := sl[z].get_data()
			for k in range(ch, d.size(), 3 * 11):
				lo = mini(lo, d[k])
				hi = maxi(hi, d[k])
		check(lo < 40 and hi > 215, "канал %d занимает диапазон (%d…%d)" % [ch, lo, hi])


func test_quantiles_monotone() -> void:
	var q := CloudLayer.slice_quantiles(_slices())
	check(q.size() == 16, "16 квантилей")
	for k in range(1, 16):
		check(q[k] >= q[k - 1], "квантили не убывают (%d)" % k)
	check(q[15] > 1.2 and q[15] < 1.95, "верх шкалы — не предел носителя (%.3f)" % q[15])
	check(q[8] > 0.8 and q[8] < 1.2, "середина суммы около 1 (%.3f)" % q[8])


func test_area_equals_cover() -> void:
	var sl := _slices()
	if sl.is_empty():
		return
	var q := CloudLayer.slice_quantiles(sl)
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var n := 60000
	var sums := PackedFloat32Array()
	sums.resize(n)
	var datas: Array[PackedByteArray] = []
	for im in sl:
		datas.append(im.get_data())
	for i in n:
		var s := 0.0
		for j in 2:
			var z := rng.randi() % 128
			var p := rng.randi() % (128 * 128)
			s += datas[z][p * 3 + 1] / 255.0
		sums[i] = s
	for cover in [0.1, 0.2, 0.35, 0.5]:
		# Порог — как cf_threshold в шейдере.
		var x := clampf(1.0 - cover, 0.0, 1.0) * 15.0
		var i0 := mini(int(x), 14)
		var thr := lerpf(q[i0], q[i0 + 1], x - i0)
		var above := 0
		for s in sums:
			if s > thr:
				above += 1
		approx(float(above) / n, cover, 0.03, "доля маски выше порога при покрытии %.2f" % cover)


func test_xi_constants_match_texture() -> void:
	var sl := _slices()
	if sl.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	var datas: Array[PackedByteArray] = []
	for im in sl:
		datas.append(im.get_data())
	var n := 60000
	var sum := 0.0
	var sum2 := 0.0
	for i in n:
		var s := 0.0
		for j in 2:
			s += datas[rng.randi() % 128][(rng.randi() % (128 * 128)) * 3 + 2] / 255.0
		sum += s
		sum2 += s * s
	var mean := sum / n
	var sd := sqrt(maxf(sum2 / n - mean * mean, 0.0))
	approx(_const("CF_XI_MU"), mean, 0.02, "CF_XI_MU — среднее суммы двух выборок B")
	approx(_const("CF_XI_SD"), sd, 0.02, "CF_XI_SD — СКО суммы двух выборок B")
	check(_const("CF_W_MIN") < _const("CF_W_MAX") and _const("CF_ASPECT") > 0.3 and _const("CF_ASPECT") < 1.0, "размеры и высота/ширина в разумных границах")
