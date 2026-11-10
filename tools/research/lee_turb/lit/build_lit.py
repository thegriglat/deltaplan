#!/usr/bin/env python3
"""Собирает lit_numbers.csv (LTL v1) из таблицы ниже. Запуск: python3 build_lit.py"""
import csv, os
HERE = os.path.dirname(os.path.abspath(__file__))
MW = "Mehta R.D., Westphal R.V. 1985, An Experimental Study of Plane Mixing Layer Development, NASA TM-86698 (ntrs.nasa.gov 19850021659)"
LMK = "Le H., Moin P., Kim J. 1997, DNS of turbulent flow over a backward-facing step, J. Fluid Mech. 330:349, doi 10.1017/S0022112096003777"
MKM = "Mansour N.N., Kim J., Moin P. 1984, Computation of Turbulent Flows Over a Backward-Facing Step, NASA TM-85851"
MEN = "Menke R., Vasiljevic N., Mann J., Lundquist J.K. 2019, Characterization of flow recirculation zones at the Perdigao site using multi-lidar measurements, Atmos. Chem. Phys. 19:2713, doi 10.5194/acp-19-2713-2019"
MEM = "по памяти"  # только строки из DROP, ниже отбрасываются
R = []
def r(id, q, v, lo, hi, unit, flow, d, src, where, rel, note):
    R.append([id.lower(), q.lower(), v, lo, hi, unit, flow, d, src, where, rel, note])
LAM = "lambda=(U1-U2)/(U1+U2)"
# --- слой смешения: рост
r("ml_sigma0_rodi","spreading_parameter_sigma0",11,"","","1","mixing_layer_two",
  "sigma0 из erf-профиля U*=(U-U2)/(U1-U2)=0,5(1+erf(sigma*y/x)); sigma=sigma0/"+LAM+"; принято Rodi 1975 для однопоточного слоя",
  MW+" (цитирует Rodi 1975)","разд. 3.3, ф-лы (2),(6)","A","масштаб erf-профиля a=x/sigma")
r("ml_two_da_dx_meas","da_dx_erf_scale",0.032,0.031,0.033,"1","mixing_layer_two",
  "da/dx, a=x/sigma — масштаб erf-подгонки профиля (подгонка 0,1<U*<0,9); "+LAM+"=0,37 (U2/U1=0,46); низ-верх: tripped / untripped пограничные слои",
  MW,"разд. 3.3, после ф-лы (6)","A","расчёт по sigma0=11 даёт 0,034")
r("ml_dB_dx_over_lambda","dB_dx_over_lambda",0.165,0.15,0.18,"1","mixing_layer_two",
  "dB/dx / lambda, B=y(U*=0,9)-y(U*=0,1); lambda=(U1-U2)/(U1+U2); самоподобный слой, erf-профиль (B=1,812a)",
  MW+"; пересчёт автора","1,812/sigma0=0,165; измерения 0,031-0,033 при lambda=0,37 -> 0,152-0,162","C","пересчёт erf-масштаба a в B; верхняя граница 0,18 — Brown&Roshko 1974 (см. строку br74_ddw_dx_over_lambda, A)")
r("ml_ddelta_omega_dx_over_lambda","ddelta_omega_dx_over_lambda",0.16,0.15,0.18,"1","mixing_layer_two",
  "d(delta_omega)/dx / lambda, delta_omega=(U1-U2)/max(dU/dy); lambda=(U1-U2)/(U1+U2); erf-профиль: delta_omega=sqrt(pi)*a",
  MW+"; пересчёт автора","delta_omega'=sqrt(pi)*lambda/sigma0=0,161*lambda","C","Brown&Roshko 1974 даёт 0,181 (строка br74_ddw_dx_over_lambda, A)")
r("ml_dB_dx_single","dB_dx",0.165,0.14,0.20,"1","mixing_layer_single",
  "dB/dx, B=y(0,9)-y(0,1), U2=0 (lambda=1); самоподобная область; перед ней слой растёт медленнее",
  MW+"; Rodi 1975","разд. 3.2; пересчёт","C","у однопоточного слоя в MW85 самоподобие не достигнуто к X/h=4; разброс шире (начальные условия)")
r("ml_tripped_vs_untripped","growth_ratio_untripped_over_tripped",1.06,"","","1","mixing_layer_two",
  "отношение dδ/dX untripped/tripped при тех же U1,U2: 0,033/0,031","MW","разд. 3.3","A","чувствительность к начальному пограничному слою 5-10 %; однопоточный untripped растёт заметно быстрее tripped")
r("ml_dev_dist_single_theta0","x_dev_over_theta0",1000,625,1000,"1","mixing_layer_single",
  "расстояние до самоподобия / импульсная толщина начального пограничного слоя theta0 (Bradshaw 1966)",
  MW+" (цитирует Bradshaw 1966, Wood&Bradshaw 1982, Ho&Huerre 1984)","разд. 1, с. 7","A","низ 625 — оценка по Ho&Huerre; в MW85: X/h=7-9 для однопоточного")
r("ml_dev_dist_two_vs_single","development_distance_ratio_single_over_two",4.5,4,5,"1","mixing_layer_two",
  "во сколько раз двухпоточный слой достигает самоподобия быстрее однопоточного (X/h=1,5 против 7-9)",MW,"разд. 3.3","A","нет принятого критерия для двухпоточного слоя")
# --- толщины
r("ml_delta_omega_over_theta_tanh","delta_omega_over_theta",4.0,"","","1","mixing_layer_two",
  "delta_omega/theta, профиль U*=0,5(1+tanh(2y/delta_omega)), theta=int U*(1-U*)dy","аналитика, автор","интеграл","C","аналитически точно для tanh")
r("ml_delta_omega_over_theta_erf","delta_omega_over_theta",4.44,4.0,4.5,"1","mixing_layer_two",
  "delta_omega/theta, профиль erf; theta=0,2251*delta_omega","аналитика, автор (численный интеграл)","tools/research/lee_turb/lit/README.md","C","по реальным профилям 4,0-4,5")
r("ml_B_over_delta_omega","B_over_delta_omega",1.022,"","","1","mixing_layer_two",
  "B(10-90%)/delta_omega для erf-профиля","аналитика, автор","erfinv(0,8)=0,9062","C","для tanh 1,10")
r("ml_delta99_over_delta_omega","delta_1_99_over_delta_omega",1.86,1.8,2.3,"1","mixing_layer_two",
  "ширина между U*=0,01 и 0,99 / delta_omega: erf 1,86, tanh 2,30","аналитика, автор","erfinv(0,98)=1,645","C","хвосты профиля — не мера слоя; для границы области модели брать 1,9-2,3")
r("ml_dtheta_dx_over_lambda","dtheta_dx_over_lambda",0.036,0.033,0.040,"1","mixing_layer_two",
  "dtheta/dx / lambda; theta=int U*(1-U*)dy","MW+пересчёт автора","0,16/4,44","C","производное; для tanh 0,04")
# --- напряжения и болтанка в слое
r("ml_uv_peak","uv_peak_over_dU2",0.011,0.0094,0.0136,"1","mixing_layer_two",
  "max(-u'v')/(U1-U2)^2 в самоподобной области; lambda=0,37",MW+" (Patel 1970, 0,0103; Townsend 1976 по Sabin 1965, 0,011)","ф-ла (1), табл. 1","A","измерено 0,0094-0,012; Bradshaw однопоточный 0,01")
r("ml_uv_single_nearfield","uv_peak_over_dU2",0.0093,0.0051,0.0098,"1","mixing_layer_single",
  "max(-u'v')/dU^2 однопоточного tripped слоя в ближнем поле X/h=0,5-4 (растёт от 0,0051)",MW,"табл. 1 (SST)","A","самоподобного уровня 0,01 ещё нет; untripped 0,009-0,010 с X/h=1")
r("ml_sigma_u_peak","sigma_u_peak_over_dU",0.18,0.15,0.20,"1","mixing_layer_single",
  "max sqrt(u'^2)/(U1-U2), самоподобная область","Pope 2000, Turbulent Flows, разд. 5.4; Bell&Mehta 1990 AIAA J 28:2034",MEM,"C","значения MW85 есть на рис. 6, не оцифрованы")
r("ml_sigma_v_peak","sigma_v_peak_over_dU",0.14,0.12,0.16,"1","mixing_layer_single",
  "max sqrt(v'^2)/(U1-U2)","Pope 2000 разд. 5.4; Bell&Mehta 1990",MEM,"C","поперечная к слою (вертикальная для горизонтального слоя за гребнем)")
r("ml_sigma_w_peak","sigma_w_peak_over_dU",0.13,0.11,0.15,"1","mixing_layer_single",
  "max sqrt(w'^2)/(U1-U2), w вдоль размаха вихрей","Pope 2000 разд. 5.4; Bell&Mehta 1990",MEM,"C","по порядку величины близко к v'")
r("ml_tke_peak","tke_peak_over_dU2",0.036,0.03,0.042,"1","mixing_layer_single",
  "max k/(U1-U2)^2, k=0,5(u'2+v'2+w'2)","автор, из строк sigma_*_peak","0,5(0,18^2+0,14^2+0,13^2)","C","по порядку; сверять с замерами, не с этой цифрой")
r("ml_ruv","corr_uv",0.45,0.40,0.50,"1","mixing_layer_single",
  "коэффициент корреляции -u'v'/(u'v') в центре слоя","Pope 2000 разд. 5.4; MW85 (профили R_uv, рис. 6)",MEM,"C","")
r("ml_turb_peak_location","y_tke_peak_over_B",0.0,-0.15,0.15,"1","mixing_layer_single",
  "положение максимума TKE относительно центра слоя (U*=0,5), в долях B; + к быстрой стороне","MW85 рис. 6; Bell&Mehta 1990",MEM,"C","максимум около центра; смещение к низкоскоростной стороне у однопоточного")
# --- масштабы и перенос
r("ml_kh_wavelength_theta","lambda_x_over_theta0",31,28,32,"1","mixing_layer_two",
  "длина волны начального спиралевидного (KH) вихря / начальная импульсная толщина theta0 (Ho&Huerre 1984: Lambda_n=theta/0,032)",MW+" (цитирует Ho&Huerre 1984)","разд. 3.4, ф-ла Lambda_n","A","линейная теория tanh: alpha*theta=0,21 -> 30 theta")
r("ml_kh_wavelength_delta_omega","lambda_x_over_delta_omega0",7.75,7.0,8.0,"1","mixing_layer_two",
  "та же длина волны / начальная delta_omega (tanh, theta=delta_omega/4)","пересчёт автора","31/4","C","следующие слияния удваивают длину")
r("ml_integral_Lu","L_u_over_delta_omega",0.6,0.3,1.0,"1","mixing_layer_single",
  "продольный интегральный масштаб L_u / delta_omega в самоподобной области","оценка автора по Pope 2000 разд. 5.4; Bell&Mehta 1990",MEM+"; нет прямого числа","C","масштаб растёт линейно вместе со слоем; не использовать как порог")
r("ml_integral_Lw","L_w_over_delta_omega",0.35,0.2,0.6,"1","mixing_layer_single",
  "вертикальный (поперёк слоя) интегральный масштаб / delta_omega","оценка автора",MEM+"; нет прямого числа","C","~0,5-0,6 от L_u")
r("ml_uc","convection_velocity_over_U1",0.5,0.45,0.60,"1","mixing_layer_single",
  "скорость переноса крупных вихрей Uc/U1 при U2=0; для двух потоков при равной плотности Uc=(U1+U2)/2","Brown&Roshko 1974 JFM 64:775; Dimotakis 1986 AIAA J 24:1791",MEM,"C","ставить Uc=(U1+U2)/2; для U2=0 - 0,5-0,6")
# --- уступ
r("step_xr_lmk","xr_over_h",6.28,"","","1","step",
  "длина отрыва x_r/h от угла уступа, DNS Re_h=5100, степень расширения 1,2; среднее положение присоединения колеблется около значения",
  LMK,"аннотация","A","согласие с Jovic&Driver 1994 по статистике; DNS, не эксперимент")
r("step_xr_kim","xr_over_h",7.0,6.0,8.0,"1","step",
  "x_r/h, эксперимент Re=44580, цитируемый в MKM84","MKM84 (разд. 4, цитирует эксперимент)","разд. 4, с. 10","A","погрешность ±1h по тексту; k-eps стандартная даёт 5,2h")
r("step_xr_review","xr_over_h",6.0,5.0,8.5,"1","step",
  "диапазон x_r/h обратного уступа, турбулентный набегающий погранслой, малое расширение","Eaton J.K., Johnston J.P. 1981, AIAA J 19:1093; Driver&Seegmiller 1985 AIAA J 23:163",MEM,"C","зависит от толщины и состояния погранслоя, расширения, Re")
r("step_u_reverse","u_back_max_over_U0",-0.2,-0.25,-0.15,"1","step",
  "минимум средней скорости в пузыре / U0 набегающего потока","Driver&Seegmiller 1985; Le&Moin&Kim 1997",MEM,"C","обратное течение слабое — десятки процентов U0 не бывает")
r("step_uv_peak","uv_peak_over_U0sq",0.012,0.009,0.018,"1","step",
  "max(-u'v')/U0^2 в слое за уступом около присоединения, U0 — скорость набегающего потока","Driver&Seegmiller 1985; Le&Moin&Kim 1997",MEM,"C","на 20-50 % выше самоподобного слоя смешения (0,011) из-за кривизны и повторного возврата")
r("step_x_tke_max","x_tke_max_over_xr",0.9,0.7,1.1,"1","step",
  "где вдоль x максимум TKE слоя за уступом, в долях x_r от угла","Driver&Seegmiller 1985; Le&Moin&Kim 1997",MEM,"C","максимум на 80-100 % длины пузыря, перед присоединением")
r("step_z_tke_max","z_tke_max_over_h",1.0,0.7,1.4,"1","step",
  "высота максимума TKE над дном за уступом, в долях h","Driver&Seegmiller 1985; Le&Moin&Kim 1997",MEM,"C","по линии слоя (разделяющей линии тока), не по земле")
r("step_sigma_u_peak","sigma_u_peak_over_U0",0.19,0.16,0.22,"1","step",
  "max sqrt(u'2)/U0 в слое за уступом около x_r","Le&Moin&Kim 1997; Jovic&Driver 1994",MEM,"C","по порядку")
# --- забор
r("fence_xr","xr_over_H",12,10,14,"1","fence",
  "x_r/H от забора высотой H, тонкий сплошной забор, ровный набегающий поток","Castro I.P. 1971 JFM 46:599; Raine&Stevenson 1977; Counihan, Hunt, Jackson 1974 JFM 64:529",MEM,"C","в сдвиговом погранслое короче")
# --- холмы и гряды
r("hill_sep_zone_kf","xr_over_H",2.5,2.0,3.0,"1","hill2d",
  "длина зоны отрыва за естественным холмом / его высота","Kaimal&Finnigan 1994, Atmospheric Boundary Layer Flows (по тексту Menke 2019 Введение)","Menke 2019, введение","A","правило, цитируемое Menke 2019; у острых форм - больше")
r("hill_sep_slope","lee_slope_sep_threshold",0.314,0.26,0.38,"rad","hill2d",
  "средний подветренный угол склона, при котором в нейтральном потоке возникает отрыв на гладком двумерном холме (18°, диапазон 15-22°; в rad)",
  "Hunt, Leibovich, Richards 1988 QJRMS 114:1435; Wood 1995; Kaimal&Finnigan 1994",MEM,"C","на шероховатой поверхности порог выше; острая кромка отрывает всегда")
r("ridge_xr_mean","xr_m",697,"","","m","ridge_field",
  "средняя горизонтальная протяжённость зоны обратного течения (>0,5 м/с, ≥50 м), 10-минутные периоды, Perdigao, 3 разреза",
  MEN,"разд. 4.2","A","ширина долины 1,4 км, превышение 200 м")
r("ridge_xr_over_H","xr_over_H",3.5,2.0,5.0,"1","ridge_field",
  "xr/H, H~200 м превышение гребня над долиной (697 м / 200 м); max глубины 300/215/189 м","Menke 2019 + пересчёт автора","разд. 4.2","C","H в тексте не дана числом (табл. 2 - картинка); диапазон — по разбросу разрезов 22 % и неопределённости H")
r("ridge_depth_mean","depth_over_valley_m",157,"","","m","ridge_field",
  "средняя глубина зоны над дном долины",MEN,"разд. 4.2","A","максимумы 300 м (разрез 1), 215 (2), 189 (3)")
r("ridge_occurrence","recirc_fraction",0.52,0.32,0.69,"1","ridge_field",
  "доля 10-минутных периодов с зоной обратного течения; по разрезам 69/51/32 %; SW-ветер 55 %, NE 49 %",MEN,"резюме, разд. 4.1","A","чаще при U>8 м/с и при Ri<=0")
r("ridge_u_back","u_back_max",4.0,1.4,4.0,"m/s","ridge_field",
  "максимум обратной скорости (>4 м/с); медианы по разрезам 2,0/1,5/1,4 м/с",MEN,"разд. 4.2","A","отношение к набегающему 0,1 - 0,5, ниже 0,3 при U>12 м/с")
r("ridge_ti_case","ti_downwind_ridge",0.31,0.12,0.31,"1","ridge_field",
  "интенсивность турбулентности на 100 м над наветренным гребнем 12 %, над подветренным при зоне 31 % (случай 5.05.2017 16:30, 10,4 м/с, зона 807 м)",MEN,"разд. 4.3.1, табл. 3","A","скорость там -50 %")
r("ridge_ti_increase","ti_increase_downwind_ridge",0.078,0.019,0.078,"1","ridge_field",
  "прирост TI на подветренном гребне при зоне: SW 7,8 %, NE 1,9 % (без зоны 3,1 и 0,8 %); текст резюме даёт 3,1 % для NE",MEN,"разд. 4.3.2, табл. 4","A","в источнике противоречие 1,9 vs 3,1")
r("ridge_wake_height","wake_top_above_peak_m",250,"","","m","ridge_field",
  "высота следа наветренной гряды над вершиной NE (случай 5.05.2017)",MEN,"разд. 4.3.1","A","след шире зоны обратного течения")
# --- критерий отрыва
r("gen_simpson_itd","backflow_fraction_itd",0.01,"","","1","general",
  "по Simpson 1989: доля времени обратного течения у стенки 1 % - начало отрыва (ITD), 20 % - ID, 50 % - TD (отрыв по среднему),  0 напряжения - D",
  "Simpson R.L. 1989, Turbulent boundary-layer separation, Annu. Rev. Fluid Mech. 21:205",MEM,"C","критерий по времени, не по среднему")
r("gen_stratford","stratford_const",0.39,0.35,0.39,"1","general",
  "Cp*sqrt(x*dCp/dx)=0,39*(1e-6*Re_x)^0,1 - отрыв турбулентного погранслоя при нарастающем давлении (0,35 при малых Cp)",
  "Stratford B.S. 1959, J. Fluid Mech. 5:1",MEM,"C","нужно давление из поля; у модели игры есть только скорость")
r("gen_guide_sigma_w_lee","sigma_w_over_du_lee",0.14,0.10,0.18,"1","ridge_field",
  "σ_w/ΔU на 10-50 м в зоне lee_f>0 из текущей модели и упоминаемая в docs/guide/air-model/turbulence.md ссылка на Menke 2019",
  "docs/guide/air-model/turbulence.md; Menke 2019 (числа не найдены в тексте)","Menke 2019 (нет σ_w)","C","ссылка в guide на 0,14ΔU к Menke 2019 не подтверждается текстом статьи; 0,14 совпадает с σ_v/ΔU слоя смешения Pope - использовать как σ_v/ΔU")

# ===== LT-1 доработка 1: убраны все числа «по памяти»; добавлены строки из открытых данных/текстов =====
import json
DROP = {"ml_db_dx_single","ml_sigma_u_peak","ml_sigma_v_peak","ml_sigma_w_peak","ml_tke_peak","ml_ruv","ml_turb_peak_location",
        "ml_integral_lu","ml_integral_lw","ml_uc","step_xr_review","step_u_reverse","step_uv_peak","step_x_tke_max","step_z_tke_max",
        "step_sigma_u_peak","fence_xr","hill_sep_slope","gen_simpson_itd","gen_stratford","gen_guide_sigma_w_lee"}
R[:] = [x for x in R if x[0] not in DROP]
J = json.load(open(os.path.join(HERE, "derived_exp.json")))
f3 = lambda v: round(float(v), 4)
BR = "Brown G.L., Roshko A. 1974, On density effects and large structure in turbulent mixing layers, J. Fluid Mech. 64:775, doi 10.1017/S002211207400190X (Caltech authors m46cp-n2977, открытый PDF)"
DEL = "Delville J., Bellin S., Garem J.H., Bonnet J.P. 1989, Advances in Turbulence 2, Springer, doi 10.1007/978-3-642-83822-4_38; данные: NASA Turbulence Modeling Resource, tmbwg.github.io/turbmodels/delvilleshear_val.html (delville_exp_u/delomega/turb.dat)"
DS = "Driver D.M., Seegmiller H.L. 1985, AIAA J. 23(2):163, doi 10.2514/3.8890; данные: NASA TMR, tmbwg.github.io/turbmodels/backstep_val.html (profiles.exp.dat, cf.exp.dat)"
RM = "Rapp C., Manhart M. 2011, Exp. Fluids 51:247, doi 10.1007/s00348-011-1045-y; Rapp 2009, Dissertation TU München; данные: ERCOFTAC KBwiki UFR 3-30 (kbwiki.ercoftac.org/w/index.php/UFR_3-30_Test_Case), UFR3-30_X_<Re>_data_CR-0NN.dat"
MAN = "Mann J., Angelou N., Sjoholm M., Mikkelsen T., Hansen K.H., Cavar D., Berg J. 2014, Laser scanning of a recirculation zone on the Bolund escarpment, J. Phys.: Conf. Ser. 555:012066, doi 10.1088/1742-6596/555/1/012066"
EX = "extract_exp.py по lit/data (fetch_data.sh)"
# --- Brown & Roshko 1974 (текст прочитан)
r("br74_ddw_dx_over_lambda","ddelta_omega_dx_over_lambda",0.181,0.162,0.181,"1","mixing_layer_two",
  "d(delta_omega)/dx / lambda; delta_omega=(U1-U2)/max(dU/dy), lambda=(U1-U2)/(U1+U2); подгонка прямой по данным многих авторов, rms-отклонение 0,015; при U2=0 среднее 0,178",
  BR,"разд. 5, ф-ла (5.3), рис. 10","A","low=0,162 — Liepmann&Laufer 1947 (в тексте BR74, A); BR74 сами склоняются к 0,16 при lambda=1 и кривой, вогнутой вниз; их слой — газ/газ с разной плотностью")
r("br74_eddy_spacing","eddy_spacing_over_delta_omega",3.3,2.88,3.56,"1","mixing_layer_two",
  "средний шаг крупных вихрей слоя / delta_omega (по теневым снимкам и частоте вихрей при допущении переноса вихрей со средней скоростью (U1+U2)/2)",
  BR,"разд. 8, оценки 2,96; 3,56; 3,36; 2,88; 3,38 delta_omega","A","допущение скорости переноса в самом источнике (Uc = среднее) — не измерение; r=0,36 и 0,6")
# --- Delville (данные TMR)
d = J["delville"]; d950 = d["x=950mm"]; lam = J["lam"]
r("del_dw950","delta_omega_mm",50.547,"","","mm","mixing_layer_two","delta_omega=(U1-U2)/max(dU/dy), x=950 мм от конца разделительной пластины",DEL,"delville_exp_delomega.dat","A","U_hi=41,54, U_lo=22,40 м/с, dU=19,14 м/с, lambda=0,299; пограничные слои на пластине turbulent, theta=1,0 и 0,73 мм")
r("del_ddw_dx","ddelta_omega_dx",f3(J["ddw_dx"]),f3(min(J["ddw_dx_seg"])),0.0503,"1","mixing_layer_two",
  "d(delta_omega)/dx, линейная подгонка по x=300-1050 мм; low — наклоны 200-650 и 650-1050 мм",DEL,"delville_exp_delomega.dat",
  "C","пересчёт A-таблицы: np.polyfit(x,delta_omega,1) — "+EX)
r("del_ddw_dx_over_lambda","ddelta_omega_dx_over_lambda",f3(J["ddw_dx"]/lam),0.164,0.168,"1","mixing_layer_two",
  "(d delta_omega/dx)/lambda, lambda=(41,54-22,40)/(41,54+22,40)=0,299",DEL,"del_ddw_dx / lambda","C","согласуется с BR74 0,181+-0,015 снизу (меньше на 7 %); слой Делвиля — конечная длина канала (x<=1050 мм), самоподобие не гарантировано")
def DL(id_, q, key, d_, lo, hi, tag):
    r(id_,q,f3(d950[key]),f3(min(v[key] for v in d.values())) if lo is None else lo, f3(max(v[key] for v in d.values())) if hi is None else hi,"1","mixing_layer_two",d_,DEL,"delville_exp_turb.dat, ZONE x=200/650/950 мм","A" if tag=="A" else "C","value — x=950 мм (самый развитый), low/high — по трём сечениям; "+EX)
DL("del_sigma_u_peak","sigma_u_peak_over_du","su","max по сечению sqrt(u'u')/dU, dU=19,14 м/с (x=950 мм); разброс 200-950 мм",None,None,"A")
DL("del_sigma_v_peak","sigma_v_peak_over_du","sv","max sqrt(v'v')/dU",None,None,"A")
DL("del_sigma_w_peak","sigma_w_peak_over_du","sw","max sqrt(w'w')/dU",None,None,"A")
DL("del_uv_peak","uv_peak_over_du2","uv","max(-u'v')/dU^2; MW85 даёт 0,011 (A, строка ml_uv_peak)",None,None,"A")
DL("del_tke_peak","tke_peak_over_du2","k","max 0,5(u'u'+v'v'+w'w')/dU^2, все три компоненты измерены",None,None,"C")
DL("del_ruv_peak","corr_uv","ruv","-u'v'/(sqrt(u'u')*sqrt(v'v')) в точке пика напряжения",None,None,"C")
DL("del_uv_fwhm","uv_fwhm_over_delta_omega","fwhm","ширина профиля -u'v' на половине пика, в долях delta_omega",None,None,"C")
r("del_uv_ypk","y_uv_peak_over_delta_omega",f3(d950["uv_y"]),f3(d950["uv_y"]),f3(max(v["uv_y"] for v in d.values())),"1","mixing_layer_two","y/delta_omega положения пика -u'v' (y>0 — к быстрой стороне), y от линии слоя (y исправлен на 0,00688x)",DEL,"delville_exp_turb.dat","A","пик смещён к медленной стороне на 0,02-0,1 delta_omega: "+EX)
r("del_k_ypk","y_tke_peak_over_delta_omega",f3(d950["k_y"]),f3(min(v["k_y"] for v in d.values())),f3(max(v["k_y"] for v in d.values())),"1","mixing_layer_two","y/delta_omega положения пика TKE (u,w — у центра слоя)",DEL,"delville_exp_turb.dat","A","шаг сетки по y ~0,06 delta_omega, поэтому положения различимы с точностью +-0,05: "+EX)
r("del_su_prof_half","sigma_u_over_peak_at_half_dw",f3(sum(d950["su_half"])/2),f3(min(d950["su_half"])),f3(max(d950["su_half"])),"1","mixing_layer_two","sigma_u(y)/sigma_u_peak на |y|=0,5 delta_omega (профиль поперёк слоя, x=950 мм); на |y|=delta_omega - "+str(f3(sum(d950["su_one"])/2)),DEL,"delville_exp_turb.dat","C","приближённо гауссов профиль со стандартным отклонением ~0,49 delta_omega: интерполяция профиля, "+EX)
# --- Driver & Seegmiller (данные TMR), уступ, H = высота уступа, Uref
S = J["step"]
r("ds_xr","xr_over_h",f3(J["step_xr"]),J["step_xr_br"][0],J["step_xr_br"][1],"1","step","x_r/H: линейная интерполяция нуля cf нижней стенки между x/H=5,882 и 7,090",DS,"cf.exp.dat","C","пересчёт A-таблицы cf ("+EX+"); Re_H~36000; шаг точек cf 1-2H, погрешность x_r ~±0,6H")
r("ds_uback","u_back_min_over_uref",f3(S["4"]["umin"]),f3(S["4"]["umin"]),f3(S["1"]["umin"]),"1","step","min u/Uref на сечении x/H=4 (y/H=0,1, крайняя точка профиля); на x/H=1 -0,035",DS,"profiles.exp.dat, zone x/H=4","A","обратный ток ~0,17 Uref; ближайшая к стенке точка может быть не минимумом: "+EX)
for xh in ("1","4","6","10"):
    q=S[xh]
    r(f"ds_su_x{xh}","sigma_u_peak_over_uref",f3(q["su"]),"","","1","step",f"max sqrt(u'u')/Uref по профилю x/H={xh} (y/H пика {q['su_y']})",DS,"profiles.exp.dat","A","x/xr="+str(round(int(xh)/J["step_xr"],2))+"; "+EX)
    r(f"ds_uv_x{xh}","uv_peak_over_uref2",f3(q["uv"]),"","","1","step",f"max(-u'v')/Uref^2 по профилю x/H={xh} (y/H пика {q['uv_y']})",DS,"profiles.exp.dat","A",EX)
r("ds_sv_x4","sigma_v_peak_over_uref",f3(S["4"]["sv"]),"","","1","step","max sqrt(v'v')/Uref, x/H=4",DS,"profiles.exp.dat","A","y/H пика "+str(S["4"]["sv_y"]))
r("ds_k2_x4","k2d_peak_over_uref2",f3(S["4"]["k2"]),f3(S["1"]["k2"]),f3(S["4"]["k2"]),"1","step","max 0,5(u'u'+v'v')/Uref^2 (w'w' не измерено) на x/H=4; на x/H=1 - "+str(f3(S["1"]["k2"]))+", x/H=6 - "+str(f3(S["6"]["k2"]))+", x/H=10 - "+str(f3(S["10"]["k2"])),DS,"profiles.exp.dat","C",EX)
r("ds_x_tke_max","x_tke_max_over_xr",round(4/J["step_xr"],2),round(1/J["step_xr"],2),round(6/J["step_xr"],2),"1","step","x/x_r станции с наибольшим k2d среди x/H=1,4,6,10 (x/H=4); максимум между x/H=1 и 6, точнее профили не снимали",DS,"profiles.exp.dat","C","4 станции — грубо; 0,64 x_r, а не 0,9: максимум раньше присоединения; "+EX)
r("ds_y_tke_max","y_tke_max_over_h",S["4"]["su_y"],S["6"]["su_y"],S["1"]["su_y"],"1","step","y/H максимума sqrt(u'u') на x/H=4 (высота от нижней стенки; ступенька y/H=1); на x/H=1 - 1,0, x/H=6 - 0,3, x/H=10 - 0,6",DS,"profiles.exp.dat","A","слой опускается к стенке до присоединения: линия слоя ниже кромки уступа, "+EX)
for xh in ("1","4","6"):
    r(f"ds_dw_x{xh}","delta_omega_over_h",f3(S[xh]["dw"]),"","","1","step",f"delta_omega=(Umax-Umin)/max(dU/dy) профиля x/H={xh}, H",DS,"profiles.exp.dat","C","градиент по узлам профиля (шаг 0,1-0,2 H): погрешность ~20 %; "+EX)
r("ds_ddw_dx_1_4","ddelta_omega_dx",f3((S["4"]["dw"]-S["1"]["dw"])/3),f3((S["6"]["dw"]-S["4"]["dw"])/2),f3((S["4"]["dw"]-S["1"]["dw"])/3),"1","step","(delta_omega(4)-delta_omega(1))/3 (x/H); low - наклон 4-6; сильное замедление роста у присоединения",DS,"ds_dw_x*","C","рост слоя у уступа (0,18) близок к плоскому слою при lambda~1 (0,16-0,18); у присоединения падает вдвое: "+EX)
# --- периодический холм (Rapp & Manhart; u_b — среднерасходная над гребнем, h — высота холма)
Hh = J["hill"]; a, b = Hh["10600"], Hh["37000"]
r("hill_xr","xr_over_h",round(a["xr"],2),round(b["xr"],2),4.5,"1","hill2d","x_r/h (h - высота холма): нуль u в крайней точке профиля y/h~0,05 (Re 10600: 4,0; Re 37000: 3,55); high - значение 'about 4,5' на странице KBwiki",RM,"UFR3-30_X_*_CR-006/007 + текст страницы","C","интерполяция A-таблиц, x_r на уровне 0,05h может отличаться от точки на стенке; канал высотой 3,036h сжимает поток; "+EX)
for xh in ("0.5","2","4","6","8"):
    r(f"hill_su_x{xh.replace('.','p')}","sigma_u_peak_over_ub",f3(a["rows"][xh]["su"]),f3(b["rows"][xh]["su"]),f3(a["rows"][xh]["su"]),"1","hill2d",f"max sqrt(u'u')/u_b на x/h={xh}, Re=10600 (low - Re=37000); y/h пика {a['rows'][xh]['su_y']}",RM,"UFR3-30_X_10600_*.dat","A","u_b - среднерасходная скорость над гребнем (не dU слоя): "+EX)
r("hill_uv_pk","uv_peak_over_ub2",f3(a["rows"]["1"]["uv"]),f3(b["rows"]["1"]["uv"]),f3(a["rows"]["1"]["uv"]),"1","hill2d","max(-u'v')/u_b^2 на x/h=1 (максимум по станциям при Re=10600), low - Re=37000 (максимум на x/h=2: "+str(f3(b["rows"]["2"]["uv"]))+")",RM,"UFR3-30_X_*_CR-003.dat","A",EX)
r("hill_k2_max","k2d_peak_over_ub2",f3(a["rows"]["1"]["k2"]),f3(b["rows"]["2"]["k2"]),f3(a["rows"]["1"]["k2"]),"1","hill2d","max 0,5(u'u'+v'v')/u_b^2 по сечениям: Re=10600 на x/h=1, Re=37000 (low) на x/h=2",RM,"UFR3-30_X_*.dat","C",EX)
r("hill_x_tke_max","x_tke_max_over_xr",round(1/a["xr"],2),round(1/a["xr"],2),round(2/b["xr"],2),"1","hill2d","x/x_r станции с наибольшим k2d (Re=10600: x/h=1; Re=37000: x/h=2 -> x/x_r=0,56)",RM,"UFR3-30_X_*.dat","C","максимум турбулентности далеко от присоединения (0,25-0,56), в отличие от гипотезы 0,8-1,0 x_r; шаг станций 1h; "+EX)
r("hill_ypk","y_su_peak_over_h",a["rows"]["1"]["su_y"],a["rows"]["4"]["su_y"],a["rows"]["0.5"]["su_y"],"1","hill2d","y/h пика sqrt(u'u') над плоским дном (x/h>1.93) / над склоном: x/h=1: 1,05, x/h=3: "+str(a["rows"]["3"]["su_y"])+", x/h=4: "+str(a["rows"]["4"]["su_y"])+", x/h=6: "+str(a["rows"]["6"]["su_y"])+" (Re=10600)",RM,"UFR3-30_X_10600_*.dat","A","y считаем от плоскости дна; линия слоя ~ на высоте гребня, опускается до ~0,8h к x/h=3-4 и поднимается после присоединения: "+EX)
r("hill_uback","u_back_min_over_ub",f3(a["rows"]["2"]["umin"]),f3(a["rows"]["2"]["umin"]),f3(b["rows"]["2"]["umin"]),"1","hill2d","min u/u_b на сечении x/h=2 (y/h=0,09), Re=10600; Re=37000: "+str(f3(b["rows"]["2"]["umin"])),RM,"UFR3-30_X_*_CR-004.dat","A",EX)
# --- Bolund (лидар Mann и др.)
r("bolund_layer_h","turb_layer_height_m",3.5,2.0,5.0,"m","escarpment","высота турбулентного слоя за уступом на расстоянии ~6 м от кромки, ветер с запада; интерфейс медленный/быстрый воздух колеблется вверх-вниз",MAN,"рис. 7, подпись","A","слой над землёй: 'strongest velocity fluctuations are elevated from the ground' (разд. 4, рис. 6) — качественно; низ слоя - обратный средний ветер; число - середина диапазона 2-5 м")
w = csv.writer(open(os.path.join(HERE, "lit_numbers.csv.tmp"), "w", newline="", encoding="utf-8"))
w.writerow("id,quantity,value,low,high,unit,flow,definition,source,where,reliability,note".split(","))
w.writerows(R)
os.replace(os.path.join(HERE, "lit_numbers.csv.tmp"), os.path.join(HERE, "lit_numbers.csv"))
print(len(R), "rows")
