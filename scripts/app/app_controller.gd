class_name AppController
extends Node
## 装配、模式事务、受控时钟与保存调度（架构 §3 / §4.1 / §5.1 / §6.2 / §8）。
## 唯一把各模块连起来的地方：不做具体窗口几何、不直接写文件、不直接改 PetState。
##
## 时钟：使用单调运行时间（Time.get_ticks_msec）推进固定步进模拟；
## 墙钟仅用于持久化时间戳与诊断。系统时间回拨不影响 tick。

const PET_SCENE := preload("res://scenes/pet/pet.tscn")

## 自动保存周期（架构 §7.1）
const AUTOSAVE_INTERVAL := 60.0
## 合并防抖：拖动结束/模式或设置改变后 1 秒提交
const SAVE_DEBOUNCE := 1.0
## 双击判定交给系统（InputEventMouseButton.double_click），此常量仅保留为诊断记录用。
const DOUBLE_CLICK_WINDOW := 0.30
## 拖动结束后抑制点击的时长（秒）：仅当真正拖动过才生效（P0-005）
const DRAG_CLICK_SUPPRESS := 0.15
## 走动速度（像素/秒），仅 FLOATING 且 can_walk 时生效
const WALK_SPEED := 24.0

signal mode_switched(mode: StringName, mouse_mode: StringName, error: int)
signal save_result(revision: int, error: int)
signal recovery_action_received(action: StringName)
signal interaction_result(accepted: bool, reason: String)

var _state: PetState
var _ai: UtilityAI
var _executor: ActionExecutor
var _sim: PetSimulation
var _window_controller: WindowController
var _focus_controller := FocusController.new()
var _anim: AnimationController
var _panel: FullPanel
var _save := SaveService.new()
var _recovery := RecoveryEntry.new()

var _mode: StringName = AppMode.FLOATING
var _mouse_pref: StringName = AppMode.MOUSE_INTERACTIVE
var _previous_visible_mode: StringName = AppMode.FLOATING
var _focus_return_mode: StringName = AppMode.FLOATING
var _focus_return_mouse: StringName = AppMode.MOUSE_INTERACTIVE

var _running: bool = false
var _frozen: bool = false
var _input_frozen: bool = false
var _last_ticks: int = 0
var _autosave_timer: float = 0.0
var _debounce_timer: float = -1.0
var _last_click_time: float = -1.0
var _suppress_click_until: float = -1.0
var _walk_dir: int = 1
var _pending_shutdown: bool = false
var _save_status: String = "未保存"
var _load_problem: String = ""
## 最近一次模式切换失败的原因（P0-006：平台拒绝隐藏时必须让用户看见，不能静默）
var _last_mode_error: String = ""
var _saved_mode_for_startup: StringName = AppMode.FLOATING


func _ready() -> void:
	_window_controller = $WindowController as WindowController
	_anim = $Pet as AnimationController
	_panel = $FullPanel as FullPanel
	if _window_controller == null or _anim == null or _panel == null:
		push_error("AppController: 主场景结构不完整（需要 WindowController / Pet / FullPanel）")
		return
	_window_controller.drag_ended.connect(_on_drag_ended)
	_window_controller.geometry_corrected.connect(_on_geometry_corrected)
	_anim.animation_completed.connect(_on_animation_completed)
	_panel.action_requested.connect(_on_panel_action)
	_panel.candidate_selected.connect(_on_candidate_selected)

	add_child(_recovery)
	_recovery.action_requested.connect(_on_recovery_action)
	_recovery.availability_changed.connect(_on_recovery_availability)

	if _anim.has_node("ClickArea"):
		var area: Area2D = _anim.get_node("ClickArea") as Area2D
		area.input_event.connect(_on_pet_input_event)

	start_app()


## —— 启动 ——

func start_app() -> Error:
	if _running:
		return ERR_ALREADY_IN_USE
	_state = PetState.new()
	_ai = UtilityAI.new()
	_executor = ActionExecutor.new()
	_sim = PetSimulation.new(_state, _ai, _executor)
	_sim.action_started.connect(_on_action_started)
	_sim.action_finished.connect(_on_action_finished)
	_sim.time_gap_detected.connect(_on_time_gap)

	# 恢复入口：未就绪时 WindowController 会拒绝隐藏与穿透
	var entry_ready: bool = _recovery.setup()
	_window_controller.set_recovery_ready(entry_ready)
	_recovery.set_status("就绪" if entry_ready else _recovery.get_reason())

	var load_result: Dictionary = _save.load_snapshot()
	_apply_load_result(load_result)

	var startup_mode := _resolve_startup_mode()
	var err := switch_mode(startup_mode)
	if err != OK:
		push_error("AppController: 启动模式 %s 应用失败（%d），回退 FLOATING" % [startup_mode, err])
		switch_mode(AppMode.FLOATING)

	_running = true
	_last_ticks = Time.get_ticks_msec()
	_schedule_save()
	return OK


func _apply_load_result(result: Dictionary) -> void:
	var status: StringName = result["status"] as StringName
	if status == SaveValidator.STATUS_OK:
		var snapshot: Dictionary = result["snapshot"] as Dictionary
		_state.from_dictionary(snapshot["pet"] as Dictionary)
		_apply_settings(snapshot["settings"] as Dictionary)
		_save_status = "已加载 revision %d" % _save.get_revision()
		return

	if status == SaveValidator.STATUS_MISSING:
		# 仅真正缺档才建立默认宠物（架构 §7.2）
		_state.pet_id = _make_pet_id()
		var now: String = SaveValidator.utc_now()
		_state.created_at = now
		_state.updated_at = now
		_state.last_simulated_at = now
		_save_status = "首次运行，已建立默认宠物"
		return

	# RECOVERABLE / INVALID / UNSUPPORTED_VERSION：不静默覆盖，展示可见恢复路径
	_load_problem = str(result.get("error", "存档不可用"))
	_state.pet_id = _make_pet_id()
	_state.created_at = SaveValidator.utc_now()
	_save_status = "存档不可用，等待显式恢复"
	_previous_visible_mode = AppMode.FLOATING
	if _panel != null:
		var candidates: Array = result.get("candidates", []) as Array
		_panel.show_recovery(_load_problem, candidates)
	# 保证用户有可见入口：不可用时不进入隐藏/穿透
	_mode = AppMode.FLOATING
	_mouse_pref = AppMode.MOUSE_INTERACTIVE


func _apply_settings(settings: Dictionary) -> void:
	var saved_mode := StringName(str(settings.get("mode", AppMode.FLOATING)))
	if not AppMode.is_valid_mode(saved_mode):
		saved_mode = AppMode.FLOATING
	var saved_mouse := StringName(str(settings.get("mouse_preference", AppMode.MOUSE_INTERACTIVE)))
	_mouse_pref = saved_mouse if AppMode.is_valid_mouse(saved_mouse) else AppMode.MOUSE_INTERACTIVE
	var prev := StringName(str(settings.get("previous_visible_mode", AppMode.FLOATING)))
	_previous_visible_mode = prev if AppMode.is_valid_mode(prev) and prev != AppMode.HIDDEN else AppMode.FLOATING
	var focus_mode := StringName(str(settings.get("focus_return_mode", AppMode.FLOATING)))
	_focus_return_mode = focus_mode if (focus_mode == AppMode.FLOATING or focus_mode == AppMode.FULL) else AppMode.FLOATING
	var focus_mouse := StringName(str(settings.get("focus_return_mouse", AppMode.MOUSE_INTERACTIVE)))
	_focus_return_mouse = focus_mouse if AppMode.is_valid_mouse(focus_mouse) else AppMode.MOUSE_INTERACTIVE

	var floating := _rect_from_dict(settings.get("floating_rect", {}) as Dictionary, Rect2i(100, 100, 256, 256))
	var full := _rect_from_dict(settings.get("full_rect", {}) as Dictionary, Rect2i(100, 100, 960, 640))
	var hint: int = SaveValidator.as_int((settings.get("screen_hint", {}) as Dictionary).get("index", 0))
	_window_controller.apply_settings(floating, full, maxi(0, hint))
	# 启动是否采用记录的模式，由安全规则决定（见 _resolve_startup_mode）
	_saved_mode_for_startup = saved_mode



## 启动模式安全规则（架构 §4.1）：
## 记录 FOCUS 仅在入口就绪后恢复；记录 HIDDEN 恢复为隐藏前的可见模式；
## 穿透偏好只能在入口就绪后应用（由 _desired_mouse_for 保证）。
func _resolve_startup_mode() -> StringName:
	var saved: StringName = _saved_mode_for_startup
	if saved == AppMode.FOCUS:
		return AppMode.FOCUS if _recovery.is_ready() else AppMode.FLOATING
	if saved == AppMode.HIDDEN:
		return _previous_visible_mode if AppMode.is_visible(_previous_visible_mode) else AppMode.FLOATING
	return saved if AppMode.is_valid_mode(saved) else AppMode.FLOATING


## —— 模式事务 ——

func switch_mode(mode: StringName) -> Error:
	if not AppMode.is_valid_mode(mode):
		push_error("AppController.switch_mode: 非法模式 %s" % mode)
		return ERR_INVALID_PARAMETER
	var old_mode: StringName = _mode
	var policy: Dictionary = _focus_controller.get_policy(mode)
	policy["mouse_mode"] = _desired_mouse_for(mode)
	var err: Error = _window_controller.apply_mode(mode, policy)
	if err != OK:
		# 失败返回原可用状态，不留下“UI 已切换、窗口未切换”的状态
		var detail: String = "%s 失败（err=%d）" % [mode, err]
		_last_mode_error = detail
		push_error("AppController.switch_mode: %s，回退 %s" % [detail, old_mode])
		_window_controller.apply_mode(old_mode, _focus_controller.get_policy(old_mode))
		mode_switched.emit(old_mode, _window_controller.get_mouse_mode(), err)
		# 立即把失败原因显示在完整窗口上（若面板已可见）
		if _panel != null and _panel.visible:
			_panel.show_mode_error(detail)
		return err

	# 事务成功后再更新记忆中的返回目标
	_last_mode_error = ""
	if mode == AppMode.FOCUS and (old_mode == AppMode.FLOATING or old_mode == AppMode.FULL):
		_focus_return_mode = old_mode
		_focus_return_mouse = _window_controller.get_mouse_mode()
	if mode == AppMode.HIDDEN and AppMode.is_visible(old_mode):
		_previous_visible_mode = old_mode

	_mode = mode
	if _panel != null:
		_panel.visible = (mode == AppMode.FULL)
	_anim.play_action(_sim.get_current_action())
	_recovery.set_status("%s / %s" % [_mode, _window_controller.get_mouse_mode()])
	mode_switched.emit(mode, _window_controller.get_mouse_mode(), OK)
	_schedule_save()
	return OK


func _desired_mouse_for(mode: StringName) -> StringName:
	match mode:
		AppMode.FULL:
			return AppMode.MOUSE_INTERACTIVE
		AppMode.FOCUS, AppMode.HIDDEN:
			return AppMode.MOUSE_PASSTHROUGH
		_:
			# FLOATING：沿用用户偏好；穿透只有在入口就绪时才会被 WindowController 接受
			return _mouse_pref


func get_mode() -> StringName:
	return _mode


func get_mouse_mode() -> StringName:
	return _window_controller.get_mouse_mode() if _window_controller != null else _mouse_pref


## —— 受控时钟 ——

func _process(delta: float) -> void:
	if not _running:
		return
	var now: int = Time.get_ticks_msec()
	var dt: float = float(now - _last_ticks) / 1000.0
	_last_ticks = now
	if not _frozen:
		_sim.advance_time(dt)

	if _debounce_timer >= 0.0:
		_debounce_timer -= delta
		if _debounce_timer <= 0.0:
			_debounce_timer = -1.0
			_commit_save()
	_autosave_timer += delta
	if _autosave_timer >= AUTOSAVE_INTERVAL:
		_autosave_timer = 0.0
		_commit_save()

	_update_walk(delta)
	if _panel != null and _panel.visible:
		_panel.update_diagnostics(get_diagnostics())


## —— 互动 ——

## 单击 → 互动；双击（系统判定）→ FLOATING 打开 FULL。
## 拖动抑制：WindowController 只在真正越过阈值拖动后才发 drag_ended，
## 因此这里只需根据 drag_ended 置一个抑制位，未移动的按下不会污染点击（P0-005）。
func _on_pet_input_event(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if _input_frozen:
		return
	if not event is InputEventMouseButton:
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	if _mode != AppMode.FLOATING and _mode != AppMode.FULL:
		return
	# 刚结束真实拖动：这一次释放后的输入属于拖动手势，不当作点击
	if _window_controller != null and _window_controller.did_drag_occur():
		return
	var now_sec: float = float(Time.get_ticks_msec()) / 1000.0
	if now_sec < _suppress_click_until:
		return
	# 系统级双击判定：不自行计时，避免与平台双击间隔不一致
	if mb.double_click:
		_last_click_time = -1.0
		if _mode == AppMode.FLOATING:
			switch_mode(AppMode.FULL)
		return
	_last_click_time = now_sec
	request_interaction()


## 用户请求互动（react_happy）。请求失败不得奖励。
func request_interaction() -> Dictionary:
	if not _running:
		return {"accepted": false, "reason": "应用未运行"}
	var result: Dictionary = _sim.request_action(PetState.ACTION_REACT_HAPPY)
	var accepted: bool = bool(result["accepted"])
	if accepted:
		if not _anim.play_action(PetState.ACTION_REACT_HAPPY):
			push_warning("AppController: happy 动画播放失败，动作仍按模拟结果处理")
	interaction_result.emit(accepted, str(result["reason"]))
	return result


func _on_action_started(action: StringName, instance_id: int) -> void:
	_anim.play_action(action)
	if action == PetState.ACTION_WALK and _walk_dir == 0:
		_walk_dir = 1
	print("[MOTE] action_started %s #%d" % [action, instance_id])


func _on_action_finished(action: StringName, instance_id: int, success: bool, reason: String) -> void:
	if not success:
		push_warning("[MOTE] action_failed %s #%d: %s（回退 idle）" % [action, instance_id, reason])
	_anim.play_action(PetState.ACTION_IDLE)
	print("[MOTE] action_finished %s #%d success=%s reason=%s" % [action, instance_id, success, reason])


func _on_animation_completed(anim_name: StringName) -> void:
	# 动画完成只作表现通知；循环动作的结束由模拟侧决定（架构 §5.2）
	if anim_name == &"happy":
		_anim.play_action(PetState.ACTION_IDLE)


func _on_time_gap(gap_seconds: float) -> void:
	push_warning("[MOTE] time_gap %.1fs：清空积压、重置动作上下文" % gap_seconds)
	_executor.cancel_current_action("time_gap")
	_anim.play_action(PetState.ACTION_IDLE)


## —— 走动位移（仅 FLOATING，且不与拖动叠加）——

func _update_walk(delta: float) -> void:
	if _mode != AppMode.FLOATING or _window_controller == null:
		return
	if _window_controller.is_dragging() or _sim.get_current_action() != PetState.ACTION_WALK:
		return
	var env: Dictionary = _window_controller.get_environment()
	if not bool(env.get("can_walk", false)):
		return
	var win := get_window()
	if win == null:
		return
	var screen: int = _window_controller.get_screen_hint()
	var usable: Rect2i = DisplayServer.screen_get_usable_rect(screen)
	var next_x: int = win.position.x + int(round(WALK_SPEED * delta)) * _walk_dir
	if usable.size.x > 0:
		if next_x + win.size.x >= usable.position.x + usable.size.x:
			_walk_dir = -1
			next_x = usable.position.x + maxi(0, usable.size.x - win.size.x)
		elif next_x <= usable.position.x:
			_walk_dir = 1
			next_x = usable.position.x
	win.position = Vector2i(next_x, win.position.y)
	_anim.set_facing(_walk_dir)


## —— 保存调度 ——

func _schedule_save() -> void:
	_debounce_timer = SAVE_DEBOUNCE


func _commit_save() -> Error:
	if not _running:
		return ERR_UNAVAILABLE
	if _save.is_autosave_stopped():
		_save_status = "自动保存已停止（需显式恢复）"
		return ERR_UNAVAILABLE
	var now: String = SaveValidator.utc_now()
	_state.updated_at = now
	_state.last_simulated_at = now
	var err: Error = _save.save_snapshot(_build_snapshot())
	save_result.emit(_save.get_revision(), err)
	_save_status = ("已保存 revision %d" % _save.get_revision()) if err == OK else "保存失败：%s" % _save.get_last_error()
	if err != OK:
		push_error("[MOTE] 保存失败 %s" % _save.get_last_error())
	return err


## 立即提交一次保存（面板“保存”按钮与验收脚本入口）
func save_now() -> Error:
	return _commit_save()


## 诊断入口（架构 §8）：以模拟时间直接推进，绕过渲染帧间隔，供自动化验收使用。
func debug_advance(seconds: float) -> int:
	if not _running or _frozen:
		return 0
	return _sim.advance_time(seconds)


## 诊断入口（架构 §8）：注入保存故障，用于 SAVE-06 / WIN-07 类验证。
func debug_set_save_fault(stage: StringName, enabled: bool) -> void:
	_save.set_fault(stage, enabled)


## 诊断入口：退出事务是否冻结了 tick（保存失败应撤销冻结）
func is_frozen_for_test() -> bool:
	return _frozen


func _build_snapshot() -> Dictionary:
	return {
		"schema_version": SaveValidator.SCHEMA_VERSION,
		"save_id": _save.ensure_save_id(),
		"revision": _save.get_revision(),
		"saved_at": SaveValidator.utc_now(),
		"pet": _sim.get_snapshot(),
		"settings": _build_settings(),
		"memory": {},
		"sync": {"enabled": false},
	}


func _build_settings() -> Dictionary:
	return {
		"mode": String(_mode),
		"mouse_preference": String(_mouse_pref),
		"previous_visible_mode": String(_previous_visible_mode),
		"focus_return_mode": String(_focus_return_mode),
		"focus_return_mouse": String(_focus_return_mouse),
		"notifications_enabled": false,
		"floating_rect": _rect_to_dict(_window_controller.get_floating_rect()),
		"full_rect": _rect_to_dict(_window_controller.get_full_rect()),
		"screen_hint": _screen_hint(),
	}


## 无法可靠获得显示环境时写 null，不伪造精度（架构 §6.1）
func _screen_hint() -> Variant:
	var screen: int = _window_controller.get_screen_hint()
	if DisplayServer.get_screen_count() <= 0:
		return null
	if screen >= DisplayServer.get_screen_count():
		screen = 0
	var usable: Rect2i = DisplayServer.screen_get_usable_rect(screen)
	var resolution: Vector2i = DisplayServer.screen_get_size(screen)
	if usable.size.x <= 0 or usable.size.y <= 0 or resolution.x <= 0 or resolution.y <= 0:
		return null
	return {
		"index": screen,
		"usable_rect": _rect_to_dict(usable),
		"resolution": {"w": resolution.x, "h": resolution.y},
		"scale": null,
	}


func _rect_to_dict(rect: Rect2i) -> Dictionary:
	return {"x": rect.position.x, "y": rect.position.y, "w": rect.size.x, "h": rect.size.y}


func _rect_from_dict(data: Dictionary, fallback: Rect2i) -> Rect2i:
	if not data.has_all(["x", "y", "w", "h"]):
		return fallback
	var size := Vector2i(SaveValidator.as_int(data["w"]), SaveValidator.as_int(data["h"]))
	if size.x <= 0 or size.y <= 0:
		return fallback
	return Rect2i(Vector2i(SaveValidator.as_int(data["x"]), SaveValidator.as_int(data["y"])), size)


## —— 恢复入口事件 ——

func _on_recovery_action(action: StringName) -> void:
	recovery_action_received.emit(action)
	match action:
		RecoveryEntry.ACTION_RESTORE_INTERACT:
			# 明确的“恢复交互”：退出专注并进入 FLOATING/INTERACTIVE
			_mouse_pref = AppMode.MOUSE_INTERACTIVE
			switch_mode(AppMode.FLOATING)
		RecoveryEntry.ACTION_SHOW_PET:
			var target: StringName = _previous_visible_mode if AppMode.is_visible(_previous_visible_mode) else AppMode.FLOATING
			switch_mode(target)
		RecoveryEntry.ACTION_OPEN_FULL:
			switch_mode(AppMode.FULL)
		RecoveryEntry.ACTION_TOGGLE_FOCUS:
			if _mode == AppMode.FOCUS:
				var back: StringName = _focus_return_mode if AppMode.is_visible(_focus_return_mode) else AppMode.FLOATING
				switch_mode(back)
			else:
				switch_mode(AppMode.FOCUS)
		RecoveryEntry.ACTION_QUIT:
			shutdown_app()
		_:
			push_warning("AppController: 未知恢复入口动作 %s" % action)


func _on_recovery_availability(ready: bool, reason: String) -> void:
	_window_controller.set_recovery_ready(ready)
	if ready:
		return
	push_error("[MOTE] 恢复入口失效：%s（撤销穿透/隐藏）" % reason)
	if _mode == AppMode.HIDDEN or _mode == AppMode.FOCUS or _window_controller.get_mouse_mode() == AppMode.MOUSE_PASSTHROUGH:
		_mouse_pref = AppMode.MOUSE_INTERACTIVE
		switch_mode(AppMode.FLOATING)


func _on_drag_ended() -> void:
	_suppress_click_until = float(Time.get_ticks_msec()) / 1000.0 + DRAG_CLICK_SUPPRESS
	_schedule_save()


func _on_geometry_corrected(_old_rect: Rect2i, _new_rect: Rect2i, reason: String) -> void:
	push_warning("[MOTE] 窗口几何已修正：%s" % reason)
	_schedule_save()


## —— 完整窗口面板 ——

func _on_panel_action(action: StringName) -> void:
	match action:
		FullPanel.ACTION_BACK_TO_FLOATING:
			switch_mode(AppMode.FLOATING)
		FullPanel.ACTION_HIDE:
			switch_mode(AppMode.HIDDEN)
		FullPanel.ACTION_TOGGLE_FOCUS:
			if _mode == AppMode.FOCUS:
				switch_mode(_focus_return_mode)
			else:
				switch_mode(AppMode.FOCUS)
		FullPanel.ACTION_TOGGLE_PASSTHROUGH:
			_mouse_pref = AppMode.MOUSE_PASSTHROUGH if _mouse_pref == AppMode.MOUSE_INTERACTIVE else AppMode.MOUSE_INTERACTIVE
			switch_mode(_mode)  # 重新应用鼠标模式
		FullPanel.ACTION_QUIT:
			shutdown_app()
		&"SAVE_NOW":
			save_now()
		FullPanel.ACTION_CREATE_NEW_SAVE:
			_create_new_save()
		_:
			push_warning("AppController: 未知面板动作 %s" % action)


func _on_candidate_selected(path: String) -> void:
	var err: Error = _save.restore_from_candidate(path)
	if err != OK:
		push_error("[MOTE] 候选恢复失败：%s" % _save.get_last_error())
		return
	var result: Dictionary = _save.load_snapshot()
	if (result["status"] as StringName) == SaveValidator.STATUS_OK:
		_state.from_dictionary((result["snapshot"] as Dictionary)["pet"] as Dictionary)
		_apply_settings((result["snapshot"] as Dictionary)["settings"] as Dictionary)
		_save_status = "已从候选恢复 revision %d" % _save.get_revision()
		_load_problem = ""
		if _panel != null:
			_panel.hide_recovery()
		_schedule_save()


## 明确新建存档：新建前必须隔离现有文件，隔离失败则拒绝新建（架构 §7.2）。
## 通过 SaveService.start_new_save 走单一事务：隔离成功才解锁并首次提交，
## 避免"只解锁没隔离"或"已隔离却仍被写入锁拦住"的半状态（P0-001）。
func _create_new_save() -> Error:
	# 先摆好内存状态，再把快照交给事务做首次提交
	_state.reset_defaults()
	_state.pet_id = _make_pet_id()
	var now: String = SaveValidator.utc_now()
	_state.created_at = now
	_state.updated_at = now
	_state.last_simulated_at = now
	_mode = AppMode.FLOATING
	_mouse_pref = AppMode.MOUSE_INTERACTIVE

	var result: Dictionary = _save.start_new_save(_build_snapshot())
	if not bool(result.get("ok", false)):
		var detail: String = str(result.get("error", ""))
		push_error("[MOTE] 新建存档失败：%s" % detail)
		_save_status = "新建失败：%s" % detail
		return result.get("write_error", ERR_UNAVAILABLE) as Error

	_save_status = "已新建 revision %d（原件已隔离）" % _save.get_revision()
	_load_problem = ""
	if _panel != null:
		_panel.hide_recovery()
	return OK


## —— 退出 ——

## 正常退出：停止新输入 → 取消动作 → 冻结 tick → 尝试一次保存 → 释放入口 → 退出。
## 保存失败时撤销冻结与时钟采样，保持模拟、输入、进程与入口可用（架构 §8）。
func shutdown_app() -> Error:
	if _pending_shutdown:
		return ERR_BUSY
	_pending_shutdown = true
	_input_frozen = true
	_executor.cancel_current_action("app_shutdown")
	_frozen = true
	var err: Error = _commit_save()
	if err != OK:
		_frozen = false
		_input_frozen = false
		_pending_shutdown = false
		_last_ticks = Time.get_ticks_msec()
		push_error("[MOTE] 退出保存失败，进程保持可用：%s" % _save.get_last_error())
		return err
	_recovery.release()
	get_tree().quit()
	return OK


## 用户明确放弃本次未保存变更并退出（保存失败后的显式选择）
func shutdown_discard_changes() -> Error:
	_input_frozen = true
	_frozen = true
	_executor.cancel_current_action("app_shutdown")
	_recovery.release()
	get_tree().quit()
	return OK


## —— 诊断 ——

func get_diagnostics() -> Dictionary:
	var diag: Dictionary = {
		"needs": _state.needs.duplicate(true) if _state != null else {},
		"personality": _state.personality.duplicate(true) if _state != null else {},
		"current_action": String(_sim.get_current_action()) if _sim != null else "",
		"simulation_elapsed_seconds": _state.simulation_elapsed_seconds if _state != null else 0.0,
		"tick_count": _sim.get_tick_count() if _sim != null else 0,
		"mode": String(_mode),
		"mouse_mode": String(get_mouse_mode()),
		"recovery_kind": _recovery.get_kind(),
		"recovery_status": _recovery.get_reason(),
		"recovery_ready": _recovery.is_ready(),
		"revision": _save.get_revision(),
		"save_id": _save.get_save_id(),
		"save_path": ProjectSettings.globalize_path(SaveService.main_path()),
		"save_status": _save_status,
		"load_problem": _load_problem,
		"last_mode_error": _last_mode_error,
		# 穿透范围（WIN-02）：system=跨应用（Win32 扩展生效）；app=仅同应用；none=不穿透。
		# 只有 system 才说明具备跨应用穿透能力，另两者不得宣称满足 WIN-02。
		"passthrough_level": _window_controller.get_passthrough_level() if _window_controller != null else "none",
		"system_passthrough_available": _window_controller.has_system_passthrough() if _window_controller != null else false,
	}
	# 平台侧真实状态（P0-006）：诊断不能只报应用内部 mode，必须同时给出窗口实际状态
	if _window_controller != null:
		diag.merge(_window_controller.get_platform_state())
	diag.merge(_save.get_diagnostics())
	return diag


func _make_pet_id() -> String:
	return "pet-%s" % ("%d-%d" % [Time.get_unix_time_from_system(), randi() % 1000000]).sha256_text().substr(0, 12)
