import re,sys
cur=None; rows={}
order=[]
for line in open(sys.argv[1]):
    line=line.strip()
    m=re.match(r'=== (\S+)',line)
    if m: cur=m.group(1); order.append(cur); rows[cur]={}; continue
    if line.startswith('check failed'): continue
    m=re.match(r'(правильная (\w+), ветер (\d+)|отдача с (-?[\d.]+) м (\w+)) — (\w+) ([\d.]+): верт ([\d.]+), гор ([\d.]+) м/с, крен (-?\d+)°.*пробег ([\d.]+)',line)
    if not m: continue
    if m.group(2): key=f'w{m.group(3)}'; wing=m.group(2)
    else: key=f'p{m.group(4)}'; wing=m.group(5)
    g,sc,v,h,b,run=m.group(6),m.group(7),m.group(8),m.group(9),m.group(10),m.group(11)
    flip='П' if abs(int(b))>=60 else ''
    rows[cur].setdefault(key,[]).append(f'{wing[:3]} {sc}({v}/{h}){flip}')
for c in order:
    print('==',c)
    for k,v in rows[c].items(): print('  ',k,' | '.join(v))
