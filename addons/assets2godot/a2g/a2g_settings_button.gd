@tool
extends Button
## The plugin-wide "more" button in the main screen's header row — left
## of the A2G toggle, same dots-button mechanics the provider search
## rows use (GuiTabMenuHl dots, toggled popup right-aligned below).
##
## Its menu is the A2G scope the provider menus deliberately keep out of:
## per-provider tab switches (the registry's keys), the Assets2Godot
## fine-tuning shortcuts that also live in the Settings dialog, the
## folder the provider downloads share, the full Settings dialog, links,
## the addon version and a GitHub release check.

const A2GUI = preload("res://addons/assets2godot/a2g/a2g_ui.gd")
const SettingsDialog = preload("res://addons/assets2godot/ui/settings_dialog.gd")

## The repository's latest-release endpoint — api.github.com wants a
## User-Agent on every request (403 without one).
const RELEASES_API := "https://api.github.com/repos/ikonnow/Assets2Godot/releases/latest"
## The shared provider-download parent inside the project.
const A2G_DIR := "res://Assets2Godot"

enum Item { SETTINGS, OPEN_DIR, UPDATE, UPDATE_STATUS, SOURCES, ISSUES,
	VERSION, SHOW_FILES, TAB_LOGOS, PANEL_DOCKED, PREVIEW_SCENE }
## Provider check items get consecutive ids from this base — index into
## plugin.PROVIDERS maps back to the provider entry.
const PROVIDER_BASE := 100
const VIEW_MODES := ["Grid", "List"]
const THUMB_SIZES := [128, 256, 512]
const SCENE_CAPS := [50, 150, 300, 600, 1000]
const SETTING_VIEW := "assets2godot/browser_display_mode"
const SETTING_THUMB := "assets2godot/thumb_size"
const SETTING_CAP := "assets2godot/scene_resource_cap"
const SETTING_FILES := "assets2godot/show_all_files"
const SETTING_TAB_LOGOS := "assets2godot/tab_logos"
const SETTING_TEX_FORMAT := "assets2godot/texture_format"
const TEX_FORMATS := ["auto", "jpg", "png"]

var plugin: EditorPlugin

var _menu: PopupMenu
var _view_menu: PopupMenu
var _thumb_menu: PopupMenu
var _cap_menu: PopupMenu
var _fmt_menu: PopupMenu
var _settings: AcceptDialog
var _menu_styled := false
## GitHub release state: {} unchecked, {"latest": tag, "url": page} or
## {"error": why} after a check.
var _update := {}
var _update_checked := false


## Called by plugin.gd once the button sits in the header row.
func setup(new_plugin: EditorPlugin) -> void:
	plugin = new_plugin
	text = ""
	theme_type_variation = "FlatButton"
	tooltip_text = "Assets2Godot menu — provider tabs, fine-tuning, settings and updates."

	_menu = PopupMenu.new()
	add_child(_menu)
	# Toggle rows stay open — flipping several providers or watching the
	# update row land needs the menu alive; action rows hide it themselves.
	_menu.hide_on_item_selection = false
	_menu.hide_on_checkable_item_selection = false
	_menu.id_pressed.connect(_on_id_pressed)
	_menu.popup_hide.connect(func(): set_pressed_no_signal(false))
	_view_menu = PopupMenu.new()
	_view_menu.name = "ViewMenu"
	_view_menu.id_pressed.connect(func(id): _set_es(SETTING_VIEW, id))
	_menu.add_child(_view_menu)
	_thumb_menu = PopupMenu.new()
	_thumb_menu.name = "ThumbMenu"
	_thumb_menu.id_pressed.connect(func(id): _set_es(SETTING_THUMB, THUMB_SIZES[id]))
	_menu.add_child(_thumb_menu)
	_cap_menu = PopupMenu.new()
	_cap_menu.name = "CapMenu"
	_cap_menu.id_pressed.connect(func(id): _set_es(SETTING_CAP, SCENE_CAPS[id]))
	_menu.add_child(_cap_menu)
	_fmt_menu = PopupMenu.new()
	_fmt_menu.name = "FmtMenu"
	_fmt_menu.id_pressed.connect(func(id): _set_es(SETTING_TEX_FORMAT, TEX_FORMATS[id]))
	_menu.add_child(_fmt_menu)
	# The one shared Settings dialog — the BlendKit menu builds it if we
	# didn't; both menus open the same surface.
	if plugin.settings_dialog == null:
		plugin.settings_dialog = SettingsDialog.new()
		EditorInterface.get_base_control().add_child(plugin.settings_dialog)
		plugin.settings_dialog.setup(plugin)
	_settings = plugin.settings_dialog
	toggle_mode = true
	toggled.connect(_on_toggled)


func _notification(what: int) -> void:
	match what:
		# setup() runs while the header row is still off-tree — the theme
		# icon only resolves once we're inside the editor's theme chain
		# (ENTER_TREE) and again on theme/scale changes.
		NOTIFICATION_ENTER_TREE, NOTIFICATION_THEME_CHANGED:
			icon = get_theme_icon("GuiTabMenuHl", "EditorIcons")


func _on_toggled(pressed: bool) -> void:
	if not pressed:
		_menu.hide()
		return
	_fill_menu()
	_menu.reset_size()
	var canvas_scale := get_global_transform_with_canvas().get_scale()
	# Right-aligned below the button, positioned like MenuButton does it.
	var pos := get_screen_position() + Vector2(size.x * canvas_scale.x - _menu.size.x, size.y * canvas_scale.y)
	_menu.popup(Rect2i(Vector2i(pos), _menu.size))
	# One silent release check per session — the status row joins on the
	# next open; "Check for Updates…" re-runs it on demand.
	if not _update_checked:
		_update_checked = true
		_check_updates()


## Same row discipline as the provider menus: disabled status lines,
## short labels, a click does the verb; the popup is as wide as its
## longest item.
func _fill_menu() -> void:
	# Separator headlines get the A2G branding — emboldened and
	# letter-spaced like the preview panel's caps labels. Deferred to
	# first fill: only inside the theme chain does the resolved font
	# exist (same timing the ENTER_TREE icon fix works around).
	if not _menu_styled:
		_menu_styled = true
		var sep_font := FontVariation.new()
		sep_font.base_font = _menu.get_theme_default_font()
		sep_font.variation_embolden = 0.7
		sep_font.spacing_glyph = 2
		_menu.add_theme_font_override(&"font_separator", sep_font)
		_menu.add_theme_font_size_override(&"font_separator_size", 13)
	_menu.clear()
	_view_menu.clear()
	_thumb_menu.clear()
	_cap_menu.clear()
	_fmt_menu.clear()
	# Provider tab switches — the registry's keys and logos, checked
	# state from the same editor settings the plugin answers.
	for i in plugin.PROVIDERS.size():
		var p: Dictionary = plugin.PROVIDERS[i]
		var key := str(p.get("key", ""))
		_menu.add_icon_check_item(A2GUI.provider_icon(key), str(p.get("title", key)),
			PROVIDER_BASE + i)
		_menu.set_item_checked(-1, plugin.provider_enabled(key))
		var daemon := bool(p.get("daemon", false))
		_menu.set_item_tooltip(-1, "Show the %s tab.%s" % [p.get("title", key),
			" The Client keeps running — the A2G index needs it." if daemon else \
			" Its catalog never fetches while off."])
	_menu.add_separator("ASSETS2GODOT FILES")
	for i in VIEW_MODES.size():
		_view_menu.add_radio_check_item(VIEW_MODES[i], i)
		_view_menu.set_item_checked(i, int(_es(SETTING_VIEW, 0)) == i)
	_menu.add_submenu_item("Browser view", _view_menu.name)
	_menu.set_item_icon(-1, get_theme_icon("FileList", "EditorIcons"))
	_menu.set_item_tooltip(-1, "Gallery tiles or a compact list — shared with the Settings dialog (applies on next browser load).")
	for i in THUMB_SIZES.size():
		_thumb_menu.add_radio_check_item("%d px" % THUMB_SIZES[i], i)
		_thumb_menu.set_item_checked(i, _es(SETTING_THUMB, 256) == THUMB_SIZES[i])
	_menu.add_submenu_item("Thumbnail size", _thumb_menu.name)
	_menu.set_item_icon(-1, get_theme_icon("ImageTexture", "EditorIcons"))
	_menu.set_item_tooltip(-1, "Render size for thumbnails of files outside res:// — also in Settings.")
	for i in SCENE_CAPS.size():
		_cap_menu.add_radio_check_item(str(SCENE_CAPS[i]), i)
		_cap_menu.set_item_checked(i, _es(SETTING_CAP, 300) == SCENE_CAPS[i])
	_menu.add_submenu_item("Scene resources cap", _cap_menu.name)
	_menu.set_item_icon(-1, get_theme_icon("NodeInfo", "EditorIcons"))
	_menu.set_item_tooltip(-1, "Max resources collected from the open scene for the Assets view.")
	for i in TEX_FORMATS.size():
		var label: String = "Auto" if TEX_FORMATS[i] == "auto" else TEX_FORMATS[i].to_upper()
		_fmt_menu.add_radio_check_item(label, i)
		_fmt_menu.set_item_checked(i, _es(SETTING_TEX_FORMAT, "auto") == TEX_FORMATS[i])
	# Icon check row like the provider switches above — a plain check
	# item renders its box offset from the icon_check rows' boxes.
	_menu.add_icon_check_item(get_theme_icon("File", "EditorIcons"), "Show all files", Item.SHOW_FILES)
	_menu.set_item_checked(-1, bool(_es(SETTING_FILES, false)))
	_menu.set_item_tooltip(-1, "List text files, configs and scripts in the Assets view too.")
	_menu.add_separator("ASSETS2GODOT")
	_menu.add_submenu_item("Texture format", _fmt_menu.name)
	_menu.set_item_icon(-1, get_theme_icon("AssetStore", "EditorIcons"))
	_menu.set_item_tooltip(-1, "Default format for texture downloads — Auto picks PNG for opacity maps. Per-provider overrides live in Settings.")
	# Opt-in provider marks inside the tabs — a panel feature, so it
	# sits with the dock/preview switches under Assets2Godot.
	_menu.add_icon_check_item(get_theme_icon("TabBar", "EditorIcons"),
		"Provider logos in tabs", Item.TAB_LOGOS)
	_menu.set_item_checked(-1, plugin.tab_logos_enabled())
	_menu.set_item_tooltip(-1, "Show each provider's logo in its main tab — off keeps tabs text-only.")
	# The header's dock toggle as a menu check — same setting, same
	# immediate reparent; EditorDock is the icon the header button uses
	# (GuiTabUnfloat doesn't exist in the editor's icon set).
	_menu.add_icon_check_item(get_theme_icon("EditorDock", "EditorIcons"),
		"Docked panel", Item.PANEL_DOCKED)
	_menu.set_item_checked(-1, plugin.panel_mode() == plugin.PanelMode.DOCKED)
	_menu.set_item_tooltip(-1, "Dock the A2G panel natively — position and close then come from the dock's ⋮ menu.")
	_menu.add_icon_check_item(get_theme_icon("WorldEnvironment", "EditorIcons"),
		"Preview stage in edited scene ", Item.PREVIEW_SCENE)
	_menu.set_item_checked(-1, plugin.preview_scene_enabled())
	_menu.set_item_tooltip(-1, "Places the neutral test stage inside the edited scene — internal child, never saved. Its environment replaces the scene's while on.")
	var has_dir := DirAccess.dir_exists_absolute(A2G_DIR)
	_menu.add_icon_item(get_theme_icon("Folder", "EditorIcons"), "Show downloads folder", Item.OPEN_DIR)
	if not has_dir:
		_menu.set_item_disabled(-1, true)
	_menu.set_item_tooltip(-1, "%s — the shared parent of all provider downloads.%s"
		% [A2G_DIR, "" if has_dir else "\nCreated by the first provider download."])
	_menu.add_icon_item(get_theme_icon("Tools", "EditorIcons"), "Settings…", Item.SETTINGS)
	_menu.add_separator()
	_menu.add_icon_item(get_theme_icon("Reload", "EditorIcons"), "Check for Updates…", Item.UPDATE)
	_fill_update_row()
	_menu.add_icon_item(get_theme_icon("Script", "EditorIcons"), "README & Sources", Item.SOURCES)
	_menu.set_item_tooltip(-1, plugin.SOURCES_URL)
	_menu.add_icon_item(get_theme_icon("Debug", "EditorIcons"), "Report an Issue", Item.ISSUES)
	_menu.set_item_tooltip(-1, plugin.ISSUES_URL)
	_menu.add_separator()
	_menu.add_item("A2G Plugin v%s" % plugin.get_addon_version(), Item.VERSION)
	_menu.set_item_disabled(-1, true)


## The release-check result row — nothing before the first check, a
## "Checking…" placeholder while the request is out, then a disabled
## status or a clickable "Update available" link.
func _fill_update_row() -> void:
	if _update.is_empty():
		return
	if _update.has("pending"):
		_menu.add_icon_item(get_theme_icon("Timer", "EditorIcons"),
			"Checking for updates…", Item.UPDATE_STATUS)
		_menu.set_item_disabled(-1, true)
		return
	var latest := str(_update.get("latest", ""))
	if latest.is_empty():
		# Short status like the other menus' rows — the reason lives in the
		# tooltip and the row doubles as the releases link (the API 404s on
		# repos without public releases; the browser page still answers).
		_menu.add_icon_item(get_theme_icon("StatusError", "EditorIcons"),
			"Update check failed", Item.UPDATE_STATUS)
		_menu.set_item_tooltip(-1, "%s — click to open the releases page."
			% str(_update.get("error", "?")))
		return
	var current: String = plugin.get_addon_version()
	if _version_newer(latest, current):
		_menu.add_icon_item(get_theme_icon("ExternalLink", "EditorIcons"),
			"Update available: %s" % latest, Item.UPDATE_STATUS)
		_menu.set_item_tooltip(-1, str(_update.get("url", plugin.SOURCES_URL + "/releases")))
	else:
		_menu.add_icon_item(get_theme_icon("StatusSuccess", "EditorIcons"),
			"Up to date (v%s)" % current, Item.UPDATE_STATUS)
		_menu.set_item_disabled(-1, true)


func _on_id_pressed(id: int) -> void:
	if id >= PROVIDER_BASE:
		var i := id - PROVIDER_BASE
		if i < plugin.PROVIDERS.size():
			var key := str(plugin.PROVIDERS[i].get("key", ""))
			plugin.set_provider_enabled(key, not plugin.provider_enabled(key))
		return
	match id:
		Item.SHOW_FILES:
			_set_es(SETTING_FILES, not bool(_es(SETTING_FILES, false)))
		Item.TAB_LOGOS:
			plugin.set_tab_logos(not plugin.tab_logos_enabled())
		Item.PANEL_DOCKED:
			plugin.set_panel_mode(plugin.PanelMode.EMBEDDED \
				if plugin.panel_mode() == plugin.PanelMode.DOCKED \
				else plugin.PanelMode.DOCKED)
		Item.PREVIEW_SCENE:
			plugin.set_preview_scene(not plugin.preview_scene_enabled())
		Item.OPEN_DIR:
			_menu.hide()
			EditorInterface.get_file_system_dock().navigate_to_path(A2G_DIR)
		Item.SETTINGS:
			_menu.hide()
			_settings.popup_centered()
		Item.UPDATE:
			_check_updates()
		Item.UPDATE_STATUS:
			_menu.hide()
			var url := str(_update.get("url", ""))
			if not url.is_empty():
				OS.shell_open(url)
		Item.SOURCES:
			_menu.hide()
			OS.shell_open(plugin.SOURCES_URL)
		Item.ISSUES:
			_menu.hide()
			OS.shell_open(plugin.ISSUES_URL)


## Queries the repo's latest release once per menu open until answered —
## the row lands via _fill_menu on the next open or a manual re-check.
func _check_updates() -> void:
	_update = {"pending": true}
	# The menu stays open for this item — show the pending row right
	# away so the click visibly registered.
	if _menu.visible:
		_fill_menu()
		_menu.reset_size()
	var req := HTTPRequest.new()
	req.timeout = 15.0
	(plugin if plugin != null else self).add_child(req)
	# The request hangs on the plugin and can outlive this button — and
	# teardown frees the request while the signal is still queued.
	# Capture both weakly, bail on either death.
	var rw := weakref(req)
	var wr := weakref(self)
	req.request_completed.connect(func(_result, code, _h, body):
		var r = rw.get_ref()
		if r == null:
			return
		r.queue_free()
		var o = wr.get_ref()
		if o == null:
			return
		var releases_url: String = o.plugin.SOURCES_URL + "/releases"
		if code != 200:
			o._update = {"error": "HTTP %d" % code, "url": releases_url}
		else:
			var data: Variant = JSON.parse_string(body.get_string_from_utf8())
			if data is Dictionary and not str(data.get("tag_name", "")).is_empty():
				o._update = {"latest": str(data["tag_name"]),
					"url": str(data.get("html_url", releases_url))}
			else:
				o._update = {"error": "no release found", "url": releases_url}
		if o._menu.visible:
			o._fill_menu()
			o._menu.reset_size())
	req.request(RELEASES_API,
		["Accept: application/vnd.github+json",
			"User-Agent: Assets2Godot/%s (Godot editor plugin)" % plugin.get_addon_version()])


## "v1.2.3" > "1.2.0"? Numeric part compare, prefixes and suffixes ignored.
func _version_newer(latest: String, current: String) -> bool:
	var a := latest.trim_prefix("v").split(".")
	var b := current.trim_prefix("v").split(".")
	for i in maxi(a.size(), b.size()):
		var x := int(a[i]) if i < a.size() else 0
		var y := int(b[i]) if i < b.size() else 0
		if x != y:
			return x > y
	return false


func _es(key: String, fallback: Variant) -> Variant:
	var es := EditorInterface.get_editor_settings()
	if es and es.has_setting(key):
		return es.get_setting(key)
	return fallback


func _set_es(key: String, value: Variant) -> void:
	var es := EditorInterface.get_editor_settings()
	if es:
		es.set_setting(key, value)
