import re, glob, json, csv, os
rows=[]
for f in sorted(glob.glob('logs/*_w*_h*.log')):
    m=re.search(r'(\w+)_w(\d+)_h(\d+)\.log',f); loc,w,h=m.group(1),int(m.group(2)),int(m.group(3))
    t=open(f).read()
    r=dict(place=loc,wind=w,hour=h)
    mw=re.search(r'этап wind\s+([\d.]+) с',t); r['wind_stage_s']=float(mw.group(1)) if mw else None
    mt=re.search(r'итог (\S+) за ([\d.]+) с',t); r['outcome']=mt.group(1) if mt else 'нет'; r['total_s']=float(mt.group(2)) if mt else None
    mf=re.search(r'air_model: поле [\d:]+ ч, .*?\(загрузка\): ([\d.]+) с, итераций (\[[^\]]*\])',t)
    an=re.search(r'analytic \(([^)]*)\)',t)
    if mf: r['status']='сошлось'; r['field_s']=float(mf.group(1)); r['iters']=mf.group(2)
    else: r['status']='таймаут/аналитика'; r['field_s']=None; r['iters']=''; r['why']=an.group(1) if an else ''
    mp=re.search(r'проходов (\d+)',t); r['passes']=int(mp.group(1)) if mp else None
    r['cap3000']= bool(mf and '3000' in mf.group(2))
    r['warm']= bool(mf and 'тёплый' in t)
    rows.append(r)
json.dump(rows,open('table.json','w'),ensure_ascii=False,indent=1)
keys=['place','wind','hour','wind_stage_s','total_s','status','field_s','iters','passes','cap3000','outcome']
w=csv.DictWriter(open('table.csv','w'),keys,extrasaction='ignore'); w.writeheader(); w.writerows(rows)
print(len(rows),'rows')
for r in rows: print(r['place'],r['wind'],r['hour'],r['wind_stage_s'],r['status'],r['iters'],r['passes'],r['outcome'])
