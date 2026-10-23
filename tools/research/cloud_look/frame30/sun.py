#!/usr/bin/env python3
"""CLK-7: высота солнца кадра 30 (Эльбрус 43.245, 42.51; 15 июля, пояс UTC+3) — зеркало SunClock.solar_position (scripts/world/sun_clock.gd).
    python3 sun.py [час ...]"""
import math, sys
def el(lat, lon, doy, h, utc):
    g = 2*math.pi/365*(doy-1+(h-12)/24)
    d = .006918-.399912*math.cos(g)+.070257*math.sin(g)-.006758*math.cos(2*g)+.000907*math.sin(2*g)-.002697*math.cos(3*g)+.00148*math.sin(3*g)
    eot = 229.18*(.000075+.001868*math.cos(g)-.032077*math.sin(g)-.014615*math.cos(2*g)-.040849*math.sin(2*g))
    sh = h+(4*lon-60*utc+eot)/60
    ha = math.radians(15*(sh-12)); la = math.radians(lat)
    return math.degrees(math.asin(math.sin(la)*math.sin(d)+math.cos(la)*math.cos(d)*math.cos(ha)))
doy = 31+28+31+30+31+30+15
for h in ([float(a) for a in sys.argv[1:]] or [19.4, 19.5, 19.6, 19.7, 19.8, 20.0, 20.4]):
    print("%.2f %.3f" % (h, el(43.245, 42.51, doy, h, 3)))
