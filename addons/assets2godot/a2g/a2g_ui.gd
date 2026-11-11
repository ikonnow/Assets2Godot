@tool
extends RefCounted
## Shared UI helpers for the Assets2Godot surfaces: extension → kind
## classification, kind colors and the gallery-style asset card used by the
## Browser and Assets tabs (styled after ui/gallery/gallery_item.tscn).

const ICON_PATH = "res://addons/assets2godot/a2g/a2g_icon.svg"

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


const Icons = preload("res://addons/assets2godot/ui/icons.gd")
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
	item.set_drag_forwarding(_card_drag_data.bind(item), Callable(), Callable())
	_fix_card_filters(item)
	return item


## Lets drags start anywhere on the card: the engine's drag-data lookup
## walks up from the pressed control and stops at the first
## MOUSE_FILTER_STOP child — badge labels inside the tile would be dead
## spots for dragging otherwise. The item root keeps its own filter.
static func _fix_card_filters(item: Control) -> void:
	for c in item.find_children("*", "Control", true, false):
		var cc := c as Control
		if cc != null and cc.mouse_filter == Control.MOUSE_FILTER_STOP:
			cc.mouse_filter = Control.MOUSE_FILTER_IGNORE


## Drag payload for set_drag_forwarding(): the engine calls the forward
## callable with ONE argument — the local position — so bound args trail
## it: (at, item), not (item, at). A res:// file hands the engine's own
## "files" drag type (identical to the FileSystem dock, so the editor's
## own drop targets accept it too), a remote-provider card passes its
## remote_* payload through — the scene-drop overlay reads
## slug/options/dimensions/progress out of it. Anything else isn't
## draggable (external paths can't enter a res:// files drag).
static func _card_drag_data(_at: Vector2, item: Control) -> Variant:
	var asset: Dictionary = item.get("asset")
	var payload: Dictionary = asset.get("a2g_payload", {})
	var path := str(payload.get("path", ""))
	var data: Variant = null
	if path.begins_with("res://"):
		data = {"type": "files", "files": [path]}
	elif str(payload.get("remote_slug", "")) != "":
		data = payload.duplicate()
	if data == null:
		return null
	var preview := Label.new()
	preview.text = str(payload.get("remote_title",
		asset.get("displayName", path.get_file())))
	item.set_drag_preview(preview)
	return data


## Combined AABB of a subtree in its own coordinate frame — local
## transforms accumulated from [param root] down, so it works whether the
## subtree is in the tree or not (a freshly instantiated drop candidate
## isn't). Duck-typed on get_aabb() like the editor: ImporterMeshInstance3D
## (what GLTFDocument yields in the editor) is a Node3D, not a
## VisualInstance3D — its mesh carries the box instead. Fallback matches
## the old a2g_thumbs helper: a unit box centered on origin.
static func world_aabb(root: Node) -> AABB:
	var aabb := AABB()
	var found := false
	var stack := [[root, Transform3D()]]
	while not stack.is_empty():
		var it: Array = stack.pop_back()
		var n: Node = it[0]
		var xform: Transform3D = it[1]
		var n3d := n as Node3D
		if n3d != null:
			xform = xform * n3d.transform
			var box: Variant = null
			if n3d.has_method("get_aabb"):
				box = n3d.get_aabb()
			else:
				var m: Variant = n3d.get("mesh")
				if m != null and m.has_method("get_aabb"):
					box = m.get_aabb()
			if box is AABB:
				var sub: AABB = xform * box
				aabb = sub if not found else aabb.merge(sub)
				found = true
		for c in n.get_children():
			stack.append([c, xform])
	return aabb if found else AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)


## GLTFDocument/FBXDocument generate_scene() yields ImporterMeshInstance3D
## nodes in the editor — Node3D subclasses that draw nothing. Swaps every
## node whose "mesh" property resolves through get_mesh() (ImporterMesh →
## ArrayMesh) for a renderable MeshInstance3D, preserving transform,
## children and sibling order. Returns the (possibly replaced) root.
static func resolve_importer_meshes(root: Node) -> Node:
	var out := root
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		var n3d := n as Node3D
		if n3d == null:
			continue
		var m: Variant = n3d.get("mesh")
		if m == null or not m.has_method("get_mesh"):
			continue
		var converted: Variant = m.get_mesh()
		if converted == null:
			continue
		var mi := MeshInstance3D.new()
		mi.name = n3d.name
		mi.transform = n3d.transform
		mi.mesh = converted
		for c in n3d.get_children():
			n3d.remove_child(c)
			mi.add_child(c)
		var parent := n3d.get_parent()
		if parent != null:
			var idx := n3d.get_index()
			parent.remove_child(n3d)
			parent.add_child(mi)
			parent.move_child(mi, idx)
		else:
			out = mi
		n3d.free()
	return out


## Loads a placeable file into a Node3D without going through the editor
## importer: res:// uses ResourceLoader (imported PackedScene/Mesh),
## absolute paths fall back to the runtime GLTF/FBX documents like
## a2g_thumbs — so a just-downloaded file works before its import lands.
## Returns null for non-placeable resources (materials, textures…).
static func instantiate_placeable(path: String) -> Node3D:
	var ext := path.get_extension().to_lower()
	var node: Node3D = null
	# Downloads arrive as absolute paths — the FileSystem-side file is
	# the res:// form, and it's what an instance's scene_file_path
	# must point at (the .tscn serializer writes it as an ExtResource).
	var res_path := ProjectSettings.localize_path(path)
	# Imported files load as real PackedScenes — the engine sets
	# scene_file_path itself, so the placed node is a true scene
	# instance (selects as one, "editable children" expands it).
	if res_path.begins_with("res://") and ResourceLoader.exists(res_path):
		var res := ResourceLoader.load(res_path)
		if res is PackedScene:
			node = res.instantiate() as Node3D
		elif res is Mesh:
			node = MeshInstance3D.new()
			node.mesh = res
	# Model formats NEVER go through ResourceLoader.load while their
	# import is still pending: a res:// .gltf that isn't imported yet
	# triggers the GUI import pipeline mid-drop — that path has
	# hard-crashed the editor (signal 11). The raw document parsers
	# read res:// too and skip the importer entirely.
	elif ext in ["glb", "gltf"]:
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		if doc.append_from_file(path, state) == OK:
			node = doc.generate_scene(state) as Node3D
	elif ext == "fbx":
		if ClassDB.class_exists("FBXDocument") and ClassDB.class_exists("FBXState"):
			var doc: Object = ClassDB.instantiate("FBXDocument")
			var state: Object = ClassDB.instantiate("FBXState")
			if doc != null and state != null \
					and doc.call("append_from_file", path, state) == OK:
				node = doc.call("generate_scene", state) as Node3D
	if node == null:
		return null
	node = resolve_importer_meshes(node) as Node3D
	# Raw-parsed res:// models get instanced manually: scene_file_path
	# marks the node as an instance of its source file (the import
	# lands at the next scan and the node reloads as a real instance),
	# children owned by it instead of the edited scene.
	if node != null and node.scene_file_path.is_empty() \
			and res_path.begins_with("res://"):
		node.scene_file_path = res_path
		_instance_owners(node)
	return node


## Every descendant of an instanced root belongs to the instance's own
## file, not the edited scene — the same ownership PackedScene
## assigns, which is what hides the children until "editable children".
static func _instance_owners(node: Node) -> void:
	for c in node.get_children():
		c.owner = node
		_instance_owners(c)


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
		# tree.node_added fires for EVERY GalleryItem entering the editor —
		# provider panes build cards through asset_card() too. Their own
		# _card_drag_data forwarding must not be overwritten with the BK
		# hook (its a2g guard returns null → provider cards never drag).
		var nasset: Variant = node.get("asset")
		if nasset is Dictionary and nasset.get("a2g", false):
			return
		node.set_meta(&"a2g_bk_quick", true)
		node.gui_input.connect(func(ev): _on_bk_card_input(node, ev, gallery))
		node.set_drag_forwarding(_bk_card_drag_data.bind(node, gallery),
			Callable(), Callable())
		_fix_card_filters(node)
	tree.node_added.connect(holder[0])


## BlendKit gallery cards are built upstream, not via asset_card() — the
## same drag-forwarding hook, reusing _bk_remote_entry so the scene
## preview gets the full remote_* contract (download/progress/dir).
static func _bk_card_drag_data(_at: Vector2, item: Control, gallery: Control) -> Variant:
	var asset: Variant = item.get("asset")
	if not asset is Dictionary or asset.is_empty() or asset.get("a2g", false) \
			or not is_instance_valid(gallery):
		return null
	var entry := _bk_remote_entry(asset, gallery)
	if entry.is_empty():
		return null
	var preview := Label.new()
	preview.text = str(entry.get("remote_title", "asset"))
	item.set_drag_preview(preview)
	return entry


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
	if plugin == null or not is_instance_valid(plugin):
		return {}
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
		"remote_progress": func() -> float:
			return _bk_progress(asset, gallery),
		"remote_dimensions": null,
		"remote_kind": str(asset.get("assetType", "")),
		"remote_dir": func() -> String:
			return ProjectAssets.asset_folder(plugin.absolute_download_path, asset) \
				if gallery.is_downloaded(asset) else "",
		"remote_delete": func() -> bool:
			return _bk_delete(asset, plugin),
		"remote_details": func(): gallery.open_details(asset),
	}


## Scene-preview progress source for the BlendKit card: the Downloads
## model's task percentage, -1 while nothing is running, 1 once the
## asset is downloaded (the preview then treats the drop as local).
static func _bk_progress(asset: Dictionary, gallery: Control) -> float:
	if not is_instance_valid(gallery):
		return -1.0
	var dl: Dictionary = gallery.downloads.get_download(GalleryApi.base_id(asset))
	if dl.get("status", "") in GalleryApi.ACTIVE_DOWNLOAD:
		return clampf(float(dl.get("progress", 0)) / 100.0, 0.0, 1.0)
	return 1.0 if gallery.is_downloaded(asset) else -1.0


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


## Trashes the asset's folder under the download root — the guard keeps
## it honest: only a dir strictly inside the provider's own root goes to
## the trash, never a path the payload could name. filesystem_changed
## then drives every downloaded-state surface (project view, badges,
## provider downloads panes) to re-scan on its own.
static func _bk_delete(asset: Dictionary, plugin) -> bool:
	var dir := ProjectAssets.asset_folder(plugin.absolute_download_path, asset)
	if not trash_downloaded_dir(dir, plugin.absolute_download_path):
		return false
	EditorInterface.get_resource_filesystem().scan()
	return true


## The shared guard behind every remote_delete: [param dir] is trashed
## ONLY when it resolves strictly inside [param root] — deleting a card's
## payload path outright would hand the UI a remove-anything primitive.
static func trash_downloaded_dir(dir: String, root: String) -> bool:
	dir = dir.replace("\\", "/").rstrip("/")
	root = root.replace("\\", "/").rstrip("/")
	if dir.is_empty() or root.is_empty() or not dir.begins_with(root + "/"):
		return false
	if not DirAccess.dir_exists_absolute(dir):
		return false
	return OS.move_to_trash(dir) == OK


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


## gallery.tscn's LibraryMargin: the MarginContainer between the pane's
## VBox and the card scroll. The editor theme's NoBorderAssetLib
## variation gives it negative margins (-4 L/R/B on 4.7) that cancel the
## AssetLib "bg" panel's content margin, so the scroll reaches the pane's
## edges — without it the scroll is 8px narrower and update_columns()
## lands every card 1px narrower and 4px right of BlendKit's.
static func make_library_margin() -> MarginContainer:
	var margin := MarginContainer.new()
	margin.theme_type_variation = "NoBorderAssetLib"
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return margin


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
## background upstream has) + horizontal scrollbar never shown + the
## top/left scroll hints gallery.gd sets on Godot 4.6+.
static func make_scroll() -> ScrollContainer:
	var scroll := ScrollContainer.new()
	# Resolved against the editor base control — an out-of-tree control has
	# no editor theme context yet.
	scroll.add_theme_stylebox_override("panel",
			EditorInterface.get_base_control().get_theme_stylebox("panel", "Tree"))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	if "scroll_hint_mode" in scroll: # Godot 4.6+
		scroll.set("scroll_hint_mode", 2) # SCROLL_HINT_MODE_TOP_AND_LEFT
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
	# Constants: hseparation is the icon↔text gap (the name is literally
	# "hseparation" — a missing constant would silently become a 0
	# override, so only copy what the theme really defines).
	for name in ["hseparation", "side_margin", "tab_separation",
			"icon_max_width", "outline_size"]:
		if base.has_theme_constant(name, "TabContainer"):
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


## MARK: provider marks — the same logo files the provider menus use,
## shared by the tab strip, the Sources tree and the settings menu so a
## provider reads identically on every surface. `mono` requests the
## editor-icon recolor (light on dark themes); colored marks (Polyhaven)
## keep their paint like their menu logo does. Rendered content-fit, so
## a file's canvas size or inner padding is irrelevant.
const PROVIDER_LOGOS := {
	"blendkit": {"path": "res://addons/assets2godot/logo/blendkit-logo-hexa_pure.svg", "mono": false},
	"polyhaven": {"path": "res://addons/assets2godot/logo/polyhaven-icon.svg", "mono": false},
	"ambientcg": {"path": "res://addons/assets2godot/logo/ambientcg-icon.svg", "mono": true},
}


## The provider's [param px]-pixel mark, or null for an unknown key.
static func provider_icon(key: String, px := 16.0) -> Texture2D:
	var info: Dictionary = PROVIDER_LOGOS.get(key, {})
	if info.is_empty():
		return null
	return Icons.render_svg_fit(str(info["path"]),
		px * EditorInterface.get_editor_scale(), bool(info["mono"]))
