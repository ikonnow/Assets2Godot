@tool
extends PanelContainer
## The Assets2Godot browser: every indexed asset from every provider
## (local dirs, Fab vault — BlendKit downloads too once their folder is
## scanned), rendered gallery-style. Styled after ui/gallery: search row,
## filter row, scrollable card grid.

const Icons = preload("res://addons/assets2godot/ui/icons.gd")
const A2GUI = preload("res://addons/assets2godot/a2g/a2g_ui.gd")
const A2GThumbs = preload("res://addons/assets2godot/a2g/a2g_thumbs.gd")
const SizeFilter = preload("res://addons/assets2godot/a2g/a2g_size_filter.gd")
const SEARCH_LIMIT = 500

## assets2godot/browser_display_mode editor setting: 0 = thumbnails, 1 = list.
const SETTING_VIEW := "assets2godot/browser_display_mode"
## assets2godot/browser_thumbnail_size: tile icon px at 1x editor scale.
const SETTING_THUMB := "assets2godot/browser_thumbnail_size"
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
var _list: ItemList
var _empty: Label
var _icon: Texture2D
var _thumbs: Node
var _size_filter: Button
var _assets: Array = []
var _preview_map := {}
var _view_mode := View.GRID
var _list_entries: Array = []
var _split_btn: Button
## The SplitContainer this browser shares with the Sources dock — set by
## the plugin so the toolbar's split-mode button flips its orientation.
var split: SplitContainer
## Where the toolbar controls go. The plugin hands the tab-level toolbar
## row so the panel itself can shrink to the ItemList's minimum — the
## FileSystem dock's own toolbar spans the whole dock, it isn't inside
## the file panel. Standalone use falls back to a row on top of the panel.
var toolbar_parent: Container


func _ready() -> void:
	# Thin the panel frame so the ItemListSecondary field nearly reaches
	# the split edge — the native file list has no outer margin around it.
	var sb: StyleBox = get_theme_stylebox("panel").duplicate()
	var edge := int(2 * EditorInterface.get_editor_scale())
	for m in ["content_margin_left", "content_margin_top", "content_margin_right", "content_margin_bottom"]:
		sb.set(m, edge)
	add_theme_stylebox_override("panel", sb)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	add_child(vbox)

	# Toolbar — host is the injected dock-wide row or a local fallback.
	var host: Container = toolbar_parent if toolbar_parent != null else HBoxContainer.new()
	if toolbar_parent == null:
		vbox.add_child(host)
	_search = LineEdit.new()
	_search.placeholder_text = "Search indexed assets (ENTER to search)"
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_submitted.connect(func(_q): _reload())
	host.add_child(_search)
	_provider_filter = OptionButton.new()
	_provider_filter.tooltip_text = "Filter by provider."
	_provider_filter.item_selected.connect(func(_i): _rebuild())
	host.add_child(_provider_filter)
	_kind_filter = OptionButton.new()
	_kind_filter.tooltip_text = "Filter by asset kind."
	_kind_filter.item_selected.connect(func(_i): _rebuild())
	host.add_child(_kind_filter)
	_refresh = Button.new()
	_refresh.icon = _editor_icon("Reload")
	if _refresh.icon == null:
		_refresh.text = "Refresh"
	_refresh.tooltip_text = "Reload the index."
	_refresh.theme_type_variation = "FlatButton"
	_refresh.pressed.connect(_reload)
	host.add_child(_refresh)
	# Grid/list toggle — the FileSystem dock's own mode icons.
	_view_toggle = Button.new()
	_view_toggle.theme_type_variation = "FlatButton"
	_view_toggle.toggle_mode = true
	_view_toggle.pressed.connect(_toggle_view)
	host.add_child(_view_toggle)
	_view_mode = _setting(SETTING_VIEW, View.GRID)
	# Tile-size picker — the gallery's Polygons-slider shape, one handle.
	_size_filter = SizeFilter.new()
	_size_filter.setup(_thumb_px())
	_size_filter.size_changed.connect(_on_thumb_size)
	host.add_child(_size_filter)
	# Split-mode toggle — the FS dock puts display_mode at the right end of
	# the file panel's toolbar, not on the tree side.
	_split_btn = Button.new()
	_split_btn.theme_type_variation = "FlatButton"
	_split_btn.tooltip_text = "Change split mode — sources left/right or top/bottom."
	_split_btn.pressed.connect(_toggle_split)
	host.add_child(_split_btn)
	_update_split_icon()

	# The FileSystem dock's file panel: one ItemListSecondary whose
	# icon_mode switches between the dock's two display modes —
	# FILE_DISPLAY_THUMBNAILS (ICON_MODE_TOP, fixed tiles, previews as
	# icons) and FILE_DISPLAY_LIST (ICON_MODE_LEFT, compact rows). It sits
	# directly in the panel — the native file list has zero margin around it.
	_list = ItemList.new()
	_list.theme_type_variation = "ItemListSecondary"
	# Right-click selects the row under the cursor before the context menu
	# opens — same as FileSystemTree's allow_rmb_select.
	_list.allow_rmb_select = true
	_list.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_list.item_clicked.connect(_on_list_item_clicked)
	_list.item_activated.connect(_on_list_item_activated)
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_list)
	_update_view_flags()
	_empty = Label.new()
	_empty.text = "No indexed assets yet.\nAdd folders and press Scan in the Sources panel."
	# Like the status line in the Sources dock: clipped text must not
	# widen the split panel's minimum width.
	_empty.clip_text = true
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
		var path := str(a.get("path", ""))
		# Tile mode shows the plain name like the FS dock; list rows carry
		# kind + provider where the extra width is useful.
		var label := str(a.get("name", "?")) if _view_mode == View.GRID \
			else "%s  ·  %s  ·  %s" % [a.get("name", "?"), a.get("kind", "?"), a.get("provider", "?")]
		var idx := _list.add_item(label, _list_icon(str(a.get("kind", ""))))
		_list.set_item_tooltip(idx, "%s\n%s" % [path.get_file(), A2GUI.short_path(path)])
		_list_entries.append({"path": path, "kind": a.get("kind", ""),
			"provider": a.get("provider", ""),
			"ext": path.get_extension().to_lower()})
		_queue_preview(path, {"idx": idx, "path": path})
		shown += 1
	_empty.visible = shown == 0


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
	_update_view_flags()
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


## Applies the FileSystem dock's FILE_DISPLAY_* flags to the list for the
## current view mode: THUMBNAILS = top-icon tiles with real previews at
## fixed_icon_size, LIST = left-icon rows. Mirrors update_file_list_display_mode.
func _update_view_flags() -> void:
	var list := _view_mode == View.LIST
	if _view_toggle != null:
		_view_toggle.button_pressed = list
		_view_toggle.icon = _editor_icon("FileThumbnail" if list else "FileList")
		_view_toggle.tooltip_text = ("Switch to tile view." if list
			else "Switch to list view.")
	if _list == null:
		return
	var edscale := EditorInterface.get_editor_scale()
	# Values measured against the live native FileSystemList — see
	# docs/research/editor_ui_parity.md §2 (FileSystemList display modes).
	if list:
		_list.icon_mode = ItemList.ICON_MODE_LEFT
		_list.fixed_column_width = 0
		_list.fixed_icon_size = Vector2i(int(16 * edscale), int(16 * edscale))
		_list.max_text_lines = 1
		_list.max_columns = 1
		_list.same_column_width = false
	else:
		# Tile size from the size picker (defaults to the dock's own
		# thumbnail_size on first run); columns are 1.5x like upstream.
		var thumb := _thumb_px()
		_list.icon_mode = ItemList.ICON_MODE_TOP
		_list.fixed_column_width = int(thumb * 1.5 * edscale)
		_list.fixed_icon_size = Vector2i(int(thumb * edscale), int(thumb * edscale))
		_list.max_text_lines = 2
		_list.max_columns = 0
		_list.same_column_width = false


## Tile icon size in px at 1x scale: the user's pick, falling back to the
## FileSystem dock's own thumbnail_size so first run matches the dock.
func _thumb_px() -> int:
	return int(_setting(SETTING_THUMB, int(_setting("filesystem/file_dialog/thumbnail_size", 64))))


func _on_thumb_size(px: int) -> void:
	_set_setting(SETTING_THUMB, px)
	_update_view_flags()


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


## Files under res:// get the editor's own previews — the same textures the
## FileSystem dock's tiles show; everything else goes through the A2G
## thumbnail renderer. The payload is {idx, path} of the list item.
func _queue_preview(path: String, payload: Dictionary) -> void:
	# A claimed sibling preview image wins over any generated thumbnail —
	# it is the asset pack's intended presentation.
	var stem := path.get_basename()
	if _preview_map.has(stem) and not _is_image(path):
		if _thumbs != null:
			_thumbs.request(payload, _preview_map[stem])
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
			previewer.queue_resource_preview(res_path, self, "_on_preview", payload)
	elif _thumbs != null:
		_thumbs.request(payload, path)


## A2GThumbs rendered a thumbnail for a file outside res://. Guard against
## stale payloads from before a rebuild: index bounds + path must match.
func _on_rendered(payload, texture: Texture2D) -> void:
	_set_item_thumb(payload, texture)


func _on_preview(_path: String, preview: Texture2D, thumbnail_preview: Texture2D, payload) -> void:
	var tex: Texture2D = preview if preview else thumbnail_preview
	if tex:
		_set_item_thumb(payload, tex)


func _set_item_thumb(payload, texture: Texture2D) -> void:
	if not (payload is Dictionary) or _list == null:
		return
	var idx: int = payload.get("idx", -1)
	if idx < 0 or idx >= _list_entries.size() or _list_entries[idx].get("path") != payload.get("path"):
		return
	_list.set_item_icon(idx, texture)


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
