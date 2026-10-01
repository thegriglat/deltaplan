extends SceneTree
## Ряд шума FastNoiseLite (симплекс, без фрактала, частота 1) вдоль прямой — для спектра одной
## октавы (какой длине волны соответствует «масштаб» шума). Пишет csv: x, n.
func _init() -> void:
	var out := "user://noise_line.csv"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	var nz := FastNoiseLite.new()
	nz.seed = 7
	nz.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	nz.fractal_type = FastNoiseLite.FRACTAL_NONE
	nz.frequency = 1.0
	var f := FileAccess.open(out, FileAccess.WRITE)
	var dx := 0.05
	for line in 16:
		var y := 37.3 * line
		for i in 8192:
			f.store_line("%d,%f,%f" % [line, i * dx, nz.get_noise_3d(i * dx * 0.93, y, i * dx * 0.37)])
	f.close()
	quit(0)
