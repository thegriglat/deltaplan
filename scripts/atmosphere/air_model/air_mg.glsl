#[compute]
#version 450
// Многосеточный метод для давления на сетке с маской (AM-02; оператор — как в прикидке
// tools/research/air3d/solver.py, класс MG). φ в центрах клеток (NZ, NY, NX); проводимости граней
// c = K/h² (0 — грань закрыта): cx (NZ, NY, NX+1), cy (NZ, NY+1, NX), cz (NZ+1, NY, NX).
// Огрубление только по x, y (×2), z не огрубляется. Размеры в push-константах — мелкого уровня.
// OP 0 — шаблон C (7 плоскостей) из граней и активности; OP 1 — активность грубого (хоть одна
// из 2×2); OP 2/3/4 — грубые cx/cy/cz; OP 5 — ограничение невязки (среднее 2×2 × активность);
// OP 6 — продолжение: x += e[грубая] · активность · f.x.

layout(local_size_x = 256) in;

layout(constant_id = 0) const uint OP_U = 0u;
#define OP int(OP_U)  // uint: знаковые константы специализации D3D12 в Godot 4.7 не переводит

layout(set = 0, binding = 0, std430) readonly buffer B0 { float in0[]; };
layout(set = 0, binding = 1, std430) readonly buffer B1 { float in1[]; };
layout(set = 0, binding = 2, std430) readonly buffer B2 { float in2[]; };
layout(set = 0, binding = 3, std430) readonly buffer B3 { float act[]; };
layout(set = 0, binding = 4, std430) buffer B4 { float o[]; };

layout(push_constant, std430) uniform PC {
	ivec4 i0;  // NX, NY, NZ мелкого уровня (для OP 0 и 6 — самого уровня)
	ivec4 i1;
	vec4 f;
} pc;

void main() {
	int nx = pc.i0.x, ny = pc.i0.y, nz = pc.i0.z;
	int cx = nx / 2, cy = ny / 2;
	int total;
	if (OP == 0 || OP == 6) total = nx * ny * nz;
	else if (OP == 1 || OP == 5) total = cx * cy * nz;
	else if (OP == 2) total = (cx + 1) * cy * nz;
	else if (OP == 3) total = cx * (cy + 1) * nz;
	else total = cx * cy * (nz + 1);
	int stride = int(gl_NumWorkGroups.x * 256u);
	for (int t = int(gl_GlobalInvocationID.x); t < total; t += stride) {
		if (OP == 0) {
			int n = total;
			int i = t % nx, j = (t / nx) % ny, k = t / (nx * ny);
			float c1 = in0[(k * ny + j) * (nx + 1) + i];
			float c2 = in0[(k * ny + j) * (nx + 1) + i + 1];
			float c3 = in1[(k * (ny + 1) + j) * nx + i];
			float c4 = in1[(k * (ny + 1) + j + 1) * nx + i];
			float c5 = in2[(k * ny + j) * nx + i];
			float c6 = in2[((k + 1) * ny + j) * nx + i];
			float c0 = -(((((c1 + c2) + c3) + c4) + c5) + c6);
			if (i == 0) c1 = 0.0;
			if (i == nx - 1) c2 = 0.0;
			if (j == 0) c3 = 0.0;
			if (j == ny - 1) c4 = 0.0;
			if (k == 0) c5 = 0.0;
			if (k == nz - 1) c6 = 0.0;
			if (act[t] == 0.0 || c0 == 0.0) {
				c0 = 1.0; c1 = 0.0; c2 = 0.0; c3 = 0.0; c4 = 0.0; c5 = 0.0; c6 = 0.0;
			}
			o[t] = c0; o[n + t] = c1; o[2 * n + t] = c2; o[3 * n + t] = c3;
			o[4 * n + t] = c4; o[5 * n + t] = c5; o[6 * n + t] = c6;
		} else if (OP == 1 || OP == 5) {
			int I = t % cx, J = (t / cx) % cy, k = t / (cx * cy);
			int f = (k * ny + 2 * J) * nx + 2 * I;
			if (OP == 1) {
				bool a = in0[f] != 0.0 || in0[f + nx] != 0.0 || in0[f + 1] != 0.0 || in0[f + nx + 1] != 0.0;
				o[t] = a ? 1.0 : 0.0;
			} else {
				o[t] = 0.25 * (((in0[f] + in0[f + nx]) + in0[f + 1]) + in0[f + nx + 1]) * act[t];
			}
		} else if (OP == 2) {
			int w = cx + 1;
			int I = t % w, J = (t / w) % cy, k = t / (w * cy);
			float v = (in0[(k * ny + 2 * J) * (nx + 1) + 2 * I] + in0[(k * ny + 2 * J + 1) * (nx + 1) + 2 * I]) / 8.0;
			int ab = (k * cy + J) * cx;
			float m;
			if (I == 0) m = act[ab];
			else if (I == cx) m = act[ab + cx - 1];
			else m = (act[ab + I] != 0.0 && act[ab + I - 1] != 0.0) ? 1.0 : 0.0;
			o[t] = v * m;
		} else if (OP == 3) {
			int I = t % cx, J = (t / cx) % (cy + 1), k = t / (cx * (cy + 1));
			float v = (in0[(k * (ny + 1) + 2 * J) * nx + 2 * I] + in0[(k * (ny + 1) + 2 * J) * nx + 2 * I + 1]) / 8.0;
			float m;
			if (J == 0) m = act[(k * cy) * cx + I];
			else if (J == cy) m = act[(k * cy + cy - 1) * cx + I];
			else m = (act[(k * cy + J) * cx + I] != 0.0 && act[(k * cy + J - 1) * cx + I] != 0.0) ? 1.0 : 0.0;
			o[t] = v * m;
		} else if (OP == 4) {
			int I = t % cx, J = (t / cx) % cy, K = t / (cx * cy);
			int f = (K * ny + 2 * J) * nx + 2 * I;
			float v = (((in0[f] + in0[f + nx]) + in0[f + 1]) + in0[f + nx + 1]) / 4.0;
			int a0 = J * cx + I;
			int sl = cx * cy;
			float m;
			if (K == 0) m = act[a0];
			else if (K == nz) m = act[(nz - 1) * sl + a0];
			else m = (act[K * sl + a0] != 0.0 && act[(K - 1) * sl + a0] != 0.0) ? 1.0 : 0.0;
			o[t] = v * m;
		} else {
			int i = t % nx, j = (t / nx) % ny, k = t / (nx * ny);
			float e = in0[(k * cy + j / 2) * cx + i / 2];
			o[t] = o[t] + e * (act[t] * pc.f.x);
		}
	}
}
