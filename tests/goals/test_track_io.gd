extends TestCase
## TrackIO (IGC) и LastTrackStore (GL-К5).

const DATA := "res://tests/goals/data/"
const TMP := "user://test_track_io"


func _circle() -> FlightTrack:
	var t := FlightTrack.new()
	t.name = "Круг"
	for i in 61:
		var a := TAU * i / 60.0
		t.append(50.0 + 0.01 * sin(a), -30.0 + 0.02 * cos(a), 800.0 + i * 1.5, float(i))
	return t


func _cleanup() -> void:
	if not DirAccess.dir_exists_absolute(TMP):
		return
	for f in DirAccess.get_files_at(TMP):
		DirAccess.remove_absolute(TMP.path_join(f))
	DirAccess.remove_absolute(TMP)


func test_roundtrip_circle() -> void:
	_cleanup()
	var src := _circle()
	var p := TMP.path_join("c.igc")
	check(TrackIO.write_igc(src, p, {"year": 2026, "month": 7, "day": 15, "start_s": 40000}) == OK, "запись")
	check(not FileAccess.file_exists(p + ".tmp"), "временного файла нет")
	var got := TrackIO.read(p)
	check(got != null, "чтение")
	if got != null:
		check(got.size() == 61, "число точек")
		for i in [0, 15, 30, 60]:
			approx(got.lat[i], src.lat[i], 1e-4, "lat %d" % i)
			approx(got.lon[i], src.lon[i], 1e-4, "lon %d (запад)" % i)
			approx(got.alt_m[i], src.alt_m[i], 0.51, "alt %d" % i)
			approx(got.t_s[i], src.t_s[i], 1e-3, "t %d" % i)
		check(got.name == "Круг", "имя")
		check(got.source == p, "источник")
	var text := FileAccess.get_file_as_string(p)
	check(text.contains("HFDTE150726"), "дата в заголовке")
	_cleanup()


func test_read_midnight_zero_gps() -> void:
	var t := TrackIO.read_igc(DATA + "circle_midnight.igc")
	check(t != null, "чтение образца")
	if t == null:
		return
	check(t.size() == 4, "4 точки")
	approx(t.t_s[0], 0.0, 1e-6, "t0")
	approx(t.t_s[1], 1.0, 1e-6, "t1")
	approx(t.t_s[2], 2.0, 1e-6, "через полночь +86400")
	approx(t.t_s[3], 3.0, 1e-6, "t3")
	approx(t.alt_m[0], 500.0, 1e-3, "GPS нулевая — давление")
	approx(t.alt_m[3], 503.0, 1e-3, "давление 3")
	approx(t.lat[0], 1.0, 1e-9, "lat")
	check(t.lat[3] < 0.0 and t.lon[3] < 0.0, "S и W отрицательны")
	check(t.name == "Тест", "имя из HFSIT")


func test_write_across_midnight() -> void:
	_cleanup()
	var t := FlightTrack.new()
	t.append(10.0, 10.0, 100.0, 0.0)
	t.append(10.0, 10.0, 101.0, 20.0)
	var p := TMP.path_join("m.igc")
	TrackIO.write_igc(t, p, {"start_s": 86390})
	var got := TrackIO.read_igc(p)
	check(got != null and got.size() == 2, "прочитан")
	if got != null:
		approx(got.t_s[1], 20.0, 1e-6, "полночь при записи")
	_cleanup()


func test_errors() -> void:
	check(TrackIO.read("user://нет.igc") == null and TrackIO.last_error() != "", "нет файла")
	check(TrackIO.read("a.gpx") == null and TrackIO.last_error() != "", "gpx пока null")
	check(TrackIO.read("a.txt") == null, "расширение")


func test_last_store_replace_and_other_place() -> void:
	_cleanup()
	var old_dir := LastTrackStore.base_dir
	LastTrackStore.base_dir = TMP
	check(LastTrackStore.load("A") == null, "пусто")
	var t1 := _circle()
	check(LastTrackStore.save("A", t1) == OK, "save 1")
	var t2 := FlightTrack.new()
	t2.append(1.0, 2.0, 3.0, 0.0)
	t2.append(1.0, 2.0, 4.0, 1.0)
	check(LastTrackStore.save("A", t2) == OK, "save 2 заменяет")
	var got := LastTrackStore.load("A")
	check(got != null and got.size() == 2, "осталась последняя")
	if got != null:
		check(got.source == "last", "source last")
	check(LastTrackStore.load("B") == null, "другое место — пусто")
	check(DirAccess.get_files_at(TMP).size() == 1, "один файл на место")
	check(LastTrackStore.path_for("A") == TMP + "/A.igc", "path_for")
	LastTrackStore.base_dir = old_dir
	_cleanup()


func test_place_key() -> void:
	var s := FlightSettings.new()
	s.location_id = "altai"
	check(LastTrackStore.place_key(s) == "altai", "встроенное")
	s.location_id = "custom_x"
	s.pick_lat = 50.0004
	s.pick_lon = 30.0004
	check(LastTrackStore.place_key(s) == LocationCache.key_for(50.0004, 30.0004), "точка")
