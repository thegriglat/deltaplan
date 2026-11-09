import json, sys, numpy as np, math
P=sys.argv[1]
for name in sys.argv[2:]:
    m=json.load(open(f"{P}/{name}.json")); g=m["grid"]; w,h=g["width"],g["height"]; s=g["spacing"]
    raw=np.fromfile(f"{P}/{name}.bin",dtype="<i2",count=w*h).reshape(h,w)
    z=raw.astype(np.float64)*m["h_scale"]+m["h_offset"]
    xhi=g["origin_x"]+(w-1)*s; zhi=g["origin_z"]+(h-1)*s
    fit=min(-g["origin_x"],xhi,-g["origin_z"],zhi)-2*s
    half=min(fit,19200.0); f=3
    n=int(math.floor(2*half/1200))*f
    out={"place":name,"grid":[w,h,s],"hmin":float(z.min()),"hmax":float(z.max()),"n400":n}
    if n<12: print(json.dumps(out)); continue
    side=n*400; i0=int(round((-side/2-g["origin_x"])/s))
    for dx,fac,nn in ((400,16,n),(1200,48,n//3)):
        sub=z[i0:i0+fac*nn,i0:i0+fac*nn]
        r=sub.reshape(nn,fac,nn,fac); bm=r.mean(axis=(1,3))
        dz=105.0; lo,hi=bm.min(),bm.max()
        zb=math.floor(lo/dz)*dz-dz
        nz=math.ceil((hi+3000-zb)/dz); nz+=nz%2
        out[f"dx{dx}"]={"nx":nn,"nz":nz,"cells_halo":(nn+2)**2*(nz+2),
          "col_relief_max_m":round(float((r.max(axis=(1,3))-r.min(axis=(1,3))).max()),1),
          "cols_relief_gt_dz":int(((r.max(axis=(1,3))-r.min(axis=(1,3)))>dz).sum())}
    print(json.dumps(out,ensure_ascii=False))
