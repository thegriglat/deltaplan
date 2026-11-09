import json, sys, numpy as np, math
P=sys.argv[1]
res={}
for name in sys.argv[2:]:
    m=json.load(open(f"{P}/{name}.json")); g=m["grid"]; w,h=g["width"],g["height"]; s=g["spacing"]
    raw=np.fromfile(f"{P}/{name}.bin",dtype="<i2",count=w*h).reshape(h,w)
    z=raw.astype(np.float64)*m["h_scale"]+m["h_offset"]
    xhi=g["origin_x"]+(w-1)*s; zhi=g["origin_z"]+(h-1)*s
    fit=min(-g["origin_x"],xhi,-g["origin_z"],zhi)-2*s
    half=min(fit,19200.0); n=int(math.floor(2*half/1200))*3
    side=n*400; i0=int(round((-side/2-g["origin_x"])/s))
    o={"n400":n}
    for dx,fac,nn,dz in ((400,16,n,105.0),(1200,48,n//3,105.0)):
        sub=z[i0:i0+fac*nn+1,i0:i0+fac*nn+1]
        r=sub[:-1,:-1].reshape(nn,fac,nn,fac)
        lo=sub.min(); zb=math.floor(r.mean(axis=(1,3)).min()/dz)*dz-dz
        # cell edges of columns (with shared edge samples) -> use block min/max incl. edge
        mx=np.maximum(r.max(axis=(1,3)), 0); mn=r.min(axis=(1,3))
        k_lo=np.floor((mn-zb)/dz); k_hi=np.floor((mx-zb)/dz)
        layers=(k_hi-k_lo+1)
        o[f"dx{dx}"]={"nx":nn,"mixed_layers_total":int(layers.sum()),"mixed_layers_mean_per_col":round(float(layers.mean()),2),
                      "pt_evals_vf_M":round(float(layers.sum())*17*17/1e6,2),"raster_nodes_M":round((fac*nn+1)**2/1e6,2)}
    res[name]=o
print(json.dumps(res,ensure_ascii=False,indent=1))
