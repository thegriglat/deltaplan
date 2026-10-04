import numpy as np
from multiprocessing import Pool
import fastscape_gen as g, compare
base=dict(n=512,dx=100.0,m=0.45,T=4e6,dt=5e4,n_ridges=3,strike_deg=70,strike_spread_deg=40,ridge_H=(0.5,1),ridge_L_km=(10,25),
          ridge_sigma_km=(3,6),n_blobs=10,blob_sigma_km=(1.5,4),blob_H=(0.1,0.5),fourier_amp=0.3,K_logsd=0.7,Sc=np.tan(np.radians(35)),U0=1e-3)
def run(a):
    U0,K,D,fa=a; p=dict(base,U0=U0,K=K,D=D,fourier_amp=fa); r=g.gen(p,5)
    m=compare.metrics(r['z100'],r['z400']); return a,r['seconds'],compare.row(m)
if __name__=="__main__":
    grid=[(u,k,d,fa) for u in (5e-4,1e-3) for k in (5e-6,2e-5) for d in (0.03,0.3) for fa in (0.3,)]
    with Pool(8) as pool:
        for a,s,row in pool.imap(run,grid):
            print(a,f"{s:.0f}s",[round(float(x),2) for x in row],flush=True)
