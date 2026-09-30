"""Профили мачт ISFS (5 мин) для выбранных случаев -> cases/<case>_5min.csv и cases/<case>_hourmean.csv"""
import netCDF4 as n,numpy as np,csv,re,os,datetime as dt
H=os.path.dirname(os.path.abspath(__file__))+'/..'
CASES={'ne_20170427':('20170427',16,20),'sw_20170511':('20170511',8,12)}
def arr(V,k):
    a=np.ma.filled(V[k][:].astype(float),np.nan); a[a<-900]=np.nan; return a
for name,(day,h0,h1) in CASES.items():
    V=n.Dataset(f'{H}/raw/isfs5/isfs_qc_tiltcor_{day}.nc').variables
    t0=dt.datetime.strptime(day,'%Y%m%d')
    keys=sorted({(m.group(2),int(m.group(1))) for k in V for m in [re.match(r'spd_(\d+)m_(\w+)$',k)] if m and m.group(2).startswith(('tse','rsw','rne','v0'))})
    out=[];hm=[]
    for site,z in keys:
        s=f'{z}m_{site}'
        if f'u_u__{s}' not in V: continue
        g=lambda p:arr(V,p+s) if p+s in V else np.full(288,np.nan)
        u,v,w,uu,vv,ww,wt,uw,vw,spd,dr,tc=[g(p) for p in ('u_','v_','w_','u_u__','v_v__','w_w__','w_tc__','u_w__','v_w__','spd_','dir_','tc_')]
        tke=0.5*(uu+vv+ww); ust=(uw**2+vw**2)**.25
        i0,i1=h0*12,h1*12
        for i in range(i0,i1):
            out.append([ (t0+dt.timedelta(minutes=5*i)).strftime('%Y-%m-%dT%H:%M'),site,z]+[None if np.isnan(x[i]) else round(float(x[i]),4) for x in (spd,dr,u,v,w,tke,ust,wt,tc)])
        # среднее за окно (случай: центральные 2 ч для ne, 1 ч для sw)
        a,b=(17*12,19*12) if name.startswith('ne') else (10*12,11*12)
        f=lambda x: None if np.all(np.isnan(x[a:b])) else round(float(np.nanmean(x[a:b])),4)
        hm.append([site,z,f(spd),f(dr),f(w),f(tke),f(ust),f(wt),f(tc),int(np.sum(~np.isnan(spd[a:b])))])
    w_=csv.writer(open(f'{H}/cases/{name}_5min.csv','w')); w_.writerow('time_utc,site,z_agl_m,spd,dir_deg,u_east,v_north,w,tke,ustar,wtc_flux,tc_degC'.split(',')); w_.writerows(out)
    w_=csv.writer(open(f'{H}/cases/{name}_windowmean.csv','w')); w_.writerow('site,z_agl_m,spd,dir_deg,w,tke,ustar,wtc_flux,tc_degC,n_5min'.split(',')); w_.writerows(hm)
    print(name,len(out),len(hm))
