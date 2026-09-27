class_name LoadMeter
extends RefCounted
## Перегрузка n = подъёмная сила / вес (для приборов и звука скрипа каркаса).
## Сглаживается фильтром flight.json → load_factor.filter_s. Поломка крыла (FR-14c) отложена.

## Мгновенная перегрузка, g.
var load_raw: float = 1.0
## Сглаженная перегрузка, g.
var load_factor: float = 1.0
## Максимум и минимум сглаженной перегрузки с последнего сброса, g.
var load_max: float = 1.0
var load_min: float = 1.0
## Средний разброс мгновенной перегрузки вокруг сглаженной, g — мера болтанки.
var jitter: float = 0.0


func reset() -> void:
	load_raw = 1.0
	load_factor = 1.0
	load_max = 1.0
	load_min = 1.0
	jitter = 0.0


## lift — подъёмная сила со знаком, Н; weight — вес, Н; filter_s — сглаживание, с;
## jitter_s — окно усреднения разброса (болтанки), с.
func update(lift: float, weight: float, filter_s: float, dt: float, jitter_s: float = 1.0) -> void:
	load_raw = lift / weight
	load_factor += (load_raw - load_factor) * (1.0 - exp(-dt / filter_s))
	var dev := absf(load_raw - load_factor)
	jitter += (dev - jitter) * (1.0 - exp(-dt / jitter_s))
	load_max = maxf(load_max, load_factor)
	load_min = minf(load_min, load_factor)
