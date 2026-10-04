import sys, json, numpy as np, itertools
from multiprocessing import Pool
import fastscape_gen as g, compare
base=dict(n=512,dx=100.0,m=0.45,T=4e6,dt=5e4,n_ridges=2,strike_deg=170,strike_spread_deg=10,ridge_H=(0.5,1),ridge_L_km=(15,30),
          ridge_sigma_km=(4,8),n_blobs=3,fourier_amp=0.05,Sc=np.tan(np.radians(35)),U0=2e-4)
def run(a):
    K,D,fa,kl=a; p=dict(base,K=K,D=D,fourier_amp=fa,K_logsd=kl); r=g.gen(p,3)
    m=compare.metrics(r['z100'],r['z400']); return a,r['seconds'],compare.row(m)
if __name__=="__main__":
    grid=[(4e-6,d,fa,kl) for d in (0.003,0.03) for fa in (0.05,0.3) for kl in (0,0.5,1.0)]
    with Pool(9) as pool:
        for a,s,row in pool.imap(run,grid):
            print(a,f"{s:.0f}s",[round(float(x),2) for x in row],flush=True)
