@tool
extends EditorPlugin
## The Blendkit plugin: settings, logging and the main screen tab. The Client
## connection is ClientConnection, the tab is the gallery.

signal model_format_changed
signal download_dir_changed

const SERVER = "https://blendkit.com"
# [value, label] pairs for the settings dialog and the Format filter
const MODEL_FORMATS = [["blend", "Blender (.blend)"], ["gltf_godot", "glTF (.glb)"]]
const UUID_NAMES = [[ProjectAssets.UUID_NAMES_FULL, "Full"], [ProjectAssets.UUID_NAMES_SHORT, "Short"], [ProjectAssets.UUID_NAMES_STRIP, "Strip"]]
const RESOLUTIONS = [["", "Auto"], ["ORIGINAL", "Original"], ["resolution_4K", "4K"], ["resolution_2K", "2K"], ["resolution_1K", "1K"], ["resolution_0_5K", "0.5K"]]
# Project settings live in project.godot and are shared with the team, editor
# settings stay on this computer. All of them show in Godot's settings dialogs.
const SETTING_DOWNLOAD_DIR = "blendkit/downloads/directory"
const SETTING_MODEL_FORMAT = "blendkit/downloads/model_format"
const SETTING_RESOLUTION = "blendkit/downloads/resolution"
const SETTING_UUID_NAMES = "blendkit/downloads/uuids_in_names"
const SETTING_CLIENT_ENABLED = "blendkit/client/enabled"
const SETTING_PORT = "blendkit/client/port"
const SETTING_LOG_LEVEL = "blendkit/client/log_level"
# Assets2Godot — local index browser and unified Assets tab.
# The browser persists its view under browser_display_mode — the same
# key a2g_browser reads; registering an alias would be a dead setting.
const SETTING_A2G_VIEW = "assets2godot/browser_display_mode"
const SETTING_A2G_THUMB_SIZE = "assets2godot/thumb_size"
const SETTING_A2G_SCENE_CAP = "assets2godot/scene_resource_cap"
const SETTING_A2G_SHOW_FILES = "assets2godot/show_all_files"
# Per-provider tab visibility — "assets2godot/providers/<key>_enabled".
const SETTING_A2G_PROVIDER = "assets2godot/providers/%s_enabled"
# Opt-in provider logos inside the tabs — off keeps them text-only.
const SETTING_A2G_TAB_LOGOS = "assets2godot/tab_logos"
# Where the A2G panel lives: embedded in its main screen, or a native
# editor dock (whose ⋮ menu then offers position, floating and close).
const SETTING_A2G_PANEL_MODE = "assets2godot/panel_mode"
# Tab logo render size — the editor's 16px glyph grid, capped per tab
# via set_tab_icon_max_width so wide marks can't stretch the tab.
const TAB_LOGO_PX := 16.0
# Older keys moved to the settings above.
const OLD_SETTINGS = {"blendkit/model_format": SETTING_MODEL_FORMAT, "blendkit/resolution": SETTING_RESOLUTION}
# Godot's enum hints can't hold an empty value, so Auto resolution "" is stored as this.
const RESOLUTION_AUTO = "auto"
# The resolution Auto downloads.
const AUTO_RESOLUTION = "resolution_2K"
const USER_GUIDE_URL = "https://www.blendkit.com/blendkit-in-godot/"
const SOURCES_URL = "https://github.com/ikonnow/Assets2Godot"
const ISSUES_URL = "https://github.com/ikonnow/Assets2Godot/issues"

const gallery_scene = preload("res://addons/assets2godot/ui/gallery/gallery.tscn")
const A2GUI = preload("res://addons/assets2godot/a2g/a2g_ui.gd")
const A2GDock = preload("res://addons/assets2godot/a2g/a2g_dock.gd")
const A2GBrowser = preload("res://addons/assets2godot/a2g/a2g_browser.gd")
const A2GContextPlugin = preload("res://addons/assets2godot/a2g/a2g_context_plugin.gd")
const A2GPolyhaven = preload("res://addons/assets2godot/a2g/a2g_polyhaven.gd")
const A2GAmbientcg = preload("res://addons/assets2godot/a2g/a2g_ambientcg.gd")
const A2GSettingsButton = preload("res://addons/assets2godot/a2g/a2g_settings_button.gd")
const A2GSceneDrop = preload("res://addons/assets2godot/a2g/a2g_scene_drop.gd")
const Auth = preload("res://addons/assets2godot/auth.gd")
const BlenderImport = preload("res://addons/assets2godot/blender_import.gd")
const ClientBinary = preload("res://addons/assets2godot/client_binary.gd")
const ClientConnection = preload("res://addons/assets2godot/client_connection.gd")
const GalleryApi = preload("res://addons/assets2godot/ui/gallery/gallery_api.gd")
const ProjectAssets = preload("res://addons/assets2godot/ui/gallery/project_assets.gd")
const Icons = preload("res://addons/assets2godot/ui/icons.gd")


enum LogLevel { ERROR, WARNING, INFO, VERBOSE, DEBUG, TRACE }
## Where the A2G panel lives — the assets2godot/panel_mode setting.
enum PanelMode { EMBEDDED, DOCKED }

var log_level: int = LogLevel.INFO

# The Client reports message_level in Python logging values:
# 0=Debug, 10=Info, 20=Warning, 30=Error, 40=Fatal
static func client_message_log_level(message_level: int) -> LogLevel:
	if message_level >= 30:
		return LogLevel.ERROR
	if message_level >= 20:
		return LogLevel.WARNING
	if message_level >= 10:
		return LogLevel.INFO
	return LogLevel.DEBUG

func bk_log(level: LogLevel, msg: String) -> void:
	if level > log_level:
		return
	var prefix = "Assets2Godot: " if level == LogLevel.INFO else "Assets2Godot %s: " % LogLevel.keys()[level]
	var log_msg = prefix + msg
	match level:
		LogLevel.ERROR:
			push_error(log_msg)
		LogLevel.WARNING:
			push_warning(log_msg)
		_:
			print(log_msg)

func log_error(msg: String) -> void:
	bk_log(LogLevel.ERROR, msg)

func log_warning(msg: String) -> void:
	bk_log(LogLevel.WARNING, msg)

func log_info(msg: String) -> void:
	bk_log(LogLevel.INFO, msg)

func log_verbose(msg: String) -> void:
	bk_log(LogLevel.VERBOSE, msg)

func log_debug(msg: String) -> void:
	bk_log(LogLevel.DEBUG, msg)

func log_trace(msg: String) -> void:
	bk_log(LogLevel.TRACE, msg)


var client_enabled := true
# a2g: upstream default "res://bk_assets/" — providers share one parent.
var download_dir: String = "res://Assets2Godot/bk_assets/"
var absolute_download_path: String
var model_format: String = "blend"
var resolution: String = ""
# How much of the UUIDs downloaded folders and files are named with.
var uuid_names: String = ProjectAssets.UUID_NAMES_STRIP
# Godot sets up .blend import when the editor starts, so changes to these
# apply after a restart.
var startup_blend_enabled: bool
var startup_blender_path: String
# Port to start the Client on when none is running
var preferred_port: String = ClientConnection.CLIENT_PORTS[0]
var addon_version: String

var connection: ClientConnection
var auth: Auth
var gallery: Control
## The A2G main screen: a header row (provider TabBar + the right-aligned
## "A2G" toggle) over a stack of panes. The Assets2Godot organization
## surface is one of the panes, covering the whole content area while the
## toggle is pressed — an overlay across all providers, not a tab.
var main_screen: VBoxContainer
var a2g_pane: Control
var _tab_bar: TabBar
var _tab_panes: Array[Control] = []
var _a2g_button: Button
var _a2g_dock: A2GDock
var _ctx_fs: EditorContextMenuPlugin
var _ctx_scene: EditorContextMenuPlugin
## The EditorDock shell main_screen moves into while docked — untyped
## because the class only exists on Godot 4.6+ (ClassDB instantiation
## keeps this plugin parsing on older versions).
var _a2g_dock_shell: Variant
var _a2g_placeholder: Control
var _dock_button: Button
var _panel_docked := false
## The remote-drop overlays parked inside the editor's own surfaces —
## the 3D viewport's input surface and the FileSystem dock's list.
var _drop_overlays: Array[Control] = []

## The remote providers in display order — alphabetical by title, the
## one rule the TabBar, the Sources tree's remote rows and the settings
## menu's switches all share. "blendkit" is the daemon-backed upstream
## gallery, the rest are in-plugin HTTP providers (spec §3). A new
## provider inserts its entry alphabetically and adds its pane to
## init_gallery's registration dict — the array IS the order everywhere.
const PROVIDERS := [
	{"key": "ambientcg", "title": "ambientCG", "daemon": false},
	{"key": "blendkit", "title": "BlendKit", "daemon": true},
	{"key": "polyhaven", "title": "Polyhaven", "daemon": false},
]
## key → pane, filled by _add_tab_pane as each provider pane registers.
var _provider_panes := {}
## The custom EditorResourcePreviewGenerator registered in _enter_tree.
var _preview_gen: EditorResourcePreviewGenerator


func _enter_tree() -> void:
	# godotengine/godot#114067: on the gl_compatibility renderer the
	# texture importer spins up a separate Vulkan/D3D12 device for GPU
	# compression — that spinup crashes on some drivers (signal 11
	# during a "detected as used in 3D" reimport of provider textures).
	# Force CPU compression for the session; other renderers keep GPU.
	if RenderingServer.get_current_rendering_method() == "gl_compatibility":
		ProjectSettings.set_setting(
			"rendering/textures/vram_compression/compress_with_gpu", false)
	init_settings()
	# The A2G preview generator fills the gaps the built-ins leave
	# (external images, .glb/.gltf/.fbx) inside the native preview queue.
	# request_draw_and_wait exists only since 4.6 (godot#96897) — on
	# older editors the file wouldn't even parse, so it's never loaded
	# there and a2g_browser's `staged` route falls back to the A2G rig.
	var previewer := EditorInterface.get_resource_previewer()
	var ver := Engine.get_version_info()
	if previewer != null and (ver.major > 4 or (ver.major == 4 and ver.minor >= 6)):
		var gen_script: Script = load("res://addons/assets2godot/a2g/a2g_preview_generator.gd")
		if gen_script != null:
			_preview_gen = gen_script.new()
			previewer.add_preview_generator(_preview_gen)
	startup_blend_enabled = BlenderImport.blend_import_enabled()
	startup_blender_path = BlenderImport.blender_path()
	log_info("Plugin enabled")
	absolute_download_path = ProjectSettings.globalize_path(download_dir)
	log_info("Download path: %s" % absolute_download_path)
	log_verbose("Client data dir: %s" % ClientBinary.get_client_data_dir())

	connection = ClientConnection.new(self)
	add_child(connection)

	auth = Auth.new()
	auth.plugin = self
	add_child(auth)

	init_gallery()
	_install_drop_overlays()
	if panel_mode() == PanelMode.DOCKED:
		_undock_panel()
	ProjectSettings.settings_changed.connect(load_settings)
	EditorInterface.get_editor_settings().settings_changed.connect(load_settings)
	if client_enabled:
		connection.start()


# No unsubscribe here: on editor shutdown the request never reaches the
# Client, as the HTTPRequest is freed with the plugin before it's sent.
func _exit_tree() -> void:
	if _preview_gen != null:
		var previewer := EditorInterface.get_resource_previewer()
		if previewer != null:
			previewer.remove_preview_generator(_preview_gen)
		_preview_gen = null
	ProjectSettings.settings_changed.disconnect(load_settings)
	EditorInterface.get_editor_settings().settings_changed.disconnect(load_settings)
	if _ctx_fs:
		remove_context_menu_plugin(_ctx_fs)
		_ctx_fs = null
	if _ctx_scene:
		remove_context_menu_plugin(_ctx_scene)
		_ctx_scene = null
	for ov in _drop_overlays:
		if is_instance_valid(ov):
			ov.queue_free()
	_drop_overlays.clear()
	# Undock first — main_screen is freed below, the dock shell with it.
	if _panel_docked:
		if _a2g_dock_shell != null and has_method(&"remove_dock"):
			call("remove_dock", _a2g_dock_shell)
		elif _a2g_dock_shell == null and has_method(&"remove_control_from_docks"):
			call("remove_control_from_docks", main_screen)
	if _a2g_dock_shell != null:
		_a2g_dock_shell.queue_free()
		_a2g_dock_shell = null
	if _a2g_placeholder != null:
		_a2g_placeholder.queue_free()
		_a2g_placeholder = null
	# The children go with the plugin; the panes live in the main screen.
	if main_screen:
		main_screen.queue_free()
		main_screen = null
		a2g_pane = null
		_tab_bar = null
		_tab_panes = []
		_provider_panes = {}
		_a2g_button = null
		_a2g_dock = null
		gallery = null
	log_info("Plugin exited")


# Main screen tab. _has_main_screen() is deprecated in Godot 4.8 in favor of an
# EditorDock in DOCK_SLOT_MAIN_SCREEN, but it still works and is the only
# option on Godot 4.0-4.7.
func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	# Docked: the "A2G" screen entry shows a placeholder instead of an
	# empty surface — the panel lives in a dock until it docks back.
	if _panel_docked:
		if _a2g_placeholder != null:
			_a2g_placeholder.visible = visible
		return
	if main_screen:
		main_screen.visible = visible


func _get_plugin_name() -> String:
	return "A2G"


# Godot asks again on theme changes, so the icon follows the editor scale and
# light/dark icon colors.
func _get_plugin_icon() -> Texture2D:
	return Icons.render_svg_fit(A2G_ICON_PATH, 16.0 * EditorInterface.get_editor_scale(), true)


const A2G_ICON_PATH := "res://addons/assets2godot/a2g/icon.svg"


# The A2G main screen: a header row — the TabBar of provider tabs on the
# left, the "A2G" toggle button at the right end — over a stack of
# full-rect panes. The Assets2Godot organization surface is one of the
# panes, covering the provider panes while the toggle is pressed: an
# overlay across all providers, not another tab competing with them.
func init_gallery() -> void:
	main_screen = VBoxContainer.new()
	main_screen.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_screen.add_theme_constant_override("separation", 0)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", int(4 * EditorInterface.get_editor_scale()))
	main_screen.add_child(header)
	_tab_bar = TabBar.new()
	_tab_bar.name = "A2GTabs"
	_tab_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_bar.deselect_enabled = false
	# The dock-tab look comes from TabContainer's theme items — copied
	# onto the standalone TabBar so the strip renders identically.
	A2GUI.style_tabbar(_tab_bar)
	_tab_bar.tab_selected.connect(_show_tab)
	header.add_child(_tab_bar)
	# A click on the already-selected tab leaves the A2G surface too —
	# tab_selected only fires on change.
	if _tab_bar.has_signal(&"tab_clicked"):
		_tab_bar.connect(&"tab_clicked", func(_i): select_tab(_tab_bar.current_tab))
	header.add_child(VSeparator.new())
	# The plugin-wide menu left of the A2G toggle: provider switches,
	# A2G fine-tuning, Settings, links and the release check — same
	# dots-button mechanics the provider search rows use.
	var a2g_menu := A2GSettingsButton.new()
	a2g_menu.name = "A2GMenu"
	header.add_child(a2g_menu)
	a2g_menu.setup(self)
	_a2g_button = Button.new()
	_a2g_button.name = "A2GToggle"
	_a2g_button.text = "A2G"
	_a2g_button.theme_type_variation = "FlatButton"
	_a2g_button.toggle_mode = true
	_a2g_button.tooltip_text = "Assets2Godot — organize indexed and project assets."
	_a2g_button.toggled.connect(_on_a2g_toggled)
	header.add_child(_a2g_button)
	# Last control, far right: detaches the whole panel into a native
	# editor dock — the dock's own ⋮ menu then carries Dock Position,
	# Make Floating and Close like every other dock.
	_dock_button = Button.new()
	_dock_button.name = "A2GDockToggle"
	_dock_button.theme_type_variation = "FlatButton"
	_dock_button.toggle_mode = true
	_dock_button.tooltip_text = "Dock the A2G panel into the editor — position, floating and close come from the dock's own ⋮ menu."
	_dock_button.toggled.connect(func(on): set_panel_mode(
		PanelMode.DOCKED if on else PanelMode.EMBEDDED))
	header.add_child(_dock_button)

	# The pane stack: every child fills the content area, exactly one
	# visible at a time.
	var panes := Control.new()
	panes.name = "A2GPanes"
	panes.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_screen.add_child(panes)
	# The former "Assets" tab lives inside the A2G surface now — the
	# Sources tree's "Project → Files / Open scene" rows swap the browser
	# pane to the embedded A2GSceneAssets panel.
	# The A2G pane is the former "Assets2Godot" tab content, unchanged:
	# a MarginContainer framing a VBox — dock-wide toolbar over the
	# Sources|Browser split — plus its context-menu injections.
	a2g_pane = MarginContainer.new()
	a2g_pane.name = "Assets2Godot"
	# Left keeps the dock-panel margin; the right field reaches the main
	# screen's edge flush — the same edge the native FileSystem dock's
	# list reaches against the right dock column.
	a2g_pane.add_theme_constant_override("margin_left", int(4 * EditorInterface.get_editor_scale()))
	a2g_pane.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	a2g_pane.hide()
	var tabv := VBoxContainer.new()
	a2g_pane.add_child(tabv)
	var tbar := HBoxContainer.new()
	tabv.add_child(tbar)
	var a2g := HSplitContainer.new()
	a2g.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# The theme's own split separation (~3px — same gap the FileSystem
	# dock shows between its panes); the visible grab handle keeps it
	# discoverable without widening the gap.
	a2g.dragger_visibility = SplitContainer.DRAGGER_VISIBLE
	var local := A2GDock.new()
	local.plugin = self
	_a2g_dock = local
	# Tree ops go to the left of the shared toolbar, browser controls to
	# the right — the FileSystem dock's own toolbar layout.
	local.toolbar_parent = tbar
	a2g.add_child(local)
	var browser := A2GBrowser.new()
	browser.plugin = self
	browser.toolbar_parent = tbar
	browser.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	a2g.add_child(browser)
	a2g.split_offset = int(340 * EditorInterface.get_editor_scale())
	# The split-mode button lives in the browser's toolbar — same spot the
	# FileSystem dock's display_mode button sits (right end, file panel).
	browser.split = a2g
	# A finished scan reindexes — refresh the browser so results appear
	# without a manual search.
	local.scanned.connect(browser.refresh)
	# The Sources selection picks the right pane: index browser or the
	# downloaded-to-project surface (the "Downloaded to project" row).
	local.view_mode_selected.connect(browser.show_view_mode)
	tabv.add_child(a2g)
	panes.add_child(a2g_pane)
	# A2G entries inside Godot's own context menus — FileSystem dock
	# ("Scan folder as root") and Scene tree ("Show scene resources").
	_ctx_fs = A2GContextPlugin.new(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM)
	_ctx_fs.add_scan_root.connect(local.add_scan_root)
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, _ctx_fs)
	_ctx_scene = A2GContextPlugin.new(EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TREE)
	_ctx_scene.browse_scene_resources.connect(func(): open_a2g("scene"))
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TREE, _ctx_scene)
	gallery = gallery_scene.instantiate()
	gallery.plugin = self
	gallery.name = "BlendKit"
	# Right-click quick download on BlendKit cards too — the same compact
	# tile remote-provider cards get, installed without upstream edits.
	A2GUI.install_bk_quick_download(get_tree(), gallery)
	# Polyhaven: same kind of main tab as BlendKit, but pure GDScript —
	# the public CC0 API needs neither login nor the Client.
	var polyhaven := A2GPolyhaven.new()
	polyhaven.plugin = self
	polyhaven.name = "Polyhaven"
	# ambientCG: second pure-GDScript provider — public v3 API, all-CC0
	# catalog, downloads are extracted zip archives.
	var ambientcg := A2GAmbientcg.new()
	ambientcg.plugin = self
	ambientcg.name = "ambientCG"
	# Tab order is the PROVIDERS order — alphabetical by title; where a
	# pane is constructed above doesn't matter, the registry decides.
	var provider_panes := {
		"ambientcg": ambientcg,
		"blendkit": gallery,
		"polyhaven": polyhaven,
	}
	for pd in PROVIDERS:
		var pane: Control = provider_panes.get(pd.get("key", ""))
		if pane != null:
			_add_tab_pane(panes, pane, str(pd.get("key")))
	main_screen.hide()
	EditorInterface.get_editor_main_screen().add_child(main_screen)
	# The A2G toggle on the right carries the FileSystem dock's own icon,
	# reading "opens the file organization panel" rather than a logo mark.
	for icon_name in [&"Filesystem", &"Folder"]:
		var ic := main_screen.get_theme_icon(icon_name, "EditorIcons")
		if ic:
			_a2g_button.icon = ic
			break
	# FlatButton's pressed state tints the icon accent but leaves the
	# font neutral — Godot's own panel toggles paint the label too.
	var accent := main_screen.get_theme_color(&"accent_color", &"Editor")
	_a2g_button.add_theme_color_override("font_pressed_color", accent)
	_a2g_button.add_theme_color_override("font_hover_pressed_color", accent)
	# The dock toggle borrows the editor's own dock glyph (4.7's
	# EditorDock icon; DistractionFree/GuiTab as older fallbacks).
	for dock_icon in [&"EditorDock", &"DistractionFree", &"GuiTab"]:
		var dic := main_screen.get_theme_icon(dock_icon, "EditorIcons")
		if dic:
			_dock_button.icon = dic
			break
	# A provider switched off in the settings menu starts hidden — the
	# first visible tab is the startup selection, not hardcoded tab 0.
	var first := _first_enabled_tab()
	_tab_bar.current_tab = first
	_show_tab(first)


## Registers [param pane] as a full-rect stack pane plus a TabBar tab
## titled with the pane's name. A provider [param key] puts the pane in
## the provider registry (Sources rows, settings switches) and honors a
## stored tab-off setting. Tabs stay text-only unless the A2G menu's
## "Provider logos in tabs" switch (assets2godot/tab_logos) is on —
## _apply_tab_logo renders the mark then.
## Returns the tab index.
func _add_tab_pane(panes: Control, pane: Control, key := "") -> int:
	pane.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pane.hide()
	panes.add_child(pane)
	_tab_panes.append(pane)
	_tab_bar.add_tab(pane.name)
	var idx := _tab_bar.tab_count - 1
	if key != "":
		_provider_panes[key] = pane
		_apply_tab_logo(idx)
		if not provider_enabled(key):
			_set_tab_visible(idx, false)
	return idx


## Whether provider tabs carry their logo — the A2G menu's "Provider
## logos in tabs" switch (assets2godot/tab_logos), default off.
func tab_logos_enabled() -> bool:
	var es := EditorInterface.get_editor_settings()
	if es and es.has_setting(SETTING_A2G_TAB_LOGOS):
		return bool(es.get_setting(SETTING_A2G_TAB_LOGOS))
	return false


## The settings menu's logo switch — persists and re-applies every tab
## icon immediately, so the change needs neither restart nor reload.
func set_tab_logos(enabled: bool) -> void:
	var es := EditorInterface.get_editor_settings()
	if es:
		es.set_setting(SETTING_A2G_TAB_LOGOS, enabled)
	for i in _tab_panes.size():
		_apply_tab_logo(i)


## Sets or clears the tab's provider logo per the tab_logos setting.
## Off = a null icon — plain text like the editor's own tabs. On =
## the provider's mark rendered under the icon_max_width cap
## (style_tabbar copied it from TabContainer) so it stays padded.
func _apply_tab_logo(idx: int) -> void:
	var key := _pane_provider_key(_tab_panes[idx])
	var icon: Texture2D = null
	if not key.is_empty() and tab_logos_enabled():
		icon = A2GUI.provider_icon(key, TAB_LOGO_PX)
	_tab_bar.set_tab_icon(idx, icon)
	_tab_bar.set_tab_icon_max_width(idx,
		int(TAB_LOGO_PX * EditorInterface.get_editor_scale()))


## The registered provider key owning [param pane], "" for a pane that
## isn't a provider tab.
func _pane_provider_key(pane: Control) -> String:
	for key in _provider_panes:
		if _provider_panes[key] == pane:
			return key
	return ""


## Whether provider [param key]'s tab is on — the settings menu's
## switches and the providers' own catalog gates share this answer.
func provider_enabled(key: String) -> bool:
	var es := EditorInterface.get_editor_settings()
	var setting := SETTING_A2G_PROVIDER % key
	if es and es.has_setting(setting):
		return bool(es.get_setting(setting))
	return true


## The pane registered under provider [param key], or null — the Sources
## tree's remote rows and the A2G downloads surface find their provider
## this way.
func provider_pane(key: String) -> Control:
	return _provider_panes.get(key)


## Switch a provider tab on/off from the settings menu. Off = hidden tab
## + hidden pane; a daemon provider's Client keeps running regardless
## (the A2G index needs it) and an in-plugin provider simply never
## fetches — its gate in _reload() covers late calls too.
func set_provider_enabled(key: String, enabled: bool) -> void:
	var pane: Control = _provider_panes.get(key)
	if pane == null:
		return
	var es := EditorInterface.get_editor_settings()
	if es:
		es.set_setting(SETTING_A2G_PROVIDER % key, enabled)
	var idx := _tab_panes.find(pane)
	if idx < 0:
		return
	_set_tab_visible(idx, enabled)
	if not enabled:
		pane.hide()
		if _tab_bar.current_tab == idx:
			var next := _first_enabled_tab()
			if next >= 0:
				select_tab(next)
			else:
				_show_tab(-1)


## Hidden when the API allows it, merely disabled on Godot versions
## without TabBar.set_tab_hidden — either way the tab stops offering
## the pane.
func _set_tab_visible(idx: int, visible_tab: bool) -> void:
	if _tab_bar.has_method("set_tab_hidden"):
		_tab_bar.set_tab_hidden(idx, not visible_tab)
	else:
		_tab_bar.set_tab_disabled(idx, not visible_tab)


func _tab_shown(idx: int) -> bool:
	if _tab_bar.has_method("is_tab_hidden"):
		return not _tab_bar.is_tab_hidden(idx)
	return not _tab_bar.is_tab_disabled(idx)


func _first_enabled_tab() -> int:
	for i in _tab_panes.size():
		if _tab_shown(i):
			return i
	return -1


## Shows TabBar tab [param idx] and closes the A2G overlay. Bound to the
## TabBar's tab_selected and used by programmatic entry points.
func _show_tab(idx: int) -> void:
	if _a2g_button != null and _a2g_button.button_pressed:
		_a2g_button.set_pressed_no_signal(false)
	if a2g_pane != null:
		a2g_pane.hide()
	for i in _tab_panes.size():
		_tab_panes[i].visible = i == idx


func select_tab(idx: int) -> void:
	if idx < 0 or idx >= _tab_panes.size() or not _tab_shown(idx):
		return
	_tab_bar.current_tab = idx
	_show_tab(idx)


## Switch to the tab owning [param pane] — e.g. a cross-surface link
## jumping back to a provider tab.
func select_provider(pane: Control) -> void:
	select_tab(_tab_panes.find(pane))


func _on_a2g_toggled(pressed: bool) -> void:
	if pressed:
		for p in _tab_panes:
			p.hide()
		a2g_pane.show()
	else:
		_show_tab(_tab_bar.current_tab)


# MARK: panel docking — the whole A2G surface as a native editor dock

## The assets2godot/panel_mode setting: 0 = embedded main screen, 1 =
## a docked EditorDock whose own ⋮ menu (Dock Position / Make Floating
## / Close) the editor provides like for every other dock.
func panel_mode() -> int:
	var es := EditorInterface.get_editor_settings()
	if es and es.has_setting(SETTING_A2G_PANEL_MODE):
		return int(es.get_setting(SETTING_A2G_PANEL_MODE))
	return PanelMode.EMBEDDED


## The header's dock toggle and the settings share this entry — the
## setting persists, the reparent applies immediately.
func set_panel_mode(mode: int) -> void:
	var es := EditorInterface.get_editor_settings()
	if es:
		es.set_setting(SETTING_A2G_PANEL_MODE, mode)
	if mode == PanelMode.DOCKED and not _panel_docked:
		_undock_panel()
	elif mode == PanelMode.EMBEDDED and _panel_docked:
		_redock_panel()


## Moves main_screen into an EditorDock — the editor then owns its tab,
## position, floating and layout persistence (layout_key). On Godot
## <4.6 without EditorDock the legacy dock call does the same job.
func _undock_panel() -> void:
	if _panel_docked or main_screen == null:
		return
	_panel_docked = true
	if ClassDB.class_exists("EditorDock") and has_method(&"add_dock"):
		_a2g_dock_shell = ClassDB.instantiate("EditorDock")
		_a2g_dock_shell.set("title", "A2G")
		_a2g_dock_shell.set("layout_key", "assets2godot")
		# DOCK_SLOT_LEFT_UL — empty in the default layout, next to the
		# Scene/FileSystem docks a dragged card comes from.
		_a2g_dock_shell.set("default_slot", 0)
		_a2g_dock_shell.set("available_layouts", 7)  # DOCK_LAYOUT_ALL
		_a2g_dock_shell.set("global", true)
		_a2g_dock_shell.set("closable", true)
		var icon := _get_plugin_icon()
		if icon != null:
			_a2g_dock_shell.set("dock_icon", icon)
		_a2g_dock_shell.set("force_show_icon", true)
		main_screen.reparent(_a2g_dock_shell)
		call("add_dock", _a2g_dock_shell)
	else:
		add_control_to_dock(DOCK_SLOT_LEFT_UL, main_screen)
	main_screen.show()
	_make_placeholder()
	_refresh_dock_button()


## Back to the main screen — the dock shell is discarded; docking again
## rebuilds it (last position comes from the editor's layout, not us).
func _redock_panel() -> void:
	if not _panel_docked or main_screen == null:
		return
	_panel_docked = false
	if _a2g_dock_shell != null:
		if has_method(&"remove_dock"):
			call("remove_dock", _a2g_dock_shell)
		main_screen.reparent(EditorInterface.get_editor_main_screen())
		_a2g_dock_shell.queue_free()
		_a2g_dock_shell = null
	else:
		call("remove_control_from_docks", main_screen)
		EditorInterface.get_editor_main_screen().add_child(main_screen)
	if _a2g_placeholder != null:
		_a2g_placeholder.hide()
	_refresh_dock_button()
	# The user asked for the surface — make it the active screen.
	EditorInterface.set_main_screen_editor(_get_plugin_name())


## What the A2G screen shows while the panel is docked elsewhere — the
## mode is deactivated, the note says why and offers the way back.
func _make_placeholder() -> void:
	if _a2g_placeholder != null:
		return
	var edscale := EditorInterface.get_editor_scale()
	var c := CenterContainer.new()
	c.name = "A2GDockedPlaceholder"
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", int(8 * edscale))
	var l := Label.new()
	l.text = "The A2G panel is docked — the dock's ⋮ menu moves, floats and closes it."
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(l)
	var b := Button.new()
	b.text = "Dock back to the main screen"
	b.pressed.connect(func(): set_panel_mode(PanelMode.EMBEDDED))
	v.add_child(b)
	c.add_child(v)
	c.hide()
	EditorInterface.get_editor_main_screen().add_child(c)
	_a2g_placeholder = c


func _refresh_dock_button() -> void:
	if _dock_button != null:
		_dock_button.set_pressed_no_signal(_panel_docked)


## The remote-drop overlays — one parked on the 3D viewport's input
## surface, one on the FileSystem dock's list. Each re-attaches itself
## to the current host inside _process, so a plain add_child under the
## base control is all the lifecycle they need.
func _install_drop_overlays() -> void:
	var base := EditorInterface.get_base_control()
	if base == null:
		return
	var scene_ov: Control = A2GSceneDrop.new()
	scene_ov.parking = base
	base.add_child(scene_ov)
	_drop_overlays.append(scene_ov)
	var fs_ov: Control = A2GSceneDrop.new()
	fs_ov.mode = A2GSceneDrop.Mode.FILESYSTEM
	fs_ov.parking = base
	base.add_child(fs_ov)
	_drop_overlays.append(fs_ov)


## Public entry: open the A2G organization surface; [param section]
## names a Sources-tree row to select ("scene" once the Assets tab is
## folded in — ignored until then).
func open_a2g(section := "") -> void:
	if _a2g_button != null:
		_a2g_button.button_pressed = true
	if not section.is_empty() and _a2g_dock != null:
		_a2g_dock.select_section(section)


# MARK: settings

func set_client_enabled(enabled: bool) -> void:
	if enabled == client_enabled:
		return
	client_enabled = enabled
	EditorInterface.get_editor_settings().set_setting(SETTING_CLIENT_ENABLED, enabled)
	if enabled:
		connection.start()
	else:
		connection.stop()


func restart_client() -> void:
	set_client_enabled(false)
	set_client_enabled(true)


func set_download_dir(dir: String) -> void:
	if dir == download_dir:
		return
	download_dir = dir
	save_project_setting(SETTING_DOWNLOAD_DIR, download_dir)
	absolute_download_path = ProjectSettings.globalize_path(download_dir)
	log_info("Download path set to: %s" % absolute_download_path)
	download_dir_changed.emit()


func set_log_level(level: int) -> void:
	if level == log_level:
		return
	log_level = level
	EditorInterface.get_editor_settings().set_setting(SETTING_LOG_LEVEL, log_level)
	log_info("Log level set to %s" % LogLevel.keys()[log_level])


func set_preferred_port(new_port: String) -> void:
	if new_port == preferred_port:
		return
	preferred_port = new_port
	EditorInterface.get_editor_settings().set_setting(SETTING_PORT, preferred_port)


func set_model_format(format: String) -> void:
	if format == model_format:
		return
	model_format = format
	save_project_setting(SETTING_MODEL_FORMAT, model_format)
	model_format_changed.emit()


## Godot's switch for .blend import, which applies after a restart.
func set_blend_import_enabled(enabled: bool) -> void:
	if enabled == BlenderImport.blend_import_enabled():
		return
	save_project_setting(BlenderImport.GODOT_ENABLED, enabled)
	log_info(".blend import %s" % ("enabled" if enabled else "disabled"))


func set_blender_path(path: String) -> void:
	if path == BlenderImport.blender_path():
		return
	EditorInterface.get_editor_settings().set_setting(BlenderImport.GODOT_BLENDER_PATH, path)
	log_info("Blender path set to %s" % path if path else "Blender path cleared")


## Whether .blend import [param enabled] with Blender at [param path] differs
## from what Godot set up when the editor started.
func blend_import_needs_restart(enabled: bool, path: String) -> bool:
	return enabled != startup_blend_enabled or (enabled and path != startup_blender_path)


## The resolution to download, with Auto resolved.
func download_resolution() -> String:
	return AUTO_RESOLUTION if resolution.is_empty() else resolution


func set_uuid_names(new_uuid_names: String) -> void:
	if new_uuid_names == uuid_names:
		return
	uuid_names = new_uuid_names
	save_project_setting(SETTING_UUID_NAMES, uuid_names)


func set_resolution(new_resolution: String) -> void:
	if new_resolution == resolution:
		return
	resolution = new_resolution
	save_project_setting(SETTING_RESOLUTION, RESOLUTION_AUTO if resolution.is_empty() else resolution)


## Registers the settings with Godot and reads them, without side effects
## so it can run before the plugin is set up.
func init_settings() -> void:
	add_project_setting(SETTING_DOWNLOAD_DIR, download_dir, PROPERTY_HINT_DIR)
	add_project_setting(SETTING_MODEL_FORMAT, model_format, PROPERTY_HINT_ENUM,
		",".join(MODEL_FORMATS.map(func(f): return f[0])))
	add_project_setting(SETTING_RESOLUTION, RESOLUTION_AUTO, PROPERTY_HINT_ENUM,
		",".join(RESOLUTIONS.map(func(r): return r[0] if r[0] else RESOLUTION_AUTO)))
	add_project_setting(SETTING_UUID_NAMES, uuid_names, PROPERTY_HINT_ENUM, ",".join(UUID_NAMES.map(func(n): return n[0])))
	add_editor_setting(SETTING_CLIENT_ENABLED, client_enabled)
	add_editor_setting(SETTING_PORT, preferred_port, PROPERTY_HINT_ENUM, ",".join(ClientConnection.CLIENT_PORTS))
	add_editor_setting(SETTING_LOG_LEVEL, log_level, PROPERTY_HINT_ENUM, ",".join(LogLevel.keys()))
	add_editor_setting(SETTING_A2G_VIEW, 0, PROPERTY_HINT_ENUM, "Grid,List")
	add_editor_setting(SETTING_A2G_THUMB_SIZE, 256, PROPERTY_HINT_ENUM, "128,256,512")
	add_editor_setting(SETTING_A2G_SCENE_CAP, 300, PROPERTY_HINT_RANGE, "50,2000,50")
	add_editor_setting(SETTING_A2G_SHOW_FILES, false)
	add_editor_setting(SETTING_A2G_TAB_LOGOS, false)
	add_editor_setting(SETTING_A2G_PANEL_MODE, PanelMode.EMBEDDED, PROPERTY_HINT_ENUM,
		"Embedded,Docked")
	# Provider download dirs — "" means the provider's own default root
	# under res://Assets2Godot/<key>; the keys live in the tab classes.
	add_editor_setting(A2GPolyhaven.SETTING_DIR, "")
	add_editor_setting(A2GAmbientcg.SETTING_DIR, "")
	for p in PROVIDERS:
		add_editor_setting(SETTING_A2G_PROVIDER % str(p.get("key", "")), true)
	# After registering, so migrated defaults aren't written to project.godot.
	for old in OLD_SETTINGS:
		if ProjectSettings.has_setting(old):
			var value = ProjectSettings.get_setting(old)
			var key: String = OLD_SETTINGS[old]
			if key == SETTING_RESOLUTION and str(value).is_empty():
				value = RESOLUTION_AUTO
			if not str(value).is_empty():
				ProjectSettings.set_setting(key, value)
			ProjectSettings.set_setting(old, null)
			ProjectSettings.save()

	var editor_settings := EditorInterface.get_editor_settings()
	download_dir = ProjectSettings.get_setting(SETTING_DOWNLOAD_DIR)
	model_format = ProjectSettings.get_setting(SETTING_MODEL_FORMAT)
	resolution = _resolution_setting()
	uuid_names = ProjectSettings.get_setting(SETTING_UUID_NAMES)
	client_enabled = editor_settings.get_setting(SETTING_CLIENT_ENABLED)
	preferred_port = editor_settings.get_setting(SETTING_PORT)
	log_level = editor_settings.get_setting(SETTING_LOG_LEVEL)


## Applies settings changed elsewhere, e.g. in Godot's settings dialogs.
func load_settings() -> void:
	var editor_settings := EditorInterface.get_editor_settings()
	set_log_level(editor_settings.get_setting(SETTING_LOG_LEVEL))
	set_download_dir(ProjectSettings.get_setting(SETTING_DOWNLOAD_DIR))
	set_model_format(ProjectSettings.get_setting(SETTING_MODEL_FORMAT))
	set_resolution(_resolution_setting())
	set_uuid_names(ProjectSettings.get_setting(SETTING_UUID_NAMES))
	set_preferred_port(editor_settings.get_setting(SETTING_PORT))
	set_client_enabled(editor_settings.get_setting(SETTING_CLIENT_ENABLED))
	if editor_settings.has_setting(SETTING_A2G_PANEL_MODE):
		var want := int(editor_settings.get_setting(SETTING_A2G_PANEL_MODE))
		# set_panel_mode() also writes the setting — syncing only on an
		# actual mode mismatch keeps the settings_changed echo out.
		if (want == PanelMode.DOCKED) != _panel_docked:
			set_panel_mode(want)


func _resolution_setting() -> String:
	var value: String = ProjectSettings.get_setting(SETTING_RESOLUTION)
	return "" if value == RESOLUTION_AUTO else value


static func add_project_setting(key: String, default: Variant, hint := PROPERTY_HINT_NONE, hint_string := "") -> void:
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, default)
	ProjectSettings.add_property_info({"name": key, "type": typeof(default), "hint": hint, "hint_string": hint_string})
	# Values equal to the initial one aren't written to project.godot.
	ProjectSettings.set_initial_value(key, default)
	ProjectSettings.set_as_basic(key, true)


static func add_editor_setting(key: String, default: Variant, hint := PROPERTY_HINT_NONE, hint_string := "") -> void:
	var settings := EditorInterface.get_editor_settings()
	if not settings.has_setting(key):
		settings.set_setting(key, default)
	settings.add_property_info({"name": key, "type": typeof(default), "hint": hint, "hint_string": hint_string})
	settings.set_initial_value(key, default, false)


static func save_project_setting(key: String, value: Variant) -> void:
	ProjectSettings.set_setting(key, value)
	ProjectSettings.save()


## Read once, as it's sent with every Client request.
func get_addon_version() -> String:
	if addon_version.is_empty():
		var config := ConfigFile.new()
		var err := config.load("res://addons/assets2godot/plugin.cfg")
		addon_version = str(config.get_value("plugin", "version", "unknown")) if err == OK else "unknown"
	return addon_version
