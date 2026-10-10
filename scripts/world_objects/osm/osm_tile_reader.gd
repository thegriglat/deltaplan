class_name OsmTileReader
extends RefCounted
## Разбор файла тайла OSM (контракты O2/O3, docs/contracts/osm-tiles.md): заголовок DPOT, один кадр
## zstd, protobuf вручную, потоки O3 → словарь в координатах тайла (целые метры, x восток, y север).
## Вид словаря — как у `osmtiles dump` (O5), поток — массив объектов:
##   {format_version, j, i, n, osm_timestamp, sources: [String], header: {magic, version, flags, raw_len},
##    streams: {"roads": [...], ..., "names": [String]}}
## Дороги/track — {cls, width_dm|null, lanes|null, tunnel, bridge, pts: PackedVector2Array};
## дома — {x, y, w2, l2, angle, hq, lv, type}; остальные — {cls, flags, h, pts}.
## Не использует дерево сцены: вызывается на рабочих потоках. Ошибка формата — пустой словарь и строка в лог.

const MAGIC := "DPOT"
const HEADER_LEN := 16
const MAX_RAW := 64 * 1024 * 1024

## Kind → имя потока (как у dump и stats).
const KIND_NAMES := {
	1: "roads", 2: "track", 3: "buildings", 4: "powerline", 5: "power_tower", 6: "aerialway",
	7: "aeroway", 8: "vertical", 9: "rail", 10: "peak", 11: "pass", 12: "names", 13: "river", 14: "canal"
}


static func read(bytes: PackedByteArray) -> Dictionary:
	var h := read_header(bytes)
	if h.is_empty():
		return {}
	var raw := bytes.slice(HEADER_LEN).decompress(int(h.raw_len), FileAccess.COMPRESSION_ZSTD)
	if raw.size() != int(h.raw_len):
		print("OsmTileReader: zstd — получено %d Б из %d" % [raw.size(), int(h.raw_len)])
		return {}
	var tile := _parse_tile(raw)
	if tile.is_empty():
		return {}
	tile["header"] = h
	return tile


## Заголовок O2 {magic, version, flags, raw_len}; пустой словарь — не наш файл. Фрагмент (бит 0) —
## не итоговый тайл, клиент его не читает.
static func read_header(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() <= HEADER_LEN or bytes.slice(0, 4).get_string_from_ascii() != MAGIC:
		print("OsmTileReader: нет магии DPOT")
		return {}
	var version := bytes.decode_u16(4)
	var flags := bytes.decode_u16(6)
	var raw_len := bytes.decode_u32(8)
	if version != 1 or (flags & 1) != 0 or raw_len == 0 or raw_len > MAX_RAW:
		print("OsmTileReader: версия %d, флаги %d, raw_len %d" % [version, flags, raw_len])
		return {}
	return {"magic": MAGIC, "version": version, "flags": flags, "raw_len": raw_len}


# ---------- protobuf ----------

## Читатель varint: позиция в p[0].
static func _varint(b: PackedByteArray, p: PackedInt32Array) -> int:
	var pos := p[0]
	var v := 0
	var shift := 0
	var n := b.size()
	while pos < n:
		var c := b[pos]
		pos += 1
		v |= (c & 0x7F) << shift
		if c < 0x80:
			p[0] = pos
			return v
		shift += 7
		if shift > 63:
			break
	p[0] = n + 1  # ошибка: вышли за конец
	return 0


static func _zz(v: int) -> int:
	return (v >> 1) ^ -(v & 1)


static func _skip(b: PackedByteArray, p: PackedInt32Array, wire: int) -> void:
	match wire:
		0:
			_varint(b, p)
		1:
			p[0] += 8
		2:
			var l := _varint(b, p)
			p[0] += l
		5:
			p[0] += 4
		_:
			p[0] = b.size() + 1


static func _parse_tile(raw: PackedByteArray) -> Dictionary:
	var out := {"format_version": 0, "j": 0, "i": 0, "n": 0, "osm_timestamp": 0,
		"sources": [] as Array, "streams": {}}
	var p := PackedInt32Array([0])
	var n := raw.size()
	while p[0] < n:
		var tag := _varint(raw, p)
		var field := tag >> 3
		var wire := tag & 7
		if field == 1 and wire == 0:
			out.format_version = _varint(raw, p)
		elif field == 2 and wire == 0:
			out.j = _zz(_varint(raw, p))
		elif field == 3 and wire == 0:
			out.i = _varint(raw, p)
		elif field == 4 and wire == 0:
			out.n = _varint(raw, p)
		elif field == 5 and wire == 0:
			out.osm_timestamp = _varint(raw, p)
		elif field == 6 and wire == 2:
			var l := _varint(raw, p)
			out.sources.append(raw.slice(p[0], p[0] + l).get_string_from_utf8())
			p[0] += l
		elif field == 7 and wire == 2:
			var l := _varint(raw, p)
			var end: int = p[0] + l
			if end > n:
				return _fail("поток за концом данных")
			_parse_stream(raw.slice(p[0], end), out.streams)
			p[0] = end
		else:
			_skip(raw, p, wire)
		if p[0] > n:
			return _fail("протобуф оборван")
	if int(out.format_version) != 1:
		return _fail("format_version %d" % int(out.format_version))
	return out


static func _fail(msg: String) -> Dictionary:
	print("OsmTileReader: " + msg)
	return {}


static func _parse_stream(b: PackedByteArray, streams: Dictionary) -> void:
	var p := PackedInt32Array([0])
	var kind := 0
	var count := 0
	var data := PackedByteArray()
	while p[0] < b.size():
		var tag := _varint(b, p)
		var field := tag >> 3
		var wire := tag & 7
		if field == 1 and wire == 0:
			kind = _varint(b, p)
		elif field == 2 and wire == 0:
			count = _varint(b, p)
		elif field == 3 and wire == 2:
			var l := _varint(b, p)
			data = b.slice(p[0], p[0] + l)
			p[0] += l
		else:
			_skip(b, p, wire)
	if not KIND_NAMES.has(kind):
		return  # неизвестный kind клиент пропускает
	var name: String = KIND_NAMES[kind]
	match kind:
		1, 2:
			streams[name] = _roads(data, count)
		3:
			streams[name] = _buildings(data, count)
		12:
			streams[name] = _names(data, count)
		_:
			streams[name] = _generic(data, count)


# ---------- потоки O3 ----------

static func _points(b: PackedByteArray, p: PackedInt32Array, cnt: int, last: PackedInt32Array) -> PackedVector2Array:
	var pts := PackedVector2Array()
	pts.resize(cnt)
	var lx := last[0]
	var ly := last[1]
	for k in cnt:
		lx += _zz(_varint(b, p))
		ly += _zz(_varint(b, p))
		pts[k] = Vector2(lx, ly)
	last[0] = lx
	last[1] = ly
	return pts


static func _roads(b: PackedByteArray, count: int) -> Array:
	var out: Array = []
	var p := PackedInt32Array([0])
	var last := PackedInt32Array([0, 0])
	for _k in count:
		if p[0] >= b.size():
			break
		var cls := _varint(b, p)
		if p[0] >= b.size():
			break
		var flags := b[p[0]]
		p[0] += 1
		var width: Variant = null
		var lanes: Variant = null
		if flags & 1:
			width = _varint(b, p)
		if flags & 2:
			lanes = _varint(b, p)
		var cnt := _varint(b, p)
		if cnt > b.size():
			break
		out.append({"cls": cls, "width_dm": width, "lanes": lanes, "tunnel": (flags & 8) != 0,
			"bridge": (flags & 16) != 0, "pts": _points(b, p, cnt, last)})
	return out


static func _buildings(b: PackedByteArray, count: int) -> Array:
	var out: Array = []
	var p := PackedInt32Array([0])
	var rx := 0
	var ry := 0
	for _k in count:
		if p[0] >= b.size():
			break
		rx += _zz(_varint(b, p))
		ry += _zz(_varint(b, p))
		var w2 := _varint(b, p)
		var l2 := _varint(b, p)
		var angle := _varint(b, p)
		var hv := _varint(b, p)
		var type := _varint(b, p)
		out.append({"x": rx, "y": ry, "w2": w2, "l2": l2, "angle": angle, "hq": hv >> 1,
			"lv": (hv & 1) != 0, "type": type})
	return out


static func _generic(b: PackedByteArray, count: int) -> Array:
	var out: Array = []
	var p := PackedInt32Array([0])
	var last := PackedInt32Array([0, 0])
	for _k in count:
		if p[0] >= b.size():
			break
		var cls := _varint(b, p)
		if p[0] >= b.size():
			break
		var flags := b[p[0]]
		p[0] += 1
		var h := _varint(b, p)
		var cnt := _varint(b, p)
		if cnt > b.size():
			break
		out.append({"cls": cls, "flags": flags, "h": h, "pts": _points(b, p, cnt, last)})
	return out


static func _names(b: PackedByteArray, count: int) -> Array:
	var out: Array = []
	var p := PackedInt32Array([0])
	for _k in count:
		if p[0] >= b.size():
			break
		var l := _varint(b, p)
		out.append(b.slice(p[0], p[0] + l).get_string_from_utf8())
		p[0] += l
	return out
