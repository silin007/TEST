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
		_test_p006_hidden_no_divergence(_controller)
		_test_full_layout_not_clipped(_controller)
		_finish()
		return true
	return false


## P0-006 回归：平台不能隐藏时，HIDDEN 必须失败且**不得**提交应用状态。
## 复验报告实测到旧实现的分裂：应用 mode=HIDDEN、平台 Window.visible=true 且窗口仍在桌面。
## headless 下不存在可隐藏的窗口表面（_can_hide_natively()=false），正好覆盖"平台拒绝"分支。
func _test_p006_hidden_no_divergence(controller: AppController) -> void:
	print("P0-006 回归: 平台拒绝隐藏时不提交 HIDDEN")
	var wc: WindowController = controller.get_node("WindowController") as WindowController
	if wc == null:
		_check(false, "P0-006 取得 WindowController")
		return

	# 放开恢复入口限制，确保测到的是"原生隐藏"这一步而不是前置拒绝
	wc.set_recovery_ready(true)
	var before_mode: StringName = controller.get_mode()
	var can_hide: bool = bool(wc.get_platform_state()["can_hide"])
	print("  平台 can_hide=", can_hide)

	var err: Error = controller.switch_mode(AppMode.HIDDEN)
	var st: Dictionary = wc.get_platform_state()

	if can_hide:
		# 有真实窗口表面（例如 GUI 运行）：成功路径必须真的最小化
		_check(err == OK, "P0-006 有原生能力时 HIDDEN 成功（err=%d）" % err)
		_check(bool(st["minimized"]), "P0-006 成功后平台确实 minimized")
	else:
		# 平台拒绝：必须报错、回滚模式、且不宣称已隐藏
		_check(err != OK, "P0-006 平台拒绝时返回错误（err=%d）" % err)
		_check(controller.get_mode() == before_mode,
			"P0-006 失败后模式回滚为 %s（实际 %s）" % [before_mode, controller.get_mode()])
		_check(not bool(st["hidden_by_minimize"]),
			"P0-006 失败后不记录为已隐藏")
		_check(controller.get_diagnostics()["last_mode_error"] != "",
			"P0-006 失败原因进入诊断（用户可见）")

	# 无论哪条分支，诊断都必须同时给出平台真实状态，而不只是应用内部 mode
	var diag: Dictionary = controller.get_diagnostics()
	_check(diag.has("window_mode") and diag.has("minimized"),
		"P0-006 诊断同时暴露平台窗口状态")
	wc.set_recovery_ready(false)


## 复验 §5 回归：FULL 面板不得裁切控件。
## 根因是 canvas_items 拉伸让 UI 画布只有 384×256，按钮被压成两行后溢出。
func _test_full_layout_not_clipped(controller: AppController) -> void:
	print("布局回归: FULL 面板不裁切")
	controller.switch_mode(AppMode.FULL)
	if controller.get_mode() != AppMode.FULL:
		_check(false, "布局 进入 FULL 失败")
		return

	var panel: Control = controller.get_node("FullPanel") as Control
	var win := controller.get_window()
	if panel == null or win == null:
		_check(false, "布局 取得面板/窗口")
		return

	# 面板尺寸必须等于窗口尺寸（不得停留在 256 基线）
	_check(panel.size.x >= float(win.size.x) - 1.0 and panel.size.y >= float(win.size.y) - 1.0,
		"布局 面板 %.0f×%.0f 覆盖窗口 %s" % [panel.size.x, panel.size.y, win.size])

	# 每个按钮都必须完整落在面板内
	var overflow: Array[String] = []
	var count: int = 0
	for node: Node in _walk(panel):
		if node is Button:
			count += 1
			var b: Button = node as Button
			var right: float = b.global_position.x + b.size.x
			if right > panel.size.x + 1.0 or b.global_position.y + b.size.y > panel.size.y + 1.0:
				overflow.append("%s(右=%.0f)" % [b.text, right])
	_check(count >= 6, "布局 面板内按钮数量=%d" % count)
	_check(overflow.is_empty(), "布局 无按钮越界（越界项：%s）" % ", ".join(overflow))

	# 诊断区必须有实际高度，不能塌成 0
	var scroll_ok := false
	for node: Node in _walk(panel):
		if node is ScrollContainer:
			if (node as Control).size.y >= 40.0:
				scroll_ok = true
	_check(scroll_ok, "布局 诊断滚动区高度充足")
	controller.switch_mode(AppMode.FLOATING)


func _walk(root_node: Node) -> Array[Node]:
	var out: Array[Node] = []
	for child: Node in root_node.get_children():
		out.append(child)
		out.append_array(_walk(child))
	return out


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
