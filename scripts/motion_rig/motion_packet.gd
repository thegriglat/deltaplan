class_name MotionPacket
extends RefCounted
## Упаковка MotionSample в пакеты UDP (MR-К2): srs (SRS API v102, 236 байт) и generic (DPMR, 64 байта).
## Little-endian, смещения — по таблицам контракта.

const SRS_SIZE := 236
const SRS_VERSION := 102
const GENERIC_SIZE := 64
const GENERIC_VERSION := 1
const GENERIC_MAGIC := "DPMR"
const GAME_NAME := "Deltaplan"
const VEHICLE_NAME := "Hang glider"
const STR_LEN := 50


static func pack_srs(s: MotionSample, location: String = "") -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(SRS_SIZE)  # нули
	b.encode_u8(0, 0x61)  # "api"
	b.encode_u8(1, 0x70)
	b.encode_u8(2, 0x69)
	b.encode_u32(4, SRS_VERSION)
	_put_str(b, 8, GAME_NAME)
	_put_str(b, 58, VEHICLE_NAME)
	_put_str(b, 108, location)
	b.encode_float(160, s.airspeed * 3.6)
	b.encode_float(176, s.pitch)
	b.encode_float(180, s.roll)
	var yaw := s.yaw if s.yaw <= 180.0 else s.yaw - 360.0
	b.encode_float(184, yaw)
	b.encode_float(188, s.air_lateral)
	b.encode_float(192, s.sway / Units.G)
	b.encode_float(196, s.heave / Units.G - 1.0)
	b.encode_float(200, s.surge / Units.G)
	return b


static func pack_generic(s: MotionSample, seq: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(GENERIC_SIZE)
	b.encode_u8(0, 0x44)  # "DPMR"
	b.encode_u8(1, 0x50)
	b.encode_u8(2, 0x4D)
	b.encode_u8(3, 0x52)
	b.encode_u32(4, GENERIC_VERSION)
	b.encode_u32(8, seq & 0xFFFFFFFF)
	b.encode_u32(12, (1 if s.valid else 0) | (2 if s.on_ground else 0))
	var vals: Array[float] = [
		s.t, s.surge, s.sway, s.heave, s.roll, s.pitch, s.yaw,
		s.roll_rate, s.pitch_rate, s.yaw_rate, s.airspeed, s.air_lateral,
	]
	for i in vals.size():
		b.encode_float(16 + 4 * i, vals[i])
	return b


## Строка в поле фикс. длины: до 49 байт UTF-8 по границе символа, остальное — нули.
static func _put_str(b: PackedByteArray, at: int, text: String) -> void:
	var bytes := text.to_utf8_buffer()
	var n := mini(bytes.size(), STR_LEN - 1)
	while n > 0 and n < bytes.size() and (bytes[n] & 0xC0) == 0x80:
		n -= 1  # не рвать многобайтный символ
	for i in n:
		b[at + i] = bytes[i]
