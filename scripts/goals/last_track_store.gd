class_name LastTrackStore
extends RefCounted
## След прошлой попытки (GL-К5): одна запись на место, новая заменяет старую.

static var base_dir := "user://tracks/last"  ## подменяется тестами


## Встроенное место — его id, иначе ключ точки выбора на карте.
static func place_key(s: FlightSettings) -> String:
	if Locations.is_builtin(s.location_id):
		return s.location_id
	return LocationCache.key_for(s.pick_lat, s.pick_lon)


static func path_for(key: String) -> String:
	return base_dir.path_join(key + ".igc")


static func save(key: String, track: FlightTrack) -> Error:
	return TrackIO.write_igc(track, path_for(key), {"name": track.name})


static func load(key: String) -> FlightTrack:
	var p := path_for(key)
	if not FileAccess.file_exists(p):
		return null
	var t := TrackIO.read_igc(p)
	if t != null:
		t.source = "last"
	return t
