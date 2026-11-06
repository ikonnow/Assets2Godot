@tool
extends PanelContainer
## Assets: everything the project offers — all files under res:// PLUS the
## resources of the currently open scene (meshes, materials, textures that
## exist only inside the .tscn, e.g. primitive-mesh nodes). Rendered with
## the same gallery-style cards as the unified browser.

const Icons = preload("res://addons/assets2godot/ui/icons.gd")
const A2GUI = preload("res://addons/assets2godot/a2g/a2g_ui.gd")

const MAX_SCENE_RESOURCES := 300
const MAX_RES_DEPTH := 2

var plugin: EditorPlugin

var _search: LineEdit
var _include: OptionButton
var _refresh: Button
var _grid: HFlowContainer
var _empty: Label
var _icon: Texture2D
var _assets: Array = []
var _seen: Dictionary = {}


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
	var il := Label.new()
	il.text = "Include:"
	filter_row.add_child(il)
	_include = OptionButton.new()
	for label in ["All", "Project", "Scene"]:
		_include.add_item(label)
	_include.item_selected.connect(func(_i): _rebuild())
	filter_row.add_child(_include)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)
	_grid = HFlowContainer.new()
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(_grid)
	_empty = Label.new()
	_empty.text = "No assets found."
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_empty)

	_icon = Icons.render_svg(A2GUI.ICON_PATH, EditorInterface.get_editor_scale(), true)
	visibility_changed.connect(_on_visibility_changed)
	_collect()


## Re-collect when the tab becomes visible so scene edits show up.
func _on_visibility_changed() -> void:
	if visible and _grid != null:
		_collect()


## Rebuilds the asset list from both sources: project files and the
## resources referenced by the currently edited scene.
func _collect() -> void:
	_assets = []
	_seen = {}
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
		if _assets.size() >= MAX_SCENE_RESOURCES:
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
	if _seen.has(id) or depth > MAX_RES_DEPTH or _assets.size() >= MAX_SCENE_RESOURCES:
		return
	_seen[id] = true
	var title := res.resource_name
	if title == "":
		title = node.name if depth == 0 else "%s (%s)" % [prop, res.get_class()]
	_assets.append({
		"name": title,
		"kind": A2GUI.kind_for_resource(res),
		"type": res.get_class(),
		"source": "scene",
		"path": "%s:%s" % [node.get_path(), prop],
		"res": res,
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
	var inc_sel: String = _include.get_item_text(_include.selected) if _include.selected >= 0 else "All"
	var q := _search.text.to_lower()
	var shown := 0
	for a in _assets:
		if inc_sel == "Project" and a["source"] != "project":
			continue
		if inc_sel == "Scene" and a["source"] != "scene":
			continue
		if q != "" and not (str(a["name"]).to_lower().contains(q) or str(a["path"]).to_lower().contains(q)):
			continue
		var card := A2GUI.asset_card(a["name"], a["kind"], a["source"], a["path"], _icon, a["type"])
		_grid.add_child(card)
		_request_preview(a, card)
		shown += 1
	_empty.visible = shown == 0


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
	var tex: Texture2D = thumbnail_preview if thumbnail_preview else preview
	if tex:
		A2GUI.set_card_thumb(card, tex)
