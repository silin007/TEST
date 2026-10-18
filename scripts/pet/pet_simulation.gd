class_name PetSimulation
extends RefCounted
## 生命模拟（架构 §5）：唯一修改核心 PetState 的模块；协调 ActionExecutor 与 UtilityAI。
## 不访问 Node、窗口、磁盘、网络。固定步长推进；结果通过返回值/信号对外暴露。
##
## 奖励发放规则（架构 §5.2 / PET-04）：react_happy 成功开始并完成才应用一次
## comfort+2、social_need-5；失败/取消/重复事件不重复奖励。

signal action_started(action: StringName, instance_id: int)
signal action_finished(action: StringName, instance_id: int, success: bool, reason: String)
signal time_gap_detected(gap_seconds: float)

const SIM_DT := 0.1
## 决策节奏：每 1 秒模拟时间（架构 §5.1）
const DECISION_INTERVAL := 1.0
## 时间断点阈值（秒）：单次间隔大于此值视为暂停/挂起（架构 §5.1）
const GAP_SECONDS := 5.0
## 补步上限：每渲染轮最多 50 tick（架构 §5.1）
const MAX_CATCH_UP_TICKS := 50

## 每秒变化基线（架构 §5.2）
const ENERGY_DRAIN := -0.01
const ENERGY_REST_GAIN := 0.10
const HUNGER_GAIN := 0.005
const COMFORT_DRAIN := -0.002
const SOCIAL_GAIN := 0.005
const HAPPY_COMFORT_BONUS := 2.0
const HAPPY_SOCIAL_CHANGE := -5.0

var _state: PetState
var _ai: UtilityAI
var _executor: ActionExecutor

## 决策累计时间（决定何时重新 choose_action）
var _decision_timer := 0.0
## 累计 tick 计数（诊断）
var _tick_count := 0
## 上次成功发奖的 happy 实例（幂等）
var _rewarded_instance_id := -1

## 诊断钩子：固定动作选择（架构 §8 要求诊断可固定行为；SIM-01 用固定 idle）
var _fixed_action: StringName = &""


func _init(state: PetState, ai: UtilityAI, executor: ActionExecutor) -> void:
	_state = state
	_ai = ai
	_executor = executor
	_executor.action_started.connect(_on_executor_started)
	_executor.action_finished.connect(_on_executor_finished)


func get_state() -> PetState:
	return _state


func get_tick_count() -> int:
	return _tick_count


func get_executor() -> ActionExecutor:
	return _executor


func get_current_action() -> StringName:
	return _state.current_action


## 固定动作诊断钩子（空串表示不固定）。固定后决策点直接采用该动作；
## 且在推进开始时立即生效，确保从首 tick 起即为该动作（SIM-01 精确匹配）。
func set_fixed_action(action: StringName) -> void:
	_fixed_action = action
	if action != &"" and _state.current_action != action:
		var instance_id := _next_instance_id()
		if _executor.execute(action, instance_id):
			_state.current_action = action
			action_started.emit(action, instance_id)


func get_fixed_action() -> StringName:
	return _fixed_action


## 固定步长推进。dt 为单调运行时间（秒）。返回实际应用的 tick 数。
func advance_time(dt: float) -> int:
	if dt < 0.0:
		push_warning("PetSimulation.advance_time: 负 dt 忽略")
		return 0
	if dt > GAP_SECONDS:
		# 时间断点：不补算、不惩罚、清积压，仅记录
		time_gap_detected.emit(dt)
		_decision_timer = 0.0
		return 0
	if _fixed_action != &"" and _state.current_action != _fixed_action:
		var instance_id := _next_instance_id()
		if _executor.execute(_fixed_action, instance_id):
			_state.current_action = _fixed_action
			action_started.emit(_fixed_action, instance_id)
	var applied := 0
	var accumulator := dt
	while accumulator >= SIM_DT and applied < MAX_CATCH_UP_TICKS:
		_step(SIM_DT)
		accumulator -= SIM_DT
		applied += 1
	return applied


## 用户请求一个动作（当前仅 react_happy 为可请求互动）。
## 返回 {accepted: bool, reason: String, instance_id: int}
func request_action(id: StringName) -> Dictionary:
	var environment := _environment()
	var evaluation := _ai.evaluate_request(_state, environment, id)
	if not bool(evaluation["accepted"]):
		return {"accepted": false, "reason": str(evaluation["reason"]), "instance_id": 0}
	var instance_id := _next_instance_id()
	var started := _executor.execute(id, instance_id)
	if not started:
		return {"accepted": false, "reason": "执行器拒绝（可能同类动作运行中或冷却）", "instance_id": 0}
	_state.current_action = id
	return {"accepted": true, "reason": "", "instance_id": instance_id}


## 处理外部动作事件（完成/失败），幂等。
func on_action_event(event: Dictionary) -> void:
	var action: StringName = StringName(str(event.get("action", "")))
	var instance_id := int(event.get("instance_id", 0))
	var success := bool(event.get("success", false))
	var reason := str(event.get("reason", ""))
	_apply_happy_reward_if_needed(action, instance_id, success)
	if success:
		_state.current_action = PetState.ACTION_IDLE
	action_finished.emit(action, instance_id, success, reason)


## 只读快照（不泄露可变引用）
func get_snapshot() -> Dictionary:
	return _state.to_dictionary()


func _step(dt: float) -> void:
	_tick_count += 1
	_state.simulation_elapsed_seconds += dt
	_tick_needs(dt)
	_executor.tick(dt)
	_decision_timer += dt
	if _decision_timer >= DECISION_INTERVAL:
		_decide()
		_decision_timer = 0.0


## 决策：UtilityAI 选择目标动作，若与当前不同则让执行器切换。
func _decide() -> void:
	if _fixed_action != &"":
		var fixed: StringName = _fixed_action
		if fixed != _state.current_action:
			var fixed_instance := _next_instance_id()
			if _executor.execute(fixed, fixed_instance):
				_state.current_action = fixed
				action_started.emit(fixed, fixed_instance)
		return
	var environment := _environment()
	var choice: StringName = _ai.choose_action(_state.to_dictionary(), _state.personality, environment)
	if choice != _state.current_action:
		var instance_id := _next_instance_id()
		if _executor.execute(choice, instance_id):
			_state.current_action = choice
			action_started.emit(choice, instance_id)


func _environment() -> Dictionary:
	return {
		"can_walk": true,
		"action_running": _executor.is_busy(),
		"current_action": _state.current_action,
		"action_elapsed": _executor.get_action_elapsed(),
		"cooldowns": _executor.get_cooldowns(),
	}


func _tick_needs(dt: float) -> void:
	var needs: Dictionary = _state.needs
	var resting := _state.current_action == PetState.ACTION_REST
	var energy_delta := ENERGY_REST_GAIN if resting else ENERGY_DRAIN
	needs["energy"] = clampf(float(needs["energy"]) + energy_delta * dt, PetState.NEED_MIN, PetState.NEED_MAX)
	needs["hunger"] = clampf(float(needs["hunger"]) + HUNGER_GAIN * dt, PetState.NEED_MIN, PetState.NEED_MAX)
	needs["comfort"] = clampf(float(needs["comfort"]) + COMFORT_DRAIN * dt, PetState.NEED_MIN, PetState.NEED_MAX)
	needs["social_need"] = clampf(float(needs["social_need"]) + SOCIAL_GAIN * dt, PetState.NEED_MIN, PetState.NEED_MAX)


## 仅在 react_happy 成功完成时应用一次奖励（幂等，防止重复事件重复发奖）
func _apply_happy_reward_if_needed(action: StringName, instance_id: int, success: bool) -> void:
	if action != PetState.ACTION_REACT_HAPPY or not success:
		return
	if _rewarded_instance_id == instance_id:
		return
	_rewarded_instance_id = instance_id
	var needs: Dictionary = _state.needs
	needs["comfort"] = clampf(float(needs["comfort"]) + HAPPY_COMFORT_BONUS, PetState.NEED_MIN, PetState.NEED_MAX)
	needs["social_need"] = clampf(float(needs["social_need"]) + HAPPY_SOCIAL_CHANGE, PetState.NEED_MIN, PetState.NEED_MAX)


func _next_instance_id() -> int:
	return _tick_count * 1000 + _tick_count + 1


func _on_executor_started(_action: StringName, _instance_id: int) -> void:
	# 执行器已开始：PetState.current_action 由 _decide / request_action 同步
	pass


func _on_executor_finished(action: StringName, instance_id: int, success: bool, reason: String) -> void:
	# 执行器结束动作：同步 PetState 并应用奖励
	_apply_happy_reward_if_needed(action, instance_id, success)
	_state.current_action = PetState.ACTION_IDLE
	action_finished.emit(action, instance_id, success, reason)
