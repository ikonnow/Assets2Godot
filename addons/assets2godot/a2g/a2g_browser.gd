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

var plugin: EditorPlugin

var _search: LineEdit
var _provider_filter: OptionButton
var _kind_filter: OptionButton
var _refresh: Button
var _grid: GridContainer
var _scroll: ScrollContainer
var _empty: Label
var _icon: Texture2D
var _thumbs: Node
var _assets: Array = []


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

	# Scrollable card grid + empty state.
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.resized.connect(_update_columns)
	vbox.add_child(_scroll)
	_grid = A2GUI.make_grid()
	_scroll.add_child(_grid)
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
	_refill_filters()
	var provider_sel: String = _provider_filter.get_item_text(_provider_filter.selected) if _provider_filter.selected >= 0 else "All"
	var kind_sel: String = _kind_filter.get_item_text(_kind_filter.selected) if _kind_filter.selected >= 0 else "All"
	var shown := 0
	for a in _assets:
		if provider_sel != "All" and a.get("provider", "") != provider_sel:
			continue
		if kind_sel != "All" and a.get("kind", "") != kind_sel:
			continue
		var card := A2GUI.asset_card(a.get("name", "?"), a.get("kind", "?"),
			a.get("provider", "?"), a.get("path", ""), _icon, "",
			{"ext": str(a.get("path", "")).get_extension().to_lower()})
		_grid.add_child(card)
		_queue_preview(a.get("path", ""), card)
		shown += 1
	_empty.visible = shown == 0
	_update_columns()


## Recomputes card width so each row fills the scroll view (gallery.gd math).
func _update_columns() -> void:
	if _scroll != null and _grid != null:
		A2GUI.update_columns(_scroll, _grid)


## Files under res:// get the editor's own previews; everything else goes
## through the A2G thumbnail renderer, which loads and renders them itself.
func _queue_preview(path: String, card: Control) -> void:
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


## A2GThumbs rendered a thumbnail for a file outside res://.
func _on_rendered(card, texture: Texture2D) -> void:
	A2GUI.set_card_thumb(card, texture)


func _on_preview(_path: String, preview: Texture2D, thumbnail_preview: Texture2D, card) -> void:
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
