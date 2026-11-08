@tool
extends PanelContainer
## The Assets2Godot browser: every indexed asset from every provider
## (local dirs, Fab vault — BlendKit downloads too once their folder is
## scanned), rendered gallery-style. Styled after ui/gallery: search row,
## filter row, scrollable card grid.

const Icons = preload("res://addons/assets2godot/ui/icons.gd")
const A2GUI = preload("res://addons/assets2godot/a2g/a2g_ui.gd")
const A2GThumbs = preload("res://addons/assets2godot/a2g/a2g_thumbs.gd")
const A2GProjectView = preload("res://addons/assets2godot/a2g/a2g_project_view.tscn")
const A2GSceneAssets = preload("res://addons/assets2godot/a2g/a2g_scene_assets.gd")
const A2GDetails = preload("res://addons/assets2godot/a2g/a2g_details.gd")
const A2GImportDialog = preload("res://addons/assets2godot/a2g/a2g_import_dialog.gd")
const SEARCH_LIMIT = 500

## assets2godot/browser_display_mode editor setting: 0 = thumbnails, 1 = list.
const SETTING_VIEW := "assets2godot/browser_display_mode"
## assets2godot/browser_thumbnail_size: tile icon px at 1x editor scale.
const SETTING_THUMB := "assets2godot/browser_thumbnail_size"
## Two fixed tile sizes — the picker switches between them, no px slider.
const THUMB_TILE := 128
const THUMB_ICON := 48
## assets2godot/browser_sort editor setting — index into SORT_ITEMS.
const SETTING_SORT := "assets2godot/browser_sort"
## The FileSystem dock's own sort menu, item-for-item.
const SORT_ITEMS := [
	"Sort by Name (Ascending)",
	"Sort by Name (Descending)",
	"Sort by Type (Ascending)",
	"Sort by Type (Descending)",
	"Sort by Last Modified",
	"Sort by First Modified",
]
enum SortMode { NAME, NAME_REV, TYPE, TYPE_REV, MODIFIED, MODIFIED_REV }
enum View { GRID, LIST }
## The FileSystem dock's DisplayMode cycle for the split button:
## VSPLIT (stacked) → HSPLIT (side by side) → TREE_ONLY (Sources only).
enum SplitMode { VSPLIT, HSPLIT, TREE_ONLY }

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
var _sort_btn: MenuButton
var _sort_mode := SortMode.NAME
var _refresh: Button
var _view_btn: Button
var _list: ItemList
var _empty: Label
var _icon: Texture2D
var _thumbs: Node
var _assets: Array = []
var _preview_map := {}
var _view_mode := View.GRID
var _list_entries: Array = []
var _split_btn: Button
## Base tile column pitch (thumb * 1.5 * edscale) — _fit_columns widens
## the actual fixed_column_width so the last column ends at the field
## edge instead of leaving a dead strip.
var _base_col := 0
## Current split-mode state, mirroring the dock's DisplayMode.
var _split_mode := SplitMode.HSPLIT
## Per-orientation split positions — the dock keeps split_box_offset_v/_h
## separately so toggling restores the dragged position of that axis.
var _split_offset_h := 0
var _split_offset_v := 0
## Browser controls that hide in TREE_ONLY mode (split button stays).
var _browser_toolbar_controls: Array[Control] = []
## The downloaded-to-project surface: the gallery's real ProjectView inside
## the same Scroll → Border chrome, swapped in when the Sources tree's
## "Downloaded to project" row is selected.
var _dl_scroll: ScrollContainer
var _dl_border: PanelContainer
var _dl_view: VBoxContainer
var _dl_active := false
var _dl_fit_queued := false
## The folded-in Assets surface (project files + open-scene resources):
## the same A2GSceneAssets panel that used to be a main tab, swapped in
## when a Sources "Project" row selects view mode "project"/"scene".
var _sa_view: PanelContainer
var _sa_mode := &""
## A Sources-tree row's filter wish {provider, root} — applied to the
## provider dropdown once _refill_provider has an item carrying it.
var _wanted_source := {}
## The single detail popup every tile click raises — one instance,
## re-shown like the provider tabs' asset_details.
var _details: AcceptDialog
## Batch-import dialog for the multi-selection and the popup's own
## "Import into project" action.
var _import_dialog: ConfirmationDialog
var _import_btn: Button
## The SplitContainer this browser shares with the Sources dock — set by
## the plugin so the toolbar's split-mode button flips its orientation.
var split: SplitContainer:
	set(value):
		split = value
		if split:
			split.dragged.connect(_on_split_dragged)
## Where the toolbar controls go. The plugin hands the tab-level toolbar
## row so the panel itself can shrink to the ItemList's minimum — the
## FileSystem dock's own toolbar spans the whole dock, it isn't inside
## the file panel. Standalone use falls back to a row on top of the panel.
var toolbar_parent: Container


func _ready() -> void:
	# No panel frame at all — the native file list has zero margin around
	# it and the ItemListSecondary background IS the boundary. The fields
	# must reach the split edge exactly.
	add_theme_stylebox_override("panel", StyleBoxEmpty.new())
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
	# A manual pick drops a Sources row's pending filter wish — the user
	# overrode what the tree wanted.
	_provider_filter.item_selected.connect(func(_i): _wanted_source = {}; _rebuild())
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
	# View cycle — one button walking the three display modes (Tiles →
	# small icons → List), each with the editor's own mode icon like the
	# FileDialog's display-mode button.
	_view_btn = Button.new()
	_view_btn.name = "A2GViewMode"
	_view_btn.theme_type_variation = "FlatButton"
	_view_btn.pressed.connect(_cycle_view)
	host.add_child(_view_btn)
	_view_mode = _setting(SETTING_VIEW, View.GRID)
	# Sort — the FS dock's own radio-check menu, icon-only button sitting
	# with the display-mode buttons at the toolbar's right end.
	_sort_mode = int(_setting(SETTING_SORT, SortMode.NAME))
	_sort_btn = MenuButton.new()
	_sort_btn.theme_type_variation = "FlatButton"
	_sort_btn.icon = _editor_icon("Sort")
	if _sort_btn.icon == null:
		_sort_btn.text = "Sort"
	_sort_btn.tooltip_text = "Sort the file view — same options as the FileSystem dock."
	var sort_popup := _sort_btn.get_popup()
	for i in SORT_ITEMS.size():
		sort_popup.add_radio_check_item(SORT_ITEMS[i], i)
	sort_popup.id_pressed.connect(_on_sort_selected)
	_update_sort_checks()
	host.add_child(_sort_btn)
	# Split-mode toggle — the FS dock puts display_mode at the right end of
	# the file panel's toolbar, not on the tree side.
	_split_btn = Button.new()
	_split_btn.theme_type_variation = "FlatButton"
	_split_btn.tooltip_text = "Change split mode — sources left/right or top/bottom."
	_split_btn.pressed.connect(_toggle_split)
	host.add_child(_split_btn)
	# Batch import — enabled when the multi-selection holds external
	# files; opens the import-options dialog (staging + .import params).
	_import_btn = Button.new()
	_import_btn.icon = _editor_icon("Import")
	_import_btn.theme_type_variation = "FlatButton"
	_import_btn.tooltip_text = "Import the selected files into the project (import options included)."
	_import_btn.disabled = true
	_import_btn.pressed.connect(_import_selection)
	host.add_child(_import_btn)
	_browser_toolbar_controls = [_search, _provider_filter, _kind_filter, _sort_btn, _refresh, _view_btn, _import_btn]
	_split_offset_h = int(340 * EditorInterface.get_editor_scale())
	_split_offset_v = _split_offset_h
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
	# Ctrl/Shift multi-select like the FileSystem dock — plain click
	# still opens the detail popup, selection-clicks don't.
	_list.select_mode = ItemList.SELECT_MULTI
	_list.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_list.item_clicked.connect(_on_list_item_clicked)
	_list.item_activated.connect(_on_list_item_activated)
	_list.multi_selected.connect(func(_i, _s): _update_import_btn())
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_list)
	# The grid fills edge to edge: columns stretch by a few px so no dead
	# strip remains next to the scrollbar. Re-fit on width changes and
	# whenever the scrollbar appears/disappears.
	_list.resized.connect(_fit_columns)
	_list.get_v_scroll_bar().visibility_changed.connect(_fit_columns)
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
	# The downloaded-to-project surface in the gallery's own chrome:
	# Scroll (Tree-panel stylebox, never a horizontal bar) → Border (the
	# 15/0/35/15 content margins) → the real ProjectView subtree.
	_dl_scroll = A2GUI.make_scroll()
	_dl_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_dl_scroll.visible = false
	vbox.add_child(_dl_scroll)
	_dl_border = A2GUI.make_scroll_border()
	_dl_scroll.add_child(_dl_border)
	_dl_view = A2GProjectView.instantiate()
	_dl_border.add_child(_dl_view)
	_dl_scroll.resized.connect(_queue_dl_fit)
	_dl_scroll.get_v_scroll_bar().visibility_changed.connect(_queue_dl_fit)
	# setup() needs the BlendKit tab's Downloads model, which the gallery
	# builds in its own _ready — ours ran first, so wire it a frame later.
	call_deferred("_wire_downloads_view")

	# The folded-in Assets surface — a self-contained panel with its own
	# filter rows, shown for the Sources' "project"/"scene" view modes.
	_sa_view = A2GSceneAssets.new()
	_sa_view.plugin = plugin
	_sa_view.visible = false
	# Like _dl_scroll above: without expand the embedded panel keeps only
	# its minimum height and clips the card grid to a strip.
	_sa_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_sa_view)

	_details = A2GDetails.new()
	_details.import_requested.connect(_import_entries)
	add_child(_details)
	_import_dialog = A2GImportDialog.new()
	add_child(_import_dialog)

	_icon = Icons.render_svg(A2GUI.ICON_PATH, EditorInterface.get_editor_scale(), true)
	_thumbs = A2GThumbs.new()
	_thumbs.rendered.connect(_on_rendered)
	_thumbs.failed.connect(_on_thumbs_failed)
	add_child(_thumbs)
	if plugin.connection:
		plugin.connection.connected.connect(_reload)
	_update_state()


func _update_state() -> void:
	var connected: bool = plugin.connection != null and plugin.connection.is_client_connected()
	_refresh.disabled = not connected
	_search.editable = connected


# MARK: downloaded-to-project surface — the upstream ProjectView hosted in
# this pane, sharing the BlendKit tab's Downloads model and asset index so
# download progress tiles, lookups and thumbnails match it exactly.

func _wire_downloads_view() -> void:
	var gallery: Node = plugin.gallery
	if gallery == null or _dl_view == null:
		return
	_dl_view.setup(gallery)
	# One shared ProjectAssets index between both project views — lookup
	# results and copied thumbnails land in the same store whichever view
	# shows. downloads.index stays the gallery's own (upstream semantics).
	_dl_view.project = gallery.project_view.project
	gallery.downloads.index = gallery.project_view.project
	_dl_view.get_node("%BrowseButton").pressed.connect(_on_dl_browse)
	_dl_view.grid.sort_children.connect(_queue_dl_fit)


## "Browse Blendkit" — the upstream button returns to the search surface;
## here that means switching to the BlendKit tab in search mode.
func _on_dl_browse() -> void:
	var gallery: Control = plugin.gallery
	if gallery == null:
		return
	plugin.select_provider(gallery)
	gallery.project_toggle.button_pressed = false


## Sources-tree driven pane swap: the indexed browser vs the downloaded
## assets surface. The index toolbar controls belong to the browser and
## hide with it, like upstream's filter row in project mode.
func show_view_mode(mode: StringName, provider := "", root := "") -> void:
	# A Sources row narrows the browser: provider/root go through the
	# same dropdown filter a manual pick would set.
	if mode == &"browser":
		_wanted_source = {"provider": provider, "root": root}
		_apply_source_filter()
	_dl_active = mode == &"downloads" and _dl_scroll != null
	_sa_mode = mode if mode in [&"project", &"scene"] and _sa_view != null else &""
	if _dl_scroll != null:
		_dl_scroll.visible = _dl_active
	if _sa_view != null:
		_sa_view.visible = _sa_mode != &""
		if _sa_mode != &"":
			_sa_view.set_source(_sa_mode)
	_list.visible = not _dl_active and _sa_mode == &""
	_empty.visible = not _dl_active and _sa_mode == &"" and _list.item_count == 0
	_update_toolbar_visibility()
	# project is null until _wire_downloads_view ran — refresh would crash
	# on the unset index before that.
	if _dl_active and _dl_view.get("project") != null:
		_dl_view.refresh_if_shown()
		_queue_dl_fit()


## Selects the provider dropdown item matching _wanted_source — the
## tree row and the manual pick are the same filter by construction.
## Returns false while the dropdown can't express it (provider not in
## the result set yet); _refill_provider retries on every refill.
func _apply_source_filter() -> bool:
	if _wanted_source.is_empty():
		return false
	var want_root := str(_wanted_source.get("root", "")).replace("\\", "/").trim_suffix("/")
	for i in _provider_filter.item_count:
		var md: Variant = _provider_filter.get_item_metadata(i)
		if not md is Dictionary:
			continue
		var item_root := str(md.get("root", "")).replace("\\", "/").trim_suffix("/")
		if str(md.get("provider", "")) == str(_wanted_source.get("provider", "")) \
				and item_root == want_root:
			_wanted_source = {}
			if _provider_filter.selected != i:
				_provider_filter.select(i)
				_rebuild()
			return true
	return false


func _update_toolbar_visibility() -> void:
	var hide := _dl_active or _sa_mode != &"" or _split_mode == SplitMode.TREE_ONLY
	for c in _browser_toolbar_controls:
		c.visible = not hide


func _queue_dl_fit() -> void:
	if _dl_fit_queued:
		return
	_dl_fit_queued = true
	_apply_dl_fit.call_deferred()


## Our grid isn't covered by gallery.update_columns() — fit it to this
## pane's width with the same math (A2GUI.update_columns).
func _apply_dl_fit() -> void:
	_dl_fit_queued = false
	if _dl_view != null and _dl_view.is_visible_in_tree():
		A2GUI.update_columns(_dl_scroll, _dl_view.grid, _dl_border)


## Public refresh entry — the dock emits `scanned` into this after a scan
## finishes so the browser shows the new index without a manual search.
func refresh() -> void:
	_reload()


## Configured scan roots per provider — the Sources panel's roots,
## fetched alongside each search so the provider dropdown can offer them.
var _provider_roots := {}


## Fires a GET for [param endpoint] and calls [param cb] with the decoded
## JSON (or null on failure). Same shape as the dock's helper.
func _fetch(endpoint: String, cb: Callable) -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_result, code, _h, body):
		req.queue_free()
		cb.call(JSON.parse_string(body.get_string_from_utf8()) if code == 200 else null))
	var url: String = plugin.connection.client_url(endpoint)
	if req.request(url) != OK:
		req.queue_free()
		plugin.log_warning("A2G browser request failed to start: %s" % url)


func _reload() -> void:
	_update_state()
	if not (plugin.connection and plugin.connection.is_client_connected()):
		return
	_fetch("providers/search?limit=%d&q=%s" % [SEARCH_LIMIT, _search.text.uri_encode()], func(data):
		if data is Dictionary:
			_assets = data.get("results", [])
			_fetch_roots())


## Collect each local provider's configured roots, then rebuild. The
## pending-counter lambda pattern mirrors the dock's multi-fetch.
func _fetch_roots() -> void:
	var pending := [0]
	var roots := {}
	for pname in ["fab_vault", "local_dir"]:
		pending[0] += 1
		_fetch("providers/%s/status" % pname, func(st):
			pending[0] -= 1
			if st is Dictionary:
				var paths := []
				for r in st.get("roots", []):
					if r.get("exists", false):
						paths.append(str(r.get("path", "")))
				roots[pname] = paths
			if pending[0] == 0:
				_provider_roots = roots
				_rebuild())


func _rebuild() -> void:
	_list.clear()
	_list_entries.clear()
	_refill_filters()
	_sort_assets()
	_match_previews()
	var sel_md: Variant = _provider_filter.get_selected_metadata() if _provider_filter.selected > 0 else null
	var kind_sel: String = _kind_filter.get_item_text(_kind_filter.selected) if _kind_filter.selected >= 0 else "All"
	var shown := 0
	for a in _assets:
		var path := str(a.get("path", ""))
		var stem := path.get_basename()
		# Preview images claimed by a sibling asset are not own entries.
		if _preview_map.has(stem) and _is_image(path):
			continue
		# The provider dropdown mixes provider rows with their configured
		# roots — item metadata says which it is.
		if sel_md is Dictionary:
			var prov := str(sel_md.get("provider", ""))
			if prov != "" and a.get("provider", "") != prov:
				continue
			var root := str(sel_md.get("root", ""))
			if root != "" and not _path_in_root(path, root):
				continue
		if kind_sel != "All" and a.get("kind", "") != kind_sel:
			continue
		# Tile mode shows the plain name like the FS dock; list rows carry
		# kind + provider where the extra width is useful.
		var label := str(a.get("name", "?")) if _view_mode == View.GRID \
			else "%s  ·  %s  ·  %s" % [a.get("name", "?"), a.get("kind", "?"), a.get("provider", "?")]
		var idx := _list.add_item(label, _list_icon(str(a.get("kind", ""))))
		_list.set_item_tooltip(idx, "%s\n%s" % [path.get_file(), A2GUI.short_path(path)])
		var e := {"path": path, "kind": a.get("kind", ""),
			"provider": a.get("provider", ""),
			"ext": path.get_extension().to_lower()}
		e["details"] = _show_entry_details.bind(e)
		_list_entries.append(e)
		_queue_preview(path, {"idx": idx, "path": path})
		shown += 1
	_empty.visible = shown == 0 and not _dl_active
	# Rebuild drops the selection — the Import button follows.
	_update_import_btn()


## A plain left-click opens the detail popup like the provider tabs'
## cards do; Ctrl/Shift-click stays plain selection for multi-select,
## right-click opens the context menu (FileSystem-dock behavior).
func _on_list_item_clicked(index: int, _at: Vector2, mouse_button: int) -> void:
	if index >= _list_entries.size():
		return
	match mouse_button:
		MOUSE_BUTTON_LEFT:
			if not Input.is_key_pressed(KEY_CTRL) and not Input.is_key_pressed(KEY_SHIFT):
				_show_entry_details(_list_entries[index])
		MOUSE_BUTTON_RIGHT:
			A2GUI.asset_context_menu(_list_entries[index], _list)


## Double-click = the FileSystem dock's Open action. The click that
## started the double may have popped details — retract it.
func _on_list_item_activated(index: int) -> void:
	_details.hide()
	if index < _list_entries.size():
		A2GUI._open_entry(_list_entries[index])


func _show_entry_details(entry: Dictionary) -> void:
	var idx := _list_entries.find(entry)
	var thumb: Texture2D = _list.get_item_icon(idx) if idx >= 0 else null
	_details.show_asset(entry, thumb)


## Batch import entry — the details popup's "Import into project" and
## the toolbar's Import button both land here; the dialog collects the
## staged set, offers the importer's own options, and reports results.
func _import_entries(entries: Array) -> void:
	_import_dialog.open_for(entries)


func _import_selection() -> void:
	var entries := []
	for idx in _list.get_selected_items():
		if idx < _list_entries.size():
			entries.append(_list_entries[idx])
	_import_entries(entries)


## Import stays a file verb — enabled only while the selection holds at
## least one real external path.
func _update_import_btn() -> void:
	var ok := false
	for idx in _list.get_selected_items():
		if idx < _list_entries.size():
			var p := str(_list_entries[idx].get("path", ""))
			if p != "" and not p.begins_with("res://"):
				ok = true
				break
	_import_btn.disabled = not ok


func _list_icon(kind: String) -> Texture2D:
	var icon_name: StringName = LIST_ICONS.get(kind, "File")
	var theme := EditorInterface.get_editor_theme()
	if theme and theme.has_icon(icon_name, &"EditorIcons"):
		return theme.get_icon(icon_name, &"EditorIcons")
	return _icon


## One button, three display modes: Tiles → small icons → List — the
## FileDialog's display-mode button does the same cycle.
enum DispMode { TILES, ICONS, LIST }


func _disp_mode() -> DispMode:
	if _view_mode == View.LIST:
		return DispMode.LIST
	return DispMode.ICONS if _thumb_px() <= THUMB_ICON else DispMode.TILES


func _cycle_view() -> void:
	match _disp_mode():
		DispMode.TILES:
			_view_mode = View.GRID
			_set_setting(SETTING_THUMB, THUMB_ICON)
		DispMode.ICONS:
			_view_mode = View.LIST
		DispMode.LIST:
			_view_mode = View.GRID
			_set_setting(SETTING_THUMB, THUMB_TILE)
	_set_setting(SETTING_VIEW, _view_mode)
	_update_view_flags()
	_rebuild()


## The FileSystem dock's "Change Split Mode" — a three-state cycle, same
## as _change_split_mode(): VSPLIT → HSPLIT → TREE_ONLY → VSPLIT.
func _toggle_split() -> void:
	if split == null:
		return
	match _split_mode:
		SplitMode.VSPLIT:
			_split_mode = SplitMode.HSPLIT
		SplitMode.HSPLIT:
			_split_mode = SplitMode.TREE_ONLY
		SplitMode.TREE_ONLY:
			_split_mode = SplitMode.VSPLIT
	_apply_split_mode()


func _on_split_dragged(offset: int) -> void:
	if split.vertical:
		_split_offset_v = offset
	else:
		_split_offset_h = offset


## Applies the dock's DisplayMode: orientation + per-orientation offset,
## or the Sources-only view where the whole file panel hides.
func _apply_split_mode() -> void:
	if split == null:
		return
	var tree_only := _split_mode == SplitMode.TREE_ONLY
	visible = not tree_only
	_update_toolbar_visibility()
	if not tree_only:
		split.vertical = _split_mode == SplitMode.VSPLIT
		split.split_offset = _split_offset_v if split.vertical else _split_offset_h
	_update_split_icon()


func _update_split_icon() -> void:
	if _split_btn == null:
		return
	# The dock's own icons per DisplayMode: Panels1 = tree only, Panels2 =
	# stacked (vertical split), Panels2Alt = side by side (horizontal).
	var icon_name := "Panels1" if _split_mode == SplitMode.TREE_ONLY \
		else ("Panels2" if _split_mode == SplitMode.VSPLIT else "Panels2Alt")
	_split_btn.icon = _editor_icon(icon_name)


## Applies the FileSystem dock's FILE_DISPLAY_* flags to the list for the
## current view mode: THUMBNAILS = top-icon tiles with real previews at
## fixed_icon_size, LIST = left-icon rows. Mirrors update_file_list_display_mode.
func _update_view_flags() -> void:
	var list := _view_mode == View.LIST
	if _view_btn != null:
		match _disp_mode():
			DispMode.TILES:
				_view_btn.icon = _editor_icon("FileBigThumbnail")
				if _view_btn.icon == null:
					_view_btn.icon = _editor_icon("FileThumbnail")
				_view_btn.tooltip_text = "Tiles view — click for small icons."
			DispMode.ICONS:
				_view_btn.icon = _editor_icon("FileMediumThumbnail")
				if _view_btn.icon == null:
					_view_btn.icon = _editor_icon("FileThumbnail")
				_view_btn.tooltip_text = "Small icons — click for list view."
			DispMode.LIST:
				_view_btn.icon = _editor_icon("FileList")
				_view_btn.tooltip_text = "List view — click for tiles."
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
		# thumbnail_size on first run). Column = icon + fixed edge gap —
		# at 64px that is exactly the dock's 96px (its 1.5x factor), but
		# unlike 1.5x it does not balloon at large sizes, so more columns
		# fit and _fit_columns has less to stretch.
		var thumb := _thumb_px()
		_list.icon_mode = ItemList.ICON_MODE_TOP
		_base_col = int((thumb + 32) * edscale)
		_list.fixed_column_width = _base_col
		_list.fixed_icon_size = Vector2i(int(thumb * edscale), int(thumb * edscale))
		_list.max_text_lines = 2
		_list.max_columns = 0
		_list.same_column_width = false
		_fit_columns()


## Column pitch: base (thumb*1.5) widened just enough that the last full
## column ends flush at the field edge — margins, h_separation and the
## live scrollbar width are subtracted like the list's own layout does.
func _fit_columns() -> void:
	if _list == null or _view_mode == View.LIST or _base_col <= 0:
		return
	var sb := _list.get_theme_stylebox("panel")
	var margins := 0.0
	if sb:
		margins = sb.content_margin_left + sb.content_margin_right
	var vsb := _list.get_v_scroll_bar()
	var sbw := vsb.size.x if vsb != null and vsb.visible else 0.0
	var h_sep: int = _list.get_theme_constant("h_separation")
	var avail := _list.size.x - margins - sbw
	if avail <= 0:
		return
	# ItemList cell pitch is fixed_col + h_sep for EVERY column including
	# the last — under-counting it makes the final column not fit and the
	# list drops to fewer columns, leaving a huge dead strip at the edge.
	var cols := maxi(1, int(floor(avail / float(_base_col + h_sep))))
	_list.fixed_column_width = clampi(int(floor(avail / cols) - h_sep),
		_base_col, int(_base_col * 1.5))


## Tile icon size in px at 1x scale: the user's pick, falling back to the
## FileSystem dock's own thumbnail_size so first run matches the dock.
func _thumb_px() -> int:
	return int(_setting(SETTING_THUMB, int(_setting("filesystem/file_dialog/thumbnail_size", 64))))


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


## Renderable types go through the A2G rig first: it produces the same
## preview as the native generators but at card size — the native queue
## is fixed at 64px and looks soft on the grid. Only when the rig finds
## nothing renderable (failed signal) does the native queue take over,
## for res:// and external .tres/.res alike. Audio keeps the native
## edited-preview waveform (no renderer of our own). Payload is
## {idx, path} of the list item.
const STAGED_EXTS := ["tres", "res", "tscn", "scn", "glb", "gltf", "fbx"]

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
	var previewer := EditorInterface.get_resource_previewer()
	var ext := path.get_extension().to_lower()
	if ext in ["wav", "mp3", "ogg"]:
		if previewer != null:
			var stream := _load_audio(ext, path)
			if stream != null:
				previewer.queue_edited_resource_preview(stream, self, "_on_preview", payload)
				return
	elif ext in STAGED_EXTS and _thumbs != null:
		# fallback carries the native-loadable path (res:// for project
		# files, abs for external .tres/.res) — _on_thumbs_failed uses it.
		payload["fallback"] = res_path if res_path != "" else ext in ["tres", "res"]
		_thumbs.request(payload, path)
		return
	elif res_path != "":
		if previewer != null:
			previewer.queue_resource_preview(res_path, self, "_on_preview", payload)
		return
	if _thumbs != null:
		_thumbs.request(payload, path)


func _load_audio(ext: String, path: String) -> AudioStream:
	match ext:
		"wav": return AudioStreamWAV.load_from_file(path)
		"mp3": return AudioStreamMP3.load_from_file(path)
		"ogg": return AudioStreamOggVorbis.load_from_file(path)
	return null


## A2GThumbs rendered a thumbnail for a file outside res://. Guard against
## stale payloads from before a rebuild: index bounds + path must match.
func _on_rendered(payload, texture: Texture2D) -> void:
	_set_item_thumb(payload, texture)


## The rig found nothing renderable — fall back to the native queue for
## the paths it can actually reach (res://, external .tres/.res).
func _on_thumbs_failed(payload, path: String) -> void:
	if not (payload is Dictionary):
		return
	var fb: Variant = payload.get("fallback")
	if fb == null or fb == false:
		return
	payload.erase("fallback")
	var previewer := EditorInterface.get_resource_previewer()
	if previewer == null:
		return
	if fb is String:
		previewer.queue_resource_preview(fb, self, "_on_preview", payload)
	elif path.get_extension().to_lower() in ["tres", "res"]:
		previewer.queue_resource_preview(path, self, "_on_preview", payload)


func _on_preview(_path: String, preview: Texture2D, thumbnail_preview: Texture2D, payload) -> void:
	var tex: Texture2D = preview if preview else thumbnail_preview
	if tex:
		_set_item_thumb(payload, tex)
	elif payload is Dictionary and payload.get("fallback") and _thumbs != null:
		# Null preview on a queued external .tres/.res — usually a
		# PackedScene .tres (resthumb-only generator) or a resource type
		# without a generator; the A2G renderer stages it instead.
		_thumbs.request(payload, str(payload.get("path", "")))


func _set_item_thumb(payload, texture: Texture2D) -> void:
	if not (payload is Dictionary) or _list == null:
		return
	var idx: int = payload.get("idx", -1)
	if idx < 0 or idx >= _list_entries.size() or _list_entries[idx].get("path") != payload.get("path"):
		return
	_list.set_item_icon(idx, texture)


## Rebuilds the filter dropdowns from the result set, preserving selections.
func _refill_filters() -> void:
	_refill_provider()
	_refill(_kind_filter, _field_values("kind"))


## Path inside a scan root? Separators normalize to "/" first — the index
## stores whatever the OS reported while roots come from settings.
func _path_in_root(path: String, root: String) -> bool:
	var p := path.replace("\\", "/")
	var r := root.replace("\\", "/").trim_suffix("/")
	return p == r or p.begins_with(r + "/")


## The provider dropdown: providers from the result set, each with its
## configured scan roots nested underneath — like picking a folder in
## the Sources tree narrows the file view. Metadata {provider[, root]}.
func _refill_provider() -> void:
	var prev: Variant = _provider_filter.get_selected_metadata() if _provider_filter.selected > 0 else null
	_provider_filter.clear()
	_provider_filter.add_item("All")
	_provider_filter.selected = 0
	for p in _field_values("provider"):
		if p == "":
			continue
		_provider_filter.add_item(str(p))
		var i := _provider_filter.item_count - 1
		_provider_filter.set_item_metadata(i, {"provider": p})
		if prev is Dictionary and prev.get("provider") == p and not prev.has("root"):
			_provider_filter.selected = i
		for r in _provider_roots.get(p, []):
			_provider_filter.add_item("  " + A2GUI.short_path(r))
			var j := _provider_filter.item_count - 1
			_provider_filter.set_item_metadata(j, {"provider": p, "root": r})
			_provider_filter.set_item_tooltip(j, r)
			if prev is Dictionary and prev.get("provider") == p and str(prev.get("root", "")) == r:
				_provider_filter.selected = j
	# A Sources row's filter wish pending since before this refill —
	# now the items exist to carry it.
	_apply_source_filter()


## Sort handlers — the dock sorts the file list itself; the search result
## order is just the index order, so we sort _assets before listing.
func _on_sort_selected(id: int) -> void:
	_sort_mode = id
	_set_setting(SETTING_SORT, _sort_mode)
	_update_sort_checks()
	_rebuild()


func _update_sort_checks() -> void:
	if _sort_btn == null:
		return
	var popup := _sort_btn.get_popup()
	for i in SORT_ITEMS.size():
		popup.set_item_checked(i, i == _sort_mode)


func _sort_assets() -> void:
	_assets.sort_custom(_sort_cmp)


func _sort_cmp(a: Dictionary, b: Dictionary) -> bool:
	match _sort_mode:
		SortMode.NAME, SortMode.NAME_REV:
			var c := str(a.get("name", "")).naturalnocasecmp_to(str(b.get("name", "")))
			return c < 0 if _sort_mode == SortMode.NAME else c > 0
		SortMode.TYPE, SortMode.TYPE_REV:
			var ka := "%s %s" % [a.get("kind", ""), a.get("name", "")]
			var kb := "%s %s" % [b.get("kind", ""), b.get("name", "")]
			var c := ka.naturalnocasecmp_to(kb)
			return c < 0 if _sort_mode == SortMode.TYPE else c > 0
		_:
			var c := int(a.get("mtime", 0)) - int(b.get("mtime", 0))
			return c > 0 if _sort_mode == SortMode.MODIFIED else c < 0


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
