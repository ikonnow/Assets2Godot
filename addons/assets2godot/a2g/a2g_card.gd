@tool
extends Button
## An asset card replicating ui/gallery/gallery_item.tscn's look so the A2G
## surfaces read as one piece with the BlendKit gallery: a square clipped
## thumbnail with rounded top corners, a kind badge at its bottom right,
## the name below, the editor theme's button colors with rounded corners,
## and a border on hover and focus. Shows the editor's type icon while no
## real thumbnail is loaded.

signal activated(payload: Variant)

const CORNER_RADIUS := 8
const TITLE_PADDING := Vector2(10, 6)
const FRAME_WIDTH := 2
const CARD_WIDTH := 220
const STATES := ["normal", "hover", "pressed", "hover_pressed"]

## Kind -> the editor's own class icon, the same visual language the
## FileSystem dock and the BlendKit gallery use.
const TYPE_ICONS := {
	"model": "MeshInstance3D",
	"material": "StandardMaterial3D",
	"texture": "ImageTexture",
	"hdr": "WorldEnvironment",
	"scene_data": "PackedScene",
	"animation": "Animation",
	"ue_asset": "MeshInstance3D",
	"metadata": "TextFile",
	"file": "File",
	"resource": "Object",
}

var payload: Variant
var thumb_clip: Panel
var thumb: TextureRect
var kind_icon: TextureRect
var badge: Label
var title_label: Label
var frame: Panel

var _kind := ""
var _type_name := ""
var _width := 0.0
var _hovered := false
var _updating_theme := false
var _fallback_icon: Texture2D
static var _styles: Dictionary = {}


func _init() -> void:
	thumb_clip = Panel.new()
	thumb_clip.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	thumb_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(thumb_clip)

	thumb = TextureRect.new()
	thumb.set_anchors_preset(Control.PRESET_FULL_RECT)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thumb_clip.add_child(thumb)

	kind_icon = TextureRect.new()
	kind_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	kind_icon.expand_mode = TextureRect.EXPAND_KEEP_SIZE
	kind_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	kind_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thumb_clip.add_child(kind_icon)

	badge = Label.new()
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thumb_clip.add_child(badge)

	title_label = Label.new()
	title_label.clip_text = true
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(title_label)

	frame = Panel.new()
	frame.visible = false
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(frame)


func _ready() -> void:
	if _width == 0.0:
		_width = CARD_WIDTH * EditorInterface.get_editor_scale()
	pressed.connect(func(): activated.emit(payload))
	mouse_entered.connect(_set_hovered.bind(true))
	mouse_exited.connect(_set_hovered.bind(false))
	focus_entered.connect(_update_frame)
	focus_exited.connect(_update_frame)
	_apply_theme()
	_update_size()


func _notification(what: int) -> void:
	if not is_node_ready():
		return
	match what:
		NOTIFICATION_THEME_CHANGED:
			if not _updating_theme:
				_apply_theme()
		NOTIFICATION_RESIZED:
			_layout()


func setup(title: String, kind: String, source: String, path: String, new_payload: Variant, fallback_icon: Texture2D = null, type_name: String = "") -> void:
	payload = new_payload
	_kind = kind
	_type_name = type_name
	_fallback_icon = fallback_icon
	title_label.text = title
	tooltip_text = "%s\n%s · %s\n%s" % [title, kind, source, path]
	badge.text = kind
	if is_node_ready():
		_update_kind_icon()
		_update_size()


func set_thumbnail(texture: Texture2D) -> void:
	thumb.texture = texture
	kind_icon.visible = texture == null


## The theme's look, matching gallery_item.gd: PanelBackgroundButton bases
## with rounded corners and no margins so the thumbnail reaches the edges.
func _apply_theme() -> void:
	_updating_theme = true
	var edscale := EditorInterface.get_editor_scale()
	var key := str(edscale)
	var bases := STATES.map(func(state): return get_theme_stylebox(state, "PanelBackgroundButton"))
	key += " " + " ".join(bases.map(func(b): return str(b.get_instance_id())))
	if _styles.get("key") != key:
		var styles := {"key": key, "focus": StyleBoxEmpty.new()}
		var radius := int(CORNER_RADIUS * edscale)
		for i in STATES.size():
			var box: StyleBoxFlat = bases[i].duplicate() if bases[i] is StyleBoxFlat else StyleBoxFlat.new()
			box.set_corner_radius_all(radius)
			box.set_content_margin_all(0)
			styles[STATES[i]] = box
		var mask := StyleBoxFlat.new()
		mask.bg_color = Color.WHITE
		mask.corner_radius_top_left = radius
		mask.corner_radius_top_right = radius
		styles.mask = mask
		var title_box := StyleBoxEmpty.new()
		title_box.content_margin_left = TITLE_PADDING.x * edscale
		title_box.content_margin_right = TITLE_PADDING.x * edscale
		title_box.content_margin_top = TITLE_PADDING.y * edscale
		title_box.content_margin_bottom = TITLE_PADDING.y * edscale
		styles.title = title_box
		var chip := StyleBoxFlat.new()
		chip.bg_color = Color(0, 0, 0, 0.55)
		chip.set_corner_radius_all(int(4 * edscale))
		chip.content_margin_left = 6 * edscale
		chip.content_margin_right = 6 * edscale
		chip.content_margin_top = 2 * edscale
		chip.content_margin_bottom = 2 * edscale
		styles.chip = chip
		_styles = styles
	for state in STATES:
		add_theme_stylebox_override(state, _styles[state])
	add_theme_stylebox_override("focus", _styles.focus)
	thumb_clip.add_theme_stylebox_override("panel", _styles.mask)
	title_label.add_theme_stylebox_override("normal", _styles.title)
	badge.add_theme_stylebox_override("normal", _styles.chip)
	badge.add_theme_font_size_override("font_size", int(12 * edscale))
	badge.modulate = Color(1, 1, 1, 0.85)
	_update_kind_icon()
	_update_frame()
	_updating_theme = false


## Icon resolution follows Godot's own convention: the resource/file type
## name (EditorFileSystem.get_file_type / Resource.get_class) is an
## EditorIcons name, so FileSystem and A2G show the same icon per type.
func _update_kind_icon() -> void:
	var icon_name := _type_name if _type_name != "" else TYPE_ICONS.get(_kind, "File")
	var icon: Texture2D = null
	if has_theme_icon(icon_name, "EditorIcons"):
		icon = get_theme_icon(icon_name, "EditorIcons")
	elif has_theme_icon(TYPE_ICONS.get(_kind, "File"), "EditorIcons"):
		icon = get_theme_icon(TYPE_ICONS.get(_kind, "File"), "EditorIcons")
	elif _fallback_icon != null:
		icon = _fallback_icon
	kind_icon.texture = icon
	kind_icon.visible = thumb.texture == null and icon != null


func _update_size() -> void:
	custom_minimum_size = Vector2(_width, _width + title_label.get_combined_minimum_size().y)
	_layout()


## The card is as tall as its square thumbnail plus the name below.
func _layout() -> void:
	var edscale := EditorInterface.get_editor_scale()
	var width := size.x
	thumb_clip.position = Vector2.ZERO
	thumb_clip.size = Vector2(width, width)
	title_label.position = Vector2(0, width)
	title_label.size = Vector2(width, size.y - width)
	badge.size = badge.get_combined_minimum_size()
	badge.position = Vector2(width, width) - badge.size - Vector2(6, 6) * edscale
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)


func _set_hovered(hovered: bool) -> void:
	_hovered = hovered
	_update_frame()


## The border goes over the thumbnail, which covers the card's own hover
## and focus look — same as gallery_item.
func _update_frame() -> void:
	frame.visible = has_focus() or _hovered
	if not frame.visible:
		return
	var box := StyleBoxFlat.new()
	box.draw_center = false
	box.set_corner_radius_all(int(CORNER_RADIUS * EditorInterface.get_editor_scale()))
	box.set_border_width_all(maxi(1, int(FRAME_WIDTH * EditorInterface.get_editor_scale())))
	box.border_color = get_theme_color("accent_color", "Editor") if has_focus() \
		else Color(get_theme_color("mono_color", "Editor"), 0.35)
	frame.add_theme_stylebox_override("panel", box)
