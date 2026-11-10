#!/usr/bin/env python3
"""diagnosis.json: выводы + числа из tables.json (build_diagnosis.py) и логов правленных тестов."""
import json, os, re
R = os.path.expanduser("~/worktrees/deltaplan/picard-terrain-PT-14/tools/research/picard_terrain/out/PT-14/")
t = json.load(open(R + "tables.json"))
pr = t["synthetic_ridge_crate_probe"]
st = t["real_starts"]
def pt(sha, x): return pr[sha]["points_agl40_wind25"][str(x)]
def mean_w(log):
    m = re.search(r"штиль (-?[\d.]+), ветер 6 м/с (-?[\d.]+)", open(R + "logs/" + log, errors="replace").read())
    return {"calm": float(m.group(1)), "wind6": float(m.group(2))}
S0, S1, S2 = "f44c66b4a", "4316db7e0", "9d94bf30c"
d = {
 "task": "PT-14",
 "culprit": "PT-9",
 "cause_kind": "field_physics",
 "verdict": ("Подветренная болтанка и опускание «ослабли» из-за поля PT-9 (срезанные клетки), а не из-за правил PT-10: "
             "поле стало честнее (убрана ступенчатая заторможенность наветренного подножия и завышенный сдвиг над ступенью за гребнем), "
             "потребитель (σ по сдвигу/местной скорости, признак отрыва lee) не менялся и отвечает на новое поле предсказуемо. "
             "Само опускание за гребнем в поле не ослабло, а выросло в 1,7–2,4 раза; падают пороги тестов, настроенные на ступенчатое поле, "
             "и метрика полёта, которой мешает «хвост» подъёма за гребнем. Расхождение снимка 0,05 м/с — отдельная причина, шаг PT-10."),
 "snapshot": {
   "culprit": "PT-10", "cause_kind": "snapshot",
   "cause": ("PT-10 (версия 2 файла поля) записал в снимок массив k1 (первая воздушная клетка по типам) и ввёл якорь лог-профиля hc+dz/2 "
             "у срезанных столбцов; GDScript-зеркало WindField (AirFieldImport.load_bytes) массив k1 не читает и считает k1 от hc "
             "(ceil((hc−z_bot)/dz−0,5)), а якорь — по центру k1. В тесте (плоское место 500 м, z_bot 315, dz 105) граница 500 м "
             "лежит внутри клетки 420…525: крейт берёт k1=1 (vf=0,24 ≥ 0,05, центр 472,5 < hc), GD — k1=2."),
   "where": "только ниже ≈ 77 м над землёй (до центра второй клетки): max |Δ| 0,0496 при agl 64 м; выше 100 м — 2·10⁻⁷",
   "snapshot_source": ("файла нет: снимок строится на лету крейтом (DpAir.field_export_header/field_export_data, Formula::field_export → "
                       "encode_solved, версия формата 2) в самом тесте; пересъёмка не нужна — поле изменилось намеренно (PT-10), "
                       "расходится зеркало в GDScript"),
   "consumer_in_game": "AirFieldSet из снимка (Atmosphere.air_field) — отладка и превью (F3…F7); горячий путь игры читает слагаемое field крейта, поэтому на полёт не влияет",
   "max_abs_diff_mps": {"before": t["snapshot"][S0]["max_abs_diff_mps"], "PT-9": t["snapshot"][S1]["max_abs_diff_mps"], "PT-10": t["snapshot"][S2]["max_abs_diff_mps"], "PT-10+patch": t["snapshot"]["patch"]["max_abs_diff_mps"]},
   "fix": "out/PT-14/patch_snapshot_k1.patch (GDScript: AirFieldImport передаёт k1, WindField строит k1/kfa и читает ниже якоря как Field::col_vel/col_scalar)",
 },
 "tests_by_commit": t["tests_by_commit"],
 "tests_after_patch_proposals": {
   "test_lee_turbulence_stronger (lee x=500, наветренная x=−900)": "ok на до, PT-9 и PT-10-копиях",
   "test_lee_mean_sink_behind_crest (новый, средняя w 200–700 м)": {"before": mean_w("f44c66b4a-lee_rotor_new.log"), "PT-9": mean_w("4316db7e0-lee_rotor_new.log"), "PT-10": mean_w("patch-lee_rotor_new.log"), "unit": "м/с"},
   "test_air_field_import с patch_snapshot_k1": "ok, max |Δ| 4,8·10⁻⁷",
 },
 "decomposition": {
   "synthetic_ridge": {
     "setup": "тесты test_atmosphere/test_lee_rotor: гребень 300 м, a=400 м, ветер 270°, 25 км/ч (6 м/с в полёте), поле 400 м, зонд крейта с точными входами фасада",
     "windward_foot_x-600_agl40": {k: {"uf": pt(s, -600)["uf"], "ustar": pt(s, -600)["ustar"], "sigma_w_mech": pt(s, -600)["sg_w"], "wf": pt(s, -600)["wf"]} for k, s in (("before", S0), ("PT-9", S1), ("PT-10", S2))},
     "lee_test_point_x350_agl40": {k: {"uf": pt(s, 350)["uf"], "shear": pt(s, 350)["shear"], "ustar": pt(s, 350)["ustar"], "sigma_w_mech": pt(s, 350)["sg_w"], "lee_f": pt(s, 350)["lee_f"], "wf": pt(s, 350)["wf"]} for k, s in (("before", S0), ("PT-9", S1), ("PT-10", S2))},
     "separated_lee_x500_agl40": {k: {"uf": pt(s, 500)["uf"], "lee_f": pt(s, 500)["lee_f"], "sigma_w_total": pt(s, 500)["sw_total"], "sep_w": pt(s, 500)["sep_w"]} for k, s in (("before", S0), ("PT-9", S1), ("PT-10", S2))},
     "windward_lift_x-300_agl40_wf": {k: pt(s, -300)["wf"] for k, s in (("before", S0), ("PT-9", S1), ("PT-10", S2))},
     "w_field_mean_y350_wind6": {k: pr[s]["w_field_mean_y350_wind6"] for k, s in (("before", S0), ("PT-9", S1), ("PT-10", S2))},
     "columns_first_air_cells_u": {k: {c["xc"]: c["u_first_cells"] for c in pr[s]["columns_wind25"] if c["xc"] in (-600, 200, 600)} for k, s in (("before", S0), ("PT-9", S1), ("PT-10", S2))},
     "variance_w_test": {"before": {"lee350": 0.194, "wind-600": 0.108}, "PT-9": {"lee350": 0.143, "wind-600": 0.331}, "PT-10": {"lee350": 0.145, "wind-600": 0.328}},
   },
   "real_starts": st,
 },
 "answers": {
   "which_step": "PT-9 (слияние 4316db7e0); PT-10 на старты не влияет (4316db7e0 и 9d94bf30c дают бит в бит те же w, σ, uf, shear), на синтетике — ≤ 5 %",
   "which_quantity": ("не средний подветренный поток как таковой (он стал сильнее вниз) и не вход слагаемого болтанки как правило: изменились "
                      "(1) местная скорость и сдвиг |∂U/∂z| в точке: на стартах lee shear 0,062→0,042 и 0,096→0,056 с⁻¹ (−32…−42 %), uf в точке +25…34 %; "
                      "(2) наветренный базис на синтетике: uf подножия 4,1→5,7 м/с, u* 0,41→0,89 (столбец подножия был «заперт» ступенью); "
                      "σ_lee/σ_wind на стартах 1,45→1,12 и 1,69→1,10, σ_wind не изменилась (1,42→1,44; 1,59→1,66)"),
   "consumer_rule": ("σ_w = 1,25·max(u*_loc, l_mix·shear), u*_loc = κ·uf/ln(z/z0) — прежняя, байт-в-байт; признак отрыва lee_f ≈ 0 (0…0,06) до и после в точках тестов "
                     "(дефицит ex < 0,3), поэтому слагаемое слоя смешения (0,14·ΔU) в них не работало ни до, ни после; в зоне отрыва x≥500 м синтетики lee_f=0,93→1,0, σ_w 1,59→1,54"),
   "mean_sink": "вертикаль поля за гребнем выросла: средняя w на гребень+50 м, 200–700 м: −0,52 → −0,87 м/с (ветер 6 м/с); на стартах w_f −0,48→−1,00 и −0,60→−1,43 м/с, наклон опускания desc 0,05→0,11 и 0,06→0,135",
   "flight_test": ("метрика теста, а не поле: первые ≈150 м за гребнем при сетке 400 м ещё подъём (+1,2 м/с, было +0,05), он вычитается из потери, "
                   "а штилевая база сама скачет 14→23→20 м при нулевом поле (случайная болтанка и термики) — шум метрики ±9 м больше эффекта"),
   "physically_plausible": ("срезанные клетки в PT-2…PT-5 приблизили поле к опыту: Askervein ΔS 0,285→0,485 при измеренном 0,52, ротор Perdigão NE 320→473 м при Menke 493 м; "
                            "на синтетике подъём на наветренном склоне 4–5 м/с против 0,2–0,6 (кинематика U·tg α ≈ 8 м/с) — поле PT-9 физичнее; "
                            "проверки подветренной болтанки на самом этих местах опытом нет"),
 },
 "proposals": [
   {"id": "P1", "kind": "snapshot", "file": "tools/research/picard_terrain/out/PT-14/patch_snapshot_k1.patch", "where": "scripts/atmosphere/air_model/air_field_import.gd, wind_field.gd",
    "check": "test_air_field_import 0,0496 → 4,8·10⁻⁷; test_wind_field 9/9, test_air_field_contracts 18/18, test_debug_layers 7/7"},
   {"id": "P2", "kind": "tests", "file": "tools/research/picard_terrain/out/PT-14/patch_tests_lee.patch",
    "what": "test_lee_turbulence_stronger: точки lee x=500 (зона отрыва по lee_f≈1) и наветренная x=−900 (невозмущённый подход); новый test_lee_mean_sink_behind_crest вместо полёта 30 с",
    "check": "оба проходят на до, PT-9, PT-10 (не подгонка под новое поле): дисперсия lee/wind 13,2 / 8,2 / 8,4; опускание −0,52 / −0,87 / −0,87 против штиля +0,05"},
   {"id": "P3", "kind": "decision", "what": "test_ridge_starts::test_lee_zone_all_starts (σ_lee > σ_wind): ниже порога не подгонять — решение пользователя, нужна ли в игре повышенная болтанка на прилегающем (не оторванном) спуске с лежащим ниже гребнем; рычаг — lee.field_deficit_attached/separated (ex0/ex1) или шкала σ по сдвигу, замер на 10 стартах после решения"},
 ],
 "uncertain": [
   "σ из разложения фасада (интенсивность) ≠ σ_w слагаемого: значения зонда крейта σ_w (формулы sigma.rs по каналам поля) и σ разложения фасада отличаются в 1,3–1,6 раза; сравнения до/после внутри одного источника согласованы по направлению",
   "реальный рельеф: только 2 из 10 стартов (aushtau_south, kayancha_south) в двух точках A/B; остальные 8 — по данным координатора (отношение упало на всех 10)",
   "поле на сетке 400 м (на синтетике окон 50/100 м нет в снимке) не разрешает гребень a=400 м: выводы про x=350 м относятся к интерполяции между столбцами гребня и первым подветренным",
   "физичность подветренного потока оценена по PT-2…PT-5 (Askervein, Perdigão, Каянча/air3d), а не по опыту на этих местах",
   "полёт 30 с хаотичен: числа 14/23/20 и 32/18/27 м — одна реализация шума, повторов с другим сидом не делалось",
 ],
}
json.dump(d, open(R + "diagnosis.json", "w"), ensure_ascii=False, indent=1)
print("ok")
