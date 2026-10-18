extends SceneTree
## 装配冒烟：加载主场景、跑若干帧，检查 AppController 装配、模式事务与模拟推进。
## 运行：Godot --headless --path . --script res://tests/unit/test_app_smoke.gd
##
## 注意：headless 下无法验证真实窗口表现（透明/穿透/托盘），
## 仅验证装配、状态机、时钟与保存链路；桌面能力仍须实机验收。

var _failures: Array[String] = []
var _frames: int = 0
var _main: Node = null
var _controller: AppController = null


func _initialize() -> void:
	var scene: PackedScene = load("res://scenes/app/main.tscn") as PackedScene
	if scene == null:
		print("FAIL 加载 main.tscn")
		quit(1)
		return
	_main = scene.instantiate()
	root.add_child(_main)


func _process(delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		_controller = _main as AppController
		_check(_controller != null, "装配：主场景根节点为 AppController")
		if _controller == null:
			_finish()
			return true
		_check(_controller.has_node("WindowController"), "装配：存在 WindowController")
		_check(_controller.has_node("Pet"), "装配：存在 Pet 骨骼角色")
		_check(_controller.has_node("FullPanel"), "装配：存在 FullPanel")
		_check(_controller.get_mode() == AppMode.FLOATING, "启动默认 FLOATING，实际=%s" % _controller.get_mode())
		var diag: Dictionary = _controller.get_diagnostics()
		print("  诊断: ", JSON.stringify(diag).substr(0, 400))
		_check(float(diag["simulation_elapsed_seconds"]) > 0.0 or int(diag["tick_count"]) >= 0,
			"装配：模拟时钟已启动")
		return false

	if _frames == 3:
		# 模式事务：恢复入口未就绪时拒绝隐藏
		var recovery_ready: bool = bool(_controller.get_diagnostics()["recovery_ready"])
		print("  恢复入口就绪=", recovery_ready)
		if not recovery_ready:
			var err: Error = _controller.switch_mode(AppMode.HIDDEN)
			_check(err != OK, "安全规则：入口未就绪时拒绝 HIDDEN")
			_check(_controller.get_mode() == AppMode.FLOATING, "安全规则：失败后仍在 FLOATING")
		# 互动请求返回结果
		var result: Dictionary = _controller.request_interaction()
		_check(result.has("accepted") and result.has("reason"), "互动请求返回 accepted/reason")
		return false

	if _frames == 5:
		# 诊断入口：直接推进模拟时间（headless 帧间隔不足以凑满 0.1s 步长）
		var ticks: int = _controller.debug_advance(1.0)
		_check(ticks == 10, "受控时钟：推进 1.0 秒得到 10 个 tick，实际=%d" % ticks)
		var diag2: Dictionary = _controller.get_diagnostics()
		print("  推进后 tick=", diag2["tick_count"], " 模拟秒=", diag2["simulation_elapsed_seconds"],
			" 动作=", diag2["current_action"])
		_check(float(diag2["simulation_elapsed_seconds"]) > 0.0, "受控时钟：模拟秒数已累加")
		_check(_controller.save_now() == OK, "保存链路：显式保存成功")
		_check(FileAccess.file_exists("user://saves/save.json"), "保存链路：已产生主档")
		var svc := SaveService.new()
		var loaded: Dictionary = svc.load_snapshot()
		_check(loaded["status"] == SaveValidator.STATUS_OK, "保存链路：重启可加载 OK，实际=%s" % loaded["status"])
		# 退出事务：注入保存故障后，退出必须失败且进程保持可用
		_controller.debug_set_save_fault(SaveService.STAGE_TMP_WRITE, true)
		var shutdown_err: Error = _controller.shutdown_app()
		_check(shutdown_err != OK, "退出事务：保存失败时退出被拒绝")
		_check(not _controller.is_frozen_for_test(), "退出事务：保存失败后撤销冻结，进程保持可用")
		_controller.debug_set_save_fault(SaveService.STAGE_TMP_WRITE, false)
		svc.clear_all_for_test()
		_finish()
		return true
	return false


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS ", label)
	else:
		print("FAIL ", label)
		_failures.append(label)


func _finish() -> void:
	if _failures.is_empty():
		print("ALL APP SMOKE TESTS PASSED")
		quit(0)
	else:
		print("FAILURES (%d):" % _failures.size())
		for f: String in _failures:
			print("  - ", f)
		quit(1)
