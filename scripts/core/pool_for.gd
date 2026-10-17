class_name PoolFor
## Параллельный цикл fn(i), i ∈ [0, n), с ожиданием конца — общее правило вложенных ожиданий
## WorkerThreadPool (FL-20).
##
## Ожидание группы (wait_for_group_task_completion) в Godot 4.7 — простой семафор: ждущий поток
## чужих задач не берёт. Если группы ждут все рабочие потоки (вложенные полосы внутри задач пула:
## AirRuntime._prep_task → домены → полосы TerrainRelief._par и т. п.), задачам групп не на чем
## выполниться — пул встаёт; при малом пуле (2–4 потока) — сразу. Ожидание задачи
## (wait_for_task_completion) из рабочего потока совместное: ждущий сам выполняет задачи очереди.
## Поэтому: не из пула (главный поток, свой Thread) — прежняя группа (высокий приоритет); из задачи
## пула — элементы 1…n-1 отдельными задачами высокого приоритета, элемент 0 — сам, затем совместное
## ожидание (ждущий берёт из очереди в том числе свои элементы). Каждый элемент пишет только своё —
## результат тот же, что у группы и у последовательного обхода.


## Вызов из задачи пула (рабочий поток выполняет задачу или элемент группы).
static func in_pool() -> bool:
	return WorkerThreadPool.get_caller_task_id() != -1 or WorkerThreadPool.get_caller_group_id() != -1


## fn(i) для i в [0, n) параллельно; возврат — когда все выполнены.
static func run(fn: Callable, n: int, description := "") -> void:
	if n <= 0:
		return
	if n == 1:
		fn.call(0)
		return
	if not in_pool():
		var gid := WorkerThreadPool.add_group_task(fn, n, -1, true, description)
		WorkerThreadPool.wait_for_group_task_completion(gid)
		return
	var ids := PackedInt64Array()
	ids.resize(n - 1)
	for i in range(1, n):
		ids[i - 1] = WorkerThreadPool.add_task(fn.bind(i), true, description)
	fn.call(0)
	for id in ids:
		# задачи новее текущей — ERR_BUSY (ожидание более старой) здесь не бывает
		var err := WorkerThreadPool.wait_for_task_completion(id)
		if err != OK:
			push_error("PoolFor: ожидание задачи %d — ошибка %d" % [id, err])
