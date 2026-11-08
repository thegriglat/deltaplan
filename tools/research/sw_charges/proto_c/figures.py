import json, sys
import numpy as np
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
sys.path.insert(0, ".")
from common import *
r = json.load(open("out/results.json")); s3 = json.load(open("out/step3.json"))["base"]
x = np.linspace(-3, 3, 1201)
_, w = lc_velocity(x, 0 * x, 0.0, 1.0, 1.0, 1.0)
fig, ax = plt.subplots(1, 3, figsize=(15, 4))
ax[0].plot(x, w / w.max(), label="ЛЧ, a=R"); ax[0].plot(x, np.exp(-x**2) * (1 - x**2), label="Гедеон"); ax[0].set_title("w(x)/пик"); ax[0].legend()
zs = [float(k) for k in r["step2"]["base"] if k != "_meta"]
ax[1].plot(zs, [r["step2"]["base"][str(z)]["sigma_w"] for z in zs], "o-", label="пары"); ax[1].plot(zs, [r["step2"]["base"][str(z)]["sigma_w_game"] for z in zs], "s--", label="игра"); ax[1].set_title("σ_w(z)"); ax[1].legend()
zc = np.array(s3["z_centres"]); ax[2].plot(np.array(s3["H_profile"]) / 0.2074, zc, label="H/H_kin"); ax[2].plot(1 - zc / 1500, zc, "--", label="1-ζ"); ax[2].plot(np.array(s3["uw_profile"]) / 0.16, zc, label="<u'w'>/u*²"); ax[2].set_ylim(0, 2500); ax[2].legend()
fig.savefig("out/fig_proto_c.png", dpi=90)
