@tool
extends PanelContainer
## The Polyhaven tab: browse polyhaven.com's public CC0 catalog — no API
## key, no Client needed — and download into a local folder. Downloads
## into a local_dir root land in the A2G index on the next scan; the card
## menu stages files into res:// like any other external asset.

const Icons = preload("res://addons/assets2godot/ui/icons.gd")
const A2GUI = preload("res://addons/assets2godot/a2g/a2g_ui.gd")
const PhApi = preload("res://addons/assets2godot/a2g/polyhaven_api.gd")

## Editor setting holding the absolute download target dir. "" = auto:
## a local_dir root named like *polyhaven*, else <download_dir>/polyhaven.
const SETTING_DIR := "assets2godot/polyhaven_dir"
## Rendered-cards cap: the API returns whole type lists (~1k each);
## sorted by download_count the cap keeps the popular end.
const PAGE_MAX := 500
const THUMB_PARALLEL := 4

var plugin: EditorPlugin

var _search: LineEdit
var _type: OptionButton
var _sort_btn: OptionButton
var _cat_btn: OptionButton
var _refresh_btn: Button
var _target_btn: Button
var _status: Label
var _scroll: ScrollContainer
var _border: PanelContainer
var _grid: GridContainer
var _empty: Label
var _dlg: ConfirmationDialog
var _dlg_options: OptionButton
var _dlg_label: Label
var _file_dlg: EditorFileDialog

var _assets: Array = []
var _cache := {}
var _cards := {}
var _thumb_cache := {}
var _thumb_queue: Array = []
var _thumb_active := 0
var _cats := {}
var _res_hint := "2k"
var _local_roots := []
var _roots_fetched := false
var _dl_asset: Dictionary = {}
var _dl_files: Array = []
var _dl_queue: Array = []
var _dl_dest := ""
var _dl_req: HTTPRequest
var _dl_done := {}


func _ready() -> void:
	add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	add_child(vbox)

	var tbar := HBoxContainer.new()
	vbox.add_child(tbar)
	_search = LineEdit.new()
	_search.placeholder_text = "Search Polyhaven (ENTER to search)"
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_submitted.connect(func(_q): _rebuild())
	tbar.add_child(_search)
	# SearchRow ends like BlendKit's: VSeparator + icon buttons, no text.
	tbar.add_child(VSeparator.new())
	_refresh_btn = Button.new()
	_refresh_btn.icon = _editor_icon("Reload")
	if _refresh_btn.icon == null:
		_refresh_btn.text = "Refresh"
	_refresh_btn.theme_type_variation = "FlatButton"
	_refresh_btn.tooltip_text = "Reload the Polyhaven catalog."
	_refresh_btn.pressed.connect(_reload)
	tbar.add_child(_refresh_btn)
	_target_btn = Button.new()
	_target_btn.icon = _editor_icon("Folder")
	_target_btn.theme_type_variation = "FlatButton"
	_target_btn.tooltip_text = "Download target folder…"
	_target_btn.pressed.connect(_pick_target)
	tbar.add_child(_target_btn)

	# FilterRow mirroring BlendKit: an HFlowContainer of Label+Option HBox
	# groups (Sort/Type/Category — plus Resolution, Polyhaven's honest
	# equivalent of BK's "Format", preselecting the download dialog's res).
	var fbar := HFlowContainer.new()
	vbox.add_child(fbar)
	_sort_btn = _foption(fbar, "Sort:",
		"Catalog order — the site's own sort options, applied client-side.",
		PhApi.SORT_OPTIONS, func(_i):
		PhApi.sort_assets(_assets, str(_sort_btn.get_selected_metadata()))
		_rebuild())
	_type = _foption(fbar, "Type:", "Filter by asset type.", PhApi.TYPE_OPTIONS,
		func(_i): _reload())
	_cat_btn = _foption(fbar, "Category:",
		"Filter by category — the real taxonomy from api.polyhaven.com.", [],
		func(_i): _rebuild())
	# Same width discipline as BK's CategoryOption: never fit the longest
	# item's width — category names run long ("Natural Light (822)").
	_cat_btn.clip_text = true
	_cat_btn.fit_to_longest_item = false
	var res_btn := _foption(fbar, "Resolution:",
		"Preferred resolution, preselected in the download dialog.",
		[["1k", "1k"], ["2k", "2k"], ["4k", "4k"], ["8k", "8k"]], Callable())
	res_btn.item_selected.connect(func(i): _res_hint = str(res_btn.get_item_metadata(i)))
	res_btn.selected = 1
	# Status lives at the filter row's end — BlendKit keeps the SearchRow
	# text-free, its own messages sit inside the scroll body.
	_status = Label.new()
	_status.clip_text = true
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	fbar.add_child(_status)

	_scroll = A2GUI.make_scroll()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_border = A2GUI.make_scroll_border()
	_scroll.add_child(_border)
	_grid = A2GUI.make_grid()
	_border.add_child(_grid)
	vbox.add_child(_scroll)
	_scroll.resized.connect(func(): A2GUI.update_columns(_scroll, _grid, _border))

	_empty = Label.new()
	_empty.text = "No Polyhaven assets yet — check the type filter or the connection."
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.visible = false
	vbox.add_child(_empty)

	_dlg = ConfirmationDialog.new()
	var dvb := VBoxContainer.new()
	_dlg_label = Label.new()
	dvb.add_child(_dlg_label)
	_dlg_options = OptionButton.new()
	_dlg_options.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dvb.add_child(_dlg_options)
	_dlg.add_child(dvb)
	_dlg.confirmed.connect(_on_download_confirmed)
	add_child(_dlg)

	_file_dlg = EditorFileDialog.new()
	_file_dlg.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	_file_dlg.access = EditorFileDialog.ACCESS_FILESYSTEM
	_file_dlg.dir_selected.connect(func(dir):
		var es := EditorInterface.get_editor_settings()
		if es:
			es.set_setting(SETTING_DIR, dir)
		_status.text = "Download target: %s" % A2GUI.short_path(dir))
	add_child(_file_dlg)

	if plugin.connection:
		plugin.connection.connected.connect(_fetch_roots)
	_reload()


# MARK: catalog

func _fetch_url(url: String, cb: Callable) -> void:
	var req := HTTPRequest.new()
	req.timeout = 30.0
	add_child(req)
	req.request_completed.connect(func(_r, code, _h, body):
		req.queue_free()
		cb.call(body.get_string_from_utf8() if code == 200 else ""))
	if req.request(url) != OK:
		req.queue_free()
		plugin.log_warning("Polyhaven request failed to start: %s" % url)


func _reload() -> void:
	var slug := str(_type.get_selected_metadata()) if _type.selected >= 0 else ""
	var needed: Array = [slug] if slug != "" else ["models", "textures", "hdris"]
	var missing := needed.filter(func(t): return not _cache.has(t))
	if missing.is_empty():
		_merge_and_rebuild()
		return
	_status.text = "Loading Polyhaven %s…" % ", ".join(missing)
	var pending := [missing.size() * 2]
	for t in missing:
		_fetch_url(PhApi.assets_url(t), func(text):
			_cache[t] = PhApi.parse_assets(JSON.parse_string(text))
			pending[0] -= 1
			if pending[0] == 0:
				_merge_and_rebuild())
		_fetch_url(PhApi.categories_url(t), func(text):
			var d = JSON.parse_string(text)
			_cats[t] = d if d is Dictionary else {}
			pending[0] -= 1
			if pending[0] == 0:
				_merge_and_rebuild())


func _merge_and_rebuild() -> void:
	var slug := str(_type.get_selected_metadata()) if _type.selected >= 0 else ""
	var needed: Array = [slug] if slug != "" else ["models", "textures", "hdris"]
	var seen := {}
	_assets = []
	for t in needed:
		for a in _cache.get(t, []):
			var key := str(a.get("slug", ""))
			if seen.has(key):
				continue
			seen[key] = true
			_assets.append(a)
	PhApi.sort_assets(_assets, str(_sort_btn.get_selected_metadata()) if _sort_btn.selected >= 0 else "hot")
	_refill_categories()
	_rebuild()


func _refill_categories() -> void:
	var slug := str(_type.get_selected_metadata()) if _type.selected >= 0 else ""
	var needed: Array = [slug] if slug != "" else ["models", "textures", "hdris"]
	var dicts := []
	for t in needed:
		if _cats.has(t):
			dicts.append(_cats[t])
	var prev := str(_cat_btn.get_selected_metadata()) if _cat_btn.selected > 0 else ""
	_cat_btn.clear()
	_cat_btn.add_item("All")
	_cat_btn.set_item_metadata(0, "")
	var sel := 0
	for e in PhApi.merge_categories(dicts):
		var i := _cat_btn.item_count
		_cat_btn.add_item("%s (%d)" % [PhApi.category_label(e[0]), int(e[1])])
		_cat_btn.set_item_metadata(i, e[0])
		if e[0] == prev:
			sel = i
	_cat_btn.selected = sel


func _rebuild() -> void:
	for c in _grid.get_children():
		c.queue_free()
		_cards.clear()
		_thumb_queue.clear()
	var text := _search.text
	var cat := str(_cat_btn.get_selected_metadata()) if _cat_btn.selected > 0 else ""
	var shown := 0
	var matched := 0
	for a in _assets:
		if not PhApi.matches(a, text) or not PhApi.in_category(a, cat):
			continue
		matched += 1
		if shown >= PAGE_MAX:
			continue
		shown += 1
		var slug := str(a.get("slug", ""))
		var card: Control = A2GUI.asset_card(str(a.get("name", "?")), str(a.get("type", "")),
			"polyhaven", "", null, str(PhApi.TYPE_ICONS.get(a.get("type", ""), "File")),
			{"ph": true, "ph_slug": slug, "ph_url": PhApi.web_url(slug),
				"ph_download": Callable(self, "_on_card_download").bind(slug),
				"ph_dir": Callable(self, "_downloaded_dir").bind(slug)})
		card.connect("selected", func(_asset): _on_card_download(slug))
		_grid.add_child(card)
		_cards[slug] = card
		_queue_thumb(a)
	_empty.visible = matched == 0
	var total := _assets.size()
	if total == 0:
		_status.text = "Nothing loaded — offline or fetch failed."
	elif shown < matched:
		_status.text = "Showing %d of %d matches (%d catalog)" % [shown, matched, total]
	elif text.strip_edges() != "" or cat != "":
		_status.text = "%d matches of %d" % [matched, total]
	else:
		_status.text = "%d assets" % total
	A2GUI.update_columns(_scroll, _grid, _border)
	_fetch_roots()


func _asset_by_slug(slug: String) -> Dictionary:
	for a in _assets:
		if str(a.get("slug", "")) == slug:
			return a
	return {}


# MARK: thumbnails

func _queue_thumb(asset: Dictionary) -> void:
	var url := str(asset.get("thumbnail_url", ""))
	if url.is_empty():
		return
	var slug := str(asset.get("slug", ""))
	if _thumb_cache.has(url):
		var card: Control = _cards.get(slug)
		if is_instance_valid(card):
			card.call("set_thumb_texture", _thumb_cache[url])
		return
	_thumb_queue.append(asset)
	_pump_thumbs()


func _pump_thumbs() -> void:
	while _thumb_active < THUMB_PARALLEL and not _thumb_queue.is_empty():
		var a: Dictionary = _thumb_queue.pop_front()
		var url := str(a.get("thumbnail_url", ""))
		var slug := str(a.get("slug", ""))
		_thumb_active += 1
		var req := HTTPRequest.new()
		req.timeout = 15.0
		add_child(req)
		req.request_completed.connect(func(_r, code, _h, body):
			req.queue_free()
			_thumb_active -= 1
			if code == 200:
				var img := Image.new()
				var err := img.load_webp_from_buffer(body)
				if err != OK:
					err = img.load_png_from_buffer(body)
				if err != OK:
					img.load_jpg_from_buffer(body)
				if err == OK:
					var tex := ImageTexture.create_from_image(img)
					_thumb_cache[url] = tex
					var card: Control = _cards.get(slug)
					if is_instance_valid(card):
						card.call("set_thumb_texture", tex)
			_pump_thumbs())
		if req.request(url) != OK:
			req.queue_free()
			_thumb_active -= 1
			_pump_thumbs()


# MARK: download

func _on_card_download(slug: String) -> void:
	if _dl_req != null:
		_status.text = "A download is running — wait for it to finish."
		return
	var asset := _asset_by_slug(slug)
	if asset.is_empty():
		return
	_status.text = "Fetching files for %s…" % str(asset.get("name", slug))
	_fetch_url(PhApi.files_url(slug), func(text):
		var options := PhApi.flatten_files(JSON.parse_string(text))
		if options.is_empty():
			_status.text = "No downloadable files for %s" % str(asset.get("name", slug))
			return
		_dl_asset = asset
		_dl_files = options
		_dlg.title = "Download %s" % str(asset.get("name", slug))
		_dlg_label.text = "%s  ·  %s  ·  → %s" % [str(asset.get("name", slug)),
			str(asset.get("type", "")), A2GUI.short_path(_target_dir())]
		_dlg_options.clear()
		for i in options.size():
			_dlg_options.add_item(str(options[i].get("label", "?")), i)
			_dlg_options.set_item_metadata(i, options[i])
		_dlg_options.select(PhApi.pick_default(options, _res_hint))
		_dlg.popup_centered())


func _on_download_confirmed() -> void:
	var i := _dlg_options.selected
	if i < 0 or i >= _dl_files.size():
		return
	var option: Dictionary = _dl_files[i]
	var dir := _target_dir()
	if dir.is_empty():
		_status.text = "No download target — pick a folder via the toolbar button."
		return
	_dl_dest = dir.path_join(str(PhApi.TYPE_DIRS.get(_dl_asset.get("type", ""), "misc"))) \
		.path_join(str(_dl_asset.get("slug", "")))
	_dl_queue = [{"url": str(option.get("url", "")), "rel": PhApi.file_basename(str(option.get("url", "")))}]
	for rel in option.get("includes", {}):
		_dl_queue.append({"url": str(option["includes"][rel]), "rel": str(rel)})
	_dl_next()


func _dl_next() -> void:
	if _dl_queue.is_empty():
		_dl_finish()
		return
	var job: Dictionary = _dl_queue[0]
	var dest := _dl_dest.path_join(str(job.get("rel", "")))
	if FileAccess.file_exists(dest):
		_dl_queue.pop_front()
		_dl_next()
		return
	DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
	_dl_req = HTTPRequest.new()
	_dl_req.timeout = 300.0
	_dl_req.download_file = dest + ".part"
	add_child(_dl_req)
	_dl_req.request_completed.connect(func(result, code, _h, _b):
		var err := ""
		if result != HTTPRequest.RESULT_SUCCESS:
			err = "connection failed (%d)" % result
		elif code != 200:
			err = "HTTP %d" % code
		if err.is_empty() and DirAccess.rename_absolute(dest + ".part", dest) != OK:
			err = "rename failed"
		_dl_req.queue_free()
		_dl_req = null
		if not err.is_empty():
			_dl_queue.clear()
			set_process(false)
			_status.text = "Download failed (%s): %s" % [dest.get_file(), err]
			return
		_dl_queue.pop_front()
		_dl_next())
	if _dl_req.request(str(job.get("url", ""))) != OK:
		_dl_req.queue_free()
		_dl_req = null
		_dl_queue.pop_front()
		_dl_next()
		return
	set_process(true)


func _process(_delta: float) -> void:
	if _dl_req == null:
		set_process(false)
		return
	var total := _dl_req.get_body_size()
	var got := _dl_req.get_downloaded_bytes()
	var pct := "%d%%" % int(100.0 * got / total) if total > 0 else "…"
	_status.text = "Downloading %d file(s) left — %s (%s)" % [_dl_queue.size(), PhApi.short_size(got), pct]


func _dl_finish() -> void:
	set_process(false)
	var slug := str(_dl_asset.get("slug", ""))
	_dl_done[slug] = _dl_dest
	_status.text = "Downloaded %s → %s" % [str(_dl_asset.get("name", slug)), A2GUI.short_path(_dl_dest)]
	if _dl_dest.begins_with("res://"):
		EditorInterface.get_resource_filesystem().scan()
	elif _in_local_root(_dl_dest) and plugin.connection \
			and plugin.connection.is_client_connected():
		_post_client("providers/local_dir/scan", {})


# MARK: target dir + client

func _pick_target() -> void:
	_file_dlg.current_dir = _target_dir()
	_file_dlg.popup_centered_ratio(0.6)


## The download target: the editor setting, else a local_dir root named
## like *polyhaven*, else <download_dir>/polyhaven.
func _target_dir() -> String:
	var es := EditorInterface.get_editor_settings()
	if es and es.has_setting(SETTING_DIR):
		var dir := str(es.get_setting(SETTING_DIR))
		if not dir.is_empty():
			return dir
	for root in _local_roots:
		if str(root).get_file().to_lower().contains("polyhaven"):
			return str(root)
	return plugin.absolute_download_path.path_join("polyhaven")


func _downloaded_dir(slug: String) -> String:
	return str(_dl_done.get(slug, ""))


func _in_local_root(path: String) -> bool:
	var norm := path.replace("\\", "/")
	for root in _local_roots:
		var r := str(root).replace("\\", "/").rstrip("/")
		if norm == r or norm.begins_with(r + "/"):
			return true
	return false


func _fetch_roots() -> void:
	if _roots_fetched or not (plugin.connection and plugin.connection.is_client_connected()):
		return
	_roots_fetched = true
	_fetch_client("providers/local_dir/status", func(st):
		if st is Dictionary:
			for r in st.get("roots", []):
				if r.get("exists", false):
					_local_roots.append(str(r.get("path", ""))))


func _fetch_client(endpoint: String, cb: Callable) -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_r, code, _h, body):
		req.queue_free()
		cb.call(JSON.parse_string(body.get_string_from_utf8()) if code == 200 else null))
	if req.request(plugin.connection.client_url(endpoint)) != OK:
		req.queue_free()


func _post_client(endpoint: String, body: Dictionary) -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_a, _b, _c, _d): req.queue_free())
	if req.request(plugin.connection.client_url(endpoint),
			["Content-Type: application/json"], HTTPClient.METHOD_POST,
			JSON.stringify(body)) != OK:
		req.queue_free()


func _editor_icon(icon_name: StringName) -> Texture2D:
	var theme := EditorInterface.get_editor_theme()
	if theme and theme.has_icon(icon_name, &"EditorIcons"):
		return theme.get_icon(icon_name, &"EditorIcons")
	return null


## BlendKit's FilterRow unit: an HBox holding a caption Label next to an
## OptionButton, parented into the HFlow row. Returns the button.
func _foption(parent: Control, caption: String, tip: String,
		items: Array, on_selected: Callable) -> OptionButton:
	var h := HBoxContainer.new()
	var l := Label.new()
	l.text = caption
	h.add_child(l)
	var btn := OptionButton.new()
	btn.tooltip_text = tip
	for e in items:
		var i := btn.item_count
		btn.add_item(str(e[0]))
		btn.set_item_metadata(i, e[1])
	if on_selected.is_valid():
		btn.item_selected.connect(on_selected)
	h.add_child(btn)
	parent.add_child(h)
	return btn
