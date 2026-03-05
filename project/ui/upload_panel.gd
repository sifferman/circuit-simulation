extends Control

@export var simulator_path: NodePath = NodePath("..")
const UPLOAD_DIR := "user://uploads"

const WORKSPACE_EXT := ".cvw.zip"
const WORKSPACE_MANIFEST := "manifest.json"
const WORKSPACE_FILES_DIR := "files/"

var NETLIST_EXTS: PackedStringArray = PackedStringArray(["spice", "cir", "net", "txt"])
var XSCHEM_EXTS: PackedStringArray = PackedStringArray(["sch", "sym"])

@onready var upload_button: Button = $Margin/VBox/ControlsRow/UploadButton
@onready var run_button: Button = $Margin/VBox/ControlsRow/RunButton
@onready var clear_button: Button = $Margin/VBox/ControlsRow/ClearButton
@onready var save_ws_button: Button = $Margin/VBox/ControlsRow/SaveWorkspaceButton
@onready var load_ws_button: Button = $Margin/VBox/ControlsRow/LoadWorkspaceButton

@onready var staged_list: ItemList = $Margin/VBox/StagedList

@onready var status_bar: PanelContainer = $Margin/VBox/StatusBar
@onready var status_prefix: Label = $Margin/VBox/StatusBar/StatusRow/StatusPrefix
@onready var status_value: Label = $Margin/VBox/StatusBar/StatusRow/StatusValue

@onready var output_box: RichTextLabel = $Margin/VBox/Output
@onready var file_dialog: FileDialog = $FileDialog
@onready var workspace_dialog: FileDialog = $WorkspaceDialog

@onready var drop_zone: PanelContainer = $Margin/VBox/DropZone
@onready var drop_title: Label = $Margin/VBox/DropZone/DropZoneMargin/DropZoneVBox/DropTitle
@onready var drop_hint: Label = $Margin/VBox/DropZone/DropZoneMargin/DropZoneVBox/DropHint

# Each entry:
# { "display": String, "user_path": String, "bytes": int, "kind": String, "ext": String }
var staged: Array[Dictionary] = []

var _sim_signal_connected: bool = false
var _sim: Node = null

# --- Aesthetic theme state (light, “Microsoft-esque”) ---
var _t: Theme = null
var _sb_panel: StyleBoxFlat = null
var _sb_panel_hover: StyleBoxFlat = null
var _sb_drop_idle: StyleBoxFlat = null
var _sb_drop_flash: StyleBoxFlat = null
var _sb_status_bar: StyleBoxFlat = null

enum StatusTone { IDLE, OK, WARN, ERROR }

var _ws_mode: String = "" # "save" or "load"

func _ready() -> void:
	_apply_light_theme()
	_ensure_upload_dir()

	# --- FileDialog setup ---
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	file_dialog.use_native_dialog = true
	file_dialog.clear_filters()
	file_dialog.add_filter("*.spice, *.cir, *.net, *.txt ; Netlists")
	file_dialog.add_filter("*.sch, *.sym ; Xschem schematics/symbols")
	file_dialog.add_filter("* ; All files")

	upload_button.pressed.connect(Callable(self, "_on_upload_pressed"))
	run_button.pressed.connect(Callable(self, "_on_run_pressed"))
	clear_button.pressed.connect(Callable(self, "_on_clear_pressed"))

	save_ws_button.pressed.connect(Callable(self, "_on_save_workspace_pressed"))
	load_ws_button.pressed.connect(Callable(self, "_on_load_workspace_pressed"))

	file_dialog.files_selected.connect(Callable(self, "_on_native_files_selected"))
	file_dialog.file_selected.connect(Callable(self, "_on_native_file_selected"))

	workspace_dialog.file_selected.connect(Callable(self, "_on_workspace_dialog_file_selected"))

	output_box.bbcode_enabled = true
	output_box.default_color = Color(0.10, 0.10, 0.10, 1)

	# OS drag-and-drop signal (best-effort).
	if not OS.has_feature("web"):
		if get_viewport() != null:
			if not get_viewport().files_dropped.is_connected(Callable(self, "_on_os_files_dropped")):
				get_viewport().files_dropped.connect(Callable(self, "_on_os_files_dropped"))

		if Engine.is_editor_hint():
			_log("[color=#666666][b]Note:[/b][/color] [color=#111111]On Windows, OS drag-drop is often captured by the editor. Export and run the .exe to test drag-drop reliably.[/color]")

	_sim = _resolve_simulator()
	_refresh_status("idle", StatusTone.IDLE)

	if OS.has_feature("web"):
		var has_bridge: bool = _web_eval_bool("typeof window.godotUploadOpenPicker === 'function' && Array.isArray(window.godotUploadQueue)")
		if has_bridge:
			_log("[color=lime][b]OK:[/b][/color] [color=#111111]Web upload bridge detected.[/color]")
		else:
			_log("[color=#b56a00][b]Warning:[/b][/color] [color=#111111]Web upload bridge not detected yet. Ensure upload_bridge.js is included in the exported HTML.[/color]")

func _process(_delta: float) -> void:
	if OS.has_feature("web"):
		_poll_web_queue()

# -------------------------------------------------------------------
# Upload flows
# -------------------------------------------------------------------

func _on_upload_pressed() -> void:
	if OS.has_feature("web"):
		var ok: bool = _web_eval_bool("typeof window.godotUploadOpenPicker === 'function'")
		if not ok:
			_set_error("Web picker not available. Did you include upload_bridge.js in the export HTML?")
			return
		JavaScriptBridge.eval("window.godotUploadOpenPicker()", true)
		_refresh_status("web: picker opened", StatusTone.WARN)
	else:
		file_dialog.popup_centered_ratio(0.8)
		_refresh_status("native: file dialog opened", StatusTone.WARN)

func _on_native_file_selected(path: String) -> void:
	if path.strip_edges() == "":
		return
	var ok: bool = _stage_native_file(path)
	if ok:
		_flash_drop_zone()
		_refresh_status("native: staged 1 file", StatusTone.OK)

func _on_native_files_selected(paths: PackedStringArray) -> void:
	if paths.is_empty():
		return
	var added: int = 0
	for p: String in paths:
		if p.strip_edges() == "":
			continue
		added += int(_stage_native_file(p))
	if added > 0:
		_flash_drop_zone()
		_refresh_status("native: staged %d file(s)" % added, StatusTone.OK)
	else:
		_refresh_status("native: no valid files selected", StatusTone.WARN)

func _on_os_files_dropped(files: PackedStringArray) -> void:
	if OS.has_feature("web"):
		return
	if files.is_empty():
		return

	var added: int = 0
	for p: String in files:
		if p.strip_edges() == "":
			continue
		added += int(_stage_native_file(p))

	if added > 0:
		_flash_drop_zone()
		_refresh_status("native: dropped %d file(s)" % added, StatusTone.OK)
	else:
		_refresh_status("native: drop received, no valid files", StatusTone.WARN)

func _stage_native_file(src_path: String) -> bool:
	if not FileAccess.file_exists(src_path):
		_set_error("File does not exist: %s" % src_path)
		return false

	var src: FileAccess = FileAccess.open(src_path, FileAccess.READ)
	if src == null:
		_set_error("Failed to open: %s" % src_path)
		return false

	var bytes: PackedByteArray = src.get_buffer(src.get_length())
	src.close()

	var base_name: String = src_path.get_file()
	return _stage_bytes(base_name, bytes)

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
	_log("[color=#0366fc][b]Info:[/b][/color] [color=#111111]Staged %s  →  %s[/color]" % [safe_name, user_path])
	return true

# -------------------------------------------------------------------
# Web queue polling (JS -> Godot)
# -------------------------------------------------------------------

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

	# If it's a workspace zip, load it instead of staging it.
	if _looks_like_workspace_zip(filename, bytes):
		var ok_ws: bool = _load_workspace_zip_from_bytes(bytes)
		if ok_ws:
			_refresh_status("web: workspace loaded", StatusTone.OK)
		return

	var ok: bool = _stage_bytes(filename, bytes)
	if ok:
		_flash_drop_zone()
		_refresh_status("web: staged %s (%s)" % [filename, _human_size(bytes.size())], StatusTone.OK)

func _looks_like_workspace_zip(filename: String, bytes: PackedByteArray) -> bool:
	var lower := filename.to_lower()
	if not (lower.ends_with(WORKSPACE_EXT) or lower.ends_with(".zip")):
		return false
	# ZIP files start with "PK" (0x50 0x4B)
	if bytes.size() < 2:
		return false
	return int(bytes[0]) == 0x50 and int(bytes[1]) == 0x4B

func _web_eval_bool(expr: String) -> bool:
	var v: Variant = JavaScriptBridge.eval("(%s) ? true : false" % expr, true)
	return bool(v)

# -------------------------------------------------------------------
# Run simulation (native only)
# -------------------------------------------------------------------

func _on_run_pressed() -> void:
	if staged.is_empty():
		_set_error("No staged files. Upload a .spice/.cir/.net/.txt netlist first.")
		return

	var idx: PackedInt32Array = staged_list.get_selected_items()
	if idx.is_empty():
		_set_error("Select a staged netlist in the list first.")
		return

	var entry: Dictionary = staged[int(idx[0])]
	if not _is_netlist_entry(entry):
		_set_error("Selected file is not a netlist type. Choose .spice/.cir/.net/.txt.")
		return

	if OS.has_feature("web"):
		_set_error("Web build: ngspice runtime is not supported yet, staging works though.")
		return

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

	_refresh_status("native: initializing ngspice…", StatusTone.WARN)
	var init_ok: Variant = _sim.call("initialize_ngspice")
	if not bool(init_ok):
		_set_error("initialize_ngspice() returned false.")
		return

	_refresh_status("native: loading netlist…", StatusTone.WARN)
	var godot_path: String = str(entry["user_path"]) # user://uploads/...
	var os_path: String = ProjectSettings.globalize_path(godot_path)
	_sim.call("load_netlist", os_path)

	_refresh_status("native: running simulation…", StatusTone.WARN)
	_sim.call("run_simulation")

func _on_sim_finished() -> void:
	_refresh_status("native: simulation_finished", StatusTone.OK)
	_log("[color=lime][b]OK:[/b][/color] [color=#111111]Simulation finished.[/color]")

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
	workspace_dialog.access = FileDialog.ACCESS_FILESYSTEM
	workspace_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	workspace_dialog.use_native_dialog = true
	workspace_dialog.clear_filters()
	workspace_dialog.add_filter("*%s ; Circuit Visualizer Workspace" % WORKSPACE_EXT)
	workspace_dialog.current_file = "workspace%s" % WORKSPACE_EXT
	workspace_dialog.popup_centered_ratio(0.8)
	_refresh_status("choose workspace save location…", StatusTone.WARN)

func _on_load_workspace_pressed() -> void:
	if OS.has_feature("web"):
		# Web: use the browser picker via your upload bridge
		var ok: bool = _web_eval_bool("typeof window.godotUploadOpenPicker === 'function'")
		if not ok:
			_set_error("Web picker not available.")
			return
		JavaScriptBridge.eval("window.godotUploadOpenPicker()", true)
		_refresh_status("web: choose a workspace zip to load…", StatusTone.WARN)
		return

	_ws_mode = "load"
	workspace_dialog.access = FileDialog.ACCESS_FILESYSTEM
	workspace_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	workspace_dialog.use_native_dialog = true
	workspace_dialog.clear_filters()
	workspace_dialog.add_filter("*%s ; Circuit Visualizer Workspace" % WORKSPACE_EXT)
	workspace_dialog.add_filter("*.zip ; ZIP files")
	workspace_dialog.popup_centered_ratio(0.8)
	_refresh_status("choose workspace file to load…", StatusTone.WARN)

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

	# Prompts browser download (Web export). :contentReference[oaicite:2]{index=2}
	JavaScriptBridge.download_buffer(buf, "workspace%s" % WORKSPACE_EXT, "application/zip")
	_refresh_status("web: workspace downloaded", StatusTone.OK)
	_log("[color=lime][b]OK:[/b][/color] [color=#111111]Workspace download started.[/color]")

func _save_workspace_zip_to_path(path: String) -> void:
	var zip_path := path
	if not zip_path.to_lower().ends_with(WORKSPACE_EXT):
		zip_path += WORKSPACE_EXT

	var ok := _save_workspace_zip_to_filesystem_path(zip_path)
	if ok:
		_refresh_status("workspace saved: %s" % zip_path.get_file(), StatusTone.OK)
		_log("[color=lime][b]OK:[/b][/color] [color=#111111]Saved workspace %s[/color]" % zip_path)

func _save_workspace_zip_to_filesystem_path(zip_abs_path: String) -> bool:
	# We write to the chosen absolute path (filesystem path).
	var writer := ZIPPacker.new()
	var err := writer.open(zip_abs_path, ZIPPacker.APPEND_CREATE)
	if err != OK:
		_set_error("Could not create zip: %s (err=%s)" % [zip_abs_path, str(err)])
		return false

	var manifest := _build_workspace_manifest_for_zip()

	# Write manifest.json
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

	# Write files
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
	# Same as filesystem version, but writes to user:// (works on Web too).
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
	# Produce a manifest that also remembers the user:// source path for each file,
	# and assigns a zip_path under files/ that is collision-free.
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
	if not zip_path.to_lower().ends_with(".zip"):
		_set_error("Not a zip file: %s" % zip_path)
		return

	# ZIPReader reads from a file path (user:// or absolute). :contentReference[oaicite:3]{index=3}
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
			_log("[color=#b56a00][b]Warning:[/b][/color] [color=#111111]Missing file inside zip: %s[/color]" % zip_rel)
			continue

		if _stage_bytes(name, buf):
			added += 1

	reader.close()
	_refresh_status("workspace loaded: %d file(s)" % added, StatusTone.OK)
	_log("[color=lime][b]OK:[/b][/color] [color=#111111]Loaded workspace (%d files).[/color]" % added)

func _load_workspace_zip_from_bytes(bytes: PackedByteArray) -> bool:
	# ZIPReader can't open from memory, so write to a temp user:// file, then open it. :contentReference[oaicite:4]{index=4}
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

func _on_clear_pressed() -> void:
	staged.clear()
	staged_list.clear()
	output_box.clear()
	_refresh_status("staging cleared", StatusTone.WARN)

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------

func _resolve_simulator() -> Node:
	if simulator_path != NodePath("") and has_node(simulator_path):
		var n0: Node = get_node(simulator_path)
		if n0 != null and n0.has_method("initialize_ngspice"):
			return n0

	var cur: Node = self
	while cur != null:
		if cur.has_method("initialize_ngspice") and cur.has_method("load_netlist") and cur.has_method("run_simulation"):
			return cur
		cur = cur.get_parent()

	var root: Window = get_tree().root
	if root != null:
		var candidates: Array = root.find_children("*", "", true, false)
		for c in candidates:
			if c is Node and (c as Node).has_method("initialize_ngspice") and (c as Node).has_method("load_netlist"):
				return c as Node

	return null

func _ensure_upload_dir() -> void:
	var abs_path: String = ProjectSettings.globalize_path(UPLOAD_DIR)
	DirAccess.make_dir_recursive_absolute(abs_path)

func _sanitize_filename(filename: String) -> String:
	var s: String = filename.strip_edges()
	s = s.replace("\\", "_").replace("/", "_").replace(":", "_")
	s = s.replace("*", "_").replace("?", "_").replace("\"", "_").replace("<", "_").replace(">", "_").replace("|", "_")
	if s == "":
		s = "upload.bin"
	return s

func _avoid_collision(user_path: String) -> String:
	if not FileAccess.file_exists(user_path):
		return user_path

	var base: String = user_path.get_basename()
	var ext: String = user_path.get_extension()
	var stamp: int = int(Time.get_unix_time_from_system())
	return "%s_%d.%s" % [base, stamp, ext]

func _detect_kind(ext: String, bytes: PackedByteArray) -> String:
	if XSCHEM_EXTS.has(ext):
		return "xschem (.sch/.sym)"
	if NETLIST_EXTS.has(ext):
		var head: String = _bytes_head_as_text(bytes, 120).strip_edges()
		if head.begins_with(".") or head.begins_with("*") or head.find("ngspice") != -1:
			return "netlist"
		return "netlist/text"
	return "unknown"

func _is_netlist_entry(entry: Dictionary) -> bool:
	return entry.has("ext") and NETLIST_EXTS.has(str(entry["ext"]))

func _bytes_head_as_text(bytes: PackedByteArray, n: int) -> String:
	var slice: PackedByteArray = bytes.slice(0, min(n, bytes.size()))
	return slice.get_string_from_utf8()

func _rebuild_list() -> void:
	staged_list.clear()
	for e in staged:
		var label: String = "%s    (%s, %s)    → %s" % [
			str(e["display"]),
			str(e["kind"]),
			_human_size(int(e["bytes"])),
			str(e["user_path"])
		]
		staged_list.add_item(label)

func _human_size(n: int) -> String:
	if n < 1024:
		return "%d B" % n
	if n < 1024 * 1024:
		return "%.1f KB" % (float(n) / 1024.0)
	return "%.2f MB" % (float(n) / (1024.0 * 1024.0))

func _refresh_status(msg: String, tone: StatusTone = StatusTone.IDLE) -> void:
	status_prefix.text = "Status:"
	status_prefix.add_theme_color_override("font_color", Color(1, 1, 1, 1))

	status_value.text = msg

	var c: Color
	match tone:
		StatusTone.OK:
			c = Color(0.25, 0.85, 0.45)
		StatusTone.WARN:
			c = Color(1.00, 0.70, 0.20)
		StatusTone.ERROR:
			c = Color(1.00, 0.30, 0.30)
		_:
			c = Color(0.90, 0.90, 0.90)

	status_value.add_theme_color_override("font_color", c)

func _set_error(msg: String) -> void:
	_refresh_status("error", StatusTone.ERROR)
	_log("[color=tomato][b]Error:[/b][/color] [color=#111111]%s[/color]" % msg)

func _log(bb: String) -> void:
	output_box.append_text(bb + "\n")
	output_box.scroll_to_line(output_box.get_line_count())

# -------------------------------------------------------------------
# Styling: light “Microsoft-esque” theme + drop flash
# -------------------------------------------------------------------

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

func _flash_drop_zone() -> void:
	drop_zone.add_theme_stylebox_override("panel", _sb_drop_flash)
	drop_title.text = "Dropped, staging…"
	await get_tree().create_timer(0.35).timeout
	drop_zone.add_theme_stylebox_override("panel", _sb_drop_idle)
	drop_title.text = "Drop files here"