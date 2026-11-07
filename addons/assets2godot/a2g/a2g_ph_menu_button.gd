@tool
extends Button
## Polyhaven menu at the end of the tab's search row — same slot and
## mechanics as BlendKit's MainMenuButton (logo + status dot + the
## editor's "more" dots, toggled popup right-aligned below).
##
## The logo is the official Poly Haven mark (logo/polyhaven-icon.svg) —
## permitted use #2 on polyhaven.com/logo: credit for a product built on
## their API; its menu links point back to polyhaven.com as required.
## The status dot tracks the catalog's reachability (the service this
## tab depends on): green online / red unreachable / yellow connecting.
## Items carry only Polyhaven concerns — the catalog browses and
## downloads over plain HTTP; the Client/BlendKit controls live in the
## BlendKit tab's menu (client status also shows in the A2G dock).

const Icons = preload("res://addons/assets2godot/ui/icons.gd")

enum Item {
	CATALOG, RELOAD, TARGET, ACCOUNT, LICENSE, WEBSITE,
	GALLERY, CONTRIBUTE, PATRON, LEARN, API, SERVICE_STATUS, SOURCES, ISSUES,
	VERSION,
}

const PH_ICON_PATH = "res://addons/assets2godot/logo/polyhaven-icon.svg"
const USER_ICON_PATH = "res://addons/assets2godot/ui/icons/user.svg"
const PH_ICON_SVG_SIZE := 1250.0
const PH_URL := "https://polyhaven.com"
const PH_GALLERY_URL := "https://polyhaven.com/gallery"
const PH_CONTRIBUTE_URL := "https://polyhaven.com/contribute"
const PH_PATRON_URL := "https://www.patreon.com/polyhaven/join"
const PH_LEARN_URL := "https://polyhaven.com/learn"
const PH_API_URL := "https://polyhaven.com/our-api"
const PH_LICENSE_URL := "https://polyhaven.com/license"
const PH_STATUS_URL := "https://status.polyhaven.org/"
const LOGO_SIZE := 16
const DOT_RADIUS := 3.5

var plugin: EditorPlugin
## The A2GPolyhaven panel this menu acts on (target dir, pick dialog,
## catalog_state).
var polyhaven: Control

var _content: HBoxContainer
var _logo: TextureRect
var _dot: Control
var _dots: TextureRect
var _menu: PopupMenu
var _logo_key := ""


## Called by the Polyhaven tab once plugin and panel are known.
func setup(new_plugin: EditorPlugin, new_polyhaven: Control) -> void:
	plugin = new_plugin
	polyhaven = new_polyhaven
	text = ""
	icon = null
	_content = HBoxContainer.new()
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_content.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(_content)
	_logo = TextureRect.new()
	_logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Containers floor shrink-centered positions, so icons land on whole
	# pixels and draw crisp.
	_logo.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_content.add_child(_logo)
	_dot = Control.new()
	_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dot.draw.connect(_draw_dot)
	_logo.add_child(_dot)
	_dots = TextureRect.new()
	_dots.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dots.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_content.add_child(_dots)

	_menu = PopupMenu.new()
	add_child(_menu)
	_menu.id_pressed.connect(_on_id_pressed)
	_menu.popup_hide.connect(func(): set_pressed_no_signal(false))
	toggle_mode = true
	toggled.connect(_on_toggled)
	if polyhaven.has_signal("catalog_state_changed"):
		polyhaven.catalog_state_changed.connect(func(_s): refresh())
	refresh()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _content:
		refresh()


func _catalog_state() -> int:
	return int(polyhaven.get("catalog_state")) if polyhaven != null else 0


## Update the status dot, tooltip and, when open, the menu — same contract
## as BlendKit's button.
func refresh() -> void:
	if _content == null:
		return
	var edscale := EditorInterface.get_editor_scale()
	var logo_size := Vector2.ONE * LOGO_SIZE * edscale
	_logo.custom_minimum_size = logo_size
	var key := str(edscale)
	if key != _logo_key:
		_logo_key = key
		_logo.texture = Icons.render_svg(PH_ICON_PATH, LOGO_SIZE * edscale / PH_ICON_SVG_SIZE)
	# Bottom right corner of the logo, half outside like a badge.
	var dot_size := Vector2.ONE * (DOT_RADIUS + 1.5) * 2 * edscale
	_dot.position = logo_size - dot_size * 0.6
	_dot.size = dot_size
	_dot.queue_redraw()
	_dots.texture = get_theme_icon("GuiTabMenuHl", "EditorIcons")
	_content.add_theme_constant_override("separation", int(4 * edscale))
	# The logo dims while the catalog is unreachable, the dot stays readable.
	_logo.self_modulate.a = 0.5 if _catalog_state() == 2 else 1.0
	tooltip_text = "Polyhaven menu\n" + _hint()

	var style := get_theme_stylebox("normal", "Button")
	custom_minimum_size = _content.get_combined_minimum_size() + style.get_minimum_size()
	# As tall as a text button, like the Asset Store's search row buttons.
	var font := get_theme_font("font", "Button")
	var font_height := font.get_height(get_theme_font_size("font_size", "Button"))
	custom_minimum_size.y = maxf(custom_minimum_size.y, font_height + style.get_minimum_size().y)
	_content.offset_left = style.get_margin(SIDE_LEFT)
	_content.offset_right = -style.get_margin(SIDE_RIGHT)
	if _menu.visible:
		_fill_menu()


## The catalog reachability first — the tab's actual dependency.
func _hint() -> String:
	match _catalog_state():
		1: return "Catalog online — CC0, no account needed"
		2: return "Catalog unreachable — offline or polyhaven.com down"
	return "Connecting to polyhaven.com…"


func status_color() -> Color:
	match _catalog_state():
		1: return get_theme_color("success_color", "Editor")
		2: return get_theme_color("error_color", "Editor")
	return get_theme_color("warning_color", "Editor")


func _draw_dot() -> void:
	var edscale := EditorInterface.get_editor_scale()
	var center := _dot.size / 2
	# A ring in the button color separates the dot from the logo.
	var ring := get_theme_color("base_color", "Editor")
	var style := get_theme_stylebox("normal", "Button")
	if style is StyleBoxFlat:
		ring = style.bg_color
	ring.a = 1.0
	_dot.draw_circle(center, (DOT_RADIUS + 1.5) * edscale, ring)
	_dot.draw_circle(center, DOT_RADIUS * edscale, status_color())


func _on_toggled(pressed: bool) -> void:
	if not pressed:
		_menu.hide()
		return
	_fill_menu()
	_menu.reset_size()
	var canvas_scale := get_global_transform_with_canvas().get_scale()
	# Right-aligned below the button, positioned like MenuButton does it.
	var pos := get_screen_position() + Vector2(size.x * canvas_scale.x - _menu.size.x, size.y * canvas_scale.y)
	_menu.popup(Rect2i(Vector2i(pos), _menu.size))


## Same row layout as BlendKit's menu: a disabled status line + the tab's
## one real setting, then the provider section (its "Account" — CC0 needs
## no login, the license is the "plan"), links, versions. Short labels only:
## the popup is as wide as its longest item.
func _fill_menu() -> void:
	_menu.clear()
	var cs := _catalog_state()
	var cat_icon: Texture2D = get_theme_icon("StatusSuccess", "EditorIcons") if cs == 1 else \
		get_theme_icon("StatusError", "EditorIcons") if cs == 2 else get_theme_icon("Timer", "EditorIcons")
	_menu.add_icon_item(cat_icon, "Catalog: %s" % ["connecting…", "online", "unreachable"][cs], Item.CATALOG)
	_menu.set_item_disabled(-1, true)
	_menu.set_item_tooltip(-1, "Reachability of api.polyhaven.com — see Service status below.")
	# Recovery action in the "Restart Client" slot of the blueprint.
	_menu.add_icon_item(get_theme_icon("Reload", "EditorIcons"), "Reload catalog", Item.RELOAD)
	_menu.set_item_tooltip(-1, "Refetch the catalog from api.polyhaven.com")
	_menu.add_icon_item(get_theme_icon("Folder", "EditorIcons"), "Download folder…", Item.TARGET)
	var dir: String = polyhaven._target_dir() if polyhaven != null else ""
	_menu.set_item_tooltip(-1, "%s\nClick to change." % dir)
	_menu.add_separator("Polyhaven")
	_menu.add_icon_item(_mono_icon(USER_ICON_PATH), "No account needed", Item.ACCOUNT)
	_menu.set_item_disabled(-1, true)
	_menu.set_item_tooltip(-1, "Everything on polyhaven.com is CC0 — no login, no key.")
	_menu.add_icon_item(get_theme_icon("Favorites", "EditorIcons"), "License: CC0", Item.LICENSE)
	_menu.set_item_tooltip(-1, PH_LICENSE_URL + " — free for any use")
	_menu.add_separator()
	_menu.add_icon_item(_mono_icon(PH_ICON_PATH, 16, PH_ICON_SVG_SIZE), "polyhaven.com", Item.WEBSITE)
	_menu.set_item_tooltip(-1, PH_URL)
	_menu.add_icon_item(get_theme_icon("ImageTexture", "EditorIcons"), "Community gallery", Item.GALLERY)
	_menu.set_item_tooltip(-1, PH_GALLERY_URL + " — renders shared by the community")
	_menu.add_icon_item(get_theme_icon("Add", "EditorIcons"), "Contribute assets", Item.CONTRIBUTE)
	_menu.set_item_tooltip(-1, PH_CONTRIBUTE_URL + " — share your own CC0 assets")
	_menu.add_icon_item(get_theme_icon("Favorites", "EditorIcons"), "Support Poly Haven", Item.PATRON)
	_menu.set_item_tooltip(-1, PH_PATRON_URL + " — community-funded library")
	_menu.add_icon_item(get_theme_icon("Help", "EditorIcons"), "User Guide", Item.LEARN)
	_menu.set_item_tooltip(-1, PH_LEARN_URL)
	_menu.add_icon_item(get_theme_icon("HTTPRequest", "EditorIcons"), "API", Item.API)
	_menu.set_item_tooltip(-1, PH_API_URL)
	_menu.add_icon_item(get_theme_icon("Timer", "EditorIcons"), "Service status", Item.SERVICE_STATUS)
	_menu.set_item_tooltip(-1, PH_STATUS_URL)
	_menu.add_icon_item(get_theme_icon("Script", "EditorIcons"), "README & Sources", Item.SOURCES)
	_menu.set_item_tooltip(-1, plugin.SOURCES_URL)
	_menu.add_icon_item(get_theme_icon("Debug", "EditorIcons"), "Report an Issue", Item.ISSUES)
	_menu.set_item_tooltip(-1, plugin.ISSUES_URL)
	_menu.add_separator()
	_menu.add_item("A2G Plugin v%s" % plugin.get_addon_version(), Item.VERSION)
	_menu.set_item_disabled(-1, true)


func _on_id_pressed(id: int) -> void:
	match id:
		Item.RELOAD:
			if polyhaven != null:
				polyhaven.reload_catalog()
		Item.TARGET:
			if polyhaven != null:
				polyhaven._pick_target()
		Item.WEBSITE:
			OS.shell_open(PH_URL)
		Item.GALLERY:
			OS.shell_open(PH_GALLERY_URL)
		Item.CONTRIBUTE:
			OS.shell_open(PH_CONTRIBUTE_URL)
		Item.PATRON:
			OS.shell_open(PH_PATRON_URL)
		Item.LEARN:
			OS.shell_open(PH_LEARN_URL)
		Item.API:
			OS.shell_open(PH_API_URL)
		Item.SERVICE_STATUS:
			OS.shell_open(PH_STATUS_URL)
		Item.LICENSE:
			OS.shell_open(PH_LICENSE_URL)
		Item.SOURCES:
			OS.shell_open(plugin.SOURCES_URL)
		Item.ISSUES:
			OS.shell_open(plugin.ISSUES_URL)


## Monochrome 16 px SVG icon matching the editor icons, rendered like the
## plugin's tab icon. size is in unscaled pixels; vb is the source SVG's
## viewBox side (16 for editor-style icons, 1250 for the PH mark).
func _mono_icon(path: String, size := 16, vb := 16.0) -> Texture2D:
	return Icons.render_svg(path, size * EditorInterface.get_editor_scale() / vb, true)
