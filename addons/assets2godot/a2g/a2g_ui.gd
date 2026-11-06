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
	"tscn": "scene_data", "gd": "scene_data", "gdshader": "scene_data",
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

const GALLERY_ITEM := preload("res://addons/assets2godot/ui/gallery/gallery_item.tscn")
const GalleryItemScript = preload("res://addons/assets2godot/ui/gallery/gallery_item.gd")


## The identical tile the BlendKit gallery uses — a real GalleryItem scene
## instance configured for a local/indexed asset via setup_a2g(), so every
## A2G surface is pixel-identical by construction.
static func asset_card(title: String, kind: String, source: String, path: String, _icon: Texture2D, type_name: String = "") -> Control:
	var item: Control = GALLERY_ITEM.instantiate()
	item.setup_a2g(title, kind, type_name, "%s\n%s · %s\n%s" % [title, kind, source, path],
		{"path": path, "kind": kind, "source": source})
	return item


## Sets the real preview texture on a card built by asset_card().
static func set_card_thumb(card: Control, texture: Texture2D) -> void:
	if is_instance_valid(card) and card.has_method("set_thumb_texture"):
		card.set_thumb_texture(texture)


## The same column math as ui/gallery/gallery.gd's update_columns(): cards
## are widened so every row fills the scroll view exactly, minimum
## GalleryItem.MIN_WIDTH * editor scale.
static func update_columns(scroll: ScrollContainer, grid: GridContainer) -> void:
	var min_width := GalleryItemScript.MIN_WIDTH * EditorInterface.get_editor_scale()
	var separation := grid.get_theme_constant("h_separation")
	var available := scroll.size.x
	var columns := maxi(1, int((available + separation) / (min_width + separation)))
	var width := maxf(min_width, floorf((available + separation) / columns - separation))
	if grid.columns != columns:
		grid.columns = columns
	for c in grid.get_children():
		c.set_width(width)


## A GridContainer configured like the gallery's grid (gap = GAP * scale).
static func make_grid() -> GridContainer:
	var grid := GridContainer.new()
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var gap := int(GalleryItemScript.GAP * EditorInterface.get_editor_scale())
	grid.add_theme_constant_override("h_separation", gap)
	grid.add_theme_constant_override("v_separation", gap)
	return grid
