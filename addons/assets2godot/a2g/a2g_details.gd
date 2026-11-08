@tool
extends AcceptDialog
## The local-asset detail popup — the indexed/project counterpart of
## a2g_ph_details.gd (which itself mirrors ui/gallery/asset_details):
## framed preview + thumbnail strip on the left, kind + title +
## parameter rows on the right, filesystem actions in the footer.
##
## The host owns state: it passes the index/project entry and the tile's
## own thumbnail; the batch-import dialog opens off import_requested.
## Everything else the popup does itself through the same engine calls
## the context menu uses (navigate_to_path, edit_resource, clipboard,
## shell_show_in_file_manager).

signal import_requested(entries: Array)

const A2GUI = preload("res://addons/assets2godot/a2g/a2g_ui.gd")
const A2GThumbs = preload("res://addons/assets2godot/a2g/a2g_thumbs.gd")
const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

var asset: Dictionary = {}

var _preview: TextureRect
var _frame: PanelContainer
var _strip: HBoxContainer
var _textures := {}
var _shown_type := ""
var _path_text: RichTextLabel
var _kind_label: Label
var _title_label: Label
var _heading: VBoxContainer
var _panes: HBoxContainer
var _right: VBoxContainer
var _params: GridContainer
var _note: Label
## Frame the dialog last opened — _close_if_outside ignores focus churn
## on that same frame (asset_details' guard against instant self-close).
var _shown_frame := -1
var _actions := {}


func _ready() -> void:
	var edscale := EditorInterface.get_editor_scale()
	title = "Asset"
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", int(12 * edscale))
	add_child(content)

	_panes = HBoxContainer.new()
	_panes.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_panes.add_theme_constant_override("separation", int(16 * edscale))
	content.add_child(_panes)

	# Left: framed preview + optional strip (full image next to the tile
	# thumb), the full path as selectable text under it.
	var left := VBoxContainer.new()
	_panes.add_child(left)
	_frame = PanelContainer.new()
	_frame.clip_contents = true
	# No panel override: asset_details' PreviewFrame is a plain
	# PanelContainer — the theme's own dark panel shows through the
	# image's transparent margins, never a white box.
	left.add_child(_frame)
	_preview = TextureRect.new()
	_preview.custom_minimum_size = Vector2.ONE * 400 * edscale
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_frame.add_child(_preview)
	_strip = HBoxContainer.new()
	_strip.alignment = BoxContainer.ALIGNMENT_CENTER
	left.add_child(_strip)
	_path_text = RichTextLabel.new()
	_path_text.fit_content = true
	_path_text.selection_enabled = true
	_path_text.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	_path_text.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_path_text.add_theme_constant_override("line_separation", int(4 * edscale))
	_path_text.add_theme_color_override("default_color", get_theme_color("font_disabled_color", "Editor"))
	left.add_child(_path_text)

	# Right: dimmed kind over the big title, then the param rows.
	_right = VBoxContainer.new()
	_right.custom_minimum_size.x = _preview.custom_minimum_size.x
	_panes.add_child(_right)
	_heading = VBoxContainer.new()
	_right.add_child(_heading)
	_kind_label = Label.new()
	_kind_label.add_theme_color_override("font_color", get_theme_color("font_disabled_color", "Editor"))
	_heading.add_child(_kind_label)
	_title_label = Label.new()
	_title_label.theme_type_variation = &"HeaderMedium"
	_title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var title_size := get_theme_font_size("font_size", "Label") * 2
	_title_label.add_theme_font_size_override("font_size", title_size)
	_title_label.add_theme_constant_override("line_spacing", -int(title_size * 0.3))
	_heading.add_child(_title_label)
	_params = GridContainer.new()
	_params.columns = 2
	_params.add_theme_constant_override("h_separation", int(16 * edscale))
	_params.add_theme_constant_override("v_separation", 0)
	_right.add_child(_params)
	var label_box := _kind_label.get_theme_stylebox("normal")
	_heading.add_theme_constant_override("separation",
		-int(label_box.get_margin(SIDE_TOP) + label_box.get_margin(SIDE_BOTTOM) + title_size * 0.25))

	_note = Label.new()
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.visible = false
	content.add_child(_note)

	# Footer: the filesystem verbs the context menu serves, same order —
	# Open/Show in FileSystem for res://, Import for external files,
	# resource/node actions for scene-assets entries, reveal + copy last.
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", int(8 * edscale))
	content.add_child(footer)
	var left_spacer := Control.new()
	left_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(left_spacer)
	_actions["open"] = _footer_button(footer, "Open",
		func(): A2GUI._open_entry(asset); hide())
	_actions["edit_res"] = _footer_button(footer, "Edit Resource",
		func(): EditorInterface.edit_resource(asset.get("res")); hide())
	_actions["select_node"] = _footer_button(footer, "Select Node in Scene",
		func(): _select_node())
	_actions["import"] = _footer_button(footer, "Import into project…",
		func(): import_requested.emit([asset.duplicate()]); hide())
	_actions["reveal_fs"] = _footer_button(footer, "Show in FileSystem",
		func(): EditorInterface.get_file_system_dock().navigate_to_path(str(asset.get("path", ""))))
	_actions["reveal_fm"] = _footer_button(footer, "Show in File Manager",
		func(): _reveal_fm())
	_actions["copy"] = _footer_button(footer, "Copy Path",
		func(): DisplayServer.clipboard_set(str(asset.get("path", asset.get("name", "")))))

	get_ok_button().hide()
	add_theme_constant_override("buttons_separation", 0)
	exclusive = false
	get_tree().root.focus_entered.connect(_close_if_outside)
	focus_exited.connect(func(): _close_if_outside.call_deferred())


func _footer_button(footer: HBoxContainer, text: String, on_pressed: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(on_pressed)
	footer.add_child(b)
	return b


## Show [param entry] — the browser list's {path, kind, provider, ext}
## dict (scene-assets entries may add "res"/"node"). [param thumb] is
## the tile's own texture and only shows when nothing better exists:
## image files decode the full-res "Original" instead, so the strip
## never ends up holding two copies of the same picture.
func show_asset(entry: Dictionary, thumb: Texture2D = null) -> void:
	asset = entry
	var path := str(entry.get("path", ""))
	title = path.get_file() if path else str(entry.get("name", "Asset"))
	_title_label.text = title
	_kind_label.text = str(entry.get("kind", "")).capitalize()
	_kind_label.visible = not _kind_label.text.is_empty()
	_path_text.text = path if path else str(entry.get("name", ""))
	_path_text.visible = not _path_text.text.is_empty()
	_fill_params()

	_textures.clear()
	_shown_type = ""
	_preview.texture = null
	if thumb != null:
		_textures["tile"] = thumb
		_set_frame("tile")
	if path != "" and path.get_extension().to_lower() in A2GThumbs.IMAGE_EXTS:
		var img := Image.new()
		var abs_path := ProjectSettings.globalize_path(path) \
			if path.begins_with("res://") else path
		if img.load(abs_path) == OK:
			# The full-res frame replaces the tile's thumb — two frames
			# of the same picture are a duplicate, not a strip.
			_textures.erase("tile")
			_textures["full"] = ImageTexture.create_from_image(img)
			_set_frame("full")
	_rebuild_strip()

	_refresh_actions()
	_note.visible = false
	# ph_details' opening math: give wrapped text its width first so the
	# dialog opens as big as the content, not as tall as the text.
	_set_text_widths()
	reset_size()
	popup_centered_clamped(Vector2i.ZERO, 0.9)
	_shown_frame = Engine.get_process_frames()


## Footer visibility per entry: res:// files get Open/Reveal-in-FS,
## external files Import/Reveal-in-FM, scene entries their res/node
## verbs. Copy Path always shows for file entries.
func _refresh_actions() -> void:
	var path := str(asset.get("path", ""))
	var is_res := path.begins_with("res://")
	var is_file := path != ""
	var has_res: bool = asset.get("res") is Resource and is_instance_valid(asset.get("res"))
	var has_node: bool = asset.get("node") is Node and is_instance_valid(asset.get("node"))
	_actions["open"].visible = is_res
	_actions["edit_res"].visible = has_res
	_actions["select_node"].visible = has_node
	_actions["import"].visible = is_file and not is_res
	_actions["reveal_fs"].visible = is_res
	_actions["reveal_fm"].visible = is_file
	_actions["copy"].visible = is_file or str(asset.get("name", "")) != ""


func _select_node() -> void:
	var node: Node = asset.get("node")
	if node == null or not is_instance_valid(node):
		return
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(node)
	EditorInterface.edit_node(node)
	hide()


func _reveal_fm() -> void:
	var path := str(asset.get("path", ""))
	if path == "":
		return
	OS.shell_show_in_file_manager(ProjectSettings.globalize_path(path) \
		if path.begins_with("res://") else path)


## Parameter rows — only what exists shows, file facts for path entries,
## class/node info for scene-assets entries.
func _fill_params() -> void:
	for c in _params.get_children():
		_params.remove_child(c)
		c.queue_free()
	var dim := get_theme_color("font_disabled_color", "Editor")
	var path := str(asset.get("path", ""))
	var rows: Array = []
	if str(asset.get("provider", "")) != "":
		rows.append(["Provider", str(asset.get("provider", ""))])
	if str(asset.get("source", "")) != "":
		rows.append(["Source", str(asset.get("source", "")).capitalize()])
	if str(asset.get("type", "")) != "":
		rows.append(["Type", str(asset.get("type", ""))])
	if path != "":
		if FileAccess.file_exists(ProjectSettings.globalize_path(path) \
				if path.begins_with("res://") else path):
			rows.append(["Size", String.humanize_size(
				FileAccess.get_file_as_bytes(_abs(path)).size())])
			var dt := _date(int(FileAccess.get_modified_time(_abs(path))))
			if dt != "":
				rows.append(["Modified", dt])
		if EditorInterface.get_resource_filesystem() != null and path.begins_with("res://"):
			var t := EditorInterface.get_resource_filesystem().get_file_type(path)
			if t != "":
				rows.append(["Resource", t])
		if path.get_extension() != "":
			rows.append(["Format", path.get_extension().to_upper()])
		if _textures.has("full"):
			var img: Texture2D = _textures["full"]
			rows.append(["Dimensions", "%d × %d px" % [img.get_width(), img.get_height()]])
	else:
		var res: Resource = asset.get("res")
		if res is Resource:
			rows.append(["Resource", res.get_class()])
			if res.resource_name != "":
				rows.append(["Name", res.resource_name])
		var node: Node = asset.get("node")
		if node is Node and is_instance_valid(node):
			rows.append(["Node", str(node.get_path())])
	for row in rows:
		var key := Label.new()
		key.text = row[0]
		key.add_theme_color_override("font_color", dim)
		_params.add_child(key)
		var value := Label.new()
		value.text = row[1]
		value.tooltip_text = row[1]
		_params.add_child(value)


func _abs(path: String) -> String:
	return ProjectSettings.globalize_path(path) if path.begins_with("res://") else path


func _set_frame(type: String) -> void:
	_shown_type = type
	_preview.texture = _textures.get(type)
	for b in _strip.get_children():
		b.set_pressed_no_signal(b.get_meta("type") == type)


func _rebuild_strip() -> void:
	for c in _strip.get_children():
		_strip.remove_child(c)
		c.queue_free()
	if _textures.size() < 2:
		_strip.custom_minimum_size.y = 0
		return
	var edscale := EditorInterface.get_editor_scale()
	_strip.custom_minimum_size.y = 64 * edscale
	for type in ["full", "tile"]:
		if not _textures.has(type):
			continue
		var b := Button.new()
		b.set_meta("type", type)
		b.custom_minimum_size = Vector2.ONE * 64 * edscale
		b.expand_icon = true
		b.icon = _textures[type]
		b.toggle_mode = true
		b.button_pressed = type == _shown_type
		b.tooltip_text = "Original" if type == "full" else "Thumbnail"
		b.pressed.connect(_set_frame.bind(type))
		_strip.add_child(b)


## The widths the panes give the wrapped text, before they are laid out —
## ph_details' math verbatim: content = two panes + the gap.
func _set_text_widths() -> void:
	var pane := _preview.custom_minimum_size.x
	var content_width := pane * 2 + _panes.get_theme_constant("separation")
	for box: Control in [_panes.get_parent(), _panes]:
		box.size.x = content_width
	for box: Control in [_path_text.get_parent(), _right, _heading]:
		box.size.x = pane
	_set_text_width(_title_label, pane)
	_set_text_width(_path_text, pane)
	_set_text_width(_note, content_width)


## Measures [param control] again at [param width] only when asked, and
## drops the height it had at the old width, which would grow the dialog.
func _set_text_width(control: Control, width: float) -> void:
	control.size.x = width
	control.update_minimum_size()
	control.size.y = 0


func _close_if_outside() -> void:
	if not is_inside_tree() or not visible or has_focus() \
			or _shown_frame == Engine.get_process_frames():
		return
	if not get_tree().root.has_focus():
		return
	for w in find_children("*", "Window", true, false):
		if w.visible:
			return
	hide()


## "07 Nov 2026" from a unix timestamp, or "".
static func _date(ts: int) -> String:
	if ts <= 0:
		return ""
	var d := Time.get_datetime_dict_from_unix_time(ts)
	return "%02d %s %04d" % [d.day, MONTHS[int(d.month) - 1], d.year]
