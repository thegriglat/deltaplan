extends TestCase
## Без RenderingDevice (headless, tools/check.sh) блоки модели воздуха (AM-02) отказывают
## понятной ошибкой, а не падением: AirGpu.init() → false, AirGpuJob.start() → false + failed.


func test_no_rd_is_clear_error() -> void:
	if DisplayServer.get_name() != "headless":
		return  # с настоящим RD это проверяет test_air_gpu_blocks.gd
	var g := AirGpu.new()
	check(not g.init(), "init без RD — false")
	check(g.error.contains("нет RenderingDevice"), "понятная ошибка: " + g.error)
	g.release()
	var job := AirPoissonJob.new()
	var got := []
	job.failed.connect(func(m: String) -> void: got.append(m))
	check(not job.start(), "start без RD — false")
	check(got.size() == 1 and job.error != "", "сигнал failed с ошибкой")
	check(job.poll() == 0.0 and not job.is_done(), "poll после ошибки — без расчёта")
	job.release()
