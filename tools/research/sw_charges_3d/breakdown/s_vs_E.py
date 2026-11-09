"""Оценка числа закрутки S ротора-звена по SWD9 v2 как функции E (порядки величин, не прогноз).
Модель: звено длиной l=2H, ядро радиуса a=H/2 (допущение), Гамма=0.5*ut^2*tau, q=E*dU*Ls,
осевой отток W = q*l/(pi a^2) (сток q на единицу длины уходит из ядра через два конца),
S_sw = v_theta_max / W, v_theta_max ~ 0.64*Gamma/(2 pi a) (Бюргерс/Ламб–Озин, максимум при r~1.12 a_Burgers)."""
import json, itertools
import numpy as np
ut_frac=0.5     # u_t(x_c)/U  допущение (SWD7: обратное течение ~0.2-0.5 U)
res=[]
Sc={'S_sw_low':1.0,'S_sw_high':1.5}   # диапазон порога по v_theta/W: см. README
for H,U,Lfac in itertools.product([100,200,400],[8,12],[3,4,5]):
    Ls=Lfac*H; l=2*H; a=H/2
    ut=ut_frac*U; tau=Ls/U
    G=0.5*ut**2*tau
    vth=0.64*G/(2*np.pi*a)
    for E in [0.01,0.02,0.05,0.1,0.2]:
        q=E*ut*Ls
        W=q*l/(np.pi*a**2)
        S=vth/W
        res.append(dict(H=H,U=U,Ls_over_H=Lfac,E=E,Gamma=G,q=q,W=W,vth=vth,S=S))
S=np.array([r['S'] for r in res]); E=np.array([r['E'] for r in res])
out={'rows':res}
for e in sorted(set(E)):
    s=S[E==e]; out[f'E={e}']=dict(S_min=s.min(),S_med=float(np.median(s)),S_max=s.max())
# E, при котором S=S_c (S ~ 1/E)
s5=np.array([r['S'] for r in res if r['E']==0.05])
out['E_crit_for_S']={f'Sc={c}':dict(E_min=0.05*s5.min()/c,E_med=0.05*float(np.median(s5))/c,E_max=0.05*s5.max()/c) for c in (1.0,1.5)}
json.dump(out,open('s_vs_E.json','w'),indent=1,default=float)
print(json.dumps({k:v for k,v in out.items() if k!='rows'},indent=1,default=float))
