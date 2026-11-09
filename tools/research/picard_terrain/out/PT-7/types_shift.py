import json, sys, numpy as np, math
P=sys.argv[1]
out={}
for name in sys.argv[2:]:
    m=json.load(open(f"{P}/{name}.json")); g=m["grid"]; w,h=g["width"],g["height"]; s=g["spacing"]
    raw=np.fromfile(f"{P}/{name}.bin",dtype="<i2",count=w*h).reshape(h,w)
    z=raw.astype(np.float64)*m["h_scale"]+m["h_offset"]
    xhi=g["origin_x"]+(w-1)*s; zhi=g["origin_z"]+(h-1)*s
    fit=min(-g["origin_x"],xhi,-g["origin_z"],zhi)-2*s
    half=min(fit,19200.0); n=int(math.floor(2*half/1200))*3
    side=n*400; i0=int(round((-side/2-g["origin_x"])/s))
    res={}
    for dx,fac,nn in ((400,16,n),(1200,48,n//3)):
        dz=105.0
        sub=z[i0:i0+fac*nn+1,i0:i0+fac*nn+1]       # nodes incl. last edge (row index = south->; symmetric stats)
        r=sub[:-1,:-1].reshape(nn,fac,nn,fac); hc=r.mean(axis=(1,3))
        zb=math.floor(hc.min()/dz)*dz-dz
        wt=np.ones(fac+1); wt[0]=wt[-1]=0.5; W=np.outer(wt,wt)/ (fac*fac)
        d_hc=[];dk=[];vf1=[]
        for j in range(nn):
            for i in range(nn):
                blk=sub[j*fac:(j+1)*fac+1, i*fac:(i+1)*fac+1]
                lo=blk.min(); k0=int(math.floor((lo-zb)/dz))
                kk=None
                for k in range(max(k0-1,0),k0+60):
                    top=zb+(k+1)*dz  # cell index k+1 (halo idx) spans [zb+k dz, zb+(k+1)dz]
                    vf=(np.clip((top-blk)/dz,0,1)*W).sum()
                    if vf>=0.05: kk=k; break
                hct=zb+kk*dz
                d_hc.append(hct-hc[j,i])
                kf_old=math.ceil((hc[j,i]-zb)/dz+0.5)  # 1-based
                dk.append((kk+1)-kf_old)
        d_hc=np.array(d_hc); dk=np.array(dk)
        res[f"dx{dx}"]={"cols":int(nn*nn),"hc_type_minus_hc_m":{"min":round(float(d_hc.min()),1),"p05":round(float(np.percentile(d_hc,5)),1),"median":round(float(np.median(d_hc)),1),"p95":round(float(np.percentile(d_hc,95)),1),"max":round(float(d_hc.max()),1)},
          "kf_new_minus_old":{str(v):int((dk==v).sum()) for v in sorted(set(dk.tolist()))}}
    out[name]=res
print(json.dumps(out,ensure_ascii=False,indent=1))
