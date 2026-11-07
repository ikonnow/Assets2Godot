@tool
extends Node
## On-demand thumbnail renderer for asset files the EditorResourcePreview
## can't reach — anything outside res:// (vault caches, local roots).
## Images are decoded then run through queue_edited_resource_preview for
## editor-identical output; .tres/.tscn resources load and stage; .glb/
## .gltf go through GLTFDocument, .fbx through FBXDocument (4.3+). Staged
## content renders in a hidden SubViewport using the same rig the engine's
## own preview plugins (EditorMeshPreviewPlugin & co.) use: transparent
## background, fov-45 camera at z=3, key light + 0.7-gray fill, AABB
## normalized to 0.5 units, rounded corners r=min/32.
##
## Rendered thumbs persist to <editor cache>/a2g/thumbs/<md5(path)>-<size>
## .png + .json {mtime, md5} — the editor's own resthumb invalidation
## scheme — so each file renders exactly once per content change.
##
## Usage: thumbs.request(payload, "/abs/path.glb") -> rendered(payload, tex)

signal rendered(payload: Variant, texture: Texture2D)

const DEFAULT_SIZE := 256
const SETTING_SIZE := "assets2godot/thumb_size"
const PER_FRAME := 1
const CACHE_MAX := 256
const CACHE_DIR := "a2g/thumbs"
const IMAGE_EXTS := ["png", "jpg", "jpeg", "tga", "bmp", "webp", "exr", "hdr", "tif", "tiff", "svg"]

var _viewport: SubViewport
var _camera: Camera3D
var _holder: Node3D
var _queue: Array = []
## path → rendered texture. A rebuild re-requests every card — without a
## cache each one re-runs GLTFDocument, which makes the editor's importer
## log "can't reimport" noise for every external file every time.
var _cache := {}
## path → decoded Image for image items waiting on an edited preview.
var _pending := {}
var _size := DEFAULT_SIZE


func _ready() -> void:
	# Render size is an editor setting (Settings → Assets2Godot → Thumb
	# size); a missing value means this code ran outside the plugin.
	_size = DEFAULT_SIZE
	var es := EditorInterface.get_editor_settings()
	if es and es.has_setting(SETTING_SIZE):
		_size = int(es.get_setting(SETTING_SIZE))
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(_size, _size)
	_viewport.own_world_3d = true
	_viewport.transparent_bg = true   # editor rig: transparent, no env
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_viewport)

	# Two directional lights verbatim from editor_preview_plugins.cpp:
	# white key looking at (-1,-1,-1), 0.7-gray fill at +Y.
	var key := DirectionalLight3D.new()
	key.transform = Transform3D().looking_at(Vector3(-1, -1, -1), Vector3.UP)
	_viewport.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.light_color = Color(0.7, 0.7, 0.7)
	fill.transform = Transform3D().looking_at(Vector3(0, 1, 0), Vector3(0, 0, 1))
	_viewport.add_child(fill)

	_camera = Camera3D.new()
	_camera.fov = 45                  # native preview fov (was 40)
	_camera.position = Vector3(0, 0, 3)
	_camera.near = 0.1
	_camera.far = 10.0
	_camera.current = true
	_viewport.add_child(_camera)

	_holder = Node3D.new()
	_viewport.add_child(_holder)

	set_process(false)


## Queues a thumbnail render for an absolute filesystem path. Emits
## rendered() once done; files with no renderable content are skipped
## silently (the card keeps its placeholder).
func request(payload: Variant, path: String) -> void:
	if _cache.has(path):
		rendered.emit(payload, _cache[path])
		return
	var disk := _disk_lookup(path)
	if disk != null:
		_cache_store(path, disk)
		rendered.emit(payload, disk)
		return
	for it in _queue:
		if it["path"] == path:
			return
	if _pending.has(path):
		return
	_queue.append({"payload": payload, "path": path})
	set_process(true)


func _process(_delta: float) -> void:
	for i in mini(PER_FRAME, _queue.size()):
		var item: Dictionary = _queue.pop_front()
		var path: String = item["path"]
		var ext := path.get_extension().to_lower()
		if ext in IMAGE_EXTS:
			_handle_image(item)
		else:
			var img := _render_path(path)
			if img != null:
				_finish(path, img, item["payload"])
	if _queue.is_empty():
		set_process(false)


## Image files: decode, then hand the texture to the editor previewer —
## it produces the native fit-in-box + rounded corners + small preview on
## its thread. Falls back to a self-processed image when the previewer is
## unavailable or returns null.
func _handle_image(item: Dictionary) -> void:
	var path: String = item["path"]
	var img := _decode_image(path)
	if img == null:
		return
	var previewer := EditorInterface.get_resource_previewer()
	if previewer == null:
		_finish(path, img, item["payload"])
		return
	_pending[path] = img
	var tex := ImageTexture.create_from_image(img)
	previewer.queue_edited_resource_preview(tex, self, "_on_edited_preview",
			{"payload": item["payload"], "path": path})


func _on_edited_preview(_cb_path: String, preview: Texture2D, _small: Texture2D, ud) -> void:
	if not (ud is Dictionary):
		return
	var path: String = ud["path"]
	var img: Image = _pending.get(path)
	_pending.erase(path)
	if preview != null:
		# Engine output is already post-processed — persist as-is.
		_finish_tex(path, preview, ud["payload"])
	elif img != null:
		_finish(path, img, ud["payload"])


func _decode_image(path: String) -> Image:
	var img := Image.new()
	var err := OK
	if path.get_extension().to_lower() == "svg":
		# SVGs rasterize tiny by default — bump the scale so they survive
		# at card size.
		err = img.load_svg_from_buffer(FileAccess.get_file_as_bytes(path), 4.0)
	else:
		err = img.load(path)
	return img if err == OK else null


## Staged renders: loads the file, stages a Node3D, renders one frame in
## the hidden viewport and returns the captured Image (or null).
func _render_path(path: String) -> Image:
	if not FileAccess.file_exists(path):
		return null
	var res: Resource = null
	var node: Node3D = null
	match path.get_extension().to_lower():
		"tres", "res", "tscn", "scn":
			res = ResourceLoader.load(path)
		"glb", "gltf":
			var doc := GLTFDocument.new()
			var state := GLTFState.new()
			if doc.append_from_file(path, state) == OK:
				node = doc.generate_scene(state) as Node3D
		"fbx":
			# ufbx runtime path (4.3+, Experimental) — the
			# EditorSceneFormatImporter* classes are a verified dead end.
			if ClassDB.class_exists("FBXDocument") and ClassDB.class_exists("FBXState"):
				var doc = ClassDB.instantiate("FBXDocument")
				var state = ClassDB.instantiate("FBXState")
				if doc != null and state != null and doc.append_from_file(path, state) == OK:
					node = doc.generate_scene(state) as Node3D
	if res is Texture2D:
		return res.get_image()
	if res is Image:
		return res
	if res is Mesh:
		var inst := MeshInstance3D.new()
		inst.mesh = res
		node = inst
	elif res is Material:
		var inst := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radial_segments = 32
		inst.mesh = sphere
		inst.material_override = res
		node = inst
	elif res is PackedScene:
		node = res.instantiate() as Node3D

	if node != null:
		node = _resolve_importer_meshes(node) as Node3D
	if node == null:
		return null
	_holder.add_child(node)
	var aabb := _world_aabb(node)
	var ok := _frame(aabb, node)
	var img: Image = null
	if ok:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		RenderingServer.force_draw()
		img = _viewport.get_texture().get_image()
	_holder.remove_child(node)
	node.queue_free()
	return img


## GLTFDocument/FBXDocument generate_scene() yields ImporterMeshInstance3D
## nodes in the editor — Node3D subclasses that draw nothing. Swaps every
## node whose "mesh" property resolves through get_mesh() (ImporterMesh →
## ArrayMesh) for a renderable MeshInstance3D, preserving transform,
## children and sibling order. Returns the (possibly replaced) root.
func _resolve_importer_meshes(root: Node) -> Node:
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


## Combined AABB of the staged subtree in _holder space, duck-typed on
## get_aabb() — ImporterMeshInstance3D (what GLTFDocument yields in the
## editor) is a Node3D, not a VisualInstance3D.
func _world_aabb(root: Node) -> AABB:
	var aabb := AABB()
	var found := false
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var n3d := n as Node3D
		if n3d != null:
			var box: Variant = null
			if n3d.has_method("get_aabb"):
				box = n3d.get_aabb()
			else:
				# ImporterMeshInstance3D (GLTFDocument's editor node type)
				# may lack a bound get_aabb — its mesh has one.
				var m: Variant = n3d.get("mesh")
				if m != null and m.has_method("get_aabb"):
					box = m.get_aabb()
			if box is AABB:
				var sub: AABB = n3d.global_transform * box
				aabb = sub if not found else aabb.merge(sub)
				found = true
		stack.append_array(n.get_children())
	return aabb if found else AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)


## Verbatim framing from EditorMeshPreviewPlugin::generate — rotate the
## content into the fixed -22.5° yaw / +22.5° pitch preview basis, scale
## its largest rotated half-extent to 0.5 units, recenter on origin, pull
## back ~2× the rotated depth. Camera stays fixed at (0,0,3), fov 45.
func _frame(aabb: AABB, node: Node3D) -> bool:
	var ofs := aabb.get_center()
	aabb.position -= ofs
	var xform := Transform3D()
	xform.basis = Basis().rotated(Vector3(0, 1, 0), -PI * 0.125)
	xform.basis = Basis().rotated(Vector3(1, 0, 0), PI * 0.125) * xform.basis
	var rot_aabb := xform * aabb
	var m := maxf(rot_aabb.size.x, rot_aabb.size.y) * 0.5
	if m == 0:
		return false
	m = (1.0 / m) * 0.5
	xform.basis = xform.basis.scaled(Vector3(m, m, m))
	xform.origin = -(xform.basis * ofs)
	xform.origin.z -= rot_aabb.size.z * 2
	node.transform = xform
	return true


## The editor's post_process_preview: alpha-out the four corners with
## radius min(w,h)/32 — every native preview gets subtle rounded corners.
func _post_process(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	img.convert(Image.FORMAT_RGBA8)
	var r := mini(w, h) / 32
	if r <= 0:
		return
	var rf := float(r)
	for c in [[0, 0], [w - 1, 0], [0, h - 1], [w - 1, h - 1]]:
		var cx: int = c[0]
		var cy: int = c[1]
		for y in range(maxi(0, cy - r), mini(h - 1, cy + r) + 1):
			for x in range(maxi(0, cx - r), mini(w - 1, cx + r) + 1):
				# Circle center sits at the corner itself; pixels farther
				# than r get cleared.
				var dx := absf(x - cx)
				var dy := absf(y - cy)
				if dx * dx + dy * dy > rf * rf:
					img.set_pixel(x, y, Color(0, 0, 0, 0))


## Post-processes, persists and emits a staged/decoded Image.
func _finish(path: String, img: Image, payload: Variant) -> void:
	_post_process(img)
	_disk_store(path, img)
	_cache_store(path, ImageTexture.create_from_image(img))
	rendered.emit(payload, _cache[path])


## Persists and emits an engine-rendered texture (already post-processed).
func _finish_tex(path: String, tex: Texture2D, payload: Variant) -> void:
	var img := tex.get_image()
	if img != null:
		_disk_store(path, img)
	_cache_store(path, tex)
	rendered.emit(payload, tex)


func _cache_store(path: String, tex: Texture2D) -> void:
	if _cache.size() >= CACHE_MAX:
		_cache.clear()
	_cache[path] = tex


## MARK: persistent disk cache — mirrors the editor's resthumb scheme:
## <md5(path)>-<size>.png plus a .json sidecar {mtime, md5}; an mtime
## match is a hit, an mtime miss falls back to a content md5 compare
## (equal → refresh sidecar, different → regen).

func _disk_root() -> String:
	var ep := EditorInterface.get_editor_paths()
	if ep == null or not ep.has_method("get_cache_dir"):
		return ""
	var root: String = ep.get_cache_dir().path_join(CACHE_DIR)
	DirAccess.make_dir_recursive_absolute(root)
	return root


func _disk_paths(path: String) -> PackedStringArray:
	var root := _disk_root()
	if root == "":
		return PackedStringArray()
	var base := root.path_join("%s-%d" % [path.md5_text(), _size])
	return PackedStringArray([base + ".png", base + ".json"])


func _disk_lookup(path: String) -> Texture2D:
	var dp := _disk_paths(path)
	if dp.is_empty() or not FileAccess.file_exists(dp[0]) or not FileAccess.file_exists(dp[1]):
		return null
	var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(dp[1]))
	if not (meta is Dictionary):
		return null
	if int(meta.get("mtime", -1)) != FileAccess.get_modified_time(path):
		if str(meta.get("md5", "")) != FileAccess.get_md5(path):
			return null
		# Content identical, only mtime drifted — refresh the sidecar.
		_disk_write_meta(dp[1], path)
	var img := Image.new()
	if img.load(dp[0]) != OK:
		return null
	return ImageTexture.create_from_image(img)


func _disk_store(path: String, img: Image) -> void:
	var dp := _disk_paths(path)
	if dp.is_empty():
		return
	if img.save_png(dp[0]) == OK:
		_disk_write_meta(dp[1], path)


func _disk_write_meta(meta_path: String, src_path: String) -> void:
	var f := FileAccess.open(meta_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({
			"mtime": FileAccess.get_modified_time(src_path),
			"md5": FileAccess.get_md5(src_path),
		}))
		f.close()
