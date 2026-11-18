@tool
extends AcceptDialog
## Settings opened from the Blendkit or A2G menu. Changes apply right away.
## Project rows save to project.godot under blendkit/*; Editor and
## Assets2Godot rows save to editor settings under blendkit/* and
## assets2godot/* — all visible in Project/Editor Settings too.

const BlenderImport = preload("res://addons/assets2godot/blender_import.gd")
const AcgApi = preload("res://addons/assets2godot/a2g/ambientcg_api.gd")
const AcgTerrain = preload("res://addons/assets2godot/a2g/a2g_terrain.gd")
const BlenderImportDialog = preload("res://addons/assets2godot/ui/blender_import_dialog.gd")
const ClientConnection = preload("res://addons/assets2godot/client_connection.gd")
const GalleryApi = preload("res://addons/assets2godot/ui/gallery/gallery_api.gd")

var plugin: EditorPlugin

var _grid: GridContainer
var _download_dir: LineEdit
var _download_dir_dialog: EditorFileDialog
var _model_format: OptionButton
var _blend_import: Button
# Opened from the Blender Import row, back to Settings after Apply or Cancel.
var _blender_import_dialog: BlenderImportDialog
var _resolution: OptionButton
var _uuid_names: OptionButton
var _port: OptionButton
var _log_level: OptionButton
var _a2g_view: OptionButton
var _a2g_thumb: OptionButton
var _a2g_cap: OptionButton
var _a2g_files: CheckBox
var _a2g_panel: OptionButton
var _a2g_tablogos: CheckBox
# Provider tab switches — provider key → its CheckBox, same rows the
# A2G menu offers above its fine-tuning shortcuts.
var _prov_checks := {}
var _player_path: LineEdit
var _player_dialog: EditorFileDialog
var _terrain_extent: SpinBox
var _terrain_relief: SpinBox
var _terrain_res: OptionButton
var _tex_format: OptionButton
var _fmt_rows := {}
var _res_rows := {}
# Texture-bearing providers with a jpg/png choice — values in the
# provider's own casing (Polyhaven lists lowercase resolutions).
const PROVIDER_DEFAULTS := [
	{"key": "ambientcg", "title": "ambientCG", "res": ["1K", "2K", "4K", "8K"]},
	{"key": "polyhaven", "title": "Polyhaven", "res": ["1k", "2k", "4k", "8k"]},
]


## Called by the menu once the plugin is known.
func setup(new_plugin: EditorPlugin) -> void:
	plugin = new_plugin
	title = "Assets2Godot Settings"
	ok_button_text = "Close"
	var edscale := EditorInterface.get_editor_scale()
	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.add_theme_constant_override("h_separation", int(12 * edscale))
	_grid.add_theme_constant_override("v_separation", int(6 * edscale))
	add_child(_grid)

	_section("Providers", "Which provider tabs the panel shows.\nSaved in your editor settings — the A2G menu's check rows toggle the same settings.")
	for p in plugin.PROVIDERS:
		var key := str(p.get("key", ""))
		var title_p := str(p.get("title", key))
		var check := CheckBox.new()
		check.text = "Show the %s tab" % title_p
		# .bind() freezes the key — a lambda's capture of the loop var
		# would alias every row to the last provider.
		check.toggled.connect(_on_provider_enabled.bind(key))
		_row(title_p, check, "Show the %s tab.%s" % [title_p,
			" The Client keeps running — the A2G index needs it." if bool(p.get("daemon", false)) \
				else " Its catalog never fetches while off."])
		_prov_checks[key] = check

	_section("A2G panel", "The Assets2Godot panel itself — where it lives and how its tabs look.\nSaved in your editor settings. Also in Editor Settings → Assets2Godot.")
	_a2g_panel = _options(["Embedded (main screen)", "Docked"])
	_a2g_panel.item_selected.connect(func(i): plugin.set_panel_mode(i))
	_row("A2G panel", _a2g_panel, "Where the Assets2Godot panel opens.\nEmbedded keeps it inside its own main screen; Docked moves it into a native editor dock — the dock's ⋮ menu then offers dock position, floating and close, and the header button toggles the same setting.")
	_a2g_tablogos = CheckBox.new()
	_a2g_tablogos.text = "Show provider logos in the main tabs"
	_a2g_tablogos.toggled.connect(plugin.set_tab_logos)
	_row("Provider logos", _a2g_tablogos, "Marks BlendKit, Polyhaven and ambientCG tabs with their provider logo.\nOff keeps the tabs text-only like the editor's own — the A2G menu's 'Provider logos in tabs' toggles the same setting.")

	_section("A2G download defaults", "Which option drag & drop, the quick-download tile and the details popup preselect for texture-bearing providers.\nProvider rows override the global default; 'Provider default' inherits it.\nAlso in Editor Settings → Assets2Godot.")
	_tex_format = _options(["Auto (PNG when the asset has an opacity map)", "JPEG", "PNG"])
	_tex_format.item_selected.connect(func(i): _set_es("assets2godot/texture_format", ["auto", "jpg", "png"][i]))
	_row("Texture format", _tex_format, "Default map format for new texture downloads.\nAuto picks PNG when the asset ships an opacity map (alpha needs lossless edges) and JPEG otherwise — JPEG is ~3× smaller.\nPNG keeps mask edges lossless; JPEG still renders transparent through the alpha bake, just with softer/noisier cutout edges.")
	for p in PROVIDER_DEFAULTS:
		var fmt := _options(["Provider default", "Auto", "JPEG", "PNG"])
		# .bind() freezes the provider key — a lambda's capture of the
		# loop var would alias every row to the last provider.
		fmt.item_selected.connect(_on_provider_fmt.bind(str(p["key"])))
		_row("%s texture format" % p["title"], fmt,
			"Overrides the global Texture format for %s. Provider default inherits it." % p["title"])
		_fmt_rows[p["key"]] = fmt
		var res_items: Array = ["Provider default"] + p["res"]
		var res := _options(res_items)
		res.item_selected.connect(_on_provider_res.bind(str(p["key"]), Array(p["res"])))
		_row("%s resolution" % p["title"], res,
			"Resolution preselected for %s downloads — the provider tab's Resolution dropdown writes the same setting." % p["title"])
		_res_rows[p["key"]] = res

	_player_path = LineEdit.new()
	_player_path.text_submitted.connect(func(_t): _apply_player_path())
	_player_path.focus_exited.connect(_apply_player_path)
	_player_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var player_browse := Button.new()
	player_browse.icon = get_theme_icon("FolderBrowse", "EditorIcons")
	player_browse.theme_type_variation = "EditorInspectorButton"
	player_browse.tooltip_text = "Locate the Substance 3D Player executable."
	player_browse.pressed.connect(func():
		_player_dialog.current_path = _player_path.text.strip_edges()
		_player_dialog.popup_file_dialog())
	var player_row := HBoxContainer.new()
	player_row.add_child(_player_path)
	player_row.add_child(player_browse)
	_player_dialog = EditorFileDialog.new()
	_player_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_player_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	_player_dialog.add_filter("*.exe;Executable")
	_player_dialog.file_selected.connect(func(p):
		_player_path.text = p
		_apply_player_path())
	add_child(_player_dialog)

	_section("Tools", "External helpers optional features integrate with.\nSaved in your editor settings.")
	_row("Substance Player", player_row, "Substance 3D Player location for ambientCG .sbsar assets.\nEmpty = auto-detect Creative Cloud / legacy installs (shown as placeholder).\nThe details popup's 'Open in Substance Player' works through the file association either way.")
	_player_path.tooltip_text = player_row.tooltip_text

	_section("Terrain defaults", "Values baked into ambientCG terrains at placement —\nexisting meshes keep what they were placed with.")
	_terrain_extent = _spin(10, 50000, 10, "m")
	_terrain_extent.value_changed.connect(func(v): _set_es(AcgTerrain.SETTING_EXTENT, v))
	_row("Terrain extent", _terrain_extent, "XZ footprint baked into placed ambientCG terrains when no sibling OBJ gives real meters.\nAffects the next placement, not existing meshes.")
	_terrain_relief = _spin(1, 10000, 1, "m")
	_terrain_relief.value_changed.connect(func(v): _set_es(AcgTerrain.SETTING_RELIEF, v))
	_row("Terrain relief", _terrain_relief, "Peak-to-valley height baked into placed terrains (the heightmap is normalized 0–1).")
	_terrain_res = _options(["129", "257", "513", "1025"])
	_terrain_res.item_selected.connect(func(i): _set_es(AcgTerrain.SETTING_RES, int(_terrain_res.get_item_text(i))))
	_row("Terrain grid", _terrain_res, "Vertex grid the heightmap decimates to for placed terrains — 257 keeps ~66k verts, higher costs memory for detail the heightmap may not have.")

	_section("Assets2Godot Files", "The local file browser — how files list, how big thumbs render,\nhow much of the open scene it collects. Saved in your editor settings.\nAlso in Editor Settings → Assets2Godot.")
	_a2g_view = _options(["Grid", "List"])
	# The browser's own persistence key — a2g_browser reads/writes
	# browser_display_mode; anything else would be a dead setting.
	_a2g_view.item_selected.connect(func(i): _set_es("assets2godot/browser_display_mode", i))
	_row("Browser view", _a2g_view, "How the Assets2Godot file browser shows assets: gallery tiles or a compact list.\nThe browser toolbar's list/tile button changes the same setting.")
	_a2g_thumb = _options(["128", "256", "512"])
	_a2g_thumb.item_selected.connect(func(i): _set_es("assets2godot/thumb_size", [128, 256, 512][i]))
	_row("Thumb size", _a2g_thumb, "Render size for thumbnails of files outside res://.\nApplies to thumbnails rendered after the change.")
	_a2g_cap = _options(["50", "150", "300", "600", "1000"])
	_a2g_cap.item_selected.connect(func(i): _set_es("assets2godot/scene_resource_cap", [50, 150, 300, 600, 1000][i]))
	_row("Scene resources cap", _a2g_cap, "Maximum resources collected from the open scene for the Assets tab.\nHigher values cover bigger scenes at a slower collect.")
	_a2g_files = CheckBox.new()
	_a2g_files.text = "Show non-visual files by default"
	_a2g_files.toggled.connect(func(on): _set_es("assets2godot/show_all_files", on))
	_row("Show all files", _a2g_files, "Initial state of the Assets tab's 'Show all files' checkbox —\ntext files, configs and scripts that have no visual preview.")


	_section("BlendKit project", "The BlendKit gallery's own settings — saved in project.godot and\nshared with everyone working on this project. Also in Project Settings → Blendkit.")
	_download_dir = LineEdit.new()
	_download_dir.text_submitted.connect(func(_t): _apply_download_dir())
	_download_dir.focus_exited.connect(_apply_download_dir)
	_download_dir.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Like EditorPropertyPath in Project Settings: path and a browse button.
	var browse := Button.new()
	browse.icon = get_theme_icon("FolderBrowse", "EditorIcons")
	# Godot 4.6+, older versions fall back to the plain Button style.
	browse.theme_type_variation = "EditorInspectorButton"
	browse.tooltip_text = "Choose the download folder."
	browse.pressed.connect(_browse_download_dir)
	var download_row := HBoxContainer.new()
	download_row.add_child(_download_dir)
	download_row.add_child(browse)
	_download_dir_dialog = EditorFileDialog.new()
	_download_dir_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	_download_dir_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_download_dir_dialog.dir_selected.connect(_on_download_dir_selected)
	add_child(_download_dir_dialog)
	_row("BlendKit download dir", download_row, "Directory BlendKit downloads land in (project setting, shared with the team).\nPolyhaven and ambientCG pick their own roots in their tab's folder button.")
	_download_dir.tooltip_text = download_row.tooltip_text
	_blend_import = _dialog_button()
	_blend_import.pressed.connect(func():
		hide()
		_blender_import_dialog.popup_centered())
	_row("Blender Import", _blend_import, "Whether Godot imports .blend files, and the Blender it imports them with.\nClick to change them.")
	_model_format = _options(plugin.MODEL_FORMATS.map(func(f): return f[1]))
	_model_format.item_selected.connect(func(i): plugin.set_model_format(plugin.MODEL_FORMATS[i][0]))
	_row("Model Format", _model_format, "Blender (.blend) downloads .blend files at the selected Resolution, which Godot imports only through Blender.\nglTF (.glb) downloads .glb files exported by Blendkit, which Godot imports directly. Only some models have one, so the Blendkit tab shows only those, and other models fall back to .blend at the selected Resolution.\nExperimental — the bundled Client can crash on these downloads.")
	_resolution = _options(plugin.RESOLUTIONS.map(func(r): return r[1]))
	_resolution.item_selected.connect(func(i): plugin.set_resolution(plugin.RESOLUTIONS[i][0]))
	_row("Resolution", _resolution, "Texture resolution for .blend files, also used when glTF is unavailable. Auto downloads 2K.")
	_uuid_names = _options(plugin.UUID_NAMES.map(func(n): return n[1]))
	_uuid_names.item_selected.connect(func(i): plugin.set_uuid_names(plugin.UUID_NAMES[i][0]))
	_row("UUIDs in Names", _uuid_names, "How downloaded folders and files are named, for new downloads.\nFull: with the whole asset and file UUIDs, like chair_1a2b3c4d-…/chair_gltf_godot_5e6f7a8b-….glb.\nShort: with their first 8 characters, like chair_1a2b3c4d/chair_gltf_godot_5e6f7a8b.glb.\nStrip: without them, like chair/chair_gltf_godot.glb. Assets with the same name get a short UUID. A newer version of an asset replaces the older one in its folder.")

	_section("BlendKit client", "The vendored Client daemon the BlendKit gallery talks to.\nSaved in your editor settings for all projects. Also in Editor Settings → Blendkit.")
	_port = _options(ClientConnection.CLIENT_PORTS)
	_port.item_selected.connect(func(i): plugin.set_preferred_port(ClientConnection.CLIENT_PORTS[i]))
	_row("Port", _port, "Port on which the plugin starts the Client when none is running.")
	_log_level = _options(plugin.LogLevel.keys())
	_log_level.item_selected.connect(plugin.set_log_level)
	_row("Log Level", _log_level, "Log level for the plugin's output.")

	# A sibling, as a child window would hide with Settings.
	_blender_import_dialog = BlenderImportDialog.new()
	get_parent().add_child(_blender_import_dialog)
	_blender_import_dialog.setup(plugin)
	# Deferred, as Cancel hides the dialog deferred too.
	_blender_import_dialog.confirmed.connect(popup_centered, CONNECT_DEFERRED)
	_blender_import_dialog.canceled.connect(popup_centered, CONNECT_DEFERRED)

	about_to_popup.connect(_load)
	confirmed.connect(_apply_download_dir)


func _load() -> void:
	_download_dir.text = plugin.download_dir
	_load_blend_import()
	_model_format.select(GalleryApi.option_index(plugin.MODEL_FORMATS, plugin.model_format))
	_resolution.select(GalleryApi.option_index(plugin.RESOLUTIONS, plugin.resolution))
	_uuid_names.select(GalleryApi.option_index(plugin.UUID_NAMES, plugin.uuid_names))
	_port.select(maxi(0, ClientConnection.CLIENT_PORTS.find(plugin.preferred_port)))
	_log_level.select(plugin.log_level)
	_a2g_view.select(clampi(_es("assets2godot/browser_display_mode", 0), 0, 1))
	_a2g_thumb.select(maxi(0, [128, 256, 512].find(_es("assets2godot/thumb_size", 256))))
	_a2g_cap.select(maxi(0, [50, 150, 300, 600, 1000].find(_es("assets2godot/scene_resource_cap", 300))))
	_a2g_files.button_pressed = bool(_es("assets2godot/show_all_files", false))
	_a2g_panel.select(clampi(plugin.panel_mode(), 0, 1))
	_a2g_tablogos.button_pressed = plugin.tab_logos_enabled()
	for key in _prov_checks:
		_prov_checks[key].set_pressed_no_signal(plugin.provider_enabled(key))
	_load_player_path()
	_terrain_extent.set_value_no_signal(float(_es(AcgTerrain.SETTING_EXTENT, AcgTerrain.DEFAULT_EXTENT_M)))
	_terrain_relief.set_value_no_signal(float(_es(AcgTerrain.SETTING_RELIEF, AcgTerrain.DEFAULT_RELIEF_M)))
	_terrain_res.select(maxi(0, [129, 257, 513, 1025].find(int(_es(AcgTerrain.SETTING_RES, AcgTerrain.GRID_RES)))))
	_tex_format.select(maxi(0, ["auto", "jpg", "png"].find(str(_es("assets2godot/texture_format", "auto")))))
	for p in PROVIDER_DEFAULTS:
		var key := str(p["key"])
		_fmt_rows[key].select(maxi(0, ["default", "auto", "jpg", "png"].find(
			str(_es("assets2godot/providers/%s_texture_format" % key, "default")))))
		_res_rows[key].select(maxi(0, ([""] + Array(p["res"])).find(
			str(_es("assets2godot/providers/%s_resolution" % key, "")))))


## Provider tab switches route through the plugin — the same entry the
## A2G menu's check rows use, so tab visibility applies immediately.
func _on_provider_enabled(on: bool, key: String) -> void:
	plugin.set_provider_enabled(key, on)


## Reads/writes the assets2godot/* editor settings — these rows have no
## plugin-level side effects, so they talk to EditorSettings directly.
func _on_provider_fmt(i: int, key: String) -> void:
	_set_es("assets2godot/providers/%s_texture_format" % key,
		["default", "auto", "jpg", "png"][i])


func _on_provider_res(i: int, key: String, res_items: Array) -> void:
	_set_es("assets2godot/providers/%s_resolution" % key,
		"" if i == 0 else str(res_items[i - 1]))


func _es(key: String, fallback: Variant) -> Variant:
	var es := EditorInterface.get_editor_settings()
	if es and es.has_setting(key):
		return es.get_setting(key)
	return fallback


func _set_es(key: String, value: Variant) -> void:
	var es := EditorInterface.get_editor_settings()
	if es:
		es.set_setting(key, value)


## Like the Blender Import choices, warning while .blend import is on without
## Blender. Only checks that the file is there, as running Blender is slow.
func _load_blend_import() -> void:
	var path := BlenderImport.blender_path()
	var native := BlenderImport.blend_import_enabled()
	var missing := native and (path.is_empty() or not FileAccess.file_exists(path))
	if not native:
		_blend_import.text = BlenderImportDialog.CHOICES[BlenderImportDialog.Choice.DONT_IMPORT][0]
	elif missing:
		_blend_import.text = "Blender isn't set up"
	else:
		_blend_import.text = BlenderImportDialog.CHOICES[BlenderImportDialog.Choice.NATIVE][0]
	if plugin.blend_import_needs_restart(native, path):
		_blend_import.text += " (after restart)"
	for color in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		if missing:
			_blend_import.add_theme_color_override(color, get_theme_color("warning_color", "Editor"))
		else:
			_blend_import.remove_theme_color_override(color)


func _browse_download_dir() -> void:
	_download_dir_dialog.current_dir = _download_dir.text.strip_edges()
	_download_dir_dialog.popup_file_dialog()


func _on_download_dir_selected(dir: String) -> void:
	_download_dir.text = dir
	_apply_download_dir()


func _apply_download_dir() -> void:
	plugin.set_download_dir(_download_dir.text.strip_edges())


## Substance Player row: placeholder shows what auto-detect found; a set
## path that doesn't exist earns the warning color like Blender Import.
func _load_player_path() -> void:
	_player_path.text = str(_es("assets2godot/substance_player_path", ""))
	var detected := AcgApi.substance_player_path()
	_player_path.placeholder_text = detected if detected != "" else "Not found — browse or get it from Adobe"
	_mark_player_path()


func _apply_player_path() -> void:
	_set_es("assets2godot/substance_player_path", _player_path.text.strip_edges())
	_mark_player_path()


func _mark_player_path() -> void:
	var custom := _player_path.text.strip_edges()
	var bad := not custom.is_empty() and not FileAccess.file_exists(custom)
	var warn := get_theme_color("warning_color", "Editor")
	if bad:
		_player_path.add_theme_color_override("font_color", warn)
	else:
		_player_path.remove_theme_color_override("font_color")


func _spin(min_v: float, max_v: float, step: float, suffix: String) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = min_v
	spin.max_value = max_v
	spin.step = step
	spin.suffix = suffix
	return spin


## Section headline: caps + emboldened + letter-spaced — the same
## FontVariation recipe the preview panel's headlines use (A2G
## branding), wrapped around the theme's own default font.
func _section(text: String, tooltip: String) -> void:
	var edscale := EditorInterface.get_editor_scale()
	for i in 2:
		var label := Label.new()
		if i == 0:
			label.text = text.to_upper()
			label.tooltip_text = tooltip
			label.mouse_filter = Control.MOUSE_FILTER_PASS
			var fv := FontVariation.new()
			fv.base_font = label.get_theme_default_font()
			fv.variation_embolden = 0.7
			fv.spacing_glyph = 2
			label.add_theme_font_override("font", fv)
			# Fixed 13 like the preview panel's headlines — uniform
			# caps size across every A2G surface.
			label.add_theme_font_size_override("font_size", 13)
		if _grid.get_child_count() > 0:
			label.custom_minimum_size.y = 24 * edscale
			label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		_grid.add_child(label)


func _row(text: String, control: Control, tooltip: String) -> void:
	var label := Label.new()
	label.text = text
	label.tooltip_text = tooltip
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	control.tooltip_text = tooltip
	control.custom_minimum_size.x = 220 * EditorInterface.get_editor_scale()
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_child(label)
	_grid.add_child(control)


## Looks like an OptionButton, with vertical dots for its arrow: shows a value
## and opens a dialog to change it.
func _dialog_button() -> Button:
	var button := Button.new()
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	button.clip_text = true
	button.icon = get_theme_icon("GuiTabMenuHl", "EditorIcons")
	button.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	return button


func _options(items: Array) -> OptionButton:
	var option := OptionButton.new()
	for item in items:
		option.add_item(str(item))
	return option
