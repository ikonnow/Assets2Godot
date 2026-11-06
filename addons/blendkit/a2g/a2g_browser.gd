@tool
extends PanelContainer
## The Assets2Godot browser: every indexed asset from every provider
## (local dirs, Fab vault — BlendKit downloads too once their folder is
## scanned), rendered gallery-style. Styled after ui/gallery: search row,
## filter row, scrollable card grid.

const Icons = preload("res://addons/blendkit/ui/icons.gd")
const ICON_PATH = "res://addons/blendkit/a2g/icon.svg"
const SEARCH_LIMIT = 500

var plugin: EditorPlugin

var _search: LineEdit
var _provider_filter: OptionButton
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
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)
	_grid = HFlowContainer.new()
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(_grid)
	_empty = Label.new()
	_empty.text = "No indexed assets yet.\nAdd folders and press Scan in the Local Assets tab."
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_empty)

	_icon = Icons.render_svg(ICON_PATH, EditorInterface.get_editor_scale(), true)
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
		_grid.add_child(_card(a))
		shown += 1
	_empty.visible = shown == 0


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


func _card(asset: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(170, 190)
	card.tooltip_text = "%s\n%s" % [asset.get("path", ""), asset.get("provider", "")]
	var vbox := VBoxContainer.new()
	card.add_child(vbox)
	# Kind-colored thumbnail placeholder with the A2G icon.
	var thumb := PanelContainer.new()
	thumb.custom_minimum_size = Vector2(0, 120)
	var style := StyleBoxFlat.new()
	style.bg_color = _kind_color(asset.get("kind", ""))
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	thumb.add_theme_stylebox_override("panel", style)
	var tex := TextureRect.new()
	tex.texture = _icon
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.custom_minimum_size = Vector2(48, 48)
	tex.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tex.size_flags_vertical = Control.SIZE_EXPAND_FILL
	thumb.add_child(tex)
	vbox.add_child(thumb)
	var name_label := Label.new()
	name_label.text = asset.get("name", "?")
	name_label.clip_text = true
	name_label.tooltip_text = name_label.text
	vbox.add_child(name_label)
	var meta := Label.new()
	meta.text = "%s · %s" % [asset.get("kind", "?"), asset.get("provider", "?")]
	meta.add_theme_font_size_override("font_size", 11)
	meta.modulate = Color(1, 1, 1, 0.6)
	vbox.add_child(meta)
	return card


func _kind_color(kind: String) -> Color:
	match kind:
		"model": return Color(0.22, 0.35, 0.55, 0.85)
		"texture": return Color(0.25, 0.5, 0.3, 0.85)
		"hdr": return Color(0.55, 0.4, 0.2, 0.85)
		"material": return Color(0.45, 0.3, 0.55, 0.85)
		"ue_asset": return Color(0.3, 0.3, 0.32, 0.9)
		"metadata": return Color(0.35, 0.35, 0.4, 0.7)
		_: return Color(0.3, 0.3, 0.34, 0.8)
