@tool
extends Control
## In-place preview zoom for the provider detail popups — the same
## interaction the editor's EditorZoomWidget uses (theme/stylebox
## previews): the texture fits the frame letterboxed like
## STRETCH_KEEP_ASPECT_CENTERED, the mouse wheel zooms around the
## cursor, left-drag pans once zoomed in, double-click refits.
## EditorZoomWidget itself is C++-internal, so this is its script-side
## equivalent, used as the TextureRect's drop-in replacement.

var texture: Texture2D = null:
	set(v):
		texture = v
		_needs_fit = true
		queue_redraw()

var zoom := 1.0
## Pan offset applied on top of centering, in view pixels.
var offset := Vector2.ZERO

const ZOOM_STEP := 1.25
const ZOOM_MAX := 16.0

var _dragging := false
var _needs_fit := true


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_MOVE
	tooltip_text = "Scroll to zoom · drag to pan · double-click to fit"


func _draw() -> void:
	if _needs_fit and size.x > 0.0 and size.y > 0.0:
		_needs_fit = false
		_fit()
	if texture == null:
		return
	draw_texture_rect(texture, _tex_rect(), false)


## Letterbox-fit the texture into the view — identical result to
## TextureRect.STRETCH_KEEP_ASPECT_CENTERED at zoom = fit.
func _fit() -> void:
	if texture == null or size.x <= 0.0 or size.y <= 0.0:
		return
	var ts := texture.get_size()
	zoom = minf(size.x / ts.x, size.y / ts.y)
	offset = Vector2.ZERO
	queue_redraw()


func _tex_rect() -> Rect2:
	var scaled := texture.get_size() * zoom
	return Rect2(offset + (size - scaled) * 0.5, scaled)


## Zoom by [param factor] keeping the pixel under [param pos] fixed —
## EditorZoomWidget's anchor math.
func _zoom_at(pos: Vector2, factor: float) -> void:
	var nz := clampf(zoom * factor, _fit_zoom(), ZOOM_MAX)
	if nz == zoom:
		return
	var rect := _tex_rect()
	var center := pos - (pos - rect.position) * (nz / zoom)
	var scaled := texture.get_size() * nz
	offset = center - (size - scaled) * 0.5
	zoom = nz
	_clamp_offset()
	queue_redraw()


func _fit_zoom() -> float:
	if texture == null or size.x <= 0.0 or size.y <= 0.0:
		return 1.0
	var ts := texture.get_size()
	return minf(size.x / ts.x, size.y / ts.y)


## The letterbox may never expose area outside the view: after pan/zoom
## the scaled texture must cover (or stay centered inside) the frame.
func _clamp_offset() -> void:
	if texture == null:
		return
	var scaled := texture.get_size() * zoom
	for axis in [Vector2.AXIS_X, Vector2.AXIS_Y]:
		if scaled[axis] <= size[axis]:
			offset[axis] = 0.0
		else:
			# rect.position = offset + (size - scaled)/2 must stay
			# inside [-excess, 0] so no background shows through.
			var excess := scaled[axis] - size[axis]
			offset[axis] = clampf(offset[axis], -excess, 0.0)


func _gui_input(event: InputEvent) -> void:
	if texture == null:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom_at(event.position, ZOOM_STEP)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom_at(event.position, 1.0 / ZOOM_STEP)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.double_click and event.pressed:
				_fit()
			else:
				_dragging = event.pressed
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		offset += event.relative
		_clamp_offset()
		queue_redraw()
		accept_event()
