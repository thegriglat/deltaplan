extends Node
## Нода VarioAudio в дереве: плеер играет, буфер генератора заполняется.
## Тест — Node (раннер добавляет его в дерево), VarioAudio вешается к себе же:
## чужое дерево не трогаем.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_vario_audio_node_fills_buffer() -> void:
	var node := VarioAudio.new()
	add_child(node)
	node.set_vario(2.0)
	check(node.player != null and node.player.playing, "плеер играет")
	check(node.player.stream is AudioStreamGenerator, "поток — генератор")
	node.free()
