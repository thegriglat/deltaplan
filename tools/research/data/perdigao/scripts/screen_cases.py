"""Отбор 1-часовых окон: ветер поперёк гряд, около-нейтрально, умеренная скорость. Вход: raw/isfs5/isfs_qc*.nc"""
import glob,netCDF4 as n,numpy as np,csv,sys,os
os.chdir(os.path.dirname(os.path.abspath(__file__))+'/../raw/isfs5')
rows=[]
def g(V,k):
    if k not in V: return np.full(288,np.nan)
    a=np.ma.filled(V[k][:].astype(float),np.nan); a[a<-900]=np.nan; return a
for f in sorted(glob.glob('isfs_qc*.nc')):
    d=n.Dataset(f); V=d.variables; day=f[-11:-3]
    if not '20170320'<=day<='20170715': continue
    N=len(V['time'][:]); 
    if N!=288: continue
    sp=g(V,'spd_100m_tse04'); di=g(V,'dir_100m_tse04'); tc=g(V,'tc_100m_tse04'); tc10=g(V,'tc_10m_tse04'); s10=g(V,'spd_10m_tse04')
    ww=g(V,'w_tc__100m_tse04'); uw=g(V,'u_w__100m_tse04'); vw=g(V,'v_w__100m_tse04')
    ust=(uw**2+vw**2)**.25
    T=tc+273.15
    L=-ust**3*T/(0.4*9.81*ww)
    zL=100/L
    dth=tc-tc10+0.0098*90
    Ri=9.81/T*dth*90/np.maximum(sp-s10,0.5)**2
    lee=[g(V,k) for k in ('spd_60m_tse06','spd_100m_tse09','spd_20m_tse07','spd_20m_tse08')]
    for i0 in range(0,288-11,12):
        s=slice(i0,i0+12)
        dd=di[s]; 
        if np.isnan(dd).any() or np.isnan(sp[s]).any(): continue
        m=np.degrees(np.angle(np.mean(np.exp(1j*np.radians(dd)))))%360
        rows.append(dict(day=day,hour=i0//12,dir=round(m,0),U100=round(np.mean(sp[s]),1),zL=round(np.nanmean(zL[s]),3),Ri=round(np.nanmean(Ri[s]),3),
          lee_valid=int(all((~np.isnan(x[s])).all() for x in lee))))
w=csv.DictWriter(open('../../screen_all_hours.csv','w'),rows[0].keys()); w.writeheader(); w.writerows(rows)
sel=[r for r in rows if (214<=r['dir']<=254 or 34<=r['dir']<=74) and 5<=r['U100']<=12 and abs(r['zL'])<0.1 and abs(r['Ri'])<0.05 and r['lee_valid']]
w=csv.DictWriter(open('../../screen_candidates.csv','w'),rows[0].keys()); w.writeheader(); w.writerows(sel)
print(len(rows),len(sel))
for r in sel: print(r)
