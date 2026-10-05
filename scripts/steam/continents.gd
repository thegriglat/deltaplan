extends RefCounted
## Континент по координатам точки отрыва (грубые многоугольники, ST-6). Антарктида не считается.
## Порядок проверки важен: более узкие области раньше широких.

const EUROPE := "europe"
const ASIA := "asia"
const AFRICA := "africa"
const NORTH_AMERICA := "north_america"
const SOUTH_AMERICA := "south_america"
const OCEANIA := "oceania"
const ALL: PackedStringArray = ["europe", "asia", "africa", "north_america", "south_america", "oceania"]

## Кольца в (lon, lat).
const _OCEANIA_RINGS := [
	[[113, -39.5], [154.5, -39.5], [154.5, -10.5], [113, -10.5]],  # Австралия
	[[144, -43.8], [149, -43.8], [149, -40], [144, -40]],  # Тасмания
	[[165, -48], [179.9, -48], [179.9, -34], [165, -34]],  # Новая Зеландия
	[[140.5, -11], [180, -11], [180, 12], [140.5, 12]],  # Меланезия, Микронезия (с Фиджи)
	[[-180, -25], [-130, -25], [-130, 12], [-180, 12]],  # Полинезия (восток)
	[[-161, 18], [-154, 18], [-154, 23], [-161, 23]],  # Гавайи
]
const _AFRICA_RINGS := [
	[[-18, 37.5], [11, 37.5], [34, 31.5], [34.5, 28], [38, 20], [43, 12.5], [52, 12.5], [52, -1],
		[40, -15], [35, -25], [33, -36], [17, -36], [12, -18], [8, -1], [-8, 4], [-18, 14]],
	[[43, -26], [51, -26], [51, -12], [43, -12]],  # Мадагаскар
]
const _SOUTH_AMERICA_RINGS := [
	[[-82, -56], [-34, -56], [-34, 12.5], [-77.5, 12.5], [-77.5, 8], [-82, 8]],
]
const _EUROPE_RINGS := [
	[[-25, 35.5], [40, 35.5], [40, 45], [60, 45], [60, 82], [-25, 82]],
]
const _NORTH_AMERICA_RINGS := [
	[[-169, 7], [-50, 7], [-50, 84], [-169, 84]],
	[[-75, 59], [-25, 59], [-25, 84], [-75, 84]],  # Гренландия
]
const _ASIA_RINGS := [
	[[25, -11], [180, -11], [180, 78], [25, 78]],
	[[-180, 60], [-169, 60], [-169, 78], [-180, 78]],
]


## Идентификатор континента или "" (NAN, океан, Антарктида).
static func of(lat: float, lon: float) -> String:
	if is_nan(lat) or is_nan(lon) or absf(lat) > 90.0:
		return ""
	lon = fposmod(lon + 180.0, 360.0) - 180.0
	var p := Vector2(lon, lat)
	var order := [
		[OCEANIA, _OCEANIA_RINGS], [AFRICA, _AFRICA_RINGS], [SOUTH_AMERICA, _SOUTH_AMERICA_RINGS],
		[EUROPE, _EUROPE_RINGS], [NORTH_AMERICA, _NORTH_AMERICA_RINGS], [ASIA, _ASIA_RINGS],
	]
	for item in order:
		for ring in item[1]:
			if _inside(p, ring):
				return item[0]
	return ""


static func _inside(p: Vector2, ring: Array) -> bool:
	var inside := false
	var n := ring.size()
	var j := n - 1
	for i in n:
		var a := Vector2(ring[i][0], ring[i][1])
		var b := Vector2(ring[j][0], ring[j][1])
		if (a.y > p.y) != (b.y > p.y) and p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x:
			inside = not inside
		j = i
	return inside
