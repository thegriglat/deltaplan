"""Собирает out/results.json (step1, step2, criterion, timing) и PNG из *_raw.json."""
import json, numpy as np
import matplotlib; matplotlib.use('Agg')
import matplotlib.pyplot as plt
from step1 import line_stats, gedeon_compare

s1 = json.load(open('out/step1_raw.json')); s2 = json.load(open('out/step2_raw.json'))
s1b = json.load(open('out/step1b_raw.json')); tm = json.load(open('out/timing_raw.json'))
R = 100.0
m = s1['main']; b = m['b']
rec = {int(r['t']): r for r in m['rec'] if r['t'] == int(r['t'])}
def pick(t, keys): return {k: rec[t].get(k) for k in keys}
tab = [dict(t=t, **pick(t, ['zc', 'v', 'v_pred', 'ratio', 'G_half', 'G_half_pred', 'P_over_Bt', 'd_pair', 'U_pair', 'U_pair_over_bt', 'KE_over_PE']))
       for t in (10, 30, 60, 90, 120, 150)]
for r in tab: r['G_half_ratio'] = r['G_half'] / r['G_half_pred']
lines = {k: line_stats(v, R) for k, v in m['lines'].items()}
ged = {k: gedeon_compare(m['lines'][k], R) for k in ('t30_off0', 't60_off0', 't120_off0')}
step1 = dict(params=dict(R=R, dtheta=1.0, b=b, a_pred=b / 2, N_inside=m['n_in'], N_total=m['N'], sigma=m['sigma'], dt=m['dt'], z0=m['z0'], walls='z=0, z=1200 (изображения, kz=1)'),
             table=tab, lines=lines, gedeon=ged, convergence=s1['conv'], d_pred_pi_R_over_2=np.pi * R / 2,
             long_walls=[{k: v for k, v in r.items() if k in ('t', 'ratio', 'G_half', 'G_half_pred', 'P_over_Bt', 'KE_over_PE', 'd_pair', 'U_pair_over_bt', 'zc')} for r in s1['long']['rec'] if r['t'] in (100, 300, 600)],
             long_free={k: [{kk: vv for kk, vv in r.items() if kk in ('t', 'ratio', 'G_half', 'G_half_pred', 'P_over_Bt', 'KE_over_PE')} for r in v['rec'] if r['t'] in (300, 600)] for k, v in s1b.items()})
# шаг 2
t = np.array([r['t'] for r in s2['rec']]); a = np.array([r['amp'] for r in s2['rec']])
sel = (t >= 30) & (t <= 150)
fit = np.polyfit(t[sel], np.log(a[sel]), 1)
sel2 = (t >= 60) & (t <= 150); fit2 = np.polyfit(t[sel2], np.log(a[sel2]), 1)
zg = np.array(s2['zg']); sw = np.array(s2['sigma_w']); su = np.array(s2['sigma_u'])
k = np.array(s2['spec_k']); sp = np.array(s2['spec_w']); n = min(len(k), len(sp)); k = k[:n]; sp = sp[:n]
def slope(lo, hi):
    mm = (k > lo) & (k < hi); return float(np.polyfit(np.log(k[mm]), np.log(sp[mm]), 1)[0])
dU = s2['dU']
import os
seg = {}
for lo in range(30, 270, 30):
    mm = (t >= lo) & (t <= lo + 30)
    seg[f'{lo}-{lo+30}'] = float(np.polyfit(t[mm], np.log(a[mm]), 1)[0])
fit3 = np.polyfit(t[(t >= 90) & (t <= 180)], np.log(a[(t >= 90) & (t <= 180)]), 1)
conv2 = None
if os.path.exists('out/step2b_raw.json'):
    b2 = json.load(open('out/step2b_raw.json')); t2 = np.array([r['t'] for r in b2['rec']]); a2 = np.array([r['amp'] for r in b2['rec']])
    sw2 = np.array(b2['sigma_w']); su2 = np.array(b2['sigma_u'])
    conv2 = dict(N=b2['n'], sigma=b2['sigma'], wall_s=b2['wall_s'], growth_30_150=float(np.polyfit(t2[(t2 >= 30) & (t2 <= 150)], np.log(a2[(t2 >= 30) & (t2 <= 150)]), 1)[0]),
                 growth_90_180=float(np.polyfit(t2[(t2 >= 90) & (t2 <= 180)], np.log(a2[(t2 >= 90) & (t2 <= 180)]), 1)[0]),
                 sigma_w_peak=float(sw2.max()), sigma_u_peak=float(su2.max()), cores=b2['cores'])
step2 = dict(growth_segments=seg, growth_rate_fit_90_180=float(fit3[0]), convergence_dx3=conv2, params=dict(dU=dU, delta=s2['delta'], L=s2['L'], nmode=s2['nmode'], lam_fast=s2['lam_fast'], N=s2['n'], sigma=s2['sigma'], dt=s2['dt'], T=s2['T'], z_layer_m=200.0),
             growth_rate_fit_30_150=float(fit[0]), growth_rate_fit_60_150=float(fit2[0]), growth_rate_theory=s2['sigma_theory'],
             growth_ratio=float(fit[0] / s2['sigma_theory']), amp_series=[[float(x), float(y)] for x, y in zip(t[::10], a[::10])],
             Pdrift_max=float(max(abs(r['Pdrift']) for r in s2['rec'])), Gdrift_max=float(max(abs(r['Gdrift']) for r in s2['rec'])),
             sigma_w_peak=float(sw.max()), sigma_w_peak_over_dU=float(sw.max() / dU), sigma_u_peak=float(su.max()), sigma_u_peak_over_dU=float(su.max() / dU),
             sigma_w_core_band_mean=float(sw[np.abs(zg) <= 50].mean()), sigma_w_core_band_over_dU=float(sw[np.abs(zg) <= 50].mean() / dU),
             model_sigma_w=0.14 * dU, model_sigma_u=0.18 * dU,
             sigma_w_profile=dict(z=zg.tolist(), sigma_w=sw.tolist(), sigma_u=su.tolist()),
             cores=s2['cores'], spectrum_slope_k_0p05_0p3=slope(0.05, 0.3), spectrum_slope_k_0p3_1=slope(0.3, 1.0),
             spectrum_k_peak=float(k[np.argmax(sp * k)]))
# критерий
L60 = lines['t60_off0']; L120 = lines['t120_off0']
v30 = rec[30]['ratio']; v60 = rec[60]['ratio']
crit = {
  'ring_negative_wr': dict(value=min(lines['t30_off0']['frac_far_negative'], L60['frac_far_negative'], L120['frac_far_negative']), threshold='доля точек |x|>1.3R с w<0 = 1 (линия через центр, t=30/60/120 с)',
                           pass_=bool(min(lines['t30_off0']['frac_far_negative'], L60['frac_far_negative'], L120['frac_far_negative']) >= 1.0), wmin_over_wmax_t60=L60['wmin'] / L60['wmax']),
  'int_w_zero_core_line': dict(value=max(abs(lines[k_]['int_over_pos']) for k_ in ('t30_off0', 't60_off0', 't120_off0')), threshold=0.05, pass_=True),
  'int_w_zero_all_lines': dict(value=max(abs(v['int_over_pos']) for v in lines.values()), threshold=0.05, pass_=True),
  'speed_0p5bt': dict(value=[v30, v60], threshold='0,7…1,3 от 0,5·b·t (t = 30, 60 с)', pass_=bool(0.7 <= v30 <= 1.3 and 0.7 <= v60 <= 1.3), ratio_t90=rec[90]['ratio'], ratio_t120=rec[120]['ratio']),
  'pair_speed_point': dict(value=rec[60]['U_pair_over_bt'], reference=2 / np.pi ** 2, note='точечная пара U=Γ/(2πd): 0,19·b·t (≈2/π² = 0,20) против скорости пятна 0,93·0,5·b·t — разный объект'),
  'conservation_10min': dict(G_total=max(abs(r['G_tot']) for r in s1['long']['rec']), B='постоянна по построению (без перемешивания)',
                             P_over_Bt_t300_walls=[r['P_over_Bt'] for r in s1['long']['rec'] if r['t'] == 300][0],
                             P_over_Bt_t600_walls=[r['P_over_Bt'] for r in s1['long']['rec'] if r['t'] == 600][0],
                             P_over_Bt_t600_free={k_: [r['P_over_Bt'] for r in v['rec'] if r['t'] == 600][0] for k_, v in s1b.items()},
                             threshold=0.01, pass_=False),
  'energy_balance': dict(value=[rec[t_]['KE_over_PE'] for t_ in (30, 60, 90)], threshold='KE/ΔPE = 1 ±5 % до деформации', pass_=bool(all(abs(rec[t_]['KE_over_PE'] - 1) < 0.05 for t_ in (30, 60)))),
  'kh_growth': dict(value=step2['growth_ratio'], threshold='0,7…1,3 от теории tanh (0,0285 с⁻¹)', pass_=bool(0.7 <= step2['growth_ratio'] <= 1.3)),
}
for k_ in ('int_w_zero_core_line', 'int_w_zero_all_lines'): crit[k_]['pass_'] = bool(crit[k_]['value'] <= 0.05)
crit['overall_spec'] = dict(pass_=bool(crit['ring_negative_wr']['pass_'] and crit['int_w_zero_core_line']['pass_'] and crit['speed_0p5bt']['pass_']),
                            note='критерий задания: кольцо w<0, ∫w dx=0 (5 %), скорость 0,5·b·t ±30 % — на t ≤ 60 с (до заметной деформации)')
timing = dict(gpu=tm['gpu'], rows=tm['rows'], naive_broadcast=tm['naive'],
              step1_main_wall_s=m['wall_s'], step1_N=m['N'], step1_steps=int(m['T'] / m['dt']),
              step1_ms_per_step=m['wall_s'] / (m['T'] / m['dt']) * 1e3, step2_wall_s=s2['wall_s'], step2_N=s2['n'], step2_steps=int(s2['T'] / s2['dt']),
              step2_ms_per_step=s2['wall_s'] / (s2['T'] / s2['dt']) * 1e3, long_free_wall_s={k_: v['wall_s'] for k_, v in s1b.items()},
              note='двойная точность; ms/шаг = 2 вычисления скорости (RK2) + диагностика')
json.dump(dict(step1=step1, step2=step2, criterion=crit, timing=timing), open('out/results.json', 'w'), indent=1, ensure_ascii=False)

# рисунки
fig, ax = plt.subplots(1, 3, figsize=(15, 4))
for key, c in (('t30_off0', 'C0'), ('t60_off0', 'C1'), ('t120_off0', 'C2')):
    ln = m['lines'][key]; x = np.array(ln['x']) - ln['xc']; w = np.array(ln['w'])
    ax[0].plot(x, w, c, label=key)
    x0 = lines[key]['x_zero']; q = x / x0; g = np.exp(-q ** 2) * (1 - q ** 2) * lines[key]['wmax']
    ax[0].plot(x, g, c + '--', lw=0.8)
ax[0].set_xlim(-600, 600); ax[0].legend(); ax[0].set_title('w(x) на высоте центра; пунктир — Гедеон'); ax[0].set_xlabel('x, м')
ax[1].plot([r['t'] for r in m['rec']], [r['ratio'] for r in m['rec']], label='v/(0,5 b t)')
ax[1].plot([r['t'] for r in m['rec']], [r['P_over_Bt'] for r in m['rec']], label='P/(B t)'); ax[1].legend(); ax[1].set_xlabel('t, с')
ax[2].semilogy(t, a); ax[2].semilogy(t[sel], np.exp(np.polyval(fit, t[sel])), 'r--'); ax[2].set_title('КГ: амплитуда моды, м'); ax[2].set_xlabel('t, с')
plt.tight_layout(); plt.savefig('out/step12_summary.png', dpi=110)
fig, ax = plt.subplots(1, 2, figsize=(9, 4))
ax[0].plot(sw, zg, label='σ_w'); ax[0].plot(su, zg, label='σ_u'); ax[0].axvline(0.14 * dU, c='C0', ls=':'); ax[0].axvline(0.18 * dU, c='C1', ls=':'); ax[0].legend(); ax[0].set_xlabel('м/с'); ax[0].set_ylabel('z - 200, м')
ax[1].loglog(k, sp); ax[1].set_xlabel('k, рад/м'); ax[1].set_title('спектр w(k) в слое')
plt.tight_layout(); plt.savefig('out/step2_profiles.png', dpi=110)
print(json.dumps(crit, indent=1, ensure_ascii=False)[:3500])
