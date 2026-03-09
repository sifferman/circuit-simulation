class_name SidebarPanel extends Control

signal schematic_requested(path: String)
signal spice_paired(path: String)

const UPLOAD_PANEL_SCENE := "res://ui/upload_panel.tscn"
const PANEL_WIDTH: float = 400.0
const BUTTON_WIDTH: float = 32.0
const SLIDE_DURATION: float = 0.25

var _upload_panel: Control = null
var _toggle_button: Button = null
var _panel_visible: bool = true


func _ready() -> void:
	# Set up this container to span the left side of the screen
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 1.0
	offset_right = PANEL_WIDTH + BUTTON_WIDTH + 4.0

	_setup_panel()
	_setup_toggle_button()


func _setup_panel() -> void:
	var packed = load(UPLOAD_PANEL_SCENE)
	if packed == null:
		push_warning("Upload panel scene not found at: " + UPLOAD_PANEL_SCENE)
		return

	_upload_panel = (packed as PackedScene).instantiate()
	_upload_panel.anchor_left = 0.0
	_upload_panel.anchor_top = 0.0
	_upload_panel.anchor_right = 0.0
	_upload_panel.anchor_bottom = 1.0
	_upload_panel.offset_right = PANEL_WIDTH
	add_child(_upload_panel)

	if _upload_panel.has_signal("schematic_requested"):
		_upload_panel.schematic_requested.connect(func(path: String): schematic_requested.emit(path))
	if _upload_panel.has_signal("spice_paired"):
		_upload_panel.spice_paired.connect(func(path: String): spice_paired.emit(path))


func _setup_toggle_button() -> void:
	_toggle_button = Button.new()
	_toggle_button.name = "ToggleSidebar"
	_toggle_button.text = "<"
	_toggle_button.anchor_left = 0.0
	_toggle_button.anchor_top = 0.0
	_toggle_button.anchor_right = 0.0
	_toggle_button.anchor_bottom = 0.0
	_toggle_button.offset_left = PANEL_WIDTH + 2.0
	_toggle_button.offset_top = 8.0
	_toggle_button.offset_right = PANEL_WIDTH + 2.0 + BUTTON_WIDTH
	_toggle_button.offset_bottom = 44.0

	var btn_style = StyleBoxFlat.new()
	btn_style.bg_color = Color(0.15, 0.15, 0.2, 0.85)
	btn_style.corner_radius_top_right = 6
	btn_style.corner_radius_bottom_right = 6
	btn_style.content_margin_left = 4
	btn_style.content_margin_right = 4
	_toggle_button.add_theme_stylebox_override("normal", btn_style)

	var btn_hover = btn_style.duplicate() as StyleBoxFlat
	btn_hover.bg_color = Color(0.25, 0.25, 0.35, 0.9)
	_toggle_button.add_theme_stylebox_override("hover", btn_hover)

	var btn_pressed = btn_style.duplicate() as StyleBoxFlat
	btn_pressed.bg_color = Color(0.1, 0.1, 0.15, 0.9)
	_toggle_button.add_theme_stylebox_override("pressed", btn_pressed)

	_toggle_button.add_theme_color_override("font_color", Color(1, 1, 1))
	_toggle_button.add_theme_font_size_override("font_size", 18)
	_toggle_button.pressed.connect(_on_toggle)
	add_child(_toggle_button)


func _on_toggle() -> void:
	_panel_visible = !_panel_visible

	var tween = create_tween()
	tween.set_ease(Tween.EASE_OUT)
	tween.set_trans(Tween.TRANS_CUBIC)

	if _panel_visible:
		tween.tween_property(self, "offset_left", 0.0, SLIDE_DURATION)
		_toggle_button.text = "<"
	else:
		tween.tween_property(self, "offset_left", -PANEL_WIDTH, SLIDE_DURATION)
		_toggle_button.text = ">"
