@tool
extends RefCounted
## Shared UI helpers for the Assets2Godot surfaces: extension → kind
## classification, kind colors and the gallery-style asset card used by the
## Browser and Assets tabs (styled after ui/gallery/gallery_item.tscn).

const ICON_PATH = "res://addons/assets2godot/a2g/icon.svg"

const KIND_BY_EXT := {
	"fbx": "model", "obj": "model", "gltf": "model", "glb": "model",
	"blend": "model", "dae": "model", "stl": "model", "ply": "model",
	"usd": "model", "usda": "model", "usdc": "model", "usdz": "model",
	"uasset": "ue_asset", "umap": "ue_asset",
	"png": "texture", "jpg": "texture", "jpeg": "texture", "tga": "texture",
	"tif": "texture", "tiff": "texture", "bmp": "texture", "webp": "texture",
	"svg": "texture",
	"exr": "hdr", "hdr": "hdr",
	"mtlx": "material", "tres": "scene_data", "scn": "scene_data",
	"tscn": "scene_data",
	"gd": "script", "gdshader": "script", "cs": "script",
	"wav": "audio", "ogg": "audio", "mp3": "audio", "flac": "audio",
	"json": "metadata",
}


## Asset kind for a filename's extension, or "" for non-asset types.
static func kind_for(file_name: String) -> String:
	return KIND_BY_EXT.get(file_name.get_extension().to_lower(), "")


## Like kind_for() but never returns "": every file is listed, unknown
## extensions become their own kind, extensionless files become "file".
static func kind_for_file(file_name: String) -> String:
	var ext := file_name.get_extension().to_lower()
	return KIND_BY_EXT.get(ext, ext if ext != "" else "file")


## Asset kind for an in-memory Resource (e.g. from the open scene):
## meshes read as "model", materials/textures by class, rest "resource".
static func kind_for_resource(res: Resource) -> String:
	var c := res.get_class().to_lower()
	if "mesh" in c:
		return "model"
	if "material" in c or "shader" in c:
		return "material"
	if "texture" in c or "image" in c:
		return "texture"
	if "animation" in c:
		return "animation"
	if "script" in c or "scene" in c:
		return "scene_data"
	return "resource"

## Kinds that read as visual/playable assets — everything else (text
## files, configs, scripts) only shows when the user asks for it.
const VISUAL_KINDS := ["model", "ue_asset", "material", "texture", "hdr",
	"scene_data", "resource", "animation", "audio"]


## Middle-elides long paths for tooltips: keeps head and tail so the file
## name stays readable ("res://…/a2g/scene.gd").
## A path for display, the way the editor shows them: separators
## normalized, the user home abbreviated to ~, then middle-ellipsized at
## max_len so both ends survive. The full path always stays one hover
## away — callers put it in the tooltip.
static func short_path(path: String, max_len := 56) -> String:
	var p := path.replace("\\", "/")
	var home := OS.get_environment("USERPROFILE") if OS.has_feature("windows") else OS.get_environment("HOME")
	if not home.is_empty():
		home = home.replace("\\", "/").trim_suffix("/")
		if p == home:
			return "~"
		if p.begins_with(home + "/"):
			p = "~" + p.substr(home.length())
	if p.length() <= max_len:
		return p
	var keep := (max_len - 3) / 2
	return p.left(keep) + "…" + p.right(keep)


const GALLERY_ITEM := preload("res://addons/assets2godot/ui/gallery/gallery_item.tscn")
const GalleryItemScript = preload("res://addons/assets2godot/ui/gallery/gallery_item.gd")
const BlenderImport = preload("res://addons/assets2godot/blender_import.gd")
const GalleryApi = preload("res://addons/assets2godot/ui/gallery/gallery_api.gd")
const ProjectAssets = preload("res://addons/assets2godot/ui/gallery/project_assets.gd")
const Plans = preload("res://addons/assets2godot/ui/plans.gd")
const A2GQuickDownload = preload("res://addons/assets2godot/a2g/a2g_quick_download.gd")

## Staged external assets land here — one folder per asset, like the
## architecture spec's res://imported_assets/<asset_name>/.
const STAGING_DIR := "res://imported_assets"
const PREVIEW_IMAGE_EXTS := ["png", "jpg", "jpeg", "tga", "webp", "bmp",
	"exr", "hdr", "tif", "tiff"]


## The identical tile the BlendKit gallery uses — a real GalleryItem scene
## instance configured for a local/indexed asset via setup_a2g(), so every
## A2G surface is pixel-identical by construction. `extra` adds context
## for the right-click menu ("res", "node", "ext").
static func asset_card(title: String, kind: String, source: String, path: String, _icon: Texture2D, type_name: String = "", extra: Dictionary = {}) -> Control:
	var item: Control = GALLERY_ITEM.instantiate()
	var payload := {"path": path, "kind": kind, "source": source}
	payload.merge(extra)
	item.setup_a2g(title, kind, type_name, "%s\n%s · %s\n%s" % [title, kind, source, short_path(path)], payload)
	item.gui_input.connect(func(ev): _on_card_gui_input(item, ev))
	return item


## MARK: asset context menu — right-click actions mirroring the Godot
## FileSystem dock and Scene dock menus, driven by the same engine calls
## upstream uses internally (navigate_to_path, edit_resource,
## open_scene_from_path, edit_node, reimport_files, clipboard_set,
## shell_show_in_file_manager).
enum AssetMenu { SHOW_FS, OPEN, EDIT_RES, SELECT_NODE, COPY_NODE_PATH, REIMPORT, SHOW_FM, COPY_PATH, STAGE, DETAILS }


static func _on_card_gui_input(item: Control, ev: InputEvent) -> void:
	var mb := ev as InputEventMouseButton
	if mb and mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		var asset: Dictionary = item.get("asset")
		asset_context_menu(asset.get("a2g_payload", {}), item)
		item.accept_event()


## Builds a throwaway PopupMenu next to the card — freed on hide, so no
## stale entries survive a rebuild.
static func asset_context_menu(entry: Dictionary, card: Control) -> void:
	var menu := PopupMenu.new()
	card.add_child(menu)
	# Remote-provider cards carry no local path — right-click opens the
	# compact quick-download tile under the cursor (format picker +
	# Download + secondary actions), the same surface BlendKit cards get
	# via install_bk_quick_download. Everything it needs rides in the
	# remote_* payload keys.
	var remote_slug := str(entry.get("remote_slug", ""))
	if remote_slug != "":
		quick_download(card, entry)
		return
	var path := str(entry.get("path", ""))
	var is_res_file := path.begins_with("res://")
	var is_os_file := path != "" and (is_res_file or FileAccess.file_exists(path))
	var res: Resource = entry.get("res")
	var node: Node = entry.get("node")
	var has_res := res != null and is_instance_valid(res)
	var has_node := node != null and is_instance_valid(node)

	# Left-click already pops details; the menu offers it too so the
	# verb survives on touch and on cards whose payload lacks a click.
	var details_cb: Variant = entry.get("details")
	if details_cb is Callable and details_cb.is_valid():
		menu.add_icon_item(_menu_icon("ZoomCheck"), "Details…", AssetMenu.DETAILS)

	if is_res_file:
		# Upstream filesystem_dock order: Open first, then the file ops.
		menu.add_icon_item(_menu_icon("Load"), "Open", AssetMenu.OPEN)
		menu.add_icon_item(_menu_icon("ShowInFileSystem"), "Show in FileSystem", AssetMenu.SHOW_FS)
		menu.add_icon_item(_menu_icon("Reload"), "Reimport", AssetMenu.REIMPORT)
	elif is_os_file:
		# External files can be staged into the project — same intent as
		# dragging a file from the OS into the FileSystem dock.
		menu.add_icon_item(_menu_icon("Import"), "Import into project", AssetMenu.STAGE)
		if path.get_extension().to_lower() == "blend" and not _blend_ready():
			menu.set_item_tooltip(menu.item_count - 1,
				".blend import is off or Blender isn't configured — the staged file stays hidden until Settings → Blender Import is set up.")
	if has_res:
		if menu.item_count:
			menu.add_separator()
		menu.add_icon_item(_menu_icon("Edit"), "Edit Resource", AssetMenu.EDIT_RES)
	if has_node:
		if menu.item_count:
			menu.add_separator()
		menu.add_icon_item(_menu_icon("Edit"), "Select Node in Scene", AssetMenu.SELECT_NODE)
		menu.add_icon_item(_menu_icon("ActionCopy"), "Copy Node Path", AssetMenu.COPY_NODE_PATH)
	if is_os_file:
		if menu.item_count:
			menu.add_separator()
		menu.add_icon_item(_menu_icon("Folder"), "Show in File Manager", AssetMenu.SHOW_FM)
		menu.add_icon_item(_menu_icon("ActionCopy"), "Copy Path", AssetMenu.COPY_PATH)

	if menu.item_count == 0:
		menu.free()
		return
	menu.id_pressed.connect(func(id): _on_asset_menu(id, entry))
	menu.popup_hide.connect(menu.queue_free)
	# Editor-source popup formula (filesystem_dock/scene_tree_dock):
	# screen pos of the control + mouse pos inside it — NOT
	# get_global_mouse_position(), which is viewport/canvas space and
	# lands displaced whenever the popup is a native window.
	menu.position = card.get_screen_position() + card.get_local_mouse_position()
	menu.popup()


## Editor-icons for menu items — the same icon names Godot's own docks use,
## resolved defensively (missing name = no icon, not a crash).
static func _menu_icon(icon_name: StringName) -> Texture2D:
	var theme := EditorInterface.get_editor_theme()
	if theme and theme.has_icon(icon_name, &"EditorIcons"):
		return theme.get_icon(icon_name, &"EditorIcons")
	return null


static func _on_asset_menu(id: int, entry: Dictionary) -> void:
	var path := str(entry.get("path", ""))
	match id:
		AssetMenu.SHOW_FS:
			EditorInterface.get_file_system_dock().navigate_to_path(path)
		AssetMenu.OPEN:
			_open_entry(entry)
		AssetMenu.EDIT_RES:
			var res: Resource = entry.get("res")
			if res != null and is_instance_valid(res):
				EditorInterface.edit_resource(res)
		AssetMenu.SELECT_NODE:
			var node: Node = entry.get("node")
			if node != null and is_instance_valid(node):
				EditorInterface.get_selection().clear()
				EditorInterface.get_selection().add_node(node)
				EditorInterface.edit_node(node)
		AssetMenu.COPY_NODE_PATH:
			var node: Node = entry.get("node")
			if node != null and is_instance_valid(node):
				DisplayServer.clipboard_set(str(node.get_path()))
		AssetMenu.REIMPORT:
			EditorInterface.get_resource_filesystem().reimport_files([path])
		AssetMenu.SHOW_FM:
			OS.shell_show_in_file_manager(ProjectSettings.globalize_path(path) if path.begins_with("res://") else path)
		AssetMenu.COPY_PATH:
			DisplayServer.clipboard_set(path)
		AssetMenu.STAGE:
			stage_into_project(entry)
		AssetMenu.DETAILS:
			var cb2: Variant = entry.get("details")
			if cb2 is Callable and cb2.is_valid():
				cb2.call()


## MARK: quick-download tile — the compact remote surface under the
## cursor (format picker + Download + secondary actions), shared by
## remote-provider cards and the BlendKit gallery.


## Opens the tile for the remote_* [param entry]; one shared PopupPanel
## per card, so repeated right-clicks reuse it.
static func quick_download(card: Control, entry: Dictionary) -> void:
	var tile: PopupPanel = card.get_node_or_null(^"A2GQuickDownload")
	if tile == null:
		tile = A2GQuickDownload.new()
		tile.name = "A2GQuickDownload"
		card.add_child(tile)
	tile.open_for(card, entry)


## The same tile on upstream BlendKit gallery cards, installed once from
## plugin.gd — zero upstream edits: SceneTree.node_added spots
## GalleryItems and connects a right-click handler that builds the
## remote_* entry from the card's own asset dict. Self-disconnects when
## the gallery leaves the tree (plugin disabled).
static func install_bk_quick_download(tree: SceneTree, gallery: Control) -> void:
	# Two lambda pitfalls avoided here: locals are captured by value, so a
	# plain `hook` var would freeze the null it held at lambda creation
	# (self-disconnect never works, the hook then errors on every
	# node_added) — an Array cell carries a live view instead. And a
	# freed `gallery` capture would log "capture was freed" on every
	# invocation — a WeakRef turns that into a clean null check.
	var gallery_ref := weakref(gallery)
	var holder: Array = [Callable()]
	holder[0] = func(node: Node):
		if gallery_ref.get_ref() == null:
			var h: Callable = holder[0]
			if h.is_valid() and tree.node_added.is_connected(h):
				tree.node_added.disconnect(h)
			return
		if node.get_script() != GalleryItemScript or node.has_meta(&"a2g_bk_quick"):
			return
		node.set_meta(&"a2g_bk_quick", true)
		node.gui_input.connect(func(ev): _on_bk_card_input(node, ev, gallery))
	tree.node_added.connect(holder[0])


static func _on_bk_card_input(item: Control, ev: InputEvent, gallery: Control) -> void:
	var mb := ev as InputEventMouseButton
	if not (mb and mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed):
		return
	var asset: Variant = item.get("asset")
	if not asset is Dictionary or asset.is_empty() or asset.get("a2g", false):
		return
	item.accept_event()
	quick_download(item, _bk_remote_entry(asset, gallery))


## The BlendKit asset dict → the remote_* contract the tile consumes.
## File options come from the asset's files; downloads go through the
## gallery's own Downloads model so progress shows on the card as usual.
static func _bk_remote_entry(asset: Dictionary, gallery: Control) -> Dictionary:
	var plugin = gallery.get("plugin")
	var opts := _bk_options(asset, plugin)
	var default_ft := GalleryApi.pick_file_type(asset,
		str(plugin.model_format), plugin.download_resolution())
	var default_idx := -1
	for i in opts.size():
		if str(opts[i].get("key", "")) == default_ft:
			default_idx = i
	return {
		"remote_slug": GalleryApi.base_id(asset),
		"remote_title": str(asset.get("displayName", asset.get("name", ""))),
		"remote_url": GalleryApi.web_url(plugin.SERVER, asset),
		"remote_site": "blendkit.com",
		"remote_options": func(cb): cb.call(opts, default_idx),
		"remote_download": func(ft): _bk_download(asset, str(ft), gallery, plugin),
		"remote_state": func(_ft): return _bk_state(asset, gallery, plugin),
		"remote_dir": func() -> String:
			return ProjectAssets.asset_folder(plugin.absolute_download_path, asset) \
				if gallery.is_downloaded(asset) else "",
		"remote_details": func(): gallery.open_details(asset),
	}


static func _bk_options(asset: Dictionary, plugin) -> Array:
	var opts := []
	for ft in GalleryApi.downloadable_file_types(asset):
		opts.append({"key": ft, "label": GalleryApi.file_type_label(ft), "data": ft})
	return opts


## Tile button state for the BlendKit card: an active download on this
## asset disables it (downloads.start would no-op anyway); a plan-gated
## asset offers the pricing link like asset_details does.
static func _bk_state(asset: Dictionary, gallery: Control, plugin) -> Dictionary:
	var dl: Dictionary = gallery.downloads.get_download(GalleryApi.base_id(asset))
	if dl.get("status", "") in GalleryApi.ACTIVE_DOWNLOAD:
		return {"label": "Downloading…", "enabled": false,
			"note": str(dl.get("message", ""))}
	if asset.get("canDownload") == true:
		return {}
	var auth = plugin.auth
	if asset.get("isFree") != true \
			and (not auth.is_logged_in() or Plans.user_plan(auth.profile) == "free"):
		return {"label": "Get Full Plan…", "enabled": true, "note": ""}
	var reason := GalleryApi.cant_download_message(asset)
	return {"label": "Download", "enabled": false,
		"note": reason if not reason.is_empty() else "This asset can't be downloaded."}


static func _bk_download(asset: Dictionary, ft: String, gallery: Control, plugin) -> void:
	if ft.is_empty():
		return
	if asset.get("canDownload") != true:
		var auth = plugin.auth
		if asset.get("isFree") != true \
				and (not auth.is_logged_in() or Plans.user_plan(auth.profile) == "free"):
			OS.shell_open(plugin.SERVER + "/plans/pricing/")
		return
	gallery.downloads.start(asset, ft)


## Copies an external file into res://imported_assets/<name>/ and lets
## Godot's own importer take over — FBX/glTF import natively, .blend goes
## through the Blender configured in Settings → Blender Import (the same
## settings the BlendKit downloads use, not a parallel setup). Returns the
## staged res:// path, "" when nothing was copied.
static func stage_into_project(entry: Dictionary) -> String:
	var res := stage_files([entry])
	for f in res["failed"]:
		push_warning("A2G: %s" % str(f["error"]))
	if res["staged"].is_empty():
		return ""
	var dst: String = res["staged"][0]["dst"]
	var src: String = res["staged"][0]["src"]
	if src.get_extension().to_lower() == "blend" and not _blend_ready():
		# The Blender Import setting governs whether Godot imports .blend
		# at all; with it off the staged file stays hidden — exactly like
		# upstream describes for BlendKit .blend downloads.
		push_warning("A2G: staged %s, but .blend import isn't set up — it stays hidden until Settings → Blender Import enables native import with a Blender 3.0+ path." % src.get_file())
	EditorInterface.get_resource_filesystem().scan()
	EditorInterface.get_file_system_dock().navigate_to_path(dst)
	return dst


## Batch copy into res://imported_assets/<name>/ — the same staging the
## single-file path uses, minus scan/navigation so callers can write
## .import params between copy and scan (the import dialog) or report
## per-file results (batch import). Returns
## {"staged": [{src, dst}], "failed": [{entry, error}]}.
static func stage_files(entries: Array) -> Dictionary:
	var staged := []
	var failed := []
	for e in entries:
		var src := str(e.get("path", ""))
		# Indexed paths may carry OS separators; get_file() only splits "/".
		src = src.replace("\\", "/")
		if src == "" or src.begins_with("res://") or not FileAccess.file_exists(src):
			failed.append({"entry": e, "error": "not an external file: %s" % src})
			continue
		var dir_res := STAGING_DIR.path_join(src.get_file().get_basename().validate_filename())
		var mk := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_res))
		if mk != OK:
			failed.append({"entry": e, "error": "couldn't create %s (%s)" % [dir_res, error_string(mk)]})
			continue
		var dst := dir_res.path_join(src.get_file())
		var err := DirAccess.copy_absolute(src, ProjectSettings.globalize_path(dst))
		if err != OK:
			failed.append({"entry": e, "error": "couldn't copy %s (%s)" % [src, error_string(err)]})
			continue
		# A same-basename preview image travels with the asset — the
		# sibling match that powers browser thumbnails also keeps the
		# staged copy's preview instead of orphaning in the project.
		for ext in PREVIEW_IMAGE_EXTS:
			var sib: String = src.get_basename() + "." + ext
			if FileAccess.file_exists(sib):
				DirAccess.copy_absolute(sib, ProjectSettings.globalize_path(
					dir_res.path_join(sib.get_file())))
				break
		staged.append({"entry": e, "src": src, "dst": dst})
	return {"staged": staged, "failed": failed}


## Godot can import .blend when the Blender Import settings say so:
## native import on plus a configured, existing Blender path. Reuses the
## upstream plugin's own settings — no parallel configuration.
static func _blend_ready() -> bool:
	if not BlenderImport.blend_import_enabled():
		return false
	var bpath := BlenderImport.blender_path()
	return not bpath.is_empty() and FileAccess.file_exists(bpath)


## "Open" dispatches like the FileSystem dock's default action: scenes open
## as scenes, scripts go to the script editor, resources to the inspector.
static func _open_entry(entry: Dictionary) -> void:
	var path := str(entry.get("path", ""))
	var ext := str(entry.get("ext", path.get_extension())).to_lower()
	if ext in ["tscn", "scn"]:
		EditorInterface.open_scene_from_path(path)
		return
	var res := load(path)
	if res == null:
		if path.begins_with("res://"):
			EditorInterface.get_file_system_dock().navigate_to_path(path)
		elif FileAccess.file_exists(path):
			OS.shell_show_in_file_manager(path)
	elif res is Script:
		EditorInterface.edit_script(res)
	else:
		EditorInterface.edit_resource(res)


## Sets the real preview texture on a card built by asset_card(). The card
## param stays untyped on purpose: preview callbacks can fire after a
## rebuild freed the card, and a typed parameter would reject freed
## objects before is_instance_valid() could guard them.
static func set_card_thumb(card, texture: Texture2D) -> void:
	if is_instance_valid(card) and card.has_method("set_thumb_texture"):
		card.set_thumb_texture(texture)


## The same column math as ui/gallery/gallery.gd's update_columns(): cards
## are widened so every row fills the scroll view exactly, minimum
## GalleryItem.MIN_WIDTH * editor scale. Available width = scroll minus the
## inner Border panel's content margins minus the vertical scrollbar —
## identical to upstream's content_width() - vbar.
static func update_columns(scroll: ScrollContainer, grid: GridContainer, border: PanelContainer) -> void:
	var min_width := GalleryItemScript.MIN_WIDTH * EditorInterface.get_editor_scale()
	var separation := grid.get_theme_constant("h_separation")
	var vbar: VScrollBar = scroll.get_v_scroll_bar()
	var available := scroll.size.x - border.get_theme_stylebox("panel").get_minimum_size().x - vbar.size.x
	var columns := maxi(1, int((available + separation) / (min_width + separation)))
	var width := maxf(min_width, floorf((available + separation) / columns - separation))
	if grid.columns != columns:
		grid.columns = columns
	for c in grid.get_children():
		c.set_width(width)


## The gallery.tscn chrome around a card grid: a Border PanelContainer
## inside the ScrollContainer whose StyleBoxEmpty panel carries the
## content margins upstream sets at runtime (L15/T0/R35/B15 * scale).
## Returns the border; the scroll content goes inside it.
static func make_scroll_border() -> PanelContainer:
	var border := PanelContainer.new()
	border.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	border.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var edscale := EditorInterface.get_editor_scale()
	var style := StyleBoxEmpty.new()
	style.content_margin_left = 15 * edscale
	style.content_margin_top = 0
	style.content_margin_right = 35 * edscale
	style.content_margin_bottom = 15 * edscale
	border.add_theme_stylebox_override("panel", style)
	return border


## A ScrollContainer configured like the gallery's Scroll node: the editor
## theme's "Tree" panel stylebox as panel override (its content margin
## insets the scroll content ~6px left, and it paints the bounded-panel
## background upstream has) + horizontal scrollbar never shown.
static func make_scroll() -> ScrollContainer:
	var scroll := ScrollContainer.new()
	# Resolved against the editor base control — an out-of-tree control has
	# no editor theme context yet.
	scroll.add_theme_stylebox_override("panel",
			EditorInterface.get_base_control().get_theme_stylebox("panel", "Tree"))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	return scroll


## Standalone TabBar styled like a TabContainer's strip: the editor theme
## carries these items on the "TabContainer" theme type, the TabBar reads
## the same names under "TabBar" — copy them over so the main-screen tab
## row renders like the dock tabs it replaced.
static func style_tabbar(bar: TabBar) -> void:
	var base := EditorInterface.get_base_control()
	for name in ["tab_selected", "tab_unselected", "tab_hovered", "tab_disabled",
			"tab_focus", "tab_highlight"]:
		var sb := base.get_theme_stylebox(name, "TabContainer")
		if sb != null:
			bar.add_theme_stylebox_override(name, sb)
	for name in ["font_selected_color", "font_unselected_color",
			"font_hovered_color", "font_disabled_color", "font_outline_color"]:
		var col := base.get_theme_color(name, "TabContainer")
		bar.add_theme_color_override(name, col)
	for name in ["h_separation", "icon_max_width", "outline_size"]:
		bar.add_theme_constant_override(name,
			base.get_theme_constant(name, "TabContainer"))
	var font := base.get_theme_font("font", "TabContainer")
	if font != null:
		bar.add_theme_font_override("font", font)
	bar.add_theme_font_size_override("font_size",
		base.get_theme_font_size("font_size", "TabContainer"))


## A GridContainer configured like the gallery's grid (gap = GAP * scale,
## shrink-centered like gallery.tscn's Grid node).
static func make_grid() -> GridContainer:
	var grid := GridContainer.new()
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var gap := int(GalleryItemScript.GAP * EditorInterface.get_editor_scale())
	grid.add_theme_constant_override("h_separation", gap)
	grid.add_theme_constant_override("v_separation", gap)
	return grid
