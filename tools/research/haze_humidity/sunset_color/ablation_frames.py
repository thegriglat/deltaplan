"""Абляции света облаков в настоящем кадре (Алтай, закат 20:40, как tools/shots/haze_humidity_shots.sh): правки только через
user://configs профиля копии (глубокое слияние), код игры не трогается. Результат: frames/<вариант>.png (локально, > 1 МБ - не коммитить)
и ablation_stats.json (цвет самых ярких пикселей полосы облаков). Запуск: python3 ablation_frames.py [вариант ...]"""
import json, os, subprocess, sys, shutil, numpy as np
ROOT=os.path.abspath(os.path.join(os.path.dirname(__file__),'../../../..'))
XDG=os.path.expanduser('~/.cache/dp-xdg/'+os.path.basename(ROOT))
CFG=XDG+'/Deltaplan/configs'
OUT=os.path.join(os.path.dirname(os.path.abspath(__file__)),'frames')
sky_k=0.6233; tint=np.array([1.10683,0.92466,0.877])
def l2s(c): c=np.clip(c,0,1); return np.where(c<=0.0031308,12.92*c,1.055*c**(1/2.4)-0.055)
def s2l(c): c=np.asarray(c,float); return np.where(c<=0.04045,c/12.92,((c+0.055)/1.055)**2.4)
fog_s=[round(float(v),4) for v in l2s(s2l([0.66,0.74,0.86])*sky_k*tint)]
amb_t=[round(float(v),4) for v in np.array([0.55,0.68,0.95])*tint]; amb_b=[round(float(v),4) for v in np.array([0.34,0.35,0.37])*tint]
F1={'ambient_top':amb_t,'ambient_bottom':amb_b,'ambient_energy':round(0.5*sky_k,4),'fog_color_fallback':fog_s}
V={'base':({},{}),
 'old_light':({'clouds':{'sun_transmission':{'enabled':False}}},{}),
 'no_fog':({'clouds':{'fog_density_fallback':0.0}},{}),
 'no_ambient':({'clouds':{'ambient_energy':0.0}},{}),
 'F1':({'clouds':F1},{}),
 'F1_F3':({'clouds':F1},{'sun':{'energy':round(1.2*sky_k,4)}}),
 'sun_x0.3':({},{'sun':{'energy':0.36}}),
 'sun_x0.1':({},{'sun':{'energy':0.12}}),
 'sunonly_x0.3':({'clouds':{'fog_density_fallback':0.0,'ambient_energy':0.0}},{'sun':{'energy':0.36}}),
 'sunonly_x0.1':({'clouds':{'fog_density_fallback':0.0,'ambient_energy':0.0}},{'sun':{'energy':0.12}}),
 'sunonly_old':({'clouds':{'fog_density_fallback':0.0,'ambient_energy':0.0,'sun_transmission':{'enabled':False}}},{}),
 'no_clouds':({'clouds':{'enabled':False}},{}),
 'sun_only':({'clouds':{'fog_density_fallback':0.0,'ambient_energy':0.0}},{}),
}
SUN_AZ_EL='-22.2,5.67'   # из таблицы условий кадров HH-10 (Алтай, sinyukha_west, 20:40)
def run(name,tag='',hour=20,tmin=40,look=SUN_AZ_EL):
    atm,wor=V[name]
    os.makedirs(CFG,exist_ok=True); os.makedirs(OUT,exist_ok=True)
    wor=dict(wor); wor.setdefault('time',{})['speed']=60
    bk={}
    for n,d in (('atmosphere',atm),('world',wor)):
        p=f'{CFG}/{n}.json'; bk[p]=open(p).read() if os.path.exists(p) else None
        if d: json.dump(d,open(p,'w'))
        elif os.path.exists(p): os.remove(p)
    png=f'{OUT}/{name}{tag}.png'
    try:
        for _try in range(5):
            if os.path.exists(png): os.remove(png)
            cmd=['timeout','150','godot','--path',ROOT,'--audio-driver','Dummy','--fullscreen','--resolution','1920x1080','--',
              '--autostart','--autopilot','--no-overlay','--sky=partly','--camera=cockpit','--seed=7','--location=altai','--site=sinyukha_west',
              f'--hour={hour}',f'--time={tmin}','--look='+look,'--screenshot='+png]
            subprocess.run([ROOT+'/.dpcli/dpcli','lock','gpu','hh12a','--']+cmd,cwd=ROOT,env=dict(os.environ,XDG_DATA_HOME=XDG,DISPLAY=':0'),capture_output=True)
            import time
            for _ in range(200):
                if os.path.exists(png) and os.path.getsize(png)>0: break
                time.sleep(1)
            if os.path.exists(png) and subprocess.run(['identify','-format','%w','%s'%png],capture_output=True,text=True).stdout.strip()=='1918': break
    finally:
        for p,t in bk.items():
            if t is None:
                if os.path.exists(p): os.remove(p)
            else: open(p,'w').write(t)
    return png
SCEN={'el2_sun':(21,7.6,'-27.5,2.0'),'el2_side':(21,7.6,'47.5,8'),'el2_back':(21,7.6,'152.5,8'),
      'el08_sun':(21,17.0,'-29.3,0.8'),'el08_side':(21,17.0,'45.7,8'),'el08_back':(21,17.0,'150.7,8')}
if __name__=='__main__' and sys.argv[1:2]==['scen']:
    for sc in sys.argv[2].split(','):
        for n in sys.argv[3].split(','): print(n,sc,run(n,'__'+sc,*SCEN[sc]),flush=True)
    sys.exit(0)
if __name__=='__main__':
    for n in (sys.argv[1:] or list(V)): print(n,run(n),flush=True)
