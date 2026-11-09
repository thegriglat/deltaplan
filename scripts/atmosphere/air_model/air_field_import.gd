class_name AirFieldImport
extends RefCounted
## Набор уровней среднего поля из снимка крейта в памяти (W3 v4: DpAir.field_export_header /
## field_export_data): заголовок (JSON) и тело (массивы подряд, 3D-каналы float16, по столбцам
## float32, всё вместе — zstd). Уровень собирается WindField.from_arrays. Вынесено из прежнего класса запечённых полей
## (файлов запечённых полей в игре нет; остался только этот разбор снимка).

## Каналы по клеткам (float16) в порядке тела.
const CHANNELS_3D: Array[String] = ["u", "v", "w_mech", "w_conv", "theta"]
## Ширина картинки-носителя при переводе float16 в float32 средствами движка.
const IMG_W := 1024


## Набор уровней из заголовка и тела в памяти (снимок поля крейта: DpAir.field_export_header/
## field_export_data, без проверки key/model_hash). comp — тело (zstd).
## Рабочий поток допустим (сцену не трогает).
## null — тело не распаковалось или уровень не собрался; base — подпись для сообщений.
static func load_bytes(h: Dictionary, comp: PackedByteArray, base := "снимок") -> AirFieldSet:
	var raw_n := int(h.get("raw_bytes", 0))
	if comp.is_empty() or raw_n <= 0:
		push_warning("AirFieldImport: %s — тело пусто" % base)
		return null
	var body := comp.decompress(raw_n, FileAccess.COMPRESSION_ZSTD)
	if body.size() != raw_n:
		push_warning("AirFieldImport: %s — тело не распаковалось" % base)
		return null
	# уровни собираются параллельно (WindField.from_arrays — столбцы и пограничный слой, сотни мс на
	# уровень): чтение из кеша/файла за ~1 с, а не за сумму уровней (FL-2)
	var lvs: Array = h.get("levels", [])
	var built: Array = []
	built.resize(lvs.size())
	if lvs.size() > 1:
		PoolFor.run(func(i: int) -> void: built[i] = _level(lvs[i], body), lvs.size(), "AirFieldImport.levels")
	elif lvs.size() == 1:
		built[0] = _level(lvs[0], body)
	var levels: Array[WindField] = []
	for i in lvs.size():
		var f: WindField = built[i]
		if f == null:
			push_warning("AirFieldImport: %s — уровень %s не собрался" % [base, lvs[i].get("name", "?")])
			return null
		f.meta["path_baked"] = base
		levels.append(f)
	if levels.is_empty():
		return null
	var fs := AirFieldSet.new()
	fs.set_field(levels, 0.0)
	return fs


static func _level(lv: Dictionary, body: PackedByteArray) -> WindField:
	var arrays: Dictionary = lv.get("arrays", {})
	for name in CHANNELS_3D + ["hc"]:
		if not arrays.has(name):
			return null
	var m: Dictionary = (lv.get("meta", {}) as Dictionary).duplicate(true)
	m.merge(lv.get("grid", {}), true)
	var ch := {}
	for name in CHANNELS_3D:
		ch[name] = _array(body, arrays[name])
	for name: String in arrays:
		if name == "heat":
			m["heat"] = _array(body, arrays[name])
		elif name.begins_with("meta."):
			m[name.substr(5)] = _array(body, arrays[name])
		elif name == "k1":
			m["k1"] = _array(body, arrays[name])  # версия 2 файла поля (PT-10): первая воздушная клетка
	return WindField.from_arrays(
		m, ch.u, ch.v, ch.w_mech, ch.w_conv, ch.theta, _array(body, arrays["hc"])
	)


static func _array(body: PackedByteArray, ent: Array) -> PackedFloat32Array:
	var seg := body.slice(int(ent[0]), int(ent[0]) + int(ent[1]))
	if String(ent[2]) == "f16":
		return _from_half(seg)
	return seg.to_float32_array()


static func _from_half(h: PackedByteArray) -> PackedFloat32Array:
	var n := h.size() / 2
	if n == 0:
		return PackedFloat32Array()
	var rows := ceili(float(n) / IMG_W)
	var bytes := h.duplicate()
	bytes.resize(IMG_W * rows * 2)
	var img := Image.create_from_data(IMG_W, rows, false, Image.FORMAT_RH, bytes)
	img.convert(Image.FORMAT_RF)
	var out := img.get_data().to_float32_array()
	out.resize(n)
	return out
