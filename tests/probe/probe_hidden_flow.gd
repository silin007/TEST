extends SceneTree
## 探针：HIDDEN 模式的原生隐藏与恢复（P0-006 复验）。
## 必须在**有显示驱动**时运行（不要 --headless），否则拿不到真实窗口模式。
## 运行：Godot.exe --path . --script res://tests/probe/probe_hidden_flow.gd

var _frames: int = 0
var _main: Node = null
var _phase: int = 0
var _app: AppController = null
var _wc: WindowController = null


func _initialize() -> void:
	SaveService.use_sandbox("user://test_sandbox/probe_hidden")
	var scene: PackedScene = load("res://scenes/app/main.tscn") as PackedScene
	_main = scene.instantiate()
	root.add_child(_main)


func _process(_d: float) -> bool:
	_frames += 1
	if _frames < 4:
		return false
	_app = _main as AppController
	_wc = _main.get_node("WindowController") as WindowController

	match _phase:
		0:
			_show("初始")
			_phase = 1
		1:
			print("=== 进入 FULL ===")
			_app.switch_mode(AppMode.FULL)
			_show("FULL 后")
			_phase = 2
		2:
			print("=== 进入 HIDDEN（走原生最小化）===")
			var err: Error = _app.switch_mode(AppMode.HIDDEN)
			print("switch_mode(HIDDEN) 返回 err=", err)
			_show("HIDDEN 后")
			var st: Dictionary = _wc.get_platform_state()
			var ok: bool = err == OK and bool(st["minimized"])
			print("判定：应用mode=HIDDEN 且 平台minimized → ", ok)
			_phase = 3
		3:
			print("=== 从 HIDDEN 恢复到 FLOATING ===")
			var err2: Error = _app.switch_mode(AppMode.FLOATING)
			print("switch_mode(FLOATING) 返回 err=", err2)
			_show("恢复后")
			var st2: Dictionary = _wc.get_platform_state()
			print("判定：恢复后不再 minimized → ", not bool(st2["minimized"]))
			print("=== 结束 ===")
			quit(0)
			return true
	return false


func _show(tag: String) -> void:
	var st: Dictionary = _wc.get_platform_state()
	print("[%s] 应用mode=%s  平台状态=%s" % [tag, _app.get_mode(), JSON.stringify(st)])
