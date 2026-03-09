class_name VisAnimPlayer
extends RefCounted

const VMAX: float = 1.8

## Untyped reference to the main SchVis3D Node3D.
var _vis


func _init(vis) -> void:
	_vis = vis


# ---------- Voltage helpers ----------

func get_net_voltage_at(net_name: String, idx: int) -> float:
	match net_name:
		"vpwr", "vdd", "vcc":
			return VMAX
		"vgnd", "gnd", "vss", "0":
			return 0.0
	if not _vis._sim_vectors.has(net_name):
		return 0.0
	var vec: Array = _vis._sim_vectors[net_name]
	if idx >= vec.size():
		return 0.0
	return float(vec[idx])


## Maps 0–1.8 V to a spectral color. All branches currently return the same
## warm yellow — edit the return values to restore the full voltage palette.
func voltage_to_color(v: float) -> Color:
	var t: float = clamp(v / VMAX, 0.0, 1.0)
	if t < 0.25:
		var s: float = t / 0.25
		return Color(1.0, 0.95, 0.3)
	elif t < 0.5:
		var s: float = (t - 0.25) / 0.25
		return Color(1.0, 0.95, 0.3)
	elif t < 0.75:
		var s: float = (t - 0.5) / 0.25
		return Color(1.0, 0.95, 0.3)
	else:
		var s: float = (t - 0.75) / 0.25
		return Color(1.0, 0.95, 0.3)


# ---------- Simulation data loading ----------

func load_sim_data(all_vecs: Dictionary) -> void:
	_vis._sim_time.clear()
	_vis._sim_vectors.clear()
	_vis._anim_active = false

	for key: String in all_vecs.keys():
		if key.to_lower() == "time":
			_vis._sim_time = Array(all_vecs[key])
			break

	var mapped: int = 0
	for key: String in all_vecs.keys():
		var norm: String = VisGeomUtils.normalize_vec_name(key)
		if norm == "time" or norm == "":
			continue
		# Store ALL non-time vectors so gate net voltages are available for
		# transistor triggering even when those nets have no labeled wire.
		_vis._sim_vectors[norm] = Array(all_vecs[key])
		if _vis._net_nodes.has(norm):
			mapped += 1

	if _vis._sim_time.size() > 1 and mapped > 0:
		_vis._anim_sim_elapsed = 0.0
		_vis._anim_active = true
		var t_start: float = float(_vis._sim_time[0])
		var t_end: float   = float(_vis._sim_time[_vis._sim_time.size() - 1])
		print("Simulation animation ready: ", _vis._sim_time.size(), " time steps (", t_start, " s to ", t_end, " s), ", mapped, " nets mapped: ", _vis._sim_vectors.keys())
	else:
		if _vis._sim_time.size() <= 1:
			push_warning("Visualizer: time vector missing or has only " + str(_vis._sim_time.size()) + " point(s)")
		print("Visualizer: no matching nets (mapped=", mapped, ", time_pts=", _vis._sim_time.size(), ")")
		print("  Available vectors: ", all_vecs.keys())
		print("  Schematic nets tracked: ", _vis._net_nodes.keys())

	# Seed nets: all tracked nets EXCEPT those driven by transistor D or S pins.
	# Gate nets (e.g. "A") are NOT driven by transistors — they stay as seeds and
	# self-trigger from voltage-transition detection in Phase 1.
	# Drain/source nets (e.g. "net1", "X") are transistor outputs — they must wait
	# for cascade_net_from_pin so current flow is causally ordered.
	_vis._seed_nets.clear()
	for net: String in _vis._net_nodes.keys():
		_vis._seed_nets[net] = true
	for comp_name: String in _vis._transistor_data.keys():
		var tdata: Dictionary = _vis._transistor_data[comp_name]
		_vis._seed_nets.erase(str(tdata["d"]))
		_vis._seed_nets.erase(str(tdata["s"]))
	print("Visualizer: ", _vis._seed_nets.size(), " seed nets (not transistor-driven): ", _vis._seed_nets.keys())


# ---------- Transistor cursor triggering ----------

## Checks conductance and fires the gate cursor (which will fire the channel cursor
## on completion).  If no gate cursor exists, fires the channel cursor directly.
func try_trigger_transistor_cursor(comp_name: String, sim_idx: int) -> void:
	if not _vis._transistor_cursor_map.has(comp_name):
		return

	var tdata: Dictionary = _vis._transistor_data[comp_name]
	var is_pmos: bool = str(tdata["type"]) == "pfet"
	var vg: float = get_net_voltage_at(str(tdata["g"]), sim_idx)
	var vs: float = get_net_voltage_at(str(tdata["s"]), sim_idx)
	var conductance: float = clampf(
		(vs - vg - VisGeomUtils.VTH) / VisGeomUtils.VTH if is_pmos else (vg - vs - VisGeomUtils.VTH) / VisGeomUtils.VTH,
		0.0, 1.0)
	if conductance < 0.05:
		return

	# If a gate cursor exists, trigger it and let it fire the channel cursor once
	# the gate animation completes (gap fill lights up).
	if _vis._gate_cursor_map.has(comp_name):
		var gc_idx: int  = int(_vis._gate_cursor_map[comp_name])
		var gc:    Dictionary = _vis._gate_cursors[gc_idx]
		var gc_age: float = _vis._real_elapsed - float(gc["trigger_t"])
		var g_trav: float = float(gc.get("traverse", _vis.cursor_traverse_seconds * 0.35))
		if gc_age >= 0.0 and gc_age <= g_trav:
			return   # gate cursor already traveling — don't re-trigger
		gc["trigger_t"] = _vis._real_elapsed
		return   # channel cursor will fire when gate cursor finishes

	# No gate cursor — fire channel cursor directly (fallback).
	_fire_channel_cursor(comp_name, sim_idx)


## Fires the channel cursor immediately if the transistor is conducting.
func _fire_channel_cursor(comp_name: String, sim_idx: int) -> void:
	if not _vis._transistor_cursor_map.has(comp_name):
		return
	var tc_idx: int = int(_vis._transistor_cursor_map[comp_name])
	var age: float  = _vis._real_elapsed - float(_vis._transistor_cursors[tc_idx]["trigger_t"])
	if age >= 0.0 and age <= _vis.cursor_traverse_seconds:
		return   # already active — first trigger wins
	var tdata: Dictionary = _vis._transistor_data[comp_name]
	var is_pmos: bool = str(tdata["type"]) == "pfet"
	var vg: float = get_net_voltage_at(str(tdata["g"]), sim_idx)
	var vs: float = get_net_voltage_at(str(tdata["s"]), sim_idx)
	var conductance: float = clampf(
		(vs - vg - VisGeomUtils.VTH) / VisGeomUtils.VTH if is_pmos else (vg - vs - VisGeomUtils.VTH) / VisGeomUtils.VTH,
		0.0, 1.0)
	if conductance < 0.05:
		return
	_vis._transistor_cursors[tc_idx]["trigger_t"] = _vis._real_elapsed


## Re-seeds a net's wire BFS from the given transistor pin.
func cascade_net_from_pin(comp_name: String, pin_name: String, sim_idx: int) -> void:
	if not _vis._transistor_data.has(comp_name) or not _vis._transistor_nodes.has(comp_name):
		return
	var tdata: Dictionary      = _vis._transistor_data[comp_name]
	var target_net: String     = str(tdata[pin_name.to_lower()])
	if not _vis._net_cascade.has(target_net):
		return
	var sym: CircuitSymbol     = _vis._transistor_nodes[comp_name] as CircuitSymbol
	var pin_local: Vector3     = _vis.to_local(sym.get_pin_position(pin_name))
	var max_hop: int           = WireGraph.reseed_net(_vis._wire_cursors, target_net, pin_local, _vis.scale_factor)
	var nc: Dictionary         = _vis._net_cascade[target_net]
	nc["max_hop"]   = max_hop
	nc["trigger_t"] = _vis._real_elapsed
	if _vis._sim_vectors.has(target_net):
		var cvec: Array  = _vis._sim_vectors[target_net]
		var ni: int      = mini(sim_idx + 1, cvec.size() - 1)
		var v_new: float = float(cvec[ni])      if ni      < cvec.size() else 0.0
		var v_old: float = float(cvec[sim_idx]) if sim_idx < cvec.size() else 0.0
		nc["color_old"]  = voltage_to_color(v_old)
		nc["energy_old"] = 0.15 + 2.5 * clamp(v_old / VMAX, 0.0, 1.0)
		nc["color_new"]  = voltage_to_color(v_new)
		nc["energy_new"] = 0.15 + 2.5 * clamp(v_new / VMAX, 0.0, 1.0)


## Called when a transistor channel cursor finishes — cascades the output net.
## Which SPICE pin is the output depends on physical orientation (layout D/S can
## be swapped vs. schematic convention), so we read dest_spice_pin from the cursor.
func on_transistor_cursor_done(comp_name: String, sim_idx: int) -> void:
	if not _vis._transistor_data.has(comp_name):
		return
	var tc_idx: int = _vis._transistor_cursor_map.get(comp_name, -1)
	var dest_pin: String = "D"
	if tc_idx >= 0 and tc_idx < _vis._transistor_cursors.size():
		dest_pin = str(_vis._transistor_cursors[tc_idx].get("dest_spice_pin", "d")).to_upper()
	cascade_net_from_pin(comp_name, dest_pin, sim_idx)


# ---------- Per-frame animation ----------

func process_frame(delta: float) -> void:
	_vis._real_elapsed += delta

	if not _vis._anim_active or _vis._sim_time.size() < 2:
		return

	var sim_start: float    = float(_vis._sim_time[0])
	var sim_end: float      = float(_vis._sim_time[_vis._sim_time.size() - 1])
	var sim_duration: float = sim_end - sim_start
	if sim_duration <= 0.0:
		return

	_vis._anim_sim_elapsed = fmod(
		_vis._anim_sim_elapsed + delta * (sim_duration / _vis.anim_playback_duration),
		sim_duration
	)
	var sim_t: float = sim_start + _vis._anim_sim_elapsed

	# Binary search for the current time index.
	var lo: int = 0
	var hi: int = _vis._sim_time.size() - 1
	while lo < hi:
		var mid: int = (lo + hi + 1) / 2
		if float(_vis._sim_time[mid]) <= sim_t:
			lo = mid
		else:
			hi = mid - 1

	_update_wire_colors(lo)
	_update_wire_cursors(lo)
	_trigger_transistors_from_cascades(lo)
	_update_transistor_glow(lo)
	_update_channel_cursors(lo)
	_update_gate_cursors(lo)
	_trigger_transistors_from_unlabeled_gates(lo)


# ---------- Animation sub-sections ----------

func _update_wire_colors(lo: int) -> void:
	for net_name: String in _vis._sim_vectors.keys():
		if not _vis._net_materials.has(net_name):
			continue
		# Don't color wires that haven't been reached by the cascade chain yet.
		# They stay neutral gray until a cursor arrives from the upstream direction.
		if _vis._net_cascade.has(net_name) and float(_vis._net_cascade[net_name]["trigger_t"]) < -100.0:
			continue
		var vec: Array = _vis._sim_vectors[net_name]
		if lo >= vec.size():
			continue
		var voltage: float = float(vec[lo])
		var mat: StandardMaterial3D = _vis._net_materials[net_name]
		mat.emission = voltage_to_color(voltage)
		mat.emission_energy_multiplier = 0.15 + 2.5 * clamp(voltage / VMAX, 0.0, 1.0)


func _update_wire_cursors(lo: int) -> void:
	var next_idx: int = mini(lo + 1, _vis._sim_time.size() - 1)

	# Phase 1: detect per-net transitions and arm the cascade.
	# Only seed nets (directly connected to input pins) self-trigger here.
	# Nets behind transistors are triggered exclusively via cascade_net_from_pin
	# so current flow is causally ordered: input → gate → transistor → output net.
	for net: String in _vis._net_cascade.keys():
		if not _vis._sim_vectors.has(net):
			continue
		if not _vis._seed_nets.get(net, false):
			continue
		var cvec: Array = _vis._sim_vectors[net]
		if lo >= cvec.size() or next_idx >= cvec.size():
			continue
		var dv: float = float(cvec[next_idx]) - float(cvec[lo])
		if absf(dv) / VMAX < _vis.dv_anim_threshold:
			continue
		var nc: Dictionary = _vis._net_cascade[net]
		var done_t: float  = float(nc["trigger_t"]) + (int(nc["max_hop"]) + 1) * _vis.cursor_traverse_seconds
		if _vis._real_elapsed < done_t:
			continue
		nc["trigger_t"]  = _vis._real_elapsed
		var v_old: float = float(cvec[lo])
		var v_new: float = float(cvec[next_idx])
		nc["color_old"]  = voltage_to_color(v_old)
		nc["energy_old"] = 0.15 + 2.5 * clamp(v_old / VMAX, 0.0, 1.0)
		nc["color_new"]  = voltage_to_color(v_new)
		nc["energy_new"] = 0.15 + 2.5 * clamp(v_new / VMAX, 0.0, 1.0)

	# Phase 2: animate each wire cursor using its hop-delayed start time.
	for cursor_data: Dictionary in _vis._wire_cursors:
		var net: String              = cursor_data["net"]
		var cursor: MeshInstance3D   = cursor_data["cursor"]
		var wire_shader: ShaderMaterial = cursor_data["wire_shader"] as ShaderMaterial

		if not _vis._net_cascade.has(net):
			cursor.visible = false
			continue

		var nc: Dictionary = _vis._net_cascade[net]
		var hop: int       = cursor_data.get("hop_dist", 0)
		if hop >= 999: hop = 0
		var src_end: int   = cursor_data.get("source_end", 0)
		var age: float     = _vis._real_elapsed - float(nc["trigger_t"]) - hop * _vis.cursor_traverse_seconds

		if age < 0.0 or age > _vis.cursor_traverse_seconds:
			cursor.visible = false
			if wire_shader != null:
				wire_shader.set_shader_parameter("fill_fraction",  1.0)
				wire_shader.set_shader_parameter("color_behind",   Color.BLACK)
				wire_shader.set_shader_parameter("color_ahead",    Color.BLACK)
				wire_shader.set_shader_parameter("energy_behind",  0.0)
				wire_shader.set_shader_parameter("energy_ahead",   0.0)
			continue

		cursor.visible = true
		var phase: float    = clamp(age / _vis.cursor_traverse_seconds, 0.0, 1.0)
		var p_from: Vector3 = cursor_data["p1"] if src_end == 0 else cursor_data["p2"]
		var p_to:   Vector3 = cursor_data["p2"] if src_end == 0 else cursor_data["p1"]
		cursor.position     = p_from.lerp(p_to, phase)
		var fade: float     = 1.0 - smoothstep(0.8, 1.0, phase)
		var cursor_mat: StandardMaterial3D = cursor_data["cursor_mat"]
		cursor_mat.emission = nc["color_new"]
		cursor_mat.emission_energy_multiplier = (float(nc["energy_new"]) * 2.0 + 1.5) * fade

		if wire_shader != null:
			wire_shader.set_shader_parameter("fill_fraction",  phase)
			wire_shader.set_shader_parameter("fill_from_p1",   1 if src_end == 0 else 0)
			wire_shader.set_shader_parameter("color_behind",   nc["color_new"])
			wire_shader.set_shader_parameter("color_ahead",    nc["color_old"])
			wire_shader.set_shader_parameter("energy_behind",  nc["energy_new"])
			wire_shader.set_shader_parameter("energy_ahead",   nc["energy_old"])


func _trigger_transistors_from_cascades(lo: int) -> void:
	for net: String in _vis._net_cascade.keys():
		var nc: Dictionary = _vis._net_cascade[net]
		if float(nc["trigger_t"]) < -100.0:
			_vis._net_was_done[net] = true
			continue
		var done_t:  float = float(nc["trigger_t"]) + (int(nc["max_hop"]) + 1) * _vis.cursor_traverse_seconds
		var is_done: bool  = _vis._real_elapsed >= done_t
		var was_done: bool = _vis._net_was_done.get(net, true)
		_vis._net_was_done[net] = is_done
		if is_done and not was_done:
			if _vis._gate_to_transistors.has(net):
				for comp_name: String in (_vis._gate_to_transistors[net] as Array):
					try_trigger_transistor_cursor(comp_name, lo)
			if _vis._upstream_to_transistors.has(net):
				for comp_name: String in (_vis._upstream_to_transistors[net] as Array):
					try_trigger_transistor_cursor(comp_name, lo)


## Fires transistor gate cursors for transistors whose gate net has no labeled
## wire (and therefore no cascade entry).  Detects transitions directly from
## the simulation voltage.  Runs AFTER _update_gate_cursors so the channel
## cursor debounce is already armed before we check it.
func _trigger_transistors_from_unlabeled_gates(lo: int) -> void:
	var next_idx: int = mini(lo + 1, _vis._sim_time.size() - 1)
	for comp_name: String in _vis._transistor_data.keys():
		var tdata: Dictionary = _vis._transistor_data[comp_name]
		var gate_net: String  = str(tdata["g"])

		# If the gate net has a labeled wire, the cascade / Phase-1 path handles it.
		if _vis._net_cascade.has(gate_net):
			continue

		# Skip if gate cursor is currently traveling.
		if _vis._gate_cursor_map.has(comp_name):
			var gc: Dictionary = _vis._gate_cursors[int(_vis._gate_cursor_map[comp_name])]
			var gc_age: float  = _vis._real_elapsed - float(gc["trigger_t"])
			var g_trav: float  = float(gc.get("traverse", _vis.cursor_traverse_seconds * 0.35))
			if gc_age >= 0.0 and gc_age <= g_trav:
				continue

		# Skip if channel cursor is currently traveling (fired by this gate's completion).
		if _vis._transistor_cursor_map.has(comp_name):
			var tc: Dictionary = _vis._transistor_cursors[int(_vis._transistor_cursor_map[comp_name])]
			var tc_age: float  = _vis._real_elapsed - float(tc["trigger_t"])
			if tc_age >= 0.0 and tc_age <= _vis.cursor_traverse_seconds:
				continue

		# Detect a voltage transition on the gate net.
		if not _vis._sim_vectors.has(gate_net):
			continue
		var cvec: Array = _vis._sim_vectors[gate_net]
		if lo >= cvec.size() or next_idx >= cvec.size():
			continue
		var dv: float = float(cvec[next_idx]) - float(cvec[lo])
		if absf(dv) / VMAX < _vis.dv_anim_threshold:
			continue

		try_trigger_transistor_cursor(comp_name, lo)


func _update_transistor_glow(lo: int) -> void:
	for comp_name: String in _vis._transistor_data.keys():
		if not _vis._transistor_materials.has(comp_name):
			continue
		var tdata: Dictionary = _vis._transistor_data[comp_name]
		var is_pmos: bool     = str(tdata["type"]) == "pfet"
		var vg: float = get_net_voltage_at(str(tdata["g"]), lo)
		var vs: float = get_net_voltage_at(str(tdata["s"]), lo)
		var conductance: float
		if is_pmos:
			conductance = clampf((vs - vg - VisGeomUtils.VTH) / VisGeomUtils.VTH, 0.0, 1.0)
		else:
			conductance = clampf((vg - vs - VisGeomUtils.VTH) / VisGeomUtils.VTH, 0.0, 1.0)
		var base_color: Color = Color(0.2, 0.8, 1.0) if not is_pmos else Color(1.0, 0.2, 0.8)
		var hot_color: Color  = Color(1.0, 0.95, 0.3)
		var tmat: StandardMaterial3D = _vis._transistor_materials[comp_name]
		tmat.emission = base_color.lerp(hot_color, conductance)
		tmat.emission_energy_multiplier = 0.15 + conductance * 2.5


func _update_channel_cursors(lo: int) -> void:
	for i: int in range(_vis._transistor_cursors.size()):
		var tc:        Dictionary     = _vis._transistor_cursors[i]
		var tc_cursor: MeshInstance3D = tc["cursor"]
		var age:       float          = _vis._real_elapsed - float(tc["trigger_t"])
		var is_idle:   bool           = age < 0.0 or age > _vis.cursor_traverse_seconds
		var was_idle:  bool           = _vis._tc_was_done[i] if i < _vis._tc_was_done.size() else true
		_vis._tc_was_done[i] = is_idle

		if is_idle:
			tc_cursor.visible = false
			if not was_idle:
				on_transistor_cursor_done(str(tc["comp_name"]), lo)
			continue

		tc_cursor.visible = true
		var phase: float = age / _vis.cursor_traverse_seconds
		var fade:  float = 1.0 - smoothstep(0.8, 1.0, phase)
		tc_cursor.position = VisGeomUtils.path_eval(
			tc.get("path", [tc["p_from"], tc["p_to"]]) as Array,
			tc.get("cum",  []) as Array,
			phase)
		var tc_mat: StandardMaterial3D = tc["cursor_mat"]
		tc_mat.emission_energy_multiplier = 4.0 * fade


func _update_gate_cursors(lo: int) -> void:
	for i: int in range(_vis._gate_cursors.size()):
		var gc:        Dictionary     = _vis._gate_cursors[i]
		var gc_cursor: MeshInstance3D = gc["cursor"]
		var g_trav:    float          = float(gc.get("traverse", _vis.cursor_traverse_seconds * 0.35))
		var age:       float          = _vis._real_elapsed - float(gc["trigger_t"])
		var is_idle:   bool           = age < 0.0 or age > g_trav
		var was_idle:  bool           = _vis._gc_was_done[i] if i < _vis._gc_was_done.size() else true
		_vis._gc_was_done[i] = is_idle

		var gate_net: String = gc["gate_net"]
		var cn:       String = str(gc["comp_name"])

		# Read transistor body color/energy — already updated by _update_transistor_glow.
		var tmat_color:  Color = Color(1.0, 0.2, 0.8)
		var tmat_energy: float = 1.0
		if _vis._transistor_materials.has(cn):
			var tmat: StandardMaterial3D = _vis._transistor_materials[cn]
			tmat_color  = tmat.emission
			tmat_energy = tmat.emission_energy_multiplier

		# Traveling cursor.
		if is_idle:
			gc_cursor.visible = false
			if not was_idle:
				gc["gbar_t"]   = _vis._real_elapsed
				gc["gflash_t"] = _vis._real_elapsed
				# Gate is now connected — fire the channel cursor.
				_fire_channel_cursor(cn, lo)
		else:
			gc_cursor.visible = true
			var phase: float = clamp(age / g_trav, 0.0, 1.0)
			var fade:  float = 1.0 - smoothstep(0.8, 1.0, phase)
			gc_cursor.position = (gc["p_from"] as Vector3).lerp(gc["p_to"] as Vector3, phase)
			var gc_mat: StandardMaterial3D = gc["cursor_mat"]
			gc_mat.emission = tmat_color
			gc_mat.emission_energy_multiplier = tmat_energy * 2.0 * fade

		# Contact flash.
		var gflash: MeshInstance3D         = gc["gflash"]
		var gflash_mat: StandardMaterial3D = gc["gflash_mat"]
		var flash_age: float = _vis._real_elapsed - float(gc.get("gflash_t", -999.0))
		if flash_age >= 0.0 and flash_age <= 0.5:
			gflash.visible = true
			var fp: float      = flash_age / 0.5
			var flash_e: float = smoothstep(0.0, 0.15, fp) * (1.0 - smoothstep(0.6, 1.0, fp))
			gflash_mat.emission = tmat_color
			gflash_mat.emission_energy_multiplier = flash_e * 8.0
			if _vis._transistor_materials.has(cn):
				var tmat: StandardMaterial3D = _vis._transistor_materials[cn]
				tmat.emission_energy_multiplier = maxf(tmat.emission_energy_multiplier, flash_e * 3.5)
		else:
			gflash.visible = false

		# Gate oxide gap fill ("O| |" → "O|█|").
		var gbar: MeshInstance3D         = gc["gbar"]
		var gbar_mat: StandardMaterial3D = gc["gbar_mat"]
		var gbar_age: float = _vis._real_elapsed - float(gc.get("gbar_t", -999.0))
		if gbar_age < 0.0 or gbar_age > 1.0:
			gbar.visible = false
		else:
			gbar.visible = true
			gbar_mat.emission = tmat_color
			gbar_mat.emission_energy_multiplier = smoothstep(0.0, 0.1, gbar_age) * (1.0 - smoothstep(0.6, 1.0, gbar_age)) * tmat_energy
