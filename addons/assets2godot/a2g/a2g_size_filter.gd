@tool
extends Button
## Thumbnail-size picker for the browser's tile view — same widget shape as
## the gallery's Polygons filter (ui/gallery/polygon_filter.gd): a dropdown
## button showing the current size that opens a slider over preset stops,
## an exact-size field and a Default reset.

signal size_changed(px: int)
## The popup closed, with any typed size applied.
signal closed

const POPUP_WIDTH := 300
const STOPS := [16, 24, 32, 48, 64, 96, 128, 192]
const DEFAULT_SIZE := 64

var size_px := DEFAULT_SIZE

var _popup: PopupPanel
var _slider: SizeSlider
var _edit: LineEdit
var _reset: Button


## Called by the browser with the saved size.
func setup(px: int) -> void:
	var edscale := EditorInterface.get_editor_scale()
	theme_type_variation = "OptionButton"
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	toggle_mode = true
	tooltip_text = "Thumbnail size of the tile view."
	icon = get_theme_icon("GuiOptionArrow", "EditorIcons")

	_popup = PopupPanel.new()
	add_child(_popup)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", int(8 * edscale))
	_popup.add_child(box)
	_slider = SizeSlider.new()
	_slider.custom_minimum_size.x = POPUP_WIDTH * edscale
	_slider.moved.connect(func(pos: int): _apply_size(STOPS[pos]))
	box.add_child(_slider)
	var edits := HBoxContainer.new()
	box.add_child(edits)
	var label := Label.new()
	label.text = "Size"
	edits.add_child(label)
	_edit = LineEdit.new()
	_edit.placeholder_text = str(DEFAULT_SIZE)
	_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edit.tooltip_text = "An exact tile size in pixels."
	_edit.text_submitted.connect(func(_text): _apply_edit())
	_edit.focus_exited.connect(_apply_edit)
	edits.add_child(_edit)
	edits.add_child(VSeparator.new())
	_reset = Button.new()
	_reset.text = "Default"
	_reset.tooltip_text = "Back to the FileSystem dock's %dpx tiles." % DEFAULT_SIZE
	_reset.pressed.connect(func(): _apply_size(DEFAULT_SIZE))
	edits.add_child(_reset)

	_popup.popup_hide.connect(func():
		_apply_edit()
		set_pressed_no_signal(false)
		closed.emit())
	toggled.connect(_on_toggled)
	size_px = clampi(px, STOPS[0], STOPS[STOPS.size() - 1])
	_show()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _popup:
		icon = get_theme_icon("GuiOptionArrow", "EditorIcons")


func _on_toggled(pressed: bool) -> void:
	if not pressed:
		_popup.hide()
		return
	_popup.reset_size()
	var canvas_scale := get_global_transform_with_canvas().get_scale()
	# Below the button like OptionButton, kept within the editor window.
	var pos := get_screen_position() + Vector2(0, size.y * canvas_scale.y)
	var window := get_window()
	pos.x = maxf(window.position.x, minf(pos.x, window.position.x + window.size.x - _popup.size.x))
	_popup.popup(Rect2i(Vector2i(pos), _popup.size))


func _apply_edit() -> void:
	var text := _edit.text.strip_edges()
	if text.is_empty():
		_show()
		return
	if not text.is_valid_int():
		_show()
		return
	_apply_size(clampi(text.to_int(), STOPS[0], STOPS[STOPS.size() - 1]))


func _apply_size(px: int) -> void:
	var changed := px != size_px
	size_px = px
	_show()
	if changed:
		size_changed.emit(px)


func _show() -> void:
	text = "%d px" % size_px
	if _slider:
		_slider.set_pos(_position_of(size_px))
	if _edit:
		_edit.text = str(size_px)


## Slider position for a size: fractional index into STOPS, interpolated
## between stops so typed sizes still land where they belong.
func _position_of(px: int) -> float:
	if px <= STOPS[0]:
		return 0.0
	for i in range(1, STOPS.size()):
		if px <= STOPS[i]:
			var span := float(STOPS[i] - STOPS[i - 1])
			return (i - 1) + (px - STOPS[i - 1]) / span
	return float(STOPS.size() - 1)


## One grabber over the evenly spaced STOPS, labeled below — the single-
## handle sibling of the Polygons filter's RangeSlider.
class SizeSlider extends Control:
	## The grabber was dragged to this STOPS index.
	signal moved(pos: int)

	var pos := 0.0
	var _dragging := false
	var _hovered := false

	func _init() -> void:
		mouse_exited.connect(func():
			_hovered = false
			queue_redraw())

	func set_pos(new_pos: float) -> void:
		pos = clampf(new_pos, 0.0, float(STOPS.size() - 1))
		queue_redraw()

	func _get_minimum_size() -> Vector2:
		var grabber := get_theme_icon("grabber", "HSlider")
		var font := get_theme_font("font", "Label")
		var gap := 4 * EditorInterface.get_editor_scale()
		return Vector2(0, grabber.get_height() + gap + font.get_height(get_theme_font_size("font_size", "Label")))

	## Half of the widest stop label or grabber, so both fit at the ends.
	func _margin() -> float:
		var font := get_theme_font("font", "Label")
		var font_size := get_theme_font_size("font_size", "Label")
		var widest: float = get_theme_icon("grabber", "HSlider").get_width()
		for stop in STOPS:
			widest = maxf(widest, font.get_string_size(str(stop), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
		return ceilf(widest / 2)

	func _x(position: float) -> float:
		var margin := _margin()
		return margin + (size.x - 2 * margin) * position / (STOPS.size() - 1)

	func _stop_at(x: float) -> int:
		var margin := _margin()
		var last := STOPS.size() - 1
		return clampi(roundi((x - margin) / (size.x - 2 * margin) * last), 0, last)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
			if _dragging:
				_drag_to(event.position.x)
			else:
				queue_redraw()
			accept_event()
		elif event is InputEventMouseMotion:
			if _dragging and not event.button_mask & MOUSE_BUTTON_MASK_LEFT:
				_dragging = false
				queue_redraw()
			if _dragging:
				_drag_to(event.position.x)
			else:
				var half := get_theme_icon("grabber", "HSlider").get_width() / 2.0
				var hovered := absf(event.position.x - _x(pos)) <= half
				if hovered != _hovered:
					_hovered = hovered
					queue_redraw()

	func _drag_to(x: float) -> void:
		var stop := _stop_at(x)
		if stop != roundi(pos):
			set_pos(stop)
			moved.emit(stop)

	func _draw() -> void:
		var grabber := get_theme_icon("grabber", "HSlider")
		var highlight := get_theme_icon("grabber_highlight", "HSlider")
		var track := get_theme_stylebox("slider", "HSlider")
		var area := get_theme_stylebox("grabber_area", "HSlider")
		var font := get_theme_font("font", "Label")
		var font_size := get_theme_font_size("font_size", "Label")
		var font_color := get_theme_color("font_color", "Label")
		var dim_color := Color(font_color, font_color.a * 0.5)
		var center_y := grabber.get_height() / 2.0
		var track_height := track.get_minimum_size().y
		var start := _x(0)
		var end := _x(STOPS.size() - 1)
		draw_style_box(track, Rect2(start, center_y - track_height / 2, end - start, track_height))
		draw_style_box(area, Rect2(start, center_y - track_height / 2, _x(pos) - start, track_height))
		var label_y := grabber.get_height() + 4 * EditorInterface.get_editor_scale() + font.get_ascent(font_size)
		for i in STOPS.size():
			var label := str(STOPS[i])
			var width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			var color := font_color if i <= pos + 0.001 else dim_color
			draw_string(font, Vector2(roundf(_x(i) - width / 2), label_y), label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
		var texture := highlight if _dragging or _hovered else grabber
		draw_texture(texture, Vector2(roundf(_x(pos) - texture.get_width() / 2.0), roundf(center_y - texture.get_height() / 2.0)))
