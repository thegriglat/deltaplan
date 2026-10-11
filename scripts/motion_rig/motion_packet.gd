class_name MotionPacket
extends RefCounted
## Упаковка MotionSample в пакеты UDP (MR-К2): srs (SRS API v102, 236 байт) и generic (DPMR, 64 байта).
## Little-endian, смещения — по таблицам контракта.

const SRS_SIZE := 236
const SRS_VERSION := 102
const GENERIC_SIZE := 64
const GENERIC_VERSION := 2
const GENERIC_MAGIC := "DPMR"
const GAME_NAME := "Deltaplan"
const VEHICLE_NAME := "Hang glider"
const STR_LEN := 50


const SIGN_KEYS: PackedStringArray = [
	"surge", "sway", "heave", "roll", "pitch", "yaw", "roll_rate", "pitch_rate", "yaw_rate",
]


## −1 для "inverse", иначе +1 (неизвестное — direct), MR-К3 v2.
static func _sg(signs: Dictionary, key: String) -> float:
	return -1.0 if String(signs.get(key, "direct")) == "inverse" else 1.0


## Поля пакета, которые смешиваются при плавном входе (MR-К2 v3): все float, кроме t.
const BLEND_KEYS: PackedStringArray = [
	"surge", "sway", "heave", "roll", "pitch", "yaw", "roll_rate", "pitch_rate", "yaw_rate", "airspeed", "air_lateral",
]
const FLAG_VALID := 1
const FLAG_GROUND := 2
const FLAG_SYNTHETIC := 4
const FLAG_RAMP := 8


## Итоговые поля пакета (после перевода единиц, множителя на земле и знаков, MR-К2 v3 «Порядок для пакета»):
## словарь {format, surge, sway, heave, roll, pitch, yaw, roll_rate, pitch_rate, yaw_rate, airspeed, air_lateral,
## t, valid, on_ground, synthetic, ramp}. В srs surge/sway/heave — продольное/боковое/вертикальное ускорение
## (heave = heave − G), airspeed — м/с (в км/ч переводит упаковка). ground_scale применяется только к srs.
static func make_frame(s: MotionSample, fmt: String, signs: Dictionary = {}, ground_scale: float = 1.0,
		synthetic: bool = false) -> Dictionary:
	var srs := fmt != "generic"
	var k := ground_scale if srs else 1.0
	var f := {
		"format": "srs" if srs else "generic",
		"surge": s.surge * k * _sg(signs, "surge"),
		"sway": s.sway * k * _sg(signs, "sway"),
		"heave": ((s.heave - Units.G) * k if srs else s.heave) * _sg(signs, "heave"),
		"roll": s.roll * _sg(signs, "roll"),
		"pitch": s.pitch * _sg(signs, "pitch"),
		"yaw": norm_yaw(s.yaw * _sg(signs, "yaw"), srs),
		"roll_rate": s.roll_rate * _sg(signs, "roll_rate"),
		"pitch_rate": s.pitch_rate * _sg(signs, "pitch_rate"),
		"yaw_rate": s.yaw_rate * _sg(signs, "yaw_rate"),
		"airspeed": s.airspeed,
		"air_lateral": s.air_lateral,
		"t": s.t,
		"valid": s.valid,
		"on_ground": s.on_ground,
		"synthetic": synthetic,
		"ramp": false,
	}
	return f


## Курс в диапазон формата: srs (−180, 180], generic [0, 360).
static func norm_yaw(y: float, srs: bool) -> float:
	y = fposmod(y, 360.0)
	if srs and y > 180.0:
		y -= 360.0
	return y


## Смешение a → b с весом w (0 — a, 1 — b); углы — по кратчайшей дуге, курс приводится к диапазону формата b.
## Не смешиваются: t, флаги, формат — берутся из b.
static func blend(a: Dictionary, b: Dictionary, w: float) -> Dictionary:
	var o := b.duplicate()
	for key in BLEND_KEYS:
		var x := float(a[key])
		var y := float(b[key])
		if key == "yaw" or key == "roll":
			o[key] = x + wrapf(y - x, -180.0, 180.0) * w
		else:
			o[key] = x + (y - x) * w
	o["yaw"] = norm_yaw(float(o["yaw"]), b.format == "srs")
	if float(o["roll"]) > 180.0 or float(o["roll"]) <= -180.0:
		o["roll"] = 180.0 - fposmod(180.0 - float(o["roll"]), 360.0)
	return o


## Упаковать итоговые поля (make_frame/blend) в датаграм своего формата. seq — только generic.
static func pack_frame(f: Dictionary, location: String = "", seq: int = 0) -> PackedByteArray:
	if f.format == "generic":
		return _pack_generic_frame(f, seq)
	var b := PackedByteArray()
	b.resize(SRS_SIZE)  # нули
	b.encode_u8(0, 0x61)  # "api"
	b.encode_u8(1, 0x70)
	b.encode_u8(2, 0x69)
	b.encode_u32(4, SRS_VERSION)
	_put_str(b, 8, GAME_NAME)
	_put_str(b, 58, VEHICLE_NAME)
	_put_str(b, 108, location)
	b.encode_float(160, float(f.airspeed) * 3.6)
	b.encode_float(176, f.pitch)
	b.encode_float(180, f.roll)
	b.encode_float(184, f.yaw)
	b.encode_float(188, f.air_lateral)
	b.encode_float(192, f.sway)  # м/с² (MR-К2 v2)
	b.encode_float(196, f.heave)  # heave − G: стоя ≈ 0
	b.encode_float(200, f.surge)
	return b


static func _pack_generic_frame(f: Dictionary, seq: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(GENERIC_SIZE)
	b.encode_u8(0, 0x44)  # "DPMR"
	b.encode_u8(1, 0x50)
	b.encode_u8(2, 0x4D)
	b.encode_u8(3, 0x52)
	b.encode_u32(4, GENERIC_VERSION)
	b.encode_u32(8, seq & 0xFFFFFFFF)
	var flags := (FLAG_VALID if f.valid else 0) | (FLAG_GROUND if f.on_ground else 0)
	flags |= (FLAG_SYNTHETIC if f.synthetic else 0) | (FLAG_RAMP if f.ramp else 0)
	b.encode_u32(12, flags)
	var vals: Array[float] = [
		f.t, f.surge, f.sway, f.heave, f.roll, f.pitch, f.yaw, f.roll_rate, f.pitch_rate, f.yaw_rate,
		f.airspeed, f.air_lateral,
	]
	for i in vals.size():
		b.encode_float(16 + 4 * i, vals[i])
	return b


static func pack_srs(s: MotionSample, location: String = "", signs: Dictionary = {}) -> PackedByteArray:
	return pack_frame(make_frame(s, "srs", signs), location)


static func pack_generic(s: MotionSample, seq: int, signs: Dictionary = {}) -> PackedByteArray:
	return pack_frame(make_frame(s, "generic", signs), "", seq)


## Строка в поле фикс. длины: до 49 байт UTF-8 по границе символа, остальное — нули.
static func _put_str(b: PackedByteArray, at: int, text: String) -> void:
	var bytes := text.to_utf8_buffer()
	var n := mini(bytes.size(), STR_LEN - 1)
	while n > 0 and n < bytes.size() and (bytes[n] & 0xC0) == 0x80:
		n -= 1  # не рвать многобайтный символ
	for i in n:
		b[at + i] = bytes[i]
