import json,gzip,sys
base='tools/research/pilot-feedback-trim/longitudinal/out/'
for ms in('game','ref'):
  d=json.load(gzip.open(base+f'steady_{ms}.json.gz','rt'))
  print(ms)
  for w,r in d['wings'].items():
    n,x=r['neutral'],r['relaxed']
    print(f"{w:20s}{r['group'][:5]:6s} pass {r['trim_kmh']:5.1f} m{r['mass']:.0f}/{r['mass_ref']:.0f} solve {r['solve_trim_kmh']:5.1f} neut {n['V']:5.1f} th{n['theta']:5.1f} relax {x['V']:5.1f} th{x['theta']:5.1f} k/cm {r['kmh_per_cm']:.2f} sh2 {r['shift']['2']['V']:.1f} sh4 {r['shift']['4']['V']:.1f}")
