extends TestCase
## Заглушка AM-00: локальный RenderingDevice есть, компилирует и гоняет тривиальный
## compute-шейдер. Под headless (tools/check.sh) RD недоступен — тест пропускается
## (TestCase.needs_gpu), не падает. Запускается tools/gpu_tests.sh (окно, флаг --gpu).

const N := 64

const SHADER_SRC := """
#version 450
layout(local_size_x = 64) in;
layout(set = 0, binding = 0, std430) buffer Data { float v[64]; } data;
void main() {
	uint i = gl_GlobalInvocationID.x;
	data.v[i] = data.v[i] * 2.0 + 1.0;
}
"""


func needs_gpu() -> bool:
	return true


func test_compute_smoke() -> void:
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		check(false, "нет RenderingDevice (запускать через tools/gpu_tests.sh)")
		return

	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = SHADER_SRC
	var spirv := rd.shader_compile_spirv_from_source(src)
	if spirv.compile_error_compute != "":
		check(false, "ошибка компиляции шейдера: " + spirv.compile_error_compute)
		rd.free()
		return
	var shader := rd.shader_create_from_spirv(spirv)

	var n := N
	var input := PackedFloat32Array()
	input.resize(n)
	for i in n:
		input[i] = float(i)
	var buf := rd.storage_buffer_create(input.size() * 4, input.to_byte_array())

	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 0
	u.add_id(buf)
	var uniform_set := rd.uniform_set_create([u], shader, 0)

	var pipeline := rd.compute_pipeline_create(shader)
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	rd.compute_list_dispatch(cl, 1, 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()

	var out_bytes := rd.buffer_get_data(buf)
	var out := out_bytes.to_float32_array()
	var ok := true
	for i in n:
		if absf(out[i] - (float(i) * 2.0 + 1.0)) > 1e-5:
			ok = false
			break
	check(ok, "compute-шейдер вернул неверный результат")

	rd.free_rid(uniform_set)
	rd.free_rid(pipeline)
	rd.free_rid(buf)
	rd.free_rid(shader)
	rd.free()
