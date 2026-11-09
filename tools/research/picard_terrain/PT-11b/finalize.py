"""PT-11b: summary_part.json + table.csv -> summary.json (вердикт, таблица S по гребням)."""
import csv, json
from pathlib import Path
OUT = Path(__file__).resolve().parent.parent / "out" / "PT-11b"
s = json.load(open(OUT / "summary_part.json"))
rows = list(csv.DictReader(open(OUT / "table.csv")))
tab = []
for x in rows:
    if x["z_agl"] in ("10", "30", "60", "100"):
        tab.append(dict(name=x["name"], mode=x["mode"], z_agl=int(x["z_agl"]), S_before=round(float(x["S_before"]), 3), S_after=round(float(x["S_after"]), 3),
                        slope_w_before=round(float(x["slope_w_before"]), 3), slope_w_after=round(float(x["slope_w_after"]), 3),
                        rot_win50_frac_before=round(float(x["rot_win50_frac_before"]), 4), rot_win50_frac_after=round(float(x["rot_win50_frac_after"]), 4),
                        rot_win50_minu_before=round(float(x["rot_win50_minu_before"]), 2), rot_win50_minu_after=round(float(x["rot_win50_minu_after"]), 2)))
s["per_crest_S"] = tab
s["slope_w_mean_median_before_after"] = {m: [sorted(float(x["slope_w_before"]) for x in rows if x["mode"] == m and x["z_agl"] == "10")[3],
                                              sorted(float(x["slope_w_after"]) for x in rows if x["mode"] == m and x["z_agl"] == "10")[3]] for m in ("focus", "nofocus")}
s["verdict"] = ("Да, разгон после слабее и там, где сетка его разрешает: в окнах 100/50 м (S_после-1)/(S_до-1) медиана 0,60 (мин 0,41) против 0,50 (0,33) на 400 м, "
                "то есть окна возвращают лишь часть потери; «до» в окнах (S 3,7-4,0 на z_agl 10-30 м) почти не отличается от «до» на 400 м (3,7-3,8), так что завышения ступеньками на 400 м "
                "по этим 6 гребням не видно; ротор слабее (доля u∥<0 в окне 50 м у 1 из 6 гребней: 0,020 → 0,008, ниже порога 0,01, min u∥ −0,48 → −0,41, длина 400 → 300 м), но у ongudai massif2 не исчез.")
s["scope"] = "6 гребней (ongudai massif 0/1/2, mod0; synth massif0, mod2), t=0, фокус на гребне z_agl 30 м, dp-stand formula mean"
d = json.load(open(OUT / "decomp_summary.json")); far = json.load(open(OUT / "far_U.json"))
s["crest_U_after_over_before_median"] = d["focus"]["crest_U_after_over_before_median"]
s["ref_U_after_over_before_median"] = d["focus"]["ref_U_after_over_before_median"]
s["crest_U_after_over_before_median_400"] = d["nofocus"]["crest_U_after_over_before_median"]
s["ref_U_after_over_before_median_400"] = d["nofocus"]["ref_U_after_over_before_median"]
s["U_crest_ref_median_by_z_agl"] = {m: d[m]["by_z"] for m in d}
s["far_U_mean_before_after"] = {c: [v["before"]["mean"], v["after"]["mean"]] for c, v in far.items()}
s["verdict_S_split"] = ("Потеря S - от опоры, не от гребня: |U| на гребне после ВЫШЕ (x1,19 в окнах, x1,11 на 400 м), |U| опоры после выше ещё сильнее (x1,62 / x1,68): "
                        "«до» опора 2,4-5,3 м/с (z_agl 10-100) заблокирована ступеньками, после 4,5-7,6 м/с; свободный поток (far-точки) ongudai 9,2 -> 10,9, synth 22,1 -> 22,3. "
                        "S «до» завышено знаменателем (малая U опоры), не разгоном на гребне.")
json.dump(s, open(OUT / "summary.json", "w"), indent=1, ensure_ascii=False)
print(s["verdict"])
