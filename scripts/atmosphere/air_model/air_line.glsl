#[versions]

line = "";
coarse = "#define COARSE";

#[compute]
#version 450

#VERSION_DEFINES

// Прогонка по линиям в разделяемой памяти (AM-02).
// Группа 256 потоков решает LPG = 256/TPL линий длины n ≤ 1024/LPG (n ≥ 2·TPL; вся линия — в
// разделяемой памяти). Метод разбиения (как PaScaL_TDMA): каждый поток сводит свой отрезок линии
// (≥ 2 точек) модифицированной прогонкой к двум строкам через крайние точки отрезка; сведённая
// система (2·TPL строк на линию) решается параллельной циклической редукцией (PCR); затем
// внутренние точки отрезков. Для диагонально преобладающих матриц устойчив, как прогонка.
// TPL — наибольшая степень 2, не больше min(256, n/2).
//
// MODE 0 — линии 7-точечного шаблона на поле (NZ, NY, NX): уравнение строки
//   C0·x + C_lo·x[−1] + C_hi·x[+1] = b − Σ(остальные 4 соседа·x) — соседи не на линии берутся из X
//   (зебра: parity 0/1 — линии с чётностью суммы двух других индексов; −1 — все линии, «Якоби»).
//   Выход: зебра — на месте в X (соседи чужой чётности в этом проходе не пишутся), «все линии» —
//   в XO. Один буфер в двух привязках не ставим: граф RD тогда теряет запись и барьер.
// MODE 2 — упакованные трёхдиагональные системы: C[(L·n + p)·4 + 0..3] = (a, b, c, d), выход XO[L·n + p]
//   (сведённая система многопроходной прогонки, air_line_mp.glsl).
// MODE 3 — самый грубый уровень V-цикла одной группой: i1.w раз зебра по z, x, y (чётные, затем
//   нечётные линии) с барьером группы между проходами — вместо 6·i1.w запусков на крошечной сетке.

layout(local_size_x = 256) in;

layout(constant_id = 0) const int MODE = 0;

layout(set = 0, binding = 0, std430) readonly buffer BC { float cf[]; };
// Зебра пишет в X на месте. Вариант coarse (MODE 3, всё в одной группе) читает то, что другие
// потоки группы записали в прошлом проходе, — X там coherent; в остальных — нет (кэш L1).
#ifdef COARSE
layout(set = 0, binding = 1, std430) coherent buffer BX { float x[]; };
#else
layout(set = 0, binding = 1, std430) buffer BX { float x[]; };
#endif
layout(set = 0, binding = 2, std430) readonly buffer BB { float b[]; };
layout(set = 0, binding = 3, std430) buffer BXO { float xo[]; };

layout(push_constant, std430) uniform PC {
	ivec4 i0;  // NX, NY, NZ, dir (0 x, 1 y, 2 z)
	ivec4 i1;  // parity, число линий, n (длина линии), проходов (MODE 3)
	vec4 f;
} pc;

shared float sa[1024];
shared float sb[1024];
shared float sc[1024];
shared float sd[1024];
shared float ra[512];
shared float rc[512];
shared float rd[512];

// Текущий проход (одинаков для всей группы).
int g_nx, g_ny, g_nz, g_dir, g_par, g_nlines, g_n, g_tpl, g_lpg;

int line_tpl(int n) {
	int t = 1;
	while (t * 2 <= min(256, n / 2)) t *= 2;
	return t;
}

// Линия L → (a1, a2): a1 — быстрый из двух других индексов, a2 — медленный.
bool line_of(int L, out int a1, out int a2) {
	int n1 = g_dir == 0 ? g_ny : g_nx;
	if (g_par < 0) {
		a1 = L % n1;
		a2 = L / n1;
		return true;
	}
	int h = (n1 + 1) / 2;
	a2 = L / h;
	a1 = 2 * (L % h) + ((a2 + g_par) & 1);
	return a1 < n1;
}

int gidx(int p, int a1, int a2) {
	if (g_dir == 0) return (a2 * g_ny + a1) * g_nx + p;
	if (g_dir == 1) return (a2 * g_ny + p) * g_nx + a1;
	return (p * g_ny + a2) * g_nx + a1;
}

// Строка уравнения точки p линии (a1, a2).
void row_of(int p, int a1, int a2, out float ca, out float cb, out float cc, out float cd) {
	int nx = g_nx, ny = g_ny, nz = g_nz, dir = g_dir;
	int n = nx * ny * nz;
	int i, j, k;
	if (dir == 0) { i = p; j = a1; k = a2; }
	else if (dir == 1) { i = a1; j = p; k = a2; }
	else { i = a1; j = a2; k = p; }
	int sz = nx * ny;
	int g = (k * ny + j) * nx + i;
	float r = b[g];
	// соседи — без ветвлений по коэффициенту (иначе цепочка зависимых чтений); за краем — 0
	if (dir != 0) {
		r -= (i > 0 ? cf[n + g] * x[g - 1] : 0.0) + (i < nx - 1 ? cf[2 * n + g] * x[g + 1] : 0.0);
	}
	if (dir != 1) {
		r -= (j > 0 ? cf[3 * n + g] * x[g - nx] : 0.0) + (j < ny - 1 ? cf[4 * n + g] * x[g + nx] : 0.0);
	}
	if (dir != 2) {
		r -= (k > 0 ? cf[5 * n + g] * x[g - sz] : 0.0) + (k < nz - 1 ? cf[6 * n + g] * x[g + sz] : 0.0);
	}
	ca = p > 0 ? cf[(1 + 2 * dir) * n + g] : 0.0;
	cb = cf[g];
	cc = p < g_n - 1 ? cf[(2 + 2 * dir) * n + g] : 0.0;
	cd = r;
}

// Линии L0 .. L0+LPG−1 текущего прохода.
void solve_batch(int L0) {
	int tid = int(gl_LocalInvocationID.x);
	int n = g_n;
	int TPL = g_tpl;
	int LPG = g_lpg;
	bool xfast = MODE == 2 || g_dir == 0;
	barrier();  // разделяемая память свободна (прошлый пакет записан)
	// 1. Загрузка: вдоль x подряд идут точки линии, по y/z — соседние линии.
	for (int t = tid; t < LPG * n; t += 256) {
		int l = xfast ? t / n : t % LPG;
		int p = xfast ? t % n : t / LPG;
		int L = L0 + l;
		int si = l * n + p;
		int a1, a2;
		if (L >= g_nlines || (MODE != 2 && !line_of(L, a1, a2))) {
			sa[si] = 0.0; sb[si] = 1.0; sc[si] = 0.0; sd[si] = 0.0;
			continue;
		}
		float ca, cb, cc, cd;
		if (MODE == 2) {
			int q = (L * n + p) * 4;
			ca = cf[q]; cb = cf[q + 1]; cc = cf[q + 2]; cd = cf[q + 3];
		} else {
			row_of(p, a1, a2, ca, cb, cc, cd);
		}
		sa[si] = ca; sb[si] = cb; sc[si] = cc; sd[si] = cd;
	}
	barrier();
	// 2. Отрезок потока: строки через крайние точки отрезка.
	int l = tid / TPL;
	int s = tid % TPL;
	int base = l * n;
	int p0 = base + s * n / TPL;
	int p1 = base + (s + 1) * n / TPL;
	{
		float inv = 1.0 / sb[p0];
		sa[p0] *= inv; sc[p0] *= inv; sd[p0] *= inv;
		inv = 1.0 / sb[p0 + 1];
		sa[p0 + 1] *= inv; sc[p0 + 1] *= inv; sd[p0 + 1] *= inv;
		for (int i = p0 + 2; i < p1; ++i) {
			float r = 1.0 / (sb[i] - sa[i] * sc[i - 1]);
			sd[i] = r * (sd[i] - sa[i] * sd[i - 1]);
			sc[i] = r * sc[i];
			sa[i] = -r * sa[i] * sa[i - 1];
		}
		for (int i = p1 - 3; i >= p0 + 1; --i) {
			sd[i] -= sc[i] * sd[i + 1];
			sa[i] -= sc[i] * sa[i + 1];
			sc[i] = -sc[i] * sc[i + 1];
		}
		if (p1 - p0 >= 3) {
			float r = 1.0 / (1.0 - sc[p0] * sa[p0 + 1]);
			sd[p0] = r * (sd[p0] - sc[p0] * sd[p0 + 1]);
			sa[p0] = r * sa[p0];
			sc[p0] = -r * sc[p0] * sc[p0 + 1];
		}
		int q = l * 2 * TPL + 2 * s;
		ra[q] = sa[p0]; rc[q] = sc[p0]; rd[q] = sd[p0];
		ra[q + 1] = sa[p1 - 1]; rc[q + 1] = sc[p1 - 1]; rd[q + 1] = sd[p1 - 1];
	}
	barrier();
	// 3. PCR по сведённой системе (диагональ нормирована к 1).
	int m2 = 2 * TPL;
	int qb = l * m2;
	for (int st = 1; st < m2; st <<= 1) {
		float na[2], nc[2], nd[2];
		for (int e = 0; e < 2; ++e) {
			int q = 2 * s + e;
			int gi = qb + q;
			float a = ra[gi], c = rc[gi], d = rd[gi];
			float am = 0.0, cm = 0.0, dm = 0.0, ap = 0.0, cp = 0.0, dp = 0.0;
			if (q - st >= 0) { am = ra[gi - st]; cm = rc[gi - st]; dm = rd[gi - st]; }
			if (q + st < m2) { ap = ra[gi + st]; cp = rc[gi + st]; dp = rd[gi + st]; }
			float inv = 1.0 / (1.0 - a * cm - c * ap);
			na[e] = -a * am * inv;
			nc[e] = -c * cp * inv;
			nd[e] = (d - a * dm - c * dp) * inv;
		}
		barrier();
		for (int e = 0; e < 2; ++e) {
			int gi = qb + 2 * s + e;
			ra[gi] = na[e]; rc[gi] = nc[e]; rd[gi] = nd[e];
		}
		barrier();
	}
	// 4. Внутренние точки отрезка.
	{
		float x0 = rd[qb + 2 * s];
		float xl = rd[qb + 2 * s + 1];
		sd[p0] = x0;
		sd[p1 - 1] = xl;
		for (int i = p0 + 1; i < p1 - 1; ++i) sd[i] = sd[i] - sa[i] * x0 - sc[i] * xl;
	}
	barrier();
	// 5. Запись тем же порядком, что загрузка.
	for (int t = tid; t < LPG * n; t += 256) {
		int ll = xfast ? t / n : t % LPG;
		int p = xfast ? t % n : t / LPG;
		int L = L0 + ll;
		if (L >= g_nlines) continue;
		int si = ll * n + p;
		if (MODE == 2) {
			xo[L * n + p] = sd[si];
			continue;
		}
		int a1, a2;
		if (!line_of(L, a1, a2)) continue;
		if (g_par >= 0) x[gidx(p, a1, a2)] = sd[si];
		else xo[gidx(p, a1, a2)] = sd[si];
	}
}

void set_pass(int dir, int par) {
	g_dir = dir;
	g_par = par;
	g_n = dir == 0 ? g_nx : (dir == 1 ? g_ny : g_nz);
	int n1 = dir == 0 ? g_ny : g_nx;
	int n2 = dir == 2 ? g_ny : g_nz;
	g_nlines = par < 0 ? n1 * n2 : ((n1 + 1) / 2) * n2;
	g_tpl = line_tpl(g_n);
	g_lpg = 256 / g_tpl;
}

void main() {
	g_nx = pc.i0.x;
	g_ny = pc.i0.y;
	g_nz = pc.i0.z;
	if (MODE == 3) {
		const int dirs[3] = int[3](2, 0, 1);
		for (int sw = 0; sw < pc.i1.w; ++sw) {
			for (int di = 0; di < 3; ++di) {
				for (int par = 0; par < 2; ++par) {
					set_pass(dirs[di], par);
					for (int L0 = 0; L0 < g_nlines; L0 += g_lpg) solve_batch(L0);
					memoryBarrierBuffer();
					barrier();
				}
			}
		}
		return;
	}
	if (MODE == 2) {
		g_dir = 0;
		g_par = 0;
		g_n = pc.i1.z;
		g_nlines = pc.i1.y;
		g_tpl = line_tpl(g_n);
		g_lpg = 256 / g_tpl;
	} else {
		set_pass(pc.i0.w, pc.i1.x);
	}
	int grp = int(gl_WorkGroupID.y * gl_NumWorkGroups.x + gl_WorkGroupID.x);
	solve_batch(grp * g_lpg);
}
