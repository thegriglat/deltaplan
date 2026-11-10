"""Markdown-таблицы из out/summary.json для docs/research/lee_turb/baseline.md (печатает в stdout по разделам)."""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
S = json.load(open(os.path.join(HERE, "out", "summary.json")))


def f(v, p=2, none="–"):
    if v is None:
        return none
    if isinstance(v, str):
        return v
    return f"{v:.{p}f}"


def key(r):
    return f"{r['case'].replace('ongudai_', '')}/{r['ridge']}"


def overview():
    out = ["| разрез | зона | H, м | dx | lee_f>0.5, x/H | макс σ_w всего: x/H, agl, ветвь | макс σ_w при agl≤150 | макс избыток σ_w/σ_w,приток |",
           "|---|---|---|---|---|---|---|---|"]
    for r in S:
        a = r["max_sigma_w_all"]
        b = r.get("sw_ratio_max", {}).get("lee_gt0")
        lf = r["lee_f_gt05_xh"]
        m150 = r.get("max150")
        out.append("| " + " | ".join([
            key(r), str(r["zone"]), f(r["H"], 0), f(r["dx_crest"], 0),
            "–" if lf is None else f"{lf[0]:.1f}…{lf[1]:.1f}",
            f"{a['xh']:.1f}; {a['agl']:.0f} м; {a['src']} ({a['sigma_w']:.2f})" if a else "–",
            f"{m150['xh']:.1f}; {m150['agl']:.0f} м; {m150['src']} ({m150['sigma_w']:.2f})" if m150 else "–",
            f"×{b['ratio']:.1f} при x/H {b['xh']:.1f}, agl {b['agl']} м ({b['src']})" if b else "–"]) + " |")
    return "\n".join(out)


def per_section(r):
    out = [f"**{key(r)}** (H = {r['H']:.0f} м, гребень {r['crest_msl']:.0f} м, dx на гребне {r['dx_crest']:.0f} м)", "",
           "| x/H | dx | lee_f | ветвь σ_w макс (agl≤150) | σ_w макс (agl, м) | σ_u/σ_w | σ_w/ΔU_п | σ_w agl 10 / 30 / 100 | l_w, м |",
           "|---|---|---|---|---|---|---|---|---|"]
    for st in r["stations"]:
        if "sw_max" not in st:
            continue
        out.append("| " + " | ".join([
            f(st["xh"], 1), f(st["dx"], 0), f(st["lee_f"], 2), st["src_at_max"],
            f"{st['sw_max']:.2f} ({st['agl_at_max']:.0f})", f(st["su"] / st["sw_max"], 1), f(st.get("sw_over_duf"), 2),
            " / ".join(f(st[f"sw_agl{a}"], 2) for a in (10, 30, 100)), f(st["lw"], 0)]) + " |")
    return "\n".join(out)


def per_section_short(r):
    pick = (0.5, 1.0, 2.0, 3.0, 4.0, 6.0)
    out = [f"**{key(r)}** — H {r['H']:.0f} м, dx {r['dx_crest']:.0f} м", "",
           "| x/H | lee_f | ветвь@30 м | σ_w макс, agl≤150 (agl; ветвь) | σ_w/ΔU_п | σ_w@30 | l_w | избыток σ_w |",
           "|---|---|---|---|---|---|---|---|"]
    ratio = {}
    for st in r["stations"]:
        if "sw_max" not in st:
            continue
        if min(pick, key=lambda p: abs(p - st["xh"])) != min(pick, key=lambda p: abs(p - st["xh"])) or not any(abs(st["xh"] - p) < 0.12 for p in pick):
            continue
        ref = (r.get("sw_up_ref") or {}).get("30")
        sw30 = st.get("sw_agl30")
        out.append("| " + " | ".join([
            f(st["xh"], 1), f(st["lee_f"], 2), st.get("src30", "–"), f"{st['sw_max']:.2f} ({st['agl_at_max']:.0f}; {st['src_at_max']})",
            f(st.get("sw_over_duf"), 2), f(sw30, 2), f(st["lw"], 0),
            f(sw30 / ref, 2) if (sw30 and ref) else "–"]) + " |")
    return "\n".join(out)


def field_table():
    out = ["| разрез | u₁₀ вверх, м/с | дефицит u₁₀<½ вверх: x/H | отрыв u₁₀<0: x/H | присоед. | L/H | L/dx | h пузыря (ψ=0), м | z½ над гребнем при x/H 1 / 2 / 4, м | max∂U/∂z у стенки? (доля внутр.) | δ_ω(x/H 1…4) = ΔU/max∂U/∂z, м; dδ_ω/dx; R² | δ₁₀₋₉₀: наклон; R² |",
           "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in S:
        sc = {round(s["xh"]): s for s in r["shear_center"]}
        zh = " / ".join(f(sc[k]["z_half_zc"], 0) if k in sc else "–" for k in (1, 2, 4))
        fit = (r["delta_fit"] or {}).get("1-4")
        vf = (r.get("dvis_fit") or {}).get("1-4")
        bp = r["bubble_psi"]
        out.append("| " + " | ".join([
            key(r), f(r["u10_upstream"], 1), f(r.get("deficit_half_xh"), 1), f(r["sep_u10"], 1), f(r["reattach_u10"], 1),
            f(r["bubble_L_over_H_u10"], 2), f(r["bubble_L_over_dx"], 1),
            f(bp["h_max"], 0) if bp else "–", zh, f(r["interior_frac_1_6"], 2),
            f"{fit['delta_mid']:.0f}; {fit['slope']:.2f}; {fit['r2']:.2f}" if fit and fit["r2"] is not None else "–",
            f"{vf['slope']:.2f}; {vf['r2']:.2f}" if vf and vf["r2"] is not None else "–"]) + " |")
    return "\n".join(out)


def cf_table():
    out = ["| разрез | макс σ_w слоя смешения (контрфакт): x/H, agl | σ_w,mix | σ_w сейчас там | доля точек следа, где mix > сейчас | медиана mix/сейчас |",
           "|---|---|---|---|---|---|"]
    for r in S:
        c = r.get("counterfactual_mix") or {}
        m = c.get("max")
        if not m:
            continue
        out.append(f"| {key(r)} | {m['xh']:.1f}; {m['agl']:.0f} м | {m['sigma_w_mix']:.2f} | {m['sigma_w_now']:.2f} | "
                   f"{f(c.get('frac_mix_gt_now'), 2)} | {f(c.get('median_ratio_mix_over_now'), 2)} |")
    return "\n".join(out)


if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "overview"
    if which == "overview":
        print(overview())
    elif which == "field":
        print(field_table())
    elif which == "cf":
        print(cf_table())
    elif which == "short":
        for r in S:
            print(per_section_short(r))
            print()
    elif which == "sections":
        for r in S:
            print(per_section(r))
            print()
