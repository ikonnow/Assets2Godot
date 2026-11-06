@tool
extends PanelContainer
## The Assets2Godot browser: every indexed asset from every provider
## (local dirs, Fab vault — BlendKit downloads too once their folder is
## scanned), rendered gallery-style. Styled after ui/gallery: search row,
## filter row, scrollable card grid.

const Icons = preload("res://addons/assets2godot/ui/icons.gd")
const A2GUI = preload("res://addons/assets2godot/a2g/a2g_ui.gd")
const A2GThumbs = preload("res://addons/assets2godot/a2g/a2g_thumbs.gd")
const SEARCH_LIMIT = 500

## assets2godot/browser_view editor setting: 0 = tile grid, 1 = list.
const SETTING_VIEW := "assets2godot/browser_view"
enum View { GRID, LIST }

## Kind → EditorIcons name for the list view's rows — same names the
## FileSystem dock shows for those resource types.
const LIST_ICONS := {
	"model": "MeshInstance3D", "ue_asset": "MeshInstance3D",
	"material": "StandardMaterial3D", "texture": "ImageTexture",
	"hdr": "ImageTexture", "scene_data": "PackedScene",
	"resource": "Object", "animation": "Animation", "audio": "AudioStreamWAV",
	"script": "Script", "metadata": "TextFile", "file": "File",
}

var plugin: EditorPlugin

var _search: LineEdit
var _provider_filter: OptionButton
var _kind_filter: OptionButton
var _refresh: Button
var _view_toggle: Button
var _grid: GridContainer
var _scroll: ScrollContainer
var _border: PanelContainer
var _list: ItemList
var _empty: Label
var _icon: Texture2D
var _thumbs: Node
var _assets: Array = []
var _preview_map := {}
var _view_mode := View.GRID
var _list_entries: Array = []
var _split_btn: Button
## The SplitContainer this browser shares with the Sources dock — set by
## the plugin so the toolbar's split-mode button flips its orientation.
var split: SplitContainer


func _ready() -> void:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	add_child(vbox)

	# Search row — same shape as the BlendKit gallery.
	var search_row := HBoxContainer.new()
	vbox.add_child(search_row)
	_search = LineEdit.new()
	_search.placeholder_text = "Search indexed assets (ENTER to search)"
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_submitted.connect(func(_q): _reload())
	search_row.add_child(_search)
	_refresh = Button.new()
	_refresh.text = "Refresh"
	_refresh.tooltip_text = "Reload the index."
	_refresh.theme_type_variation = "FlatButton"
	_refresh.pressed.connect(_reload)
	search_row.add_child(_refresh)
	# Grid/list toggle — the FileSystem dock's own mode icons.
	_view_toggle = Button.new()
	_view_toggle.theme_type_variation = "FlatButton"
	_view_toggle.toggle_mode = true
	_view_toggle.pressed.connect(_toggle_view)
	search_row.add_child(_view_toggle)
	_view_mode = _setting(SETTING_VIEW, View.GRID)
	_update_view_toggle()
	# Split-mode toggle — the FS dock puts display_mode at the right end of
	# the file panel's toolbar, not on the tree side.
	_split_btn = Button.new()
	_split_btn.theme_type_variation = "FlatButton"
	_split_btn.tooltip_text = "Change split mode — sources left/right or top/bottom."
	_split_btn.pressed.connect(_toggle_split)
	search_row.add_child(_split_btn)
	_update_split_icon()

	# Filter row.
	var filter_row := HFlowContainer.new()
	vbox.add_child(filter_row)
	var pl := Label.new()
	pl.text = "Provider:"
	filter_row.add_child(pl)
	_provider_filter = OptionButton.new()
	_provider_filter.item_selected.connect(func(_i): _rebuild())
	filter_row.add_child(_provider_filter)
	var kl := Label.new()
	kl.text = "  Kind:"
	filter_row.add_child(kl)
	_kind_filter = OptionButton.new()
	_kind_filter.item_selected.connect(func(_i): _rebuild())
	filter_row.add_child(_kind_filter)

	# Scrollable card grid + empty state — identical chrome to
	# gallery.tscn: Margin(NoBorderAssetLib) → Scroll → Border panel
	# (empty stylebox, L15/T0/R35/B15) → Grid.
	var margin := MarginContainer.new()
	margin.theme_type_variation = "NoBorderAssetLib"
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(margin)
	_scroll = A2GUI.make_scroll()
	_scroll.resized.connect(_update_columns)
	margin.add_child(_scroll)
	_border = A2GUI.make_scroll_border()
	_scroll.add_child(_border)
	_grid = A2GUI.make_grid()
	_border.add_child(_grid)
	# List view — FileSystem-dock-style rows (icon + name); the
	# ItemListSecondary variation is the secondary bg the FS list uses.
	_list = ItemList.new()
	_list.theme_type_variation = "ItemListSecondary"
	_list.fixed_icon_size = Vector2i(int(20 * EditorInterface.get_editor_scale()),
		int(20 * EditorInterface.get_editor_scale()))
	_list.item_clicked.connect(_on_list_item_clicked)
	_list.item_activated.connect(_on_list_item_activated)
	_list.visible = _view_mode == View.LIST
	margin.add_child(_list)
	_scroll.visible = _view_mode == View.GRID
	_empty = Label.new()
	_empty.text = "No indexed assets yet.\nAdd folders and press Scan in the Local Assets tab."
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_empty)

	_icon = Icons.render_svg(A2GUI.ICON_PATH, EditorInterface.get_editor_scale(), true)
	_thumbs = A2GThumbs.new()
	_thumbs.rendered.connect(_on_rendered)
	add_child(_thumbs)
	if plugin.connection:
		plugin.connection.connected.connect(_reload)
	_update_state()


func _update_state() -> void:
	var connected: bool = plugin.connection != null and plugin.connection.is_client_connected()
	_refresh.disabled = not connected
	_search.editable = connected


## Public refresh entry — the dock emits `scanned` into this after a scan
## finishes so the browser shows the new index without a manual search.
func refresh() -> void:
	_reload()


func _reload() -> void:
	_update_state()
	if not (plugin.connection and plugin.connection.is_client_connected()):
		return
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_result, code, _h, body):
		req.queue_free()
		var data = JSON.parse_string(body.get_string_from_utf8()) if code == 200 else null
		if data is Dictionary:
			_assets = data.get("results", [])
			_rebuild())
	var url: String = plugin.connection.client_url("providers/search?limit=%d&q=%s" % [SEARCH_LIMIT, _search.text.uri_encode()])
	if req.request(url) != OK:
		req.queue_free()
		plugin.log_warning("A2G browser search failed to start: %s" % url)


func _rebuild() -> void:
	for c in _grid.get_children():
		c.queue_free()
	_list.clear()
	_list_entries.clear()
	_refill_filters()
	_match_previews()
	var provider_sel: String = _provider_filter.get_item_text(_provider_filter.selected) if _provider_filter.selected >= 0 else "All"
	var kind_sel: String = _kind_filter.get_item_text(_kind_filter.selected) if _kind_filter.selected >= 0 else "All"
	var shown := 0
	for a in _assets:
		var stem := str(a.get("path", "")).get_basename()
		# Preview images claimed by a sibling asset are not own entries.
		if _preview_map.has(stem) and _is_image(str(a.get("path", ""))):
			continue
		if provider_sel != "All" and a.get("provider", "") != provider_sel:
			continue
		if kind_sel != "All" and a.get("kind", "") != kind_sel:
			continue
		if _view_mode == View.GRID:
			var card := A2GUI.asset_card(a.get("name", "?"), a.get("kind", "?"),
				a.get("provider", "?"), a.get("path", ""), _icon, "",
				{"ext": str(a.get("path", "")).get_extension().to_lower()})
			_grid.add_child(card)
			_queue_preview(a.get("path", ""), card)
		else:
			var path := str(a.get("path", ""))
			var idx := _list.add_item("%s  ·  %s  ·  %s" % [a.get("name", "?"),
				a.get("kind", "?"), a.get("provider", "?")], _list_icon(str(a.get("kind", ""))))
			_list.set_item_tooltip(idx, "%s\n%s" % [path.get_file(), A2GUI.short_path(path)])
			_list_entries.append({"path": path, "kind": a.get("kind", ""),
				"provider": a.get("provider", ""),
				"ext": path.get_extension().to_lower()})
		shown += 1
	_empty.visible = shown == 0
	_update_columns()


## Right-click on a list row opens the same asset context menu the cards
## show; left-click just selects (FileSystem-dock behavior).
func _on_list_item_clicked(index: int, _at: Vector2, mouse_button: int) -> void:
	if mouse_button == MOUSE_BUTTON_RIGHT and index < _list_entries.size():
		A2GUI.asset_context_menu(_list_entries[index], _list)


## Double-click = the FileSystem dock's Open action.
func _on_list_item_activated(index: int) -> void:
	if index < _list_entries.size():
		A2GUI._open_entry(_list_entries[index])


func _list_icon(kind: String) -> Texture2D:
	var icon_name: StringName = LIST_ICONS.get(kind, "File")
	var theme := EditorInterface.get_editor_theme()
	if theme and theme.has_icon(icon_name, &"EditorIcons"):
		return theme.get_icon(icon_name, &"EditorIcons")
	return _icon


func _toggle_view() -> void:
	_view_mode = View.LIST if _view_mode == View.GRID else View.GRID
	_set_setting(SETTING_VIEW, _view_mode)
	_update_view_toggle()
	_rebuild()


## The FileSystem dock's "Change Split Mode" — toggling .vertical on the
## shared SplitContainer is all the orientation change needs.
func _toggle_split() -> void:
	if split == null:
		return
	split.vertical = not split.vertical
	split.split_offset = int(340 * EditorInterface.get_editor_scale())
	_update_split_icon()


func _update_split_icon() -> void:
	if _split_btn == null:
		return
	# Panels2 = side by side, Panels2Alt = stacked — the FS dock's own icons
	# (docs/research/editor_ui_parity.md §2).
	var vertical := split != null and split.vertical
	_split_btn.icon = _editor_icon("Panels2Alt" if vertical else "Panels2")


func _update_view_toggle() -> void:
	var list := _view_mode == View.LIST
	_view_toggle.button_pressed = list
	_view_toggle.icon = _editor_icon("FileThumbnail" if list else "FileList")
	_view_toggle.tooltip_text = ("Switch to tile view." if list
		else "Switch to list view.")
	# Null while _ready() runs: the controls are created after this call.
	if _list != null:
		_list.visible = list
	if _scroll != null:
		_scroll.visible = not list


## Editor settings helpers — assets2godot/* values registered by the
## plugin; a missing setting falls back to the given default.
func _setting(key: String, fallback: Variant) -> Variant:
	var es := EditorInterface.get_editor_settings()
	if es and es.has_setting(key):
		return es.get_setting(key)
	return fallback


func _set_setting(key: String, value: Variant) -> void:
	var es := EditorInterface.get_editor_settings()
	if es:
		es.set_setting(key, value)


func _editor_icon(icon_name: StringName) -> Texture2D:
	var theme := EditorInterface.get_editor_theme()
	if theme and theme.has_icon(icon_name, &"EditorIcons"):
		return theme.get_icon(icon_name, &"EditorIcons")
	return null


## Preview matchmaking: asset packs ship a curated preview image next to
## each model (same directory, same basename — "chair.glb" + "chair.png").
## Those images become the asset's thumbnail instead of appearing as
## separate texture cards.
func _match_previews() -> void:
	_preview_map = {}
	var by_stem := {}
	for a in _assets:
		var stem := str(a.get("path", "")).get_basename()
		if stem == "":
			continue
		by_stem.get_or_add(stem, []).append(a)
	for stem in by_stem:
		var img := ""
		var has_non_image := false
		for a in by_stem[stem]:
			var p := str(a.get("path", ""))
			if _is_image(p):
				if img == "":
					img = p
			else:
				has_non_image = true
		if has_non_image and img != "":
			_preview_map[stem] = img


func _is_image(path: String) -> bool:
	return path.get_extension().to_lower() in A2GThumbs.IMAGE_EXTS


## Recomputes card width so each row fills the scroll view (gallery.gd math).
func _update_columns() -> void:
	if _scroll != null and _grid != null:
		A2GUI.update_columns(_scroll, _grid, _border)


## Files under res:// get the editor's own previews; everything else goes
## through the A2G thumbnail renderer, which loads and renders them itself.
func _queue_preview(path: String, card: Control) -> void:
	# A claimed sibling preview image wins over any generated thumbnail —
	# it is the asset pack's intended presentation.
	var stem := path.get_basename()
	if _preview_map.has(stem) and not _is_image(path):
		if _thumbs != null:
			_thumbs.request(card, _preview_map[stem])
		return
	var res_path := ""
	if path.begins_with("res://"):
		res_path = path
	else:
		var proj := ProjectSettings.globalize_path("res://")
		if path.begins_with(proj):
			res_path = "res://" + path.substr(proj.length())
	if res_path != "":
		var previewer := EditorInterface.get_resource_previewer()
		if previewer != null:
			previewer.queue_resource_preview(res_path, self, "_on_preview", card)
	elif _thumbs != null:
		_thumbs.request(card, path)


## A2GThumbs rendered a thumbnail for a file outside res://. The payload
## card may be a freed one from before a rebuild — guard before touching.
func _on_rendered(card, texture: Texture2D) -> void:
	if is_instance_valid(card):
		A2GUI.set_card_thumb(card, texture)


func _on_preview(_path: String, preview: Texture2D, thumbnail_preview: Texture2D, card) -> void:
	if not is_instance_valid(card):
		return
	var tex: Texture2D = preview if preview else thumbnail_preview
	if tex:
		A2GUI.set_card_thumb(card, tex)


## Rebuilds the filter dropdowns from the result set, preserving selections.
func _refill_filters() -> void:
	_refill(_provider_filter, _field_values("provider"))
	_refill(_kind_filter, _field_values("kind"))


func _field_values(field: String) -> Array:
	var seen := {}
	for a in _assets:
		seen[a.get(field, "")] = true
	var out := seen.keys()
	out.sort()
	return out


func _refill(box: OptionButton, values: Array) -> void:
	var prev: String = box.get_item_text(box.selected) if box.selected >= 0 else "All"
	box.clear()
	box.add_item("All")
	var idx := 0
	for v in values:
		if v == "":
			continue
		box.add_item(str(v))
		if str(v) == prev:
			idx = box.item_count - 1
	box.selected = idx
