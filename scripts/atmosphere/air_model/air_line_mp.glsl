#[compute]
#version 450
// Многопроходная прогонка для линий длиннее 1024 точек (AM-02). Тот же метод разбиения, что в
// air_line.glsl, но на уровне всей сетки: поток — отрезок линии (S отрезков на линию, 2·S ≤ 1024).
// PASS 1: поток сводит свой отрезок модифицированной прогонкой (коэффициенты — в W, по линии
//   подряд), пишет две строки сведённой системы в R[(L·2S + q)·4 + (a, b, c, d)].
// Затем air_line.glsl MODE 2 решает сведённые системы (длина 2S) → XR[L·2S + q].
// PASS 3: внутренние точки отрезков по крайним → XO (поле).
// Линии, зебра и строка уравнения — как в air_line.glsl MODE 0.

layout(local_size_x = 64) in;

layout(constant_id = 0) const int PASS = 1;

layout(set = 0, binding = 0, std430) readonly buffer BC { float cf[]; };
layout(set = 0, binding = 1, std430) buffer BX { float x[]; };  // зебра пишет сюда же
layout(set = 0, binding = 2, std430) readonly buffer BB { float b[]; };
layout(set = 0, binding = 3, std430) buffer BXO { float xo[]; };
layout(set = 0, binding = 4, std430) buffer BW { float w[]; };
layout(set = 0, binding = 5, std430) buffer BR { float rr[]; };

layout(push_constant, std430) uniform PC {
	ivec4 i0;  // NX, NY, NZ, dir
	ivec4 i1;  // parity, число линий, n, S — отрезков на линию
	vec4 f;
} pc;

bool line_of(int L, out int a1, out int a2) {
	int dir = pc.i0.w;
	int n1 = dir == 0 ? pc.i0.y : pc.i0.x;
	int par = pc.i1.x;
	if (par < 0) {
		a1 = L % n1;
		a2 = L / n1;
		return true;
	}
	int h = (n1 + 1) / 2;
	a2 = L / h;
	a1 = 2 * (L % h) + ((a2 + par) & 1);
	return a1 < n1;
}

int gidx(int p, int a1, int a2) {
	int dir = pc.i0.w, nx = pc.i0.x, ny = pc.i0.y;
	if (dir == 0) return (a2 * ny + a1) * nx + p;
	if (dir == 1) return (a2 * ny + p) * nx + a1;
	return (p * ny + a2) * nx + a1;
}

void row_of(int p, int a1, int a2, out float ca, out float cb, out float cc, out float cd) {
	int nx = pc.i0.x, ny = pc.i0.y, nz = pc.i0.z, dir = pc.i0.w;
	int n = nx * ny * nz;
	int i, j, k;
	if (dir == 0) { i = p; j = a1; k = a2; }
	else if (dir == 1) { i = a1; j = p; k = a2; }
	else { i = a1; j = a2; k = p; }
	int sz = nx * ny;
	int g = (k * ny + j) * nx + i;
	int len = dir == 0 ? nx : (dir == 1 ? ny : nz);
	float r = b[g];
	float v;
	if (dir != 0) {
		v = cf[n + g];     if (v != 0.0 && i > 0)      r -= v * x[g - 1];
		v = cf[2 * n + g]; if (v != 0.0 && i < nx - 1) r -= v * x[g + 1];
	}
	if (dir != 1) {
		v = cf[3 * n + g]; if (v != 0.0 && j > 0)      r -= v * x[g - nx];
		v = cf[4 * n + g]; if (v != 0.0 && j < ny - 1) r -= v * x[g + nx];
	}
	if (dir != 2) {
		v = cf[5 * n + g]; if (v != 0.0 && k > 0)      r -= v * x[g - sz];
		v = cf[6 * n + g]; if (v != 0.0 && k < nz - 1) r -= v * x[g + sz];
	}
	ca = p > 0 ? cf[(1 + 2 * dir) * n + g] : 0.0;
	cb = cf[g];
	cc = p < len - 1 ? cf[(2 + 2 * dir) * n + g] : 0.0;
	cd = r;
}

void main() {
	int n = pc.i1.z;
	int S = pc.i1.w;
	int id = int(gl_GlobalInvocationID.x);
	int L = id / S;
	int s = id % S;
	if (L >= pc.i1.y) return;
	int a1, a2;
	bool valid = line_of(L, a1, a2);
	int p0 = s * n / S;
	int p1 = (s + 1) * n / S;
	int wb = L * n;  // начало линии в W (по 3 числа на точку)
	int q = (L * 2 * S + 2 * s);
	if (PASS == 1) {
		if (!valid) {
			// Пустая линия: тождественные строки.
			for (int e = 0; e < 2; ++e) {
				rr[(q + e) * 4] = 0.0; rr[(q + e) * 4 + 1] = 1.0;
				rr[(q + e) * 4 + 2] = 0.0; rr[(q + e) * 4 + 3] = 0.0;
			}
			return;
		}
		float ca, cb, cc, cd;
		// строки p0, p0+1 — нормировка; далее — прямой ход
		for (int p = p0; p < p1; ++p) {
			row_of(p, a1, a2, ca, cb, cc, cd);
			int o = (wb + p) * 3;
			if (p < p0 + 2) {
				float inv = 1.0 / cb;
				w[o] = ca * inv; w[o + 1] = cc * inv; w[o + 2] = cd * inv;
			} else {
				int om = o - 3;
				float r = 1.0 / (cb - ca * w[om + 1]);
				w[o + 2] = r * (cd - ca * w[om + 2]);
				w[o + 1] = r * cc;
				w[o] = -r * ca * w[om];
			}
		}
		for (int p = p1 - 3; p >= p0 + 1; --p) {
			int o = (wb + p) * 3, op = o + 3;
			w[o + 2] -= w[o + 1] * w[op + 2];
			w[o] -= w[o + 1] * w[op];
			w[o + 1] = -w[o + 1] * w[op + 1];
		}
		int o0 = (wb + p0) * 3;
		if (p1 - p0 >= 3) {
			int o1 = o0 + 3;
			float r = 1.0 / (1.0 - w[o0 + 1] * w[o1]);
			w[o0 + 2] = r * (w[o0 + 2] - w[o0 + 1] * w[o1 + 2]);
			w[o0] = r * w[o0];
			w[o0 + 1] = -r * w[o0 + 1] * w[o1 + 1];
		}
		int ol = (wb + p1 - 1) * 3;
		rr[q * 4] = w[o0]; rr[q * 4 + 1] = 1.0; rr[q * 4 + 2] = w[o0 + 1]; rr[q * 4 + 3] = w[o0 + 2];
		rr[(q + 1) * 4] = w[ol]; rr[(q + 1) * 4 + 1] = 1.0;
		rr[(q + 1) * 4 + 2] = w[ol + 1]; rr[(q + 1) * 4 + 3] = w[ol + 2];
	} else {
		if (!valid) return;
		// XR (решение сведённой системы) привязан к binding 5.
		float x0 = rr[q];
		float xl = rr[q + 1];
		bool inplace = pc.i1.x >= 0;  // зебра — на месте в X, «все линии» — в XO
		for (int p = p0; p < p1; ++p) {
			int o = (wb + p) * 3;
			float v = p == p0 ? x0 : (p == p1 - 1 ? xl : w[o + 2] - w[o] * x0 - w[o + 1] * xl);
			if (inplace) x[gidx(p, a1, a2)] = v;
			else xo[gidx(p, a1, a2)] = v;
		}
	}
}
