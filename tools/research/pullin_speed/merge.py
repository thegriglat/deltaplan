import json, glob, os
here = os.path.dirname(os.path.abspath(__file__))
out = {}
for f in sorted(glob.glob(here + '/out/raw_*.json')):
    out.update(json.load(open(f))['wings'])
for f in sorted(glob.glob(here + '/out/extra_*.json')):  # доп. случаи тех же крыльев
    for w, c in json.load(open(f))['wings'].items():
        out[w].update({k: v for k, v in c.items() if k != 'cfg'})
json.dump(out, open(here + '/out/cases.json', 'w'), ensure_ascii=False, indent=1)
print(len(out), 'wings')
