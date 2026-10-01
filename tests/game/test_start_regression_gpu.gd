extends "res://tests/game/test_start_regression.gd"
## CF-1: тот же старт по умолчанию, но с полем воздуха GPU (AirRuntime, как в игре в окне).
## Запуск: tools/gpu_tests.sh --filter=start_regression_gpu (headless пропускается).


func needs_gpu() -> bool:
	return true
