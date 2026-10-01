"""DHV Geräteportal: список всех Hängegleiter, затем карточки и тест-отчёты моделей с сертификацией >= 2005."""
import re, html, json, sys
from common import *
BASE = "https://service.dhv.de/db1/"
st, p0 = get(BASE + "searchresultpage.php", "dhv/list_p1.html",
             post={"lang": "DE", "num_EquipmentTypes_IDEquipmentType": "1"})
t = p0.read_text(errors="ignore")
form = {m[0]: html.unescape(m[1]) for m in re.findall(r'<input type="hidden" name="(\w+)"(?: value="([^"]*)")?', t)}
total = int(form["totalpage"])
rows = []
for pg in range(1, total + 1):
    if pg == 1: pth = p0
    else:
        f = dict(form, currentpage=str(pg), startpage="1")
        _, pth = get(BASE + "searchresultpage.php", f"dhv/list_p{pg}.html", post=f)
    tt = pth.read_text(errors="ignore")
    for tr in re.findall(r"<tr align.*?</tr>", tt, re.S):
        m = re.search(r'href="(technicdatareport\d\.php[^"]*)"[^>]*>\s*([^<]*?)\s*</a>', tr)
        if not m: continue
        cells = [re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", c))).strip() for c in re.findall(r"<td.*?</td>", tr, re.S)]
        tr_link = re.search(r'href="(technictestreport\d\.php[^"]*)"', tr)
        rows.append(dict(datalink=html.unescape(m.group(1)), name=m.group(2), maker=cells[2], cert=cells[3],
                         testlink=html.unescape(tr_link.group(1)) if tr_link else None))
print("всего в списке", len(rows))
def year(c):
    m = re.search(r"-(\d\d)\s*$", c)
    if not m: return None
    y = int(m.group(1)); return 2000 + y if y < 40 else 1900 + y
sel = [r for r in rows if (year(r["cert"]) or 0) >= 2005]
print("сертификация >= 2005:", len(sel))
for r in sel:
    r["year"] = year(r["cert"])
    _, p = get(BASE + r["datalink"], "dhv/data_%s.html" % re.sub(r"\W+", "_", r["datalink"].split("?")[1])[-60:])
    r["data_file"] = str(p.relative_to(RAW))
    if r["testlink"]:
        _, p = get(BASE + r["testlink"], "dhv/test_%s.html" % re.sub(r"\W+", "_", r["testlink"].split("?")[1])[-60:])
        r["test_file"] = str(p.relative_to(RAW))
    r["url"] = BASE + r["datalink"]
json.dump(rows, open(RAW / "dhv/index.json", "w"), ensure_ascii=False, indent=1)
