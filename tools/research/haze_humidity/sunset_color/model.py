"""Порт SunTransmission (scripts/atmosphere/sun_transmission.gd) и света облака cloud_light (cloud_common.gdshaderinc)."""
import numpy as np, json, math
R=6371000.0; H=8000.0; BR=1.16e-5; WL=(680.,550.,440.); TOP=100000.0
EXT_RGB=(0.85,1.0,1.2)
def ir_int(r0,sin_e,s0,s1,n=4000):
    u=np.linspace(0,1,n+1); s=s0+(s1-s0)*u*u
    r=np.sqrt(r0*r0+2*r0*sin_e*s+s*s)
    f=np.exp(-(r-R)/H)*2*u
    return abs(s1-s0)*np.trapz(f,u)
def tau(el_deg,h,ext550,haze_top,rgb=EXT_RGB):
    r0=R+h; e=math.radians(el_deg); se,ce=math.sin(e),math.cos(e); b=r0*ce
    if se<0 and b<R: return None
    s_exit=-r0*se+math.sqrt((R+TOP)**2-b*b)
    if se<0:
        sp=-r0*se; ir=ir_int(r0,se,sp,0)+ir_int(r0,se,sp,s_exit)
    else: ir=ir_int(r0,se,0,s_exit)
    ih=0
    rt=R+haze_top; dd=rt*rt-b*b
    if ext550>0 and dd>0:
        sq=math.sqrt(dd); si=max(-r0*se-sq,0); so=-r0*se+sq
        ih=max(so-si,0)
    t=[]
    for lam,k in zip(WL,rgb):
        t.append(BR*(550/lam)**4*ir+ext550*k*ih)
    return np.array(t),ir,ih
def T(el,h,ext,top):
    r=tau(el,h,ext,top)
    return np.zeros(3) if r is None else np.exp(-r[0])
