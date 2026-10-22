"""Цвет облачных пикселей по frames/*.png -> ablation_stats.json. Маска облаков = |base - no_clouds| > 25 (по каналу, sRGB 8 бит),
внутри маски - все пиксели и 25 % самых ярких ("освещённые бока"). Одна и та же маска для всех вариантов."""
import subprocess, glob, os, json, numpy as np
D=os.path.dirname(os.path.abspath(__file__))
def lin(c):
    c=np.asarray(c,float)/255; return np.where(c<=0.04045,c/12.92,((c+0.055)/1.055)**2.4)
def stat(a):
    L=a.mean(1); lit=L>=np.percentile(L,75); out={}
    for n,m in (('all',slice(None)),('lit25',lit),('top5',L>=np.percentile(L,95)),('top1',L>=np.percentile(L,99))):
        c=a[m].mean(0); lc=lin(c); out[n]=dict(srgb8=[int(round(v)) for v in c],G_R=round(float(lc[1]/lc[0]),2),B_R=round(float(lc[2]/lc[0]),2),R_minus_B=int(round(c[0]-c[2])))
    out['frac_pixels_ge250']=round(float((a.max(1)>=250).mean()),4); return out
def load(f):
    w,h=map(int,subprocess.run(['identify','-format','%w %h',f],capture_output=True,text=True).stdout.split())
    raw=subprocess.run(['convert',f,'-alpha','off','-depth','8','rgb:-'],capture_output=True).stdout
    return np.frombuffer(raw,np.uint8).reshape(h,w,3).astype(float)
import re,collections
files=collections.defaultdict(dict)
for f in glob.glob(D+'/frames/*.png'):
    n=os.path.basename(f)[:-4]; v,_,sc=n.partition('__'); files[sc or 'el5.7_sun'][v]=f
res={'mask_rule':'|variant base - no_clouds|>25 по каналу (sRGB 8 бит); lit25 = 25 % самых ярких пикселей маски; кадры только шириной 1918'}
for sc,d in sorted(files.items()):
    if 'base' not in d or 'no_clouds' not in d: continue
    base=load(d['base']); bg=load(d['no_clouds'])
    if base.shape!=bg.shape: continue
    mask=(np.abs(base-bg).max(2)>25); r={'mask_fraction':round(float(mask.mean()),4),'background_under_mask':stat(bg[mask])}
    for v,f in sorted(d.items()):
        if v=='no_clouds': continue
        a=load(f)
        if a.shape!=base.shape: continue
        r[v]=stat(a[mask])
    res[sc]=r
json.dump(res,open(D+'/ablation_stats.json','w'),indent=1)
for sc,r in res.items():
    if not isinstance(r,dict) or 'mask_fraction' not in r: continue
    print(sc,'mask',r['mask_fraction'])
    for v,x in r.items():
        if isinstance(x,dict) and 'all' in x: print('  ',v,'all',x['all']['srgb8'],x['all']['G_R'],x['all']['B_R'],'lit',x['lit25']['srgb8'],x['lit25']['G_R'],x['lit25']['B_R'],'top1',x['top1']['srgb8'],x['top1']['G_R'],x['top1']['B_R'],'>=250',x['frac_pixels_ge250'])
