@tool
extends PanelContainer
## Assets: everything the project offers — all files under res:// PLUS the
## resources of the currently open scene (meshes, materials, textures that
## exist only inside the .tscn, e.g. primitive-mesh nodes). Rendered with
## the same gallery-style cards as the unified browser.

const Icons = preload("res://addons/assets2godot/ui/icons.gd")
const A2GUI = preload("res://addons/assets2godot/a2g/a2g_ui.gd")
const A2GDetails = preload("res://addons/assets2godot/a2g/a2g_details.gd")
const A2GImportDialog = preload("res://addons/assets2godot/a2g/a2g_import_dialog.gd")

const DEFAULT_MAX_SCENE_RESOURCES := 300
const SETTING_SCENE_CAP := "assets2godot/scene_resource_cap"
const MAX_RES_DEPTH := 2

var plugin: EditorPlugin

## Kind groups for the Type dropdown — what reads as an asset vs file
## chaff. "Files" covers extensions/text/config/script content.
const TYPE_GROUPS := {
	"Models": ["model", "ue_asset"],
	"Materials": ["material"],
	"Textures": ["texture", "hdr"],
	"Scenes": ["scene_data", "resource", "animation"],
	"Audio": ["audio"],
	"Files": ["file", "metadata", "script"],
}

## File-format groups for the Format dropdown (project files only —
## scene resources have no file format and match "All").
const FORMAT_EXTS := {
	"glTF": ["gltf", "glb"],
	"FBX": ["fbx"],
	"OBJ": ["obj"],
	"USD": ["usd", "usda", "usdc", "usdz"],
	"Godot": ["tscn", "scn", "tres", "res"],
	"Images": ["png", "jpg", "jpeg", "tga", "tif", "tiff", "bmp", "webp", "svg", "exr", "hdr"],
	"Audio": ["wav", "ogg", "mp3", "flac"],
}

var _search: LineEdit
var _sort: OptionButton
var _dir: OptionButton
var _type: OptionButton
var _source: OptionButton
var _format: OptionButton
var _show_files: CheckBox
var _size_cache := {}
var _mtime_cache := {}
var _refresh: Button
var _grid: GridContainer
var _scroll: ScrollContainer
var _border: PanelContainer
var _empty: Label
var _icon: Texture2D
var _assets: Array = []
var _seen: Dictionary = {}
## Card clicks raise the same detail popup the browser list uses.
var _details: AcceptDialog
## External files stage through the same import dialog the browser owns.
var _import_dialog: ConfirmationDialog


func _ready() -> void:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	add_child(vbox)

	var search_row := HBoxContainer.new()
	vbox.add_child(search_row)
	_search = LineEdit.new()
	_search.placeholder_text = "Search assets (ENTER to search)"
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_submitted.connect(func(_q): _rebuild())
	search_row.add_child(_search)
	_refresh = Button.new()
	_refresh.text = "Refresh"
	_refresh.tooltip_text = "Rescan project files and the open scene."
	_refresh.theme_type_variation = "FlatButton"
	_refresh.pressed.connect(_collect)
	search_row.add_child(_refresh)

	var filter_row := HFlowContainer.new()
	vbox.add_child(filter_row)
	# Sort criteria mirror the Godot FileSystem dock's sort menu:
	# Name / Type / Last Modified / Size + a direction toggle.
	_sort = _filter_dropdown(filter_row, "Sort:", ["Name", "Type", "Last Modified", "Size"])
	_dir = OptionButton.new()
	_dir.add_item("Asc")
	_dir.add_item("Desc")
	_dir.selected = 0
	_dir.item_selected.connect(func(_i): _rebuild())
	filter_row.add_child(_dir)
	_type = _filter_dropdown(filter_row, "Type:", ["All", "Models", "Materials", "Textures", "Scenes", "Audio", "Files"])
	_source = _filter_dropdown(filter_row, "Source:", ["All", "Project", "Scene"])
	_format = _filter_dropdown(filter_row, "Format:", ["All", "glTF", "FBX", "OBJ", "USD", "Godot", "Images", "Audio"])
	_show_files = CheckBox.new()
	_show_files.text = "Show all files"
	_show_files.tooltip_text = "Also list text files, configs and scripts — kinds that have no visual preview."
	_show_files.button_pressed = _editor_setting("assets2godot/show_all_files", false)
	_show_files.toggled.connect(func(_on): _rebuild())
	filter_row.add_child(_show_files)

	# Same chrome as the BlendKit gallery: Margin(NoBorderAssetLib) → Scroll
	# → Border panel (empty stylebox, upstream's L15/T0/R35/B15 margins)
	# → Grid. The border lives INSIDE the scroll — identical to
	# gallery.tscn's LibraryMargin/Scroll/Border chain.
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
	_empty = Label.new()
	_empty.text = "No assets found."
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_empty)

	_icon = Icons.render_svg(A2GUI.ICON_PATH, EditorInterface.get_editor_scale(), true)
	_details = A2GDetails.new()
	_details.import_requested.connect(_import_entries)
	add_child(_details)
	_import_dialog = A2GImportDialog.new()
	add_child(_import_dialog)
	visibility_changed.connect(_on_visibility_changed)
	_collect()


## A labeled filter dropdown like the BlendKit toolbar's pairs.
func _filter_dropdown(row: HFlowContainer, label: String, items: Array) -> OptionButton:
	var l := Label.new()
	l.text = label
	row.add_child(l)
	var dd := OptionButton.new()
	for item in items:
		dd.add_item(item)
	dd.item_selected.connect(func(_i): _rebuild())
	row.add_child(dd)
	return dd


## Re-collect when the tab becomes visible so scene edits show up.
func _on_visibility_changed() -> void:
	if visible and _grid != null:
		_collect()


## Rebuilds the asset list from both sources: project files and the
## resources referenced by the currently edited scene.
func _collect() -> void:
	_assets = []
	_seen = {}
	_size_cache = {}
	_mtime_cache = {}
	_collect_project()
	_collect_scene()
	_rebuild()


func _collect_project() -> void:
	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return
	_walk_fs(efs.get_filesystem())


func _walk_fs(dir: EditorFileSystemDirectory) -> void:
	for i in dir.get_file_count():
		var fname := dir.get_file(i)
		_assets.append({
			"name": fname,
			"kind": A2GUI.kind_for_file(fname),
			"type": dir.get_file_type(i),
			"ext": fname.get_extension().to_lower(),
			"source": "project",
			"path": dir.get_file_path(i),
			"res": null,
		})
	for i in dir.get_subdir_count():
		_walk_fs(dir.get_subdir(i))


## Walks the edited scene's nodes and gathers every stored Resource —
## meshes, materials, textures, animations, embedded or standalone — plus
## their nested sub-resources (e.g. a material inside a mesh).
func _collect_scene() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	_walk_node(root)


func _walk_node(node: Node) -> void:
	for prop in node.get_property_list():
		if _assets.size() >= _max_resources():
			return
		if prop.get("type") != TYPE_OBJECT or not (prop.get("usage", 0) & PROPERTY_USAGE_STORAGE):
			continue
		var value: Variant = node.get(prop["name"])
		if value is Resource:
			_collect_resource(value, node, prop["name"], 0)
	for child in node.get_children():
		_walk_node(child)


func _collect_resource(res: Resource, node: Node, prop: String, depth: int) -> void:
	var id := res.get_instance_id()
	if _seen.has(id) or depth > MAX_RES_DEPTH or _assets.size() >= _max_resources():
		return
	_seen[id] = true
	var title := res.resource_name
	if title == "":
		title = node.name if depth == 0 else "%s (%s)" % [prop, res.get_class()]
	_assets.append({
		"name": title,
		"kind": A2GUI.kind_for_resource(res),
		"type": res.get_class(),
		"ext": "",
		"source": "scene",
		"path": "%s:%s" % [node.get_path(), prop],
		"res": res,
		"node": node,
	})
	for sub in res.get_property_list():
		if sub.get("type") != TYPE_OBJECT or not (sub.get("usage", 0) & PROPERTY_USAGE_STORAGE):
			continue
		var value: Variant = res.get(sub["name"])
		if value is Resource:
			_collect_resource(value, node, prop, depth + 1)


func _rebuild() -> void:
	for c in _grid.get_children():
		c.queue_free()
	var src_sel := _sel(_source, "All")
	var type_sel := _sel(_type, "All")
	var fmt_sel := _sel(_format, "All")
	var q := _search.text.to_lower()
	var list := _assets.duplicate()
	list.sort_custom(_sort_cmp.bind(_sel(_sort, "Name")))
	var shown := 0
	for a in list:
		if src_sel != "All" and a["source"] != src_sel.to_lower():
			continue
		if type_sel != "All" and a["kind"] not in TYPE_GROUPS.get(type_sel, []):
			continue
		if type_sel != "Files" and not _show_files.button_pressed and a["kind"] not in A2GUI.VISUAL_KINDS:
			continue
		if fmt_sel != "All" and a["ext"] not in FORMAT_EXTS.get(fmt_sel, []):
			continue
		if q != "" and not (str(a["name"]).to_lower().contains(q) or str(a["path"]).to_lower().contains(q)):
			continue
		var payload := {"name": a["name"], "path": a["path"], "kind": a["kind"],
			"source": a["source"], "type": a["type"], "ext": a["ext"],
			"res": a["res"], "node": a.get("node")}
		payload["details"] = _show_details.bind(payload)
		var card := A2GUI.asset_card(a["name"], a["kind"], a["source"], a["path"], _icon, a["type"],
			payload)
		card.selected.connect(func(_a): _show_details(payload, card.thumb.texture))
		_grid.add_child(card)
		_request_preview(a, card)
		shown += 1
	_empty.visible = shown == 0
	_update_columns()


func _show_details(payload: Dictionary, thumb: Texture2D = null) -> void:
	_details.show_asset(payload, thumb)


## External files stage through the same import dialog the browser
## uses; res:// payloads are filtered inside open_for.
func _import_entries(entries: Array) -> void:
	_import_dialog.open_for(entries)


## Picks the Source filter by name ("project"/"scene") — the Sources
## tree's Project rows drive it when this panel is an embedded view
## mode rather than a standalone tab.
func set_source(name: String) -> void:
	if _source == null:
		return
	for i in _source.item_count:
		if _source.get_item_text(i).to_lower() == name.to_lower():
			_source.select(i)
			_rebuild()
			return


func _sel(dd: OptionButton, fallback: String) -> String:
	return dd.get_item_text(dd.selected) if dd.selected >= 0 else fallback


## Sort comparators — same criteria set as the FileSystem dock menu.
## File size and mtime are resolved lazily and cached (0 for in-memory
## scene resources, so they group together at one end).
func _sort_cmp(a: Dictionary, b: Dictionary, mode: String) -> bool:
	var lt := false
	match mode:
		"Type":
			lt = str(a["type"]).naturalnocasecmp_to(str(b["type"])) < 0
		"Size":
			lt = _size_of(a) < _size_of(b)
		"Last Modified":
			lt = _mtime_of(a) < _mtime_of(b)
		_:
			lt = str(a["name"]).naturalnocasecmp_to(str(b["name"])) < 0
	return not lt if _dir != null and _dir.selected == 1 else lt


func _size_of(a: Dictionary) -> int:
	var path := str(a.get("path", ""))
	if not path.begins_with("res://"):
		return 0
	if _size_cache.has(path):
		return _size_cache[path]
	var size := 0
	var f := FileAccess.open(path, FileAccess.READ)
	if f != null:
		size = f.get_length()
		f.close()
	_size_cache[path] = size
	return size


func _mtime_of(a: Dictionary) -> int:
	var path := str(a.get("path", ""))
	if not path.begins_with("res://"):
		return 0
	if _mtime_cache.has(path):
		return _mtime_cache[path]
	var mtime := int(FileAccess.get_modified_time(path))
	_mtime_cache[path] = mtime
	return mtime


## Recomputes card width so each row fills the scroll view (gallery.gd math).
func _update_columns() -> void:
	if _scroll != null and _grid != null and _border != null:
		A2GUI.update_columns(_scroll, _grid, _border)


## File assets get a real thumbnail via the editor previewer; in-memory
## scene resources go through the edited-resource preview path — whatever
## has no preview generator keeps the kind-colored placeholder.
func _request_preview(a: Dictionary, card: Control) -> void:
	var previewer := EditorInterface.get_resource_previewer()
	if previewer == null:
		return
	if a["res"] is Resource:
		previewer.queue_edited_resource_preview(a["res"], self, "_on_preview", card)
	elif a["path"].begins_with("res://"):
		previewer.queue_resource_preview(a["path"], self, "_on_preview", card)


func _on_preview(_path: String, preview: Texture2D, thumbnail_preview: Texture2D, card) -> void:
	if not is_instance_valid(card):
		return
	var tex: Texture2D = preview if preview else thumbnail_preview
	if tex:
		A2GUI.set_card_thumb(card, tex)


## Settings → Assets2Godot → Scene resources cap bounds the scene walk.
func _max_resources() -> int:
	return int(_editor_setting(SETTING_SCENE_CAP, DEFAULT_MAX_SCENE_RESOURCES))


func _editor_setting(key: String, fallback: Variant) -> Variant:
	var es := EditorInterface.get_editor_settings()
	if es and es.has_setting(key):
		return es.get_setting(key)
	return fallback
