class_name VisMaterialFactory
extends RefCounted


## Builds and returns the shared material dictionary keyed by component type.
static func build_materials() -> Dictionary:
	var materials: Dictionary = {}
	var defs := {
		"pmos":         Color(1.0, 0.2, 0.8),
		"nmos":         Color(0.2, 0.8, 1.0),
		"input_pin":    Color(0.2, 1.0, 0.3),
		"ipin":         Color(0.2, 1.0, 0.3),
		"output_pin":   Color(1.0, 0.2, 0.2),
		"opin":         Color(1.0, 0.2, 0.2),
		"label":        Color(1.0, 1.0, 0.3),
		"resistor":     Color(1.0, 0.6, 0.1),
		"capacitor":    Color(0.4, 0.6, 1.0),
		"poly_resistor":Color(1.0, 0.6, 0.1),
		"unknown":      Color(0.5, 0.5, 0.5),
		"wire":         Color(0.9, 0.9, 0.9),
	}
	for type: String in defs:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = defs[type]
		mat.emission_enabled = true
		mat.emission = defs[type]
		mat.emission_energy_multiplier = 0.3
		materials[type] = mat
	return materials


## Creates and adds the floor plane to parent, returns the MeshInstance3D.
static func create_floor(parent: Node3D) -> MeshInstance3D:
	var floor := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(50, 50)
	floor.mesh = plane
	floor.position = Vector3(0, -0.01, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.08, 0.08, 0.12)
	mat.metallic = 0.2
	mat.roughness = 0.8
	floor.material_override = mat
	floor.name = "Floor"
	parent.add_child(floor)
	return floor


## Returns the material for type, falling back to "unknown".
static func get_material(materials: Dictionary, type: String) -> StandardMaterial3D:
	if materials.has(type):
		return materials[type]
	return materials["unknown"]


## Returns the Y offset for a component label based on its type.
static func get_label_height(type: String) -> float:
	match type:
		"pmos": return 0.08
		"nmos": return 0.08
		"resistor", "poly_resistor": return 0.08
		"label": return 0.04
		"ipin", "input_pin": return 0.06
		"opin", "output_pin": return 0.06
		_: return 0.07
