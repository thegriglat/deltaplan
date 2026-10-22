extends TestCase
## CR-5 (контракт CR-К2): пустой RID из RenderingDevice в AirGpu — одна запись GpuHealth, failed,
## холостые вызовы дальше, отказ задачи (AirGpuJob.failed) вместо каскада ошибок RenderingDevice.
## tools/gpu_tests.sh --filter=test_air_gpu_invalid


class FailJob:
	extends AirGpuJob
	var bad := RID()

	func _shaders() -> Array:
		return ["air_vec"]

	func _setup() -> bool:
		bad = gpu.buffer(0)  # размер 0 — RD вернёт пустой RID
		return true


func needs_gpu() -> bool:
	return true


func test_invalid_buffer_reports_once() -> void:
	GpuHealth.reset()
	var g := AirGpu.new()
	if not g.init(["air_vec"]):
		failures.append("нет RD: " + g.error)
		return
	check(not g.failed and not GpuHealth.is_failed(), "здоровое устройство")
	var b := g.buffer(0)
	check(not b.is_valid(), "пустой RID")
	check(g.failed, "AirGpu.failed")
	check(GpuHealth.is_failed(), "GpuHealth.is_failed")
	check(GpuHealth.source() == "AirGpu.buffer", "source: " + GpuHealth.source())
	check(GpuHealth.count() == 1, "count после первого: %d" % GpuHealth.count())
	# дальше всё холостое: ни ошибок RD, ни новых отчётов
	var ok := g.buffer(16)
	check(not ok.is_valid(), "после отказа буфер не создаётся")
	g.fill(ok, 16)
	g.upload(ok, PackedFloat32Array([1.0]))
	g.submit()
	g.sync()
	check(g.download(ok, 1).size() == 0, "чтение после отказа пусто")
	check(g.read_scalar(0) == 0.0, "скаляр после отказа 0")
	check(GpuHealth.count() == 1, "повторные вызовы не отчитываются: %d" % GpuHealth.count())
	g.release()
	GpuHealth.reset()


func test_job_fails_instead_of_cascade() -> void:
	GpuHealth.reset()
	var job := FailJob.new()
	var msgs: Array[String] = []
	job.failed.connect(func(m: String) -> void: msgs.append(m))
	check(not job.start(), "start отказывает")
	check(msgs.size() == 1, "failed ровно один раз: %d" % msgs.size())
	check(job.error != "", "error задан")
	check(GpuHealth.is_failed() and GpuHealth.count() == 1, "GpuHealth")
	job.poll()
	job.poll_slice(10.0)
	check(msgs.size() == 1, "после отказа poll не повторяет failed")
	job.gpu.release()
	GpuHealth.reset()
