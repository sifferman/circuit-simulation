class_name AnimControlOverlay
extends CanvasLayer

## In-game overlay panel for live animation speed controls.
##
## Usage:
##   In your scene tree, add a new node of type AnimControlOverlay (this script
##   extends CanvasLayer, so search for that base type and attach this script).
##   It will auto-find the 3DSchVisualizer node by looking for load_schematic().
##   Press [H] to show / hide the panel while the simulation is running.

## Key that toggles the panel visibility.
@export var toggle_key: Key = KEY_H

## Width of the control panel in pixels.
@export var panel_width: float = 300.0

# Reference to the 3DSchVisualizer (resolved at runtime).
var _vis: Node = null
var _panel: PanelContainer = null


func _ready() -> void:
	layer = 20  # renders above the sidebar (which uses layer 10)
	_resolve_visualizer()
	_build_ui()


func _unhandled_key_input(event: InputEvent) -> void:
	var ke := event as InputEventKey
	if ke and ke.pressed and not ke.echo and ke.keycode == toggle_key:
		if _panel != null:
			_panel.visible = not _panel.visible
		get_viewport().set_input_as_handled()


# ---------- UI construction ----------

func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.name = "AnimControlPanel"

	# Semi-transparent dark panel style
	var sb := StyleBoxFlat.new()
	sb.bg_color          = Color(0.07, 0.07, 0.13, 0.90)
	sb.border_color      = Color(0.30, 0.30, 0.55, 0.85)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left   = 14.0
	sb.content_margin_right  = 14.0
	sb.content_margin_top    = 10.0
	sb.content_margin_bottom = 12.0
	_panel.add_theme_stylebox_override("panel", sb)

	# Anchor to bottom-right corner
	_panel.anchor_left   = 1.0
	_panel.anchor_top    = 1.0
	_panel.anchor_right  = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left   = -(panel_width + 12.0)
	_panel.offset_top    = -230.0
	_panel.offset_right  = -12.0
	_panel.offset_bottom = -12.0

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	_panel.add_child(vbox)

	# ── Title row ──────────────────────────────────────────────
	var title_row := HBoxContainer.new()
	vbox.add_child(title_row)

	var title := Label.new()
	title.text = "Animation Controls"
	title.add_theme_color_override("font_color", Color(0.85, 0.85, 1.00))
	title.add_theme_font_size_override("font_size", 13)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)

	var hint := Label.new()
	hint.text = "[H] hide"
	hint.add_theme_color_override("font_color", Color(0.45, 0.45, 0.60))
	hint.add_theme_font_size_override("font_size", 10)
	title_row.add_child(hint)

	var sep := HSeparator.new()
	sep.add_theme_color_override("color", Color(0.28, 0.28, 0.50, 0.70))
	vbox.add_child(sep)

	# ── Sliders ────────────────────────────────────────────────

	# Overall playback loop duration (1 – 60 s).  Higher = slower.
	_add_slider(vbox,
		"Loop duration", "s",
		1.0, 60.0, 0.5,
		_get_vis_float("anim_playback_duration", 5.0),
		func(v: float) -> void: _set_vis("anim_playback_duration", v))

	# How many real seconds the cursor takes to cross one wire (0.2 – 5 s).
	_add_slider(vbox,
		"Cursor traverse", "s",
		0.2, 5.0, 0.1,
		_get_vis_float("cursor_traverse_seconds", 1.5),
		func(v: float) -> void: _set_vis("cursor_traverse_seconds", v))

	# Minimum ΔV/Vmax per sample required to show a cursor (sensitivity).
	_add_slider(vbox,
		"Cursor sensitivity", "ΔV/Vmax",
		0.01, 0.50, 0.01,
		_get_vis_float("dv_anim_threshold", 0.04),
		func(v: float) -> void: _set_vis("dv_anim_threshold", v))

	add_child(_panel)


## Adds a labelled HSlider row to the given VBoxContainer.
func _add_slider(
		parent: VBoxContainer,
		label_text: String,
		unit: String,
		min_v: float, max_v: float, step_v: float, init_v: float,
		on_change: Callable) -> void:

	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	parent.add_child(row)

	# Header: name on the left, live value on the right
	var header := HBoxContainer.new()
	row.add_child(header)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_color_override("font_color", Color(0.75, 0.85, 1.00))
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(lbl)

	var val_lbl := Label.new()
	val_lbl.text = _fmt(init_v, unit)
	val_lbl.add_theme_color_override("font_color", Color(1.00, 0.85, 0.35))
	val_lbl.add_theme_font_size_override("font_size", 11)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val_lbl.custom_minimum_size.x = 80.0
	header.add_child(val_lbl)

	var slider := HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step      = step_v
	slider.value     = init_v
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)

	slider.value_changed.connect(func(v: float) -> void:
		val_lbl.text = _fmt(v, unit)
		on_change.call(v)
	)


# ---------- Helpers ----------

## Formats a value + unit label for the live readout.
func _fmt(v: float, unit: String) -> String:
	if absf(v) >= 100.0:
		return "%d %s" % [int(v), unit]
	elif absf(v) >= 1.0:
		return "%.1f %s" % [v, unit]
	else:
		return "%.2f %s" % [v, unit]


## Finds the 3DSchVisualizer by duck-typing: first node that has load_schematic().
func _resolve_visualizer() -> void:
	if _vis != null:
		return
	for c: Node in get_tree().root.find_children("*", "", true, false):
		if c.has_method("load_schematic"):
			_vis = c
			return
	push_warning("AnimControlOverlay: could not find a node with load_schematic(). " +
		"Make sure the 3DSchVisualizer is in the scene tree before this overlay.")


## Returns a float property from the visualizer, or a default if absent.
func _get_vis_float(prop: String, default_val: float) -> float:
	if _vis != null and prop in _vis:
		return float(_vis.get(prop))
	return default_val


## Sets a property on the visualizer (silently ignores unknown props).
func _set_vis(prop: String, value: float) -> void:
	if _vis != null and prop in _vis:
		_vis.set(prop, value)
