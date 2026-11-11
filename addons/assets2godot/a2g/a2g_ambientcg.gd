@tool
extends PanelContainer
## The ambientCG tab: browse ambientcg.com's public CC0 catalog — no API
## key, no Client needed — and download into a local folder. Downloads
## into a local_dir root land in the A2G index on the next scan.
##
## Divergences from the Polyhaven tab (a different API, not a bug):
## - The catalog is offset-paginated (limit 500): page 0 reveals
##   totalResults, the remaining pages fetch in parallel and merge.
## - Type AND Category filter server-side — assets carry no per-asset
##   category field, so picking a category refetches that subset. Text
##   search and sort stay client-side over the loaded facet.
## - Downloads are flat zip archives (+ plain sbsar/obj/exr files) served
##   through a 302 redirect HTTPRequest won't follow; zips get an
##   explicit extract step with traversal guards.

const Icons = preload("res://addons/assets2godot/ui/icons.gd")
const A2GUI = preload("res://addons/assets2godot/a2g/a2g_ui.gd")
const AcgApi = preload("res://addons/assets2godot/a2g/ambientcg_api.gd")
const Conversions = preload("res://addons/assets2godot/conversions.gd")
const AcgMenuButton = preload("res://addons/assets2godot/a2g/a2g_acg_menu_button.gd")
const AcgDetails = preload("res://addons/assets2godot/a2g/a2g_acg_details.gd")

## This provider's key in the plugin's PROVIDERS registry — tab switch,
## Sources row and downloads surface all share it.
const PROVIDER_KEY := "ambientcg"
## Editor setting holding the absolute download target dir. "" = auto:
## a local_dir root named like *ambientcg*, else res://Assets2Godot/ambientcg.
const SETTING_DIR := "assets2godot/ambientcg_dir"
## Rendered-cards cap: the full catalog is ~3k assets; the cap keeps the
## popular end (default sort) while PAGE_SIZE fetches stay cheap.
const PAGE_MAX := 500
const THUMB_PARALLEL := 4
## Redirect hops allowed on a download — ambientcg.com/get 302s once to
## acg-download.struffelproductions.com.
const MAX_REDIRECTS := 4
## Source formats skipped on zip extract: not importable in Godot, and a
## .blend under res:// makes the GUI editor pop its Blender-locate dialog
## during the filesystem scan — a native crash path.
## Source formats Godot can't import — they stay out of the project like
## BlendKit's, not just unimportable but useless there (.blend also
## triggers the editor's Blender-locate path during scan → crash).
const EXTRACT_SKIP_EXTS := ["blend", "usd", "usda", "usdc", "usdz", "mtlx"]

var plugin: EditorPlugin

## 0 connecting / 1 online / 2 unreachable — set from the catalog fetch
## results; drives the menu's "Catalog:" row, its status dot and the
## offline empty-state.
var catalog_state := 0
signal catalog_state_changed(state: int)

var _search: LineEdit
var _type: OptionButton
var _sort_btn: OptionButton
var _cat_btn: OptionButton
var _dl_toggle: Button
var _dl_badge: Label
var _dl_only := false
var _menu_btn: Button
var _status: Label
var _scroll: ScrollContainer
var _border: PanelContainer
var _grid: GridContainer
var _empty: Label
var _retry: Button
var _file_dlg: EditorFileDialog
var _details

var _assets: Array = []
## facet cache: "<type>|<category>" → full merged asset list. ambientCG
## assets lack a category field — the only honest category filter is the
## API's own parameter.
var _cache := {}
## In-flight facet fetches: key → {"assets":[], "seen":{}, "left":int,
## "type":String, "cat":String} — the facet they were started with, so a
## mid-flight filter change can't pollute the wrong cache bucket.
var _pages := {}
var _cards := {}
var _thumb_cache := {}
var _thumb_queue: Array = []
var _thumb_active := 0
var _cats: Array = []
var _cats_fetched := false
var _res_hint := "2K"
var _local_roots := []
var _roots_fetched := false
var _dl_asset: Dictionary = {}
var _dl_queue: Array = []
var _dl_dest := ""
var _dl_req: HTTPRequest
var _dl_done := {}
var _dl_zips: Array = []
## Byte accounting for the drop ghost's progress box: the queued
## option's total_size and the bytes of already-completed queue jobs —
## the live job adds _dl_req.get_downloaded_bytes() on top.
var _dl_total := 0
var _dl_done_bytes := 0
## Cards outside _cards that still want their slug's thumbnail — the A2G
## downloads surface's tiles, kept weak-ish by pruning in _push_thumb.
var _thumb_watchers := {}
## Synthesized asset dicts for downloaded slugs the catalog doesn't list —
## keeps details/state working for disk-only downloads.
var _dl_extra_assets := {}
var _converting := false
var _updating_theme := false


func _ready() -> void:
	var edscale := EditorInterface.get_editor_scale()
	var vbox := VBoxContainer.new()
	# Same row separation as BlendKit's Main VBox (10 * edscale there).
	vbox.add_theme_constant_override("separation", int(10 * edscale))
	add_child(vbox)

	var tbar := HBoxContainer.new()
	vbox.add_child(tbar)
	_search = LineEdit.new()
	_search.placeholder_text = "Search ambientCG (ENTER to search)"
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_submitted.connect(func(_q): _rebuild())
	tbar.add_child(_search)
	# SearchRow verbatim from BlendKit: SearchEdit | DownloadToggle |
	# VSeparator | MenuButton — one flat icon toggle in the ProjectToggle
	# slot (the AssetStore/AssetLib "download arrow"), then the menu.
	_dl_toggle = Button.new()
	_dl_toggle.theme_type_variation = "FlatButton"
	_dl_toggle.toggle_mode = true
	_dl_toggle.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_dl_toggle.toggled.connect(func(pressed): _dl_only = pressed; _rebuild())
	tbar.add_child(_dl_toggle)
	# The download badge on the toggle's top-right corner — same
	# construction as gallery.gd's _download_badge on ProjectToggle.
	_dl_badge = Label.new()
	_dl_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dl_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_dl_badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_dl_badge.custom_minimum_size = Vector2.ONE * roundf(16 * edscale)
	_dl_toggle.add_child(_dl_badge)
	_dl_badge.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_dl_badge.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	# Hang over the corner, clear of the icon.
	_dl_badge.offset_left = 5 * edscale
	_dl_badge.offset_right = 5 * edscale
	_dl_badge.offset_top = -4 * edscale
	_dl_badge.offset_bottom = -4 * edscale
	_update_dl_badge()
	tbar.add_child(VSeparator.new())
	_menu_btn = AcgMenuButton.new()
	# In-tree before setup: its refresh() resolves theme icons, which only
	# works once the button is inside the tree (BlendKit's button is a
	# scene node, so it has this for free).
	tbar.add_child(_menu_btn)
	_menu_btn.setup(plugin, self)

	# FilterRow mirroring BlendKit: an HFlowContainer of Label+Option HBox
	# groups (Sort/Type/Category — plus Resolution, ambientCG's honest
	# equivalent of BK's "Format", preselecting the download dialog's res).
	var fbar := HFlowContainer.new()
	vbox.add_child(fbar)
	_sort_btn = _foption(fbar, "Sort:",
		"Catalog order — the site's own sort options, applied client-side.",
		AcgApi.SORT_OPTIONS, func(_i):
		AcgApi.sort_assets(_assets, str(_sort_btn.get_selected_metadata()))
		_rebuild())
	_type = _foption(fbar, "Type:", "Filter by asset type — fetches the type's catalog.",
		AcgApi.TYPE_OPTIONS, func(_i): _reload())
	_cat_btn = _foption(fbar, "Category:",
		"Filter by category — the real taxonomy from ambientcg.com; the API filters it server-side.",
		[["All", ""]], func(_i): _reload())
	# Same width discipline as BK's CategoryOption: never fit the longest
	# item's width — category names run long ("Corrugated Steel (15)").
	_cat_btn.clip_text = true
	_cat_btn.fit_to_longest_item = false
	var res_btn := _foption(fbar, "Resolution:",
		"Preferred resolution, preselected in the download dialog.",
		[["1K", "1K"], ["2K", "2K"], ["4K", "4K"], ["8K", "8K"]], Callable())
	res_btn.item_selected.connect(func(i): _res_hint = str(res_btn.get_item_metadata(i)))
	res_btn.selected = 1
	# Status lives at the filter row's end — BlendKit keeps the SearchRow
	# text-free, its own messages sit inside the scroll body.
	_status = Label.new()
	_status.clip_text = true
	# Right-aligned + clip alone cuts the text's LEFT edge — ellipsis
	# marks the overflow instead of silently losing "Showing 5".
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	fbar.add_child(_status)

	var margin := A2GUI.make_library_margin()
	vbox.add_child(margin)
	_scroll = A2GUI.make_scroll()
	margin.add_child(_scroll)
	_border = A2GUI.make_scroll_border()
	_scroll.add_child(_border)
	_grid = A2GUI.make_grid()
	_border.add_child(_grid)
	_scroll.resized.connect(func(): A2GUI.update_columns(_scroll, _grid, _border))

	_empty = Label.new()
	_empty.text = "No ambientCG assets yet — check the type filter or the connection."
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.visible = false
	vbox.add_child(_empty)
	# BlendKit's MessageBox + Retry pattern for the offline state.
	_retry = Button.new()
	_retry.text = "Retry"
	_retry.theme_type_variation = "PanelBackgroundButton"
	_retry.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_retry.visible = false
	_retry.pressed.connect(reload_catalog)
	vbox.add_child(_retry)

	# The asset popup — a card click opens it like BlendKit's
	# asset_details; right-click keeps the quick-download tile.
	_details = AcgDetails.new()
	add_child(_details)
	_details.download_requested.connect(_start_download)
	_details.tag_selected.connect(func(t):
		_search.text = t
		_rebuild())

	_file_dlg = EditorFileDialog.new()
	_file_dlg.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	_file_dlg.access = EditorFileDialog.ACCESS_FILESYSTEM
	_file_dlg.dir_selected.connect(func(dir):
		var es := EditorInterface.get_editor_settings()
		if es:
			es.set_setting(SETTING_DIR, dir)
		_status.text = "Download target: %s" % A2GUI.short_path(dir))
	add_child(_file_dlg)

	_update_theme()
	if plugin.connection:
		plugin.connection.connected.connect(_fetch_roots)
	_fetch_categories()
	_reload()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_VISIBILITY_CHANGED:
			# VISIBILITY_CHANGED can arrive between ENTER_TREE and _ready —
			# _search does not exist yet then.
			if not plugin or not is_visible_in_tree() or _search == null:
				return
			# Like the Asset Store / BlendKit tab, typing goes straight to
			# the search when the tab shows.
			_search.grab_focus()
			# …and the catalog refetches when it never arrived — the tab
			# recovers on its own once the connection is back.
			if _assets.is_empty():
				_reload()
		NOTIFICATION_THEME_CHANGED:
			# Overriding own styles emits THEME_CHANGED again, hence the guard.
			if is_node_ready() and plugin and not _updating_theme:
				_updating_theme = true
				_update_theme()
				_updating_theme = false


## Theme-derived bits, refreshed on NOTIFICATION_THEME_CHANGED — the panel
## wears the AssetLib "bg" stylebox like BlendKit's gallery (its content
## margin gives the search row the inset) and the field carries the same
## Search right_icon.
func _update_theme() -> void:
	add_theme_stylebox_override("panel", get_theme_stylebox("bg", "AssetLib"))
	if _search:
		_search.right_icon = get_theme_icon("Search", "EditorIcons")
	if _dl_toggle:
		# AssetStore is the Godot 4.7+ name of AssetLib — gallery.gd:164.
		_dl_toggle.icon = get_theme_icon("AssetStore" if has_theme_icon("AssetStore", "EditorIcons") else "AssetLib", "EditorIcons")
		# Flat look, but the padding of a regular button like the menu button.
		_dl_toggle.custom_minimum_size.x = _dl_toggle.icon.get_width() + get_theme_stylebox("normal", "Button").get_minimum_size().x
		var edscale := EditorInterface.get_editor_scale()
		var badge_style := StyleBoxFlat.new()
		badge_style.bg_color = get_theme_color("accent_color", "Editor")
		badge_style.set_corner_radius_all(int(8 * edscale))
		# A ring in the background color keeps it apart from the pressed button.
		badge_style.set_border_width_all(maxi(1, int(2 * edscale)))
		badge_style.border_color = get_theme_color("base_color", "Editor")
		badge_style.content_margin_left = 3 * edscale
		badge_style.content_margin_right = 3 * edscale
		_dl_badge.add_theme_stylebox_override("normal", badge_style)
		_dl_badge.add_theme_color_override("font_color", get_theme_color("base_color", "Editor"))
		_dl_badge.add_theme_font_override("font", get_theme_font("bold", "EditorFonts"))
		_dl_badge.add_theme_font_size_override("font_size", int(10 * edscale))


# MARK: catalog

## Refetch the whole catalog — the menu's "Reload catalog" and the
## offline-state Retry both run through here.
func reload_catalog() -> void:
	# Provider switched off in the A2G menu — no catalog fetch while its
	# tab stays hidden; re-enabling reloads on first show.
	if plugin != null and not plugin.provider_enabled(PROVIDER_KEY):
		return
	_cache.clear()
	_cats.clear()
	_cats_fetched = false
	_fetch_categories()
	_reload()


func _set_catalog_state(s: int) -> void:
	if s == catalog_state:
		return
	catalog_state = s
	catalog_state_changed.emit(s)
	if _menu_btn:
		_menu_btn.refresh()


## Shared fetch for catalog + files. track_state marks the request as a
## catalog probe — only those feed the menu's status dot; a ?id= files
## failure must never flip the whole catalog red.
func _fetch_url(url: String, cb: Callable, track_state := false) -> void:
	var req := HTTPRequest.new()
	req.timeout = 60.0
	# Off the main thread — catalog pages run to ~6MB of JSON each.
	req.use_threads = true
	(plugin if plugin != null else self).add_child(req)
	req.request_completed.connect(func(_result, code, _h, body):
		req.queue_free()
		if track_state:
			_set_catalog_state(1 if code == 200 else 2)
		cb.call(body.get_string_from_utf8() if code == 200 else ""))
	if req.request(url, [AcgApi.UA_HEADER]) != OK:
		req.queue_free()
		if track_state:
			_set_catalog_state(2)
		plugin.log_warning("ambientCG request failed to start: %s" % url)


## The server's two facets — the selected type and category slugs.
func _facet_type() -> String:
	return str(_type.get_selected_metadata()) if _type.selected >= 0 else ""


func _facet_cat() -> String:
	return str(_cat_btn.get_selected_metadata()) if _cat_btn.selected > 0 else ""


func _facet_key() -> String:
	return "%s|%s" % [_facet_type(), _facet_cat()]


## The category taxonomy — one endpoint for all types, fetched once.
func _fetch_categories() -> void:
	if _cats_fetched:
		return
	_cats_fetched = true
	_fetch_url(AcgApi.categories_url(), func(text):
		_cats = AcgApi.parse_categories(JSON.parse_string(text))
		_refill_categories())


func _reload() -> void:
	if plugin != null and not plugin.provider_enabled(PROVIDER_KEY):
		return
	_refill_categories()
	var key := _facet_key()
	if _cache.has(key):
		_assets = _cache[key]
		_finish_load()
		return
	if _pages.has(key):
		return # this facet is already being fetched
	_status.text = "Loading ambientCG catalog…"
	_pages[key] = {"assets": [], "seen": {}, "left": 1,
		"type": _facet_type(), "cat": _facet_cat()}
	_fetch_url(AcgApi.assets_url(_facet_type(), _facet_cat(), 0),
		func(text): _on_catalog_page(key, 0, text), true)


## A catalog page arrived: page 0 reveals totalResults, so it also fires
## the remaining offsets in parallel — every page merges deduped assets
## into the facet bucket until the count is exhausted. The grid paints
## once on first content (cards + thumbs go live while pages still
## merge); intermediate pages only refresh the status line, the last
## page does the authoritative rebuild — a per-page rebuild frees and
## recreates up to 500 GalleryItems and resets the thumb queue each
## time.
func _on_catalog_page(key: String, offset: int, text: String) -> void:
	var st: Dictionary = _pages.get(key, {})
	if st.is_empty():
		return # superseded or done already
	var raw = JSON.parse_string(text)
	if not raw is Dictionary or not raw.has("assets"):
		# A failed page fails the facet fetch loudly — no silent partial
		# catalog claiming completeness.
		_pages.erase(key)
		if _facet_key() == key:
			_set_catalog_state(2)
			_rebuild()
		return
	var st_type := str(st.get("type", ""))
	var st_cat := str(st.get("cat", ""))
	var seen: Dictionary = st.get("seen", {})
	for a in AcgApi.parse_assets(raw):
		var slug := str(a.get("slug", ""))
		if slug.is_empty() or seen.has(slug):
			continue
		seen[slug] = true
		st["assets"].append(a)
	if key == _facet_key() and not st["assets"].is_empty():
		if _assets.is_empty():
			# First content: paint once. A per-page rebuild was the thumb
			# stall — 500 freed+recreated GalleryItems and a cleared thumb
			# queue on every one of the ~7 pages.
			_assets = st["assets"]
			_finish_load()
		elif int(st["left"]) > 1:
			_status.text = "Loading… %d / %d" % [st["assets"].size(),
				int(st.get("total", _assets.size()))]
	if offset == 0:
		st["total"] = AcgApi.parse_total(raw)
		for off in range(AcgApi.PAGE_SIZE, int(st["total"]), AcgApi.PAGE_SIZE):
			st["left"] += 1
			_fetch_url(AcgApi.assets_url(st_type, st_cat, off),
				func(t): _on_catalog_page(key, off, t), true)
	st["left"] -= 1
	if int(st["left"]) <= 0:
		_pages.erase(key)
		_cache[key] = st["assets"]
		if _facet_key() == key:
			_assets = _cache[key]
			_finish_load()


func _finish_load() -> void:
	AcgApi.sort_assets(_assets, str(_sort_btn.get_selected_metadata()) if _sort_btn.selected >= 0 else "popular")
	_rebuild()


## The category dropdown: "All" + the taxonomy entries matching the
## selected type, count-desc like the site's own category sidebar.
func _refill_categories() -> void:
	var type_slug := _facet_type()
	var prev := _facet_cat()
	var cats: Array = _cats.filter(func(c):
		return type_slug.is_empty() or str(c.get("type", "")) == type_slug)
	cats = cats.duplicate()
	cats.sort_custom(func(a, b):
		return str(a.get("title", "")) < str(b.get("title", "")) \
			if int(a.get("count", 0)) == int(b.get("count", 0)) \
			else int(a.get("count", 0)) > int(b.get("count", 0)))
	_cat_btn.clear()
	_cat_btn.add_item("All")
	_cat_btn.set_item_metadata(0, "")
	var sel := 0
	for c in cats:
		var i := _cat_btn.item_count
		_cat_btn.add_item("%s (%d)" % [str(c.get("title", c.get("id", ""))), int(c.get("count", 0))])
		_cat_btn.set_item_metadata(i, str(c.get("id", "")))
		if str(c.get("id", "")) == prev:
			sel = i
	_cat_btn.selected = sel


func _rebuild() -> void:
	for c in _grid.get_children():
		_grid.remove_child(c)
		c.queue_free()
	_cards.clear()
	_thumb_queue.clear()
	var text := _search.text
	var downloaded := _downloaded_slugs()
	var shown := 0
	var matched := 0
	for a in _assets:
		var slug := str(a.get("slug", ""))
		if not AcgApi.matches(a, text):
			continue
		if _dl_only and not downloaded.has(slug):
			continue
		matched += 1
		if shown >= PAGE_MAX:
			continue
		shown += 1
		var card := _make_card(a, downloaded.has(slug))
		_grid.add_child(card)
		# Register BEFORE queueing the thumb: a cached hit inside
		# _queue_thumb pushes synchronously through _cards — it must find
		# this card or the texture is dropped (thumbs fetched during the
		# catalog load hit exactly this on the finish rebuild).
		_cards[slug] = card
		_queue_thumb(a)
	_empty.visible = matched == 0
	if matched == 0:
		if _dl_only:
			_empty.text = "Nothing downloaded yet — cards get a Download option."
		elif _assets.is_empty():
			_empty.text = "ambientCG unreachable — offline or ambientcg.com is down."
		else:
			_empty.text = "No ambientCG assets match — check the search and filters."
	# The Retry only matters while the catalog itself is missing.
	_retry.visible = _assets.is_empty()
	var total := _assets.size()
	if total == 0:
		_status.text = "ambientCG unreachable — offline or fetch failed." if catalog_state == 2 \
			else "Nothing loaded yet."
	elif shown < matched:
		_status.text = "Showing %d of %d matches (%d loaded)" % [shown, matched, total]
	elif text.strip_edges() != "":
		_status.text = "%d matches of %d" % [matched, total]
	else:
		_status.text = "%d assets" % total
	if not _pages.is_empty():
		_status.text += " — loading more…"
	A2GUI.update_columns(_scroll, _grid, _border)
	_fetch_roots()


## One catalog/downloaded asset → the shared card: remote_* payload and
## downloaded badge — the exact tile _rebuild lists and the A2G downloads
## surface borrows via make_download_card(). The caller queues the thumb
## AFTER registering the card (_cards resp. _thumb_watchers).
func _make_card(a: Dictionary, is_downloaded := false) -> Control:
	var slug := str(a.get("slug", ""))
	# The chip mirrors BK's plan badge: the honest equivalent for an
	# all-CC0 catalog is the license itself (type stays on filter/icon).
	var card: Control = A2GUI.asset_card(str(a.get("name", "?")), "CC0",
		"ambientcg", "", null, str(AcgApi.TYPE_ICONS.get(a.get("type", ""), "ImageTexture")),
		{"remote_slug": slug, "remote_title": str(a.get("name", slug)),
			"remote_url": AcgApi.web_url(slug),
			"remote_site": "ambientcg.com",
			# Contract arg comes FIRST, the bound slug last — .bind(slug)
			# would land the slug in the wrong slot and type-error the
			# call (options/download/state all take one contract arg).
			"remote_options": func(cb: Callable): _remote_options_for(slug, cb),
			"remote_download": func(d): _remote_download(slug, d),
			"remote_state": func(d): _remote_state(slug, d),
			"remote_dir": Callable(self, "_downloaded_dir").bind(slug),
			"remote_delete": Callable(self, "_remote_delete").bind(slug),
			"remote_details": Callable(self, "_show_details").bind(slug),
			"remote_progress": Callable(self, "_remote_progress").bind(slug),
			"remote_dimensions": null,
			"remote_kind": str(a.get("type", ""))})
	card.connect("selected", func(_asset): _show_details(slug))
	card.call("set_downloaded", is_downloaded)
	return card


## The downloads surface's data: every downloaded slug → its asset dict.
## Slugs on disk the catalog doesn't list still get a synthesized entry
## (name + type from the folder) so reveal/state/quick-tile work.
func downloaded_assets() -> Array:
	var out := []
	var slugs := _downloaded_slugs()
	for slug in slugs:
		var a := _asset_by_slug(slug)
		out.append(a if not a.is_empty() else _synth_asset(slug, str(slugs[slug])))
	return out


## The exact card this tab's grid would show for [param a], for the A2G
## downloads surface — same tile by construction, thumb delivered
## through _thumb_watchers since the card never joins _cards.
func make_download_card(a: Dictionary) -> Control:
	var card := _make_card(a, true)
	var slug := str(a.get("slug", ""))
	if str(a.get("thumbnail_url", "")).is_empty():
		return card
	# Watch BEFORE queueing: a cached hit inside _queue_thumb pushes
	# synchronously — it must find this card among the watchers.
	_thumb_watchers.get_or_add(slug, []).append(card)
	_queue_thumb(a)
	return card


## Slugs of downloaded assets → their type dir: this session's finished
## downloads plus any asset folder under the download target
## (<target>/<type>/<slug>) — the toggle's "downloaded" view, mirroring
## BlendKit's project view. The type dir rides along so disk-only slugs
## synthesize a correct asset type and _dl_state_for finds the real path.
func _downloaded_slugs() -> Dictionary:
	var slugs := {}
	for slug in _dl_done:
		slugs[slug] = str(_dl_done[slug]).get_base_dir().get_file()
	var base := _target_dir()
	if DirAccess.dir_exists_absolute(base):
		for type_dir in DirAccess.get_directories_at(base):
			for d in DirAccess.get_directories_at(base.path_join(type_dir)):
				slugs[d] = type_dir
	return slugs


## A disk-only slug → a minimal catalog-shaped dict: type inferred from
## its parent folder (TYPE_DIRS reversed), name from the slug. Cached in
## _dl_extra_assets so _asset_by_slug answers it too.
func _synth_asset(slug: String, type_dir: String) -> Dictionary:
	if _dl_extra_assets.has(slug):
		return _dl_extra_assets[slug]
	var rev := {}
	for t in AcgApi.TYPE_DIRS:
		rev[AcgApi.TYPE_DIRS[t]] = t
	var a := {"slug": slug, "name": slug.replace("-", " ").replace("_", " ").capitalize(),
		"type": str(rev.get(type_dir, ""))}
	_dl_extra_assets[slug] = a
	return a


func _update_dl_badge() -> void:
	var count := _dl_queue.size()
	_dl_badge.text = str(count)
	_dl_badge.visible = count > 0
	_dl_toggle.tooltip_text = "Show downloaded ambientCG assets"
	if count > 0:
		_dl_toggle.tooltip_text += "\n%d %s in progress" % [count, "download" if count == 1 else "downloads"]


## Catalog lookup with the disk-only fallback: a slug the catalog doesn't
## list but that exists under the target still answers its synthesized
## dict, so details/state/reveal work for every downloaded asset.
func _asset_by_slug(slug: String) -> Dictionary:
	for a in _assets:
		if str(a.get("slug", "")) == slug:
			return a
	return _dl_extra_assets.get(slug, {})


# MARK: thumbnails

func _queue_thumb(asset: Dictionary) -> void:
	var url := str(asset.get("thumbnail_url", ""))
	if url.is_empty():
		return
	var slug := str(asset.get("slug", ""))
	if _thumb_cache.has(url):
		_push_thumb(slug, _thumb_cache[url])
		return
	_thumb_queue.append(asset)
	_pump_thumbs()


## Delivers a finished thumbnail to the grid card AND every watcher card
## (the A2G downloads surface's tiles) — pruning freed watchers so the
## map never holds dead refs. ambientCG thumbs never use the HDR fill.
func _push_thumb(slug: String, tex: Texture2D) -> void:
	var card: Control = _cards.get(slug)
	if is_instance_valid(card):
		card.call("set_thumb_texture", tex, false)
	if not _thumb_watchers.has(slug):
		return
	var alive := []
	# Untyped loop var: a stale freed ref would fail the typed assignment
	# before is_instance_valid ever gets to prune it.
	for c in _thumb_watchers[slug]:
		if is_instance_valid(c):
			c.call("set_thumb_texture", tex, false)
			alive.append(c)
	if alive.is_empty():
		_thumb_watchers.erase(slug)
	else:
		_thumb_watchers[slug] = alive


func _pump_thumbs() -> void:
	while _thumb_active < THUMB_PARALLEL and not _thumb_queue.is_empty():
		var a: Dictionary = _thumb_queue.pop_front()
		var url := str(a.get("thumbnail_url", ""))
		# Dropped since it was queued — a rebuild refills the queue while
		# fetches are in flight; without this every sort/filter refetches.
		if url.is_empty() or _thumb_cache.has(url):
			continue
		var slug := str(a.get("slug", ""))
		_thumb_active += 1
		var req := HTTPRequest.new()
		req.timeout = 15.0
		# Transfers off the main thread — without it the pump competes
		# with the 500-card rebuild for frame time.
		req.use_threads = true
		(plugin if plugin != null else self).add_child(req)
		req.request_completed.connect(func(_r, code, _h, body):
			req.queue_free()
			_thumb_active -= 1
			if code == 200:
				var img := Image.new()
				var err := img.load_webp_from_buffer(body)
				if err != OK:
					err = img.load_png_from_buffer(body)
				if err != OK:
					err = img.load_jpg_from_buffer(body)
				if err == OK:
					var tex := ImageTexture.create_from_image(img)
					_thumb_cache[url] = tex
					_push_thumb(slug, tex)
			_pump_thumbs())
		if req.request(url, [AcgApi.UA_HEADER]) != OK:
			req.queue_free()
			_thumb_active -= 1
			_pump_thumbs()


# MARK: details popup

## Card click — the details popup like BlendKit's asset_details. Fetches
## the asset's downloads first so the picker's options are real, then shows.
func _show_details(slug: String) -> void:
	var asset := _asset_by_slug(slug)
	if asset.is_empty():
		return
	_status.text = "Fetching files for %s…" % str(asset.get("name", slug))
	_fetch_url(AcgApi.files_url(slug), func(text):
		var options := AcgApi.flatten_files(JSON.parse_string(text),
			str(asset.get("type", "")))
		var thumb: Texture2D = _thumb_cache.get(str(asset.get("thumbnail_url", "")))
		_details.state_getter = _dl_state_for.bind(slug)
		_details.show_asset(asset, options, thumb, _res_hint)
		_status.text = "")


## The state the popup's action button needs: downloaded folder when the
## asset's dir exists under the target, downloading while its queue runs.
## The real type dir comes from the disk scan — a slug the catalog
## doesn't list resolves just as correctly as a fresh download does.
func _dl_state_for(slug: String) -> Dictionary:
	var dir := str(_dl_done.get(slug, ""))
	if dir.is_empty():
		var slugs := _downloaded_slugs()
		# Disk folders carry the validate_filename()d slug — try both.
		for s in [slug, slug.validate_filename()]:
			if slugs.has(s):
				dir = _target_dir().path_join(str(slugs[s])).path_join(s)
				break
	return {"dir": dir,
		"downloading": (_dl_req != null or _converting) \
			and str(_dl_asset.get("slug", "")) == slug}


# MARK: quick-download tile callbacks (the card's remote_* payload)

var _files_cache := {}


## Options for the quick tile: ?id=downloads fetched once per asset,
## flattened to the picker's rows, answered with the res-preferred default.
## The tile contract is {key,label,data} — remote_download hands .data
## back, so the flatten entry nests inside it.
func _remote_options_for(slug: String, cb: Callable) -> void:
	var answer := func(options: Array):
		var wrapped := []
		for e in options:
			wrapped.append({"key": str(e.get("key", "")),
				"label": str(e.get("label", "?")), "data": e})
		cb.call(wrapped, AcgApi.pick_default(options, _res_hint))
	if _files_cache.has(slug):
		answer.call(_files_cache[slug])
		return
	_fetch_url(AcgApi.files_url(slug), func(text):
		var options := AcgApi.flatten_files(JSON.parse_string(text),
			str(_asset_by_slug(slug).get("type", "")))
		_files_cache[slug] = options
		answer.call(options))


## The tile's Download action — the chosen option is a flatten_files
## entry, queued through the same pipeline as the details popup's.
func _remote_download(slug: String, data: Variant) -> void:
	var asset := _asset_by_slug(slug)
	if asset.is_empty() or not data is Dictionary:
		return
	_start_download(asset, data)


## Tile button state: our queue is single-flight, so a running download
## disables it — "Downloading…" on this asset, a note on the others.
func _remote_state(slug: String, _data: Variant) -> Dictionary:
	if _dl_req == null and not _converting:
		return {}
	var this := str(_dl_asset.get("slug", "")) == slug
	return {"enabled": false,
		"label": ("Converting…" if _converting else "Downloading…") if this else "Download",
		"note": "" if this else "A download is running — wait for it to finish."}


## The tile's Delete action: trash the asset's own folder under the
## download target — trash_downloaded_dir refuses anything not strictly
## inside _target_dir(), and an in-flight job on this slug can't have
## its files pulled out from under it. Card badge, details popup and
## the downloads pane all re-read disk state via the rescan.
func _remote_delete(slug: String) -> bool:
	if str(_dl_asset.get("slug", "")) == slug and (_dl_req != null or _converting):
		_status.text = "A download is running — wait for it to finish."
		return false
	if not A2GUI.trash_downloaded_dir(_downloaded_dir(slug), _target_dir()):
		return false
	_dl_done.erase(slug)
	var card: Control = _cards.get(slug)
	if is_instance_valid(card):
		card.call("set_downloaded", false)
	if _details.visible and str(_details.asset.get("slug", "")) == slug:
		_details.refresh_state()
	_status.text = "Deleted %s (moved to trash)" % slug
	# filesystem_changed refreshes the downloads pane even for external
	# targets — its refresh() re-reads the disk listing.
	EditorInterface.get_resource_filesystem().scan()
	return true


## The drop overlay's progress source: real byte fraction of the
## queued download when this slug is the active job (0..1), 1.0 for a
## finished one, -1.0 when the queue is busy elsewhere or the total is
## unknown — the box stays empty/idle rather than lying about progress.
func _remote_progress(slug: String) -> float:
	# A running job for this slug outranks _dl_done — a repair or
	# re-download must show its own fraction (<1.0 until _dl_done;
	# got == total already while post-download conversion still moves
	# files), or the drop poll would see "finished" mid-download and
	# abort as "produced no usable files".
	if str(_dl_asset.get("slug", "")) == slug \
			and (_dl_req != null or _converting):
		var got := _dl_done_bytes
		if _dl_req != null:
			got += _dl_req.get_downloaded_bytes()
		if _dl_total <= 0:
			return -1.0
		return clampf(float(got) / float(_dl_total), 0.0, 0.999)
	if _dl_done.has(slug):
		return 1.0
	# Not the running job — disk state answers (same truth remote_dir
	# reports): a folder from an earlier session is a finished
	# download, otherwise nothing has landed yet.
	return 1.0 if _downloaded_dir(slug) != "" else -1.0


# MARK: download

## Shared start for the quick tile's remote_download and the popup's
## download_requested — the same queue either way.
func _start_download(asset: Dictionary, option: Dictionary) -> void:
	if _dl_req != null or _converting:
		_status.text = "A download is running — wait for it to finish."
		return
	var dir := _target_dir()
	if dir.is_empty():
		_status.text = "No download target — pick a folder via the toolbar button."
		return
	_dl_asset = asset
	_dl_zips.clear()
	_dl_dest = dir.path_join(str(AcgApi.TYPE_DIRS.get(asset.get("type", ""), "misc"))) \
		.path_join(str(asset.get("slug", "")).validate_filename())
	_dl_queue = [{"url": str(option.get("url", "")), "rel": AcgApi.file_basename(str(option.get("url", "")))}]
	for rel in option.get("includes", {}):
		_dl_queue.append({"url": str(option["includes"][rel]), "rel": str(rel)})
	_dl_total = int(option.get("total_size", 0))
	_dl_done_bytes = 0
	_dl_next()
	if _details.visible and str(_details.asset.get("slug", "")) == str(asset.get("slug", "")):
		_details.refresh_state()


func _dl_next() -> void:
	_update_dl_badge()
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
	var url := str(job.get("url", ""))
	# ambientcg.com/get sits behind a stricter Cloudflare rule that
	# rejects Godot's mbedTLS ClientHello (400 invalid_request — curl
	# and Schannel pass, OpenSSL gets 403). The CDN behind the
	# redirect accepts us, so resolve that one hop via the system
	# curl and let HTTPRequest stream the real file.
	if "ambientcg.com/get" in url:
		url = _resolve_get(url)
	_dl_send(url, dest, 0)


## Resolve a /get URL's redirect target with the system curl (Windows
## ships curl.exe since 1809). Blocks ~300ms once per file — nothing
## next to a multi-MB download. Falls back to the input when curl is
## absent or the answer wasn't a redirect.
func _resolve_get(url: String) -> String:
	var out := []
	OS.execute("curl", ["-s", "-I", "-o",
		"NUL" if OS.has_feature("windows") else "/dev/null",
		"-w", "%{redirect_url}", url], out, true)
	var loc := str(out[0]).strip_edges() if out.size() > 0 else ""
	return loc if loc.begins_with("http") else url


## One staged download to [param dest].part. ambientcg.com/get answers
## 302 → acg-download.struffelproductions.com and HTTPRequest doesn't
## follow redirects — follow Location ourselves, bounded at
## MAX_REDIRECTS. A request that fails to start fails the job loudly.
func _dl_send(url: String, dest: String, redirs: int) -> void:
	_dl_req = HTTPRequest.new()
	_dl_req.timeout = 300.0
	_dl_req.use_threads = true
	_dl_req.download_file = dest + ".part"
	(plugin if plugin != null else self).add_child(_dl_req)
	_dl_req.request_completed.connect(func(result, code, headers, _b):
		var got := _dl_req.get_downloaded_bytes()
		_dl_req.queue_free()
		_dl_req = null
		if code in [301, 302, 303, 307, 308] and redirs < MAX_REDIRECTS:
			var loc := _header(headers, "location")
			if not loc.is_empty():
				_dl_send(loc, dest, redirs + 1)
				return
		var err := ""
		if result != HTTPRequest.RESULT_SUCCESS:
			err = "connection failed (%d)" % result
		elif code != 200:
			err = "HTTP %d" % code
		if err.is_empty() and DirAccess.rename_absolute(dest + ".part", dest) != OK:
			err = "rename failed"
		if not err.is_empty():
			_dl_fail(dest, err)
			return
		if dest.get_extension().to_lower() == "zip":
			_dl_zips.append(dest)
		_dl_done_bytes += got
		_dl_queue.pop_front()
		_dl_next())
	# raw redirect paths carry spaces/^ — encode_url before requesting
	if _dl_req.request(AcgApi.encode_url(url), [AcgApi.UA_HEADER]) != OK:
		_dl_req.queue_free()
		_dl_req = null
		_dl_fail(dest, "request did not start")
		return
	set_process(true)


static func _header(headers: PackedStringArray, wanted: String) -> String:
	for h in headers:
		if h.get_slice(":", 0).to_lower() == wanted:
			return h.substr(h.find(":") + 1).strip_edges()
	return ""


## A failed job aborts the download loudly — clear the queue, drop the
## orphaned .part, say so. Silently popping it would end in _dl_finish
## reporting a success that never happened.
func _dl_fail(dest: String, err: String) -> void:
	DirAccess.remove_absolute(dest + ".part")
	_dl_queue.clear()
	set_process(false)
	_update_dl_badge()
	_status.text = "Download failed (%s): %s" % [dest.get_file(), err]


func _process(_delta: float) -> void:
	if _dl_req == null:
		set_process(false)
		return
	var total := _dl_req.get_body_size()
	var got := _dl_req.get_downloaded_bytes()
	var pct := "%d%%" % int(100.0 * got / total) if total > 0 else "…"
	_status.text = "Downloading %d file(s) left — %s (%s)" % [_dl_queue.size(), AcgApi.short_size(got), pct]


func _dl_finish() -> void:
	set_process(false)
	_update_dl_badge()
	var slug := str(_dl_asset.get("slug", ""))
	# zip deliverables are flat archives — extract their contents (the
	# maps + .tres/.blend/.usdc files Godot can actually use), then drop
	# the container. The spec's archive rule: explicit extract step with
	# path-traversal guards.
	var failed := 0
	for zip_path in _dl_zips:
		if _extract_zip(zip_path):
			DirAccess.remove_absolute(zip_path)
		else:
			failed += 1
	_dl_zips.clear()
	# The post-download Godot adaptation runs AFTER extraction — it must see
	# the zip's contents (maps, .blend, .tres), not the archive. ambientCG
	# ships Godot-ready .tres, so its .blends stay untouched; whatever still
	# needs converting (e.g. an unreadable EXR) converts where it landed.
	var note := await _convert_downloads()
	# ambientCG's zips ship flat folders: <stem>.tres + <stem>_* maps —
	# reorganize into BlendKit's layout (.tres up top, maps in
	# textures_<tag>/); surviving .blends get keep-marked so the scan
	# doesn't feed them to the import bridge.
	Conversions.organize_materials(_dl_dest)
	Conversions.materialize_maps(_dl_dest)
	Conversions.keep_unimported(_dl_dest)
	_dl_done[slug] = _dl_dest
	_status.text = "Downloaded %s → %s%s" % [str(_dl_asset.get("name", slug)), A2GUI.short_path(_dl_dest), note]
	var card: Control = _cards.get(slug)
	if is_instance_valid(card):
		card.call("set_downloaded", true)
	if failed > 0:
		_status.text += " (%d archive(s) left unextracted)" % failed
	if _details.visible and str(_details.asset.get("slug", "")) == slug:
		_details.refresh_state()
	# _dl_dest is absolute (absolute_download_path is globalized), so an
	# in-project target compares against the globalized res:// root.
	if _dl_dest.begins_with(ProjectSettings.globalize_path("res://")):
		EditorInterface.get_resource_filesystem().scan()
	elif _in_local_root(_dl_dest) and plugin.connection \
			and plugin.connection.is_client_connected():
		_post_client("providers/local_dir/scan", {})


## Extract a downloaded zip flat into its folder — ambientCG archives are
## root-level (maps + .tres/.blend/.usdc + preview). Entry names are
## remote strings that become local paths: refuse anything escaping.
func _extract_zip(path: String) -> bool:
	var z := ZIPReader.new()
	if z.open(path) != OK:
		return false
	var base := path.get_base_dir()
	var ok := true
	for name in z.get_files():
		var rel := name.replace("\\", "/").trim_prefix("/")
		if rel.is_empty() or rel.ends_with("/") or ":" in rel \
				or ".." in rel.split("/"):
			continue
		# .blend/.usd* are source formats Godot can't import — and a
		# .blend under res:// makes the GUI editor pop the Blender-locate
		# dialog during scan → native crash. Keep importable content only.
		if rel.get_extension().to_lower() in EXTRACT_SKIP_EXTS:
			continue
		# <slug>.<img>/preview.<img> at the root is the archive's site
		# thumbnail — maps always carry a <stem>_* suffix. BlendKit
		# doesn't store previews either; the index uses remote thumbs.
		if not "/" in rel and rel.get_extension().to_lower() in \
				["png", "jpg", "jpeg", "webp"] \
				and rel.get_basename().to_lower() in \
				[base.get_file().to_lower(), "preview", "thumbnail"]:
			continue
		var target := base.path_join(rel)
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var f := FileAccess.open(target, FileAccess.WRITE)
		if f == null:
			ok = false
			continue
		f.store_buffer(z.read_file(name))
		f.close()
	z.close()
	return ok


## Run the post-download conversion pass over the asset folder —
## Conversions decides what needs it (unreadable EXRs, material .blends
## without a shipped .tres). Returns a status suffix, "" when nothing
## needed converting or all of it worked.
func _convert_downloads() -> String:
	if Conversions.collect(_dl_dest).is_empty():
		return ""
	_converting = true
	_status.text = Conversions.MESSAGE + "…"
	var result: Dictionary = await Conversions.convert_dir(_dl_dest)
	_converting = false
	var failed: Array = result.get("failed", [])
	if str(result.get("reason", "")) == "no blender":
		plugin.log_warning("The ambientCG download needs Blender to adapt it for Godot — the files were kept as they are.")
		return " (kept raw — Blender not found)"
	if failed.is_empty():
		return ""
	plugin.log_warning("%d ambientCG file(s) could not be converted for Godot: %s" \
		% [failed.size(), str(failed[0].get("error", ""))])
	return " (%d file(s) couldn't be converted)" % failed.size()


# MARK: target dir + client

func _pick_target() -> void:
	_file_dlg.current_dir = _target_dir()
	_file_dlg.popup_centered_ratio(0.6)


## The download target: the editor setting, else the provider's own
## project root — like BlendKit's bk_assets, downloads land in the
## project, never on some external path picked by name.
func _target_dir() -> String:
	var es := EditorInterface.get_editor_settings()
	if es and es.has_setting(SETTING_DIR):
		var dir := str(es.get_setting(SETTING_DIR))
		if not dir.is_empty():
			return dir
	# own root under the shared Assets2Godot folder beside bk_assets —
	# globalized so _dl_dest stays absolute
	return ProjectSettings.globalize_path("res://Assets2Godot/ambientcg")


## The downloaded folder for the tile's reveal action — _dl_state_for's
## disk check, so it survives an editor restart like the popup's does.
func _downloaded_dir(slug: String) -> String:
	return str(_dl_state_for(slug).get("dir", ""))


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
	(plugin if plugin != null else self).add_child(req)
	req.request_completed.connect(func(_r, code, _h, body):
		req.queue_free()
		cb.call(JSON.parse_string(body.get_string_from_utf8()) if code == 200 else null))
	if req.request(plugin.connection.client_url(endpoint)) != OK:
		req.queue_free()


func _post_client(endpoint: String, body: Dictionary) -> void:
	var req := HTTPRequest.new()
	(plugin if plugin != null else self).add_child(req)
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
