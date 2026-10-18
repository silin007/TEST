extends SceneTree

## 验证：接入 MousePassthrough 后，穿透级别是否真的从 app（仅同应用）
## 升级为 system（跨应用）。以及扩展缺失时是否正确回退。

var _frames: int = 0
var _main: Node = null


func _initialize() -> void:
	SaveService.use_sandbox("user://test_sandbox/probe_passthrough")
	var scene: PackedScene = load("res://scenes/app/main.tscn") as PackedScene
	_main = scene.instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 4:
		return false

	var app: AppController = _main as AppController
	var wc: WindowController = _main.get_node("WindowController") as WindowController

	print("=== 扩展可用性 ===")
	print("  has_system_passthrough() = ", wc.has_system_passthrough())
	print("  初始 passthrough_level   = ", wc.get_passthrough_level())

	# 穿透需要恢复入口就绪（架构 §4.1）
	wc.set_recovery_ready(true)
	var err: Error = wc.set_mouse_mode(AppMode.MOUSE_PASSTHROUGH)
	print("=== 切到 MOUSE_PASSTHROUGH ===")
	print("  set_mouse_mode err = ", err)
	print("  passthrough_level  = ", wc.get_passthrough_level())
	var env: Dictionary = wc.get_environment()
	print("  environment.passthrough_level = ", env.get("passthrough_level", "<缺失>"))
	var diag: Dictionary = app.get_diagnostics()
	print("  diagnostics.passthrough_level = ", diag.get("passthrough_level", "<缺失>"))
	print("  diagnostics.system_passthrough_available = ",
		diag.get("system_passthrough_available", "<缺失>"))

	print("=== 切回 INTERACTIVE ===")
	wc.set_mouse_mode(AppMode.MOUSE_INTERACTIVE)
	print("  passthrough_level  = ", wc.get_passthrough_level())

	var level: String = wc.get_passthrough_level()
	print(">>> 结论：has=", wc.has_system_passthrough(), " 最终 level=", level)
	quit(0)
	return true
