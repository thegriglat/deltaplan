import json,sys
ok=True
for t in ('PHD-2','PHD-3'):
    d=json.load(open(f'tools/research/pilot-handling/out/{t}_verdict.json'))
    for m in d['modes']:
        if m['mode'] in ('roll','spiral'):
            if m.get('omega_rad_s') is not None or m.get('zeta') is not None or not isinstance(m.get('lambda_1_s'),(int,float)):
                print('aperiodic', t, m); ok=False
            if m['mode']=='roll' and m['source']=='game' and t=='PHD-3' and 'замер' not in m['case']:
                print('roll source', t, m); ok=False
    for i in d['items']:
        for e in i['evidence']:
            if len(str(e['unit']))>8: print('unit', t, e['unit']); ok=False
d=json.load(open('tools/research/pilot-handling/out/PHD-2_verdict.json'))
if not any('center_time_s' in e['what'] for i in d['items'] for e in i['evidence']): print('no center_time_s evidence'); ok=False
print('ok' if ok else 'FAIL')
