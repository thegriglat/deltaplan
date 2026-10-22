"""HH-12: где теряется тёплый цвет облаков на закате. Запуск: python3 analyze.py  (нужны godot и DISPLAY=:0; GPU-замок берёт сам)."""
import json, numpy as np
from scenario import *
from spectral import spectral_T
from run_probe import probe
EL=5.7; K=1.4; VALLEY=600.0; TOP_H=2800.0; Y=3200.0      # сценарий кадра (Алтай, 15.07 20:40): облако над верхом дымки
vis=60.0; ext=3.912/(vis*1000)*K
out={'scenario':dict(sun_el_deg=EL,haze_k=K,valley_msl_m=VALLEY,haze_top_msl_m=TOP_H,cloud_side_msl_m=Y,visibility_km=vis,
     note='haze_k=1.4 ~ RH 0.65 вечером на Алтае (haze_k_rh); кадр сняла HH-10, значения haze_k/valley/верха дымки в кадре не логировались - сценарий, не измерение')}
# 1. таблица против спектра
rows=[]
trs=spectral_T(35,VALLEY,ext,TOP_H); trt=T(35,VALLEY,ext,TOP_H)
for el in (35,18,8,5.7,2):
    tt=T(el,Y,ext,TOP_H); ts=spectral_T(el,Y,ext,TOP_H); to=spectral_T(el,Y,ext,TOP_H,ozone=True)
    rows.append(dict(el_deg=el,T_table=[round(float(v),4) for v in tt],T_spectral=[round(float(v),4) for v in ts],
        ratio_table=[round(float(v),3) for v in tt/trt],ratio_spectral=[round(float(v),3) for v in ts/trs],ratio_spectral_with_ozone_approx=[round(float(v),3) for v in to/trs]))
out['table_T']=dict(rows=rows,T_ref_table=[round(float(v),4) for v in trt],
    note='T(el, y=3200 м) таблицы HH4 против спектрального интеграла (Планк 5778 К, CIE Wyman 2013, Рэлей λ^-4.08); T_ref = T(35°, долина 600 м)',
    chapman_check=dict(zenith_tau550=float(tau(90,0,0,0)[0][1]),expected=float(BR*H),horizon_air_mass=float(tau(0,0,0,0)[1]/H),chapman=float(np.sqrt(np.pi*R/(2*H)))))
# 2. свет
l=light_at(EL)
sun_o=sun_old(EL); sun_n=sun_new(EL,Y,K,VALLEY,TOP_H)
out['sun_l']=dict(old=[round(float(v),3) for v in sun_o],new=[round(float(v),3) for v in sun_n],
   old_G_R=round(float(sun_o[1]/sun_o[0]),3),old_B_R=round(float(sun_o[2]/sun_o[0]),3),new_G_R=round(float(sun_n[1]/sun_n[0]),3),new_B_R=round(float(sun_n[2]/sun_n[0]),3),
   new_over_old=[round(float(a/b),2) for a,b in zip(sun_n,sun_o)])
# ожидаемый физический цвет: спектральное отношение x цвет дневного солнца в игре
base=lin(WS*light_at(35)['sun_color'])*WE
exp_sun=base*spectral_T(EL,Y,ext,TOP_H)/trs
exp_sun_oz=base*spectral_T(EL,Y,ext,TOP_H,ozone=True)/trs
def to8(c):  # цвет света без тонмаппера: нормировка по максимальному каналу = 235
    c=np.asarray(c,float); c=c/c.max()*0.83; return [int(round(float(255*(12.92*v if v<=0.0031308 else 1.055*v**(1/2.4)-0.055)))) for v in c]
out['expected_rgb']=dict(sun_l_linear=[round(float(v),3) for v in exp_sun],G_R=round(float(exp_sun[1]/exp_sun[0]),3),B_R=round(float(exp_sun[2]/exp_sun[0]),3),
   srgb8_color_only=to8(exp_sun),G_R_with_ozone=round(float(exp_sun_oz[1]/exp_sun_oz[0]),3),B_R_with_ozone=round(float(exp_sun_oz[2]/exp_sun_oz[0]),3),
   note='цвет прямого света на облаке над дымкой при солнце 5,7° (спектр): оранжево-жёлтый; srgb8 - только оттенок (макс. канал 211), без яркости')
# 3. цепочка до кадра + абляции
cases=[]; meta=[]
sky_k=l['sky_energy']; tint=l['tint']
for cos in (0.95,0.9,0.7,0.3):
    for b in (1.25,0.6):
        for name,fn in (
          ('old',lambda c,b_:cloud_rad(sun_o,b_,c,powder=0.8)),
          ('new',lambda c,b_:cloud_rad(sun_n,b_,c,powder=0.8)),
          ('new_no_fog_amb',lambda c,b_:cloud_rad(sun_n,b_,c,powder=0.8,amb=AMB*0,fogc=FOGC*0)),
          ('new_fog_amb_scaled',lambda c,b_:cloud_rad(sun_n,b_,c,powder=0.8,amb=AMB*sky_k*tint,fogc=FOGC*sky_k*tint)),
          ('new_limited',None)):
            if fn is None:
                rad=cloud_rad(sun_n,b,cos,powder=0.8,amb=AMB*sky_k*tint,fogc=FOGC*sky_k*tint)
                m=rad.max(); rad=rad*min(1.0,2.5/m)   # F2: сохранение оттенка - общий масштаб, макс. канал <= 2.5
            else: rad=fn(cos,b)
            cases.append(rad); meta.append((name,cos,b))
png=probe(cases,False,'c')
chain=[]
for (n,c,b),h,o in zip(meta,cases,png):
    ol=lin(o); chain.append(dict(model=n,cos_t=c,beer=b,hdr=[round(float(v),2) for v in h],srgb8=o,G_R=round(float(ol[1]/ol[0]),2),B_R=round(float(ol[2]/ol[0]),2),R_minus_B=o[0]-o[2]))
out['chain']=chain
# 4. запас тонмаппера: цвет света (1, G/R, B/R) x s
d=np.array([1.0,exp_sun[1]/exp_sun[0],exp_sun[2]/exp_sun[0]])
ss=[0.25,0.5,1,1.5,2,3,4,6,8]
pr=probe([d*s for s in ss],False,'d')
head=[]
for s,o in zip(ss,pr):
    ol=lin(o); head.append(dict(scale_R=s,srgb8=o,G_R=round(float(ol[1]/max(ol[0],1e-6)),2),B_R=round(float(ol[2]/max(ol[0],1e-6)),2),R_minus_B=o[0]-o[2]))
out['tonemap_headroom']=dict(light_dir=[round(float(v),3) for v in d],rows=head,note='AgX, exposure 1.1, white 6, saturation 1.08, contrast 1.04: оттенок света (G/R, B/R) на выходе при масштабе яркости R')
json.dump(out,open('/tmp/claude-1000/analysis.json','w'),ensure_ascii=False,indent=1)
print(json.dumps(out['sun_l'],ensure_ascii=False)); print(json.dumps(out['expected_rgb'],ensure_ascii=False))
for r in head: print(r)
for r in chain: print(r)
