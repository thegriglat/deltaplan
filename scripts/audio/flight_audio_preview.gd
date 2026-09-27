extends Node
## Стенд звуков полёта: синтетический сценарий «карабин → шаг → разбег → взлёт →
## полёт 30–80 км/ч с виражами и болтанкой → сваливание → посадка → одышка».
## Аргументы (после --): --record=путь.wav (записать шину Master в WAV и выйти в конце),
##   --seed=N. Числа сценария — не конфиг игры, а только стенд.

## Ключевые точки сценария: [время с, фаза, путевая скорость м/с, воздушная км/ч,
## высота над землёй м, крен °, болтанка 0..1, сваливание 0..1, скольжение °].
const TIMELINE: Array = [
	[0.0, "standing", 0.0, 11.0, 0.0, 0.0, 0.0, 0.0, 0.0],
	[2.5, "standing", 0.0, 11.0, 0.0, 0.0, 0.0, 0.0, 0.0],
	[2.6, "walking", 1.4, 16.0, 0.0, 0.0, 0.0, 0.0, 0.0],
	[5.0, "walking", 1.4, 16.0, 0.0, 0.0, 0.0, 0.0, 0.0],
	[5.1, "running", 3.0, 22.0, 0.0, 0.0, 0.0, 0.0, 0.0],
	[10.0, "running", 6.0, 32.0, 0.0, 0.0, 0.0, 0.0, 0.0],
	[10.1, "flying", 6.0, 33.0, 1.0, 0.0, 0.1, 0.0, 0.0],
	[16.0, "flying", 9.0, 40.0, 60.0, 0.0, 0.2, 0.0, 0.0],
	[22.0, "flying", 16.0, 65.0, 120.0, 0.0, 0.3, 0.0, 5.0],
	[28.0, "flying", 20.0, 80.0, 150.0, 0.0, 0.2, 0.0, -8.0],
	[34.0, "flying", 10.0, 38.0, 170.0, 45.0, 0.6, 0.0, 0.0],
	[40.0, "flying", 9.0, 36.0, 180.0, 45.0, 0.8, 0.0, 0.0],
	[44.0, "flying", 7.0, 29.0, 170.0, 0.0, 0.3, 0.0, 0.0],
	[46.0, "flying", 6.0, 25.0, 160.0, 0.0, 0.3, 1.0, 0.0],
	[48.0, "flying", 12.0, 50.0, 130.0, 0.0, 0.3, 0.0, 0.0],
	[58.0, "flying", 9.0, 38.0, 20.0, 0.0, 0.2, 0.0, 0.0],
	[62.0, "flying", 6.0, 29.0, 0.5, 0.0, 0.1, 0.4, 0.0],
	[62.1, "landed", 0.0, 11.0, 0.0, 0.0, 0.0, 0.0, 0.0],
	[70.0, "landed", 0.0, 11.0, 0.0, 0.0, 0.0, 0.0, 0.0],
]
const CARABINER_AT_S := 1.0
const LANDING_AT_S := 62.1

var t := Telemetry.new()
var _time := 0.0
var _args := {}
var _record: AudioEffectRecord
var _carabiner_done := false
var _landed := false
var _last_print := -1

@onready var audio: FlightAudio = $FlightAudio


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			_args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if _args.has("seed"):
		audio.setup(Config.get_config("audio").flight, int(_args.seed))
	if _args.has("record"):
		_record = AudioEffectRecord.new()
		AudioServer.add_bus_effect(0, _record)
		_record.set_recording_active(true)


func _physics_process(delta: float) -> void:
	_time += delta
	var k := _sample(_time)
	var phase := String(k[1])
	t.on_ground = phase != "flying"
	t.groundspeed = float(k[2])
	t.airspeed = Units.kmh(float(k[3]))
	t.altitude_agl = float(k[4])
	t.bank_deg = float(k[5])
	t.stalled = float(k[7]) > 0.5
	var extra := {
		"phase": phase,
		"turbulence": float(k[6]),
		"stall_amount": float(k[7]),
		"sideslip_deg": float(k[8]),
		"ground_wind_ms": 3.0,
	}
	audio.update(t, extra)
	if not _carabiner_done and _time >= CARABINER_AT_S:
		_carabiner_done = true
		audio.play_carabiner()
	if not _landed and _time >= LANDING_AT_S:
		_landed = true
		audio.play_landing({"grade": "soft", "vertical_speed_ms": 1.2})
	var sec := int(_time)
	if sec != _last_print and sec % 5 == 0:
		_last_print = sec
		print("%3d с  %-8s  %3.0f км/ч  AGL %4.0f м" % [sec, phase, float(k[3]), float(k[4])])
	if _time >= float(TIMELINE[-1][0]):
		_finish()


func _finish() -> void:
	set_physics_process(false)
	if _record:
		_record.set_recording_active(false)
		var wav := _record.get_recording()
		if wav:
			wav.save_to_wav(String(_args.record))
			print("записано: ", _args.record)
		AudioServer.remove_bus_effect(0, AudioServer.get_bus_effect_count(0) - 1)
		_record = null
	if _args.has("record"):
		# Дать аудиосерверу отпустить потоки перед выходом.
		audio.queue_free()
		for i in 3:
			await get_tree().process_frame
		# Аудиопоток удаляет остановленные playback асинхронно.
		OS.delay_msec(150)
		get_tree().quit()


## Линейная интерполяция точек сценария (фаза — от левой точки).
func _sample(time_s: float) -> Array:
	for i in range(1, TIMELINE.size()):
		var b: Array = TIMELINE[i]
		if time_s <= float(b[0]):
			var a: Array = TIMELINE[i - 1]
			var f := (time_s - float(a[0])) / maxf(float(b[0]) - float(a[0]), 1e-6)
			var out: Array = [time_s, a[1]]
			for j in range(2, a.size()):
				out.append(lerpf(float(a[j]), float(b[j]), f))
			return out
	return TIMELINE[-1]
