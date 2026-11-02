extends Node
# Mod List Exporter
# Metro Mod Loader の mod_config.cfg を読み取り、
# 有効 / 無効 / 合計の mod 一覧を mod_list.txt に書き出します。
#  - ゲーム起動時に自動で1回出力
#  - 再出力キー(既定F8、MCMで変更可能)で再出力

const CONFIG_PATH := "user://mod_config.cfg"
const OUTPUT_NAME := "mod_list.txt"
const MOD_EXTS := ["vmz", "zip", "pck"]
const NL := "\r\n"

# --- MCM (Mod Configuration Menu) 連携 ---
const MOD_ID := "ModListExporter"
const MCM_DIR := "user://MCM/ModListExporter"
const MCM_FILE := "user://MCM/ModListExporter/config.ini"
# MCMでは「セクション名 = 値の型名」(Keycode)、キー名 = Input Action 名になる
const MCM_SECTION := "Keycode"
const MCM_OLD_SECTION := "Keybind"  # v1.1.0 で作ってしまった誤ったセクション(掃除用)
const MCM_KEY_NAME := "exportKey"
const MCM_HELPER_PATHS := [
	"res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres",
	"res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.gd",
]

# 再出力キー (MCM未導入ならF8のまま)
var export_key: int = KEY_F8


func _ready() -> void:
	_setup_mcm()
	generate()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	# MCM が Input Action を登録していればそれを優先(修飾キーにも対応)
	if InputMap.has_action(MCM_KEY_NAME):
		if event.is_action_pressed(MCM_KEY_NAME):
			generate()
		return
	# MCM なしの場合は F8 固定
	if event.keycode == export_key or event.physical_keycode == export_key:
		generate()


func _setup_mcm() -> void:
	# 設定ファイルを(なければ)作成する。
	# MCM はプロファイルごとの .ini (例: Test.ini) を読むので、フォルダ内の .ini を全部直す
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(MCM_DIR))
	var targets: Array = [MCM_FILE]
	for f in DirAccess.get_files_at(MCM_DIR):
		var full := MCM_DIR.path_join(f)
		if f.get_extension().to_lower() == "ini" and not targets.has(full):
			targets.append(full)
	for path in targets:
		_fix_ini(path)

	var config := ConfigFile.new()
	config.load(MCM_FILE)
	_apply_config(config)

	# MCM が入っていれば設定画面に登録(入っていなくても動く)
	var helpers = null
	for p in MCM_HELPER_PATHS:
		if ResourceLoader.exists(p):
			helpers = load(p)
			break
	if helpers == null:
		print("[ModListExporter] MCM が見つからないので、キーは F8 のままです")
		return
	if helpers.has_method("RegisterConfiguration"):
		helpers.RegisterConfiguration(
			MOD_ID,
			"Mod List Exporter",
			MCM_DIR,
			"有効/無効のmod一覧を mod_list.txt に書き出します",
			{"config.ini": _apply_config}
		)
	else:
		push_warning("[ModListExporter] MCM_Helpers に RegisterConfiguration が見つかりません")


func _fix_ini(path: String) -> void:
	var config := ConfigFile.new()
	if FileAccess.file_exists(path):
		config.load(path)
	var dirty := false
	if config.has_section(MCM_OLD_SECTION):
		config.erase_section(MCM_OLD_SECTION)
		dirty = true
	if not config.has_section_key(MCM_SECTION, MCM_KEY_NAME):
		config.set_value(MCM_SECTION, MCM_KEY_NAME, {
			"name": "再出力キー",
			"tooltip": "押すと mod_list.txt を作り直します(既定: F8)",
			"default": KEY_F8,
			"default_type": "Key",
			"value": KEY_F8,
			"type": "Key",
		})
		dirty = true
	if dirty:
		config.save(path)
		print("[ModListExporter] 設定ファイルを修正しました: ", path)


# MCM で保存された時にも呼ばれる
func _apply_config(config: ConfigFile) -> void:
	if config.has_section_key(MCM_SECTION, MCM_KEY_NAME):
		var entry = config.get_value(MCM_SECTION, MCM_KEY_NAME)
		if entry is Dictionary and entry.has("value"):
			export_key = int(entry["value"])
		elif entry is int:
			export_key = int(entry)
	print("[ModListExporter] 再出力キー: ", OS.get_keycode_string(export_key))


func generate() -> void:
	var lines: Array = []
	var now := Time.get_datetime_string_from_system(false, true)
	lines.append("==== Road to Vostok Mod List ====")
	lines.append("出力日時: %s" % now)
	lines.append("")

	var cfg := ConfigFile.new()
	var err := cfg.load(CONFIG_PATH)
	if err != OK:
		lines.append("mod_config.cfg を読み込めませんでした (エラーコード: %d)" % err)
		lines.append("一度 Mod Loader のランチャーで Launch してから、もう一度お試しください。")
		_output(lines)
		return

	var profile := _find_profile(cfg)
	var enabled_section := _enabled_section_name(cfg, profile)
	if enabled_section == "":
		lines.append("mod_config.cfg に mod の一覧が見つかりませんでした。")
		_output(lines)
		return

	var priority_section := enabled_section.replace(".enabled", ".priority")
	var enabled_mods: Array = []
	var disabled_mods: Array = []

	for key in cfg.get_section_keys(enabled_section):
		var raw = cfg.get_value(enabled_section, key, false)
		var is_on := str(raw).strip_edges().to_lower() == "true"
		var entry := _make_entry(str(key))
		entry["priority"] = str(cfg.get_value(priority_section, key, "0")) if cfg.has_section(priority_section) else "0"
		if is_on:
			enabled_mods.append(entry)
		else:
			disabled_mods.append(entry)

	enabled_mods.sort_custom(_by_name)
	disabled_mods.sort_custom(_by_name)

	var total := enabled_mods.size() + disabled_mods.size()
	if profile != "":
		lines.append("プロファイル: %s" % profile)
	lines.append("全体の数: %d" % total)
	lines.append("有効: %d" % enabled_mods.size())
	lines.append("無効: %d" % disabled_mods.size())
	lines.append("")

	lines.append("---- 有効な mod (%d) ----" % enabled_mods.size())
	_append_entries(lines, enabled_mods)
	lines.append("")
	lines.append("---- 無効な mod (%d) ----" % disabled_mods.size())
	_append_entries(lines, disabled_mods)
	lines.append("")

	var archive_count := _count_archives()
	if archive_count >= 0:
		lines.append("(参考) mods フォルダ内のファイル数: %d" % archive_count)

	_output(lines)


func _append_entries(lines: Array, entries: Array) -> void:
	if entries.is_empty():
		lines.append("(なし)")
		return
	for e in entries:
		var text := "・%s" % e["name"]
		if e["version"] != "":
			text += "  v%s" % e["version"]
		if e["priority"] != "0":
			text += "  [優先度 %s]" % e["priority"]
		lines.append(text)


func _make_entry(full_key: String) -> Dictionary:
	# キーは "ModName@Version" の形式
	var name := full_key
	var version := ""
	var at := full_key.rfind("@")
	if at > 0:
		name = full_key.substr(0, at)
		version = full_key.substr(at + 1)
	return {"name": name, "version": version, "priority": "0"}


func _by_name(a: Dictionary, b: Dictionary) -> bool:
	return str(a["name"]).to_lower() < str(b["name"]).to_lower()


func _find_profile(cfg: ConfigFile) -> String:
	var active := str(cfg.get_value("settings", "active_profile", "")).strip_edges()
	active = active.trim_prefix("\"").trim_suffix("\"")
	if active != "" and cfg.has_section("profile.%s.enabled" % active):
		return active
	for s in cfg.get_sections():
		if s.begins_with("profile.") and s.ends_with(".enabled"):
			return s.trim_prefix("profile.").trim_suffix(".enabled")
	return ""


func _enabled_section_name(cfg: ConfigFile, profile: String) -> String:
	if profile != "":
		return "profile.%s.enabled" % profile
	if cfg.has_section("enabled"):
		return "enabled"
	return ""


func _count_archives() -> int:
	var dir_path := OS.get_executable_path().get_base_dir().path_join("mods")
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return -1
	var n := 0
	for f in dir.get_files():
		if f.get_extension().to_lower() in MOD_EXTS:
			n += 1
	return n


func _output(lines: Array) -> void:
	var text := NL.join(PackedStringArray(lines)) + NL
	var saved: Array = []
	var game_path := OS.get_executable_path().get_base_dir().path_join(OUTPUT_NAME)
	if _write(game_path, text):
		saved.append(game_path)
	var user_path := ProjectSettings.globalize_path("user://" + OUTPUT_NAME)
	if _write("user://" + OUTPUT_NAME, text):
		saved.append(user_path)
	if saved.is_empty():
		push_warning("[ModListExporter] mod_list.txt を書き出せませんでした")
	else:
		print("[ModListExporter] 出力しました: ", ", ".join(PackedStringArray(saved)))


func _write(path: String, text: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	return true
