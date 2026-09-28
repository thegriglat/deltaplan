class_name NetPauseInfo
extends RefCounted
## NET-52: тонкий, тестируемый слой между NetZone/NetPilots и экранами паузы/загрузки —
## строит одну и ту же структуру для обоих. Экраны сами автозагрузки не трогают.
##
## build(zone, pilots, own_alt_m) -> {} — не в зоне; иначе {code: String,
## pilots: [{name, alt_m (число или null — неизвестна), is_leader, is_me}, …]} по порядку
## подключения. zone/pilots — NetZone/NetPilots или любой объект с теми же полями/методами
## (in_zone, code, peers, leader_id, my_id; has_pilot(id), sample(id)) — для тестов.
## own_alt_m — высота своего пилота (null, если недоступна — например, ещё нет телеметрии).


static func build(zone: Object, pilots: Object, own_alt_m: Variant = null) -> Dictionary:
	if zone == null or not zone.in_zone:
		return {}
	var peers: Dictionary = zone.peers
	var ids: Array = peers.keys()
	ids.sort_custom(
		func(a, b) -> bool:
			return int(peers[a].get("joinOrder", 0)) < int(peers[b].get("joinOrder", 0))
	)
	var my_id := String(zone.my_id)
	var leader_id := String(zone.leader_id)
	var rows: Array = []
	for id: Variant in ids:
		var p: Dictionary = peers[id]
		var is_me := String(id) == my_id
		var alt: Variant = own_alt_m if is_me else _remote_alt(pilots, String(id))
		rows.append(
			{
				"name": String(p.get("name", "")),
				"alt_m": alt,
				"is_leader": String(id) == leader_id,
				"is_me": is_me,
			}
		)
	return {"code": String(zone.code), "pilots": rows}


static func _remote_alt(pilots: Object, id: String) -> Variant:
	if pilots == null or not pilots.has_pilot(id):
		return null
	var s: Dictionary = pilots.sample(id)
	if s.is_empty():
		return null
	return (s.pos as Vector3).y
