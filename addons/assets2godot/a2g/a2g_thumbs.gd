@tool
extends Node
## On-demand thumbnail renderer for asset files the EditorResourcePreview
## can't reach — anything outside res:// (vault caches, local roots).
## Images are decoded directly; .tres/.tscn resources are loaded and
## staged; .glb/.gltf are imported through GLTFDocument. Meshes, materials
## and scenes are rendered in a hidden SubViewport with a key light and a
## fitted camera — the same technique the engine's own preview plugins
## (EditorMeshPreviewPlugin & co.) use internally.
##
## Usage: thumbs.request(payload, "/abs/path.glb") -> rendered(payload, tex)

signal rendered(payload: Variant, texture: Texture2D)

const DEFAULT_SIZE := 256
const SETTING_SIZE := "assets2godot/thumb_size"
const PER_FRAME := 1
const IMAGE_EXTS := ["png", "jpg", "jpeg", "tga", "bmp", "webp", "exr", "hdr", "tif", "tiff", "svg"]

var _viewport: SubViewport
var _camera: Camera3D
var _holder: Node3D
var _queue: Array = []


func _ready() -> void:
	# Render size is an editor setting (Settings → Assets2Godot → Thumb
	# size); a missing value means this code ran outside the plugin.
	var size := DEFAULT_SIZE
	var es := EditorInterface.get_editor_settings()
	if es and es.has_setting(SETTING_SIZE):
		size = int(es.get_setting(SETTING_SIZE))
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(size, size)
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_viewport)

	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.13, 0.14, 0.16)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.9, 0.9, 0.95)
	env.ambient_light_energy = 0.7
	world_env.environment = env
	_viewport.add_child(world_env)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -35, 0)
	_viewport.add_child(light)

	_camera = Camera3D.new()
	_camera.fov = 40
	_camera.current = true
	_viewport.add_child(_camera)

	_holder = Node3D.new()
	_viewport.add_child(_holder)

	set_process(false)


## Queues a thumbnail render for an absolute filesystem path. Emits
## rendered() once done; files with no renderable content are skipped
## silently (the card keeps its placeholder).
func request(payload: Variant, path: String) -> void:
	_queue.append({"payload": payload, "path": path})
	set_process(true)


func _process(_delta: float) -> void:
	for i in mini(PER_FRAME, _queue.size()):
		var item: Dictionary = _queue.pop_front()
		var tex := _render_path(item["path"])
		if tex != null:
			rendered.emit(item["payload"], tex)
	if _queue.is_empty():
		set_process(false)


## Decodes or renders one file into a Texture2D, or null if unsupported.
func _render_path(path: String) -> Texture2D:
	if not FileAccess.file_exists(path):
		return null
	var ext := path.get_extension().to_lower()
	if ext in IMAGE_EXTS:
		var img := Image.load_from_file(path)
		return ImageTexture.create_from_image(img) if img != null else null

	var res: Resource = null
	var node: Node3D = null
	match ext:
		"tres", "res":
			res = ResourceLoader.load(path)
		"tscn", "scn":
			res = ResourceLoader.load(path)
		"glb", "gltf":
			var doc := GLTFDocument.new()
			var state := GLTFState.new()
			if doc.append_from_file(path, state) == OK:
				node = doc.generate_scene(state) as Node3D
	if res is Texture2D:
		return res
	if res is Mesh:
		var inst := MeshInstance3D.new()
		inst.mesh = res
		node = inst
	elif res is Material:
		var inst := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		inst.mesh = sphere
		inst.material_override = res
		node = inst
	elif res is PackedScene:
		node = res.instantiate() as Node3D

	if node == null:
		return null
	_holder.add_child(node)
	var aabb := _world_aabb(node)
	_frame(aabb)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	RenderingServer.force_draw()
	var image := _viewport.get_texture().get_image()
	_holder.remove_child(node)
	node.queue_free()
	return ImageTexture.create_from_image(image) if image != null else null


## Combined world-space AABB of every visual in the staged subtree.
func _world_aabb(root: Node) -> AABB:
	var aabb := AABB()
	var found := false
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n := stack.pop_back()
		if n is VisualInstance3D:
			var sub: AABB = n.global_transform * n.get_aabb()
			aabb = sub if not found else aabb.merge(sub)
			found = true
		stack.append_array(n.get_children())
	return aabb if found else AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)


## Positions the camera so the staged content fills the frame nicely.
func _frame(aabb: AABB) -> void:
	var center := aabb.get_center()
	var radius: float = maxf(aabb.size.length() * 0.5, 0.01)
	var dist := radius / tan(deg_to_rad(_camera.fov) * 0.5) * 1.35
	_camera.position = center + Vector3(0.8, 0.55, 1.0).normalized() * dist
	_camera.look_at(center, Vector3.UP)
