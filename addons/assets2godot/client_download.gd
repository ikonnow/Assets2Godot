@tool
extends RefCounted
## Download-on-first-run for the Blendkit Client: the Asset Store build ships
## no precompiled executables, so the plugin fetches the pinned release ZIP
## from GitHub and extracts only this platform's binary into the shared
## client data dir. Network-free statics; client_connection drives the HTTP.

const ClientBinary = preload("res://addons/assets2godot/client_binary.gd")

const RELEASES_BASE = "https://github.com/ikonnow/bk_client/releases/download/"


## ZIP asset URL for a client version like "1.13.12".
static func download_url(version: String) -> String:
	return RELEASES_BASE + "v" + version + "/bk_client.zip"


## Where the staged ZIP lands while downloading.
static func tmp_zip_path(version: String) -> String:
	var dir := ClientBinary.get_client_data_dir().path_join("download")
	return dir.path_join("bk_client-v" + version + ".zip")


## Final home of the extracted binary, shared across projects.
static func target_dir(version: String) -> String:
	return ClientBinary.get_client_data_dir().path_join("bin").path_join("v" + version)


## Expected sha256 of [param bin_name] from the bundled manifest.json, or ""
## when no manifest/entry exists (verification is skipped then).
static func expected_sha256(base_dir: String, version: String, bin_name: String) -> String:
	var manifest_path := base_dir.path_join("v" + version).path_join("manifest.json")
	var text := FileAccess.get_file_as_string(manifest_path)
	if text.is_empty():
		return ""
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return ""
	for b in data.get("binaries", []):
		if b.get("filename", "") == bin_name:
			return str(b.get("sha256", ""))
	return ""


## Extract [param bin_name] from the downloaded ZIP into [param target] and
## verify it against [param expected_sha] (skipped when empty). Returns "" on
## success or the reason it failed.
static func extract_binary(zip_path: String, bin_name: String, target: String, expected_sha: String) -> String:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return "cannot open downloaded ZIP"
	if not reader.file_exists(bin_name):
		reader.close()
		return "binary %s not in release ZIP" % bin_name
	var data := reader.read_file(bin_name)
	reader.close()
	if data.is_empty():
		return "binary %s empty in release ZIP" % bin_name

	if DirAccess.make_dir_recursive_absolute(target.get_base_dir()) != OK:
		return "cannot create %s" % target.get_base_dir()
	var f := FileAccess.open(target, FileAccess.WRITE)
	if not f:
		return "cannot write %s" % target
	f.store_buffer(data)
	f.close()

	if not expected_sha.is_empty() and FileAccess.get_sha256(target) != expected_sha:
		DirAccess.remove_absolute(target)
		return "sha256 mismatch for %s" % bin_name
	return ""
