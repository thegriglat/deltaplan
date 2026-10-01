"""Композит RHI: среднее лучевой скорости (CNR > -27 дБ) по всем сканам файлов -> cases/rhi_<case>_<WS>.npz + png.
Знак: по e-WindLidar comment (см. README). x — расстояние вдоль луча в горизонтали от лidара, z — высота над лidаром."""
import netCDF4 as n,numpy as np,glob,sys,os
import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot as plt
H=os.path.dirname(os.path.abspath(__file__))+'/..'
def comp(files):
    S=None
    for f in files:
        d=n.Dataset(f);V=d.variables
        el=np.round(np.ma.filled(V['elevation_angle'][:],np.nan),2); vel=np.ma.filled(V['VEL'][:],np.nan); cnr=np.ma.filled(V['CNR'][:],np.nan)
        vel=np.where(cnr>-27,vel,np.nan); r=np.array(V['range'][:],float)
        if S is None: ue=np.unique(el); s=np.zeros((len(ue),len(r))); s2=s.copy(); c=s.copy(); az=float(V['azimuth_angle'][:]); pos=[float(V[k][:]) for k in('position_x','position_y','position_z')]
        for i,e in enumerate(ue):
            m=el==e; x=vel[m]; ok=~np.isnan(x); s[i]+=np.where(ok,x,0).sum(0); s2[i]+=(np.where(ok,x,0)**2).sum(0); c[i]+=ok.sum(0)
        S=1
    mean=np.where(c>0,s/np.maximum(c,1),np.nan); std=np.sqrt(np.maximum(s2/np.maximum(c,1)-mean**2,0)); return ue,r,mean,std,c,az,pos
def run(case,ws,pattern):
    files=sorted(glob.glob(f'{H}/raw/dtu/transect/{ws}/{pattern}'))
    ue,r,m,sd,c,az,pos=comp(files)
    m[c<20]=np.nan
    X=r[None,:]*np.cos(np.radians(ue))[:,None]; Z=r[None,:]*np.sin(np.radians(ue))[:,None]
    np.savez_compressed(f'{H}/cases/rhi_{case}_{ws}.npz',elev_deg=ue,range_m=r,vel_mean=m.astype(np.float32),vel_std=sd.astype(np.float32),count=c.astype(np.int16),azimuth_deg=az,lidar_xyz_pt_tm06=pos,files=[os.path.basename(f) for f in files])
    fig,ax=plt.subplots(figsize=(9,3.6)); q=ax.pcolormesh(X,Z,m,cmap='RdBu_r',vmin=-12,vmax=12,shading='auto'); ax.set_aspect('equal'); ax.set_xlabel('расстояние по горизонтали от лидара, м'); ax.set_ylabel('высота над лидаром, м'); ax.set_title(f'{case} {ws}: средняя лучевая скорость, {len(files)} файлов, аз. {az:.0f}°'); plt.colorbar(q,label='м/с'); fig.tight_layout(); fig.savefig(f'{H}/cases/rhi_{case}_{ws}.png',dpi=110); plt.close()
    print(case,ws,len(files),np.nanmin(m),np.nanmax(m))
run('ne_20170427','WS3','2017042717*.nc') if False else None
for ws in ('WS3','WS1'):
    run('ne_20170427',ws,'20170427[1][78]*.nc')
for ws in ('WS3','WS1'):
    run('sw_20170511',ws,'2017051109*.nc')
for ws in ('WS5','WS6'):
    run('sw_20170511',ws,'2017051110*.nc')
