#!/usr/bin/env python3
"""PHD-3: сводка feel.json + cmdlp.json -> summary.json, таблицы в stdout."""
import json, math, os
HERE = os.path.dirname(os.path.abspath(__file__))  # пути от каталога скрипта, не от cwd
d = json.load(open(os.path.join(HERE, 'feel.json'))); lp = json.load(open(os.path.join(HERE, 'cmdlp.json')))
W = ['training', 'laminar', 'sport', 'ww_u2']
out = {}
for w in W:
    r = d[w]; ine = r['inertia']; dv = r['deriv']
    # качание пилота: лог. декремент по экстремумам относительно асимптоты (среднее последних 4)
    e = r['swing']['extrema_t_y']; ys = [x[1] for x in e]; ts = [x[0] for x in e]
    df = [abs(ys[k + 1] - ys[k]) for k in range(0, 6)]
    rat = [df[k + 1] / df[k] for k in range(0, 4)]
    half = math.exp(sum(math.log(x) for x in rat) / len(rat))
    delta = -2 * math.log(half)  # на период
    zeta = delta / math.sqrt(4 * math.pi ** 2 + delta ** 2)
    T = 2 * (ts[3] - ts[1]) / 2  # период по 2 полупериодам
    T = ts[3] - ts[1]
    lam_sys = abs(dv['Lp_Nms']) / ine['ixx_system']
    lam_sys2 = abs(dv['dpMsys_Nms'][0]) / ine['ixx_system']
    out[w] = dict(ixx_wing=ine['ixx_wing'], iyy_wing=ine['iyy_wing'], izz_wing=ine['izz_wing'],
                  added=ine['ixx_added_air'], ixx_system=ine['ixx_system'], m_wing=ine['wing_mass_kg'],
                  span=ine['span_m'], ixx_over_mb2=ine['ixx_wing'] / (ine['wing_mass_kg'] * ine['span_m'] ** 2),
                  Clp=dv['Clp'], Clp_sys=dv['Clp_sys'], Cnr=dv['Cnr'], Cmq=dv['Cmq'], Cnp=dv['Cnp'], Clr=dv['Clr'],
                  lam_roll=lam_sys2, decay_t63=dv['decay_t63_s'], swing_T=T, swing_zeta=zeta, swing_half_ratio=half,
                  izz_with_body=ine['izz_system_pilot_body_28'])
    print(w, {k: round(v, 3) for k, v in out[w].items()})
json.dump(out, open(os.path.join(HERE, 'summary.json'), 'w'), ensure_ascii=False, indent=1)
for w in ['training','laminar','sport']:
    print(w)
    for t, v in lp[w]['cmdlp'].items(): print('  ', t, {k.replace('_p_amp_dps', ''): round(x, 2) for k, x in v.items()})
