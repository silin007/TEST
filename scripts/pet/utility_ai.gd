class_name UtilityAI
extends RefCounted
## 纯规则行为选择（架构 §5.2）：根据快照、性格与环境返回候选动作；无副作用。
## 冷却/动作计时由 ActionExecutor 维护，通过 environment 注入，本类不持有可变状态。

const REST_THRESHOLD := 30.0
const REST_MIN_SECONDS := 20.0
const REST_END_ENERGY := 60.0
## 各动作最短持续（架构 §5.2 第 4 条）：完成后重新评分
const MIN_DURATIONS: Dictionary = {
	PetState.ACTION_IDLE: 5.0,
	PetState.ACTION_WALK: 6.0,
	PetState.ACTION_LOOK_AROUND: 4.0,
	PetState.ACTION_REACT_HAPPY: 2.0,
}

const IDLE_SCORE := 0.25
const WALK_BASE_SCORE := 0.15
const WALK_ACTIVITY_FACTOR := 0.60
const LOOK_BASE_SCORE := 0.15
const LOOK_CURIOSITY_FACTOR := 0.60


## 纯函数：选择下一个动作。
## snapshot: 只读状态快照；personality: 只读性格；
## environment: {can_walk, action_running, current_action, action_elapsed, cooldowns}
func choose_action(snapshot: Dictionary, personality: Dictionary, environment: Dictionary) -> StringName:
	var needs: Dictionary = snapshot.get("needs", {})
	var energy: float = float(needs.get("energy", 0.0))
	var current: StringName = StringName(str(snapshot.get("current_action", "idle")))
	var action_running := bool(environment.get("action_running", false))
	var elapsed: float = float(environment.get("action_elapsed", 0.0))
	var can_walk: bool = bool(environment.get("can_walk", true))
	var cooldowns: Dictionary = environment.get("cooldowns", {})

	# 休息锁定（架构 §5.2 第 1 条）：
	#   energy<30 立即休息；休息至少 20 秒；之后保持到 energy>=60
	if energy < REST_THRESHOLD:
		return PetState.ACTION_REST
	if current == PetState.ACTION_REST and elapsed < REST_MIN_SECONDS:
		return PetState.ACTION_REST
	if current == PetState.ACTION_REST and energy < REST_END_ENERGY:
		return PetState.ACTION_REST

	# 最短持续：仅在动作真正运行时才生效，避免每帧/过早重启
	if action_running and MIN_DURATIONS.has(current) and elapsed < float(MIN_DURATIONS[current]):
		return current

	# 候选评分（架构 §5.2 第 3 条）
	var scores: Array[Dictionary] = [
		{"id": PetState.ACTION_IDLE, "score": IDLE_SCORE, "prio": 0},
	]
	if can_walk:
		var walk_score: float = WALK_BASE_SCORE + WALK_ACTIVITY_FACTOR * float(personality.get("activity", 0.5))
		scores.append({"id": PetState.ACTION_WALK, "score": walk_score, "prio": 2})
	var look_score: float = LOOK_BASE_SCORE + LOOK_CURIOSITY_FACTOR * float(personality.get("curiosity", 0.5))
	scores.append({"id": PetState.ACTION_LOOK_AROUND, "score": look_score, "prio": 1})

	# 冷却中的候选排除；同分按 idle -> look_around -> walk 固定顺序（prio 越小越优先）
	var best: StringName = PetState.ACTION_IDLE
	var best_score := -INF
	var best_prio := 999
	for candidate: Dictionary in scores:
		var candidate_id: StringName = candidate["id"] as StringName
		var score: float = float(candidate["score"])
		if cooldowns.has(candidate_id) and float(cooldowns[candidate_id]) > 0.0:
			continue
		var prio: int = int(candidate["prio"])
		if score > best_score or (score == best_score and prio < best_prio):
			best = candidate_id
			best_score = score
			best_prio = prio
	return best


## 评估用户显式请求（架构 §5.2 第 2 条：单击 -> react_happy）。
## 返回 {accepted: bool, reason: String}
func evaluate_request(state: PetState, environment: Dictionary, requested: StringName) -> Dictionary:
	if requested != PetState.ACTION_REACT_HAPPY:
		return {"accepted": false, "reason": "当前仅接受 react_happy 用户请求"}
	if float(state.needs.get("energy", 0.0)) < REST_THRESHOLD:
		return {"accepted": false, "reason": "低精力锁定，用户互动不抢占休息"}
	if state.current_action == PetState.ACTION_REST:
		return {"accepted": false, "reason": "休息锁定中"}
	var cooldowns: Dictionary = environment.get("cooldowns", {})
	if cooldowns.has(requested) and float(cooldowns[requested]) > 0.0:
		return {"accepted": false, "reason": "互动冷却中，2 秒内不得重复成功"}
	return {"accepted": true, "reason": ""}
