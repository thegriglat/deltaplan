class_name TowTrikeSound
extends AudioStreamPlayer3D
## Звук двигателя буксировщика-дельталёта (TT-К5): синтез двухтактного двухцилиндрового Rotax 582 + винт.
## Основная частота — вспышки: rpm_двигателя/60 · 2 (два цилиндра, вспышка на каждом обороте; rpm_двигателя =
## prop_rpm · gear_ratio) плюс частота лопастей prop_rpm/60 · prop_blades. Петля 1 с синтезирована на опорных оборотах
## REF_FLASH_HZ, дальше высота — pitch_scale = prop_rpm / обороты_опорные (оба тона масштабируются вместе, их
## отношение gear_ratio·2 / blades постоянно, как у настоящего двигателя). Громкость — от газа.
## Модель границ: спектр не измерен, а подобран (резкая вспышка с экспоненциальным спадом, гармоники, шум выхлопа);
## частоты и их отношение — физические. Лопасти округлены до целого числа периодов на петлю (до ±0,5 Гц).

const RATE := 22050
const REF_FLASH_HZ := 140.0  ## вспышки на опорных оборотах
const VOL_IDLE_DB := -14.0
const VOL_FULL_DB := -2.0

var ref_prop_rpm := 1.0  ## обороты винта, на которых записана петля
var gear_ratio := 3.47
var blades := 2
var prop_rpm_idle := 0.0  ## обороты винта на холостых (TP-К9: ниже них громкость падает с оборотами)
var cabin_offset_db := 0.0
var _player_mode := false


## gear_ratio, blades — из configs/tow_tug.json engine. Возвращает петлю и опорные обороты винта.
static func build_stream(gear_ratio_: float, blades_: int) -> Dictionary:
	var rev_hz := REF_FLASH_HZ / 2.0  ## обороты двигателя, об/с
	var prop_hz := rev_hz / gear_ratio_
	var blade_hz := roundf(prop_hz * blades_)  ## целое число периодов за секунду
	var data := PackedByteArray()
	data.resize(RATE * 2)
	var lp := 0.0
	var seed_v := 4242
	var flash_n := int(REF_FLASH_HZ)
	for i in RATE:
		var t := float(i) / RATE
		# вспышки: k-я вспышка в k/flash_n с; цилиндры чередуются по амплитуде (неодинаковость)
		var ph := fposmod(t * flash_n, 1.0)
		var cyl := int(floor(t * flash_n)) % 2
		var env := exp(-ph * 9.0)
		var amp := 1.0 if cyl == 0 else 0.8
		var tone := 0.0
		for k in 6:
			tone += sin(TAU * (k + 1) * ph + 0.5 * k) / float(k + 1)
		var pulse := env * amp * tone
		seed_v = (seed_v * 1103515245 + 12345) & 0x7fffffff
		var noise := float(seed_v) / 1073741824.0 - 1.0
		lp += 0.25 * (noise - lp)
		var s := 0.55 * pulse + 0.30 * lp * (0.4 + env) + 0.22 * sin(TAU * blade_hz * t)
		data.encode_s16(i * 2, int(clampf(s * 0.6, -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = RATE
	return {"stream": w, "ref_prop_rpm": rev_hz * 60.0 / gear_ratio_, "blade_hz": blade_hz}


func setup(engine_cfg: Dictionary) -> void:
	gear_ratio = float(engine_cfg.get("gear_ratio", 3.47))
	blades = int(engine_cfg.get("prop_blades", 2))
	var b := build_stream(gear_ratio, blades)
	stream = b.stream
	ref_prop_rpm = float(b.ref_prop_rpm)
	bus = "Ambient" if AudioServer.get_bus_index("Ambient") >= 0 else "Master"
	attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	unit_size = 20.0
	max_distance = 1200.0
	attenuation_filter_cutoff_hz = 5000.0
	doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_IDLE_STEP
	autoplay = true
	update(ref_prop_rpm, 0.0)


## Основная частота вспышек, Гц, при оборотах винта prop_rpm.
func flash_hz(prop_rpm: float) -> float:
	return prop_rpm * gear_ratio / 60.0 * 2.0


## Частота лопастей, Гц.
func blade_hz(prop_rpm: float) -> float:
	return prop_rpm / 60.0 * blades


func update(prop_rpm: float, throttle: float) -> void:
	pitch_scale = clampf(prop_rpm / ref_prop_rpm, 0.05, 8.0)
	volume_db = lerpf(VOL_IDLE_DB, VOL_FULL_DB, clampf(throttle, 0.0, 1.0))


## TP-К9: настройка для игрока. engine_cfg — блок engine (configs/tow_tug.json), sound_cfg — configs/trike_pilot.json →
## sound: volume_offset_db, unit_size_m, max_distance_m, filter_cutoff_hz. Автозапуска нет: звук идёт по update_engine.
func setup_player(engine_cfg: Dictionary, sound_cfg: Dictionary) -> void:
	setup(engine_cfg)
	_player_mode = true
	prop_rpm_idle = float(engine_cfg.get("prop_rpm_idle", 0.0))
	cabin_offset_db = float(sound_cfg.get("volume_offset_db", 0.0))
	unit_size = float(sound_cfg.get("unit_size_m", unit_size))
	max_distance = float(sound_cfg.get("max_distance_m", max_distance))
	attenuation_filter_cutoff_hz = float(sound_cfg.get("filter_cutoff_hz", attenuation_filter_cutoff_hz))
	doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED  ## двигатель едет вместе с слушателем
	autoplay = false
	stop()
	update_engine("off", 0.0, 0.0)


## Громкость, дБ, по состоянию (без смещения кабины): газ — как TT-К5; ниже холостых оборотов (запуск/остановка) —
## мощность звука ∝ n^4 (−40·lg(idle/n) дБ), чтобы не было щелчка на старте и остановке.
func engine_volume_db(prop_rpm: float, throttle: float) -> float:
	var v := lerpf(VOL_IDLE_DB, VOL_FULL_DB, clampf(throttle, 0.0, 1.0))
	if prop_rpm_idle > 0.0 and prop_rpm < prop_rpm_idle:
		v += 40.0 * log(maxf(prop_rpm, 1.0) / prop_rpm_idle) / log(10.0)
	return maxf(v, -80.0)


## Состояние TrikeEngine (TP-К2): state "off" — тишина; иначе звук идёт за prop_rpm (высота непрерывна по оборотам).
func update_engine(state: String, prop_rpm: float, throttle: float) -> void:
	if state == "off" or prop_rpm <= 0.0:
		if playing:
			stop()
		return
	pitch_scale = clampf(prop_rpm / ref_prop_rpm, 0.05, 8.0)
	volume_db = engine_volume_db(prop_rpm, throttle) + cabin_offset_db
	if not playing:
		play()
