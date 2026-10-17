class_name HeightCache
extends RefCounted
## Кеш производных слоя высот в папке места (FL-8): пирамида максимумов (<слой>_maxpyr.bin) —
## при повторной загрузке читается, а не считается. Результат бит-в-бит тот же: в файле лежат
## ровно байты уровней, которые иначе посчитал бы HeightLayer.
##
## Формат (little-endian): магия "DPHC", версия; ключ источника — sha256[:16] файла высот слоя
## (webp из meta.json) и его размер; число уровней, у каждого w, h, формат Image, байт; размер
## тела до и после сжатия; тело — уровни подряд, PackedByteArray.compress(ZSTD).
## Ключ или размеры не совпали, файл обрезан или битый — пустой ответ (пересчёт и перезапись).
## Запись — во временный файл + rename, в WorkerThreadPool (главный поток не ждёт).

const MAGIC := 0x43485044  ## "DPHC"
const VERSION := 1
const SUBDIR := "cache"
## Кеш для данных из res:// (встроенные места в паке, фикстуры тестов): там писать нельзя.
const RES_ROOT := "user://height_cache"


## Ключ источника: первые 16 байт sha256 содержимого файла высот.
static func key_of(bytes: PackedByteArray) -> PackedByteArray:
	var hc := HashingContext.new()
	hc.start(HashingContext.HASH_SHA256)
	hc.update(bytes)
	return hc.finish().slice(0, 16)


## Файл кеша для слоя из source_path: <папка места>/cache/<слой>_<вид>.bin; для res:// —
## user://height_cache/<путь папки>/<слой>_<вид>.bin.
static func path_for(source_path: String, layer_id: String, kind: String) -> String:
	var base := source_path.get_base_dir()
	var dir := base.path_join(SUBDIR)
	if base.begins_with("res://"):
		dir = RES_ROOT.path_join(base.trim_prefix("res://").replace("/", "_"))
	return dir.path_join("%s_%s.bin" % [layer_id, kind])


## Тело (уровни подряд) или пустой массив, если файла нет, он чужой (ключ, размер источника,
## уровни не те) или битый. levels — ожидаемые уровни: [Vector3i(w, h, формат Image)];
## level_bytes — их размеры в байтах.
static func read(
	path: String, key: PackedByteArray, src_size: int, levels: Array, level_bytes: PackedInt64Array
) -> PackedByteArray:
	var none := PackedByteArray()
	if not FileAccess.file_exists(path):
		return none
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return none
	var flen := f.get_length()
	var head := 4 + 4 + 16 + 8 + 4
	if flen < head or f.get_32() != MAGIC or f.get_32() != VERSION:
		return none
	if f.get_buffer(16) != key or f.get_64() != src_size:
		return none
	var n := f.get_32()
	if n != levels.size() or flen < head + n * 20 + 16:
		return none
	var raw := 0
	for k in n:
		var d: Vector3i = levels[k]
		if f.get_32() != d.x or f.get_32() != d.y or f.get_32() != d.z or f.get_64() != level_bytes[k]:
			return none
		raw += level_bytes[k]
	if f.get_64() != raw:
		return none
	var packed := f.get_64()
	if packed <= 0 or f.get_position() + packed != flen:
		return none
	var body := f.get_buffer(packed)
	if body.size() != packed:
		return none
	var out := body.decompress(raw, FileAccess.COMPRESSION_ZSTD)
	return out if out.size() == raw else none


## Записать тело в рабочем потоке (временный файл + rename). Возвращает id задачи пула
## (ждать не обязательно; тесты ждут).
static func write_async(
	path: String,
	key: PackedByteArray,
	src_size: int,
	levels: Array,
	level_bytes: PackedInt64Array,
	body: PackedByteArray
) -> int:
	return WorkerThreadPool.add_task(
		write.bind(path, key, src_size, levels, level_bytes, body), false, "HeightCache.write"
	)


static func write(
	path: String,
	key: PackedByteArray,
	src_size: int,
	levels: Array,
	level_bytes: PackedInt64Array,
	body: PackedByteArray
) -> bool:
	if key.size() != 16 or levels.size() != level_bytes.size():
		return false
	var dir := path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	var packed := body.compress(FileAccess.COMPRESSION_ZSTD)
	# своё имя временного файла: два одновременных писателя не мешают друг другу
	var tmp := "%s.%d_%d.tmp" % [path, OS.get_process_id(), randi()]
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_32(MAGIC)
	f.store_32(VERSION)
	f.store_buffer(key)
	f.store_64(src_size)
	f.store_32(levels.size())
	for k in levels.size():
		var d: Vector3i = levels[k]
		f.store_32(d.x)
		f.store_32(d.y)
		f.store_32(d.z)
		f.store_64(level_bytes[k])
	f.store_64(body.size())
	f.store_64(packed.size())
	f.store_buffer(packed)
	var ok := f.get_error() == OK
	f.close()
	if not ok or DirAccess.rename_absolute(tmp, path) != OK:
		DirAccess.remove_absolute(tmp)
		return false
	return true
