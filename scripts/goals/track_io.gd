class_name TrackIO
extends RefCounted
## Чтение/запись треков (GL-К5): подмножество IGC (FAI) и GPX.

static var _last_error := ""


static func last_error() -> String:
	return _last_error


static func read(path: String) -> FlightTrack:
	_last_error = ""
	match path.get_extension().to_lower():
		"igc":
			return read_igc(path)
		"gpx":
			return read_gpx(path)
	_last_error = "неизвестное расширение: " + path
	return null


static func read_gpx(path: String) -> FlightTrack:
	_last_error = ""
	if not FileAccess.file_exists(path):
		_last_error = "нет файла: " + path
		return null
	var xml := XMLParser.new()
	if xml.open(path) != OK:
		_last_error = "не открыть " + path
		return null
	var track := FlightTrack.new()
	var abs_t := PackedFloat64Array()
	var all_time := true
	var in_pt := false
	var cur := ""  ## имя элемента с текстом внутри trkpt
	var plat := 0.0
	var plon := 0.0
	var pele := NAN
	var ptime := NAN
	var name_txt := ""
	var in_trk_name := false
	var depth_trk := false
	var err := OK
	while true:
		err = xml.read()
		if err != OK:
			break
		var t := xml.get_node_type()
		if t == XMLParser.NODE_ELEMENT:
			var nm := xml.get_node_name()
			if nm == "trk":
				depth_trk = true
			elif nm == "trkpt":
				in_pt = true
				plat = xml.get_named_attribute_value_safe("lat").to_float()
				plon = xml.get_named_attribute_value_safe("lon").to_float()
				if not xml.has_attribute("lat") or not xml.has_attribute("lon"):
					_last_error = "trkpt без lat/lon: " + path
					return null
				pele = NAN
				ptime = NAN
				if xml.is_empty():
					in_pt = false
					_last_error = "trkpt без ele: " + path
					return null
			elif in_pt and (nm == "ele" or nm == "time"):
				cur = nm
			elif nm == "name" and depth_trk and not in_pt and name_txt == "":
				in_trk_name = true
		elif t == XMLParser.NODE_TEXT:
			var txt := xml.get_node_data().strip_edges()
			if cur == "ele" and txt.is_valid_float():
				pele = txt.to_float()
			elif cur == "time":
				ptime = _parse_iso_time(txt)
			elif in_trk_name:
				name_txt = txt
		elif t == XMLParser.NODE_ELEMENT_END:
			var nm2 := xml.get_node_name()
			if nm2 == "trkpt":
				in_pt = false
				if is_nan(pele):
					_last_error = "нет высоты (ele) в трекпоинте: " + path
					return null
				if is_nan(ptime):
					all_time = false
				track.lat.append(plat)
				track.lon.append(plon)
				track.alt_m.append(pele)
				abs_t.append(0.0 if is_nan(ptime) else ptime)
			elif nm2 == "ele" or nm2 == "time":
				cur = ""
			elif nm2 == "name":
				in_trk_name = false
	if (err != ERR_FILE_EOF and err != OK) or in_pt:
		_last_error = "повреждённый GPX: " + path
		return null
	if track.size() == 0:
		_last_error = "нет точек трека: " + path
		return null
	var prev := 0.0
	for i in track.size():
		var v := float(i)
		if all_time:
			v = maxf(prev, abs_t[i] - abs_t[0])
		prev = v
		track.t_s.append(v)
	track.name = name_txt if name_txt != "" else path.get_file().get_basename()
	track.source = path
	return track


## ISO 8601 («2024-07-15T10:23:45Z», дробные секунды, смещение ±hh:mm / ±hhmm) → секунды Unix; NAN — не разобрать.
static func _parse_iso_time(s: String) -> float:
	var rx := RegEx.create_from_string(
		"^(\\d{4})-(\\d{2})-(\\d{2})[T ](\\d{2}):(\\d{2}):(\\d{2})(\\.\\d+)?\\s*(Z|[+-]\\d{2}(?::?\\d{2})?)?$")
	var m := rx.search(s)
	if m == null:
		return NAN
	var d := {"year": m.get_string(1).to_int(), "month": m.get_string(2).to_int(),
		"day": m.get_string(3).to_int(), "hour": m.get_string(4).to_int(),
		"minute": m.get_string(5).to_int(), "second": m.get_string(6).to_int()}
	var v := float(Time.get_unix_time_from_datetime_dict(d))
	if m.get_string(7) != "":
		v += ("0" + m.get_string(7)).to_float()
	var z := m.get_string(8)
	if z != "" and z != "Z":
		var sign := -1.0 if z[0] == "-" else 1.0
		var digits := z.substr(1).replace(":", "")
		var off := digits.substr(0, 2).to_int() * 3600 + (digits.substr(2, 2).to_int() * 60 if digits.length() > 2 else 0)
		v -= sign * off
	return v


## meta: year (полный), month, day, start_s (секунда суток первой точки), name.
static func write_igc(track: FlightTrack, path: String, meta := {}) -> Error:
	_last_error = ""
	var year := int(meta.get("year", Time.get_date_dict_from_system().year))
	var month := int(meta.get("month", 7))
	var day := int(meta.get("day", 15))
	var start_s := int(meta.get("start_s", 12 * 3600))
	var nm := String(meta.get("name", track.name))
	var lines := PackedStringArray()
	lines.append("AXXXDLT Deltaplan")
	lines.append("HFDTE%02d%02d%02d" % [day, month, year % 100])
	lines.append("HFPLTPILOTINCHARGE:")
	if nm != "":
		lines.append("HFSITSite:" + nm)
	for i in track.size():
		var sec := (start_s + int(roundf(track.t_s[i]))) % 86400
		var alt := maxi(0, int(roundf(track.alt_m[i])))
		lines.append("B%02d%02d%02d%s%s" % [sec / 3600, (sec / 60) % 60, sec % 60,
			_fmt_coord(track.lat[i], 2, "N", "S") + _fmt_coord(track.lon[i], 3, "E", "W"),
			"A%05d%05d" % [alt, alt]])
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		var e := DirAccess.make_dir_recursive_absolute(dir)
		if e != OK:
			_last_error = "нет папки " + dir
			return e
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		_last_error = "не открыть " + tmp
		return FileAccess.get_open_error()
	f.store_string("\r\n".join(lines) + "\r\n")
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		_last_error = "не переименовать " + tmp
		DirAccess.remove_absolute(tmp)
	return err


static func _fmt_coord(deg: float, deg_digits: int, pos: String, neg: String) -> String:
	var total := int(roundf(absf(deg) * 60000.0))
	var d := total / 60000
	var m := total % 60000
	return ("%0" + str(deg_digits) + "d%05d%s") % [d, m, pos if deg >= 0.0 else neg]


static func read_igc(path: String) -> FlightTrack:
	_last_error = ""
	if not FileAccess.file_exists(path):
		_last_error = "нет файла: " + path
		return null
	var text := FileAccess.get_file_as_string(path)
	var track := FlightTrack.new()
	var gps := PackedFloat32Array()
	var pres := PackedFloat32Array()
	var abs_s := PackedFloat64Array()
	var day_add := 0
	var prev_tod := -1
	var site := ""
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.begins_with("HFSIT"):
			site = line.substr(line.find(":") + 1) if line.contains(":") else ""
			continue
		if not line.begins_with("B") or line.length() < 35:
			continue
		var tod := int(line.substr(1, 2)) * 3600 + int(line.substr(3, 2)) * 60 + int(line.substr(5, 2))
		if prev_tod >= 0 and tod < prev_tod:
			day_add += 86400
		prev_tod = tod
		var la := _parse_coord(line.substr(7, 7), 2, line[14] == "S")
		var lo := _parse_coord(line.substr(15, 8), 3, line[23] == "W")
		track.lat.append(la)
		track.lon.append(lo)
		abs_s.append(tod + day_add)
		pres.append(float(line.substr(25, 5).to_int()))
		gps.append(float(line.substr(30, 5).to_int()))
	if track.size() == 0:
		_last_error = "нет B-записей: " + path
		return null
	var use_gps := false
	for g in gps:
		if g != 0.0:
			use_gps = true
			break
	var src := gps if use_gps else pres
	for i in track.size():
		track.alt_m.append(src[i])
		track.t_s.append(float(abs_s[i] - abs_s[0]))
	track.name = site if site != "" else path.get_file().get_basename()
	track.source = path
	return track


static func _parse_coord(s: String, deg_digits: int, negative: bool) -> float:
	var d := s.substr(0, deg_digits).to_int()
	var m := s.substr(deg_digits).to_int()
	var v := d + m / 60000.0
	return -v if negative else v
