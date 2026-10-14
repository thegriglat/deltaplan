extends Node
## Рывок при смене пресета графики в полёте (SL-23): сцена terrain_preview (те же аргументы), после
## разгона — смены пресета по списку (GraphicsPresets.select → Config.reload → TerrainRenderer
## меняет шейдеры материалов), по каждой: время вызова select, худший кадр за SETTLE кадров после, мс.
## vsync выключен; время кадра — по часам CPU (включает ожидание GPU и компиляцию шейдеров).
##   godot --path . --resolution 1920x1080 res://tools/terrain/variant_switch.tscn -- \
##     --location=ongudai --site=kayancha_south --agl=800 --switch=low,medium,high,low [--keep-variant]
## --keep-variant — «как до вариантов»: пресеты меняют всё, кроме terrain.variant* (все — full, без far).
## Печать: VARIANT_SWITCH_JSON:{...} и выход.

const WARM := 240
const SETTLE := 90

var _seq: PackedStringArray = []
var _keep := false
var _frame := 0
var _i := -1
var _since := 0
var _t_prev := 0
var _worst := 0.0
var _base: Array[float] = []
var _res: Array[Dictionary] = []
var _cur := {}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--switch="):
			_seq = a.substr(9).split(",", false)
		elif a == "--keep-variant":
			_keep = true
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	add_child((load("res://scenes/terrain/terrain_preview.tscn") as PackedScene).instantiate())
	_t_prev = Time.get_ticks_usec()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var dt := (now - _t_prev) / 1000.0
	_t_prev = now
	_frame += 1
	if _frame < WARM:
		if _frame > WARM - 60:
			_base.append(dt)
		return
	if _i >= 0:
		_since += 1
		_worst = maxf(_worst, dt)
		if _since < SETTLE:
			return
		_cur["worst_frame_ms"] = snappedf(_worst, 0.01)
		_res.append(_cur)
	_i += 1
	if _i >= _seq.size():
		_base.sort()
		var out := {
			"base_frame_ms_median": snappedf(_base[_base.size() / 2], 0.01) if not _base.is_empty() else 0.0,
			"keep_variant": _keep,
			"switches": _res,
		}
		print("VARIANT_SWITCH_JSON:" + JSON.stringify(out))
		get_tree().quit()
		return
	var p := _seq[_i]
	if _keep:
		# пресеты без своих вариантов рельефа (как до SL-23): в памяти, до select (он читает game.json из Config)
		for k: String in Config.get_config("game").get("graphics_presets", {}):
			var pr = Config.get_config("game").graphics_presets[k]
			if pr is Dictionary and pr.has("configs") and pr.configs.has("world"):
				pr.configs.world["terrain"] = {"variant": "full", "variant_far": ""}
	var t0 := Time.get_ticks_usec()
	GraphicsPresets.select(p)
	var call_ms := (Time.get_ticks_usec() - t0) / 1000.0
	_cur = {"to": p, "select_ms": snappedf(call_ms, 0.01)}
	_since = 0
	_worst = 0.0
	_t_prev = Time.get_ticks_usec()
