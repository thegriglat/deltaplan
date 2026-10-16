class_name TrackIO
extends RefCounted
## Чтение/запись треков (GL-К5): подмножество IGC (FAI). GPX — в GL-10.

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
	_last_error = "GPX пока не поддержан: " + path
	return null


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
