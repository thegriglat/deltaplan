"""Аналитический порт cloud_light (scripts/atmosphere/cloud_common.gdshaderinc) для плоского слоя
и физический эталон (двухпотоковое пропускание). Запуск: python model.py > model.json
Единицы шейдера: яркость на единицу σ (линейная, до экспозиции), Y = 0.2126R+0.7152G+0.0722B."""
import json, math
import numpy as np

CFG = json.load(open(__file__.rsplit('/tools/', 1)[0] + '/configs/atmosphere.json'))['clouds']
Yw = np.array([0.2126, 0.7152, 0.0722])
Y = lambda v: float(np.dot(Yw, v))


def hg(c, g):
    return (1 - g * g) / (4 * math.pi * max(1 + g * g - 2 * g * c, 1e-4) ** 1.5)


def phase(cos_t):
    return (CFG['phase_mix'] * hg(cos_t, CFG['phase_back'])
            + (1 - CFG['phase_mix']) * hg(cos_t, CFG['phase_forward']) * CFG['silver']) * 4 * math.pi


def light(od, sky, hh, cos_t, sun_e=1.3, c=CFG):
    ext, la = c['extinction_per_m'], c['light_absorb']
    beer = math.exp(-od * ext * la) + c['multi_scatter'] * math.exp(-od * ext * la * 0.2)
    powder = 1 - math.exp(-1.0 * ext * 60) * c['powder_strength']
    s = min(max(hh / 0.5, 0), 1); up_w = s * s * (3 - 2 * s)
    top = np.array(c['ambient_top']); bot = np.array(c['ambient_bottom'])
    amb = (top * (sky * (1 - up_w * .5) + up_w * .5) + bot * c['base_darkness'] * (1 - up_w)) * c['ambient_energy']
    return sun_e * np.ones(3) * beer * phase(cos_t) * powder + amb


def sky_factor(D, h, sky_occ, core):
    s = math.exp(-max(D - h, 0) / sky_occ) * (1 - 0.4 * core)
    k = min(max(h / (sky_occ * 1.5), 0), 1); k = k * k * (3 - 2 * k)
    return s + (1 - s) * k


def game_ratio(D, sky_occ=None, rho=1.0, core=0.0, cos_t=0.0, el=52.0, h_base=20.0):
    sky_occ = sky_occ or CFG['sky_occlusion_m']
    od_b = rho * 0.5 * D           # путь к солнцу ≈ половина мощности (шаги света до top*0.5)
    base = light(od_b, sky_factor(D, h_base, sky_occ, core), h_base / D, cos_t)
    top = light(0.0, 1.0, 1.0, cos_t)
    return Y(base), Y(top)


def two_stream_T(tau, g=0.85):
    return 1 / (1 + 0.75 * (1 - g) * tau)


def lit_ratio(tau, A, f=1.0, g=0.85):
    """L_base/L_top физически: основание = пропущенный свет + отражённый землёй свет (R·A·f·E_g/E_top),
    верх = R·E_top. R = 1−T (консервативное рассеяние). Нижняя/верхняя границы — по τ, A, f."""
    T = two_stream_T(tau, g); R = 1 - T
    return (T + R * A * f) / R


if __name__ == '__main__':
    out = {'game': [], 'physical': []}
    for D in (300, 500, 1000, 1500, 3000, 8000):
        for so in (200, 350, 500, 700, 1e9):
            for core in (0.0, 1.0):
                b, t = game_ratio(D, so, core=core)
                out['game'].append(dict(depth_m=D, sky_occlusion_m=so, core=core, Y_base=b, Y_top=t, ratio=b / t))
    for name, (t0, t1) in {'thin_cu': (10, 25), 'med_cu': (25, 60), 'cb': (100, 300)}.items():
        lo = lit_ratio(t1, 0.1, 0.7); hi = lit_ratio(t0, 0.3, 1.0)
        out['physical'].append(dict(type=name, tau_lo=t0, tau_hi=t1, T_lo=two_stream_T(t1), T_hi=two_stream_T(t0), ratio_lo=lo, ratio_hi=hi))
    print(json.dumps(out, indent=1))
