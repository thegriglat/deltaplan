"""Кандидаты правки (числа через пробу тонмаппера): F1 - туман/ambient облаков x sky_energy x horizon_tint; F3 - общий множитель яркости облаков; F2 - потолок макс. канала с сохранением оттенка."""
import json
from scenario import *
from spectral import spectral_T
from run_probe import probe
EL=5.7;K=1.4;VALLEY=600.;TOP_H=2800.;Y=3200.;ext=3.912/60000*K
l=light_at(EL); sky_k=l['sky_energy']; tint=l['tint']
sun_n=sun_new(EL,Y,K,VALLEY,TOP_H)
day_sun=sun_new(35,700,K,VALLEY,TOP_H)   # днём у основания = прежний (1.2 x (1,.91,.79))
def render(sun,amb,fogc,cos,b,cap=None,scale=1.0):
    r=cloud_rad(sun*scale,b,cos,powder=0.8,amb=amb*scale,fogc=fogc*scale)
    if cap: r=r*min(1.0,cap/r.max())
    return r
variants=[('new',dict()),('F1',dict(amb=AMB*sky_k*tint,fogc=FOGC*sky_k*tint)),
          ('F1+F3(x sky_energy)',dict(amb=AMB*sky_k*tint,fogc=FOGC*sky_k*tint,scale=sky_k))]
for c in (1.5,2.0,2.5,3.0): variants.append((f'F1+F2 cap{c}',dict(amb=AMB*sky_k*tint,fogc=FOGC*sky_k*tint,cap=c)))
cases=[];meta=[]
for geom in ('sunset','day'):
    for cos in (0.95,0.9,0.7,0.3):
        for b in (1.25,0.6):
            for n,kw in variants:
                if geom=='sunset': sun=sun_n; kk=dict(amb=AMB,fogc=FOGC); kk.update(kw)
                else:
                    sun=day_sun; kk=dict(amb=AMB,fogc=FOGC); kk.update({k:v for k,v in kw.items() if k in('cap',)})
                cases.append(render(sun,kk['amb'],kk['fogc'],cos,b,kk.get('cap'),kk.get('scale',1.0) if geom=='sunset' else 1.0)); meta.append((geom,n,cos,b))
png=probe(cases,False,'f')
rows=[]
for (g,n,c,b),h,o in zip(meta,cases,png):
    ol=lin(o); rows.append(dict(geom=g,variant=n,cos_t=c,beer=b,hdr=[round(float(x),2) for x in h],srgb8=o,G_R=round(float(ol[1]/ol[0]),2),B_R=round(float(ol[2]/ol[0]),2)))
json.dump(rows,open('/tmp/claude-1000/fixes.json','w'),indent=1)
import collections
agg=collections.defaultdict(list)
for r in rows:
    if r['cos_t'] in (0.9,0.7) and r['beer']==0.6: agg[(r['geom'],r['variant'])].append((r['srgb8'],r['G_R'],r['B_R']))
for k,v in agg.items(): print(k,v)
