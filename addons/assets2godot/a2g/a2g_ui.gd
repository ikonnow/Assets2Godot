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


static func kind_color(kind: String) -> Color:
	match kind:
		"model": return Color(0.22, 0.35, 0.55, 0.85)
		"texture": return Color(0.25, 0.5, 0.3, 0.85)
		"hdr": return Color(0.55, 0.4, 0.2, 0.85)
		"material": return Color(0.45, 0.3, 0.55, 0.85)
		"ue_asset": return Color(0.3, 0.3, 0.32, 0.9)
		"scene_data": return Color(0.35, 0.45, 0.55, 0.85)
		"resource": return Color(0.4, 0.4, 0.45, 0.85)
		"animation": return Color(0.55, 0.35, 0.35, 0.85)
		"file": return Color(0.32, 0.32, 0.34, 0.8)
		"metadata": return Color(0.35, 0.35, 0.4, 0.7)
		_: return Color(0.3, 0.3, 0.34, 0.8)


const A2GCard = preload("res://addons/assets2godot/a2g/a2g_card.gd")


## A gallery-style card identical in look to ui/gallery/gallery_item.tscn:
## square clipped thumbnail, kind badge, name below, hover/focus frame.
static func asset_card(title: String, kind: String, source: String, path: String, icon: Texture2D) -> Control:
	var card: Control = A2GCard.new()
	card.setup(title, kind, source, path, {"path": path, "kind": kind, "source": source}, icon)
	return card


## Sets the real preview texture on a card built by asset_card().
static func set_card_thumb(card: Control, texture: Texture2D) -> void:
	if is_instance_valid(card) and card.has_method("set_thumbnail"):
		card.set_thumbnail(texture)
