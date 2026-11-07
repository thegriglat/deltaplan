"""Собирает out/step3/results.json (thermal_slope, rotor, criterion, timing) и PNG из thermal_*.json, rotor_*.json."""
import glob, json, os
import numpy as np
import matplotlib; matplotlib.use('Agg')
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__)); OUT = os.path.join(HERE, 'out', 'step3')
R = 100.0
T = {os.path.basename(f)[8:-5]: json.load(open(f)) for f in sorted(glob.glob(f'{OUT}/thermal_*.json'))}
RO = {os.path.basename(f)[6:-5]: json.load(open(f)) for f in sorted(glob.glob(f'{OUT}/rotor_*.json'))}


def at(r, t):
    return [q for q in r['rec'] if abs(q['t'] - t) < 1e-9][0]


def row(r, t):
    q = at(r, t); q0 = at(r, 0.0)
    return dict(t=t, ratio=q['ratio'], v_in=q['v_in'], dx=q['xc'] - q0['xc'], dx_minus_Ut=q['xc'] - q0['xc'] - r['U'] * t,
                dz=q['zc'] - q0['zc'], d_n=q['d_n'], d_n0=q0['d_n'], dd_n=q['d_n'] - q0['d_n'], slope=q['slope'],
                inflow_mean=q['inflow']['mean'], inflow_max=q['inflow']['max'], inflow_frac_gt0p1=q['inflow']['frac_pos_gt0p1'],
                inflow_up=q['inflow']['up'], inflow_down=q['inflow']['down'],
                frac_far_neg=q['line']['frac_far_neg'], return_frac=q['line']['return_frac'], wmin_over_wmax=q['line']['wmin'] / q['line']['wmax'],
                G_half_ratio=q['G_half'] / q['G_half_pred'], P_over_Bt=q['P_over_Bt'], d_pair_over_pred=q['d_pair'] / q['d_pred'],
                z_min_gap=q['z_min_p'])


MAIN = ['flat_U0', 'flat_U2p5', 'ag_foot_U0p0', 'ag_foot_U2p5', 'ag_mid_U0p0', 'ag_mid_U2p5', 'pd_foot_U0p0', 'pd_foot_U3p0', 'pd_mid_U0p0', 'pd_mid_U3p0']
GAP0 = [n + '_gap0' for n in ('flat_U0', 'ag_foot_U0p0', 'ag_mid_U0p0', 'ag_mid_U2p5', 'pd_mid_U0p0', 'pd_mid_U3p0')]
SENS = ['ag_mid_U2p5', 'ag_mid_U2p5_delete', 'ag_mid_U2p5_k2', 'ag_mid_U2p5_k4', 'ag_mid_U2p5_ds12', 'ag_mid_U2p5_N4000']
th = dict(main={n: dict(U=T[n]['U'], xc0=T[n]['xc0'], ground0=T[n]['ground0'], t30=row(T[n], 30.0), t60=row(T[n], 60.0)) for n in MAIN if n in T},
          gap0={n: dict(U=T[n]['U'], t30=row(T[n], 30.0), t60=row(T[n], 60.0), n_under=T[n]['n_under']) for n in GAP0 if n in T},
          sensitivity={n: dict(t60=row(T[n], 60.0), wall_s=T[n]['wall_s'], ms_per_step=T[n]['ms_per_step'], n_under=T[n]['n_under'],
                               N=T[n]['N'], n_panels=T[n]['n_panels']) for n in SENS if n in T})
for n in ('ag_mid_U2p5_T180', 'flat_T180'):
    if n in T:
        th.setdefault('long', {})[n] = [dict(t=q['t'], xc=q['xc'], zc=q['zc'], agl=q['agl'], d_n=q['d_n'], ratio=q['ratio'], inflow_mean=q['inflow']['mean'],
                                          G_half_ratio=q['G_half'] / q['G_half_pred'] if q['t'] else None, P_over_Bt=q['P_over_Bt']) for q in T[n]['rec'] if q['t'] % 30 == 0]
# разности к плоскому контролю
fl = th['main']['flat_U0']['t60']
th['delta_vs_flat_t60'] = {n: {k: v['t60'][k] - fl[k] for k in ('ratio', 'inflow_mean', 'dd_n', 'return_frac')} for n, v in th['main'].items()}
# сходимость по k, delete, ds, N: относительное расхождение с базой
base = th['sensitivity']['ag_mid_U2p5']['t60']
th['sensitivity_rel_t60'] = {n: {k: (v['t60'][k] - base[k]) / abs(base[k]) if base[k] else None for k in ('ratio', 'inflow_mean', 'dx', 'dz', 'G_half_ratio')} for n, v in th['sensitivity'].items()}

# ротор
rot = {}
for n, r in RO.items():
    z = r['zone_thr0p5']; z0 = r['zone_thr0']
    rot[n] = dict(U100=r['U100'], shed=r['shed'], tau=r.get('tau'), shed_off=r['shed_off'], ds_min=r['ds_min'], k=r['k'], lee_slope_max50=r['lee_slope_max50'],
                  n_vortices=r['n_vortices'], sum_G=r['sum_G'], born_G=r['born_G'], n_deleted=r['n_deleted'], wall_s=r['wall_s'], ms_per_step=r['ms_per_step'],
                  zone=dict(L=z.get('L'), x_start=z.get('x_start'), x_end=z.get('x_end'), depth_agl=z.get('depth_agl'), u_min=z['u_min'], umin_over_U100=z['umin_over_U100']),
                  zone_u_lt0=dict(L=z0.get('L'), x_start=z0.get('x_start'), x_end=z0.get('x_end')),
                  u15_mean_by_x={str(v): float(np.interp(v, r['x_rel'], r['u_mean_agl15'])) for v in (0, 100, 200, 400, 700, 1000, 1500)})
    if n.startswith('perd'):
        rot[n]['L_over_D'] = (z.get('L') or 0.0) / 1411.8
    else:
        rot[n]['L_over_H'] = (z.get('L') or 0.0) / 200.0
rot_out = dict(
    ref=dict(menke_L=700.0, menke_L_over_H=2.8, menke_L_over_D=0.5, menke_umax_over_U100=0.22, menke_umax_sigma=0.08, menke_depth=157.0, thr=0.5, blind=15.0,
             D_perd=1411.8, H_perd=173.6, game_back_flow_over_UH=0.22, game_L_over_r=2.8),
    runs=rot)

# критерии
c = {}
for n in ('ag_foot_U0p0', 'ag_foot_U2p5', 'ag_mid_U0p0', 'ag_mid_U2p5', 'pd_foot_U0p0', 'pd_foot_U3p0', 'pd_mid_U0p0', 'pd_mid_U3p0'):
    if n in th['main']:
        a = th['main'][n]
        c[n] = dict(inflow_t30=a['t30']['inflow_mean'], inflow_t60=a['t60']['inflow_mean'], inflow_ok=bool(a['t30']['inflow_mean'] > 0.1 and a['t60']['inflow_mean'] > 0.1),
                    detach_dd_n_t60=a['t60']['dd_n'], detach_ok=bool(a['t60']['dd_n'] > 0), ratio_t60=a['t60']['ratio'], ratio_ok=bool(0.7 <= a['t60']['ratio'] <= 1.3),
                    ring_frac_far_neg=a['t60']['frac_far_neg'], ring_ok=bool(a['t60']['frac_far_neg'] >= 0.95), G_half_ratio=a['t60']['G_half_ratio'],
                    P_over_Bt=a['t60']['P_over_Bt'], P_ok=bool(abs(a['t60']['P_over_Bt'] - 1) <= 0.01), d_pair_over_pred=a['t60']['d_pair_over_pred'])
crit = dict(thermal=c, rotor={})
for n, v in rot.items():
    if not v['shed'] or v['tau']:
        continue
    crit['rotor'][n] = dict(zone_exists=bool(v['zone']['L'] and v['zone']['L'] > 50), L=v['zone']['L'], umin_over_U100=v['zone']['umin_over_U100'],
                            ok_umax=bool(abs(abs(v['zone']['umin_over_U100']) - 0.22) <= 0.16), lee_slope_max50=v['lee_slope_max50'])
crit['definitions'] = dict(inflow='горизонтальное возмущение u на 5 м над землёй к центру термика, среднее по 0,5R<|x−xc|<3R, > 0,1 м/с при t=30 и 60 с',
                           detach='d_n(60) − d_n(0) > 0, d_n — нормальное расстояние барицентра b от линии земли', ratio='v пятна/(0,5·b·t) ∈ [0,7; 1,3]',
                           ring='доля точек w<0 на линии через центр при |x−xc| > 1,3R ≥ 0,95 (возмущение: поле с частицами минус без них)',
                           P='|P/(B·t) − 1| ≤ 1 % (у стенки P не сохраняется — стенка забирает импульс; для справки)',
                           rotor='зона u<−0,5 м/с на agl ≥ 15 м, время-среднее; L > 50 м; |u_min|/U100 = 0,22 ± 0,16 (2σ Menke)')

# время
def ms(n): return T[n]['ms_per_step'] if n in T else None
tim = dict(thermal_ms_per_step={n: T[n]['ms_per_step'] for n in T if n in MAIN or n in SENS},
           thermal_solve_share={n: T[n]['t_solve'] / (T[n]['t_solve'] + T[n]['t_vel']) for n in SENS if n in T},
           matrix_inverse_s={n: T[n]['t_setup_inv'] for n in SENS if n in T},
           n_panels={n: T[n]['n_panels'] for n in SENS if n in T},
           rotor_ms_per_step={n: RO[n]['ms_per_step'] for n in RO}, note='прогоны шли параллельно на одном GPU (RTX 4070 SUPER), свободного замера по нагрузке нет; ориентир одиночного — минимальные значения; N=11601: 43 мс на eval (proto-a.md) × 2 вычисления + solve')
tr = os.path.join(OUT, 'timing_raw.json')
if os.path.exists(tr):
    tim['free_gpu_step'] = json.load(open(tr))
    tim['note_free'] = 'step3_timing.py: свободный GPU, 20 шагов Heun без диагностики; ms_solve — часть ms_vel (solve σ: скорость частиц в центрах панелей RawKernel с nt = n_panels нитей — мало параллелизма — + Minv @ rhs + фон в NumPy)'
res = dict(thermal_slope=th, rotor=rot_out, criterion=crit, timing=tim)
json.dump(res, open(os.path.join(OUT, 'results.json'), 'w'), indent=1, default=float)

# рисунок
fig, ax = plt.subplots(2, 3, figsize=(15, 8))
for n in ('flat_U0', 'ag_mid_U0p0', 'ag_mid_U2p5', 'pd_mid_U0p0', 'pd_mid_U3p0'):
    if n in T:
        t = [q['t'] for q in T[n]['rec']]
        ax[0, 0].plot(t, [q['d_n'] for q in T[n]['rec']], label=n)
        ax[0, 1].plot(t, [q['inflow']['mean'] for q in T[n]['rec']], label=n)
        ax[0, 2].plot(t[1:], [q['ratio'] for q in T[n]['rec']][1:], label=n)
ax[0, 0].set_title('нормальное расстояние барицентра до земли, м'); ax[0, 1].set_title('подтекание у земли (к термику), м/с'); ax[0, 2].set_title('v/(0,5·b·t)')
ax[0, 0].legend(fontsize=7)
for i, (n, tt) in enumerate((('ag300_U8', 'Agnesi H=200 L=300, U100=8'), ('perd_U8', 'Perdigao, U100=8'), ('perd_U5', 'Perdigao, U100=5'))):
    if n in RO:
        r = RO[n]
        for key, lab in (('u_mean_agl15', '15 м'), ('u_mean_agl50', '50 м'), ('u_mean_agl100', '100 м')):
            ax[1, i].plot(r['x_rel'], r[key], label='agl ' + lab)
        ax[1, i].axhline(-0.5, color='k', lw=0.5); ax[1, i].set_title(tt + ': u время-среднее за бровкой, м/с'); ax[1, i].legend(fontsize=7)
plt.tight_layout(); plt.savefig(os.path.join(OUT, 'step3_summary.png'), dpi=110)
print('ok')
