extends Node

const Meteor := preload("res://scripts/world_objects/easter_eggs/meteor.gd")
## Метеор: условия появления (темно и ясно) и что параметры берутся из rng (одно место неба).

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _ctx(sun_y: float, cirrus := 0.0, sky := "clear") -> EggContext:
	var c := EggContext.new()
	c.to_sun = Vector3(0.6, sun_y, 0.2).normalized()
	c.weather = {"cirrus_cover": cirrus, "_derived": {"sky": sky}}
	return c


func test_can_appear() -> void:
	var cfg: Dictionary = Config.get_config("easter_eggs").eggs.meteor
	check(not Meteor.can_appear(_ctx(0.8), cfg), "днём нет")
	check(not Meteor.can_appear(_ctx(-0.05), cfg), "сумерки выше порога — нет")
	check(Meteor.can_appear(_ctx(-0.4), cfg), "ночью да")
	check(not Meteor.can_appear(_ctx(-0.4, 0.8), cfg), "сплошные перья — нет")
	check(not Meteor.can_appear(_ctx(-0.4, 0.0, "overcast"), cfg), "пасмурно — нет")


func test_same_sky_place() -> void:
	var cfg: Dictionary = Config.get_config("easter_eggs").eggs.meteor
	var dirs: Array[Vector3] = []
	for i in 2:
		var m := Meteor.new()
		var rng := RandomNumberGenerator.new()
		rng.seed = 12345
		m.begin(_ctx(-0.4), cfg, rng, 10.0)
		dirs.append(m.call("sky_dir"))
		m.free()
	check(dirs[0] == dirs[1], "направление детерминировано")
