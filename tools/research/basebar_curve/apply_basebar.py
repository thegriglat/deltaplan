#!/usr/bin/env python3
"""PV-2: записать wings.<id>.basebar и control_frame.basebar_default в glider_params.json.
Запуск: python3 apply_basebar.py  (из корня репозитория). Повторный запуск заменяет прежние записи.
Данные: basebar_data.json (генерируется здесь же из таблицы ниже)."""
import json, re, pathlib
ROOT = pathlib.Path(__file__).resolve().parents[3]
P = ROOT / "tools/blender/glider_params.json"
OUT = pathlib.Path(__file__).with_name("basebar_data.json")

WW = "https://willswing.com/"
# --- источники (url + цитата) ---
E = {
 "alpha": "https://willswing.com/alpha: «standard bar has round downtubes and a straight basetube; a round speedbar basetube is an optional upgrade» (Wills Wing Alpha, учебное)",
 "falcon": "https://willswing.com/falcon-basetubes: Falcon 3 F3 62/65 — «BASETUBE … SPEEDBAR» стандарт, «STRAIGHT» опция (слова пилота-тестировщика 08.10: у Falcon изогнутая)",
 "target": "https://aeros.com.ua/files/manuals/Target_en.pdf §2.1.4: «Install the speedbar so that offset of the speedbar is directed forward and upwards to the flight direction»",
 "combat": "https://aeros.com.ua/files/manuals/CombatC_en.pdf, сборка, п.3: «Install the speedbar so that the offset of the speedbar is directed forward in the direction of flight»; то же https://www.delta-club-82.com/bible/manuels/combat-09-combat-09-gt-manual-en_id828.pdf",
 "wwcarbon": "https://willswing.org/template/control-bars-section-4-2/: карбоновый speedbar WW (Talon, T2…) — «redesigned planform with a deep offset profile»",
 "wwalu": "https://willswing.com/slipstream-downtubescontrol-bars-faq/: алюминиевый обтекаемый basetube WW (Slipstream/Litestream) — «features a deeper bend and better durability than the carbon base tube»",
 "wwsport3": "https://willswing.org/support/wills-wing-control-bars/: Sport 3 — Litestream (обтекаемый алюминиевый basetube) стандарт; изгиб — по FAQ Slipstream (см. wwalu)",
 "eagle": "https://www.willswing.com/hang-gliders/archive/eagle/ (wings_merged/out/construction/batch_a.json, Eagle): «Speedbar basetube included as standard feature»",
 "sting3": "https://www.airborne.com.au/images/manuals/Sting-3-Rev1-Manual.pdf: «fitted with faired king post, downtubes and speed bar as standard»",
 "f2": "tools/research/data/wing_passports/out/construction/batch_a.json (Airborne F2): «new round down tube knuckle for optional speed bars» — speedbar опция, стандарт прямой",
 "spectrum": "tools/research/data/wing_passports/out/construction/batch_a.json (WW Spectrum): «Optional streamline downtubes and speedbar» — speedbar опция, стандарт прямой (однообшивочное)",
 "alto": "tools/research/data/wing_passports/out/construction/batch_c.json (Icaro Alto): «Optional competition upgrades including carbon speedbar and aluminum competition A-frame» — стандартная штанга круглая; speedbar в мачтовом классе принят по классу",
 "kite": "tools/research/data/wing_passports/out/construction/batch_c.json (Bautek Kite): «Optional profiled base tube with split wheel capability»",
 "she1": "tools/research/data/wing_passports/out/construction/batch_c.json (DesignProducts SHE1): «Profiled uprights and speedbar A-frame base tube»",
 "soviet": "docs/research/control_frame_refs.md §Базовая штанга: у советских крыльев голая прямая труба, спидбар только у современных; штанга Славутича/Атласа — прямая труба (A-frame 1970–80-х, спидбары появились с середины 1990-х: https://forum.hanggliding.org/viewtopic.php?t=35520 «base tube cables became standard once manufacturers started bending tubing to make speed bars»)",
}
def A(src, extra=""): return ("curved", 0.07, 0.15, "class_estimate", E[src] + extra)
def B(src, extra=""): return ("curved", 0.09, 0.12, "class_estimate", E[src] + extra)
def C(src, extra=""): return ("curved", 0.11, 0.10, "class_estimate", E[src] + extra)
def S(src, extra=""): return ("straight", 0.0, None, None, E[src] + extra)
OBR = " Величина bow_m — оценка класса (в источнике числа нет): круглый speedbar 0,07; обтекаемый алюминиевый 0,09; карбоновый/безмачтовый 0,11 (±0,03)."
T = {
 "training": S("alpha", " Образец класса: учебное крыло, прямая штанга."),
 "sport": C("wwcarbon", " Обобщённое безмачтовое «sport» — по образцу WW T2C/Talon." + OBR),
 "slavutich_ut": S("soviet"),
 "apogee": S("soviet", " «Апогей» — российское крыло 1980–90-х."),
 "atlas": S("soviet", " Советская копия La Mouette Atlas 1979."),
 "target": A("target", " Aeros Target — учебно-тренировочное, но штанга с изгибом по руководству." + OBR),
 "magic": S("soviet", " Airwave Magic IV, 1983–88: до эпохи спидбаров; оценка по эпохе (уверенность низкая)."),
 "laminar": A("alto", " Образец: мачтовый Icaro Laminar Easy ≈2003, класс Alto/Eagle." + OBR),
 "combat": C("combat", " Обобщённый «combat» по Aeros Combat." + OBR),
 "icaro_piuma": S("alpha", " Образец: Icaro Piuma — одноповерхностное учебное, класс Alpha; уверенность низкая."),
 "moyes_malibu2": S("alpha", " Образец: Moyes Malibu 2 — одноповерхностное учебное, класс Alpha; уверенность низкая."),
 "air_f2": S("f2"),
 "aeros_fox": A("target", " Образец: Aeros Fox (однопов.), тот же производитель и тип штанги, что Target." + OBR),
 "condor_crex3": A("eagle", " Образец: мачтовое двухповерхностное класса WW Eagle." + OBR),
 "condor_flex": S("alpha", " Образец: однопов. учебное класса Alpha (Condor Flex); уверенность низкая."),
 "fs_funky": S("alpha", " Образец: однопов. учебное класса Alpha (Flight Design Funky); уверенность низкая."),
 "fs_space": A("eagle", " Образец: мачтовое двухповерхностное класса WW Eagle (Flight Design Space)." + OBR),
 "ww_eagle": A("eagle", OBR),
 "ww_sport3": B("wwsport3", OBR),
 "ww_u2": B("wwalu", " WW U2 — Litestream-класс." + OBR),
 "aeros_discus": B("wwalu", " Aeros Discus C: «Wills Wing basebar with streamlined fittings» (https://en.wikipedia.org/wiki/Aeros_Discus)." + OBR),
 "air_sting3": A("sting3", OBR),
 "icaro_alto": A("alto", OBR),
 "icaro_mastr": C("wwcarbon", " Образец: Icaro Laminar MastR — мачтовый, но с карбоновым спидбаром по классу." + OBR),
 "bautek_kite": A("kite", OBR),
 "bautek_astir": A("kite", " Образец: Bautek Kite (тот же производитель)." + OBR),
 "fs_crossover": A("eagle", " Образец: класс WW Eagle." + OBR),
 "seed_spyder": C("combat", " Образец: безмачтовое класса Combat." + OBR),
 "moyes_gecko": A("eagle", " Образец: мачтовое класса WW Eagle." + OBR),
 "ww_super_sport": A("eagle", " WW Super Sport — тот же ряд, что Eagle." + OBR),
 "ww_ultra_sport": A("eagle", " WW Ultra Sport — тот же ряд, что Eagle." + OBR),
 "ww_spectrum": S("spectrum"),
 "ww_t2c": C("wwcarbon", OBR),
 "ww_t3": C("wwcarbon", OBR),
 "moyes_litespeed_rx": C("combat", " Образец: безмачтовое класса Combat/T2C (руководство Litespeed RX: https://moyes-russia.com/wp-content/uploads/2012/03/Litespeed_RX_Manual_V2.pdf не прочитано)." + OBR),
 "moyes_litespeed_s": C("combat", " Образец: безмачтовое класса Combat/T2C." + OBR),
 "moyes_litesport": A("eagle", " Образец: мачтовое класса WW Eagle." + OBR),
 "aeros_combat_c": C("combat", OBR),
 "aeros_combat_l": C("combat", OBR),
 "icaro_laminar_z9": C("wwcarbon", " Icaro Laminar Z9 — безмачтовое, карбоновый speedbar (https://www.icaro2000.com/Products/Hanggliders/Laminar/Laminar.htm: «MR carbon fibre speedbar»)." + OBR),
 "bautek_fizz": A("kite", " Образец: Bautek Kite." + OBR),
 "air_c4": C("combat", " Образец: безмачтовое класса Combat." + OBR),
 "air_rev": C("combat", " Образец: безмачтовое класса Combat." + OBR),
 "dp_she1": C("combat", " SHE1: «Profiled uprights and speedbar A-frame base tube» (batch_c.json)." + OBR),
 "seed_skyrunner_xr": A("eagle", " Образец: мачтовое класса WW Eagle." + OBR),
 "ww_fusion": C("wwcarbon", OBR),
 "ww_talon": C("wwcarbon", " WW Talon — прямо назван в совместимости карбонового speedbar." + OBR),
 "ww_cross_country": A("eagle", " Образец: мачтовое класса WW Eagle." + OBR),
}
DEFAULT = ("curved", 0.08, 0.13, "class_estimate",
  "Умолчание PV-2: среднее по классам (tier A 0,07 / B 0,09 / C 0,11) — для крыльев без данных; сводка и методика — tools/research/basebar_curve/README.md")

def rec(t):
    shape, bow, sl, src, ref = t
    d = {"shape": shape, "bow_m": bow}
    if shape == "curved":
        d["bow_src"] = src
        if sl is not None: d["straight_len_m"] = sl
    d["ref"] = ref
    return d

def main():
    s = P.read_text()
    p = json.loads(s)
    assert set(T) == set(p["wings"]), set(p["wings"]) ^ set(T)
    # убрать прежние записи при повторном запуске
    s = re.sub(r'\n( *)"basebar": \{[^{}]*\},', "", s)
    s = re.sub(r'\n( *)"basebar_default": \{[^{}]*\},', "", s)
    out = {}
    for k, t in T.items():
        d = rec(t); out[k] = d
        line = json.dumps(d, ensure_ascii=False)
        pat = re.compile(r'(\n( *)"config": "%s",)' % re.escape(k))
        assert len(pat.findall(s)) == 1, k
        s = pat.sub(lambda m: m.group(1) + "\n" + m.group(2) + '"basebar": ' + line + ",", s)
    dd = rec(DEFAULT); out["_default"] = dd
    m = re.search(r'\n( *)"bar_grip_x_m": ', s)
    s = s[:m.start()] + "\n" + m.group(1) + '"basebar_default": ' + json.dumps(dd, ensure_ascii=False) + "," + s[m.start():]
    json.loads(s)
    P.write_text(s)
    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n")
    c = sum(1 for d in out.values() if d["shape"] == "curved") - 1
    print("curved", c, "straight", len(T) - c)

main()
