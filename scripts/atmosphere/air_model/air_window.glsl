#[versions]

nest = "#define K_NEST";
flux = "#define K_FLUX";
corr = "#define K_CORR";
shift = "#define K_SHIFT";

#[compute]
#version 450

#VERSION_DEFINES

// Окно клипмапа (AM-04): граничные условия от родителя по эталону AM-01
// (tools/research/air3d/air.py → Air.set_nest_bc, reference.md → «Граничные условия области»).
// nest  — поле родителя в центрах его клеток (среднее двух граней, 0 в земле), трилинейно в грани
//         и клетки окна → ubu/ubv/ubw/thb/thbd (цель зоны релаксации и значения на граничных гранях;
//         θ′ и θ′_d — оба скаляра тепла, C7 v2);
// flux  — поток через граничные грани (тип 2) и их площадь по точкам → две редукции;
// corr  — поправка потока Σ = 0: грани типа 2 −= (поток/площадь)·s (s — внешняя нормаль);
// shift — тёплый старт сдвинутого окна: неизвестные — из старого окна той же клетки, где оно
//         есть (сдвиг на целое число клеток), остальное — уже записанный родитель; p — старое, у
//         края старого окна — ближайшее.
// Раскладка и типы — как air_picard.glsl (tcode = cell + 4·tu + 16·tv + 64·tw).

layout(local_size_x = 256) in;

layout(push_constant, std430) uniform PC {
	ivec4 i0;  // NX, NY, NZ окна, —
	ivec4 i1;  // NX, NY, NZ родителя / старого окна, слот скаляров
	vec4 f;
} pc;

layout(set = 0, binding = 0, std430) readonly buffer BPrm { float prm[]; };
const int P_DX = 0, P_DZ = 1;

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

// ================================================================ родитель → окно
#ifdef K_NEST
// nprm: 0..2 — (x0, y0, z_bot окна − родителя)/(dx, dx, dz родителя); 3 — dx/dx_p; 4 — dz/dz_p
layout(set = 0, binding = 1, std430) readonly buffer BN { float nprm[]; };
layout(set = 0, binding = 2, std430) readonly buffer BT { float tcode[]; };
layout(set = 0, binding = 3, std430) readonly buffer BPT { float ptc[]; };
layout(set = 0, binding = 4, std430) readonly buffer BPU { float pu[]; };
layout(set = 0, binding = 5, std430) readonly buffer BPV { float pv[]; };
layout(set = 0, binding = 6, std430) readonly buffer BPW { float pw[]; };
layout(set = 0, binding = 7, std430) readonly buffer BPTh { float pth[]; };
layout(set = 0, binding = 8, std430) writeonly buffer BUb { float ubu[]; };
layout(set = 0, binding = 9, std430) writeonly buffer BVb { float ubv[]; };
layout(set = 0, binding = 10, std430) writeonly buffer BWb { float ubw[]; };
layout(set = 0, binding = 11, std430) writeonly buffer BThb { float thb[]; };
layout(set = 0, binding = 12, std430) readonly buffer BPThd { float pthd[]; };
layout(set = 0, binding = 13, std430) writeonly buffer BThbd { float thbd[]; };

int PNX, PNY, PNZ;

// Центр клетки родителя (с ореолом) — как Air.centers(full=True): среднее двух граней по своей
// оси (последняя клетка по оси — 0), клетки земли — 0.
float pcen(int comp, int k, int j, int i) {
	int q = (k * PNY + j) * PNX + i;
	if (cell_of(ptc[q]) == 0) return 0.0;
	if (comp == 0) return i < PNX - 1 ? 0.5 * (pu[q] + pu[q + 1]) : 0.0;
	if (comp == 1) return j < PNY - 1 ? 0.5 * (pv[q] + pv[q + PNX]) : 0.0;
	if (comp == 2) return k < PNZ - 1 ? 0.5 * (pw[q] + pw[q + PNX * PNY]) : 0.0;
	if (comp == 4) return pthd[q];
	return pth[q];
}

// Трилинейно по центрам родителя; (fi, fj, fk) — индексы с ореолом (air.trilinear).
float tri(int comp, float fk, float fj, float fi) {
	fk = clamp(fk, 0.0, float(PNZ) - 1.0001);
	fj = clamp(fj, 0.0, float(PNY) - 1.0001);
	fi = clamp(fi, 0.0, float(PNX) - 1.0001);
	int k0 = int(fk), j0 = int(fj), i0 = int(fi);
	float a = fi - float(i0), b = fj - float(j0), c = fk - float(k0);
	float s = 0.0;
	for (int dk = 0; dk < 2; ++dk) {
		for (int dj = 0; dj < 2; ++dj) {
			for (int di = 0; di < 2; ++di) {
				float wgt = (dk == 1 ? c : 1.0 - c) * (dj == 1 ? b : 1.0 - b) * (di == 1 ? a : 1.0 - a);
				s += wgt * pcen(comp, k0 + dk, j0 + dj, i0 + di);
			}
		}
	}
	return s;
}

void main() {
	dims();
	PNX = pc.i1.x;
	PNY = pc.i1.y;
	PNZ = pc.i1.z;
	float ox = nprm[0], oy = nprm[1], oz = nprm[2], rx = nprm[3], rz = nprm[4];
	GRID_LOOP(N) {
		int i = t % NX, j = (t / NX) % NY, k = t / NYX;
		float tc = tcode[t];
		// индекс родителя с ореолом: (X − x0_p)/dx_p + ½; центр окна X = x0 + (i − ½)dx, грань — (i − 1)dx
		float fic = ox + (float(i) - 0.5) * rx + 0.5, fif = ox + (float(i) - 1.0) * rx + 0.5;
		float fjc = oy + (float(j) - 0.5) * rx + 0.5, fjf = oy + (float(j) - 1.0) * rx + 0.5;
		float fkc = oz + (float(k) - 0.5) * rz + 0.5, fkf = oz + (float(k) - 1.0) * rz + 0.5;
		ubu[t] = tu_of(tc) == 0 ? 0.0 : tri(0, fkc, fjc, fif);
		ubv[t] = tv_of(tc) == 0 ? 0.0 : tri(1, fkc, fjf, fic);
		ubw[t] = tw_of(tc) == 0 ? 0.0 : tri(2, fkf, fjc, fic);
		thb[t] = cell_of(tc) == 0 ? 0.0 : tri(3, fkc, fjc, fic);
		thbd[t] = cell_of(tc) == 0 ? 0.0 : tri(4, fkc, fjc, fic);
	}
}
#endif

// ================================================================ поток через границу окна
#ifdef K_FLUX
layout(set = 0, binding = 1, std430) readonly buffer BT { float tcode[]; };
layout(set = 0, binding = 2, std430) readonly buffer BUb { float ubu[]; };
layout(set = 0, binding = 3, std430) readonly buffer BVb { float ubv[]; };
layout(set = 0, binding = 4, std430) readonly buffer BWb { float ubw[]; };
layout(set = 0, binding = 5, std430) writeonly buffer BF { float fl[]; };
layout(set = 0, binding = 6, std430) writeonly buffer BA { float ar[]; };

void main() {
	dims();
	float a_side = prm[P_DX] * prm[P_DZ], a_top = prm[P_DX] * prm[P_DX];
	GRID_LOOP(N) {
		float tc = tcode[t];
		float s = cell_of(tc) == 1 ? -1.0 : 1.0;
		float f = 0.0, a = 0.0;
		if (tu_of(tc) == 2) { f += s * ubu[t] * a_side; a += a_side; }
		if (tv_of(tc) == 2) { f += s * ubv[t] * a_side; a += a_side; }
		if (tw_of(tc) == 2) { f += s * ubw[t] * a_top; a += a_top; }
		fl[t] = f;
		ar[t] = a;
	}
}
#endif

// ================================================================ поправка потока Σ = 0
#ifdef K_CORR
layout(set = 0, binding = 1, std430) readonly buffer BT { float tcode[]; };
layout(set = 0, binding = 2, std430) readonly buffer BS { float sc[]; };
layout(set = 0, binding = 3, std430) buffer BUb { float ubu[]; };
layout(set = 0, binding = 4, std430) buffer BVb { float ubv[]; };
layout(set = 0, binding = 5, std430) buffer BWb { float ubw[]; };

void main() {
	dims();
	int slot = pc.i1.w;
	float area = sc[slot + 1];
	float corr = area > 0.0 ? sc[slot] / area : 0.0;
	GRID_LOOP(N) {
		float tc = tcode[t];
		float s = cell_of(tc) == 1 ? -1.0 : 1.0;
		if (tu_of(tc) == 2) ubu[t] -= corr * s;
		if (tv_of(tc) == 2) ubv[t] -= corr * s;
		if (tw_of(tc) == 2) ubw[t] -= corr * s;
	}
}
#endif

// ================================================================ тёплый старт сдвинутого окна
#ifdef K_SHIFT
// sprm: 0..2 — сдвиг индекса старого окна (i, j, k: старый = новый + сдвиг)
layout(set = 0, binding = 1, std430) readonly buffer BN { float sprm[]; };
layout(set = 0, binding = 2, std430) readonly buffer BT { float tcode[]; };
layout(set = 0, binding = 3, std430) readonly buffer BOU { float ou[]; };
layout(set = 0, binding = 4, std430) readonly buffer BOV { float ov[]; };
layout(set = 0, binding = 5, std430) readonly buffer BOW { float ow[]; };
layout(set = 0, binding = 6, std430) readonly buffer BOTh { float oth[]; };
layout(set = 0, binding = 7, std430) readonly buffer BOP { float op[]; };
layout(set = 0, binding = 8, std430) buffer BU { float u[]; };
layout(set = 0, binding = 9, std430) buffer BV { float v[]; };
layout(set = 0, binding = 10, std430) buffer BW { float w[]; };
layout(set = 0, binding = 11, std430) buffer BTh { float th[]; };
layout(set = 0, binding = 12, std430) buffer BP { float p[]; };
layout(set = 0, binding = 13, std430) readonly buffer BOThd { float othd[]; };
layout(set = 0, binding = 14, std430) buffer BThd { float thd[]; };

void main() {
	dims();
	int ONX = pc.i1.x, ONY = pc.i1.y, ONZ = pc.i1.z;
	int si = int(sprm[0]), sj = int(sprm[1]), sk = int(sprm[2]);
	GRID_LOOP(N) {
		int i = t % NX, j = (t / NX) % NY, k = t / NYX;
		float tc = tcode[t];
		int io = i + si, jo = j + sj, ko = k + sk;
		// в старом окне (без нулевых индексов: грань 0 и ореол 0 — не решение)
		bool inside = io >= 1 && jo >= 1 && ko >= 1 && io <= ONX - 1 && jo <= ONY - 1 && ko <= ONZ - 1;
		int q = (ko * ONY + jo) * ONX + io;
		if (inside) {
			if (tu_of(tc) == 1) u[t] = ou[q];
			if (tv_of(tc) == 1) v[t] = ov[q];
			if (tw_of(tc) == 1) w[t] = ow[q];
			if (cell_of(tc) == 1) th[t] = oth[q];
			if (cell_of(tc) == 1) thd[t] = othd[q];
		}
		if (cell_of(tc) == 1) {
			int ic = clamp(io, 1, ONX - 2), jc = clamp(jo, 1, ONY - 2), kc = clamp(ko, 1, ONZ - 2);
			p[t] = op[(kc * ONY + jc) * ONX + ic];
		}
	}
}
#endif
