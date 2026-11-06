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


static func kind_color(kind: String) -> Color:
	match kind:
		"model": return Color(0.22, 0.35, 0.55, 0.85)
		"texture": return Color(0.25, 0.5, 0.3, 0.85)
		"hdr": return Color(0.55, 0.4, 0.2, 0.85)
		"material": return Color(0.45, 0.3, 0.55, 0.85)
		"ue_asset": return Color(0.3, 0.3, 0.32, 0.9)
		"scene_data": return Color(0.35, 0.45, 0.55, 0.85)
		"metadata": return Color(0.35, 0.35, 0.4, 0.7)
		_: return Color(0.3, 0.3, 0.34, 0.8)


## A gallery-style card: full-bleed thumb area (kind-colored placeholder
## with the A2G icon until a real preview arrives via set_card_thumb),
## then title and a source·kind meta line.
static func asset_card(title: String, kind: String, source: String, path: String, icon: Texture2D) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(230, 250)
	card.tooltip_text = "%s\n%s" % [path, source]
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	card.add_child(vbox)

	# Thumbnail: clip panel, kind color behind, cube icon centered as
	# placeholder, real preview covering on top when it arrives.
	var clip := Panel.new()
	clip.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	clip.size_flags_vertical = Control.SIZE_EXPAND_FILL
	clip.custom_minimum_size = Vector2(0, 170)
	var style := StyleBoxFlat.new()
	style.bg_color = kind_color(kind)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	clip.add_theme_stylebox_override("panel", style)
	var bg := TextureRect.new()
	bg.texture = icon
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	bg.custom_minimum_size = Vector2(48, 48)
	bg.set_anchors_preset(Control.PRESET_CENTER)
	clip.add_child(bg)
	var tex := TextureRect.new()
	tex.set_anchors_preset(Control.PRESET_FULL_RECT)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	clip.add_child(tex)
	card.set_meta("thumb", tex)
	vbox.add_child(clip)

	var name_label := Label.new()
	name_label.text = title
	name_label.clip_text = true
	name_label.tooltip_text = title
	vbox.add_child(name_label)
	var meta := Label.new()
	meta.text = "%s · %s" % [kind, source]
	meta.add_theme_font_size_override("font_size", 11)
	meta.modulate = Color(1, 1, 1, 0.6)
	vbox.add_child(meta)
	return card


## Sets the real preview texture on a card built by asset_card().
static func set_card_thumb(card: Control, texture: Texture2D) -> void:
	if not is_instance_valid(card):
		return
	var t = card.get_meta("thumb", null)
	if t is TextureRect:
		t.texture = texture
