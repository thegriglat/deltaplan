extends Node
## air-start AS-1 (в): какая невязка не падает на слабом ветре — область Онгудая 400 м (k = 1),
## AirPicardJob напрямую; история невязок (каждые 10 итераций) по обоим решениям в csv.
## Случаи: час:ветер:откуда; вывод — tools/research/air_start/out/residuals.csv.

const CASES := ["12:1:270", "12:3:180", "9:0:270", "12:6:150"]


func _ready() -> void:
	await get_tree().process_frame
	var lw := TestAirPlace.load_detail("ongudai")
	var loc := TestAirPlace.load_loc("ongudai")
	var settings := FlightSettings.defaults()
	var fa := FileAccess.open("res://tools/research/air_start/out/residuals.csv", FileAccess.WRITE)
	fa.store_line("case,solution,it,mom_rms,th_rms,thd_rms,div_rms,mom_max,th_max,ustar,h_max,wstar_max")
	for cs: String in CASES:
		var q := cs.split(":")
		var c := AirPlace.domain_case(
			lw[0], lw[1], loc, 400.0, float(q[0]), float(q[1]), float(q[2]),
			settings.temperature_c, settings.sky
		)
		var job := AirPicardJob.new()
		job.case = c
		job.mech = true
		var ok := job.start() and job.run_blocking()
		var ci: Dictionary = c.closure_info
		for r: Dictionary in job.results:
			var sol := "heat" if r.heated else "mech"
			for h: Dictionary in r.hist:
				fa.store_line(",".join([cs, sol, h.it, h.mom_rms, h.th_rms, h.thd_rms, h.div_rms, h.mom_max, h.th_max, ci.ustar, ci.h_max, ci.wstar_max]))
			print("residual_probe: %s %s %s %d, gpu %.1f с" % [cs, sol, r.status, r.iters, job.gpu_ms_total / 1000.0])
		job.release()
		fa.flush()
	fa.close()
	get_tree().quit(0)
