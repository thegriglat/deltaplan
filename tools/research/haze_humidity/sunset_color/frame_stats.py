"""Цвет самых ярких пикселей облачной полосы кадров до/после (rows 150..520 из 1036). Вход: jpg из build/screenshots/haze-humidity."""
import subprocess, numpy as np, json
D='/home/greg/deltaplan/build/screenshots/haze-humidity/'
def lin(c):
    c=np.asarray(c,float)/255; return np.where(c<=0.04045,c/12.92,((c+0.055)/1.055)**2.4)
res={}
for n in ('before','after'):
    raw=subprocess.run(['convert',D+f'{n}_sunset_altai.jpg','-depth','8','rgb:-'],capture_output=True).stdout
    a=np.frombuffer(raw,np.uint8).reshape(1036,1918,3).astype(float)[150:520]
    L=a.mean(2)
    for q in (80,95,99):
        m=L>=np.percentile(L,q); c=a[m].mean(0); lc=lin(c)
        res[f'{n}_top{100-q}pct']=dict(srgb8=[int(round(v)) for v in c],G_R=round(float(lc[1]/lc[0]),2),B_R=round(float(lc[2]/lc[0]),2),R_minus_B=int(round(c[0]-c[2])))
json.dump(res,open('frame_stats.json','w'),indent=1)
for k,v in res.items(): print(k,v)
