extends Node3D

## Preloaded once at class level so every wire shares the same Shader object.
const _WIRE_FILL_SHADER = preload("res://visualizer/wire_fill.gdshader")

@export var scale_factor: float = 0.01

## Real seconds over which the full simulation period plays back (loop).
@export var anim_playback_duration: float = 5.0

## Real seconds it takes for a flow cursor to travel one wire segment.
@export var cursor_traverse_seconds: float = 1.5

## Minimum |ΔV| / Vmax that triggers a cursor (lower = more sensitive).
@export var dv_anim_threshold: float = 0.04

var parser: SchParser
var _sidebar: SidebarPanel = null
var _floor: MeshInstance3D = null

# ---------- Shared state (read/written by helper scripts) ----------

## Symbol definition cache: symbol_name → SymbolDefinition.
var _sym_cache: Dictionary = {}

## Shared materials: component_type → StandardMaterial3D.
var _materials: Dictionary = {}

## Search paths for .sym files.
var _sym_search_paths: Array[String] = [
	"res://symbols/sym/",
	"res://symbols/sym/sky130_fd_pr/",
	"res://symbols/",
	"res://symbols/sky130_fd_pr/",
]

## net_label_lower → Array[MeshInstance3D]
var _net_nodes: Dictionary = {}
## net_label_lower → StandardMaterial3D
var _net_materials: Dictionary = {}

var _sim_time: Array = []
var _sim_vectors: Dictionary = {}   # normalized_name → Array[float]
var _anim_active: bool = false
var _anim_sim_elapsed: float = 0.0
var _real_elapsed: float = 0.0      # monotonic real-time counter

## Wire flow cursors: one per labeled segment.
var _wire_cursors: Array[Dictionary] = []

## Transistor connectivity from paired SPICE: comp_name → {d,g,s,b,type}.
var _transistor_data: Dictionary = {}
## Per-transistor duplicated material for independent conductance animation.
var _transistor_materials: Dictionary = {}
## CircuitSymbol nodes keyed by comp_name for pin position lookup.
var _transistor_nodes: Dictionary = {}

## Channel cursors: one per transistor, travels D→S through the body.
var _transistor_cursors: Array[Dictionary] = []
var _transistor_cursor_map: Dictionary = {}   # comp_name → index

## Gate cursors + flash/fill: one per transistor.
var _gate_cursors: Array[Dictionary] = []
var _gate_cursor_map: Dictionary = {}

## World positions of input-pin components for cascade BFS seeding.
var _input_positions: Array[Vector3] = []

## Per-net cascade state: net_label → {trigger_t, max_hop, color_old/new, energy_old/new}.
var _net_cascade: Dictionary = {}

## gate_net (lower) → Array[String] comp_names whose gate is that net.
var _gate_to_transistors: Dictionary = {}
## upstream_net → Array[String] comp_names whose inlet (D) is that net.
var _upstream_to_transistors: Dictionary = {}

## Edge-detection trackers (true = was idle last frame).
var _net_was_done: Dictionary = {}
var _tc_was_done: Array[bool] = []
var _gc_was_done: Array[bool] = []

## Nets directly reachable from input pins through wire connections (hop_dist < 999).
## Only these nets self-trigger their cascades from voltage-transition detection.
## All other nets (behind transistors) are triggered only via cascade_net_from_pin.
var _seed_nets: Dictionary = {}

# ---------- Helper instances ----------
var _scene_builder:  VisSceneBuilder
var _cursor_builder: VisCursorBuilder
var _anim_player:    VisAnimPlayer


func _ready() -> void:
	parser = SchParser.new()
	_materials = VisMaterialFactory.build_materials()
	_floor = VisMaterialFactory.create_floor(self)
	_scene_builder  = VisSceneBuilder.new(self)
	_cursor_builder = VisCursorBuilder.new(self)
	_anim_player    = VisAnimPlayer.new(self)
	_setup_upload_ui()


func _process(delta: float) -> void:
	_anim_player.process_frame(delta)


# ---------- Schematic loading ----------

func load_schematic(path: String) -> bool:
	if not parser.parse_file(path):
		push_error("Failed to parse: " + path)
		return false

	_scene_builder.draw_circuit(parser, _floor)

	var type_counts: Dictionary = {}
	for comp in parser.components:
		var t: String = comp.get("type", "unknown")
		type_counts[t] = type_counts.get(t, 0) + 1
	print("=== Loaded: %s ===" % path)
	print("  Components: %d" % parser.components.size())
	for t in type_counts:
		print("    %s: %d" % [t, type_counts[t]])
	print("  Wires: %d" % parser.wires.size())
	print("  Scene nodes: %d" % get_child_count())

	return true


# ---------- UI setup ----------

func _setup_upload_ui() -> void:
	var sim: Node = null
	var sim_packed: Resource = load("res://circuit_simulator.tscn")
	if sim_packed is PackedScene:
		sim = (sim_packed as PackedScene).instantiate()
	else:
		# Fallback for repos that have the simulator script but no wrapper scene.
		var sim_script: Resource = load("res://simulator/circuit_simulator.gd")
		if sim_script is GDScript:
			var created: Variant = (sim_script as GDScript).new()
			if created is Node:
				sim = created as Node

	if sim != null:
		sim.name = "CircuitSimulator"
		if sim.has_signal("simulation_finished"):
			sim.connect("simulation_finished", Callable(self, "_on_simulation_finished"))
		get_parent().add_child.call_deferred(sim)
	else:
		push_warning("Could not create CircuitSimulator (missing res://circuit_simulator.tscn and/or res://simulator/circuit_simulator.gd). Simulation will be unavailable.")

	_sidebar = SidebarPanel.new()
	_sidebar.name = "Sidebar"
	_sidebar.schematic_requested.connect(_on_schematic_requested)
	_sidebar.spice_paired.connect(_on_spice_paired)

	var ui_layer := CanvasLayer.new()
	ui_layer.layer = 10
	ui_layer.name = "UILayer"
	get_parent().add_child.call_deferred(ui_layer)
	ui_layer.add_child(_sidebar)


# ---------- Signal handlers ----------

func _on_schematic_requested(path: String) -> void:
	print("Loading schematic from UI: " + path)
	load_schematic(path)


func _on_spice_paired(path: String) -> void:
	_transistor_data = VisGeomUtils.parse_spice_transistors(path)
	print("Visualizer: paired SPICE — %d transistors mapped for conductance animation" % _transistor_data.size())
	_cursor_builder.build_transistor_cursors()

	# Gate net map: straight-forward from SPICE.
	_gate_to_transistors.clear()
	for comp_name: String in _transistor_data.keys():
		var gate_net: String = str(_transistor_data[comp_name]["g"])
		if not _gate_to_transistors.has(gate_net):
			_gate_to_transistors[gate_net] = []
		(_gate_to_transistors[gate_net] as Array).append(comp_name)

	# Upstream net map: built from from_spice_pin stored in each cursor, because
	# layout SPICE can swap D and S vs. schematic convention.  This ensures that
	# when an internal node cascade finishes, the next transistor in the current
	# path (whose supply side sits at that node) is triggered correctly.
	_upstream_to_transistors.clear()
	for tc: Dictionary in _transistor_cursors:
		var cn: String = str(tc["comp_name"])
		if not _transistor_data.has(cn):
			continue
		var from_pin: String    = str(tc.get("from_spice_pin", "s"))
		var source_net: String  = str(_transistor_data[cn][from_pin])
		if not _upstream_to_transistors.has(source_net):
			_upstream_to_transistors[source_net] = []
		(_upstream_to_transistors[source_net] as Array).append(cn)

	print("Visualizer: %d gate nets, %d upstream nets wired for cascade" % [
		_gate_to_transistors.size(), _upstream_to_transistors.size()])


func _on_simulation_finished() -> void:
	print("Simulation finished — fetching vectors for animation...")
	var sim: Node = get_tree().root.find_child("CircuitSimulator", true, false)
	if sim == null:
		push_warning("Visualizer: CircuitSimulator not found after simulation_finished")
		return

	var names: PackedStringArray = sim.call("get_last_sim_signal_names")
	var snapshot: Array = sim.call("get_last_sim_snapshot")
	print("Visualizer: buffer has %d signal names, %d samples" % [names.size(), snapshot.size()])
	if names.size() > 0:
		print("Visualizer: signal names = ", Array(names))

	if names.size() > 0 and snapshot.size() > 0:
		var all_vecs: Dictionary = {}
		for i: int in range(names.size()):
			var col: Array = []
			col.resize(snapshot.size())
			for s: int in range(snapshot.size()):
				var row: PackedFloat64Array = snapshot[s]
				col[s] = float(row[i]) if i < row.size() else 0.0
			all_vecs[str(names[i])] = col
		_anim_player.load_sim_data(all_vecs)
		return

	push_warning("Visualizer: callback buffer empty — falling back to get_all_vectors()")
	var all_vecs: Dictionary = sim.call("get_all_vectors")
	if all_vecs.is_empty():
		push_warning("Visualizer: simulation_finished but no vectors available")
		return
	_anim_player.load_sim_data(all_vecs)
