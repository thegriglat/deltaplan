"""Длинный прогон 10 мин (Δθ=0,1 К) без стенок — отделяет численную потерю от влияния земли/крышки."""
import json
from step1 import run
out = {}
for name, kw in (('free_N10000', dict(N=10000)), ('free_N20000', dict(N=20000)), ('free_N10000_s2.5', dict(N=10000, sig_fac=2.5))):
    r = run(dtheta=0.1, T=600.0, z0=600.0, dt=2.0, obs=(), ke_every=300, walls=False, **kw)
    out[name] = dict(N=r['N'], sigma=r['sigma'], wall_s=r['wall_s'], rec=[q for q in r['rec'] if q['t'] % 100 == 0])
    print(name, flush=True)
json.dump(out, open('out/step1b_raw.json', 'w'))
