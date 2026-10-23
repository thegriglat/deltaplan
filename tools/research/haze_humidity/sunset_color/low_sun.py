"""Свет облаков при солнце 2° и 0,8°: таблица против спектра, sun_l новая/старая, оттенок после тонмаппера (проба)."""
import json
from scenario import *
from spectral import spectral_T
from run_probe import probe
K=1.4;VALLEY=600.;TOP_H=2800.;ext=3.912/60000*K
res={}
for el in (2.0,0.8):
    l=light_at(el)
    row={}
    for Y in (3200,4500):
        tt=T(el,Y,ext,TOP_H); tr=T(35,VALLEY,ext,TOP_H); ts=spectral_T(el,Y,ext,TOP_H); trs=spectral_T(35,VALLEY,ext,TOP_H); to=spectral_T(el,Y,ext,TOP_H,ozone=True)
        sn=sun_new(el,Y,K,VALLEY,TOP_H); so=sun_old(el)
        row[f'y{Y}']=dict(T_table=[round(float(v),4) for v in tt],T_spectral=[round(float(v),4) for v in ts],ratio_table=[round(float(v),3) for v in tt/tr],ratio_spectral=[round(float(v),3) for v in ts/trs],
          ratio_spectral_ozone=[round(float(v),3) for v in to/trs],sun_l_new=[round(float(v),3) for v in sn],sun_l_old=[round(float(v),3) for v in so],
          new_G_R=round(float(sn[1]/sn[0]),3),new_B_R=round(float(sn[2]/sn[0]),3),old_G_R=round(float(so[1]/so[0]),3),old_B_R=round(float(so[2]/so[0]),3))
    # цепочка: сторона (cos 0.3), против солнца (cos -0.5), к солнцу (0.95), beer 0.6
    cases=[];meta=[]
    sky_k=l['sky_energy'];tint=l['tint']
    for name,sun in (('old',sun_old(el)),('new',sun_new(el,3200,K,VALLEY,TOP_H))):
        for cos in (0.95,0.3,-0.5):
            for b in (1.25,0.6):
                cases.append(cloud_rad(sun,b,cos,powder=0.8)); meta.append((name,cos,b))
    png=probe(cases,False,'g')
    row['chain']=[dict(model=n,cos_t=c,beer=b,hdr=[round(float(x),2) for x in h],srgb8=o,G_R=round(float(lin(o)[1]/lin(o)[0]),2),B_R=round(float(lin(o)[2]/lin(o)[0]),2)) for (n,c,b),h,o in zip(meta,cases,png)]
    res[f'el{el}']=row
json.dump(res,open('low_sun.json','w'),indent=1)
for k,r in res.items():
    print(k,{y:(v['sun_l_new'],v['new_G_R'],v['new_B_R'],'old',v['old_G_R'],v['old_B_R']) for y,v in r.items() if y!='chain'})
    print(' ratio table',r['y3200']['ratio_table'],'spec',r['y3200']['ratio_spectral'],'oz',r['y3200']['ratio_spectral_ozone'])
    for c in r['chain']: print('  ',c['model'],c['cos_t'],c['beer'],c['hdr'],c['srgb8'],c['G_R'],c['B_R'])
