"""TP-17: потолок скорости в горизонте по тяге винта (configs/tow_tug.json thrust) и поляре крыла
(configs/wings/trike_ixess15.json polar, эталон 315,5 кг; пересчёт на массу m по V ~ sqrt(m/m_ref), sink ~ sqrt)."""
import json, math
tug = json.load(open('../../../configs/tow_tug.json'))
w = json.load(open('../../../configs/wings/trike_ixess15.json'))
pts = w['polar']['points_kmh_ms']
Vp = [p[0]/3.6 for p in pts]; Sp = [p[1] for p in pts]
th = tug['thrust']; cda = tug['cart']['cda_m2']; rho = 1.225
def interp(xs, ys, x):
    if x <= xs[0]: return ys[0]
    for i in range(1, len(xs)):
        if x <= xs[i]:
            f = (x-xs[i-1])/(xs[i]-xs[i-1]); return ys[i-1]+f*(ys[i]-ys[i-1])
    return ys[-1] + (x-xs[-1])*(ys[-1]-ys[-2])/(xs[-1]-xs[-2])
def wing_drag(V, m):
    k = math.sqrt(m/315.5)
    s = interp(Vp, Sp, V/k)*k  # то же CL -> V~sqrt(m), D/W не меняется: sink ~ V*D/W
    return s*m*9.81/V
out = []
for m in (272.25+53, 262.5+53):
    for g in (1.0,):
        res = []
        for v in [x*0.5 for x in range(20, 80)]:
            T = interp(th['v_ms'], th['idle_n'], v) + g*(interp(th['v_ms'], th['full_n'], v)-interp(th['v_ms'], th['idle_n'], v))
            D = wing_drag(v, m) + 0.5*rho*cda*v*v
            res.append((v, T, D))
        vmax = max(v for v,T,D in res if T >= D)
        # потребная тяга на 130 км/ч, 110, 100
        need = {}
        for kmh in (100, 110, 120, 130):
            v = kmh/3.6
            T = interp(th['v_ms'], th['full_n'], v)
            need[kmh] = {"D_N": round(wing_drag(v, m)+0.5*rho*cda*v*v), "T_full_N": round(T)}
        out.append({"mass_kg": m, "vmax_level_full_throttle_kmh": round(vmax*3.6, 1), "need": need})
        # газ для горизонта на 70, 100
json.dump(out, open('level_speed.json', 'w'), ensure_ascii=False, indent=1)
print(json.dumps(out, ensure_ascii=False, indent=1))
