@tool
extends EditorResourcePreviewGenerator
## EditorResourcePreviewGenerator for files the built-in generators
## can't reach: external images (no .import sidecar) and .glb/.gltf/.fbx
## scenes. Registered once by the plugin — then native
## queue_resource_preview calls serve these paths with the engine's own
## queue, dedup, resthumb disk cache and invalidation for free.
##
## Everything here runs on the preview background thread: no SceneTree,
## no Nodes. glTF/FBX get parsed for ImporterMesh + node transforms only
## (generate_scene is skipped — it's the stateful, thread-suspect part),
## the render happens in a RenderingServer RID viewport via
## request_draw_and_wait — the same mechanism the built-in preview
## plugins (editor_preview_plugins.cpp) use.

const IMAGE_EXTS := ["png", "jpg", "jpeg", "tga", "bmp", "webp", "exr", "hdr", "svg"]
const SCENE_EXTS := ["glb", "gltf", "fbx"]

var _scenario := RID()
var _viewport := RID()
var _vtex := RID()
var _camera := RID()
var _rig_size := -1
var _lights_ready := false
## Every RID this generator created — freed in PREDELETE so plugin
## reloads don't leak server objects.
var _rids: Array[RID] = []


func _handles(type: String) -> bool:
	# "" = no ResourceFormatLoader recognized the file (external images,
	# glb/gltf/fbx). "PackedScene" lets project glbs and external scenes
	# fall through when the resthumb-only built-in returns null.
	return type == "" or type == "PackedScene"


func _generate(_from: Resource, _size: Vector2i, _metadata: Dictionary) -> Texture2D:
	# Edited-resource path stays with the built-ins — nothing of ours is
	# in-memory here.
	return null


func _generate_from_path(path: String, size: Vector2i, _metadata: Dictionary) -> Texture2D:
	var ext := path.get_extension().to_lower()
	if ext in IMAGE_EXTS:
		return _gen_image(path, size)
	if ext in SCENE_EXTS:
		return _gen_scene(path, size)
	return null


## Images: decode, fit-in-box, rounded corners — same shape as
## EditorImagePreviewPlugin's output.
func _gen_image(path: String, size: Vector2i) -> Texture2D:
	var img := Image.new()
	var err := OK
	if path.get_extension().to_lower() == "svg":
		err = img.load_svg_from_buffer(FileAccess.get_file_as_bytes(path), 4.0)
	else:
		err = img.load(path)
	if err != OK:
		return null
	return _texture_from(img, size)


## Scenes: parse the document, collect (mesh, world transform) pairs and
## render them in the RID rig. Returns null whenever the parse or the
## staged set is empty — callers then fall back to A2GThumbs.
func _gen_scene(path: String, size: Vector2i) -> Texture2D:
	var doc: GLTFDocument = null
	var state: GLTFState = null
	if path.get_extension().to_lower() == "fbx":
		if ClassDB.class_exists("FBXDocument") and ClassDB.class_exists("FBXState"):
			doc = ClassDB.instantiate("FBXDocument")
			state = ClassDB.instantiate("FBXState")
	else:
		doc = GLTFDocument.new()
		state = GLTFState.new()
	if doc == null or state == null or doc.append_from_file(path, state) != OK:
		return null
	var entries := _scene_meshes(state)
	if entries.is_empty():
		return null
	return _render_staged(entries, size)


## (mesh, world_xform) per mesh-bearing node reachable from the scene
## roots. ImporterMesh resolves via get_mesh() — the same harvest rule
## A2GThumbs uses after generate_scene.
func _scene_meshes(state: GLTFState) -> Array:
	var nodes := state.get_nodes()
	var meshes := state.get_meshes()
	var roots := state.get_root_nodes()
	var reachable := {}
	var stack: Array = []
	for i in roots:
		stack.append(i)
	while not stack.is_empty():
		var i: int = stack.pop_back()
		if reachable.has(i) or i < 0 or i >= nodes.size():
			continue
		reachable[i] = true
		for c in nodes[i].get("children") if nodes[i].get("children") != null else []:
			stack.append(c)
	var world := {}
	var out := []
	for i in reachable.keys():
		var n = nodes[i]
		var mi: int = n.get("mesh") if n.get("mesh") != null else -1
		if mi < 0 or mi >= meshes.size():
			continue
		var gmesh = meshes[mi].get_mesh()
		var real: Mesh = gmesh.get_mesh() if gmesh is ImporterMesh else gmesh
		if real == null:
			continue
		out.append({"mesh": real, "xform": _world_xform(nodes, i, world)})
	return out


func _world_xform(nodes: Array, i: int, world: Dictionary) -> Transform3D:
	if world.has(i):
		return world[i]
	var n = nodes[i]
	var xf: Transform3D = n.get("xform") if n.get("xform") != null else Transform3D()
	var parent: int = n.get("parent") if n.get("parent") != null else -1
	var res := xf
	if parent >= 0 and parent < nodes.size() and parent != i:
		res = _world_xform(nodes, parent, world) * xf
	world[i] = res
	return res


## MARK: RID render rig — mirrors EditorMeshPreviewPlugin's ctor setup:
## offscreen viewport, transparent background, camera z=3 fov 45,
## white key light at (-1,-1,-1) + 0.7-gray fill at +Y.
func _ensure_rig(side: int) -> void:
	if not _scenario.is_valid():
		_scenario = RenderingServer.scenario_create()
		_rids.append(_scenario)
	if not _viewport.is_valid():
		_viewport = RenderingServer.viewport_create()
		_rids.append(_viewport)
		RenderingServer.viewport_set_scenario(_viewport, _scenario)
		RenderingServer.viewport_set_transparent_background(_viewport, true)
		RenderingServer.viewport_set_active(_viewport, true)
		RenderingServer.viewport_set_update_mode(_viewport, RenderingServer.VIEWPORT_UPDATE_DISABLED)
		_vtex = RenderingServer.viewport_get_texture(_viewport)
		_rids.append(_vtex)
	if _rig_size != side:
		RenderingServer.viewport_set_size(_viewport, side, side)
		_rig_size = side
	if not _camera.is_valid():
		_camera = RenderingServer.camera_create()
		_rids.append(_camera)
		RenderingServer.viewport_attach_camera(_viewport, _camera)
		RenderingServer.camera_set_transform(_camera, Transform3D(Basis(), Vector3(0, 0, 3)))
		RenderingServer.camera_set_perspective(_camera, 45, 0.1, 10)
	if not _lights_ready:
		_lights_ready = true
		var key := RenderingServer.directional_light_create()
		_rids.append(key)
		var ki := RenderingServer.instance_create()
		_rids.append(ki)
		RenderingServer.instance_set_base(ki, key)
		RenderingServer.instance_set_scenario(ki, _scenario)
		RenderingServer.instance_set_transform(ki, Transform3D().looking_at(Vector3(-1, -1, -1), Vector3.UP))
		var fill := RenderingServer.directional_light_create()
		_rids.append(fill)
		RenderingServer.light_set_color(fill, Color(0.7, 0.7, 0.7))
		var fi := RenderingServer.instance_create()
		_rids.append(fi)
		RenderingServer.instance_set_base(fi, fill)
		RenderingServer.instance_set_scenario(fi, _scenario)
		RenderingServer.instance_set_transform(fi, Transform3D().looking_at(Vector3(0, 1, 0), Vector3(0, 0, 1)))


## Stage every (mesh, world_xform) as an RID instance with the shared
## normalized frame transform, draw once, read back, free instances.
func _render_staged(entries: Array, size: Vector2i) -> Texture2D:
	var side := maxi(size.x, size.y) * 2
	_ensure_rig(maxi(32, side))
	var aabb := AABB()
	var first := true
	for e in entries:
		var b: AABB = e["xform"] * e["mesh"].get_aabb()
		aabb = b if first else aabb.merge(b)
		first = false
	var xform := _frame_xform(aabb)
	var instances := []
	for e in entries:
		var inst := RenderingServer.instance_create2(e["mesh"].get_rid(), _scenario)
		RenderingServer.instance_set_transform(inst, xform * e["xform"])
		instances.append(inst)
	var img: Image = null
	# Dynamic dispatch: the base method only exists on 4.6+ (godot#96897).
	# A direct call fails to PARSE on older versions — the editor's
	# script scan would log an error even though plugin.gd only load()s
	# this file behind its version gate.
	call(&"request_draw_and_wait", _viewport)
	img = RenderingServer.texture_2d_get(_vtex)
	for inst in instances:
		RenderingServer.free_rid(inst)
	if img == null or img.is_empty():
		return null
	return _texture_from(img, size)


## Verbatim framing from EditorMeshPreviewPlugin::generate — rotate into
## the -22.5° yaw / +22.5° pitch basis, normalize the largest rotated
## half-extent to 0.5 units, recenter, pull back ~2× rotated depth.
func _frame_xform(aabb: AABB) -> Transform3D:
	var ofs := aabb.get_center()
	aabb.position -= ofs
	var xform := Transform3D()
	xform.basis = Basis().rotated(Vector3(0, 1, 0), -PI * 0.125)
	xform.basis = Basis().rotated(Vector3(1, 0, 0), PI * 0.125) * xform.basis
	var rot_aabb := xform * aabb
	var m := maxf(rot_aabb.size.x, rot_aabb.size.y) * 0.5
	if m == 0:
		return Transform3D()
	m = (1.0 / m) * 0.5
	xform.basis = xform.basis.scaled(Vector3(m, m, m))
	xform.origin = -(xform.basis * ofs)
	xform.origin.z -= rot_aabb.size.z * 2
	return xform


## The native generators' output shaping: shrink-to-box keeping aspect
## (never upscale, INTERPOLATE_CUBIC), RGBA8, rounded corners r=min/32.
func _texture_from(img: Image, size: Vector2i) -> Texture2D:
	var box := Vector2(img.get_width(), img.get_height())
	if box.x > size.x:
		box = Vector2(size.x, box.y * size.x / box.x)
	if box.y > size.y:
		box = Vector2(box.x * size.y / box.y, size.y)
	var target := Vector2i(maxi(1, int(box.x)), maxi(1, int(box.y)))
	if target != img.get_size():
		img.resize(target.x, target.y, Image.INTERPOLATE_CUBIC)
	_post_process(img)
	return ImageTexture.create_from_image(img)


## post_process_preview from editor_preview_plugins.cpp — RGBA8 + the
## four corners rounded to radius min(w,h)/32.
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
				var dx := absf(x - cx)
				var dy := absf(y - cy)
				if dx * dx + dy * dy > rf * rf:
					img.set_pixel(x, y, Color(0, 0, 0, 0))


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for r in _rids:
			if r.is_valid():
				RenderingServer.free_rid(r)
		_rids.clear()
