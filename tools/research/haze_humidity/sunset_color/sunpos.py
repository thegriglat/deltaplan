from math import *
def sun(lat,lon,off,h,doy=196):
    g=2*pi/365*(doy-1+(h-12)/24)
    d=(0.006918-0.399912*cos(g)+0.070257*sin(g)-0.006758*cos(2*g)+0.000907*sin(2*g)-0.002697*cos(3*g)+0.00148*sin(3*g))
    e=229.18*(0.000075+0.001868*cos(g)-0.032077*sin(g)-0.014615*cos(2*g)-0.040849*sin(2*g))
    s=h+(4*lon-60*off+e)/60; ha=radians(15*(s-12)); la=radians(lat)
    el=asin(sin(la)*sin(d)+cos(la)*cos(d)*cos(ha)); az=atan2(sin(ha),cos(ha)*sin(la)-tan(d)*cos(la))+pi
    return degrees(az)%360,degrees(el)
if __name__=='__main__':
    lat,lon,off=51.82121,85.85361,7
    for target in (2.0,0.8):
        lo,hi=19.5,22.5
        for _ in range(60):
            m=(lo+hi)/2
            if sun(lat,lon,off,m)[1]>target: lo=m
            else: hi=m
        print(target,round(m,4),sun(lat,lon,off,m))
