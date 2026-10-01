"""Страницы и PDF производителей. Однократный обход индексных страниц + фиксированные URL."""
import re, json
from urllib.parse import urljoin
from common import *
MAN = {}  # dest -> url
def add(dest, url): MAN[dest] = url
# --- Wills Wing
W = "https://www.willswing.com"
add("ww/placard.html", W + "/hang-glider-placard-specifications/")
add("ww/polar_data.html", W + "/polar-data-for-wills-wing-hang-gliders/")
for s in ["t3", "t2c", "u2", "sport-3", "falcon-4", "condor", "alpha"]:
    add(f"ww/{s}.html", f"{W}/hang-gliders/{s}/")
st, p = get(W + "/hang-gliders/archive/", "ww/archive_index.html")
if st == 200:
    for l in sorted(set(re.findall(r'href="(/hang-gliders/archive/[a-z0-9-]+/)"', p.read_text(errors="ignore")))):
        if "review" in l or l.count("/") != 4: continue
        add("ww/archive_%s.html" % l.strip("/").split("/")[-1], W + l)
# --- Moyes
M = "https://www.moyes.com.au/products/hang-gliders/"
st, p = get(M, "moyes/index.html")
slugs = set(re.findall(r'href="/products/hang-gliders/([a-z0-9-]+)"', p.read_text(errors="ignore"))) if st == 200 else set()
for s in sorted(slugs):
    add(f"moyes/{s}_spec.html", M + s + "/specifications")
    add(f"moyes/{s}_desc.html", M + s + "/description")
# --- Aeros
for s in ["combat_gt", "combat", "combat_l", "discus", "stratus", "target", "fox", "vector", "stratus_2", "combat_2", "combat_c", "fox_c", "fun", "fun_2"]:
    add(f"aeros/{s}.html", f"https://aeros.com.ua/{s}")
# --- Icaro / Airborne / Bautek
add("icaro/intro.html", "https://www.icaro2000.com/Products/Hanggliders/Introduction.htm")
add("icaro/alto.html", "https://www.icaro2000.com/Products/Hanggliders/Alto/Alto.htm")
add("airborne/hang_gliders.html", "https://www.airborne.com.au/pages/hang_gliders.php")
for s in ["astir", "bico", "fizz", "kite"]:
    add(f"bautek/{s}.html", f"https://www.bautek.com/english/hanggliders/{s}/")
# --- PDF
PDF = {
 "moyes_litespeed_s_manual.pdf": "https://www.delta-club-82.com/bible/manuels/litespeed-S.pdf",
 "aeros_discus_manual.pdf": "https://www.delta-club-82.com/bible/manuels/discus.pdf",
 "icaro_laminar_2011.pdf": "https://www.icaro2000.com/Products/Manuals/Laminar%202011-3-En.docx.pdf",
 "airborne_sting3_manual.pdf": "https://www.airborne.com.au/images/manuals/108841%20STING%203%20Manual.pdf",
 "ww_t2_2012_manual.pdf": "http://willswing.com/wp-content/uploads/manuals/T2_5th_September_2012.pdf",
}
for k, u in PDF.items(): add("pdf/" + k, u)
res = {}
for d, u in MAN.items():
    st, p = get(u, d); res[d] = dict(url=u, status=st, bytes=p.stat().st_size if p.exists() else 0)
# второй проход: ссылки на страницы моделей с индексов Icaro/Airborne/Bautek
extra = {}
for d, base in [("icaro/intro.html", "https://www.icaro2000.com/Products/Hanggliders/Introduction.htm"),
                ("airborne/hang_gliders.html", "https://www.airborne.com.au/pages/hang_gliders.php")]:
    p = RAW / d
    if p.exists():
        for l in set(re.findall(r'href="([^"#]+)"', p.read_text(errors="ignore"))):
            u = urljoin(base, l)
            if ("Hanggliders/" in u and u.endswith(".htm") and "Introduction" not in u) or ("airborne.com.au/pages/" in u and ("hang" in u or "sting" in u or "fun" in u or "climax" in u)):
                extra[d.split("/")[0] + "/" + re.sub(r"\W+", "_", u.split("//")[1])[-50:] + ".html"] = u
for d, u in extra.items():
    if d in res: continue
    st, p = get(u, d); res[d] = dict(url=u, status=st, bytes=p.stat().st_size if p.exists() else 0)
json.dump(res, open(RAW / "makers_index.json", "w"), indent=1)
print(sum(1 for v in res.values() if v["status"] == 200), "ok из", len(res))
