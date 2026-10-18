extends SceneTree
## 集成验收补充：必须在独立验收 user:// 中运行，会写入专用夹具。
## 原项目直接启动会退出 2，避免覆盖真实用户档。
var _app: AppController
var _wall_elapsed: float = 0.0
var _before: String = ""
var _failures: int = 0
var _checks: int = 0
var _enabled: bool = false

func _initialize() -> void:
	if not OS.get_user_data_dir().contains("MOTE_P0_AUDIT_INTEGRATION_"):
		print("REFUSED: run only in isolated MOTE_P0_AUDIT_INTEGRATION_ user directory")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://saves"))
	var future: Dictionary = SaveValidator.make_default_wrapper(SaveValidator.utc_now())
	future["schema_version"] = 999
	_before = JSON.stringify(future, "\t")
	var file := FileAccess.open("user://saves/save.json", FileAccess.WRITE)
	file.store_string(_before)
	file.close()
	var scene: PackedScene = load("res://scenes/app/main.tscn") as PackedScene
	_app = scene.instantiate() as AppController
	root.add_child.call_deferred(_app)
	_enabled = true

func _process(delta: float) -> bool:
	if not _enabled:
		return false
	_wall_elapsed += delta
	if _wall_elapsed < 3.0:
		return false
	var file := FileAccess.open("user://saves/save.json",FileAccess.READ)
	var after: String = file.get_as_text()
	file.close()
	var data: Dictionary = JSON.parse_string(after) as Dictionary
	print("MEASURE SAVE-07 wall_seconds=%.3f disk_schema=%s autosave_stopped=%s" % [_wall_elapsed,str(data.get("schema_version")),str(_app.get_diagnostics()["autosave_stopped"])])
	_check(after == _before,"SAVE-07: unknown future save must remain byte-identical after startup debounce")
	_check(int(data.get("schema_version",0)) == 999,"SAVE-07: startup must not replace future schema with v1")
	print("INTEGRATION AUDIT RESULT: checks=%d failures=%d" % [_checks,_failures])
	quit(0 if _failures == 0 else 1)
	return true

func _check(condition: bool,label: String) -> void:
	_checks += 1
	print(("PASS " if condition else "FAIL ") + label)
	if not condition:
		_failures += 1
