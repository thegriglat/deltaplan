extends Node
## SP-1 (г): цена запуска ядра с барьером на локальном RD (GPU-метки) — сколько от итерации Пикара
## уходит на запуски/барьеры, а не на счёт. Цепочки по K запусков одного ядра (x → 0,5x + a):
##   tiny_bar   — 1 группа (64 потока), барьер после каждого: постоянная цена зависимого запуска;
##   tiny_nobar — 1 группа, без барьеров, каждый в свой буфер: цена запуска без ожидания;
##   n500k_bar  — 500 000 элементов (≈ клеток области 400 м), барьер: запуск + 4 МБ чтения/записи;
##   n2m_bar    — 2 000 000 (≈ область 200 м).
##   XDG_DATA_HOME=$(mktemp -d) flock -w 1800 /tmp/heat_ca_gpu.lock godot --path . \
##     --audio-driver Dummy --resolution 320x240 res://tools/research/air_speed/dispatch_probe.tscn \
##     -- [--out=tools/research/air_speed/out/dispatch.json]

const SRC := """
#version 450
layout(local_size_x = 64) in;
layout(set = 0, binding = 0, std430) restrict buffer B { float d[]; };
layout(push_constant) uniform P { uint n; float a; uint pad0; uint pad1; } p;
void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i < p.n) d[i] = d[i] * 0.5 + p.a;
}
"""

var _out := "res://tools/research/air_speed/out/dispatch.json"


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
	_run.call_deferred()


func _run() -> void:
	var rd := RenderingServer.create_local_rendering_device()
	var src := RDShaderSource.new()
	src.source_compute = SRC
	var sh := rd.shader_create_from_spirv(rd.shader_compile_spirv_from_source(src), "t")
	var pipe := rd.compute_pipeline_create(sh)
	var rows := []
	for spec: Array in [["tiny_bar", 64, true], ["tiny_nobar", 64, false], ["n500k_bar", 500000, true], ["n2m_bar", 2000000, true]]:
		var n: int = spec[1]
		var bar: bool = spec[2]
		var nb := 1 if bar else 64
		var bufs: Array[RID] = []
		var sets: Array[RID] = []
		for q in nb:
			var b := rd.storage_buffer_create(n * 4)
			var u := RDUniform.new()
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			u.binding = 0
			u.add_id(b)
			bufs.append(b)
			sets.append(rd.uniform_set_create([u], sh, 0))
		var pc := PackedInt32Array([n, 0, 0, 0]).to_byte_array()
		pc.encode_float(4, 1.0)
		for k in [1, 10, 100, 400, 1000]:
			var best := INF
			var cpu := INF
			for rep in 5:
				var t0 := Time.get_ticks_usec()
				rd.capture_timestamp("a")
				var cl := rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(cl, pipe)
				for i in k:
					rd.compute_list_bind_uniform_set(cl, sets[i % nb], 0)
					rd.compute_list_set_push_constant(cl, pc, pc.size())
					rd.compute_list_dispatch(cl, ceili(n / 64.0), 1, 1)
					if bar:
						rd.compute_list_add_barrier(cl)
				rd.compute_list_end()
				rd.capture_timestamp("b")
				rd.submit()
				rd.sync()
				cpu = minf(cpu, (Time.get_ticks_usec() - t0) / 1000.0)
				var ta := -1
				var tb := -1
				for i in rd.get_captured_timestamps_count():
					if rd.get_captured_timestamp_name(i) == "a":
						ta = rd.get_captured_timestamp_gpu_time(i)
					elif rd.get_captured_timestamp_name(i) == "b":
						tb = rd.get_captured_timestamp_gpu_time(i)
				best = minf(best, (tb - ta) / 1e6)
			var row := {case = spec[0], n = n, k = k, gpu_ms = best, wall_ms = cpu, us_per_launch = best * 1000.0 / k}
			rows.append(row)
			print("[row] ", JSON.stringify(row))
		for s in sets:
			rd.free_rid(s)
		for b in bufs:
			rd.free_rid(b)
	rd.free_rid(pipe)
	rd.free_rid(sh)
	rd.free()
	var p := ProjectSettings.globalize_path(_out) if _out.begins_with("res://") else _out
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(JSON.stringify({adapter = RenderingServer.get_video_adapter_name(), rows = rows}, " ") + "\n")
	f.close()
	get_tree().quit(0)
