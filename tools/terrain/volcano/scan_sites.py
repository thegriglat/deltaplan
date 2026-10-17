import sys, json, math
sys.path.insert(0,'.')
import _venv; _venv.ensure("numpy","PIL")
import numpy as np, check_sites as C, sites as S
from pathlib import Path
pl=C.load(Path('../../../data/locations/volcano_island'))
lat0,lon0=-27.10,-109.35
cands={'east_cliffs':(-27.1049,-109.2384,101),'crater_ridge':(-27.1805,-109.4131,75),'crater_ridge2':(-27.170,-109.4136,110),'plateau_landing':(-27.1103,-109.2414,90)}
for k,(la,lo,hd) in cands.items():
    x,z=S.latlon_to_local(la,lo,lat0,lon0)
    print(k,round(x),round(z),pl.start_checks(x,z,hd))
    # local search: rule-passing points within 400 m, heading ±
    best=[]
    for dz in range(-400,401,25):
        for dx in range(-400,401,25):
            r=pl.start_checks(x+dx,z+dz,hd)
            if r['ok']: best.append((math.hypot(dx,dz),dx,dz,r))
    best.sort(key=lambda t:t[0])
    for b in best[:3]: print('   ',b[1],b[2],b[3])
