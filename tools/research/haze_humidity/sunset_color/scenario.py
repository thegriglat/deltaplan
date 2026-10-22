import sys, json, math, numpy as np
sys.path.insert(0,'.')
from model import *
def lin(c):
    c=np.asarray(c,float); return np.where(c<=0.04045,c/12.92,((c+0.055)/1.055)**2.4)
def lerp_tab(xs,ys,x):
    ys=np.asarray(ys,float); xs=np.asarray(xs,float)
    if x<=xs[0]: return ys[0]
    if x>=xs[-1]: return ys[-1]
    i=np.searchsorted(xs,x)-1; f=(x-xs[i])/(xs[i+1]-xs[i]); return ys[i]*(1-f)+ys[i+1]*f
W=json.load(open('/home/greg/deltaplan-haze-humidity-HH-12/configs/world.json'))
L=W['time']['light']
def light_at(el):
    return dict(sun_color=np.array([lerp_tab(L['elevation_deg'],[c[i] for c in L['sun_color']],el) for i in range(3)]),
      sun_energy=float(lerp_tab(L['elevation_deg'],L['sun_energy'],el)), sky_energy=float(lerp_tab(L['elevation_deg'],L['sky_energy'],el)),
      tint=np.array([lerp_tab(L['elevation_deg'],[c[i] for c in L['horizon_tint']],el) for i in range(3)]))
def hg(c,g): g2=g*g; return (1-g2)/(4*math.pi*max(1+g2-2*g*c,1e-4)**1.5)
def phase(c,fwd=0.6,back=-0.2,mix=0.25,silver=1.4): return (hg(c,fwd)*silver*(1-mix)+hg(c,back)*mix)*4*math.pi
WS=np.array(W['sun']['color']); WE=W['sun']['energy']
def sun_old(el, ins=1.0):
    l=light_at(el); col=lin(WS*l['sun_color']); return col*WE*l['sun_energy']*ins
def sun_new(el,y,k,valley,haze_top,ins=1.0,vis=60.0):
    ext=3.912/(vis*1000)*k
    t=T(el,y,ext,haze_top); tr=T(35,valley,ext,haze_top)
    base=lin(WS*light_at(35)['sun_color'])*WE*light_at(35)['sun_energy']
    return base*t/tr*ins
AMB=np.array([0.55,0.68,0.95])*0.5
FOGC=lin(np.array([0.66,0.74,0.86]))
def cloud_rad(sun_l,beer_,cos_t,powder=1.0,amb=AMB,fogc=FOGC,dist=8000.0,fog_density=4e-5,ph=None):
    p=phase(cos_t) if ph is None else ph
    c=sun_l*beer_*p*powder+amb
    fog=1-math.exp(-dist*fog_density)
    fc=fogc*(1+0.35*max(cos_t,0)**8)
    return c*(1-fog)+fc*fog
