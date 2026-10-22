import json, subprocess, os, sys
def probe(colors, glow=False, tag='x', mode=None):
    d='/tmp/claude-1000'; fi=f'{d}/pi_{tag}.json'; fo=f'{d}/po_{tag}.json'
    json.dump([[float(v) for v in c] for c in colors],open(fi,'w'))
    root='/home/greg/deltaplan-haze-humidity-HH-12'
    env=dict(os.environ,XDG_DATA_HOME=os.path.expanduser('~/.cache/dp-xdg/deltaplan-haze-humidity-HH-12'),DISPLAY=':0')
    if os.path.exists(fo): os.remove(fo)
    args=['/home/greg/.local/bin/godot','--path',root,'-s','tools/research/haze_humidity/sunset_color/tonemap_probe.gd','--',fi,fo]+(['glow' if glow else 'noglow'] + ([mode] if mode else []))
    cmd=[root+'/.dpcli/dpcli','lock','gpu','hh12p','--','timeout','150']+args
    subprocess.run(cmd,env=env,cwd=root,capture_output=True)
    import time
    for _ in range(100):
        if os.path.exists(fo) and os.path.getsize(fo)>0: break
        time.sleep(0.3)
    return json.load(open(fo))
