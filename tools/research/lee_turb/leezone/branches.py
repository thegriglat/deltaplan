"""Ветви σ_u (то, что возвращает turbulence_intensity_at) по каналам поля — формулы rust/dp-air/src/terms/turb/{sigma,sep,mod}.rs (LTM v1)."""
import math

KAPPA, F_COR, NEUTRAL_BL_K, LAM_FRAC, SURFACE_FRAC = 0.4, 1.13e-4, 0.3, 0.0158, 0.1
CFG = dict(sw_per_ustar=1.25, mix_len=40.0, conv_su=0.6, sep_su=0.166, sep_sv=0.130, sep_sw=0.153,
           wall_off=(0.75, 1.0), bubble_len=2.8, resolved=(4.0, 8.0), turb_max=4.0, rotor_max=7.0)


def smooth(a, b, x):
    if abs(a - b) <= 1e-5 * max(abs(a), 1.0):
        return 0.0 if x <= a else 1.0
    t = min(max((x - a) / (b - a), 0.0), 1.0)
    return t * t * (3 - 2 * t)


def branches(agl, tb, uf, z0, lee_f, relief, u_h, dx):
    """tb = [shear, n2, ustar, u_out, a_out, desc, wstar, hmix]."""
    c = CFG
    shear, n2, ustar, u_out, a_out, desc, wstar, hmix = tb[:8]
    z = max(agl, 1.0)
    h_bl = hmix if hmix > 0 else NEUTRAL_BL_K / F_COR * ustar
    lam = max(c['mix_len'], LAM_FRAC * h_bl)
    decay = max(1 - z / max(h_bl, 1.0), 0.0) ** 0.75
    l_mix = 1 / (1 / (KAPPA * z) + 1 / lam)
    u_wall_top = ustar * decay
    u_loc = KAPPA * uf / math.log(max(z, 2 * z0) / z0)
    sl = smooth(0.5, 1.0, z / max(SURFACE_FRAC * h_bl, 1.0))
    u_wall = u_loc + (u_wall_top - u_loc) * sl
    # вес снятия члена l·|dU/dz| (LTM v1 п.3)
    unres = 1.0
    if dx > 0:
        unres = 1 - smooth(c['resolved'][0], c['resolved'][1], c['bubble_len'] * max(relief, 0.0) / dx)
    w_sep = 0.0
    if lee_f > 0 and relief > 0:
        w_sep = lee_f * unres * (1 - smooth(c['wall_off'][0], c['wall_off'][1], agl / relief))
    u_shear = (1 - w_sep) * l_mix * shear
    u_m = max(u_wall, u_shear)
    stab = 1.0
    if n2 > 0:
        ri = n2 / max(shear * shear, 1e-6)
        stab = 1 + 5 * ri
    u_m /= stab
    h_ft = z / 0.3048
    aniso = 1 / (0.177 + 0.000823 * h_ft) ** 0.4 if h_ft < 1000 else 1.0
    k = c['sw_per_ustar']
    su_wall = k * aniso * u_wall / stab
    su_shear = k * aniso * u_shear / stab
    su_shear_nocut = k * aniso * l_mix * shear / stab
    su_m = k * aniso * u_m
    su_c = 0.0
    if hmix > 0 and z / hmix < 1:
        su_c = c['conv_su'] * wstar
    su_mc = (su_m ** 3 + su_c ** 3) ** (1 / 3)
    du = max(u_h - uf, 0.0) * lee_f
    su_layer = c['sep_su'] * du
    sw_layer = c['sep_sw'] * du
    return dict(u_wall=u_wall, u_shear=u_shear, w_sep=w_sep, unres=unres, aniso=aniso, stab=stab,
                su_wall=su_wall, su_shear=su_shear, su_shear_nocut=su_shear_nocut, su_m=su_m, su_c=su_c,
                su_mc=su_mc, du=du, su_layer=su_layer, sw_layer=sw_layer, su_rec=min(max(su_mc, su_layer), c['turb_max']),
                win='layer' if su_layer > su_mc else ('conv' if su_c > su_m else ('shear' if u_shear > u_wall else 'wall')))
