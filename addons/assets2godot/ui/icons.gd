@tool
extends RefCounted
## Blendkit logo and icons rendered from SVG at the editor scale.

# Monochrome editor tab icon, drawn in #e0e0e0 like the built-in editor icons.
const ICON_PATH = "res://addons/assets2godot/logo/blendkit-icon.svg"
const LOGO_PATH = "res://addons/assets2godot/logo/blendkit-logo-hexa_pure.svg"
const LOGO_SVG_SIZE = 320.0
## Renders kept, more are rendered again, see render_svg().
const CACHE_SIZE := 32

static var _rendered: Dictionary = {}


## Renders the SVG at [param scale] times its size, e.g. the editor scale for
## a 16 px icon, so it stays crisp. Monochrome icons turn dark on light themes.
## The textures are shared, so they must not be changed.
static func render_svg(path: String, scale: float, monochrome := false) -> Texture2D:
	var dark := monochrome and not is_dark_icon_theme()
	var key := "%s %s %s" % [path, scale, dark]
	if _rendered.has(key):
		return _rendered[key]
	var svg := FileAccess.get_file_as_string(path)
	if dark:
		# Same conversion as Godot does for its own icons on light themes.
		svg = svg.replace("#e0e0e0", "#5a5a5a")
	var image := Image.new()
	if svg.is_empty() or image.load_svg_from_string(svg, scale) != OK:
		return null
	if _rendered.size() >= CACHE_SIZE:
		_rendered.clear()
	_rendered[key] = ImageTexture.create_from_image(image)
	return _rendered[key]


## Renders the SVG's *painted* bounds at [param px] on the long side,
## independent of the file's canvas size or inner padding — a swapped
## logo file can't break the layout. Rendered at 2× and downscaled like
## the staged thumbs, so arbitrary artwork stays crisp. For SVGs whose
## content already fills the canvas this is a no-op over render_svg().
static func render_svg_fit(path: String, px: float, monochrome := false) -> Texture2D:
	var dark := monochrome and not is_dark_icon_theme()
	var key := "fit %s %s %s" % [path, px, dark]
	if _rendered.has(key):
		return _rendered[key]
	var svg := FileAccess.get_file_as_string(path)
	if svg.is_empty():
		return null
	if dark:
		svg = svg.replace("#e0e0e0", "#5a5a5a")
	var probe := Image.new()
	if probe.load_svg_from_string(svg, 1.0) != OK:
		return null
	var used := probe.get_used_rect()
	if used.size.x < 1 or used.size.y < 1:
		return null
	var scale := px * 2.0 / maxf(used.size.x, used.size.y)
	var img := Image.new()
	if img.load_svg_from_string(svg, scale) != OK:
		return null
	var crop := Rect2i(used.position * scale, used.size * scale)
	crop = crop.intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	img = img.get_region(crop)
	img.resize(maxi(1, int(img.get_width() * 0.5)),
		maxi(1, int(img.get_height() * 0.5)), Image.INTERPOLATE_LANCZOS)
	if _rendered.size() >= CACHE_SIZE:
		_rendered.clear()
	_rendered[key] = ImageTexture.create_from_image(img)
	return _rendered[key]


## The colored Blendkit logo, [param px] pixels wide.
static func render_logo(px: float) -> Texture2D:
	return render_svg(LOGO_PATH, px / LOGO_SVG_SIZE)


# Mirrors EditorThemeManager::is_dark_icon_and_font(): light icons and fonts
# on a dark theme.
static func is_dark_icon_theme() -> bool:
	var settings := EditorInterface.get_editor_settings()
	match settings.get_setting("interface/theme/icon_and_font_color"):
		1: return false # dark icons
		2: return true # light icons
	var base_color: Color = settings.get_setting("interface/theme/base_color")
	return base_color.get_luminance() < 0.5
