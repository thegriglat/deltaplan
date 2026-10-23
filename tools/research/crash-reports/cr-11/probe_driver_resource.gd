extends SceneTree
## Проба CR-11: доступен ли из GDScript нативный дескриптор устройства (основа для GDExtension).
## Запуск (окно нужно: RenderingDevice есть только при рендере):
##   godot --path <каталог cr-11> --rendering-driver vulkan --resolution 64x64 -s probe_driver_resource.gd
## Результат — одна JSON-строка в stdout; на Windows/d3d12 то же значение — указатель ID3D12Device.

func _init() -> void:
	await process_frame
	var rd := RenderingServer.get_rendering_device()
	var res := {"driver": RenderingServer.get_current_rendering_driver_name(), "rd": rd != null}
	if rd != null:
		res["logical_device_handle_nonzero"] = rd.get_driver_resource(RenderingDevice.DRIVER_RESOURCE_LOGICAL_DEVICE, RID(), 0) != 0
		res["physical_device_handle_nonzero"] = rd.get_driver_resource(RenderingDevice.DRIVER_RESOURCE_PHYSICAL_DEVICE, RID(), 0) != 0
		res["command_queue_handle_nonzero"] = rd.get_driver_resource(RenderingDevice.DRIVER_RESOURCE_COMMAND_QUEUE, RID(), 0) != 0
		res["adapter"] = RenderingServer.get_video_adapter_name()
	# Logger (CR-К2 v2): класс и его виртуальные методы в этой сборке.
	res["logger_class"] = ClassDB.class_exists("Logger")
	if res["logger_class"]:
		var names := []
		for m in ClassDB.class_get_method_list("Logger", true):
			names.append(m["name"])
		res["logger_methods"] = names
	print(JSON.stringify(res))
	quit()
