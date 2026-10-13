extends SceneTree
## Замер текстур крыльев: время загрузки и погрешность против исходного PNG.
## Запуск (с окном, временный профиль): godot --path . --script tools/research/wing_textures/measure.gd -- out.csv [шаг]
## Формат строки csv: вид,крыло,мс_загрузки,формат,метрика1,метрика2
##   sail:   PSNR по RGB, дБ | средняя абс. ошибка (0..255) по RGB
##   normal: средний угол, град | 95-й процентиль угла, град (z восстановлен из xy)
##   trans:  PSNR канала R, дБ | средняя абс. ошибка (0..255)
## Погрешность — по уровню mip 0 после декомпрессии (то, что видит шейдер на максимальном приближении).

const SAIL := "res://assets/shaders/sail/"
const MODELS := "res://assets/models/"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out_path: String = args[0] if args.size() > 0 else "measure.csv"
	var step := int(args[1]) if args.size() > 1 else 1
	# Крылья и файлы карт — по sail_maps.json (одинаковые карты хранятся одним файлом).
	var maps: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SAIL + "sail_maps.json"))
	var names: Array[String] = []
	for k in maps:
		names.append(k)
	names.sort()
	var lines: PackedStringArray = []
	for i in range(0, names.size(), step):
		var n := names[i]
		lines.append(_one("sail", n, MODELS + "%s_%s_sail.png" % [n, n]))
		lines.append(_one("normal", n, SAIL + maps[n].normal + "_normal.png"))
		lines.append(_one("trans", n, SAIL + maps[n].trans + "_trans.png"))
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	f.store_string("\n".join(lines) + "\n")
	f.close()
	quit()


func _one(kind: String, n: String, path: String) -> String:
	var t0 := Time.get_ticks_usec()
	var tex := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as Texture2D
	var img := tex.get_image()
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	var fmt := img.get_format()
	if img.is_compressed():
		img.decompress()
	var ref := Image.load_from_file(path)
	ref.convert(Image.FORMAT_RGBA8)
	if img.get_width() != ref.get_width():
		img.resize(ref.get_width(), ref.get_height())
	img.convert(Image.FORMAT_RGBA8)
	var a := ref.get_data()
	var b := img.get_data()
	var m1 := 0.0
	var m2 := 0.0
	if kind == "normal":
		var angs := PackedFloat32Array()
		var cnt := a.size() / 4
		angs.resize(cnt)
		var sum := 0.0
		for p in cnt:
			var va := _nrm(a[p * 4], a[p * 4 + 1])
			var vb := _nrm(b[p * 4], b[p * 4 + 1])
			var ang := rad_to_deg(acos(clampf(va.dot(vb), -1.0, 1.0)))
			angs[p] = ang
			sum += ang
		m1 = sum / cnt
		angs.sort()
		m2 = angs[int(cnt * 0.95)]
	else:
		var chans := 3 if kind == "sail" else 1
		var se := 0.0
		var ae := 0.0
		var cnt := a.size() / 4
		for p in cnt:
			for c in chans:
				var d := float(a[p * 4 + c]) - float(b[p * 4 + c])
				se += d * d
				ae += absf(d)
		var mse := se / (cnt * chans)
		m1 = 99.0 if mse < 1e-9 else 10.0 * log(255.0 * 255.0 / mse) / log(10.0)
		m2 = ae / (cnt * chans)
	return "%s,%s,%.1f,%d,%.3f,%.3f" % [kind, n, ms, fmt, m1, m2]


func _nrm(r: int, g: int) -> Vector3:
	var x := r / 255.0 * 2.0 - 1.0
	var y := g / 255.0 * 2.0 - 1.0
	var z := sqrt(maxf(0.0, 1.0 - x * x - y * y))
	return Vector3(x, y, z).normalized()
