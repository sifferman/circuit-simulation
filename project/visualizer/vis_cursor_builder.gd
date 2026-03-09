class_name VisCursorBuilder
extends RefCounted

## Untyped reference to the main SchVis3D Node3D.
var _vis


func _init(vis) -> void:
	_vis = vis


## Creates one channel cursor and one gate cursor per transistor.
## Frees any previously built cursors first (safe to call on re-pair).
func build_transistor_cursors() -> void:
	_free_old_cursors()

	for comp_name: String in _vis._transistor_data.keys():
		if not _vis._transistor_nodes.has(comp_name):
			continue
		var sym: CircuitSymbol = _vis._transistor_nodes[comp_name]
		var tdata: Dictionary  = _vis._transistor_data[comp_name]

		_build_channel_cursor(comp_name, sym, tdata)

		# Gate cursor only if both G pin and the channel cursor were created.
		if sym.pin_positions.has("G") and _vis._transistor_cursor_map.has(comp_name):
			_build_gate_cursor(comp_name, sym, tdata)

	_vis._tc_was_done.resize(_vis._transistor_cursors.size())
	_vis._tc_was_done.fill(true)
	_vis._gc_was_done.resize(_vis._gate_cursors.size())
	_vis._gc_was_done.fill(true)


func _free_old_cursors() -> void:
	for tc: Dictionary in _vis._transistor_cursors:
		var old: Node = tc["cursor"]
		if is_instance_valid(old):
			old.queue_free()
	_vis._transistor_cursors.clear()
	_vis._transistor_cursor_map.clear()

	for gc: Dictionary in _vis._gate_cursors:
		var old_c: Node = gc["cursor"]
		if is_instance_valid(old_c):
			old_c.queue_free()
		var old_f: Node = gc.get("gflash", null)
		if old_f != null and is_instance_valid(old_f):
			old_f.queue_free()
		var old_b: Node = gc.get("gbar", null)
		if old_b != null and is_instance_valid(old_b):
			old_b.queue_free()
	_vis._gate_cursors.clear()
	_vis._gate_cursor_map.clear()


# ---------- Channel cursor ----------

func _build_channel_cursor(comp_name: String, sym: CircuitSymbol, tdata: Dictionary) -> void:
	if not (sym.pin_positions.has("D") and sym.pin_positions.has("S")):
		return

	# Direction is determined by physical vertical position, not SPICE pin name,
	# so it is correct regardless of symbol rotation, mirror, or layout D/S swap.
	# PMOS: top → bottom.   NMOS: bottom → top.
	# We also record which SPICE pin ("d"/"s") sits at the destination so that
	# on_transistor_cursor_done cascades the correct internal net.
	var p_s: Vector3  = _vis.to_local(sym.get_pin_position("S"))
	var p_d: Vector3  = _vis.to_local(sym.get_pin_position("D"))
	var is_pmos: bool = str(tdata["type"]) == "pfet"
	var s_is_top: bool = p_s.z < p_d.z   # S pin is physically higher in the scene

	var p_from: Vector3
	var p_to:   Vector3
	var from_spice_pin: String   # lowercase key into tdata
	var dest_spice_pin: String

	if is_pmos:
		if s_is_top:
			p_from = p_s; p_to = p_d; from_spice_pin = "s"; dest_spice_pin = "d"
		else:
			p_from = p_d; p_to = p_s; from_spice_pin = "d"; dest_spice_pin = "s"
	else:  # NMOS
		if s_is_top:
			p_from = p_d; p_to = p_s; from_spice_pin = "d"; dest_spice_pin = "s"
		else:
			p_from = p_s; p_to = p_d; from_spice_pin = "s"; dest_spice_pin = "d"
	if p_from.distance_to(p_to) < 0.001:
		return

	var p_gate: Vector3 = _vis.to_local(sym.get_pin_position("G"))
	var path: Array     = VisGeomUtils.transistor_path(p_from, p_to, p_gate)
	var cum: Array      = VisGeomUtils.path_cum_lengths(path)

	var cursor := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.022
	sphere.height = 0.044
	cursor.mesh = sphere
	var cursor_mat := StandardMaterial3D.new()
	cursor_mat.emission_enabled = true
	cursor_mat.emission = Color(1.0, 0.95, 0.3)
	cursor_mat.emission_energy_multiplier = 3.0
	cursor.material_override = cursor_mat
	cursor.visible = false
	cursor.position = p_from
	_vis.add_child(cursor)

	_vis._transistor_cursor_map[comp_name] = _vis._transistor_cursors.size()
	_vis._transistor_cursors.append({
		"cursor":     cursor,
		"cursor_mat": cursor_mat,
		"comp_name":  comp_name,
		"p_from":     p_from,
		"p_to":       p_to,
		"path":       path,
		"cum":        cum,
		"trigger_t":       -999.0,
		"dest_spice_pin":  dest_spice_pin,   # "d" or "s" — which SPICE pin is at cursor end
		"from_spice_pin":  from_spice_pin,   # "d" or "s" — which SPICE pin is at cursor start
	})


# ---------- Gate cursor + contact flash + gap fill ----------

func _build_gate_cursor(comp_name: String, sym: CircuitSymbol, tdata: Dictionary) -> void:
	var p_gate: Vector3 = _vis.to_local(sym.get_pin_position("G"))
	var p_from: Vector3 = _vis.to_local(sym.get_pin_position("D"))
	var p_to:   Vector3 = _vis.to_local(sym.get_pin_position("S"))

	var p_gate_bar: Vector3 = p_gate.lerp((p_from + p_to) * 0.5, 22.5 / 40.0)
	var stub_len: float     = p_gate.distance_to(p_gate_bar)

	# Use the channel cursor's cum-length for proportional traverse time.
	var chan_len: float = 1.0
	var tc_idx: int = int(_vis._transistor_cursor_map[comp_name])
	var cum: Array = _vis._transistor_cursors[tc_idx].get("cum", [])
	if cum.size() > 0:
		chan_len = float(cum.back())
	var g_traverse: float = _vis.cursor_traverse_seconds * (stub_len / maxf(chan_len, 0.001))

	# Traveling gate cursor sphere.
	var gcursor := MeshInstance3D.new()
	var gsphere := SphereMesh.new()
	gsphere.radius = 0.016
	gsphere.height = 0.032
	gcursor.mesh = gsphere
	var gcursor_mat := StandardMaterial3D.new()
	gcursor_mat.emission_enabled = true
	gcursor_mat.emission = Color(0.4, 1.0, 0.4)
	gcursor_mat.emission_energy_multiplier = 2.5
	gcursor.material_override = gcursor_mat
	gcursor.visible = false
	gcursor.position = p_gate
	_vis.add_child(gcursor)

	# Contact-flash sphere: sits at gate bar, pulses when cursor arrives.
	var gflash := MeshInstance3D.new()
	var gfsphere := SphereMesh.new()
	gfsphere.radius = 0.028; gfsphere.height = 0.056
	gflash.mesh = gfsphere
	var gflash_mat := StandardMaterial3D.new()
	gflash_mat.emission_enabled = true
	gflash_mat.emission = Color(1.0, 1.0, 0.5)
	gflash_mat.emission_energy_multiplier = 0.0
	gflash.material_override = gflash_mat
	gflash.visible = false
	gflash.position = p_gate_bar
	_vis.add_child(gflash)

	# Gate oxide gap fill: flat box spanning the dielectric gap "O| |" → "O|█|".
	var ds_mid_g: Vector3      = (p_from + p_to) * 0.5
	var xschem_unit: float     = p_gate.distance_to(ds_mid_g) / 40.0
	var p_channel_bar: Vector3 = p_gate.lerp(ds_mid_g, 27.5 / 40.0)
	var gate_stub_fwd: Vector3 = (p_gate_bar - p_gate).normalized()
	var gbar_dir: Vector3      = gate_stub_fwd.cross(Vector3.UP)
	if gbar_dir.length_squared() < 0.001:
		gbar_dir = gate_stub_fwd.cross(Vector3.RIGHT)
	gbar_dir = gbar_dir.normalized()

	var gbar := MeshInstance3D.new()
	var gbar_mesh := BoxMesh.new()
	gbar_mesh.size = Vector3(30.0 * xschem_unit, 0.013, p_gate_bar.distance_to(p_channel_bar))
	gbar.mesh = gbar_mesh
	var gbar_mat := StandardMaterial3D.new()
	gbar_mat.emission_enabled = true
	gbar_mat.emission = Color(0.4, 1.0, 0.4)
	gbar_mat.emission_energy_multiplier = 0.0
	gbar.material_override = gbar_mat
	gbar.basis    = Basis(gbar_dir, Vector3.UP, gate_stub_fwd)
	gbar.position = (p_gate_bar + p_channel_bar) * 0.5
	gbar.visible  = false
	_vis.add_child(gbar)

	_vis._gate_cursor_map[comp_name] = _vis._gate_cursors.size()
	_vis._gate_cursors.append({
		"cursor":        gcursor,
		"cursor_mat":    gcursor_mat,
		"comp_name":     comp_name,
		"p_from":        p_gate,
		"p_to":          p_gate_bar,
		"traverse":      g_traverse,
		"gate_net":      str(tdata["g"]),
		"trigger_t":     -999.0,
		"gflash":        gflash,
		"gflash_mat":    gflash_mat,
		"gflash_t":      -999.0,
		"gbar":          gbar,
		"gbar_mat":      gbar_mat,
		"p_channel_bar": p_channel_bar,
		"gbar_t":        -999.0,
	})
