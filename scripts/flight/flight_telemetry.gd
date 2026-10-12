class_name FlightTelemetry
extends RefCounted
## Заполнение Telemetry из состояния FlightModel или PendulumModel (параметр без типа) (для приборов, звука, камер).

const UP := Vector3.UP


static func fill(m, air_fn: Callable, ground_fn: Callable) -> void:
	var t: Telemetry = m.telemetry
	t.time_s = m.time_s
	t.phase = m.phase()
	t.position = m.position
	t.velocity = m.velocity
	var wind := Vector3.ZERO
	if m.mode == FlightModel.Mode.AIR:
		wind = FlightModel.sample_air(air_fn, m.position)
	elif m.mode == FlightModel.Mode.GROUND:
		wind = FlightModel.sample_air(
			air_fn, m.position + UP * float(m.flight.takeoff.wing_height_m)
		)
	t.air_velocity = m.velocity - wind
	t.airspeed = t.air_velocity.length()
	t.groundspeed = Vector2(m.velocity.x, m.velocity.z).length()
	t.vario = m.velocity.y
	t.altitude_msl = m.position.y
	var gh := FlightModel.ground_height(ground_fn, m.position.x, m.position.z)
	t.altitude_agl = m.position.y - gh if gh > -INF else m.position.y
	t.heading_deg = fposmod(rad_to_deg(m.heading), 360.0)
	t.track_deg = t.heading_deg
	if t.groundspeed > 0.1:
		t.track_deg = fposmod(rad_to_deg(atan2(m.velocity.x, -m.velocity.z)), 360.0)
	t.bank_deg = rad_to_deg(m.bank)
	t.pitch_deg = rad_to_deg(m.theta)
	t.on_ground = m.mode != FlightModel.Mode.AIR
	t.stalled = m.stalled
	t.glide_ratio = t.groundspeed / -m.velocity.y if m.velocity.y < -0.05 else 0.0
	t.basis = Basis.from_euler(Vector3(m.theta, -m.heading, -m.bank))
	if "pilot_rel" in m:
		# маятник (PD-К1): точка пилота — ЦМ в конце цепи (MR-К1), нагрузка — по стропе и рукам
		t.pilot_position = m.pilot_position
		t.pilot_velocity = m.pilot_velocity
		t.pilot_basis = m.pilot_basis
		t.pilot_shift = m.pilot_shift
		t.bar_force = m.bar_force_wing
	else:
		# FlightModel: пилот — одна материальная точка с крылом
		t.pilot_position = m.position
		t.pilot_velocity = m.velocity
		t.pilot_basis = t.basis
		t.pilot_shift = m.last_shift
		t.bar_force = m.bar_force_estimate(t.airspeed) if m.mode == FlightModel.Mode.AIR else Vector2.ZERO
	if "load_factor" in t:
		t.set("load_factor", m.load.load_factor)
	if "flare_amount" in t:
		t.set("flare_amount", m.flare_amount())
