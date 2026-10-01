#[compute]
#version 450
// Редукции деревом без атомиков (AM-02): сумма, max|x|, скалярное произведение.
// Проход 0: G групп; поток t складывает элементы t, t+T, t+2T… (T = G·256) по порядку, затем
// дерево в разделяемой памяти → P[группа]. Проход 1: одна группа сворачивает P[0..G) → S[out].
// Порядок сложения задан только размерами (n, G) — повторный расчёт даёт те же биты.

layout(local_size_x = 256) in;

layout(constant_id = 0) const int OP = 0;    // 0 — сумма, 1 — max|x|, 2 — Σ x·y
layout(constant_id = 1) const int PASS = 0;

layout(set = 0, binding = 0, std430) readonly buffer BX { float x[]; };
layout(set = 0, binding = 1, std430) readonly buffer BY { float y[]; };
layout(set = 0, binding = 2, std430) buffer BP { float part[]; };
layout(set = 0, binding = 3, std430) buffer BS { float s[]; };

layout(push_constant, std430) uniform PC {
	ivec4 i0;  // n, индекс результата в S, —, —
	ivec4 i1;
	vec4 f;
} pc;

shared float red[256];

float combine(float a, float b) {
	return OP == 1 ? max(a, b) : a + b;
}

void main() {
	uint t = gl_LocalInvocationID.x;
	float acc = 0.0;
	if (PASS == 0) {
		int n = pc.i0.x;
		int stride = int(gl_NumWorkGroups.x * 256u);
		for (int i = int(gl_GlobalInvocationID.x); i < n; i += stride) {
			float v = x[i];
			if (OP == 1) v = abs(v);
			else if (OP == 2) v *= y[i];
			acc = combine(acc, v);
		}
	} else {
		int g = pc.i0.x;  // число частичных сумм
		for (int i = int(t); i < g; i += 256) acc = combine(acc, part[i]);
	}
	red[t] = acc;
	barrier();
	for (uint h = 128u; h > 0u; h >>= 1u) {
		if (t < h) red[t] = combine(red[t], red[t + h]);
		barrier();
	}
	if (t == 0u) {
		if (PASS == 0) part[gl_WorkGroupID.x] = red[0];
		else s[pc.i0.y] = red[0];
	}
}
