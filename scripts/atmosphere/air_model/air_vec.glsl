#[compute]
#version 450
// Поэлементные ядра модели воздуха (AM-02). Операция — константа специализации OP.
// Множитель a = f.x · (i1.x ≥ 0 ? S[i1.x] : 1) / (i1.y ≥ 0 ? S[i1.y] : 1) — скаляр может
// приходить из буфера скаляров S (результат редукции) без чтения на CPU.
// Цикл «по всей сетке с шагом» — сколько групп ни запусти, результат один и тот же.

layout(local_size_x = 256) in;

layout(constant_id = 0) const int OP = 0;
const int OP_FILL = 0;   // Y = f.y
const int OP_COPY = 1;   // Y = X
const int OP_SCALE = 2;  // Y = a·Y
const int OP_AXPY = 3;   // Y = Y + a·X
const int OP_XPAY = 4;   // Y = X + a·Y
const int OP_AXPBY = 5;  // Y = a·X + f.y·Y
const int OP_MUL = 6;    // Y = X·Y

layout(set = 0, binding = 0, std430) readonly buffer BX { float x[]; };
layout(set = 0, binding = 1, std430) buffer BY { float y[]; };
layout(set = 0, binding = 2, std430) readonly buffer BS { float s[]; };

layout(push_constant, std430) uniform PC {
	ivec4 i0;  // n, —, —, —
	ivec4 i1;  // индекс скаляра-множителя, индекс скаляра-делителя
	vec4 f;    // a, b
} pc;

void main() {
	int n = pc.i0.x;
	float a = pc.f.x;
	if (pc.i1.x >= 0) a *= s[pc.i1.x];
	if (pc.i1.y >= 0) a /= s[pc.i1.y];
	int stride = int(gl_NumWorkGroups.x * gl_WorkGroupSize.x);
	for (int i = int(gl_GlobalInvocationID.x); i < n; i += stride) {
		if (OP == OP_FILL) y[i] = pc.f.y;
		else if (OP == OP_COPY) y[i] = x[i];
		else if (OP == OP_SCALE) y[i] = a * y[i];
		else if (OP == OP_AXPY) y[i] = y[i] + a * x[i];
		else if (OP == OP_XPAY) y[i] = x[i] + a * y[i];
		else if (OP == OP_AXPBY) y[i] = a * x[i] + pc.f.y * y[i];
		else if (OP == OP_MUL) y[i] = x[i] * y[i];
	}
}
