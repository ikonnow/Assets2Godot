@tool
extends Button
## ambientCG menu at the end of the tab's search row — same slot and
## mechanics as BlendKit's MainMenuButton (logo + status dot + the
## editor's "more" dots, toggled popup right-aligned below).
##
## The logo is ambientCG's own icon mark (logo/ambientcg-icon.svg, from
## the site's safari-pinned-tab asset) — docs.ambientcg.com/brand allows
## using it to reference ambientCG as long as no endorsement is implied;
## its menu links point back to ambientcg.com. The status dot tracks the
## catalog's reachability (the service this tab depends on): green
## online / red unreachable / yellow connecting. Items carry only
## ambientCG concerns — the catalog browses and downloads over plain
## HTTP; the Client/BlendKit controls live in the BlendKit tab's menu.

const Icons = preload("res://addons/assets2godot/ui/icons.gd")

enum Item {
	CATALOG, RELOAD, TARGET, ACCOUNT, LICENSE, WEBSITE,
	BROWSE, API_DOCS, PATREON, SOURCES, ISSUES,
	VERSION,
}

const ACG_ICON_PATH = "res://addons/assets2godot/logo/ambientcg-icon.svg"
const USER_ICON_PATH = "res://addons/assets2godot/ui/icons/user.svg"
const ACG_ICON_SVG_SIZE := 4096.0
const ACG_URL := "https://ambientcg.com"
const ACG_BROWSE_URL := "https://ambientcg.com/list"
const ACG_API_URL := "https://docs.ambientcg.com/api/v3/"
const ACG_LICENSE_URL := "https://docs.ambientcg.com/license/"
const ACG_PATREON_URL := "https://patreon.com/ambientcg"
const LOGO_SIZE := 16
const DOT_RADIUS := 3.5

var plugin: EditorPlugin
## The A2GAmbientcg panel this menu acts on (target dir, pick dialog,
## catalog_state).
var ambientcg: Control

var _content: HBoxContainer
var _logo: TextureRect
var _dot: Control
var _dots: TextureRect
var _menu: PopupMenu
var _logo_key := ""


## Called by the ambientCG tab once plugin and panel are known.
func setup(new_plugin: EditorPlugin, new_ambientcg: Control) -> void:
	plugin = new_plugin
	ambientcg = new_ambientcg
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
	if ambientcg.has_signal("catalog_state_changed"):
		ambientcg.catalog_state_changed.connect(func(_s): refresh())
	refresh()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _content:
		refresh()


func _catalog_state() -> int:
	return int(ambientcg.get("catalog_state")) if ambientcg != null else 0


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
		# The mark is monochrome (ambientCG ships it as a silhouette), so it
		# follows the editor-icon convention: light on dark themes, dark on light.
		_logo.texture = Icons.render_svg(ACG_ICON_PATH, LOGO_SIZE * edscale / ACG_ICON_SVG_SIZE, true)
	# Bottom right corner of the logo, half outside like a badge.
	var dot_size := Vector2.ONE * (DOT_RADIUS + 1.5) * 2 * edscale
	_dot.position = logo_size - dot_size * 0.6
	_dot.size = dot_size
	_dot.queue_redraw()
	_dots.texture = get_theme_icon("GuiTabMenuHl", "EditorIcons")
	_content.add_theme_constant_override("separation", int(4 * edscale))
	# The logo dims while the catalog is unreachable, the dot stays readable.
	_logo.self_modulate.a = 0.5 if _catalog_state() == 2 else 1.0
	tooltip_text = "ambientCG menu\n" + _hint()

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
		2: return "Catalog unreachable — offline or ambientcg.com down"
	return "Connecting to ambientcg.com…"


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
	_menu.set_item_tooltip(-1, "Reachability of ambientcg.com — the API is a one-person hobby service, expect the occasional hiccup.")
	# Recovery action in the "Restart Client" slot of the blueprint.
	_menu.add_icon_item(get_theme_icon("Reload", "EditorIcons"), "Reload catalog", Item.RELOAD)
	_menu.set_item_tooltip(-1, "Refetch the catalog from ambientcg.com")
	_menu.add_icon_item(get_theme_icon("Folder", "EditorIcons"), "Download folder…", Item.TARGET)
	var dir: String = ambientcg._target_dir() if ambientcg != null else ""
	_menu.set_item_tooltip(-1, "%s\nClick to change." % dir)
	_menu.add_separator("ambientCG")
	_menu.add_icon_item(_mono_icon(USER_ICON_PATH), "No account needed", Item.ACCOUNT)
	_menu.set_item_disabled(-1, true)
	_menu.set_item_tooltip(-1, "Everything on ambientcg.com is CC0 — no login, no key. Patreon supporters can pass an API token for perks; the catalog doesn't need it.")
	_menu.add_icon_item(get_theme_icon("Favorites", "EditorIcons"), "License: CC0", Item.LICENSE)
	_menu.set_item_tooltip(-1, ACG_LICENSE_URL + " — free for any use")
	_menu.add_separator()
	_menu.add_icon_item(_mono_icon(ACG_ICON_PATH, 16, ACG_ICON_SVG_SIZE), "ambientcg.com", Item.WEBSITE)
	_menu.set_item_tooltip(-1, ACG_URL)
	_menu.add_icon_item(get_theme_icon("ImageTexture", "EditorIcons"), "Browse assets", Item.BROWSE)
	_menu.set_item_tooltip(-1, ACG_BROWSE_URL + " — the site's own asset list")
	_menu.add_icon_item(get_theme_icon("HTTPRequest", "EditorIcons"), "API docs", Item.API_DOCS)
	_menu.set_item_tooltip(-1, ACG_API_URL)
	_menu.add_icon_item(get_theme_icon("Favorites", "EditorIcons"), "Support ambientCG", Item.PATREON)
	_menu.set_item_tooltip(-1, ACG_PATREON_URL + " — one person's CC0 library")
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
			if ambientcg != null:
				ambientcg.reload_catalog()
		Item.TARGET:
			if ambientcg != null:
				ambientcg._pick_target()
		Item.WEBSITE:
			OS.shell_open(ACG_URL)
		Item.BROWSE:
			OS.shell_open(ACG_BROWSE_URL)
		Item.API_DOCS:
			OS.shell_open(ACG_API_URL)
		Item.PATREON:
			OS.shell_open(ACG_PATREON_URL)
		Item.LICENSE:
			OS.shell_open(ACG_LICENSE_URL)
		Item.SOURCES:
			OS.shell_open(plugin.SOURCES_URL)
		Item.ISSUES:
			OS.shell_open(plugin.ISSUES_URL)


## Monochrome 16 px SVG icon matching the editor icons, rendered like the
## plugin's tab icon. size is in unscaled pixels; vb is the source SVG's
## viewBox side (16 for editor-style icons, 4096 for the ACG mark).
func _mono_icon(path: String, size := 16, vb := 16.0) -> Texture2D:
	return Icons.render_svg(path, size * EditorInterface.get_editor_scale() / vb, true)
