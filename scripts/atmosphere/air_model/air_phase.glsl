#[versions]

classify = "#define K_CLASSIFY";
smoothx = "#define K_SMOOTHX";
smoothy = "#define K_SMOOTHY";
final = "#define K_FINAL";
synth0 = "#define K_SYNTH0";
synth1 = "#define K_SYNTH1";
synth2 = "#define K_SYNTH2";
sorinit = "#define K_SORINIT";
sor = "#define K_SOR";
dgrad = "#define K_DGRAD";
uml = "#define K_UML";
thinit = "#define K_THINIT";
theta = "#define K_THETA";
fill = "#define K_FILL";
faces = "#define K_FACES";

#[compute]
#version 450

#VERSION_DEFINES

// Фазы поля масштаба 1 (P10, docs/contracts/air-phase.md; docs/guide/air-model.md → «Фазы»).
// То же построчно — AirPhaseCpu (float64); подготовка по столбцам — AirPhase.prepare (CPU).
// Спецификация — tools/research/air_phase/analysis/AP-18/section.md, hybrid/drainage.py, assembly/
// mechanisms.py (AP-17). Числа модели — только из prm (configs/atmosphere.json → air_phase),
// литералов-констант модели в ядре нет.
// 2D-сетка n² = nx·ny, индекс j·nx + i (j — север); поле с ореолом (NZ, NY, NX), индекс
// (k·NY + j)·NX + i, центр клетки z = z_bot + (k − ½)dz; грани MAC: u — западная, v — южная, w — нижняя.

layout(local_size_x = 256) in;

layout(push_constant, std430) uniform PC {
	ivec4 i0;  // nx, ny, nz (без ореола), вариант / режим
	ivec4 i1;  // параметр ядра (чётность, плоскость)
	vec4 f;
} pc;

layout(set = 0, binding = 0, std430) buffer BPrm { float prm[]; };
layout(set = 0, binding = 1, std430) buffer BCol { float col[]; };
layout(set = 0, binding = 2, std430) buffer BMod { float md[]; };
layout(set = 0, binding = 3, std430) buffer BWts { float wts[]; };
layout(set = 0, binding = 4, std430) buffer BSlab { float slab[]; };
layout(set = 0, binding = 5, std430) buffer BTmp { float stmp[]; };
layout(set = 0, binding = 6, std430) buffer BPhi { float phi[]; };
layout(set = 0, binding = 7, std430) buffer BO2 { float o2d[]; };
layout(set = 0, binding = 8, std430) buffer BCtr { float ctr[]; };
layout(set = 0, binding = 9, std430) buffer BOut { float outv[]; };

// слоты prm — AirPhase.P_*
const int P_DX = 0, P_DZ = 1, P_ZBOT = 2, P_EX = 3, P_EY = 4, P_USAT = 5, P_ZSAT = 6, P_ALPHA = 7;
const int P_Z0 = 8, P_FR = 9, P_NEFF = 10, P_HCD = 11, P_NL = 12, P_USTAR = 13, P_HEATED = 14;
const int P_ZI = 15, P_GAMW = 16, P_GACT = 17, P_GDTHC = 18, P_TAU = 19;
const int P_WH = 20, P_WDS = 21, P_WD = 22, P_FULL = 23, P_D_LOCAL = 24, P_D_RAMP = 25;
const int P_C_WMS = 26, P_LEE_DEPTH = 27, P_LEE_HLO = 28, P_LEE_HHI = 29, P_LEE_STEEP = 30;
const int P_LEE_HSK = 31, P_ZIL_C = 32, P_W_EF = 33, P_FR_INF = 34;
const int P_C_WDEC = 35, P_FRZ_W = 37, P_WS_OVER_U = 38;
const int P_CAP = 39, P_BUB_R = 40, P_SLOPE_LEN = 41, P_ANA_DMIN = 42, P_ANA_DFRAC = 43;
const int P_UML_N = 44, P_UML_MIN = 45, P_SOR_OMEGA = 46, P_G_TOPL = 47, P_G_MEMB = 48;
const int P_GRAV = 49, P_THETA0 = 50, P_KAPPA = 51, P_UREF_MIN = 52, P_GK_R = 53, P_GK0 = 54;
const int GK_MAX = 17;
const int P_LEV0 = P_GK0 + GK_MAX;
const int LEV_MAX = 16;
const int P_NLEV = P_LEV0 + LEV_MAX;
const int P_ZL0 = P_NLEV + 1;
// плоскости col — AirPhase.CI_*
const int CI_HC = 0, CI_HEFF = 1, CI_T = 2, CI_S = 3, CI_GX = 4, CI_GY = 5, CI_HEAT = 6, CI_HK = 7;
const int CI_HBL = 8, CI_WST = 9, CI_GL = 10, CI_GDTH = 11, CI_GUS = 12, CI_GON = 13, CI_GLAY = 14;
const int CI_GD = 15, CI_GUC = 16, CI_GDX = 17, CI_GDY = 18, CI_GW = 19, CI_SAL = 20;
const int MO_AMP = 0, MO_ELL = 1, MO_S0 = 2;
const int K = 7, PH_A = 0, PH_B = 1, PH_C = 2, PH_D = 3, PH_F = 4, PH_G = 5, PH_H = 6;
const int NWS = 4, WS_RAW = 0, WS_TMP = 1, WS_FIN = 3;
const int O_UML = 0, O_TH0 = 1, O_FRZ_M = 3, O_FRZ_H = 4, O_FLAG = 5;
const int V_M = 0, V_H = 1;
const int NCOMP = 4;

int nx, ny, nz, n2, NX, NY, NZ, N, NLEV;
float PI;

void dims() {
	nx = pc.i0.x;
	ny = pc.i0.y;
	nz = pc.i0.z;
	n2 = nx * ny;
	NX = nx + 2;
	NY = ny + 2;
	NZ = nz + 2;
	N = NX * NY * NZ;
	NLEV = int(prm[P_NLEV]);
	PI = acos(-1.0);
}

#define GRID_LOOP(total) \
	int _stride = int(gl_NumWorkGroups.x * gl_NumWorkGroups.y * 256u); \
	int _g = int((gl_WorkGroupID.y * gl_NumWorkGroups.x + gl_WorkGroupID.x) * 256u + gl_LocalInvocationID.x); \
	for (int t = _g; t < (total); t += _stride)

float C(int plane, int c) { return col[plane * n2 + c]; }

// σ((lg x − lg x_c)/w) — граница фазы (AirPhase.sig_log)
float sig_log(float x, float xc, float w) {
	float lx = log(max(x, 1e-12)) / log(float(10));
	return 1.0 / (1.0 + exp(-(lx - log(xc) / log(float(10))) / w));
}

float band(float x, float lo, float hi, float w) { return sig_log(x, lo, w) * (1.0 - sig_log(x, hi, w)); }

float smooth01(float e0, float e1, float x) {
	float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
	return t * t * (float(3) - 2.0 * t);
}

// профиль притока решателя U(z) = U_sat·min((z/z_sat)^α, 1)
float u_prof(float z) {
	if (prm[P_USAT] <= 0.0) return 0.0;
	return prm[P_USAT] * min(pow(max(z, prm[P_Z0]) / prm[P_ZSAT], prm[P_ALPHA]), 1.0);
}

// cos/sin(π·p·(i + ½)/n) с приведением p(2i + 1) по модулю 4n
float cosb(int n, int i, int p) { return cos(PI * float((p * (2 * i + 1)) % (4 * n)) / float(2 * n)); }
float sinb(int n, int i, int p) { return sin(PI * float((p * (2 * i + 1)) % (4 * n)) / float(2 * n)); }

// отражение через полуклетку (scipy «reflect»); % от отрицательного в GLSL не определён — без него
int refl(int i, int n) {
	int m = i < 0 ? -1 - i : i;
	return m < n ? m : 2 * n - 1 - m;
}

int widx(int v, int st, int k, int c) { return ((v * NWS + st) * K + k) * n2 + c; }

// ---------------------------------------------------------------- поле механизмов в точке

// слой A на высоте zt над T: δu, δv (с ограничением cap·U), δw, η (AirPhaseCpu.slab_at)
vec4 slab_at(int c, float zt) {
	float l0 = prm[P_LEV0];
	float zc = clamp(zt, l0, prm[P_LEV0 + NLEV - 1]);
	int k = 0;
	while (k < NLEV - 2 && prm[P_LEV0 + k + 1] <= zc) k++;
	float t = (zc - prm[P_LEV0 + k]) / (prm[P_LEV0 + k + 1] - prm[P_LEV0 + k]);
	vec4 r = vec4(0.0);
	for (int side = 0; side < 2; side++) {
		int l = k + side;
		float wt = side == 1 ? t : 1.0 - t;
		float du = slab[(l * NCOMP) * n2 + c];
		float dv = slab[(l * NCOMP + 1) * n2 + c];
		float mag = sqrt(du * du + dv * dv);
		float lim = prm[P_CAP] * u_prof(prm[P_LEV0 + l]);
		float fac = mag > lim ? lim / max(mag, 1e-9) : 1.0;
		r.x += wt * du * fac;
		r.y += wt * dv * fac;
		r.z += wt * slab[(l * NCOMP + 2) * n2 + c];
		r.w += wt * slab[(l * NCOMP + 3) * n2 + c];
	}
	if (zt < l0) {
		float z0 = prm[P_Z0];
		float fh = log(max(zt, 2.0 * z0) / z0) / log(l0 / z0);
		float fw = clamp(zt / l0, 0.0, 1.0);
		r *= vec4(fh, fh, fw, fw);
	}
	return r;
}

struct Mech {
	vec3 a;
	float eta;
	vec3 b;
	vec3 d;
};

// A (обтекание T), B (пузырь под огибающей), D (слои Лапласа под H_c) — AirPhaseCpu.mech
Mech mech(int c, float zmsl) {
	float hc = C(CI_HC, c);
	float zagl = zmsl - hc;
	float zt = zmsl - C(CI_T, c);
	float ex = prm[P_EX], ey = prm[P_EY];
	vec4 s = slab_at(c, zt);
	float ub = u_prof(zt);
	Mech m;
	m.a = vec3(ub * ex + s.x, ub * ey + s.y, s.z);
	m.eta = s.w;
	m.b = m.a;
	float depth = C(CI_HEFF, c) - hc;
	if (depth > 0.0 && zagl < depth) {
		vec4 s0 = slab_at(c, prm[P_LEV0]);
		float u0 = u_prof(prm[P_LEV0]);
		float utop = length(vec2(u0 * ex + s0.x, u0 * ey + s0.y));
		float tt = clamp(zagl / depth, 0.0, 1.0);
		float rv = prm[P_BUB_R];
		float ubub = utop * (-rv + (1.0 + rv) * tt * tt);
		m.b = vec3(ubub * ex, ubub * ey, 0.0);
	}
	m.d = m.a;
	int nl = int(prm[P_NL]);
	if (nl > 0 && zmsl < prm[P_HCD]) {
		int q = -1;
		for (int l = 0; l < nl; l++)
			if (prm[P_ZL0 + l] < zmsl) q = l;
		q = clamp(q, 0, nl - 1);
		int q2 = min(q + 1, nl - 1);
		float den = max(prm[P_ZL0 + q2] - prm[P_ZL0 + q], 1e-6);
		float tq = clamp((zmsl - prm[P_ZL0 + q]) / den, 0.0, 1.0);
		float gx = (1.0 - tq) * phi[(q * 3 + 1) * n2 + c] + tq * phi[(q2 * 3 + 1) * n2 + c];
		float gy = (1.0 - tq) * phi[(q * 3 + 2) * n2 + c] + tq * phi[(q2 * 3 + 2) * n2 + c];
		float ua = u_prof(zagl);
		m.d = vec3(gx * ua, gy * ua, 0.0);
	}
	return m;
}

// нормированная смесь по весам: A, C → A; D, H → D; B → B (F, G — отдельно)
vec3 mixw(int v, int c, Mech m) {
	float wa = wts[widx(v, WS_FIN, PH_A, c)] + wts[widx(v, WS_FIN, PH_C, c)];
	float wd = wts[widx(v, WS_FIN, PH_D, c)] + wts[widx(v, WS_FIN, PH_H, c)];
	float wb = wts[widx(v, WS_FIN, PH_B, c)];
	float sm = max(wa + wb + wd, 1e-12);
	return (wa * m.a + wb * m.b + wd * m.d) / sm;
}

void main() {
	dims();
	int v = pc.i0.w;

#ifdef K_CLASSIFY
	// сырые веса P15 (classifier_ref.classify; AirPhaseCpu.classify): H, D (ниже H_c по клеткам), C (волны
	// по U_sat·|e·∇h_s|), A — остальное; B — огибающая срыва; F — по −z_i/L; G — сток
	bool heated = v == V_H && prm[P_HEATED] > 0.0;
	bool gact = v == V_H && prm[P_GACT] > 0.0;
	float ust = prm[P_USTAR];
	GRID_LOOP(n2) {
		int c = t;
		float hc = C(CI_HC, c);
		float wh = prm[P_WH];
		float wd = prm[P_WD];
		if (prm[P_D_LOCAL] > 0.0) wd *= smooth01(0.0, prm[P_D_RAMP], prm[P_HCD] - hc);
		float wc = 0.0;
		if (prm[P_C_WMS] > 0.0) {
			float x = max(prm[P_USAT] * C(CI_SAL, c), 1e-6);
			wc = (1.0 - wh) * (1.0 - wd) * sig_log(x, prm[P_C_WMS], prm[P_C_WDEC]);
		}
		float wa = max(1.0 - wh - wd - wc, 0.0);
		float sl = smooth01(0.0, prm[P_LEE_DEPTH], C(CI_HEFF, c) - hc);
		float heat = C(CI_HEAT, c);
		if (heated) {
			float steep = C(CI_S, c) < prm[P_LEE_STEEP] ? 1.0 : prm[P_LEE_HSK];
			sl *= 1.0 - smooth01(prm[P_LEE_HLO], prm[P_LEE_HHI], heat) * steep;
		}
		float wb = sl;
		wa *= 1.0 - sl;
		wc *= 1.0 - sl;
		wd *= 1.0 - sl;
		wh *= 1.0 - sl;
		float wf = 0.0;
		if (heated) {
			float hk = C(CI_HK, c);
			if (ust > 0.0) {
				float zil = C(CI_HBL, c) * prm[P_KAPPA] * prm[P_GRAV] * max(hk, 0.0)
						/ (prm[P_THETA0] * ust * ust * ust);
				wf = hk > 0.0 ? sig_log(max(zil, 1e-6), prm[P_ZIL_C], prm[P_W_EF]) : 0.0;
			} else {
				wf = heat > 0.0 ? 1.0 : 0.0;
			}
		}
		float wg = gact ? C(CI_GW, c) : 0.0;
		float r = (1.0 - wf) * (1.0 - wg);
		wts[widx(v, WS_RAW, PH_A, c)] = wa * r;
		wts[widx(v, WS_RAW, PH_B, c)] = wb * r;
		wts[widx(v, WS_RAW, PH_C, c)] = wc * r;
		wts[widx(v, WS_RAW, PH_D, c)] = wd * r;
		wts[widx(v, WS_RAW, PH_F, c)] = wf * (1.0 - wg);
		wts[widx(v, WS_RAW, PH_G, c)] = wg;
		wts[widx(v, WS_RAW, PH_H, c)] = wh * r;
	}
#endif

#ifdef K_SMOOTHX
	int r = int(prm[P_GK_R]);
	GRID_LOOP(K * n2) {
		int k = t / n2;
		int c = t % n2;
		int j = c / nx, i = c % nx;
		float s = 0.0;
		for (int q = -r; q <= r; q++)
			s += prm[P_GK0 + q + r] * wts[widx(v, WS_RAW, k, j * nx + refl(i + q, nx))];
		wts[widx(v, WS_TMP, k, c)] = s;
	}
#endif

#ifdef K_SMOOTHY
	int r = int(prm[P_GK_R]);
	GRID_LOOP(n2) {
		int c = t;
		int j = c / nx, i = c % nx;
		float tot = 0.0;
		float s[K];
		for (int k = 0; k < K; k++) {
			float a = 0.0;
			for (int q = -r; q <= r; q++)
				a += prm[P_GK0 + q + r] * wts[widx(v, WS_TMP, k, refl(j + q, ny) * nx + i)];
			s[k] = max(a, 0.0);
			tot += s[k];
		}
		for (int k = 0; k < K; k++) wts[widx(v, WS_FIN, k, c)] = s[k] / max(tot, 1e-12);
	}
#endif

#ifdef K_FINAL
	// маска заморозки по итоговым весам: вся область — H + сильное D ≥ freeze_w; вариант h — F ≥ freeze_w
	// при w* ≥ k·U_sat и G ≥ freeze_w (AirPhaseCpu.finalize)
	float fw = prm[P_FRZ_W];
	bool full = prm[P_FULL] > 0.0;
	GRID_LOOP(n2) {
		int c = t;
		bool f = full;
		if (v == V_H) {
			bool ff = wts[widx(v, WS_FIN, PH_F, c)] >= fw && C(CI_WST, c) >= prm[P_WS_OVER_U] * prm[P_USAT];
			f = f || ff || wts[widx(v, WS_FIN, PH_G, c)] >= fw;
		}
		o2d[(v == V_H ? O_FRZ_H : O_FRZ_M) * n2 + c] = f ? 1.0 : 0.0;
	}
#endif

#ifdef K_SYNTH0
	// моды → X = (Re Tee, Im Toe, Im Teo, Re Too)·amp по δu, δv, δw, η [JH75, Sm80] (AirPhaseCpu.mode_terms)
	GRID_LOOP(NLEV * n2) {
		int l = t / n2;
		int c = t % n2;
		float z = prm[P_LEV0 + l];
		float x[16];
		for (int q = 0; q < 16; q++) x[q] = 0.0;
		if (c != 0) {
			float amp = md[MO_AMP * n2 + c];
			float ell = md[MO_ELL * n2 + c];
			int pp = c % nx, qq = c / nx;
			float kx0 = PI * float(pp) / (float(nx) * prm[P_DX]);
			float ky0 = PI * float(qq) / (float(ny) * prm[P_DX]);
			float k2 = kx0 * kx0 + ky0 * ky0;
			float zeff = max(z, ell);
			float inner = 1.0;
			if (z < ell) inner = min(u_prof(z) / max(u_prof(ell), 1e-6), 1.0);
			for (int s = 0; s < 4; s++) {
				int sx = (s == 1 || s == 3) ? -1 : 1;
				int sy = (s >= 2) ? -1 : 1;
				float sr = md[(MO_S0 + 3 * s) * n2 + c];
				float mr = md[(MO_S0 + 3 * s + 1) * n2 + c];
				float mi = md[(MO_S0 + 3 * s + 2) * n2 + c];
				float kx = float(sx) * kx0, ly = float(sy) * ky0;
				float ea = exp(-mi * zeff);
				float ezr = ea * cos(mr * zeff), ezi = ea * sin(mr * zeff);
				float wr = -sr * ezi, wi = sr * ezr;
				float mwr = mr * wr - mi * wi, mwi = mr * wi + mi * wr;
				float f = inner / k2;
				float eb = exp(-mi * z);
				float e2r = eb * cos(mr * z), e2i = eb * sin(mr * z);
				float vals[8] = float[8](-kx * mwr * f, -kx * mwi * f, -ly * mwr * f, -ly * mwi * f, -sr * e2i, sr * e2r, e2r, e2i);
				for (int comp = 0; comp < 4; comp++) {
					float re = vals[2 * comp], im = vals[2 * comp + 1];
					x[comp * 4] += re * amp / float(4);
					x[comp * 4 + 1] += float(sx) * im * amp / float(4);
					x[comp * 4 + 2] += float(sy) * im * amp / float(4);
					x[comp * 4 + 3] += float(sx * sy) * re * amp / float(4);
				}
			}
		}
		for (int q = 0; q < 16; q++) stmp[(l * 16 + q) * n2 + c] = x[q];
	}
#endif

#ifdef K_SYNTH1
	// по строкам: P = X1·Cxᵀ − X2·Sxᵀ, Q = X3·Cxᵀ + X4·Sxᵀ
	int xo = NLEV * 16 * n2;
	GRID_LOOP(NLEV * NCOMP * n2) {
		int lc = t / n2;
		int c = t % n2;
		int q = c / nx, i = c % nx;
		int x1 = lc * 4 * n2;
		float sp = 0.0, sq = 0.0;
		for (int k = 0; k < nx; k++) {
			float cc = cosb(nx, i, k), ss = sinb(nx, i, k);
			int o = q * nx + k;
			sp += stmp[x1 + o] * cc - stmp[x1 + n2 + o] * ss;
			sq += stmp[x1 + 2 * n2 + o] * cc + stmp[x1 + 3 * n2 + o] * ss;
		}
		stmp[xo + (lc * 2) * n2 + c] = sp;
		stmp[xo + (lc * 2 + 1) * n2 + c] = sq;
	}
#endif

#ifdef K_SYNTH2
	// по столбцам: δ = Cy·P − Sy·Q
	int xo = NLEV * 16 * n2;
	GRID_LOOP(NLEV * NCOMP * n2) {
		int lc = t / n2;
		int c = t % n2;
		int j = c / nx, i = c % nx;
		float s = 0.0;
		for (int q = 0; q < ny; q++)
			s += cosb(ny, j, q) * stmp[xo + (lc * 2) * n2 + q * nx + i] - sinb(ny, j, q) * stmp[xo + (lc * 2 + 1) * n2 + q * nx + i];
		slab[lc * n2 + c] = s;
	}
#endif

#ifdef K_SORINIT
	// φ = e·x (в единицах dx) — набегающий поток
	int nl = int(prm[P_NL]);
	GRID_LOOP(nl * n2) {
		int l = t / n2;
		int c = t % n2;
		phi[l * 3 * n2 + c] = prm[P_EX] * (float(c % nx) + 0.5) + prm[P_EY] * (float(c / nx) + 0.5);
	}
#endif

#ifdef K_SOR
	// красно-чёрная верхняя релаксация ∇²φ = 0 в воздухе слоя, ∂φ/∂n = 0 у стенок (AirPhaseCpu.laplace)
	int nl = int(prm[P_NL]);
	int par = pc.i1.x;
	float om = prm[P_SOR_OMEGA];
	GRID_LOOP(nl * n2) {
		int l = t / n2;
		int c = t % n2;
		int j = c / nx, i = c % nx;
		if (i < 1 || i > nx - 2 || j < 1 || j > ny - 2 || (i + j) % 2 != par) continue;
		float zl = prm[P_ZL0 + l];
		if (C(CI_HC, c) > zl) continue;
		int o = l * 3 * n2;
		float s = 0.0;
		int cnt = 0;
		int nb[4] = int[4](c - 1, c + 1, c - nx, c + nx);
		for (int q = 0; q < 4; q++) {
			if (C(CI_HC, nb[q]) <= zl) {
				s += phi[o + nb[q]];
				cnt++;
			}
		}
		if (cnt > 0) phi[o + c] = (1.0 - om) * phi[o + c] + om * s / float(cnt);
	}
#endif

#ifdef K_DGRAD
	int nl = int(prm[P_NL]);
	float ex = prm[P_EX], ey = prm[P_EY];
	GRID_LOOP(nl * n2) {
		int l = t / n2;
		int c = t % n2;
		int j = c / nx, i = c % nx;
		float zl = prm[P_ZL0 + l];
		int o = l * 3 * n2;
		vec2 g = vec2(0.0);
		if (C(CI_HC, c) <= zl) {
			float fxl = i == 0 ? ex : (C(CI_HC, c - 1) <= zl ? phi[o + c] - phi[o + c - 1] : 0.0);
			float fxr = i == nx - 1 ? ex : (C(CI_HC, c + 1) <= zl ? phi[o + c + 1] - phi[o + c] : 0.0);
			float fyl = j == 0 ? ey : (C(CI_HC, c - nx) <= zl ? phi[o + c] - phi[o + c - nx] : 0.0);
			float fyr = j == ny - 1 ? ey : (C(CI_HC, c + nx) <= zl ? phi[o + c + nx] - phi[o + c] : 0.0);
			g = 0.5 * vec2(fxl + fxr, fyl + fyr);
		}
		phi[o + n2 + c] = g.x;
		phi[o + 2 * n2 + c] = g.y;
	}
#endif

#ifdef K_UML
	int nu = int(prm[P_UML_N]);
	GRID_LOOP(n2) {
		int c = t;
		float s = 0.0;
		for (int l = 0; l < nu; l++) {
			Mech m = mech(c, C(CI_HC, c) + prm[P_LEV0 + l]);
			vec3 u = mixw(V_H, c, m);
			s += length(u.xy);
		}
		o2d[O_UML * n2 + c] = max(s / float(max(nu, 1)), prm[P_UML_MIN]);
	}
#endif

#ifdef K_THINIT
	// θ′ баланса: источник H_k/h·τ·(1 − e^{−Δt/τ}), Δt = dx/U
	GRID_LOOP(n2) {
		int c = t;
		float fa = exp(-prm[P_DX] / o2d[O_UML * n2 + c] / prm[P_TAU]);
		o2d[O_TH0 * n2 + c] = C(CI_HK, c) / max(C(CI_HBL, c), 1.0) * prm[P_TAU] * (1.0 - fa);
	}
#endif

#ifdef K_THETA
	// проход Якоби θ′(p) = θ′(p − e·dx)·e^{−Δt/τ} + источник (AP-17 theta_march)
	int src = O_TH0 + pc.i1.x;
	int dst = O_TH0 + 1 - pc.i1.x;
	float ex = prm[P_EX], ey = prm[P_EY];
	GRID_LOOP(n2) {
		int c = t;
		int j = c / nx, i = c % nx;
		float fa = exp(-prm[P_DX] / o2d[O_UML * n2 + c] / prm[P_TAU]);
		float s0 = C(CI_HK, c) / max(C(CI_HBL, c), 1.0) * prm[P_TAU] * (1.0 - fa);
		float fi = float(i) - ex, fj = float(j) - ey;
		float val = 0.0;
		if (fi >= 0.0 && fi <= float(nx - 1) && fj >= 0.0 && fj <= float(ny - 1)) {
			int i0 = clamp(int(floor(fi)), 0, nx - 2);
			int j0 = clamp(int(floor(fj)), 0, ny - 2);
			float aa = fi - float(i0), bb = fj - float(j0);
			int b0 = src * n2;
			val = (1.0 - bb) * ((1.0 - aa) * o2d[b0 + j0 * nx + i0] + aa * o2d[b0 + j0 * nx + i0 + 1])
					+ bb * ((1.0 - aa) * o2d[b0 + (j0 + 1) * nx + i0] + aa * o2d[b0 + (j0 + 1) * nx + i0 + 1]);
		}
		o2d[dst * n2 + c] = val * fa + s0;
	}
#endif

#ifdef K_FILL
	// клетка: смесь механизмов + анабатика + θ′ (F, волны) + сток G (AirPhaseCpu.cell); центры → ctr
	bool heated = v == V_H && prm[P_HEATED] > 0.0;
	bool gact = v == V_H && prm[P_GACT] > 0.0;
	int thp = O_TH0 + pc.i1.x;
	GRID_LOOP(N) {
		int ih = t % NX;
		int jh = (t / NX) % NY;
		int k = t / (NX * NY);
		int j = clamp(jh - 1, 0, ny - 1), i = clamp(ih - 1, 0, nx - 1);
		int c = j * nx + i;
		float hc = C(CI_HC, c);
		float zmsl = prm[P_ZBOT] + (float(k) - 0.5) * prm[P_DZ];
		vec4 r = vec4(0.0);
		if (k >= 1 && zmsl >= hc) {
			float zagl = zmsl - hc;
			Mech m = mech(c, zmsl);
			vec3 mn = mixw(v, c, m);
			float u = mn.x, vv = mn.y, th = 0.0;
			if (heated) {
				float wf = wts[widx(v, WS_FIN, PH_F, c)] / max(1.0 - wts[widx(v, WS_FIN, PH_G, c)], 1e-12);
				float s = C(CI_S, c);
				float sina = s / sqrt(1.0 + s * s);
				float bs = prm[P_GRAV] / prm[P_THETA0] * max(C(CI_HK, c), 0.0);
				float ua = pow(bs * prm[P_SLOPE_LEN] * sina, 1.0 / float(3));
				float dl = max(prm[P_ANA_DMIN], prm[P_ANA_DFRAC] * C(CI_HBL, c));
				float pr = exp(-zagl / dl);
				float ds = max(s, 1e-9);
				u += wf * ua * C(CI_GX, c) / ds * pr;
				vv += wf * ua * C(CI_GY, c) / ds * pr;
				if (zagl < C(CI_HBL, c)) th = o2d[thp * n2 + c];
				if (zmsl >= prm[P_HCD]) th -= (zmsl > prm[P_ZI] ? prm[P_GAMW] : 0.0) * m.eta;
			}
			if (gact) {
				float wg = wts[widx(v, WS_FIN, PH_G, c)];
				bool layer = C(CI_GLAY, c) > 0.5;
				float l = C(CI_GL, c);
				float d = C(CI_GD, c);
				float top = layer ? d : prm[P_G_TOPL] * l;
				float tm = clamp((zagl - top) / (prm[P_G_MEMB] * max(top, 1.0)), 0.0, 1.0);
				float member = 1.0 - tm * tm * (float(3) - 2.0 * tm);
				float sp, thg;
				if (layer) {
					sp = C(CI_GUC, c);
					thg = -prm[P_GDTHC] * clamp(1.0 - zagl / max(d, 1.0), 0.0, 1.0);
				} else {
					float xn = zagl / l;
					sp = C(CI_GUS, c) * exp(-xn) * sin(xn);
					thg = -C(CI_GDTH, c) * exp(-xn) * cos(xn) * C(CI_GON, c);
				}
				float al = wg * member;
				u = (1.0 - al) * u + al * sp * C(CI_GDX, c) * member;
				vv = (1.0 - al) * vv + al * sp * C(CI_GDY, c) * member;
				th += wg * thg * member;
			}
			r = vec4(u, vv, mn.z, th);
			if (any(isnan(r)) || any(isinf(r))) {
				r = vec4(0.0);
				o2d[O_FLAG * n2] = 1.0;
			}
		}
		ctr[t] = r.x;
		ctr[N + t] = r.y;
		ctr[2 * N + t] = r.z;
		ctr[3 * N + t] = r.w;
	}
#endif

#ifdef K_FACES
	// грани MAC из центров (AirPhaseCpu.faces)
	int nyx = NX * NY;
	GRID_LOOP(N) {
		int ih = t % NX;
		int jh = (t / NX) % NY;
		int k = t / nyx;
		int j = clamp(jh - 1, 0, ny - 1), i = clamp(ih - 1, 0, nx - 1);
		float zk = prm[P_ZBOT] + (float(k) - 0.5) * prm[P_DZ];
		bool air = k >= 1 && zk >= C(CI_HC, j * nx + i);
		vec4 r = vec4(0.0);
		if (air) {
			float fu = ctr[t];
			if (ih > 0) {
				int i2 = clamp(ih - 2, 0, nx - 1);
				bool a2 = zk >= C(CI_HC, j * nx + i2);
				fu = a2 ? 0.5 * (ctr[t - 1] + ctr[t]) : 0.0;
			}
			float fv = ctr[N + t];
			if (jh > 0) {
				int j2 = clamp(jh - 2, 0, ny - 1);
				bool a2 = zk >= C(CI_HC, j2 * nx + i);
				fv = a2 ? 0.5 * (ctr[N + t - NX] + ctr[N + t]) : 0.0;
			}
			float fw = 0.0;
			if (k > 1) {
				float zb = prm[P_ZBOT] + (float(k - 1) - 0.5) * prm[P_DZ];
				if (zb >= C(CI_HC, j * nx + i)) fw = 0.5 * (ctr[2 * N + t - nyx] + ctr[2 * N + t]);
			}
			r = vec4(fu, fv, fw, ctr[3 * N + t]);
		}
		outv[t] = r.x;
		outv[N + t] = r.y;
		outv[2 * N + t] = r.z;
		outv[3 * N + t] = r.w;
	}
#endif
}
