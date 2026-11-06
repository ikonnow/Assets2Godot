@tool
extends EditorContextMenuPlugin
## Injects Assets2Godot entries into Godot's own context menus via the
## engine's EditorContextMenuPlugin slot mechanism — no patched popups.
## FileSystem dock: "A2G: Scan folder…" adds the directory as a local_dir
## scan root. Scene tree: "A2G: Show scene resources" opens the Assets tab.

signal add_scan_root(path: String)
signal browse_scene_resources

var _slot: int = -1


func _init(slot: int) -> void:
	_slot = slot


func _popup_menu(paths: PackedStringArray) -> void:
	match _slot:
		CONTEXT_SLOT_FILESYSTEM:
			var dirs := []
			for p in paths:
				if DirAccess.dir_exists_absolute(p):
					dirs.append(p)
			if not dirs.is_empty():
				add_context_menu_item("A2G: Scan folder as root",
					func(_ctx = null): _emit_roots(dirs))
		CONTEXT_SLOT_SCENE_TREE:
			add_context_menu_item("A2G: Show scene resources",
				func(_ctx = null): browse_scene_resources.emit())


func _emit_roots(dirs: Array) -> void:
	for d in dirs:
		add_scan_root.emit(d)
