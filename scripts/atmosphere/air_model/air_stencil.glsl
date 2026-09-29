#[compute]
#version 450
// 7-точечный шаблон (AM-02): OP 0 — невязка r = b − C·x, OP 1 — произведение y = C·x.
// Раскладка: поле (NZ, NY, NX), индекс (k·NY + j)·NX + i; шаблон C — 7 плоскостей по N:
// 0 центр, 1 −x, 2 +x, 3 −y, 4 +y, 5 −z, 6 +z. Сосед за краем массива отсутствует
// (нулевой коэффициент там обязателен и так; здесь — защита от выхода за строку).

layout(local_size_x = 256) in;

layout(constant_id = 0) const int OP = 0;

layout(set = 0, binding = 0, std430) readonly buffer BC { float c[]; };
layout(set = 0, binding = 1, std430) readonly buffer BX { float x[]; };
layout(set = 0, binding = 2, std430) readonly buffer BB { float b[]; };
layout(set = 0, binding = 3, std430) writeonly buffer BR { float r[]; };

layout(push_constant, std430) uniform PC {
	ivec4 i0;  // NX, NY, NZ, —
	ivec4 i1;
	vec4 f;
} pc;

void main() {
	int nx = pc.i0.x, ny = pc.i0.y, nz = pc.i0.z;
	int n = nx * ny * nz;
	int sz = nx * ny;
	int stride = int(gl_NumWorkGroups.x * 256u);
	for (int idx = int(gl_GlobalInvocationID.x); idx < n; idx += stride) {
		int i = idx % nx;
		int j = (idx / nx) % ny;
		int k = idx / sz;
		// без ветвлений по коэффициенту (иначе цепочка зависимых чтений); за краем — 0
		float acc = c[idx] * x[idx];
		acc += (i > 0 ? c[n + idx] * x[idx - 1] : 0.0) + (i < nx - 1 ? c[2 * n + idx] * x[idx + 1] : 0.0);
		acc += (j > 0 ? c[3 * n + idx] * x[idx - nx] : 0.0) + (j < ny - 1 ? c[4 * n + idx] * x[idx + nx] : 0.0);
		acc += (k > 0 ? c[5 * n + idx] * x[idx - sz] : 0.0) + (k < nz - 1 ? c[6 * n + idx] * x[idx + sz] : 0.0);
		r[idx] = OP == 0 ? b[idx] - acc : acc;
	}
}
