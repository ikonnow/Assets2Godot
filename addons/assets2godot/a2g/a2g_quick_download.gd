@tool
extends PopupPanel
## The compact right-click tile for remote-provider cards: the asset
## title, the file/format picker and a Download action, plus a row of
## secondary actions (details link, provider page, copy URL, reveal the
## downloaded folder) — the details popup's footer as a small tile
## floating under the cursor.
##
## Everything it shows comes from the card's remote_* payload keys
## (spec §3d), so remote providers and the BlendKit gallery (via
## install_bk_quick_download) share this surface without per-provider
## menus. remote_options answers through a callback, so providers whose
## file list needs a fetch may answer late — the picker waits on
## "Loading…" until then.

var _title: Label
var _options: OptionButton
var _dl_btn: Button
var _note: Label
var _actions: HBoxContainer
var _entry := {}


func _ready() -> void:
	var edscale := EditorInterface.get_editor_scale()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", int(8 * edscale))
	add_child(box)
	_title = Label.new()
	_title.clip_text = true
	_title.add_theme_font_size_override("font_size",
		get_theme_font_size("font_size", "Label") + 1)
	box.add_child(_title)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(6 * edscale))
	box.add_child(row)
	_options = OptionButton.new()
	_options.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_options.clip_text = true
	_options.fit_to_longest_item = false
	_options.custom_minimum_size.x = int(150 * edscale)
	_options.item_selected.connect(func(_i): _refresh_state())
	row.add_child(_options)
	_dl_btn = Button.new()
	_dl_btn.text = "Download"
	_dl_btn.pressed.connect(_on_download)
	row.add_child(_dl_btn)
	_note = Label.new()
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.add_theme_color_override("font_color",
		get_theme_color("font_disabled_color", "Editor"))
	_note.visible = false
	box.add_child(_note)
	_actions = HBoxContainer.new()
	_actions.alignment = BoxContainer.ALIGNMENT_END
	_actions.add_theme_constant_override("separation", int(2 * edscale))
	box.add_child(_actions)


## Opens the tile under the cursor for the card's remote_* [param entry].
## reset_size first so the window clamps to its real minimum, positioned
## like the context menu and kept on screen like polygon_filter does.
func open_for(card: Control, entry: Dictionary) -> void:
	_entry = entry
	var edscale := EditorInterface.get_editor_scale()
	_title.text = str(entry.get("remote_title", entry.get("remote_slug", "")))
	_title.tooltip_text = _title.text
	_title.custom_minimum_size.x = 240 * edscale
	_rebuild_actions()
	_options.clear()
	_options.add_item("Loading files…")
	_options.set_item_metadata(0, null)
	_options.disabled = true
	_set_note("")
	_refresh_state()
	reset_size()
	var pos: Vector2 = card.get_screen_position() + card.get_local_mouse_position() \
		+ Vector2.ONE * 4 * edscale
	var window := get_window()
	pos.x = clampf(pos.x, window.position.x, window.position.x + window.size.x - size.x)
	pos.y = clampf(pos.y, window.position.y, window.position.y + window.size.y - size.y)
	popup(Rect2i(Vector2i(pos), size))
	var fetcher: Variant = entry.get("remote_options")
	if fetcher is Callable:
		fetcher.call(func(options, default_idx): _fill_options(options, default_idx))
	else:
		_fill_options([], -1)


func _fill_options(options: Array, default_idx: int) -> void:
	_options.clear()
	for i in options.size():
		_options.add_item(str(options[i].get("label", "?")), i)
		_options.set_item_metadata(i, options[i])
	_options.disabled = options.is_empty()
	if options.is_empty():
		_set_note("No downloadable files.")
	elif default_idx >= 0 and default_idx < options.size():
		_options.select(default_idx)
	elif _options.selected < 0:
		_options.select(0)
	_refresh_state()


func _selected_option() -> Variant:
	if _options.selected < 0:
		return null
	return _options.get_item_metadata(_options.selected)


## The button's label/state/note from the provider's remote_state answer
## ({label, enabled, note}); defaults to a plain enabled Download.
func _refresh_state() -> void:
	var st := {"label": "Download", "enabled": true, "note": ""}
	var state_cb: Variant = _entry.get("remote_state")
	if state_cb is Callable:
		var opt: Variant = _selected_option()
		var r: Variant = state_cb.call(opt.get("data") if opt is Dictionary else null)
		if r is Dictionary:
			st.merge(r, true)
	_dl_btn.text = str(st.get("label", "Download"))
	_dl_btn.disabled = not bool(st.get("enabled", true)) \
		or _options.item_count == 0 or _options.disabled
	_set_note(str(st.get("note", "")))


func _set_note(text: String) -> void:
	_note.text = text
	_note.visible = not text.is_empty()


## Hands the chosen option's data to the provider's remote_download —
## whatever it does next (queue, daemon task) is its own. The tile closes
## like the context menu would after a pick.
func _on_download() -> void:
	var opt: Variant = _selected_option()
	var download: Variant = _entry.get("remote_download")
	if download is Callable:
		download.call(opt.get("data") if opt is Dictionary else null)
	hide()


## The secondary row, rebuilt per entry: details link, provider page,
## copy URL, and the reveal action only while a downloaded folder exists.
func _rebuild_actions() -> void:
	for c in _actions.get_children():
		_actions.remove_child(c)
		c.queue_free()
	var details: Variant = _entry.get("remote_details")
	if details is Callable:
		var b := LinkButton.new()
		b.text = "Details…"
		b.pressed.connect(func(): hide(); details.call())
		_actions.add_child(b)
	var url := str(_entry.get("remote_url", ""))
	if not url.is_empty():
		_actions.add_child(_icon_btn("ExternalLink",
			"Open on %s" % str(_entry.get("remote_site", "the provider site")),
			func(): OS.shell_open(url)))
		_actions.add_child(_icon_btn("ActionCopy", "Copy page URL",
			func(): DisplayServer.clipboard_set(url)))
	var dir_cb: Variant = _entry.get("remote_dir")
	if dir_cb is Callable and str(dir_cb.call()) != "":
		_actions.add_child(_icon_btn("Folder", "Show in File Manager",
			func(): OS.shell_show_in_file_manager(str(dir_cb.call()))))


func _icon_btn(icon_name: StringName, tooltip: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.theme_type_variation = "FlatButton"
	var theme := EditorInterface.get_editor_theme()
	if theme and theme.has_icon(icon_name, &"EditorIcons"):
		b.icon = theme.get_icon(icon_name, &"EditorIcons")
	b.tooltip_text = tooltip
	b.pressed.connect(on_press)
	return b
