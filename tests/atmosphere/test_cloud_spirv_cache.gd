extends TestCase
## Кеш SPIR-V облаков (CloudCompositorEffect): запись → чтение отдаёт тот же байткод; битый файл,
## чужой ключ (другой исходник) и мусор без SPIR-V-заголовка — промах, а не падение.


func _fake_spirv() -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(64)
	b.encode_u32(0, 0x07230203)
	for i in range(4, 64):
		b[i] = i
	return b


func test_roundtrip_and_corruption() -> void:
	var code := "// тест кеша %d" % Time.get_ticks_usec()
	var path := CloudCompositorEffect._cache_path(code)
	check(path != CloudCompositorEffect._cache_path(code + " "), "ключ зависит от исходника")
	check(CloudCompositorEffect._cache_read(path) == null, "пустой кеш — промах")
	var spv := _fake_spirv()
	CloudCompositorEffect._cache_write(path, spv)
	var got := CloudCompositorEffect._cache_read(path)
	check(got != null and got.bytecode_compute == spv, "прочитали то, что записали")
	var raw := FileAccess.get_file_as_bytes(path)
	raw[40] = raw[40] ^ 0xFF
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(raw)
	f.close()
	check(CloudCompositorEffect._cache_read(path) == null, "битый файл — промах")
	f = FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(raw.slice(0, 20))
	f.close()
	check(CloudCompositorEffect._cache_read(path) == null, "обрезанный файл — промах")
	DirAccess.remove_absolute(path)
