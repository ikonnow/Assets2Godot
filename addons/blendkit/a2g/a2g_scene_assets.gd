@tool
extends PanelContainer
## Scene Assets: the current project's own asset files (res://), gathered
## from the editor's file system and rendered with the same gallery-style
## cards as the unified browser. No client round-trip needed.

const Icons = preload("res://addons/blendkit/ui/icons.gd")
const A2GUI = preload("res://addons/blendkit/a2g/a2g_ui.gd")

var plugin: EditorPlugin

var _search: LineEdit
var _kind_filter: OptionButton
var _refresh: Button
var _grid: HFlowContainer
var _empty: Label
var _icon: Texture2D
var _assets: Array = []


func _ready() -> void:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	add_child(vbox)

	var search_row := HBoxContainer.new()
	vbox.add_child(search_row)
	_search = LineEdit.new()
	_search.placeholder_text = "Search project assets (ENTER to search)"
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_submitted.connect(func(_q): _rebuild())
	search_row.add_child(_search)
	_refresh = Button.new()
	_refresh.text = "Refresh"
	_refresh.tooltip_text = "Rescan the project's files."
	_refresh.theme_type_variation = "FlatButton"
	_refresh.pressed.connect(_collect)
	search_row.add_child(_refresh)

	var filter_row := HFlowContainer.new()
	vbox.add_child(filter_row)
	var kl := Label.new()
	kl.text = "Kind:"
	filter_row.add_child(kl)
	_kind_filter = OptionButton.new()
	_kind_filter.item_selected.connect(func(_i): _rebuild())
	filter_row.add_child(_kind_filter)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)
	_grid = HFlowContainer.new()
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(_grid)
	_empty = Label.new()
	_empty.text = "No asset files in this project."
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_empty)

	_icon = Icons.render_svg(A2GUI.ICON_PATH, EditorInterface.get_editor_scale(), true)
	_collect()


## Gathers classified asset files from the editor's resource filesystem.
func _collect() -> void:
	_assets = []
	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		_rebuild()
		return
	_walk(efs.get_filesystem())
	_rebuild()


func _walk(dir: EditorFileSystemDirectory) -> void:
	for i in dir.get_file_count():
		var fname := dir.get_file(i)
		var kind := A2GUI.kind_for(fname)
		if kind != "":
			_assets.append({
				"name": fname.get_basename(),
				"kind": kind,
				"path": dir.get_file_path(i),
			})
	for i in dir.get_subdir_count():
		_walk(dir.get_subdir(i))


func _rebuild() -> void:
	for c in _grid.get_children():
		c.queue_free()
	_refill_kinds()
	var kind_sel: String = _kind_filter.get_item_text(_kind_filter.selected) if _kind_filter.selected >= 0 else "All"
	var q := _search.text.to_lower()
	var shown := 0
	for a in _assets:
		if kind_sel != "All" and a["kind"] != kind_sel:
			continue
		if q != "" and not (str(a["name"]).to_lower().contains(q) or str(a["path"]).to_lower().contains(q)):
			continue
		_grid.add_child(A2GUI.asset_card(a["name"], a["kind"], "scene", a["path"], _icon))
		shown += 1
	_empty.visible = shown == 0


func _refill_kinds() -> void:
	var prev: String = _kind_filter.get_item_text(_kind_filter.selected) if _kind_filter.selected >= 0 else "All"
	_kind_filter.clear()
	_kind_filter.add_item("All")
	var seen := {}
	for a in _assets:
		seen[a["kind"]] = true
	var idx := 0
	for v in seen.keys():
		_kind_filter.add_item(str(v))
		if str(v) == prev:
			idx = _kind_filter.item_count - 1
	_kind_filter.selected = idx
