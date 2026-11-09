#!/usr/bin/env python3
"""Собирает lit_numbers.csv (LTL v1) из таблицы ниже. Запуск: python3 build_lit.py"""
import csv, os
HERE = os.path.dirname(os.path.abspath(__file__))
MW = "Mehta R.D., Westphal R.V. 1985, An Experimental Study of Plane Mixing Layer Development, NASA TM-86698 (ntrs.nasa.gov 19850021659)"
LMK = "Le H., Moin P., Kim J. 1997, DNS of turbulent flow over a backward-facing step, J. Fluid Mech. 330:349, doi 10.1017/S0022112096003777"
MKM = "Mansour N.N., Kim J., Moin P. 1984, Computation of Turbulent Flows Over a Backward-Facing Step, NASA TM-85851"
MEN = "Menke R., Vasiljevic N., Mann J., Lundquist J.K. 2019, Characterization of flow recirculation zones at the Perdigao site using multi-lidar measurements, Atmos. Chem. Phys. 19:2713, doi 10.5194/acp-19-2713-2019"
MEM = "по памяти автора, текст источника не открывался; сверить перед использованием как порог"
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
  MW+"; пересчёт автора","1,812/sigma0=0,165; измерения 0,031-0,033 при lambda=0,37 -> 0,152-0,162","C","пересчёт erf-масштаба a в B; верх 0,18 — классика Brown&Roshko 1974 (по памяти)")
r("ml_ddelta_omega_dx_over_lambda","ddelta_omega_dx_over_lambda",0.16,0.15,0.18,"1","mixing_layer_two",
  "d(delta_omega)/dx / lambda, delta_omega=(U1-U2)/max(dU/dy); lambda=(U1-U2)/(U1+U2); erf-профиль: delta_omega=sqrt(pi)*a",
  MW+"; пересчёт автора","delta_omega'=sqrt(pi)*lambda/sigma0=0,161*lambda","C","Brown&Roshko 1974 JFM 64:775, Dimotakis 1991 AIAA-91-0978 дают 0,16-0,18 (по памяти)")
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
r("ml_kh_wavelength_delta_omega","lambda_x_over_delta_omega0",7.5,7.0,8.0,"1","mixing_layer_two",
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
w = csv.writer(open(os.path.join(HERE, "lit_numbers.csv.tmp"), "w", newline="", encoding="utf-8"))
w.writerow("id,quantity,value,low,high,unit,flow,definition,source,where,reliability,note".split(","))
w.writerows(R)
os.replace(os.path.join(HERE, "lit_numbers.csv.tmp"), os.path.join(HERE, "lit_numbers.csv"))
print(len(R), "rows")
