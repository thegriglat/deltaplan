class_name SailTexture
extends RefCounted
## Своя картинка паруса игрока (SLT-К1): проверка PNG/JPEG, уменьшение, атомарная копия в user://,
## загрузка, сброс. Только локально: по сети не передаётся. Есть файл `path` — своя картинка включена.

const DEFAULT_PATH := "user://sail_texture.png"
const MAX_FILE_BYTES := 20 * 1024 * 1024
const MIN_SIDE_PX := 16
const MAX_INPUT_SIDE_PX := 16384
const MAX_SIDE_PX := 2048

## Файл своей картинки; тесты подменяют (свой каталог в user://) и возвращают DEFAULT_PATH.
static var path := DEFAULT_PATH


## Проверка и подготовка картинки: {"error": ключ ui.csv или "", "image": Image (RGBA8) или null}.
static func prepare(src_path: String) -> Dictionary:
	if not FileAccess.file_exists(src_path):
		return _fail("sail_tex_err_read")
	var f := FileAccess.open(src_path, FileAccess.READ)
	if f == null:
		return _fail("sail_tex_err_read")
	var length := f.get_length()
	if length > MAX_FILE_BYTES:
		f.close()
		return _fail("sail_tex_err_too_big")
	var bytes := f.get_buffer(length)
	f.close()
	var kind := _kind(bytes)
	if kind == "":
		return _fail("sail_tex_err_format")
	# размеры из заголовка — до декодирования (огромная картинка не раздувает память)
	var dims := _header_size(bytes, kind)
	if dims != Vector2i.ZERO:
		var e := _size_error(dims)
		if e != "":
			return _fail(e)
	var img := Image.new()
	var err := img.load_png_from_buffer(bytes) if kind == "png" else img.load_jpg_from_buffer(bytes)
	if err != OK or img.is_empty():
		return _fail("sail_tex_err_format")
	var e2 := _size_error(img.get_size())
	if e2 != "":
		return _fail(e2)
	if img.has_mipmaps():
		img.clear_mipmaps()
	var side := maxi(img.get_width(), img.get_height())
	if side > MAX_SIDE_PX:
		var k := float(MAX_SIDE_PX) / float(side)
		img.resize(
			maxi(1, roundi(img.get_width() * k)),
			maxi(1, roundi(img.get_height() * k)),
			Image.INTERPOLATE_LANCZOS
		)
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	return {"error": "", "image": img}


## PNG в `path` через временный файл и переименование; неудача — false, прежний файл цел.
static func save(img: Image) -> bool:
	if img == null or img.is_empty():
		return false
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		if DirAccess.make_dir_recursive_absolute(dir) != OK:
			return false
	var tmp := path + ".tmp"
	if img.save_png(tmp) != OK:
		DirAccess.remove_absolute(tmp)
		return false
	if DirAccess.rename_absolute(tmp, path) != OK:
		DirAccess.remove_absolute(tmp)
		return false
	return true


## prepare + save: "" или ключ ошибки. При ошибке прежний файл цел.
static func import_file(src_path: String) -> String:
	var r := prepare(src_path)
	var e: String = r["error"]
	if e != "":
		return e
	return "" if save(r["image"]) else "sail_tex_err_write"


static func has_custom() -> bool:
	return FileAccess.file_exists(path)


## Картинка из `path` с мипмапами; нет файла — null молча; битый — null и предупреждение.
static func load_texture() -> ImageTexture:
	if not has_custom():
		return null
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		push_warning("SailTexture: не читается %s" % path)
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func clear() -> void:
	if has_custom():
		DirAccess.remove_absolute(path)


static func _fail(key: String) -> Dictionary:
	return {"error": key, "image": null}


static func _size_error(s: Vector2i) -> String:
	if mini(s.x, s.y) < MIN_SIDE_PX:
		return "sail_tex_err_too_small"
	if maxi(s.x, s.y) > MAX_INPUT_SIDE_PX:
		return "sail_tex_err_too_big"
	return ""


## "png" / "jpg" по сигнатуре; иначе "".
static func _kind(b: PackedByteArray) -> String:
	if b.size() >= 4 and b[0] == 0x89 and b[1] == 0x50 and b[2] == 0x4E and b[3] == 0x47:
		return "png"
	if b.size() >= 3 and b[0] == 0xFF and b[1] == 0xD8 and b[2] == 0xFF:
		return "jpg"
	return ""


## Размер из заголовка (PNG IHDR, JPEG SOFn); не разобрали — ZERO.
static func _header_size(b: PackedByteArray, kind: String) -> Vector2i:
	if kind == "png":
		if b.size() < 24:
			return Vector2i.ZERO
		return Vector2i(_be32(b, 16), _be32(b, 20))
	var i := 2
	while i + 9 < b.size():
		if b[i] != 0xFF:
			i += 1
			continue
		var m := b[i + 1]
		if m == 0xFF:
			i += 1
			continue
		if m == 0xD8 or m == 0x01 or (m >= 0xD0 and m <= 0xD7):
			i += 2
			continue
		var seg := (b[i + 2] << 8) | b[i + 3]
		if m >= 0xC0 and m <= 0xCF and m != 0xC4 and m != 0xC8 and m != 0xCC:
			return Vector2i((b[i + 7] << 8) | b[i + 8], (b[i + 5] << 8) | b[i + 6])
		i += 2 + seg
	return Vector2i.ZERO


static func _be32(b: PackedByteArray, o: int) -> int:
	return (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]
