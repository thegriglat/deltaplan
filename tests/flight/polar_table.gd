extends Node
## Печать поляры каждого крыла, полученной прогоном модели в спокойном воздухе.
## Запуск: godot --headless --path . res://tests/flight/polar_table.tscn

const Sim := preload("res://tests/flight/flight_sim.gd")


func _ready() -> void:
	for wname in ["training", "kingpost", "sport"]:
		var wing: Dictionary = Config.get_config("wings/" + wname)
		var ref := float(wing.pilot_mass_ref_kg)
		for pm in [float(wing.pilot_mass_min_kg), ref, float(wing.pilot_mass_max_kg)]:
			var m := Sim.make(wname, pm)
			print(
				(
					"\n%s (%s), пилот %.0f кг, полная масса %.0f кг: сваливание %.1f км/ч, трим %.1f км/ч"
					% [
						wing.name,
						wname,
						pm,
						m.mass,
						Units.to_kmh(m.stall_speed()),
						Units.to_kmh(m.trim_speed())
					]
				)
			)
			print("  трапеция |  V км/ч | снижение м/с | качество")
			for p in [1.0, 0.75, 0.5, 0.25, 0.0, -0.1, -0.2, -0.3, -0.45, -0.6, -0.8, -1.0]:
				var r: Vector2 = Sim.settle(m, p, 30.0)
				var st := " срыв" if m.stalled else ""
				print(
					(
						"  %+5.2f    | %6.1f  |   %5.2f      | %5.1f%s"
						% [p, Units.to_kmh(r.x), r.y, r.x / maxf(r.y, 0.01), st]
					)
				)
	get_tree().quit()
