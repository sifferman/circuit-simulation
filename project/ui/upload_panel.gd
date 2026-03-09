extends Control

@export var simulator_path: NodePath = NodePath("..")
@export var pdk_root: String = ""
@export var auto_start_continuous: bool = false
@export var continuous_step: float = 1e-11
@export var continuous_window: float = 2e-8
@export var continuous_sleep_ms: int = 25
@export var continuous_memory_signals: PackedStringArray = PackedStringArray()
@export var continuous_memory_max_samples: int = 10000
@export var continuous_memory_pop_count: int = 256
const UPLOAD_DIR := "user://uploads"

const WORKSPACE_EXT := ".cvw.zip"
const WORKSPACE_MANIFEST := "manifest.json"
const WORKSPACE_FILES_DIR := "files/"

# Emitted when a .sch schematic file is selected — consumed by the 3D visualizer.
signal schematic_requested(path: String)

# Emitted when a .spice netlist is about to be simulated — carries the OS path
# so the visualizer can parse transistor D/G/S connections for conductance animation.
signal spice_paired(path: String)

var NETLIST_EXTS: PackedStringArray = PackedStringArray(["spice", "cir", "net", "txt"])
var XSCHEM_EXTS: PackedStringArray = PackedStringArray(["sch", "sym"])

@onready var upload_button: Button = get_node_or_null("Margin/VBox/ControlsRow/UploadButton") as Button
@onready var run_button: Button = get_node_or_null("Margin/VBox/ControlsRow/RunButton") as Button
@onready var continuous_button: Button = get_node_or_null("Margin/VBox/ControlsRow/ContinuousButton") as Button
@onready var clear_button: Button = get_node_or_null("Margin/VBox/ControlsRow/ClearButton") as Button
@onready var save_ws_button: Button = get_node_or_null("Margin/VBox/ControlsRow/SaveWorkspaceButton") as Button
@onready var load_ws_button: Button = get_node_or_null("Margin/VBox/ControlsRow/LoadWorkspaceButton") as Button
@onready var staged_list: ItemList = get_node_or_null("Margin/VBox/StagedList") as ItemList
@onready var status_bar: PanelContainer = get_node_or_null("Margin/VBox/StatusBar") as PanelContainer
@onready var status_prefix: Label = get_node_or_null("Margin/VBox/StatusRow/StatusPrefix") as Label
@onready var status_value: Label = get_node_or_null("Margin/VBox/StatusRow/StatusValue") as Label
@onready var output_box: RichTextLabel = get_node_or_null("Margin/VBox/Output") as RichTextLabel
@onready var file_dialog: FileDialog = get_node_or_null("FileDialog") as FileDialog
@onready var workspace_dialog: FileDialog = get_node_or_null("WorkspaceDialog") as FileDialog

@onready var drop_zone: PanelContainer = get_node_or_null("Margin/VBox/DropZone") as PanelContainer
@onready var drop_title: Label = get_node_or_null("Margin/VBox/DropZone/DropZoneMargin/DropZoneVBox/DropTitle") as Label
@onready var drop_hint: Label = get_node_or_null("Margin/VBox/DropZone/DropZoneMargin/DropZoneVBox/DropHint") as Label

# Each entry:
# { "display": String, "user_path": String, "bytes": int, "kind": String, "ext": String }
var staged: Array[Dictionary] = []
var _sim_signal_connected: bool = false
var _continuous_signal_connected: bool = false
var _sim: Node = null
var _continuous_frame_count: int = 0
var _using_memory_buffer: bool = false
var _ws_mode: String = "" # "save" or "load"

# --- Aesthetic theme state (light, "Microsoft-esque") ---
var _t: Theme = null
var _sb_panel: StyleBoxFlat = null
var _sb_panel_hover: StyleBoxFlat = null
var _sb_drop_idle: StyleBoxFlat = null
var _sb_drop_flash: StyleBoxFlat = null
var _sb_status_bar: StyleBoxFlat = null

enum StatusTone { IDLE, OK, WARN, ERROR }

# Handles single-file selection from the native file dialog.
func _on_native_file_selected(path: String) -> void:
	var normalized: String = _normalize_native_path(path)
	if normalized.is_empty():
		return
	var added: int = int(_stage_native_file(normalized))
	if added > 0:
		_flash_drop_zone()
		_refresh_status("native: staged 1 file", StatusTone.OK)

# Initializes node references, UI theme, and runtime signal wiring.
func _ready() -> void:
	if upload_button == null or run_button == null or clear_button == null or staged_list == null or status_prefix == null or status_value == null or file_dialog == null or drop_zone == null or drop_title == null or drop_hint == null:
		push_error("UploadPanel scene is missing required child nodes. Ensure res://ui/upload_panel.tscn matches upload_panel.gd paths.")
		return

	_apply_light_theme()
	_ensure_upload_dir()

	upload_button.pressed.connect(_on_upload_pressed)
	run_button.pressed.connect(_on_run_pressed)
	if continuous_button != null:
		continuous_button.pressed.connect(_on_continuous_pressed)
	clear_button.pressed.connect(_on_clear_pressed)
	staged_list.item_activated.connect(_on_staged_item_activated)
	file_dialog.file_selected.connect(_on_native_file_selected)
	file_dialog.files_selected.connect(_on_native_files_selected)
	if not OS.has_feature("web"):
		file_dialog.use_native_dialog = true
		file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
		file_dialog.filters = PackedStringArray([
			"*.spice, *.cir, *.net, *.txt ; Netlists",
			"*.sch, *.sym ; Xschem schematics/symbols",
			"* ; All files"
		])

	if save_ws_button != null:
		save_ws_button.pressed.connect(_on_save_workspace_pressed)
	if load_ws_button != null:
		load_ws_button.pressed.connect(_on_load_workspace_pressed)
	if workspace_dialog != null:
		workspace_dialog.file_selected.connect(_on_workspace_dialog_file_selected)

	# OS drag-and-drop (IMPORTANT):
	# On Windows, when running from the editor, drag-drop can be intercepted by the editor UI,
	# so the most reliable test is in an exported .exe.
	if not OS.has_feature("web"):
		if get_viewport() != null:
			if not get_viewport().files_dropped.is_connected(_on_os_files_dropped):
				get_viewport().files_dropped.connect(_on_os_files_dropped)

		var w: Window = get_window()
		if w != null:
			if not w.files_dropped.is_connected(_on_os_files_dropped):
				w.files_dropped.connect(_on_os_files_dropped)

		if Engine.is_editor_hint():
			_log("[color=yellow]Note:[/color] In the editor, Windows drag-drop often targets the editor window instead of the running game. Export and run the .exe to test OS drag-drop reliably.")

	_sim = _resolve_simulator()
	_refresh_status("idle", StatusTone.IDLE)

	if OS.has_feature("web"):
		var has_bridge: bool = _web_eval_bool("typeof window.godotUploadOpenPicker === 'function' && Array.isArray(window.godotUploadQueue)")
		if has_bridge:
			_log("[color=lime]Web upload bridge detected.[/color]")
		else:
			_log("[color=yellow]Web upload bridge not detected yet. Ensure upload_bridge.js is included in the exported HTML.[/color]")

# Polls the browser upload queue each frame in web builds.
func _process(_delta: float) -> void:
	if OS.has_feature("web"):
		_poll_web_queue()

# -------------------------------------------------------------------
# Upload flows
# -------------------------------------------------------------------

# Opens the upload picker appropriate for web or desktop.
func _on_upload_pressed() -> void:
	if OS.has_feature("web"):
		var ok: bool = _web_eval_bool("typeof window.godotUploadOpenPicker === 'function'")
		if not ok:
			_set_error("Web picker not available. Did you include res://web/shell/upload_bridge.js in the export HTML?")
			return
		JavaScriptBridge.eval("window.godotUploadOpenPicker()", true)
		_refresh_status("web: picker opened", StatusTone.WARN)
	else:
		file_dialog.popup_centered_ratio(0.8)
		_refresh_status("native: file dialog opened", StatusTone.WARN)

# Stages all files returned by native multi-select.
func _on_native_files_selected(paths: PackedStringArray) -> void:
	if paths.is_empty():
		return
	var added: int = 0
	for p: String in paths:
		var normalized: String = _normalize_native_path(p)
		if normalized.is_empty():
			continue
		added += int(_stage_native_file(normalized))
	_flash_drop_zone()
	_refresh_status("native: staged %d file(s)" % added, StatusTone.OK)

# Handles OS drag-and-drop file payloads.
func _on_os_files_dropped(files: PackedStringArray) -> void:
	if OS.has_feature("web"):
		return
	if files.is_empty():
		return

	var added: int = 0
	for p: String in files:
		var normalized: String = _normalize_native_path(p)
		if normalized.is_empty():
			continue
		added += int(_stage_native_file(normalized))

	if added > 0:
		_flash_drop_zone()
		_refresh_status("native: dropped %d file(s)" % added, StatusTone.OK)
	else:
		_refresh_status("native: drop received, no valid files", StatusTone.WARN)

# Reads a native file from disk and stages its bytes.
func _stage_native_file(src_path: String) -> bool:
	var normalized_path: String = _normalize_native_path(src_path)
	if normalized_path.is_empty():
		_set_error("File selection returned an empty/null path.")
		return false

	if not FileAccess.file_exists(normalized_path):
		_set_error("File does not exist: %s" % normalized_path)
		return false

	var src: FileAccess = FileAccess.open(normalized_path, FileAccess.READ)
	if src == null:
		_set_error("Failed to open: %s" % normalized_path)
		return false

	var length: int = int(src.get_length())
	var bytes: PackedByteArray = src.get_buffer(length)
	src.close()

	if bytes == null:
		bytes = PackedByteArray()
	if bytes.is_empty() and length > 0:
		var fallback_text: String = FileAccess.get_file_as_string(normalized_path)
		bytes = fallback_text.to_utf8_buffer()
		if bytes.is_empty():
			_set_error("Selected file read as null/empty bytes: %s" % normalized_path)
			return false

	var base_name: String = normalized_path.get_file()
	var ok: bool = _stage_bytes(base_name, bytes)
	# Store original path so load_netlist resolves relative references (.stim, .include) correctly.
	if ok and not staged.is_empty():
		staged[-1]["native_path"] = normalized_path
	return ok

# Writes staged bytes into user://uploads and tracks metadata.
func _stage_bytes(original_name: String, bytes: PackedByteArray) -> bool:
	_ensure_upload_dir()

	var safe_name: String = _sanitize_filename(original_name)
	var user_path: String = "%s/%s" % [UPLOAD_DIR, safe_name]
	user_path = _avoid_collision(user_path)

	var f: FileAccess = FileAccess.open(user_path, FileAccess.WRITE)
	if f == null:
		_set_error("Failed to write into %s" % user_path)
		return false
	f.store_buffer(bytes)
	f.close()

	var ext: String = safe_name.get_extension().to_lower()
	var kind: String = _detect_kind(ext, bytes)

	var entry: Dictionary = {
		"display": safe_name,
		"user_path": user_path,
		"bytes": bytes.size(),
		"kind": kind,
		"ext": ext
	}
	staged.append(entry)
	_rebuild_list()
	_log("[color=lightblue]Staged[/color] %s  →  %s" % [safe_name, user_path])
	return true

# -------------------------------------------------------------------
# Web queue polling (JS -> Godot)
# -------------------------------------------------------------------

# Pulls one queued web upload item and stages it.
func _poll_web_queue() -> void:
	var raw: Variant = JavaScriptBridge.eval("""
		(() => {
			if (!Array.isArray(window.godotUploadQueue) || window.godotUploadQueue.length === 0) return null;
			const item = window.godotUploadQueue.shift();
			return JSON.stringify(item);
		})()
	""", true)

	if raw == null:
		return

	var json: String = str(raw)
	if json.is_empty():
		return

	var parsed: Variant = JSON.parse_string(json)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		_set_error("Web upload: failed to parse queued JSON.")
		return

	var d: Dictionary = parsed as Dictionary
	if not d.has("name") or not d.has("base64"):
		_set_error("Web upload: queue item missing fields.")
		return

	if d.has("error") and str(d["error"]) != "":
		_set_error("Web upload error for %s: %s" % [str(d.get("name", "unknown")), str(d["error"])])
		return

	var filename: String = str(d.get("name", "upload.bin"))
	var b64: String = str(d.get("base64", ""))
	var bytes: PackedByteArray = Marshalls.base64_to_raw(b64)

	# If it's a workspace zip, load it instead of staging it normally.
	if _looks_like_workspace_zip(filename, bytes):
		var ok_ws: bool = _load_workspace_zip_from_bytes(bytes)
		if ok_ws:
			_refresh_status("web: workspace loaded", StatusTone.OK)
		return

	var ok: bool = _stage_bytes(filename, bytes)
	if ok:
		_flash_drop_zone()
		_refresh_status("web: staged %s (%s)" % [filename, _human_size(bytes.size())], StatusTone.OK)

# Returns true if filename + magic bytes look like a workspace zip.
func _looks_like_workspace_zip(filename: String, bytes: PackedByteArray) -> bool:
	var lower := filename.to_lower()
	if not (lower.ends_with(WORKSPACE_EXT) or lower.ends_with(".zip")):
		return false
	if bytes.size() < 2:
		return false
	return int(bytes[0]) == 0x50 and int(bytes[1]) == 0x4B

# Evaluates a JS expression and returns it as boolean.
func _web_eval_bool(expr: String) -> bool:
	var v: Variant = JavaScriptBridge.eval("(%s) ? true : false" % expr, true)
	return bool(v)

# -------------------------------------------------------------------
# Run / visualize
# -------------------------------------------------------------------

# Double-clicking a staged item selects and runs it immediately.
func _on_staged_item_activated(index: int) -> void:
	if index < 0 or index >= staged.size():
		return
	staged_list.select(index)
	_on_run_pressed()

# Dispatches to schematic visualization or netlist simulation based on file type.
func _on_run_pressed() -> void:
	if staged.is_empty():
		_set_error("No staged files. Upload a .sch schematic or .spice/.cir/.net/.txt netlist first.")
		return

	var idx: PackedInt32Array = staged_list.get_selected_items()
	if idx.is_empty():
		_set_error("Select a staged file in the list first.")
		return

	var entry: Dictionary = staged[int(idx[0])]

	# .sch files → visualize in 3D only. Simulation comes from the paired .spice file.
	if _is_schematic_entry(entry):
		var sch_user_path: String = str(entry["user_path"])
		_log("[color=lime]Visualizing schematic:[/color] %s" % str(entry["display"]))
		_refresh_status("loading schematic…", StatusTone.WARN)
		schematic_requested.emit(sch_user_path)
		_refresh_status("schematic loaded — select the paired .spice and click Run to simulate", StatusTone.OK)
		return

	if not _is_netlist_entry(entry):
		_set_error("Selected file is not a supported type. Choose .sch, .spice, .cir, .net, or .txt.")
		return

	if OS.has_feature("web"):
		_set_error("Web build: ngspice runtime is not supported yet, staging works though.")
		return

	# Auto-load the paired schematic (same base name) so the 3D scene and
	# net→wire mapping are ready before simulation results arrive.
	var sch_pair: Dictionary = _find_matching_sch(entry)
	if not sch_pair.is_empty():
		_log("[color=lightblue]Pairing schematic:[/color] %s" % str(sch_pair["display"]))
		schematic_requested.emit(str(sch_pair["user_path"]))

	_sim = _resolve_simulator()
	if _sim == null:
		_set_error("Could not find CircuitSimulator node. Ensure the harness instanced it, or set simulator_path.")
		return

	if not _sim.has_method("initialize_ngspice"):
		_set_error("Resolved node lacks initialize_ngspice(). Wrong simulator_path?")
		return

	if (not _sim_signal_connected) and _sim.has_signal("simulation_finished"):
		_sim.connect("simulation_finished", Callable(self, "_on_sim_finished"))
		_sim_signal_connected = true
	if (not _continuous_signal_connected) and _sim.has_signal("continuous_transient_started") and _sim.has_signal("continuous_transient_stopped") and _sim.has_signal("continuous_transient_frame"):
		_sim.connect("continuous_transient_started", Callable(self, "_on_continuous_started"))
		_sim.connect("continuous_transient_stopped", Callable(self, "_on_continuous_stopped"))
		_sim.connect("continuous_transient_frame", Callable(self, "_on_continuous_frame"))
		_continuous_signal_connected = true

	_refresh_status("native: initializing ngspice…", StatusTone.WARN)
	var init_ok: Variant = _sim.call("initialize_ngspice")
	if not bool(init_ok):
		_set_error("initialize_ngspice() returned false.")
		return

	_refresh_status("native: loading netlist…", StatusTone.WARN)
	var godot_path: String = str(entry["user_path"])
	var os_path: String = ProjectSettings.globalize_path(godot_path)
	# Prefer the original file location so relative references (.stim, .include) resolve correctly.
	var native_path: String = str(entry.get("native_path", ""))
	if native_path != "" and FileAccess.file_exists(native_path):
		os_path = native_path

	# Notify visualizer of the paired SPICE path so it can parse transistor
	# D/G/S connections for conductance-based animation.
	spice_paired.emit(os_path)

	# Resolve PDK root: inspector export > OS environment variable.
	var effective_pdk_root: String = pdk_root
	if effective_pdk_root.is_empty():
		effective_pdk_root = OS.get_environment("PDK_ROOT")

	# Detect bare subcircuit files (.subckt/.ends with no analysis) and auto-wrap in memory.
	var subckt_info: Dictionary = _parse_subcircuit_info(os_path)
	if not subckt_info.is_empty() and _sim.has_method("load_netlist_string"):
		var wrapper: String = _build_sim_wrapper(
			os_path,
			str(subckt_info["name"]),
			subckt_info["ports"] as Array,
			effective_pdk_root
		)
		_log("[color=lightblue]Subcircuit detected:[/color] %s — auto-generating stimulus" % str(subckt_info["name"]))
		_refresh_status("native: loading subcircuit…", StatusTone.WARN)
		var loaded: bool = bool(_sim.call("load_netlist_string", wrapper))
		if not loaded:
			_set_error("Failed to load auto-generated wrapper. Check ngspice output.")
			return
		# The wrapper deck contains .tran — bg_run picks it up and fires simulation_finished.
		_refresh_status("native: running simulation on subcircuit…", StatusTone.WARN)
		var subckt_run_ok: bool = bool(_sim.call("run_simulation"))
		if not subckt_run_ok:
			_set_error("run_simulation() failed for the auto-generated subcircuit wrapper. Ensure ngspice is loaded and check output logs for deck errors.")
		return

	if _sim.has_method("load_netlist"):
		_refresh_status("native: running spice pipeline…", StatusTone.WARN)
		var run_result: Variant = _sim.call("load_netlist", os_path, effective_pdk_root)
		if typeof(run_result) != TYPE_DICTIONARY:
			_set_error("load_netlist() returned unexpected result.")
			return

		var result_dict: Dictionary = run_result as Dictionary
		if result_dict.is_empty():
			_set_error("load_netlist() returned no data. Check ngspice output for deck errors.")
			return

		var key_count: int = result_dict.keys().size()
		_refresh_status("native: netlist loaded (%d result fields)" % key_count, StatusTone.OK)
		_log("[color=lime]Netlist loaded.[/color] Result keys: %s" % [str(result_dict.keys())])

	if not auto_start_continuous:
		# Always use bg_run so simulation_finished fires and the visualizer can animate.
		# load_netlist preserves top-level .tran commands; bg_run executes them in the background.
		_refresh_status("native: running simulation (bg_run)…", StatusTone.WARN)
		_log("[color=lightblue]Starting simulation (bg_run)…[/color]")
		var run_ok: bool = bool(_sim.call("run_simulation"))
		if not run_ok:
			_set_error("run_simulation() failed. Ensure your netlist includes an analysis command (for example .tran) and check ngspice output.")
			return

	if auto_start_continuous and _sim.has_method("start_continuous_transient"):
			_configure_stream_output_if_enabled()
			var started: bool = bool(_sim.call("start_continuous_transient", continuous_step, continuous_window, continuous_sleep_ms))
			if started:
				_refresh_status("native: continuous transient started", StatusTone.OK)
			else:
				_set_error("Failed to start continuous transient loop.")
	return

	_set_error("CircuitSimulator build does not expose load_netlist().")

# Toggles continuous transient mode for the loaded netlist.
func _on_continuous_pressed() -> void:
	if OS.has_feature("web"):
		_set_error("Web build: continuous ngspice mode is not supported.")
		return

	_sim = _resolve_simulator()
	if _sim == null:
		_set_error("Could not find CircuitSimulator node.")
		return
	if not _sim.has_method("start_continuous_transient") or not _sim.has_method("stop_continuous_transient"):
		_set_error("CircuitSimulator build does not expose continuous transient methods.")
		return

	if bool(_sim.call("is_continuous_transient_running")):
		_sim.call("stop_continuous_transient")
		if _sim.has_method("clear_continuous_memory_buffer"):
			_sim.call("clear_continuous_memory_buffer")
		_using_memory_buffer = false
		_refresh_status("native: stopping continuous transient…", StatusTone.WARN)
		return

	# Ensure a deck is loaded before starting continuous streaming.
	_on_run_pressed()
	if _sim == null:
		return

	if bool(_sim.call("is_continuous_transient_running")):
		return
	_configure_stream_output_if_enabled()
	var started: bool = bool(_sim.call("start_continuous_transient", continuous_step, continuous_window, continuous_sleep_ms))
	if not started:
		_set_error("Failed to start continuous transient loop.")

# Updates UI after one-shot simulation completion.
func _on_sim_finished() -> void:
	_refresh_status("native: simulation_finished", StatusTone.OK)
	_log("[color=lime]Simulation finished.[/color]")

# Defers continuous-start UI updates to the main thread.
func _on_continuous_started() -> void:
	call_deferred("_apply_continuous_started_ui")

# Defers continuous-stop UI updates to the main thread.
func _on_continuous_stopped() -> void:
	call_deferred("_apply_continuous_stopped_ui")

# Defers per-frame continuous UI updates to the main thread.
func _on_continuous_frame(frame: Dictionary) -> void:
	call_deferred("_apply_continuous_frame_ui", frame)

# Applies UI state when continuous mode starts.
func _apply_continuous_started_ui() -> void:
	_continuous_frame_count = 0
	if continuous_button != null:
		continuous_button.text = "Stop Continuous"
	_refresh_status("native: continuous transient running", StatusTone.OK)
	_log("[color=lime]Continuous transient started.[/color]")

# Applies UI state when continuous mode stops.
func _apply_continuous_stopped_ui() -> void:
	if continuous_button != null:
		continuous_button.text = "Start Continuous"
	_refresh_status("native: continuous transient stopped", StatusTone.WARN)
	_log("[color=yellow]Continuous transient stopped.[/color]")

# Updates status text periodically while streaming callback-driven frames.
func _apply_continuous_frame_ui(frame: Dictionary) -> void:
	_continuous_frame_count += 1
	if _continuous_frame_count % 10 != 0:
		return

	var sample_count: int = int(frame.get("sample_count", 0))
	var sim_time: float = float(frame.get("time", 0.0))
	var memory_count: int = -1
	if _using_memory_buffer and _sim != null and _sim.has_method("get_continuous_memory_sample_count"):
		memory_count = int(_sim.call("get_continuous_memory_sample_count"))
	var suffix: String = ""
	if memory_count >= 0:
		suffix = " | RAM samples: %d" % memory_count
	_refresh_status(
		"native: continuous stream frame %d (samples=%d, t=%.3e s)%s" % [_continuous_frame_count, sample_count, sim_time, suffix],
		StatusTone.OK
	)

# -------------------------------------------------------------------
# Workspace save/load (ZIP)
# -------------------------------------------------------------------

func _on_save_workspace_pressed() -> void:
	if staged.is_empty():
		_set_error("Nothing to save: stage at least one file first.")
		return

	if OS.has_feature("web"):
		_save_workspace_zip_web_download()
		return

	_ws_mode = "save"
	if workspace_dialog != null:
		workspace_dialog.access = FileDialog.ACCESS_FILESYSTEM
		workspace_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		workspace_dialog.use_native_dialog = true
		workspace_dialog.clear_filters()
		workspace_dialog.add_filter("*%s ; Circuit Visualizer Workspace" % WORKSPACE_EXT)
		workspace_dialog.current_file = "workspace%s" % WORKSPACE_EXT
		workspace_dialog.popup_centered_ratio(0.8)
		_refresh_status("choose workspace save location…", StatusTone.WARN)
	else:
		_set_error("WorkspaceDialog node not found in scene.")

func _on_load_workspace_pressed() -> void:
	if OS.has_feature("web"):
		var ok: bool = _web_eval_bool("typeof window.godotUploadOpenPicker === 'function'")
		if not ok:
			_set_error("Web picker not available.")
			return
		JavaScriptBridge.eval("window.godotUploadOpenPicker()", true)
		_refresh_status("web: choose a workspace zip to load…", StatusTone.WARN)
		return

	_ws_mode = "load"
	if workspace_dialog != null:
		workspace_dialog.access = FileDialog.ACCESS_FILESYSTEM
		workspace_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		workspace_dialog.use_native_dialog = true
		workspace_dialog.clear_filters()
		workspace_dialog.add_filter("*%s ; Circuit Visualizer Workspace" % WORKSPACE_EXT)
		workspace_dialog.add_filter("*.zip ; ZIP files")
		workspace_dialog.popup_centered_ratio(0.8)
		_refresh_status("choose workspace file to load…", StatusTone.WARN)
	else:
		_set_error("WorkspaceDialog node not found in scene.")

func _on_workspace_dialog_file_selected(path: String) -> void:
	if path.strip_edges() == "":
		return
	if _ws_mode == "save":
		_save_workspace_zip_to_path(path)
	elif _ws_mode == "load":
		_load_workspace_zip_from_path(path)

func _save_workspace_zip_web_download() -> void:
	_ensure_upload_dir()

	var tmp_name := "workspace_%d%s" % [int(Time.get_unix_time_from_system()), WORKSPACE_EXT]
	var tmp_path := "user://%s" % tmp_name

	var ok := _save_workspace_zip_to_user_path(tmp_path)
	if not ok:
		return

	var fa := FileAccess.open(tmp_path, FileAccess.READ)
	if fa == null:
		_set_error("Failed to open generated workspace for download.")
		return
	var buf: PackedByteArray = fa.get_buffer(fa.get_length())
	fa.close()

	JavaScriptBridge.download_buffer(buf, "workspace%s" % WORKSPACE_EXT, "application/zip")
	_refresh_status("web: workspace downloaded", StatusTone.OK)
	_log("[color=lime]Workspace download started.[/color]")

func _save_workspace_zip_to_path(path: String) -> void:
	var zip_path := path
	if not zip_path.to_lower().ends_with(WORKSPACE_EXT):
		zip_path += WORKSPACE_EXT

	var ok := _save_workspace_zip_to_filesystem_path(zip_path)
	if ok:
		_refresh_status("workspace saved: %s" % zip_path.get_file(), StatusTone.OK)
		_log("[color=lime]Saved workspace %s[/color]" % zip_path)

func _save_workspace_zip_to_filesystem_path(zip_abs_path: String) -> bool:
	var writer := ZIPPacker.new()
	var err := writer.open(zip_abs_path, ZIPPacker.APPEND_CREATE)
	if err != OK:
		_set_error("Could not create zip: %s (err=%s)" % [zip_abs_path, str(err)])
		return false

	var manifest := _build_workspace_manifest_for_zip()

	err = writer.start_file(WORKSPACE_MANIFEST)
	if err != OK:
		writer.close()
		_set_error("Zip start_file(manifest) failed (err=%s)" % str(err))
		return false
	err = writer.write_file(JSON.stringify(manifest, "\t").to_utf8_buffer())
	if err != OK:
		writer.close_file()
		writer.close()
		_set_error("Zip write_file(manifest) failed (err=%s)" % str(err))
		return false
	writer.close_file()

	for it in (manifest.get("items", []) as Array):
		if typeof(it) != TYPE_DICTIONARY:
			continue
		var item := it as Dictionary
		var user_path := str(item.get("user_path", ""))
		var zip_rel := str(item.get("zip_path", ""))

		var fa := FileAccess.open(user_path, FileAccess.READ)
		if fa == null:
			writer.close()
			_set_error("Could not open staged file for zipping: %s" % user_path)
			return false
		var buf := fa.get_buffer(fa.get_length())
		fa.close()

		err = writer.start_file(zip_rel)
		if err != OK:
			writer.close()
			_set_error("Zip start_file(%s) failed (err=%s)" % [zip_rel, str(err)])
			return false
		err = writer.write_file(buf)
		if err != OK:
			writer.close_file()
			writer.close()
			_set_error("Zip write_file(%s) failed (err=%s)" % [zip_rel, str(err)])
			return false
		writer.close_file()

	writer.close()
	return true

func _save_workspace_zip_to_user_path(zip_user_path: String) -> bool:
	var writer := ZIPPacker.new()
	var err := writer.open(zip_user_path, ZIPPacker.APPEND_CREATE)
	if err != OK:
		_set_error("Could not create zip in user storage: %s (err=%s)" % [zip_user_path, str(err)])
		return false

	var manifest := _build_workspace_manifest_for_zip()

	err = writer.start_file(WORKSPACE_MANIFEST)
	if err != OK:
		writer.close()
		_set_error("Zip start_file(manifest) failed (err=%s)" % str(err))
		return false
	err = writer.write_file(JSON.stringify(manifest, "\t").to_utf8_buffer())
	if err != OK:
		writer.close_file()
		writer.close()
		_set_error("Zip write_file(manifest) failed (err=%s)" % str(err))
		return false
	writer.close_file()

	for it in (manifest.get("items", []) as Array):
		if typeof(it) != TYPE_DICTIONARY:
			continue
		var item := it as Dictionary
		var user_path := str(item.get("user_path", ""))
		var zip_rel := str(item.get("zip_path", ""))

		var fa := FileAccess.open(user_path, FileAccess.READ)
		if fa == null:
			writer.close()
			_set_error("Could not open staged file for zipping: %s" % user_path)
			return false
		var buf := fa.get_buffer(fa.get_length())
		fa.close()

		err = writer.start_file(zip_rel)
		if err != OK:
			writer.close()
			_set_error("Zip start_file(%s) failed (err=%s)" % [zip_rel, str(err)])
			return false
		err = writer.write_file(buf)
		if err != OK:
			writer.close_file()
			writer.close()
			_set_error("Zip write_file(%s) failed (err=%s)" % [zip_rel, str(err)])
			return false
		writer.close_file()

	writer.close()
	return true

func _build_workspace_manifest_for_zip() -> Dictionary:
	var used: Dictionary = {}
	var items: Array = []

	for e: Dictionary in staged:
		var display: String = str(e.get("display", "file.bin"))
		var user_path: String = str(e.get("user_path", ""))

		var zip_name := _sanitize_filename(display)
		if zip_name == "":
			zip_name = "file.bin"
		zip_name = _unique_name(zip_name, used)
		used[zip_name] = true

		items.append({
			"name": display,
			"zip_path": WORKSPACE_FILES_DIR + zip_name,
			"user_path": user_path,
			"bytes": int(e.get("bytes", 0)),
			"kind": str(e.get("kind", "unknown")),
			"ext": str(e.get("ext", ""))
		})

	return {
		"format": "circuit-visualizer-workspace-zip",
		"version": 1,
		"created_unix": int(Time.get_unix_time_from_system()),
		"items": items
	}

func _unique_name(name: String, used: Dictionary) -> String:
	if not used.has(name):
		return name
	var base := name.get_basename()
	var ext := name.get_extension()
	var i := 2
	while true:
		var candidate := ""
		if ext == "":
			candidate = "%s_%d" % [base, i]
		else:
			candidate = "%s_%d.%s" % [base, i, ext]
		if not used.has(candidate):
			return candidate
		i += 1
	return name

func _load_workspace_zip_from_path(path: String) -> void:
	var zip_path := path
	if not (zip_path.to_lower().ends_with(".zip") or zip_path.to_lower().ends_with(WORKSPACE_EXT)):
		_set_error("Not a zip file: %s" % zip_path)
		return

	var reader := ZIPReader.new()
	var err := reader.open(zip_path)
	if err != OK:
		_set_error("Could not open workspace zip (err=%s)" % str(err))
		return

	var manifest_bytes := reader.read_file(WORKSPACE_MANIFEST)
	if manifest_bytes.is_empty():
		reader.close()
		_set_error("Workspace zip missing %s" % WORKSPACE_MANIFEST)
		return

	var manifest_text := manifest_bytes.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(manifest_text)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		reader.close()
		_set_error("Workspace manifest is not valid JSON.")
		return

	var m := parsed as Dictionary
	if str(m.get("format", "")) != "circuit-visualizer-workspace-zip":
		reader.close()
		_set_error("Not a circuit-visualizer workspace zip.")
		return

	var items_var: Variant = m.get("items", [])
	if typeof(items_var) != TYPE_ARRAY:
		reader.close()
		_set_error("Workspace manifest missing items[].")
		return

	_on_clear_pressed()
	_ensure_upload_dir()

	var added := 0
	for it_var in (items_var as Array):
		if typeof(it_var) != TYPE_DICTIONARY:
			continue
		var it := it_var as Dictionary
		var name := str(it.get("name", "file.bin"))
		var zip_rel := str(it.get("zip_path", ""))

		if zip_rel == "":
			continue

		var buf := reader.read_file(zip_rel)
		if buf.is_empty():
			_log("[color=yellow]Warning: missing file inside zip: %s[/color]" % zip_rel)
			continue

		if _stage_bytes(name, buf):
			added += 1

	reader.close()
	_refresh_status("workspace loaded: %d file(s)" % added, StatusTone.OK)
	_log("[color=lime]Loaded workspace (%d files).[/color]" % added)

func _load_workspace_zip_from_bytes(bytes: PackedByteArray) -> bool:
	var tmp_path := "user://incoming_workspace_%d%s" % [int(Time.get_unix_time_from_system()), WORKSPACE_EXT]

	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		_set_error("Failed to write workspace zip into user storage.")
		return false
	f.store_buffer(bytes)
	f.close()

	_load_workspace_zip_from_path(tmp_path)
	return true

# -------------------------------------------------------------------
# Clear staging
# -------------------------------------------------------------------

# Clears staged files, output logs, and continuous state.
func _on_clear_pressed() -> void:
	if _sim != null and _sim.has_method("is_continuous_transient_running") and bool(_sim.call("is_continuous_transient_running")):
		_sim.call("stop_continuous_transient")
	if _sim != null and _sim.has_method("clear_continuous_memory_buffer"):
		_sim.call("clear_continuous_memory_buffer")
	_using_memory_buffer = false
	staged.clear()
	if staged_list != null:
		staged_list.clear()
	if output_box != null:
		output_box.clear()
	if run_button != null:
		run_button.text = "Run Once"
	if continuous_button != null:
		continuous_button.text = "Start Continuous"
	_refresh_status("staging cleared", StatusTone.WARN)

# Configures callback-driven in-memory buffering for continuous streaming.
func _configure_stream_output_if_enabled() -> void:
	_using_memory_buffer = _configure_memory_buffer_if_enabled()
	if not _using_memory_buffer:
		_set_error("RAM sample buffer configuration failed.")

# Configures callback-driven sample buffering in native RAM.
func _configure_memory_buffer_if_enabled() -> bool:
	if _sim == null or not _sim.has_method("configure_continuous_memory_buffer"):
		_set_error("CircuitSimulator build does not expose configure_continuous_memory_buffer().")
		return false

	var max_samples: int = maxi(1, continuous_memory_max_samples)
	var ok: bool = bool(_sim.call("configure_continuous_memory_buffer", continuous_memory_signals, max_samples))
	if not ok:
		_set_error("Failed to configure RAM sample buffer.")
		return false

	_log("[color=lightblue]RAM sample buffer:[/color] max=%d, pop_batch=%d" % [max_samples, maxi(1, continuous_memory_pop_count)])
	return true

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------

# Resolves the simulator node from configured path or scene search.
func _resolve_simulator() -> Node:
	if simulator_path != NodePath("") and has_node(simulator_path):
		var n0: Node = get_node(simulator_path)
		if n0 != null and n0.has_method("initialize_ngspice"):
			return n0

	var cur: Node = self
	while cur != null:
		if cur.has_method("initialize_ngspice") and cur.has_method("load_netlist"):
			return cur
		cur = cur.get_parent()

	var root: Window = get_tree().root
	if root != null:
		var candidates: Array = root.find_children("*", "", true, false)
		for c in candidates:
			if c is Node and (c as Node).has_method("initialize_ngspice") and (c as Node).has_method("load_netlist"):
				return c as Node

	return null

# Ensures user://uploads exists before staging files.
func _ensure_upload_dir() -> void:
	var abs_path: String = ProjectSettings.globalize_path(UPLOAD_DIR)
	DirAccess.make_dir_recursive_absolute(abs_path)

# Removes path-unsafe characters from upload filenames.
func _sanitize_filename(filename: String) -> String:
	var s: String = filename.strip_edges()
	s = s.replace("\\", "_").replace("/", "_").replace(":", "_")
	s = s.replace("*", "_").replace("?", "_").replace("\"", "_").replace("<", "_").replace(">", "_").replace("|", "_")
	if s == "":
		s = "upload.bin"
	return s

# Avoids filename collisions in the upload directory.
func _avoid_collision(user_path: String) -> String:
	if not FileAccess.file_exists(user_path):
		return user_path

	var base: String = user_path.get_basename()
	var ext: String = user_path.get_extension()
	var stamp: int = int(Time.get_unix_time_from_system())
	return "%s_%d.%s" % [base, stamp, ext]

# Normalizes native/file:// paths from pickers and drag-drop.
func _normalize_native_path(raw_path: String) -> String:
	var s: String = raw_path.strip_edges()
	if s.is_empty():
		return ""
	if s.to_lower() == "null":
		return ""
	if s.begins_with("file://"):
		s = s.trim_prefix("file://")
		if s.begins_with("localhost/"):
			s = s.trim_prefix("localhost/")
		if s.length() >= 3 and s.begins_with("/") and s.substr(2, 1) == ":":
			# Windows URI like /C:/...
			s = s.substr(1)
		s = s.uri_decode()
	return s

# Classifies staged content as netlist/xschem/unknown.
func _detect_kind(ext: String, bytes: PackedByteArray) -> String:
	if XSCHEM_EXTS.has(ext):
		return "xschem (.sch/.sym)"
	if NETLIST_EXTS.has(ext):
		var head: String = _bytes_head_as_text(bytes, 120).strip_edges()
		if head.begins_with(".") or head.begins_with("*") or head.find("ngspice") != -1:
			return "netlist"
		return "netlist/text"
	return "unknown"

# Returns whether a staged entry is a runnable netlist.
func _is_netlist_entry(entry: Dictionary) -> bool:
	return entry.has("ext") and NETLIST_EXTS.has(str(entry["ext"]))

# Returns whether a staged entry is an xschem schematic for visualization.
func _is_schematic_entry(entry: Dictionary) -> bool:
	return entry.has("ext") and XSCHEM_EXTS.has(str(entry["ext"]))


# Finds a staged .sch entry whose base name matches the given netlist entry.
# e.g. "sky130_fd_sc_hd__a2bb2o_1.spice" pairs with "sky130_fd_sc_hd__a2bb2o_1.sch".
func _find_matching_sch(netlist_entry: Dictionary) -> Dictionary:
	var spice_base: String = str(netlist_entry.get("display", "")).get_basename().to_lower()
	for e: Dictionary in staged:
		if _is_schematic_entry(e):
			if str(e.get("display", "")).get_basename().to_lower() == spice_base:
				return e
	return {}

# Reads the first N bytes as UTF-8 text for lightweight sniffing.
func _bytes_head_as_text(bytes: PackedByteArray, n: int) -> String:
	var slice: PackedByteArray = bytes.slice(0, min(n, bytes.size()))
	return slice.get_string_from_utf8()

# Rebuilds the visible staged-file list from internal state.
func _rebuild_list() -> void:
	if staged_list == null:
		return
	staged_list.clear()
	for e in staged:
		var label: String = "%s    (%s, %s)    → %s" % [
			str(e["display"]),
			str(e["kind"]),
			_human_size(int(e["bytes"])),
			str(e["user_path"])
		]
		staged_list.add_item(label)

# Formats byte counts for status/list display.
func _human_size(n: int) -> String:
	if n < 1024:
		return "%d B" % n
	if n < 1024 * 1024:
		return "%.1f KB" % (float(n) / 1024.0)
	return "%.2f MB" % (float(n) / (1024.0 * 1024.0))

# Updates status message and tone colors.
func _refresh_status(msg: String, tone: StatusTone = StatusTone.IDLE) -> void:
	if status_prefix == null or status_value == null:
		return

	status_prefix.text = "Status:"
	status_prefix.add_theme_color_override("font_color", Color(1, 1, 1, 1))

	status_value.text = msg

	var c: Color
	match tone:
		StatusTone.OK:
			c = Color(0.25, 0.85, 0.45) # green
		StatusTone.WARN:
			c = Color(1.00, 0.70, 0.20) # orange
		StatusTone.ERROR:
			c = Color(1.00, 0.30, 0.30) # red
		_:
			c = Color(0.85, 0.85, 0.85) # light gray idle

	status_value.add_theme_color_override("font_color", c)

# Marks an error state and appends a formatted log entry.
func _set_error(msg: String) -> void:
	var text: String = msg.strip_edges()
	if text.is_empty():
		text = "Unknown error. Check the output log for details."
	_refresh_status(text, StatusTone.ERROR)
	_log("[color=tomato][b]Error:[/b][/color] %s" % text)

# Appends rich-text output to the panel log box.
func _log(bb: String) -> void:
	if output_box != null:
		output_box.append_text(bb + "\n")
		output_box.scroll_to_line(output_box.get_line_count())
	else:
		print_rich(bb)

# -------------------------------------------------------------------
# Styling: light "Microsoft-esque" theme + drop flash
# -------------------------------------------------------------------

# Builds and applies the panel's light custom theme.
func _apply_light_theme() -> void:
	_t = Theme.new()

	var bg: Color = Color(1, 1, 1)
	var panel: Color = Color(0.98, 0.98, 0.98)
	var border: Color = Color(0.82, 0.82, 0.82)
	var text: Color = Color(0.13, 0.13, 0.13)
	var subtext: Color = Color(0.35, 0.35, 0.35)
	var accent: Color = Color(0.00, 0.47, 0.83)
	var accent_hover: Color = Color(0.00, 0.40, 0.72)

	_sb_panel = StyleBoxFlat.new()
	_sb_panel.bg_color = panel
	_sb_panel.border_color = border
	_sb_panel.border_width_left = 1
	_sb_panel.border_width_top = 1
	_sb_panel.border_width_right = 1
	_sb_panel.border_width_bottom = 1
	_sb_panel.corner_radius_top_left = 10
	_sb_panel.corner_radius_top_right = 10
	_sb_panel.corner_radius_bottom_left = 10
	_sb_panel.corner_radius_bottom_right = 10
	_sb_panel.content_margin_left = 10
	_sb_panel.content_margin_right = 10
	_sb_panel.content_margin_top = 10
	_sb_panel.content_margin_bottom = 10

	_sb_panel_hover = _sb_panel.duplicate() as StyleBoxFlat
	_sb_panel_hover.border_color = Color(0.70, 0.70, 0.70)

	_sb_drop_idle = _sb_panel.duplicate() as StyleBoxFlat
	_sb_drop_idle.bg_color = Color(0.985, 0.985, 0.985)

	_sb_drop_flash = _sb_panel.duplicate() as StyleBoxFlat
	_sb_drop_flash.bg_color = Color(0.93, 0.97, 1.0)
	_sb_drop_flash.border_color = Color(0.35, 0.62, 0.90)

	var sb_root: StyleBoxFlat = StyleBoxFlat.new()
	sb_root.bg_color = bg
	add_theme_stylebox_override("panel", sb_root)

	_t.set_color("font_color", "Label", text)
	_t.set_color("font_color", "RichTextLabel", text)
	_t.set_color("font_color", "LineEdit", text)
	_t.set_color("font_color", "ItemList", text)

	drop_hint.add_theme_color_override("font_color", subtext)

	var sb_btn: StyleBoxFlat = StyleBoxFlat.new()
	sb_btn.bg_color = accent
	sb_btn.border_color = accent
	sb_btn.corner_radius_top_left = 8
	sb_btn.corner_radius_top_right = 8
	sb_btn.corner_radius_bottom_left = 8
	sb_btn.corner_radius_bottom_right = 8
	sb_btn.content_margin_left = 12
	sb_btn.content_margin_right = 12
	sb_btn.content_margin_top = 8
	sb_btn.content_margin_bottom = 8

	var sb_btn_hover: StyleBoxFlat = sb_btn.duplicate() as StyleBoxFlat
	sb_btn_hover.bg_color = accent_hover
	sb_btn_hover.border_color = accent_hover

	var sb_btn_pressed: StyleBoxFlat = sb_btn.duplicate() as StyleBoxFlat
	sb_btn_pressed.bg_color = Color(0.00, 0.34, 0.62)
	sb_btn_pressed.border_color = sb_btn_pressed.bg_color

	_t.set_stylebox("normal", "Button", sb_btn)
	_t.set_stylebox("hover", "Button", sb_btn_hover)
	_t.set_stylebox("pressed", "Button", sb_btn_pressed)
	_t.set_stylebox("focus", "Button", sb_btn_hover)
	_t.set_color("font_color", "Button", Color(1, 1, 1))

	var sb_edit: StyleBoxFlat = _sb_panel.duplicate() as StyleBoxFlat
	sb_edit.bg_color = Color(1, 1, 1)
	sb_edit.corner_radius_top_left = 8
	sb_edit.corner_radius_top_right = 8
	sb_edit.corner_radius_bottom_left = 8
	sb_edit.corner_radius_bottom_right = 8
	_t.set_stylebox("normal", "LineEdit", sb_edit)
	_t.set_stylebox("focus", "LineEdit", _sb_panel_hover)

	var sb_list: StyleBoxFlat = _sb_panel.duplicate() as StyleBoxFlat
	sb_list.bg_color = Color(1, 1, 1)
	_t.set_stylebox("panel", "ItemList", sb_list)
	_t.set_stylebox("normal", "RichTextLabel", sb_list)

	var sb_item_hover: StyleBoxFlat = StyleBoxFlat.new()
	sb_item_hover.bg_color = Color(0.25, 0.25, 0.25, 0.55)
	sb_item_hover.corner_radius_top_left = 6
	sb_item_hover.corner_radius_top_right = 6
	sb_item_hover.corner_radius_bottom_left = 6
	sb_item_hover.corner_radius_bottom_right = 6
	sb_item_hover.content_margin_left = 6
	sb_item_hover.content_margin_right = 6
	sb_item_hover.content_margin_top = 2
	sb_item_hover.content_margin_bottom = 2

	var sb_item_selected: StyleBoxFlat = sb_item_hover.duplicate() as StyleBoxFlat
	sb_item_selected.bg_color = Color(0.20, 0.75, 0.35, 0.90)

	var sb_item_hover_selected: StyleBoxFlat = sb_item_selected.duplicate() as StyleBoxFlat
	sb_item_hover_selected.bg_color = Color(0.16, 0.68, 0.31, 0.95)

	_t.set_stylebox("hovered", "ItemList", sb_item_hover)
	_t.set_stylebox("selected", "ItemList", sb_item_selected)
	_t.set_stylebox("selected_focus", "ItemList", sb_item_selected)
	_t.set_stylebox("hovered_selected", "ItemList", sb_item_hover_selected)
	_t.set_stylebox("hovered_selected_focus", "ItemList", sb_item_hover_selected)

	_t.set_color("font_color", "ItemList", Color(0.13, 0.13, 0.13))
	_t.set_color("font_hovered_color", "ItemList", Color(1, 1, 1))
	_t.set_color("font_selected_color", "ItemList", Color(1, 1, 1))
	_t.set_color("font_hovered_selected_color", "ItemList", Color(1, 1, 1))

	_t.set_stylebox("panel", "PanelContainer", _sb_panel)

	theme = _t
	drop_zone.add_theme_stylebox_override("panel", _sb_drop_idle)

	if status_bar != null:
		_sb_status_bar = StyleBoxFlat.new()
		_sb_status_bar.bg_color = Color(0.10, 0.10, 0.10, 0.90)
		_sb_status_bar.corner_radius_top_left = 8
		_sb_status_bar.corner_radius_top_right = 8
		_sb_status_bar.corner_radius_bottom_left = 8
		_sb_status_bar.corner_radius_bottom_right = 8
		_sb_status_bar.content_margin_left = 10
		_sb_status_bar.content_margin_right = 10
		_sb_status_bar.content_margin_top = 6
		_sb_status_bar.content_margin_bottom = 6
		status_bar.add_theme_stylebox_override("panel", _sb_status_bar)

# Temporarily highlights the drop zone after successful staging.
func _flash_drop_zone() -> void:
	drop_zone.add_theme_stylebox_override("panel", _sb_drop_flash)
	drop_title.text = "Dropped, staging…"
	await get_tree().create_timer(0.35).timeout
	drop_zone.add_theme_stylebox_override("panel", _sb_drop_idle)
	drop_title.text = "Drop files here"


# Extracts [step, stop] from the first .tran command in a SPICE file.
# Searches both inside .control blocks (bare "tran") and outside (".tran").
func _extract_tran_params(path: String) -> Array:
	var text: String = FileAccess.get_file_as_string(path)
	if text.is_empty():
		return []
	var in_control: bool = false
	for raw_line in text.split("\n"):
		var line: String = raw_line.strip_edges().to_lower()
		if line.begins_with(".control"):
			in_control = true
			continue
		if line.begins_with(".endc"):
			in_control = false
			continue
		var is_tran: bool = (in_control and line.begins_with("tran ")) \
						 or (not in_control and line.begins_with(".tran "))
		if is_tran:
			var parts: PackedStringArray = line.split(" ", false)
			if parts.size() >= 3:
				var step: float = _parse_spice_value(parts[1])
				var stop: float = _parse_spice_value(parts[2])
				if step > 0.0 and stop > 0.0:
					return [step, stop]
	return []


# Parses a SPICE numeric value with suffix: "10ns"→1e-8, "1.2e-06"→1.2e-6, "100n"→1e-7.
func _parse_spice_value(s: String) -> float:
	var lower: String = s.to_lower().strip_edges()
	# Strip trailing 's' only when preceded by a unit letter (ns, us, ps, fs)
	if lower.length() > 1 and lower.ends_with("s"):
		var prev: String = lower.substr(lower.length() - 2, 1)
		if prev in ["n", "u", "p", "f", "m"]:
			lower = lower.left(lower.length() - 1)
	var suffixes: Dictionary = {
		"meg": 1e6, "t": 1e12, "g": 1e9, "k": 1e3,
		"m": 1e-3, "u": 1e-6, "n": 1e-9, "p": 1e-12, "f": 1e-15
	}
	for suffix: String in ["meg", "t", "g", "k", "u", "n", "p", "f", "m"]:
		if lower.ends_with(suffix):
			var num: float = float(lower.left(lower.length() - suffix.length()))
			if num != 0.0:
				return num * float(suffixes[suffix])
	return float(lower)


# Returns {name, ports} if the file is a bare subcircuit definition with no top-level
# analysis commands (.tran/.ac/.dc/.op). Returns {} for complete decks or non-spice files.
func _parse_subcircuit_info(path: String) -> Dictionary:
	var text: String = FileAccess.get_file_as_string(path)
	if text.is_empty():
		return {}
	var subckt_name: String = ""
	var ports: Array[String] = []
	var found_ends: bool = false
	var has_analysis: bool = false
	for raw_line: String in text.split("\n"):
		var line: String = raw_line.strip_edges().to_lower()
		if line.begins_with(".subckt "):
			var parts: PackedStringArray = raw_line.strip_edges().split(" ", false)
			if parts.size() >= 2:
				subckt_name = parts[1]
				for i: int in range(2, parts.size()):
					ports.append(parts[i])
		elif line.begins_with(".ends"):
			found_ends = true
		elif line.begins_with(".tran") or line.begins_with(".ac") or line.begins_with(".dc") or line.begins_with(".op"):
			has_analysis = true
	if subckt_name != "" and found_ends and not has_analysis:
		return {"name": subckt_name, "ports": ports}
	return {}


# Builds a complete simulatable SPICE deck in memory from a bare subcircuit definition.
# Classifies ports as power rails, clocks, data inputs, or outputs and adds appropriate sources.
func _build_sim_wrapper(os_path: String, subckt_name: String, ports: Array, pdk_root: String) -> String:
	var lines: Array[String] = []
	lines.append("* Auto-simulation wrapper for " + subckt_name)
	var abs_path: String = os_path.replace("\\", "/")
	if pdk_root != "":
		lines.append(".lib \"" + pdk_root.replace("\\", "/") + "/sky130A/libs.tech/combined/sky130.lib.spice\" tt")
	lines.append(".include \"" + abs_path + "\"")
	lines.append(".nodeset all=0.9")
	lines.append("")
	var pwr_high: Array = ["VPWR", "VDD", "VPB"]
	var pwr_low: Array = ["VGND", "GND", "VSS", "VNB"]
	var output_hints: Array = ["Q", "QN", "Z", "Y", "OUT"]
	var inst_line: String = "X_dut"
	for port: String in ports:
		inst_line += " " + port
		var pu: String = port.to_upper()
		if pwr_high.has(pu):
			lines.append("V%s %s 0 1.8" % [port, port])
		elif pwr_low.has(pu):
			lines.append("V%s %s 0 0" % [port, port])
		elif output_hints.has(pu):
			pass  # output — driven by circuit, no source needed
		elif "CLK" in pu or "CK" in pu:
			lines.append("V%s %s 0 PULSE(0 1.8 0 2n 2n 100n 200n)" % [port, port])
		else:
			lines.append("V%s %s 0 PULSE(0 1.8 50n 2n 2n 200n 400n)" % [port, port])
	inst_line += " " + subckt_name
	lines.append("")
	lines.append(inst_line)
	lines.append("")
	lines.append(".tran 2n 1200n")
	lines.append(".end")
	return "\n".join(lines)
