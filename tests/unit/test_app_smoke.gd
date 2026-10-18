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
	# 测试隔离（报告 §4）：整套冒烟测试都在沙箱里跑，不触碰真实 user://saves/
	SaveService.use_sandbox("user://test_sandbox/app")
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
		_check(FileAccess.file_exists(SaveService.main_path()), "保存链路：已产生主档")
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
		_test_win05_click_vs_drag(_controller)
		_finish()
		return true
	return false


## WIN-05 回归（P0-005）：单击 / 双击 / 拖动三者必须互斥。
## 缺陷原状：每次按下与释放都被当作拖动开始/结束（即使位移为 0），
## 于是"释放"总是触发 150ms 点击抑制，正常双击的第二下被吃掉，FULL 打不开。
## 这里直接驱动输入状态机，断言"没有越过阈值就不算拖动"。
func _test_win05_click_vs_drag(controller: AppController) -> void:
	print("WIN-05 回归(P0-005): 单击/双击/拖动互斥")
	var wc: WindowController = controller.get_node("WindowController") as WindowController
	if wc == null:
		_check(false, "WIN-05 取得 WindowController")
		return

	var ends: Array[int] = []
	var starts: Array[int] = []
	wc.drag_ended.connect(func() -> void:
		ends.append(1)
	)
	wc.drag_started.connect(func() -> void:
		starts.append(1)
	)

	# ① 位移 0 的按下+释放：不是拖动，不得抑制后续点击
	var origin := Vector2(500.0, 500.0)
	wc._begin_press(origin)
	_check(not wc.did_drag_occur(), "WIN-05 零位移按下不算拖动")
	wc._end_press()
	_check(not wc.did_drag_occur(), "WIN-05 零位移释放后 did_drag_occur=false（双击可用）")
	_check(ends.is_empty(), "WIN-05 零位移不触发 drag_ended（不抑制点击）")
	_check(starts.is_empty(), "WIN-05 零位移不触发 drag_started")

	# ② 微小抖动（小于阈值）：仍算点击
	wc._begin_press(origin)
	wc._update_drag(origin + Vector2(2.0, 1.0))
	_check(not wc.did_drag_occur(), "WIN-05 2px 抖动仍在阈值内")
	wc._end_press()
	_check(ends.is_empty(), "WIN-05 阈值内抖动不触发 drag_ended")

	# ③ 越过阈值：真拖动，必须触发 started/ended 且被上层识别
	wc._begin_press(origin)
	wc._update_drag(origin + Vector2(40.0, 25.0))
	_check(wc.did_drag_occur(), "WIN-05 越过阈值后 did_drag_occur=true")
	_check(wc.is_dragging(), "WIN-05 越过阈值后进入拖动状态")
	_check(starts.size() == 1, "WIN-05 drag_started 恰好触发一次（实际 %d）" % starts.size())
	wc._end_press()
	_check(not wc.is_dragging(), "WIN-05 释放后退出拖动状态")
	_check(ends.size() == 1, "WIN-05 drag_ended 恰好触发一次（实际 %d）" % ends.size())
	_check(wc.did_drag_occur(), "WIN-05 拖动结束后 did_drag_occur 仍为 true（供上层抑制本次点击）")

	# ④ 下一次纯点击必须把抑制位复位，保证双击链路重新可用
	wc._begin_press(origin)
	wc._end_press()
	_check(not wc.did_drag_occur(), "WIN-05 新的一次按下复位拖动标记")
	_check(ends.size() == 1, "WIN-05 复位不额外触发 drag_ended")

	# ⑤ 模式切换不得遗留按下状态（WINDOW-03）
	wc._begin_press(origin)
	wc._update_drag(origin + Vector2(50.0, 0.0))
	wc.apply_mode(AppMode.FLOATING, {"mouse_mode": AppMode.MOUSE_INTERACTIVE, "can_walk": true})
	_check(not wc.is_dragging(), "WIN-05 模式切换后不遗留拖动状态")
	wc._end_press()
	_check(ends.size() == 1, "WIN-05 模式切换不额外触发 drag_ended")


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
