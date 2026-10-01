extends TestCase
## SP-3, контракт S1 (docs/air_speed_contracts.md): подготовка входа решателя (AirPlace.domain_case,
## AirWindowCase.window_at, AirCase.prepare обоих решений) против эталона из кода a554502/83045a8
## (tools/atmosphere/air_prep_ref.gd --gen → fixtures/air_model/prep/). Без GPU.
## Допуски S1: kf, n_unk, n_fluid, доля воды, сетка — точно; hc, h_bl ≤ 1e-3 м; heat, heat_used
## ≤ 1e-3 Вт/м²; col, lev, prm ≤ 1e-5·max(1, |x|); fixed_scale — относительная ≤ 1e-6.

const Ref := preload("res://tools/atmosphere/air_prep_ref.gd")


func test_prep_vs_reference() -> void:
	for cs: Dictionary in Ref.CASES:
		var path: String = Ref.FIX_DIR + String(cs.name)
		check(FileAccess.file_exists(path + ".json"), "эталон %s" % cs.name)
		if not FileAccess.file_exists(path + ".json"):
			continue
		var ref := Ref.load_ref(path)
		var t0 := Time.get_ticks_usec()
		var pr := Ref.build(cs)
		var t_ms := (Time.get_ticks_usec() - t0) / 1000.0
		check(not pr.is_empty(), "%s: случай построен" % cs.name)
		if pr.is_empty():
			continue
		var snap := Ref.snapshot(cs, pr[0], pr[1])
		var nums: Dictionary = snap.nums
		var arr: Dictionary = snap.arrays
		var dat: Dictionary = ref.data
		var tag := String(cs.name)
		for k in ["nx", "ny", "nz", "dz", "z_bot", "x0", "y0"]:
			check(float(nums[k]) == float(ref[k]), "%s: %s как в эталоне" % [tag, k])
		for pre in ["h_", "m_"]:
			check(
				Array(nums[pre + "n_unk"]) == Array(ref[pre + "n_unk"]).map(func(v): return int(v)),
				"%s: %sn_unk %s ≠ %s" % [tag, pre, nums[pre + "n_unk"], ref[pre + "n_unk"]]
			)
			check(
				int(nums[pre + "n_fluid"]) == int(ref[pre + "n_fluid"]),
				"%s: %sn_fluid" % [tag, pre]
			)
			var fs := float(ref[pre + "fixed_scale"])
			var e_fs := absf(float(nums[pre + "fixed_scale"]) - fs) / maxf(absf(fs), 1e-30)
			check(e_fs <= 1e-6, "%s: %sfixed_scale отн. %s" % [tag, pre, TestAirPicard.sci(e_fs)])
		# kf — столбец col[nyx..2nyx), точно
		var nyx := (int(nums.nx) + 2) * (int(nums.ny) + 2)
		for pre in ["h_", "m_"]:
			var a: PackedFloat32Array = arr[pre + "col"]
			var b: PackedFloat32Array = dat[pre + "col"]
			var bad := 0
			for q in range(nyx, 2 * nyx):
				if a[q] != b[q]:
					bad += 1
			check(bad == 0, "%s: %skf — %d клеток не те" % [tag, pre, bad])
		var w_bad := _count_ne(arr.water, dat.water)
		check(w_bad == 0, "%s: доля воды — %d клеток не те" % [tag, w_bad])
		var line := "  %s: %.0f мс;" % [tag, t_ms]
		var abs_tol := {
			hc = 1e-3, heat = 1e-3, h_heat_used = 1e-3, m_heat_used = 1e-3, h_h_bl = 1e-3,
			m_h_bl = 1e-3, gam = 1e-9
		}
		for k: String in dat:
			if k == "water":
				continue
			var got: Variant = arr[k]
			var exp: Variant = dat[k]
			check(got.size() == exp.size(), "%s: размер %s" % [tag, k])
			if got.size() != exp.size():
				continue
			if abs_tol.has(k):
				var e := _max_abs(got, exp)
				line += " %s %s" % [k, TestAirPicard.sci(e)]
				check(e <= float(abs_tol[k]), "%s: max|Δ%s| %s" % [tag, k, TestAirPicard.sci(e)])
			else:
				var e := _max_rel1(got, exp)
				line += " %s %s" % [k, TestAirPicard.sci(e)]
				check(e <= 1e-5, "%s: max|Δ%s|/max(1,|x|) %s" % [tag, k, TestAirPicard.sci(e)])
		print(line)


static func _count_ne(a: Variant, b: Variant) -> int:
	if a.size() != b.size():
		return maxi(a.size(), b.size())
	var n := 0
	for i in a.size():
		if a[i] != b[i]:
			n += 1
	return n


static func _max_abs(a: Variant, b: Variant) -> float:
	var e := 0.0
	for i in a.size():
		e = maxf(e, absf(float(a[i]) - float(b[i])))
	return e


static func _max_rel1(a: Variant, b: Variant) -> float:
	var e := 0.0
	for i in a.size():
		var x := float(b[i])
		var d := float(a[i]) - x
		if is_nan(x) and is_nan(float(a[i])):
			continue
		if is_inf(x) and float(a[i]) == x:
			continue
		e = maxf(e, absf(d) / maxf(1.0, absf(x)))
	return e
