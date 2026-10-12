class_name PilotLook
extends RefCounted
## Материалы пилота (каска, визор, подвеска, одежда, ботинки, стропа): при загрузке модели
## материалы glb заменяются процедурным шейдером (pilot_look.gdshader) с тем же цветом и
## шероховатостью как базой. Меш pilot.glb и build_pilot.py не трогаются; имя материала
## сохраняется (GliderVisual ищет Strap/Glove по имени). Glove, GlovePanel, Skin и прочее —
## без изменений. Подмена идёт в общих ресурсах меша, поэтому работает и для пилотов ботов
## и других игроков (та же модель). Параметры — configs/flight.json → visual.pilot_look.

const _SRC := preload("res://scripts/flight/pilot_look.gdshader")

const KINDS := {
	"Helmet": ["helmet", 0],
	"Visor": ["visor", 1],
	"Pod": ["pod", 2],
	"PodStripe": ["pod_stripe", 2],
	"Jacket": ["jacket", 3],
	"JacketSleeve": ["jacket", 3],
	"Trousers": ["trousers", 3],
	"Strap": ["strap", 4],
	"Boot": ["boot", 5],
	"Sole": ["sole", 6],
}

static var _shaders := {}


## model — корень модели пилота; cfg — visual.pilot_look. Возвращает число заменённых поверхностей.
static func apply(model: Node, cfg: Dictionary) -> int:
	if cfg.is_empty() or not bool(cfg.get("enabled", true)):
		return 0
	var done := 0
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := mi.mesh
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var old := mesh.surface_get_material(i)
			if old == null or not KINDS.has(old.resource_name) or old is ShaderMaterial:
				continue
			mesh.surface_set_material(i, make_material(old.resource_name, old as BaseMaterial3D, cfg))
			done += 1
	return done


static func make_material(mat_name: String, old: BaseMaterial3D, cfg: Dictionary) -> ShaderMaterial:
	var info: Array = KINDS[mat_name]
	var sm := ShaderMaterial.new()
	sm.resource_name = mat_name
	sm.shader = _shader(info[0] == "visor")
	sm.set_shader_parameter("kind", info[1])
	if old != null:
		sm.set_shader_parameter("base_color", old.albedo_color)
		sm.set_shader_parameter("base_rough", old.roughness)
	for sec: String in ["common", info[0]]:
		var d: Dictionary = cfg.get(sec, {})
		for key: String in d:
			if not key.ends_with("_doc"):
				sm.set_shader_parameter(key, d[key])
	return sm


static func _shader(visor: bool) -> Shader:
	if not _shaders.has(visor):
		var sh := Shader.new()
		sh.code = ("#define PILOT_LOOK_VISOR\n" if visor else "") + _SRC.code
		_shaders[visor] = sh
	return _shaders[visor]
