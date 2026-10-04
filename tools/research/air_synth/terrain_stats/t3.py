import numpy as np, time, fastscape_gen as g, stats
p=dict(n=512,dx=100.0,U0=1e-4,K=2e-6,m=0.45,D=0.01,Sc=np.tan(np.radians(30)),T=2e6,dt=2e4,
       n_ridges=2,strike_deg=90,ridge_H=(0.5,1),ridge_L_km=(15,30),ridge_sigma_km=(4,8),n_blobs=3,fourier_amp=0.05)
r=g.gen(p,1,verbose=True); print(r['seconds'])
z=r['z100']; print(z.min(),z.max(), stats.slope_stats(z,100.0))
