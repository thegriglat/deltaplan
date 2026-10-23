extends SceneTree
## CR-1: воспроизведение цепочки ошибок хвоста лога группы A без D3D12.
## Потеря устройства D3D12 здесь недоступна; имитация — буфер, который драйвер не создаёт
## (размер сверх предела): storage_buffer_create возвращает пустой RID, AirGpu.buffer() его не
## проверяет (air_gpu.gd:143-154), дальше upload/_uniforms дают те же сообщения движка.
## Запуск: см. README.md (окно, не headless).


func _init() -> void:
	var g := AirGpu.new()
	if not g.init(["air_vec"]):
		print("CR1 init failed: ", g.error)
		quit(2)
		return
	var good := g.buffer(1024)
	var bad := g.buffer(1 << 40)  # драйвер откажет: пустой RID, в _owned он всё равно попадает
	print("CR1 bad_valid=", bad.is_valid(), " good_valid=", good.is_valid())
	g.upload(bad, PackedFloat32Array([1.0, 2.0]))  # -> buffer_update: not a valid buffer
	g.vec(AirGpu.Vec.COPY, good, bad, 4)  # -> uniform_set_create: must provide one ID (0 provided)
	g.submit()
	g.sync()
	print("CR1 done (процесс не упал: на Vulkan пустой RID не убивает игру)")
	g.release()
	quit(0)
