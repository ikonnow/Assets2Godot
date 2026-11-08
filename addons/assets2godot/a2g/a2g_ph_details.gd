@tool
extends AcceptDialog
## The Polyhaven asset popup — the tab's version of the gallery's
## asset_details: big render on the left with the CC0 badge (the site's
## only "plan"), the type, title, parameter rows and clickable tags on
## the right, and a footer with the file picker + Download action plus
## the web/support links. Login, plans and ratings don't exist at
## polyhaven.com — everything is CC0, so there is no gate.
##
## The tab owns state: it passes the parsed asset and the flattened file
## options, answers "is it downloaded/downloading" through
## [member state_getter] and performs downloads off [signal download_requested].

signal download_requested(asset: Dictionary, option: Dictionary)
signal tag_selected(tag: String)
signal author_selected(author: String)

const PhApi = preload("res://addons/assets2godot/a2g/polyhaven_api.gd")
const FileReveal = preload("res://addons/assets2godot/ui/file_reveal.gd")
const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
const DESCRIPTION_MAX_HEIGHT := 200

var asset: Dictionary = {}
## Returns {"dir": "…" if downloaded else "", "downloading": bool}.
var state_getter := Callable()

var _preview: TextureRect
var _frame: PanelContainer
var _badge: Label
var _strip: HBoxContainer
var _textures := {}
var _shown_type := ""
var _description: RichTextLabel
var _type_label: Label
var _title_label: Label
var _heading: VBoxContainer
var _panes: HBoxContainer
var _right: VBoxContainer
var _params: GridContainer
var _tags_row: HBoxContainer
var _tags_key: Label
var _tags: RichTextLabel
var _note: Label
var _file_option: OptionButton
var _action: Button
var _files: Array = []
var _req: HTTPRequest
## Frame the dialog last opened — _close_if_outside ignores focus churn on
## that same frame (asset_details' guard against instant self-close).
var _shown_frame := -1


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

	# Left: framed preview with the CC0 badge, a strip for the frames we
	# have (primary render + the card thumb), the description under it.
	var left := VBoxContainer.new()
	_panes.add_child(left)
	_frame = PanelContainer.new()
	_frame.clip_contents = true
	# No panel override: asset_details' PreviewFrame is a plain
	# PanelContainer — the theme's own dark panel shows through the
	# render's transparent margins, never a white box.
	left.add_child(_frame)
	_preview = TextureRect.new()
	_preview.custom_minimum_size = Vector2.ONE * 400 * edscale
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# same as asset_details.tscn — letterbox any preview aspect, no crop
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_frame.add_child(_preview)
	_badge = Label.new()
	_badge.text = "CC0"
	_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_badge.add_theme_color_override("font_color", get_theme_color("base_color", "Editor"))
	var bs := StyleBoxFlat.new()
	bs.bg_color = get_theme_color("accent_color", "Editor")
	bs.set_corner_radius_all(int(8 * edscale))
	bs.content_margin_left = 6 * edscale
	bs.content_margin_right = 6 * edscale
	_badge.add_theme_stylebox_override("normal", bs)
	_badge.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_badge.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_badge.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_badge.offset_left = -6 * edscale
	_badge.offset_right = -6 * edscale
	_badge.offset_top = -6 * edscale
	_badge.offset_bottom = -6 * edscale
	_preview.add_child(_badge)
	_strip = HBoxContainer.new()
	_strip.alignment = BoxContainer.ALIGNMENT_CENTER
	left.add_child(_strip)
	_description = RichTextLabel.new()
	_description.fit_content = true
	_description.selection_enabled = true
	_description.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	_description.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_description.add_theme_constant_override("line_separation", int(4 * edscale))
	_description.meta_clicked.connect(func(meta): OS.shell_open(str(meta)))
	left.add_child(_description)

	# Right: dimmed type over the big title, then the param rows and tags.
	_right = VBoxContainer.new()
	_right.custom_minimum_size.x = _preview.custom_minimum_size.x
	_panes.add_child(_right)
	_heading = VBoxContainer.new()
	_right.add_child(_heading)
	_type_label = Label.new()
	var dim := get_theme_color("font_disabled_color", "Editor")
	_type_label.add_theme_color_override("font_color", dim)
	_heading.add_child(_type_label)
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
	_tags_row = HBoxContainer.new()
	_tags_row.add_theme_constant_override("separation", int(16 * edscale))
	_right.add_child(_tags_row)
	_tags_key = Label.new()
	_tags_key.text = "Tags"
	_tags_key.size_flags_vertical = 0
	_tags_key.add_theme_color_override("font_color", dim)
	_tags_row.add_child(_tags_key)
	_tags = RichTextLabel.new()
	_tags.bbcode_enabled = true
	_tags.fit_content = true
	_tags.scroll_active = false
	_tags.meta_underlined = false
	_tags.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tags.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	_tags.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_tags.add_theme_color_override("default_color", get_theme_color("font_color", "Label"))
	_tags.meta_clicked.connect(func(meta):
		tag_selected.emit(str(asset.get("tags", [])[int(meta)])))
	_tags_row.add_child(_tags)
	# The type sits right above the title, eating the room the title font
	# keeps above its capitals — asset_details' own separation math.
	var label_box := _tags_key.get_theme_stylebox("normal")
	_heading.add_theme_constant_override("separation",
		-int(label_box.get_margin(SIDE_TOP) + label_box.get_margin(SIDE_BOTTOM) + title_size * 0.25))
	# The tags carry the key's margins so their baseline matches the rows.
	var tags_box := StyleBoxEmpty.new()
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		tags_box.set_content_margin(side, label_box.get_margin(side))
	_tags.add_theme_stylebox_override("normal", tags_box)
	_tags.add_theme_stylebox_override("focus", tags_box)

	_note = Label.new()
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.visible = false
	content.add_child(_note)

	var footer := HBoxContainer.new()
	content.add_child(footer)
	var left_spacer := Control.new()
	left_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(left_spacer)
	_file_option = OptionButton.new()
	_file_option.tooltip_text = "File to download — the Resolution dropdown in the filter row picks the default."
	footer.add_child(_file_option)
	_action = Button.new()
	_action.text = "Download"
	_action.pressed.connect(_on_action)
	footer.add_child(_action)
	var right_box := HBoxContainer.new()
	right_box.alignment = BoxContainer.ALIGNMENT_END
	right_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(right_box)
	var support := Button.new()
	support.text = "♥ Support"
	support.tooltip_text = "Polyhaven lives off Patreon — support them like the site asks."
	support.pressed.connect(func(): OS.shell_open("https://www.patreon.com/polyhaven"))
	right_box.add_child(support)
	var web := Button.new()
	web.text = "View on polyhaven.com"
	web.pressed.connect(func(): OS.shell_open(PhApi.web_url(str(asset.get("slug", "")))))
	right_box.add_child(web)

	get_ok_button().hide()
	add_theme_constant_override("buttons_separation", 0)
	exclusive = false
	get_tree().root.focus_entered.connect(_close_if_outside)
	focus_exited.connect(func(): _close_if_outside.call_deferred())


## Show [param new_asset] (parsed /assets entry) with the flattened file
## options and the thumbnail texture the card already had — the primary
## render streams in on top once fetched.
func show_asset(new_asset: Dictionary, options: Array, thumb: Texture2D, res_hint: String) -> void:
	asset = new_asset
	_files = options
	var slug := str(asset.get("slug", ""))
	title = str(asset.get("name", slug))
	_title_label.text = title
	_type_label.text = str(asset.get("type", "")).capitalize()
	_type_label.visible = not _type_label.text.is_empty()
	# Site parity: the description, then the optional markdown info note
	# ("Edited version of [X](url)") rendered as a bbcode link.
	_description.bbcode_enabled = true
	var desc_text := str(asset.get("description", "")).strip_edges()
	var info := str(asset.get("info", "")).strip_edges()
	if not info.is_empty():
		desc_text += "\n\n" + PhApi.md_to_bbcode(info)
	_description.text = desc_text
	_description.visible = not _description.text.is_empty()
	_description.fit_content = true
	_description.custom_minimum_size.y = 0
	_fill_params()
	_fill_tags()
	_fill_files(res_hint)

	_textures.clear()
	_shown_type = ""
	_preview.texture = null
	if thumb != null:
		_textures["thumb"] = thumb
		_set_frame("thumb")
	_rebuild_strip()
	# The primary render streams in after open — with a thumb present the
	# strip will get its second button, so reserve the row up front and
	# the dialog doesn't grow mid-view.
	_strip.custom_minimum_size.y = 64 * EditorInterface.get_editor_scale() \
		if _textures.has("thumb") else 0.0
	_fetch_preview(slug)
	refresh_state()
	# asset_details' opening math: wrapped text is as tall as it is at its
	# width, which it only gets once laid out — give it the width first so
	# the dialog opens as big as the content, not as tall as the text.
	_set_text_widths()
	var max_height := DESCRIPTION_MAX_HEIGHT * EditorInterface.get_editor_scale()
	if _description.get_content_height() > max_height:
		_description.fit_content = false
		_description.custom_minimum_size.y = max_height
	reset_size()
	popup_centered_clamped(Vector2i.ZERO, 0.9)
	_shown_frame = Engine.get_process_frames()
	await get_tree().process_frame
	if visible and not _action.disabled:
		_action.grab_focus()


## The widths the panes give the wrapped text, before they are laid out —
## asset_details' math verbatim: content = two panes + the gap, each pane
## as wide as the preview, note spans the full row.
func _set_text_widths() -> void:
	var pane := _preview.custom_minimum_size.x
	var content_width := pane * 2 + _panes.get_theme_constant("separation")
	for box: Control in [_panes.get_parent(), _panes]:
		box.size.x = content_width
	for box: Control in [_description.get_parent(), _right, _heading, _tags_row]:
		box.size.x = pane
	_set_text_width(_title_label, pane)
	_set_text_width(_description, pane)
	_set_text_width(_tags, pane - _tags_key.get_combined_minimum_size().x \
		- _tags_row.get_theme_constant("separation"))
	_set_text_width(_note, content_width)


## Measures [param control] again at [param width] only when asked, and
## drops the height it had at the old width, which would grow the dialog.
func _set_text_width(control: Control, width: float) -> void:
	control.size.x = width
	control.update_minimum_size()
	control.size.y = 0


func _fetch_preview(slug: String) -> void:
	if _req != null:
		_req.queue_free()
	_req = HTTPRequest.new()
	_req.timeout = 30.0
	add_child(_req)
	_req.request_completed.connect(func(_r, code, _h, body):
		_req.queue_free()
		_req = null
		if code != 200 or str(asset.get("slug", "")) != slug:
			return
		var img := Image.new()
		var err := img.load_png_from_buffer(body)
		if err != OK:
			err = img.load_webp_from_buffer(body)
		if err != OK:
			err = img.load_jpg_from_buffer(body)
		if err == OK:
			# The real render replaces the card's low-res tile outright —
			# one picture is enough, no thumb-vs-render strip.
			_textures["primary"] = ImageTexture.create_from_image(img)
			_textures.erase("thumb")
			_set_frame("primary")
			_rebuild_strip())
	if _req.request(PhApi.preview_url(slug), [PhApi.UA_HEADER]) != OK:
		_req.queue_free()
		_req = null


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
		return
	var edscale := EditorInterface.get_editor_scale()
	for type in ["primary", "thumb"]:
		if not _textures.has(type):
			continue
		var b := Button.new()
		b.set_meta("type", type)
		b.custom_minimum_size = Vector2.ONE * 64 * edscale
		b.expand_icon = true
		b.icon = _textures[type]
		b.toggle_mode = true
		b.button_pressed = type == _shown_type
		b.tooltip_text = "Render" if type == "primary" else "Thumbnail"
		b.pressed.connect(_set_frame.bind(type))
		_strip.add_child(b)


## Parameter rows like the site's asset page — only what exists shows.
## Children are removed before freeing: a queued child still counts in
## the container's min size until it dies, ghosting the rows of the last
## asset into the dialog's opening size on reuse.
func _fill_params() -> void:
	for c in _params.get_children():
		_params.remove_child(c)
		c.queue_free()
	var dim := get_theme_color("font_disabled_color", "Editor")
	var author := PhApi.authors_text(asset.get("authors", {}))
	if not author.is_empty():
		var key := Label.new()
		key.text = "Author"
		key.add_theme_color_override("font_color", dim)
		_params.add_child(key)
		var value := Label.new()
		value.text = author
		_make_link(value, "Search for assets by %s" % author,
			func(): author_selected.emit(author))
		_params.add_child(value)
	for row in _rows():
		var key := Label.new()
		key.text = row[0]
		key.add_theme_color_override("font_color", dim)
		_params.add_child(key)
		var value := Label.new()
		value.text = row[1]
		_params.add_child(value)


func _rows() -> Array:
	var rows := []
	var cat := str(asset.get("category", ""))
	if not cat.is_empty():
		rows.append(["Category", cat])
	if int(asset.get("polycount", 0)) > 0:
		rows.append(["Polygons", _thousands(int(asset.polycount))])
	var dims: Array = asset.get("dimensions", [])
	# millimeters in the API, meters on the site — 3 values for models,
	# 2 for the physical size of textures.
	if dims.size() == 3:
		rows.append(["Dimensions", "%.2f × %.2f × %.2f m" % \
			[float(dims[0]) / 1000.0, float(dims[1]) / 1000.0, float(dims[2]) / 1000.0]])
	elif dims.size() == 2:
		rows.append(["Size", "%.2f × %.2f m" % [float(dims[0]) / 1000.0, float(dims[1]) / 1000.0]])
	if float(asset.get("texel_density", 0.0)) > 0.0:
		rows.append(["Texel density", "%d px/m" % int(asset.texel_density)])
	var maxres: Array = asset.get("max_resolution", [])
	if maxres.size() == 2:
		rows.append(["Resolution", "%d × %d px" % [int(maxres[0]), int(maxres[1])]])
	if int(asset.get("evs_cap", 0)) > 0:
		rows.append(["Dynamic range", "%d EVs" % int(asset.evs_cap)])
	if int(asset.get("whitebalance", 0)) > 0:
		rows.append(["White balance", "%dK" % int(asset.whitebalance)])
	for k in asset.get("attributes", {}):
		# values come as a single string on HDRIs, an array on models
		var v = asset.attributes[k]
		var vals: Array = v if v is Array else [v]
		if not vals.is_empty():
			rows.append([str(k).capitalize(), ", ".join(vals.map(func(x): return str(x)))])
	var coords: Array = asset.get("coords", [])
	if coords.size() == 2:
		rows.append(["Location", "%.2f°, %.2f°" % [float(coords[0]), float(coords[1])]])
	if int(asset.get("download_count", 0)) > 0:
		rows.append(["Downloads", _thousands(int(asset.download_count))])
	rows.append(["License", "CC0"])
	var published := _date(int(asset.get("date_published", 0)))
	if not published.is_empty():
		rows.append(["Published", published])
	var taken := _date(int(asset.get("date_taken", 0)))
	if not taken.is_empty() and taken != published:
		rows.append(["Taken", taken])
	return rows


func _fill_tags() -> void:
	var tags: Array = asset.get("tags", [])
	_tags_row.visible = not tags.is_empty()
	var links := PackedStringArray()
	for i in tags.size():
		links.append("[url=%d]%s[/url]" % [i, str(tags[i]).replace("[", "[lb]")])
	_tags.text = ", ".join(links)


func _fill_files(res_hint: String) -> void:
	_file_option.clear()
	for i in _files.size():
		_file_option.add_item(str(_files[i].get("label", "?")), i)
		_file_option.set_item_metadata(i, _files[i])
	var pick := PhApi.pick_default(_files, res_hint)
	if pick >= 0:
		_file_option.select(pick)
	_file_option.disabled = _file_option.item_count == 0


## Download / Downloading… / Show File — the tab answers via state_getter.
func refresh_state() -> void:
	var st: Dictionary = state_getter.call() if state_getter.is_valid() else {}
	_action.disabled = false
	if st.get("downloading", false):
		_action.text = "Downloading…"
		_action.disabled = true
		return
	var dir := str(st.get("dir", ""))
	if not dir.is_empty():
		_action.text = "Show File"
		_action.tooltip_text = "Show the downloaded folder in the file manager."
		return
	_action.text = "Download"
	_action.tooltip_text = ""
	_action.disabled = _file_option.item_count == 0


func _on_action() -> void:
	var st: Dictionary = state_getter.call() if state_getter.is_valid() else {}
	var dir := str(st.get("dir", ""))
	if not dir.is_empty():
		FileReveal.reveal(dir)
		hide()
		return
	var i := _file_option.selected
	if i >= 0 and i < _files.size():
		download_requested.emit(asset, _files[i])


func _make_link(label: Label, tooltip: String, on_click: Callable) -> void:
	var hover := get_theme_color("accent_color", "Editor")
	label.tooltip_text = tooltip
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	label.mouse_entered.connect(func(): label.add_theme_color_override("font_color", hover))
	label.mouse_exited.connect(func(): label.remove_theme_color_override("font_color"))
	label.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.is_released():
			on_click.call())


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


## "07 Oct 2026" from a unix timestamp, or "".
static func _date(ts: int) -> String:
	if ts <= 0:
		return ""
	var d := Time.get_datetime_dict_from_unix_time(ts)
	return "%02d %s %04d" % [d.day, MONTHS[int(d.month) - 1], d.year]


static func _thousands(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = " " + s.right(3) + out
		s = s.left(s.length() - 3)
	return ("-" if n < 0 else "") + s + out
