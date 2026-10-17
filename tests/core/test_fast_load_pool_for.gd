extends TestCase
## PoolFor (FL-20): вложенные параллельные циклы из задач пула не занимают все потоки ожиданием,
## результат — тот же, что у последовательного обхода.

const DEADLINE_MS := 30000


static func _threads() -> int:
	var n := int(ProjectSettings.get_setting("threading/worker_pool/max_threads", -1))
	return n if n > 0 else OS.get_processor_count()


## Три уровня вложенности, как AirRuntime._prep_task → домены → полосы; каждый лист пишет свою клетку.
## out — обычный Array (общий по ссылке; упакованные массивы лямбды захватывают копией).
static func _nested(out: Array, base: int, a: int, b: int, c: int) -> void:
	PoolFor.run(
		func(i: int) -> void:
			PoolFor.run(
				func(j: int) -> void:
					PoolFor.run(
						func(k: int) -> void:
							var idx := base + (i * b + j) * c + k
							out[idx] = idx * idx + 7,
						c
					),
				b
			),
		a
	)


## Задачи пула ждут на главном потоке с пределом времени: зависание — падение, а не вечный тест.
func _wait_all(ids: Array) -> bool:
	var t0 := Time.get_ticks_msec()
	for id: int in ids:
		while not WorkerThreadPool.is_task_completed(id):
			if Time.get_ticks_msec() - t0 > DEADLINE_MS:
				return false
			OS.delay_msec(2)
		WorkerThreadPool.wait_for_task_completion(id)
	return true


func test_fast_load_pool_for_main_thread_equals_sequential() -> void:
	check(not PoolFor.in_pool(), "главный поток — не пул")
	var n := 1000
	var out := []
	out.resize(n)
	PoolFor.run(func(i: int) -> void: out[i] = i * 3 + 1, n)
	var ok := true
	for i in n:
		ok = ok and out[i] == i * 3 + 1
	check(ok, "главный поток: все элементы посчитаны")
	PoolFor.run(func(_i: int) -> void: check(false, "n=0 не зовёт fn"), 0)


func test_fast_load_pool_for_in_pool_flag() -> void:
	var seen := [false, false]
	var t := WorkerThreadPool.add_task(func() -> void: seen[0] = PoolFor.in_pool())
	WorkerThreadPool.wait_for_task_completion(t)
	var g := WorkerThreadPool.add_group_task(func(_i: int) -> void: seen[1] = PoolFor.in_pool(), 1)
	WorkerThreadPool.wait_for_group_task_completion(g)
	check(seen[0], "задача пула — in_pool")
	check(seen[1], "элемент группы — in_pool")


## Задач с вложенными циклами вдвое больше потоков: все потоки заняты внешними задачами. С
## ожиданием групп внутри (прежний код) это зависание; с PoolFor — нет, результат как последовательный.
func test_fast_load_pool_for_nested_saturated_pool() -> void:
	var outer := 2 * _threads()
	var a := 3
	var b := 4
	var c := 5
	var per := a * b * c
	var out := []
	out.resize(outer * per)
	var ids := []
	for o in outer:
		var job := func() -> void:
			_nested(out, o * per, a, b, c)
		ids.append(WorkerThreadPool.add_task(job, true, "test PoolFor"))
	check(_wait_all(ids), "вложенные циклы при занятом пуле завершились за %d мс" % DEADLINE_MS)
	var ok := true
	for o in outer:
		for k in per:
			var idx := o * per + k
			ok = ok and out[idx] == idx * idx + 7
	check(ok, "результат вложенных циклов = последовательному")


## Низкоприоритетные внешние задачи (как add_task по умолчанию: AirRuntime, AirThermals.build):
## при пуле 4 у них один поток, вложенные элементы — высокого приоритета, не ждут его.
func test_fast_load_pool_for_low_priority_outer() -> void:
	var outer := _threads()
	var per := 2 * 3 * 4
	var res := []
	res.resize(outer)
	var ids := []
	for o in outer:
		var job := func() -> void:
			var mine := []
			mine.resize(per)
			_nested(mine, 0, 2, 3, 4)
			res[o] = mine
		ids.append(WorkerThreadPool.add_task(job, false, "test PoolFor low"))
	check(_wait_all(ids), "низкоприоритетные внешние задачи завершились")
	var ok := true
	for o in outer:
		var m: Array = res[o] if res[o] != null else []
		ok = ok and m.size() == per
		for k in m.size():
			ok = ok and m[k] == k * k + 7
	check(ok, "результат низкоприоритетных = последовательному")
