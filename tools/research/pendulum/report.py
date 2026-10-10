"""Итог прогона: таблицы (out/tables.md), ключевые числа (out/summary.json), графики (out/fig/*.png).
Графики — для статьи/пользователя; проверка — по таблицам.

Запуск:  python report.py
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from pendulum.game_ref import GameModel  # noqa: E402
from pendulum.params import GAME_REF  # noqa: E402

OUT = HERE / "out"
W = ["training", "laminar", "sport"]
WN = {"training": "учебное (Falcon)", "laminar": "мачтовое (Laminar)", "sport": "безмачтовое (Litespeed)"}


def load():
    return json.loads((OUT / "results.json").read_text())


def g(R, key, field, nd=1):
    v = R.get(key, {}).get("res", {}).get(field)
    if v is None:
        return "—"
    if isinstance(v, bool):
        return "да" if v else "нет"
    if isinstance(v, (int, float)):
        return f"{v:.{nd}f}".replace(".", ",")
    return str(v)


def head_band(key, lo=0.3, hi=3.0):
    """Голова поперёк в осях крыла: СКО в полосе lo..hi Гц (раскачка, а не медленные манёвры) и
    частота пика в этой полосе. Ряды — каждые 2 шага (1/60 с)."""
    f = OUT / "series" / (key.replace("/", "__") + ".npz")
    if not f.exists():
        return None
    d = np.load(f)
    t, y = d["series.t"], d["series.hy"]
    m = t > 10
    y = y[m] - y[m].mean()
    dt = float(np.median(np.diff(t)))
    F = np.fft.rfft(y)
    fr = np.fft.rfftfreq(len(y), dt)
    band = (fr >= lo) & (fr <= hi)
    yb = np.fft.irfft(np.where(band, F, 0), len(y))
    a = np.abs(F)
    return float(yb.std()), float(fr[band][np.argmax(a[band])])


def game_numbers():
    out = {}
    for w in W:
        gm = GameModel(w)
        t, ph, _ = gm.roll_run(lambda t, phi, p: -1.0, phi0=math.radians(45), T=8)
        i = np.where(ph <= math.radians(-45))[0]
        t30, ph30, _ = gm.roll_run(lambda t, phi, p: -1.0, phi0=math.radians(30), T=8)
        j = np.where(ph30 <= math.radians(-30))[0]
        out[w] = {"rev45": float(t[i[0]]) if len(i) else None, "rev30": float(t30[j[0]]) if len(j) else None}
    return out


def tables(R):
    gn = game_numbers()
    L = []
    L.append("## Трим и продольный канал\n")
    L.append("| Крыло | V трим, км/ч (паспорт) | снижение, м/с | α киля, ° | тангаж киля, ° | Kn | подвеска игры, м от носа | нейтр. точка, м | Cm0 паруса | км/ч на 1 см подвески вперёд | полный «на себя», км/ч (игра) | полный «от себя», км/ч (игра) | усилие «на себя», Н |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for w in W:
        t = f"trim/{w}/free"
        hs = f"hang_sens/{w}"
        b = f"bar/{w}/free"
        L.append(f"| {WN[w]} | {g(R,t,'V_kmh')} ({g(R,t,'V_trim_passport_kmh')}) | {g(R,t,'sink_ms',2)} | {g(R,t,'alpha_deg')} | {g(R,t,'theta_deg')} | {g(R,t,'Kn',3)} | {g(R,hs,'x_hang_game',3)} | {g(R,hs,'x_np',3)} | {g(R,hs,'dcm0_at_game_hang',3)} | {g(R,hs,'kmh_per_cm_forward',2)} | {g(R,b,'V_kmh_-1.0')} ({g(R,b,'game_full_pull_kmh')}) | {g(R,b,'V_kmh_+1.0')} ({g(R,b,'game_full_push_kmh')}) | {g(R,b,'fx_N_-1.0',0)} |")
    L.append("\n## Фугоида (толчок +3 м/с, руки в нейтрали)\n")
    L.append("| Крыло | период, с | отношение амплитуд за период | игра без phugoid_damping: период / отношение | игра как есть: период / отношение |")
    L.append("|---|---|---|---|---|")
    for w in W:
        k = f"phugoid/{w}/free"
        L.append(f"| {WN[w]} | {g(R,k,'period_s')} | {g(R,k,'amp_ratio_per_period',2)} | {g(R,k,'game_nodamp_period_s')} / {g(R,k,'game_nodamp_amp_ratio',2)} | {g(R,k,'game_period_s')} / {g(R,k,'game_amp_ratio',2)} |")
    L.append("\n## Крен: прототип против игры (weight_shift)\n")
    L.append("Варианты прототипа: **A** — без скольжения (курс по воздушной скорости, этап A как задан); **B** — рыскание и скольжение свободны (Cnβ 0,06), гибкий парус по опыту Ochi (flex_relief 0,2, эфф. поперечное V 1°) — основной; **B жёсткое** — то же без крутки паруса (flex_relief 1).\n")
    L.append("| Крыло | вариант | переложение 45→45, с (игра) | 30→30, с (игра) | крен через 2 с полного смещения, ° | крен через 4 с, ° | до 30°, с | выравнивание из центра после 2 с смещения, с (игра) | крен через 10 с после «в центр», ° | overbank: крен через 6 с в центре, ° (старт) | выход до 30° полным смещением, с |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|")
    for w in W:
        for tag, suf in (("A", f"{w}/noslip"), ("B", f"{w}/free"), ("B жёсткое", f"{w}/free/rigid")):
            g45 = "не достаёт" if gn[w]["rev45"] is None else f"{gn[w]['rev45']:.1f}".replace(".", ",")
            L.append(
                f"| {WN[w]} | {tag} | {g(R,'reversal/'+suf,'t_to_minus')} ({g45}) | "
                f"{g(R,'reversal30/'+suf,'t_to_minus')} ({str(round(gn[w]['rev30'], 1)).replace('.', ',')}) | {g(R,'full_shift/'+suf,'phi_2s')} | {g(R,'full_shift/'+suf,'phi_4s')} | {g(R,'full_shift/'+suf,'t_to_30')} | "
                f"{g(R,'center/'+suf,'t_level')} ({GAME_REF[w]['center_level_s']}) | {g(R,'center/'+suf,'phi_10s')} | {g(R,'spiral/'+suf,'phi_after_center_6s')} ({g(R,'spiral/'+suf,'phi_start')}) | {g(R,'spiral/'+suf,'t_exit_to_30')} |")
    L.append("\n## Термик на краю крыла (ядро 3 м/с, R 25 м, 15 м справа от линии полёта), руки в нейтрали\n")
    L.append("| Крыло | вариант | экстремум крена, ° (когда, с) | игра: экстремум, ° (когда, с) | смена курса за 14 с, ° |")
    L.append("|---|---|---|---|---|")
    for w in W:
        for tag, suf in (("A", f"{w}/noslip"), ("B", f"{w}/free"), ("B жёсткое", f"{w}/free/rigid")):
            k = "thermal_edge/" + suf
            L.append(f"| {WN[w]} | {tag} | {g(R,k,'phi_extreme')} ({g(R,k,'t_extreme')}) | {g(R,k,'game_phi_extreme')} ({g(R,k,'game_t_extreme')}) | {g(R,k,'psi_change',0)} |")
    L.append("\n## Маятник и болтанка (σ 1 м/с, L 40 м; пилот мягко держит горизонт)\n")
    L.append("| Крыло | вариант | период качания пилота поперёк / вдоль, с (математический маятник) | затухание за период поперёк / вдоль | СКО смещения пилота поперёк, м | СКО крена пилота отн. крыла, ° | СКО крена, ° | голова в осях крыла: СКО поперёк / вдоль / верт., см | голова поперёк в полосе 0,3–3 Гц: СКО, см / пик, Гц | усилие рук СКО поперёк, Н |")
    L.append("|---|---|---|---|---|---|---|---|---|---|")
    for w in W:
        for tag, suf in (("A", f"{w}/noslip"), ("B", f"{w}/free"), ("B жёсткое", f"{w}/free/rigid")):
            p = "pendulum/" + suf
            t = "turbulence/" + suf
            hy = R.get(t, {}).get("res", {})
            heads = "—"
            hbv = head_band(t)
            hb = "—" if hbv is None else f"{hbv[0]*100:.1f} / {hbv[1]:.2f}".replace(".", ",")
            if hy:
                heads = f"{hy.get('head_std_y_m',0)*100:.1f} / {hy.get('head_std_x_m',0)*100:.1f} / {hy.get('head_std_z_m',0)*100:.1f}".replace(".", ",")
            L.append(f"| {WN[w]} | {tag} | {g(R,p,'lat_period_s',2)} / {g(R,p,'lon_period_s',2)} ({g(R,p,'simple_pendulum_s',2)}) | {g(R,p,'lat_ratio_per_period',2)} / {g(R,p,'lon_ratio_per_period',2)} | {g(R,t,'std_rel_y_m',3)} | {g(R,t,'std_pilot_vs_wing_roll_deg')} | {g(R,t,'std_phi')} | {heads} | {hb} | {g(R,t,'fh_y_rms',0)} |")
    L.append("\n## Ввод в вираж: пилот относительно крыла (полное смещение из горизонта)\n")
    L.append("Угол стропы к оси крыла = asin(смещение поперёк / 1,24 м).\n")
    L.append("| Крыло | вариант | макс. смещение пилота поперёк за 4 с, м (угол, °) | крен крыла через 2 с, ° | усилие рук поперёк, макс., Н |")
    L.append("|---|---|---|---|---|")
    for w in W:
        for tag, suf in (("B", f"{w}/free"), ("B жёсткое", f"{w}/free/rigid")):
            f_ = OUT / "series" / (f"full_shift/{suf}".replace("/", "__") + ".npz")
            if not f_.exists():
                continue
            d = np.load(f_)
            t = d["series.t"]
            m = t <= 4
            ry = d["series.rel_y"][m]
            k = np.argmax(np.abs(ry))
            ang = math.degrees(math.asin(max(-1.0, min(1.0, ry[k] / 1.24))))
            L.append(f"| {WN[w]} | {tag} | {ry[k]:.2f} ({ang:.0f}) | {math.degrees(np.interp(2.0, t, d['series.phi'])):.0f} | {np.abs(d['series.fh_y'][m]).max():.0f} |".replace(".", ","))
    L.append("\n## Разбег (склон 15°, руки на стойках → после отрыва на штанге)\n")
    L.append("| Крыло | ветер, м/с | стропа несёт ½ веса пилота, с | отрыв (ступни над землёй), с | путь до отрыва, м | воздушная скорость отрыва, км/ч |")
    L.append("|---|---|---|---|---|---|")
    for w in W:
        for wind in ("0", "3"):
            k = f"ground_run/{w}/wind{wind}"
            L.append(f"| {WN[w]} | {wind} | {g(R,k,'t_strap_half_load')} | {g(R,k,'t_liftoff')} | {g(R,k,'x_liftoff')} | {g(R,k,'v_liftoff_kmh')} |")
    L.append("\n## Калибровка по лётному опыту (Takamatsu & Ochi 2022, Sport 2 155 ≈ laminar, пилот 72,6 кг): постоянное усилие рук вбок 8,5 с\n")
    L.append("Опыт: крен ≈ 30° за ≈ 7 с, затем вираж ≈ 33° с усилием < 10 Н. Цель — строка, где крен через 7 с ≈ 30°, а после — держится с малым усилием.\n")
    L.append("| усилие, Н | flex_relief | эфф. поперечное V, ° | крен через 7 с, ° | макс. крен, ° | крен после (3–9 с), ° | усилие после, сред./макс., Н | макс. скольжение, ° |")
    L.append("|---|---|---|---|---|---|---|---|")
    for k in sorted(x for x in R if x.startswith("ochi/")):
        r = R[k]["res"]
        if not r:
            continue
        _, F, rel, dd = k.split("/")
        L.append(f"| {F[1:]} | {rel[6:]} | {dd[3:]} | {r['phi_7s']:.1f} | {r['phi_max']:.1f} | {r['phi_after_mean']:.1f} | {r['fy_after_mean']:.0f} / {r['fy_after_absmax']:.0f} | {r['beta_max']:.0f} |".replace(".", ","))
    L.append("\n## Численная схема (безмачтовое, вариант B): подшаги × звенья цепи\n")
    L.append("| dt, с | подшагов | N звеньев | переложение 45→45, с | крен через 2 с, ° | СКО смещения пилота, м | макс. растяжение цепи, см | развал |")
    L.append("|---|---|---|---|---|---|---|---|")
    for k in sorted(x for x in R if x.startswith("numerics/")):
        r = R[k]["res"]
        parts = k.split("/")
        dt = "1/120"
        sub = parts[2]
        n = parts[3] if len(parts) > 3 else ""
        if sub.startswith("dt"):
            dt = "1/" + sub[2:]
            sub, n = parts[3], parts[4]
        L.append(f"| {dt} | {sub.replace('sub','')} | {n.replace('N','')} | {g(R,k,'rev_t',2)} | {g(R,k,'rev_phi_t2',2)} | {g(R,k,'turb_std_rel_y',4)} | {(r.get('max_stretch_m') or 0)*100:.1f} | {g(R,k,'blowup')} |".replace(".", ","))
    L.append("\n## Число полос (безмачтовое, вариант B)\n")
    L.append("| полос | переложение 45→45, с | крен при «в центр», ° | крен через 10 с после «в центр», ° |")
    L.append("|---|---|---|---|")
    for ns in (4, 8, 16, 32):
        rk = f"strips/reversal/sport/n{ns}" if ns != 16 else "reversal/sport/free"
        ck = f"strips/center/sport/n{ns}" if ns != 16 else "center/sport/free"
        L.append(f"| {ns} | {g(R,rk,'t_to_minus',2)} | {g(R,ck,'phi_at_release')} | {g(R,ck,'phi_10s')} |")
    L.append("\n## Чувствительность к оценочным параметрам (вариант B)\n")
    L.append("| Крыло | параметр=значение | переложение 45→45, с | крен через 10 с после «в центр», ° | overbank: крен через 6 с в центре, ° | выход до 30°, с |")
    L.append("|---|---|---|---|---|---|")
    for w in ("training", "sport"):
        L.append(f"| {WN[w]} | (база) | {g(R,f'reversal/{w}/free','t_to_minus')} | {g(R,f'center/{w}/free','phi_10s')} | {g(R,f'spiral/{w}/free','phi_after_center_6s')} | {g(R,f'spiral/{w}/free','t_exit_to_30')} |")
        keys = sorted({k.split("/")[2] for k in R if k.startswith(f"sens/{w}/")})
        for pv in keys:
            b = f"sens/{w}/{pv}/"
            if b + "reversal" not in R:
                continue
            L.append(f"| {WN[w]} | {pv} | {g(R,b+'reversal','t_to_minus')} | {g(R,b+'center','phi_10s')} | {g(R,b+'spiral','phi_after_center_6s')} | {g(R,b+'spiral','t_exit_to_30')} |")
    L.append("\n## Длина подвески: маятник и болтанка (вариант B)\n")
    L.append("| Крыло | L, м | период поперёк, с | СКО смещения пилота, м | голова поперёк СКО, см |")
    L.append("|---|---|---|---|---|")
    for w in ("training", "sport"):
        for L_ in ("1.0", "1.2", "1.4"):
            if L_ == "1.2":
                pk, tk = f"pendulum/{w}/free", f"turbulence/{w}/free"
            else:
                pk, tk = f"sens/{w}/hang_len={L_}/pendulum", f"sens/{w}/hang_len={L_}/turbulence"
            hy = R.get(tk, {}).get("res", {}).get("head_std_y_m")
            L.append(f"| {WN[w]} | {L_.replace('.', ',')} | {g(R,pk,'lat_period_s',2)} | {g(R,tk,'std_rel_y_m',3)} | {'—' if hy is None else f'{hy*100:.1f}'.replace('.', ',')} |")
    errs = [k for k, v in R.items() if v.get("err")]
    if errs:
        L.append("\n## Ошибки прогона\n")
        for k in errs:
            L.append(f"- {k}: {R[k]['err'].strip().splitlines()[-1]}")
    return "\n".join(L) + "\n", gn


def figures(R):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig_dir = OUT / "fig"
    fig_dir.mkdir(exist_ok=True)
    sd = OUT / "series"

    def ser(key):
        f = sd / (key.replace("/", "__") + ".npz")
        return np.load(f) if f.exists() else None

    cols = {"noslip": "#888888", "free": "#1f77b4", "free/rigid": "#d62728"}
    lbl = {"noslip": "A: без скольжения", "free": "B: скольжение + гибкий парус", "free/rigid": "B: жёсткое крыло"}
    for sc, field, title, fname in (
        ("full_shift", "series", "Полное смещение вправо из горизонта", "full_shift"),
        ("reversal", "series", "Переложение 45→45 полным смещением", "reversal"),
        ("center", "series", "2 с полного смещения, затем «в центр»", "center"),
    ):
        fig, axs = plt.subplots(1, 3, figsize=(15, 4), sharey=True)
        for ax, w in zip(axs, W):
            for v in ("noslip", "free", "free/rigid"):
                d = ser(f"{sc}/{w}/{v}")
                if d is not None:
                    ax.plot(d[f"{field}.t"], np.degrees(d[f"{field}.phi"]), color=cols[v], label=lbl[v])
            gm = GameModel(w)
            if sc == "full_shift":
                t, ph, _ = gm.roll_run(lambda t, phi, p: 1.0, T=15)
            elif sc == "reversal":
                t, ph, _ = gm.roll_run(lambda t, phi, p: -1.0, phi0=math.radians(45), T=12)
            else:
                t, ph, _ = gm.roll_run(lambda t, phi, p: 1.0 if t < 2 else 0.0, T=25)
            ax.plot(t, np.degrees(ph), "k--", label="игра (weight_shift)")
            ax.set_title(WN[w])
            ax.set_xlabel("t, с")
            ax.grid(alpha=0.3)
        axs[0].set_ylabel("крен, °")
        axs[0].legend(fontsize=8)
        fig.suptitle(title)
        fig.tight_layout()
        fig.savefig(fig_dir / f"{fname}.png", dpi=110)
        plt.close(fig)
    # термик
    fig, axs = plt.subplots(1, 3, figsize=(15, 4), sharey=True)
    for ax, w in zip(axs, W):
        for v in ("noslip", "free", "free/rigid"):
            d = ser(f"thermal_edge/{w}/{v}")
            if d is not None:
                ax.plot(d["series.t"], np.degrees(d["series.phi"]), color=cols[v], label=lbl[v])
                if v == "free":
                    ax.plot(d["series.game_t"], np.degrees(d["series.game_phi"]), "k--", label="игра")
        ax.set_title(WN[w]); ax.set_xlabel("t, с"); ax.grid(alpha=0.3)
    axs[0].set_ylabel("крен, °"); axs[0].legend(fontsize=8)
    fig.suptitle("Термик справа от линии полёта, руки в нейтрали")
    fig.tight_layout(); fig.savefig(fig_dir / "thermal_edge.png", dpi=110); plt.close(fig)
    # болтанка: голова
    fig, axs = plt.subplots(3, 1, figsize=(12, 8), sharex=True)
    for ax, w in zip(axs, W):
        d = ser(f"turbulence/{w}/free")
        if d is not None:
            ax.plot(d["series.t"], d["series.hy"] * 100, label="голова поперёк (оси крыла), см")
            ax.plot(d["series.t"], d["series.rel_y"] * 100, label="ЦМ пилота поперёк, см", alpha=0.7)
            ax.plot(d["series.t"], np.degrees(d["series.phi"]), label="крен крыла, °", alpha=0.7)
        ax.set_title(WN[w]); ax.grid(alpha=0.3)
    axs[0].legend(fontsize=8); axs[-1].set_xlabel("t, с")
    fig.suptitle("Болтанка σ 1 м/с: качание пилота и головы (вариант B)")
    fig.tight_layout(); fig.savefig(fig_dir / "turbulence_head.png", dpi=110); plt.close(fig)
    # разбег
    fig, axs = plt.subplots(1, 3, figsize=(15, 4))
    for ax, w in zip(axs, W):
        d = ser(f"ground_run/{w}/wind0")
        if d is not None:
            t = d["series.t"]
            ax.plot(t, d["series.lift"], label="подъёмная сила, Н")
            ax.plot(t, d["series.tension"], label="натяжение стропы, Н")
            ax.plot(t, d["series.feet"] * 1000, label="доля веса на ногах ×1000")
            ax.plot(t, d["series.V"] * 100, label="возд. скорость ×100, м/с")
        ax.set_title(WN[w]); ax.set_xlabel("t, с"); ax.grid(alpha=0.3); ax.set_xlim(0, 12)
    axs[0].legend(fontsize=8)
    fig.suptitle("Разбег, склон 15°, штиль: «несёт крыло» → «висит»")
    fig.tight_layout(); fig.savefig(fig_dir / "ground_run.png", dpi=110); plt.close(fig)
    # фугоида
    fig, axs = plt.subplots(1, 3, figsize=(15, 4), sharey=True)
    for ax, w in zip(axs, W):
        d = ser(f"phugoid/{w}/free")
        if d is not None:
            ax.plot(d["series.t"], d["series.V"] * 3.6, label="прототип")
        gm = GameModel(w)
        for gain, st, lab in ((0.0, ":", "игра без phugoid_damping"), (None, "--", "игра как есть")):
            tt = gm.phugoid_run(gain=gain)
            ax.plot(tt[:, 0], tt[:, 1] * 3.6, "k" + st, label=lab)
        ax.set_title(WN[w]); ax.set_xlabel("t, с"); ax.grid(alpha=0.3)
    axs[0].set_ylabel("V, км/ч"); axs[0].legend(fontsize=8)
    fig.suptitle("Фугоида: толчок +3 м/с, руки в нейтрали")
    fig.tight_layout(); fig.savefig(fig_dir / "phugoid.png", dpi=110); plt.close(fig)
    # маятник
    fig, axs = plt.subplots(1, 3, figsize=(15, 4), sharey=True)
    for ax, w in zip(axs, W):
        d = ser(f"pendulum/{w}/free")
        if d is not None:
            ax.plot(d["series_lat.t"], d["series_lat.x"] * 100, label="пилот поперёк, см")
            ax.plot(d["series_lat.t"], np.degrees(d["series_lat.phi"]), label="крен крыла, °")
        ax.set_title(WN[w]); ax.set_xlabel("t, с"); ax.grid(alpha=0.3)
    axs[0].legend(fontsize=8)
    fig.suptitle("Руки отпущены, боковой толчок пилоту 0,5 м/с")
    fig.tight_layout(); fig.savefig(fig_dir / "pendulum.png", dpi=110); plt.close(fig)


def main():
    R = load()
    md, gn = tables(R)
    (OUT / "tables.md").write_text(md)
    keep = {k: v["res"] for k, v in R.items() if not k.startswith("sens/") and not k.startswith("strips/")}
    (OUT / "summary.json").write_text(json.dumps({"game_roll": gn, "results": keep}, ensure_ascii=False, indent=1))
    figures(R)
    print(md)


if __name__ == "__main__":
    main()
