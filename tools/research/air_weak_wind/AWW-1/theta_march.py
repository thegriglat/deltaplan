"""AWW-1, диагноз 1: баланс θ′ механизма F вдоль ветра (air_phase.glsl K_THINIT/K_THETA, air_phase_cpu.gd theta)
на полосе море → суша (и суша → море → суша), 1D вдоль ветра (ex = 1): точное решение цепочки
θ′(i) = θ′_in(i)·e^{−Δt/τ} + s(i), Δt = dx/U_ML, s = H_k/h·τ·(1 − e^{−Δt/τ}).
Варианты: cur — как в main (переносится θ′); tw2 — переносится E = θ′·h, θ′ = E/h (proto_theta_energy.patch);
tw3 — θ′_in = E_up/max(h, h_up) (ветка archive/takeoff-wind-TW-3). Числа случая — старт «Термики» (probe, main):
море h = 15 м (замыкание: u* 0,077, H −18 Вт/м²), суша h_bl 1691 м, H 301 Вт/м², U_ML 2,45 м/с, dx 400, τ 7200 с.
Запуск: python3 theta_march.py > out/theta_march.json
"""
import json
import math

RHO_CP = 1.2 * 1005.0


def march(cells, U=2.45, dx=400.0, tau=7200.0, variant="cur"):
    """cells: список (h, H_wm2). Возвращает θ′ по клеткам, К."""
    fa = math.exp(-dx / U / tau)
    th = []
    e_up, h_up, th_up = 0.0, None, 0.0
    for h, H in cells:
        hk = H / RHO_CP
        h = max(h, 1.0)
        if variant == "cur":
            s = hk / h * tau * (1 - fa)
            t = th_up * fa + s
            th.append(t)
            th_up = t
        elif variant == "tw2":
            s = hk * tau * (1 - fa)
            e = e_up * fa + s
            th.append(e / h)
            e_up = e
        elif variant == "tw3":
            s = hk / h * tau * (1 - fa)
            t_in = 0.0 if h_up is None else (th_up * h_up) / max(h, h_up)
            t = t_in * fa + s
            th.append(t)
            th_up, h_up = t, h
        else:
            raise ValueError(variant)
    return th


def heat_content(cells, th):
    return [t * max(h, 1.0) for (h, _), t in zip(cells, th)]


def main():
    sea = (15.0, -18.0)
    land = (1691.0, 301.0)
    out = {}
    # море (40 клеток = 16 км разгона, как южнее острова) → суша (15 клеток = 6 км)
    cells = [sea] * 40 + [land] * 15
    case = {}
    for v in ("cur", "tw2", "tw3"):
        th = march(cells, variant=v)
        e = heat_content(cells, th)
        case[v] = {
            "theta_sea_last": th[39], "theta_land_first": th[40], "theta_land_5": th[44], "theta_land_last": th[54],
            "E_sea_last_Km": e[39], "E_land_first_Km": e[40],
            "theta_land_if_no_sea": march([land] * 15, variant=v)[0:5],
        }
    out["sea_to_land"] = case
    # суша (15) → море (10 клеток, 4 км пролив) → суша (15): раздувается ли θ′ над тонким слоем
    cells2 = [land] * 15 + [sea] * 10 + [land] * 15
    case2 = {}
    for v in ("cur", "tw2", "tw3"):
        th = march(cells2, variant=v)
        case2[v] = {"theta_land_last_before_sea": th[14], "theta_sea_first": th[15], "theta_sea_last": th[24],
                    "theta_land_after": th[25], "theta_land_after_5": th[29]}
    out["land_sea_land"] = case2
    # однородная суша: все варианты совпадают
    th_u = {v: march([land] * 15, variant=v)[-1] for v in ("cur", "tw2", "tw3")}
    out["uniform_land_last"] = th_u
    # над морем: установившееся θ′ = H_k·τ/h (cur)
    out["sea_steady_cur_K"] = sea[1] / RHO_CP * 7200.0 / 15.0
    out["sea_steady_E_Km"] = sea[1] / RHO_CP * 7200.0
    out["notes"] = [
        "cur: θ′ моря −7 К переносится на сушу как есть и ставится на слой 1691 м — тепло ×113 (h_суши/h_моря)",
        "tw2: E переносится, θ′ = E/h — на суше разбавлено; но суша → море даёт θ′ = E/h_моря (раздувание, см. land_sea_land)",
        "tw3: E/max(h, h_up) — разбавление при росте слоя, сохранение θ′ при утонении; однородно — как cur",
    ]
    print(json.dumps(out, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
