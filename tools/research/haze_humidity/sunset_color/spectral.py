"""Независимая проверка таблицы HH4: спектральный интеграл (Wyman 2013 — аналитический фит CIE 1931) для света солнца."""
import numpy as np, math
from model import tau, R, H, BR, TOP
lam=np.arange(380,781,5.0)
def g(x,mu,s1,s2): s=np.where(x<mu,s1,s2); return np.exp(-0.5*((x-mu)/s)**2)
def cie(l):
    x=1.056*g(l,599.8,37.9,31.0)+0.362*g(l,442.0,16.0,26.7)-0.065*g(l,501.1,20.4,26.2)
    y=0.821*g(l,568.8,46.9,40.5)+0.286*g(l,530.9,16.3,31.1)
    z=1.217*g(l,437.0,11.8,36.0)+0.681*g(l,459.0,26.0,13.8)
    return x,y,z
M=np.array([[3.2406,-1.5372,-0.4986],[-0.9689,1.8758,0.0415],[0.0557,-0.2040,1.0570]])
def planck(l,T=5778.0):
    l=l*1e-9; return 1/(l**5*(np.exp(1.4388e-2/(l*T))-1))
def rgb_of(S):
    x,y,z=cie(lam); XYZ=np.array([np.sum(S*x),np.sum(S*y),np.sum(S*z)]); return M@XYZ
TOA=planck(lam)
WHITE=rgb_of(TOA)
def spectral_T(el,h,ext550,haze_top,alpha=0.8,rayl_exp=4.08,ozone=False,ozone_du=300.0):
    r=tau(el,h,ext550,haze_top)
    if r is None: return np.zeros(3)
    _,ir,ih=r
    t=BR*(550/lam)**rayl_exp*ir+ext550*(550/lam)**alpha*ih
    if ozone:
        # приближённо: Chappuis, пик 5.0e-21 см² при 603 нм, гауссиана σ=40 нм (грубо, без таблицы сечений); столб 300 DU = 8.06e18 см⁻²;
        # слой ~ 25 км: воздушная масса озона по хорде сферы 25 км
        sig=5.0e-21*np.exp(-0.5*((lam-603)/40)**2)
        col=ozone_du*2.687e16
        e=math.radians(el); am=1/max(math.sin(e)+0.1*(e+0.0)**0 *0+1e-9,1e-3) if el>0 else 40
        # Kasten-Young-подобная воздушная масса для слоя 22 км
        r0=R+22000; ce=math.cos(e); am=1/math.sqrt(1-(R*ce/r0)**2) if el>=0 else 40
        t=t+sig*col*am
    S=TOA*np.exp(-t)
    return rgb_of(S)/WHITE
