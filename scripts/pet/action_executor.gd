class_name ActionExecutor
extends RefCounted
## 动作执行器（架构 §5.2 / §6.2）：管理动作生命周期 FSM 与冷却。
## 纯逻辑：不播放动画、不移动窗口。PetSimulation 是协调者，本类负责：
##   - 动作实例 FSM：IDLE → STARTING → RUNNING → FINISHED/CANCELLED/FAILED → IDLE
##   - 非 rest 动作在最短持续到点后自动结束并进入冷却（架构 §5.2 第 4 条）；
##     rest 例外：由决策层在 energy>=60 时切换走，不自动结束
##   - 冷却表维护（walk/look 10 秒、happy 2 秒、失败候选 10 秒）

signal action_started(action: StringName, instance_id: int)
signal action_finished(action: StringName, instance_id: int, success: bool, reason: String)

## 各动作最短持续（架构 §5.2 第 4 条）。rest 不在其中（由决策层控制）。
const MIN_DURATIONS: Dictionary = {
	PetState.ACTION_IDLE: 5.0,
	PetState.ACTION_WALK: 6.0,
	PetState.ACTION_LOOK_AROUND: 4.0,
	PetState.ACTION_REACT_HAPPY: 2.0,
}
const FAILURE_COOLDOWN := 10.0
const WALK_LOOK_COOLDOWN := 10.0
const HAPPY_COOLDOWN := 2.0

enum State { IDLE, STARTING, RUNNING, FINISHED, CANCELLED, FAILED }

var _state: int = State.IDLE
var _current_action: StringName = PetState.ACTION_IDLE
var _current_instance_id: int = 0
var _elapsed: float = 0.0
var _cooldowns: Dictionary = {}


func get_state() -> int:
	return _state


func get_current_action() -> StringName:
	return _current_action


func get_current_instance_id() -> int:
	return _current_instance_id


## 当前动作已持续秒数（供 UtilityAI 判断最短持续）
func get_action_elapsed() -> float:
	return _elapsed


func is_busy() -> bool:
	return _state != State.IDLE


## 冷却表（只读，供 UtilityAI.choose_action 使用）
func get_cooldowns() -> Dictionary:
	return _cooldowns.duplicate()


## 请求开始一个动作。若已在运行不同动作则先取消（切换）；同一动作重复请求忽略。
## 返回是否成功开始。instance_id 由调用方递增提供。
func execute(action: StringName, instance_id: int) -> bool:
	if _state == State.RUNNING:
		if _current_action == action:
			return false  # 同类动作已运行，幂等拒绝
		_cancel_for_switch()
	if _is_on_cooldown(action):
		return false
	_start(action, instance_id)
	return true


## 取消当前动作（拖动开始时调用）
func cancel_current_action(reason: String) -> void:
	if _state != State.RUNNING:
		return
	_finish(State.CANCELLED, false, reason)


## 每次 tick 推进：非 rest 动作最短持续到点自动结束 + 冷却衰减
func tick(dt: float) -> void:
	if _state == State.RUNNING:
		_elapsed += dt
		if _current_action != PetState.ACTION_REST \
				and MIN_DURATIONS.has(_current_action) \
				and _elapsed >= float(MIN_DURATIONS[_current_action]):
			_finish(State.FINISHED, true, "")
			return
	else:
		_elapsed = 0.0
	_decay_cooldowns(dt)


## 故障注入/异常防护：强制当前动作失败（PET-04⑤）
func force_timeout() -> void:
	if _state == State.RUNNING:
		_fail("injected execution timeout")


## 外部报告动画完成（仅作表现通知；非有限动作由协调者决定结束）
func on_animation_finished(action: StringName, instance_id: int) -> void:
	if _state != State.RUNNING or _current_instance_id != instance_id:
		return  # 陈旧事件，忽略
	if action == PetState.ACTION_REACT_HAPPY:
		_finish(State.FINISHED, true, "")


## 外部报告动作失败
func on_failed(action: StringName, instance_id: int, reason: String) -> void:
	if _state != State.RUNNING or _current_instance_id != instance_id:
		return
	_fail(reason)


func _start(action: StringName, instance_id: int) -> void:
	_state = State.RUNNING
	_current_action = action
	_current_instance_id = instance_id
	_elapsed = 0.0
	action_started.emit(action, instance_id)


func _cancel_for_switch() -> void:
	var old_action: StringName = _current_action
	var old_instance: int = _current_instance_id
	_state = State.IDLE
	_current_action = PetState.ACTION_IDLE
	_current_instance_id = 0
	_elapsed = 0.0
	# 切换也算一次完成：walk/look 进入冷却，防止霸占
	if old_action == PetState.ACTION_WALK or old_action == PetState.ACTION_LOOK_AROUND:
		_set_cooldown(old_action, WALK_LOOK_COOLDOWN)
	action_finished.emit(old_action, old_instance, false, "switch")


func _finish(next_state: int, success: bool, reason: String) -> void:
	var finished_action: StringName = _current_action
	var finished_instance: int = _current_instance_id
	# 结束时的冷却（架构 §5.2：walk/look 完成后 10 秒冷却；happy 2 秒；rest/idle 无）
	if finished_action == PetState.ACTION_WALK or finished_action == PetState.ACTION_LOOK_AROUND:
		_set_cooldown(finished_action, WALK_LOOK_COOLDOWN)
	elif finished_action == PetState.ACTION_REACT_HAPPY:
		_set_cooldown(finished_action, HAPPY_COOLDOWN)
	_state = next_state
	_current_action = PetState.ACTION_IDLE
	_current_instance_id = 0
	_elapsed = 0.0
	action_finished.emit(finished_action, finished_instance, success, reason)


func _fail(reason: String) -> void:
	# 失败候选冷却 10 秒（架构 §5.2 第 5 条）
	_set_cooldown(_current_action, FAILURE_COOLDOWN)
	_finish(State.FAILED, false, reason)


func _is_on_cooldown(action: StringName) -> bool:
	return _cooldowns.has(action) and float(_cooldowns[action]) > 0.0


func _set_cooldown(action: StringName, seconds: float) -> void:
	_cooldowns[action] = seconds


func _decay_cooldowns(dt: float) -> void:
	for key: StringName in _cooldowns.keys():
		var remaining: float = float(_cooldowns[key]) - dt
		if remaining <= 0.0:
			_cooldowns.erase(key)
		else:
			_cooldowns[key] = remaining
