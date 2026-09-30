#[versions]

setup = "#define K_SETUP";
mgfaces = "#define K_MGFACES";
bc = "#define K_BC";
kloc = "#define K_KLOC";
mom = "#define K_MOM";
heat = "#define K_HEAT";
div = "#define K_DIV";
proj = "#define K_PROJ";
resid = "#define K_RESID";

#[compute]
#version 450

#VERSION_DEFINES

// Итерация Пикара масштаба 1 на GPU (AM-03). Спецификация — tools/research/air3d/reference.md →
// «Дискретизация», исполнение-эталон — tools/research/air3d/air.py (ядра CUDA _SRC, класс Air);
// здесь то же построчно, float32. Поле (NZ, NY, NX) с ореолом, индекс (k·NY + j)·NX + i;
// грани MAC: u[k,j,i] — между клетками (i−1, i), v — (j−1, j), w — (k−1, k).
// Типы (tcode, одно число на клетку): cell + 4·tu + 16·tv + 64·tw; cell: 0 земля, 1 воздух,
// 2 ореол; грань: 0 закрыта землёй, 1 неизвестная, 2 воздух–ореол, 3 ореол–ореол.
// Шаблон — строкой на точку: C[8·idx + o], o = 0 центр, 1 −x, 2 +x, 3 −y, 4 +y, 5 −z, 6 +z,
// C[8·idx + 7] = b; Σ C·x = b (air_line.glsl, PACKED = 1: один сектор 32 Б на строку).
// Цикл «по всей сетке с шагом» (число групп ≤ 65535 не влияет на результат).

layout(local_size_x = 256) in;

layout(push_constant, std430) uniform PC {
	ivec4 i0;  // NX, NY, NZ, вариант (компонента / режим / что писать)
	ivec4 i1;
	vec4 f;
} pc;

// Параметры (AirCase.prm_array): числа одного решения.
layout(set = 0, binding = 0, std430) readonly buffer BPrm { float prm[]; };
const int P_DX = 0, P_DZ = 1, P_IDTU = 2, P_CD = 3, P_ZBOT = 4, P_RELAX = 5, P_CSDX2 = 6;
const int P_IDTTH = 7, P_ITAU = 8, P_UAX = 9, P_UAY = 10, P_Z0 = 11, P_ZSAT = 12, P_ALPHA = 13;
const int P_USTAR = 14, P_KFA = 15, P_FSC = 16, P_WINDY = 17, P_KAPPA = 18;
// 1 — окно клипмапа (AM-04): фон и граница ветра на гранях — от родителя (air_window.glsl:nest),
// setup их не пишет.
const int P_NEST = 19;
// 1/Pr_t — K_θ = K/Pr_t в шаблоне тепла (один множитель на все три оси; AirCase.p.pr_t).
const int P_IPRT = 20;
// Столбцы (NY·NX на плоскость, с ореолом) и уровни (NZ на плоскость) — AirCase.
const int C_HP = 0, C_KF = 1, C_HBL = 2, C_WST = 3, C_INVL = 4, C_UNST = 5, C_SIDE = 6;
const int C_SCS = 7, C_QV = 8, C_QK0 = 9, C_QK1 = 10, C_LAM = 11;
const int L_ZC = 0, L_GAM = 1, L_CPL = 2, L_SPZ = 3, L_SPZW = 4;
const float GTH = 9.81 / 300.0;

int NX, NY, NZ, NYX, N;

int cell_of(float t) { return int(t) & 3; }
int tu_of(float t) { return (int(t) >> 2) & 3; }
int tv_of(float t) { return (int(t) >> 4) & 3; }
int tw_of(float t) { return (int(t) >> 6) & 3; }

void dims() {
	NX = pc.i0.x;
	NY = pc.i0.y;
	NZ = pc.i0.z;
	NYX = NX * NY;
	N = NYX * NZ;
}

#define GRID_LOOP(total) \
	int _stride = int(gl_NumWorkGroups.x * 256u); \
	for (int t = int(gl_GlobalInvocationID.x); t < (total); t += _stride)

// ================================================================ подготовка (один раз на решение)
#ifdef K_SETUP
layout(set = 0, binding = 1, std430) readonly buffer BCol { float col[]; };
layout(set = 0, binding = 2, std430) readonly buffer BLev { float lev[]; };
layout(set = 0, binding = 3, std430) writeonly buffer BT { float tcode[]; };
layout(set = 0, binding = 4, std430) buffer BUb { float ubu[]; };
layout(set = 0, binding = 5, std430) buffer BVb { float ubv[]; };
layout(set = 0, binding = 6, std430) writeonly buffer BSu { float spu[]; };
layout(set = 0, binding = 7, std430) writeonly buffer BSw { float spw[]; };
layout(set = 0, binding = 8, std430) writeonly buffer BSc { float spc[]; };
layout(set = 0, binding = 9, std430) writeonly buffer BKb { float kbg[]; };
layout(set = 0, binding = 10, std430) writeonly buffer BQ { float qsrc[]; };
layout(set = 0, binding = 11, std430) writeonly buffer BKx { float kx[]; };
layout(set = 0, binding = 12, std430) writeonly buffer BKy { float ky[]; };
layout(set = 0, binding = 13, std430) writeonly buffer BKz { float kz[]; };

float C(int plane, int j, int i) { return col[plane * NYX + j * NX + i]; }

int cellt(int k, int j, int i) {
	if (k == 0 || float(k) < C(C_KF, j, i)) return 0;
	if (i == 0 || i == NX - 1 || j == 0 || j == NY - 1 || k == NZ - 1) return 2;
	return 1;
}

int ftype(int a, int b) {
	if (a == 0 || b == 0) return 0;
	if (a == 1 && b == 1) return 1;
	if ((a == 1 && b == 2) || (a == 2 && b == 1)) return 2;
	return 3;
}

float prof(float agl) {
	float z = max(agl, prm[P_Z0]) / prm[P_ZSAT];
	return min(pow(z, prm[P_ALPHA]), 1.0);
}

// Значение на грани типа 2 («жёсткая» граница): приток — фон, выход — фон × баланс площадей.
float fixed_face(float ub, float s) {
	if (prm[P_WINDY] == 0.0) return 0.0;
	float nn = s * ub;
	return nn > 0.0 ? ub * prm[P_FSC] : (nn < 0.0 ? ub : 0.0);
}

float kc_cell(int k, int j, int i) {
	return 1.0 / (prm[P_IDTU] + max(lev[L_SPZ * NZ + k], C(C_SIDE, j, i)));
}

void main() {
	dims();
	GRID_LOOP(N) {
		int i = t % NX, j = (t / NX) % NY, k = t / NYX;
		int c = cellt(k, j, i);
		int tu = i == 0 ? 3 : ftype(cellt(k, j, i - 1), c);
		int tv = j == 0 ? 3 : ftype(cellt(k, j - 1, i), c);
		int tw = k == 0 ? 0 : ftype(cellt(k - 1, j, i), c);
		tcode[t] = float(c + 4 * tu + 16 * tv + 64 * tw);
		float zc = lev[L_ZC * NZ + k];
		float side = C(C_SIDE, j, i);
		// фоновый ветер на гранях (профиль над средней высотой двух столбцов грани)
		float hu = i > 0 ? 0.5 * (C(C_HP, j, i) + C(C_HP, j, i - 1)) : C(C_HP, j, 0);
		float hv = j > 0 ? 0.5 * (C(C_HP, j, i) + C(C_HP, j - 1, i)) : C(C_HP, 0, i);
		float ub = tu != 0 ? prm[P_UAX] * prof(zc - hu) : 0.0;
		float vb = tv != 0 ? prm[P_UAY] * prof(zc - hv) : 0.0;
		float s = c == 1 ? -1.0 : 1.0;  // внешняя нормаль грани типа 2 (клетка c1 = эта)
		if (prm[P_NEST] == 0.0) {
			ubu[t] = tu == 2 ? fixed_face(ub, s) : ub;
			ubv[t] = tv == 2 ? fixed_face(vb, s) : vb;
		}
		float spz = lev[L_SPZ * NZ + k];
		float spzw = lev[L_SPZW * NZ + k];
		spu[t] = max(spz, side);
		spw[t] = max(spzw, side);
		spc[t] = max(spz, C(C_SCS, j, i));
		// K_b: Троен–Март / Холтслаг–Бовилль по столбцу (в ореоле — соседний внутренний)
		int jj = clamp(j, 1, NY - 2), ii = clamp(i, 1, NX - 2);
		float h = C(C_HBL, jj, ii);
		float z = max(zc - C(C_HP, jj, ii), 0.0);
		float ust = prm[P_USTAR];
		float kap = prm[P_KAPPA];
		float wm;
		if (C(C_UNST, jj, ii) != 0.0) {
			float zs = min(z, 0.1 * h);
			float ws = C(C_WST, jj, ii);
			float a = ust * ust * ust + 7.0 * kap * (zs / h) * ws * ws * ws;
			wm = a > 0.0 ? pow(a, 1.0 / 3.0) : 0.0;
		} else {
			wm = ust > 0.0 ? ust / (1.0 + 5.0 * z * C(C_INVL, jj, ii)) : 0.0;
		}
		float r1 = clamp(1.0 - z / h, 0.0, 1.0);
		float kbl = kap * wm * z * r1 * r1;
		kbg[t] = max(prm[P_KFA], z < h ? kbl : 0.0);
		// нагрев: значение и диапазон уровней столбца (внутренние столбцы)
		bool inner = i > 0 && i < NX - 1 && j > 0 && j < NY - 1;
		qsrc[t] = (inner && float(k) >= C(C_QK0, j, i) && float(k) <= C(C_QK1, j, i)) ? C(C_QV, j, i) : 0.0;
		// проводимости проекции (SIMPLEC): K = 1/(1/Δτ + s) на гранях-неизвестных
		kx[t] = tu == 1 ? 0.5 * (kc_cell(k, j, i) + kc_cell(k, j, i - 1)) : 0.0;
		ky[t] = tv == 1 ? 0.5 * (kc_cell(k, j, i) + kc_cell(k, j - 1, i)) : 0.0;
		kz[t] = tw == 1 ? 1.0 / (prm[P_IDTU] + max(spzw, side) + lev[L_CPL * NZ + k]) : 0.0;
	}
}
#endif

// ================================================================ грани и маска V-цикла (без ореола)
#ifdef K_MGFACES
layout(set = 0, binding = 1, std430) readonly buffer BT { float tcode[]; };
layout(set = 0, binding = 2, std430) readonly buffer BKx { float kx[]; };
layout(set = 0, binding = 3, std430) readonly buffer BKy { float ky[]; };
layout(set = 0, binding = 4, std430) readonly buffer BKz { float kz[]; };
layout(set = 0, binding = 5, std430) writeonly buffer BO { float o[]; };

void main() {
	dims();
	int nx = NX - 2, ny = NY - 2, nz = NZ - 2;
	int which = pc.i0.w;
	float dx = prm[P_DX], dz = prm[P_DZ];
	int w = nx + (which == 0 ? 1 : 0);
	int hgt = ny + (which == 1 ? 1 : 0);
	int total = w * hgt * (nz + (which == 2 ? 1 : 0));
	GRID_LOOP(total) {
		int i = t % w, j = (t / w) % hgt, k = t / (w * hgt);
		int g = ((k + 1) * NY + j + 1) * NX + i + 1;
		if (which == 0) o[t] = kx[g] / (dx * dx);
		else if (which == 1) o[t] = ky[g] / (dx * dx);
		else if (which == 2) o[t] = kz[g] / (dz * dz);
		else o[t] = cell_of(tcode[g]) == 1 ? 1.0 : 0.0;
	}
}
#endif

// ================================================================ граничные условия
// i0.w = 0 — обычные (apply_bc + ореол как set_ghosts_background): грани не-неизвестные ←
// заданные значения; 1 — старт от фона (init_background: и неизвестные ← фон, θ′ = θ′_d = 0, p = 0).
// θ′ и θ′_d не-неизвестных клеток ← ореол thb / thbd (0 в области, родитель в окне).
#ifdef K_BC
layout(set = 0, binding = 1, std430) readonly buffer BT { float tcode[]; };
layout(set = 0, binding = 2, std430) readonly buffer BUb { float ubu[]; };
layout(set = 0, binding = 3, std430) readonly buffer BVb { float ubv[]; };
layout(set = 0, binding = 4, std430) readonly buffer BWb { float ubw[]; };
layout(set = 0, binding = 5, std430) readonly buffer BThb { float thb[]; };
layout(set = 0, binding = 6, std430) buffer BU { float u[]; };
layout(set = 0, binding = 7, std430) buffer BV { float v[]; };
layout(set = 0, binding = 8, std430) buffer BW { float w[]; };
layout(set = 0, binding = 9, std430) buffer BTh { float th[]; };
layout(set = 0, binding = 10, std430) buffer BP { float p[]; };
layout(set = 0, binding = 11, std430) readonly buffer BThbd { float thbd[]; };
layout(set = 0, binding = 12, std430) buffer BThd { float thd[]; };

void main() {
	dims();
	bool init = pc.i0.w == 1;
	GRID_LOOP(N) {
		float tc = tcode[t];
		int c = cell_of(tc), tu = tu_of(tc), tv = tv_of(tc), tw = tw_of(tc);
		if (tu != 1 || init) u[t] = tu == 0 ? 0.0 : ubu[t];
		if (tv != 1 || init) v[t] = tv == 0 ? 0.0 : ubv[t];
		if (tw != 1 || init) w[t] = tw == 0 ? 0.0 : ubw[t];
		if (c != 1 || init) th[t] = c == 0 ? 0.0 : thb[t];
		if (c != 1 || init) thd[t] = c == 0 ? 0.0 : thbd[t];
		if (init) p[t] = 0.0;
	}
}
#endif

// ================================================================ местное K (Прандтль–Блэкадар + Смагоринский)
#ifdef K_KLOC
layout(set = 0, binding = 1, std430) readonly buffer BT { float tcode[]; };
layout(set = 0, binding = 2, std430) readonly buffer BLev { float lev[]; };
layout(set = 0, binding = 3, std430) readonly buffer BCol { float col[]; };
layout(set = 0, binding = 4, std430) readonly buffer BKb { float kbg[]; };
layout(set = 0, binding = 5, std430) readonly buffer BU { float u[]; };
layout(set = 0, binding = 6, std430) readonly buffer BV { float v[]; };
layout(set = 0, binding = 7, std430) readonly buffer BW { float w[]; };
layout(set = 0, binding = 8, std430) readonly buffer BTh { float th[]; };
layout(set = 0, binding = 9, std430) buffer BNu { float nu[]; };
layout(set = 0, binding = 10, std430) buffer BNuh { float nuh[]; };

float F(int a, int q) { return a == 0 ? u[q] : (a == 1 ? v[q] : w[q]); }

void main() {
	dims();
	int st[3] = int[3](1, NX, NYX);
	float h[3] = float[3](prm[P_DX], prm[P_DX], prm[P_DZ]);
	GRID_LOOP(N) {
		if (cell_of(tcode[t]) != 1) continue;
		int idx = t;
		int i = idx % NX, j = (idx / NX) % NY, k = idx / NYX;
		float c[3];
		for (int a = 0; a < 3; ++a) c[a] = 0.5 * (F(a, idx) + F(a, idx + st[a]));
		float g[3][3];
		for (int a = 0; a < 3; ++a) {
			for (int d = 0; d < 3; ++d) {
				if (a == d) { g[a][d] = (F(a, idx + st[a]) - F(a, idx)) / h[d]; continue; }
				int qm = idx - st[d], qp = idx + st[d];
				bool okm = cell_of(tcode[qm]) != 0, okp = cell_of(tcode[qp]) != 0;
				float cm = okm ? 0.5 * (F(a, qm) + F(a, qm + st[a])) : 0.0;
				float cpv = okp ? 0.5 * (F(a, qp) + F(a, qp + st[a])) : 0.0;
				if (okm && okp) g[a][d] = (cpv - cm) / (2.0 * h[d]);
				else if (okp) g[a][d] = (cpv - c[a]) / h[d];
				else if (okm) g[a][d] = (c[a] - cm) / h[d];
				else g[a][d] = 0.0;
			}
		}
		float S2 = 2.0 * (g[0][0] * g[0][0] + g[1][1] * g[1][1] + g[2][2] * g[2][2])
			+ (g[0][1] + g[1][0]) * (g[0][1] + g[1][0]) + (g[0][2] + g[2][0]) * (g[0][2] + g[2][0])
			+ (g[1][2] + g[2][1]) * (g[1][2] + g[2][1]);
		float dz = prm[P_DZ];
		bool dm = cell_of(tcode[idx - st[2]]) != 0, dp = cell_of(tcode[idx + st[2]]) != 0;
		float dth;
		if (dm && dp) dth = (th[idx + st[2]] - th[idx - st[2]]) / (2.0 * dz);
		else if (dp) dth = (th[idx + st[2]] - th[idx]) / dz;
		else if (dm) dth = (th[idx] - th[idx - st[2]]) / dz;
		else dth = 0.0;
		float N2 = GTH * (lev[L_GAM * NZ + k] + dth);
		float S = sqrt(S2);
		float Ri = N2 / (S2 > 1e-12 ? S2 : 1e-12);
		float Fr = Ri > 0.0 ? 1.0 / ((1.0 + 5.0 * Ri) * (1.0 + 5.0 * Ri)) : sqrt(1.0 - 16.0 * Ri);
		int q2 = j * NX + i;
		float z = prm[P_ZBOT] + (float(k) - 0.5) * dz - col[C_HP * NYX + q2];
		if (z < 0.5 * dz) z = 0.5 * dz;
		float l = 1.0 / (1.0 / (0.4 * z) + 1.0 / col[C_LAM * NYX + q2]);
		float K = l * l * S * Fr;
		float kb = kbg[idx];
		if (K < kb) K = kb;
		float relax = prm[P_RELAX];
		nu[idx] = nu[idx] + relax * (K - nu[idx]);
		float D2 = (g[0][0] - g[1][1]) * (g[0][0] - g[1][1]) + (g[0][1] + g[1][0]) * (g[0][1] + g[1][0]);
		float Kh = prm[P_CSDX2] * sqrt(D2);
		if (Kh < K) Kh = K;
		nuh[idx] = nuh[idx] + relax * (Kh - nuh[idx]);
	}
}
#endif

// ================================================================ шаблон импульса (i0.w: 0 u, 1 v, 2 w)
#ifdef K_MOM
layout(set = 0, binding = 1, std430) readonly buffer BT { float tcode[]; };
layout(set = 0, binding = 2, std430) readonly buffer BLev { float lev[]; };
layout(set = 0, binding = 3, std430) readonly buffer BU { float u[]; };
layout(set = 0, binding = 4, std430) readonly buffer BV { float v[]; };
layout(set = 0, binding = 5, std430) readonly buffer BW { float w[]; };
layout(set = 0, binding = 6, std430) readonly buffer BP { float p[]; };
layout(set = 0, binding = 7, std430) readonly buffer BTh { float th[]; };
layout(set = 0, binding = 8, std430) readonly buffer BSp { float sp[]; };
layout(set = 0, binding = 9, std430) readonly buffer BBg { float bg[]; };
layout(set = 0, binding = 10, std430) readonly buffer BNu { float nu[]; };
layout(set = 0, binding = 11, std430) readonly buffer BNuh { float nuh[]; };
layout(set = 0, binding = 12, std430) writeonly buffer BC { float C[]; };

float F(int a, int q) { return a == 0 ? u[q] : (a == 1 ? v[q] : w[q]); }
int TT(int comp, float tc) { return comp == 0 ? tu_of(tc) : (comp == 1 ? tv_of(tc) : tw_of(tc)); }
float KK(int d, int q) { return d == 2 ? nu[q] : nuh[q]; }

void main() {
	dims();
	int comp = pc.i0.w;
	int st[3] = int[3](1, NX, NYX);
	float hh[3] = float[3](prm[P_DX], prm[P_DX], prm[P_DZ]);
	float idt = prm[P_IDTU];
	GRID_LOOP(N) {
		int idx = t;
		int k = idx / NYX;
		float fi = F(comp, idx);
		if (TT(comp, tcode[idx]) != 1) {
			C[8 * idx] = 1.0;
			for (int o = 1; o < 7; ++o) C[8 * idx + o] = 0.0;
			C[8 * idx + 7] = fi;
			continue;
		}
		int sc = st[comp];
		int c0 = idx - sc, c1 = idx;
		float a3[3];
		a3[comp] = fi;
		for (int d = 0; d < 3; ++d) {
			if (d == comp) continue;
			a3[d] = 0.25 * (F(d, c0) + F(d, c0 + st[d]) + F(d, c1) + F(d, c1 + st[d]));
		}
		float diag = idt + sp[idx];
		float rhs = fi * idt + sp[idx] * bg[idx];
		float cc[7] = float[7](0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
		for (int d = 0; d < 3; ++d) {
			float ih = 1.0 / hh[d];
			float a = a3[d];
			for (int s = 0; s < 2; ++s) {
				int o = 1 + 2 * d + s;
				int q = idx + (s == 1 ? st[d] : -st[d]);
				float K;
				if (d == comp) K = KK(d, s == 1 ? c1 : c0);
				else {
					int sh = s == 1 ? st[d] : -st[d];
					K = 0.25 * (KK(d, c0) + KK(d, c1) + KK(d, c0 + sh) + KK(d, c1 + sh));
				}
				float vis = K * ih * ih;
				bool up = (s == 0 && a > 0.0) || (s == 1 && a < 0.0);
				float aa = a > 0.0 ? a : -a;
				if (TT(comp, tcode[q]) == 0) {
					if (d == comp) {
						diag += vis;
						if (up) diag += aa * ih;
					}
				} else {
					diag += vis;
					float cn = -vis;
					if (up) { diag += aa * ih; cn -= aa * ih; }
					cc[o] = cn;
				}
			}
		}
		rhs -= (p[c1] - p[c0]) / hh[comp];
		if (comp < 2) {
			if (TT(comp, tcode[idx - st[2]]) == 0) {
				float sp2 = a3[0] * a3[0] + a3[1] * a3[1];
				diag += prm[P_CD] * sqrt(sp2) / prm[P_DZ];
			}
		} else {
			rhs += GTH * 0.5 * (th[c0] + th[c1]);
			float cpl = lev[L_CPL * NZ + k];
			diag += cpl;
			rhs += cpl * w[idx];
		}
		C[8 * idx] = diag;
		for (int o = 1; o < 7; ++o) C[8 * idx + o] = cc[o];
		C[8 * idx + 7] = rhs;
	}
}
#endif

// ================================================================ шаблон тепла
// i0.w: 0 — θ′_d (диабатическая часть): L θ′_d = Q − θ′_d/τ − s_θ (θ′_d − θ_b,d);
//       1 — полное θ′: L θ′ = Q − θ′_d/τ − w dθ̄/dz − s_θ (θ′ − θ_b) (τ — явный источник от θ′_d).
// K_θ = K/Pr_t (prm[P_IPRT]) на всех осях.
#ifdef K_HEAT
layout(set = 0, binding = 1, std430) readonly buffer BT { float tcode[]; };
layout(set = 0, binding = 2, std430) readonly buffer BLev { float lev[]; };
layout(set = 0, binding = 3, std430) readonly buffer BU { float u[]; };
layout(set = 0, binding = 4, std430) readonly buffer BV { float v[]; };
layout(set = 0, binding = 5, std430) readonly buffer BW { float w[]; };
layout(set = 0, binding = 6, std430) readonly buffer BTh { float th[]; };
layout(set = 0, binding = 7, std430) readonly buffer BQ { float qsrc[]; };
layout(set = 0, binding = 8, std430) readonly buffer BSc { float spc[]; };
layout(set = 0, binding = 9, std430) readonly buffer BThb { float thb[]; };
layout(set = 0, binding = 10, std430) readonly buffer BNu { float nu[]; };
layout(set = 0, binding = 11, std430) readonly buffer BNuh { float nuh[]; };
layout(set = 0, binding = 12, std430) writeonly buffer BC { float C[]; };
layout(set = 0, binding = 13, std430) readonly buffer BThd { float thd[]; };
layout(set = 0, binding = 14, std430) readonly buffer BThbd { float thbd[]; };

void main() {
	dims();
	bool full = pc.i0.w == 1;
	int st[3] = int[3](1, NX, NYX);
	float hh[3] = float[3](prm[P_DX], prm[P_DX], prm[P_DZ]);
	float itau = prm[P_ITAU];
	GRID_LOOP(N) {
		int idx = t;
		int k = idx / NYX;
		float x = full ? th[idx] : thd[idx];
		if (cell_of(tcode[idx]) != 1) {
			C[8 * idx] = 1.0;
			for (int o = 1; o < 7; ++o) C[8 * idx + o] = 0.0;
			C[8 * idx + 7] = x;
			continue;
		}
		float fm[3] = float[3](u[idx], v[idx], w[idx]);
		float fp[3] = float[3](u[idx + 1], v[idx + NX], w[idx + NYX]);
		float diag = prm[P_IDTTH] + (full ? 0.0 : itau) + spc[idx];
		float rhs;
		if (full) {
			rhs = x * prm[P_IDTTH] + (qsrc[idx] - thd[idx] * itau) + spc[idx] * thb[idx]
				- lev[L_GAM * NZ + k] * 0.5 * (w[idx] + w[idx + NYX]);
		} else {
			rhs = x * prm[P_IDTTH] + qsrc[idx] + spc[idx] * thbd[idx];
		}
		float cc[7] = float[7](0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
		for (int d = 0; d < 3; ++d) {
			float ih = 1.0 / hh[d];
			for (int s = 0; s < 2; ++s) {
				float vo = s == 1 ? fp[d] : -fm[d];
				int q = idx + (s == 1 ? st[d] : -st[d]);
				float cn = 0.0;
				if (vo > 0.0) diag += vo * ih;
				else cn += vo * ih;
				if (cell_of(tcode[q]) != 0) {
					float kd = (d == 2 ? nu[idx] + nu[q] : nuh[idx] + nuh[q]) * prm[P_IPRT];
					float dif = 0.5 * kd * ih * ih;
					diag += dif;
					cn -= dif;
				}
				cc[1 + 2 * d + s] = cn;
			}
		}
		C[8 * idx] = diag;
		for (int o = 1; o < 7; ++o) C[8 * idx + o] = cc[o];
		C[8 * idx + 7] = rhs;
	}
}
#endif

// ================================================================ ∇·u в клетках воздуха (без ореола)
#ifdef K_DIV
layout(set = 0, binding = 1, std430) readonly buffer BT { float tcode[]; };
layout(set = 0, binding = 2, std430) readonly buffer BU { float u[]; };
layout(set = 0, binding = 3, std430) readonly buffer BV { float v[]; };
layout(set = 0, binding = 4, std430) readonly buffer BW { float w[]; };
layout(set = 0, binding = 5, std430) writeonly buffer BO { float o[]; };

void main() {
	dims();
	int nx = NX - 2, ny = NY - 2, nz = NZ - 2;
	float dx = prm[P_DX], dz = prm[P_DZ];
	GRID_LOOP(nx * ny * nz) {
		int i = t % nx, j = (t / nx) % ny, k = t / (nx * ny);
		int g = ((k + 1) * NY + j + 1) * NX + i + 1;
		float du = (u[g + 1] - u[g]) / dx;
		float dv = (v[g + NX] - v[g]) / dx;
		float dw = (w[g + NYX] - w[g]) / dz;
		o[t] = cell_of(tcode[g]) == 1 ? (du + dv) + dw : 0.0;
	}
}
#endif

// ================================================================ поправка SIMPLEC: u −= K·∇φ, p += φ (i0.w = 1)
#ifdef K_PROJ
layout(set = 0, binding = 1, std430) readonly buffer BKx { float kx[]; };
layout(set = 0, binding = 2, std430) readonly buffer BKy { float ky[]; };
layout(set = 0, binding = 3, std430) readonly buffer BKz { float kz[]; };
layout(set = 0, binding = 4, std430) readonly buffer BPhi { float phi[]; };
layout(set = 0, binding = 5, std430) buffer BU { float u[]; };
layout(set = 0, binding = 6, std430) buffer BV { float v[]; };
layout(set = 0, binding = 7, std430) buffer BW { float w[]; };
layout(set = 0, binding = 8, std430) buffer BP { float p[]; };

// φ с ореолом (0 вне внутренней области)
float P(int i, int j, int k) {
	if (i < 1 || j < 1 || k < 1 || i > NX - 2 || j > NY - 2 || k > NZ - 2) return 0.0;
	return phi[((k - 1) * (NY - 2) + j - 1) * (NX - 2) + i - 1];
}

void main() {
	dims();
	float dx = prm[P_DX], dz = prm[P_DZ];
	bool upd = pc.i0.w == 1;
	GRID_LOOP(N) {
		int i = t % NX, j = (t / NX) % NY, k = t / NYX;
		float pc0 = P(i, j, k);
		float a = kx[t], bq = ky[t], c = kz[t];
		if (a != 0.0) u[t] -= a * (pc0 - P(i - 1, j, k)) / dx;
		if (bq != 0.0) v[t] -= bq * (pc0 - P(i, j - 1, k)) / dx;
		if (c != 0.0) w[t] -= c * (pc0 - P(i, j, k - 1)) / dz;
		if (upd) p[t] += pc0;
	}
}
#endif

// ================================================================ невязка по неизвестным: r = (b − C·x)·[тип = 1]
// i0.w: 0 — грани u, 1 — v, 2 — w, 3 — клетки (тепло).
#ifdef K_RESID
layout(set = 0, binding = 1, std430) readonly buffer BT { float tcode[]; };
layout(set = 0, binding = 2, std430) readonly buffer BC { float c[]; };
layout(set = 0, binding = 3, std430) readonly buffer BX { float x[]; };
layout(set = 0, binding = 4, std430) writeonly buffer BR { float r[]; };

void main() {
	dims();
	int which = pc.i0.w;
	GRID_LOOP(N) {
		int idx = t;
		float tc = tcode[idx];
		int ty = which == 0 ? tu_of(tc) : (which == 1 ? tv_of(tc) : (which == 2 ? tw_of(tc) : cell_of(tc)));
		if (ty != 1) { r[idx] = 0.0; continue; }
		int i = idx % NX, j = (idx / NX) % NY, k = idx / NYX;
		int q = 8 * idx;
		float acc = c[q] * x[idx];
		acc += (i > 0 ? c[q + 1] * x[idx - 1] : 0.0) + (i < NX - 1 ? c[q + 2] * x[idx + 1] : 0.0);
		acc += (j > 0 ? c[q + 3] * x[idx - NX] : 0.0) + (j < NY - 1 ? c[q + 4] * x[idx + NX] : 0.0);
		acc += (k > 0 ? c[q + 5] * x[idx - NYX] : 0.0) + (k < NZ - 1 ? c[q + 6] * x[idx + NYX] : 0.0);
		r[idx] = c[q + 7] - acc;
	}
}
#endif
