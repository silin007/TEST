extends SceneTree
## 核心模拟单元测试（SIM-01 / SIM-02 / PET-03 / PET-04 的自动部分）。
## 运行：Godot --headless --path . --script res://tests/unit/test_simulation.gd

var _failures: int = 0


func _initialize() -> void:
	_test_sim01_idle_600_ticks()
	_test_sim01_rest()
	_test_sim02_fps_equivalence()
	_test_pet03_low_energy_rest()
	_test_pet03_high_activity_walk()
	_test_pet03_high_curiosity_look()
	_test_pet04_happy_reward_once()
	_test_pet04_happy_failure_no_reward()
	_test_gap_no_punishment()
	_test_wall_clock_rollback()
	if _failures == 0:
		print("ALL SIM/PET TESTS PASSED")
		quit(0)
	else:
		print("FAILURES: %d" % _failures)
		quit(1)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		print("  [FAIL] %s" % label)


func _close(a: float, b: float, epsilon: float = 0.001) -> bool:
	return absf(a - b) <= epsilon


func _make_sim(fixed_action: StringName = &"") -> Dictionary:
	var state := PetState.new()
	state.pet_id = "test-pet"
	var ai := UtilityAI.new()
	var exec := ActionExecutor.new()
	var sim := PetSimulation.new(state, ai, exec)
	if fixed_action != &"":
		sim.set_fixed_action(fixed_action)
	return {"sim": sim, "state": state}


## SIM-01：固定 idle，600 个 0.1s tick → 60 秒模拟时间
func _test_sim01_idle_600_ticks() -> void:
	print("SIM-01: 固定 idle 600 tick")
	var ctx: Dictionary = _make_sim(PetState.ACTION_IDLE)
	var sim: PetSimulation = ctx["sim"]
	var ticks := 0
	for i: int in range(600):
		ticks += sim.advance_time(0.1)
	var snap: Dictionary = sim.get_snapshot()
	var needs: Dictionary = snap["needs"]
	_check(sim.get_tick_count() == 600, "tick 数 == 600（实际 %d）" % sim.get_tick_count())
	_check(_close(float(snap["simulation_elapsed_seconds"]), 60.0), "模拟时间 60s（实际 %f）" % float(snap["simulation_elapsed_seconds"]))
	_check(_close(float(needs["energy"]), 79.4), "energy=79.4（实际 %f）" % float(needs["energy"]))
	_check(_close(float(needs["hunger"]), 20.3), "hunger=20.3（实际 %f）" % float(needs["hunger"]))
	_check(_close(float(needs["comfort"]), 79.88), "comfort=79.88（实际 %f）" % float(needs["comfort"]))
	_check(_close(float(needs["social_need"]), 20.3), "social_need=20.3（实际 %f）" % float(needs["social_need"]))


## SIM-01：固定 rest，600 tick
func _test_sim01_rest() -> void:
	print("SIM-01: 固定 rest 600 tick")
	var ctx: Dictionary = _make_sim(PetState.ACTION_REST)
	var sim: PetSimulation = ctx["sim"]
	for i: int in range(600):
		sim.advance_time(0.1)
	var snap: Dictionary = sim.get_snapshot()
	var needs: Dictionary = snap["needs"]
	_check(_close(float(needs["energy"]), 86.0), "rest energy=86（实际 %f）" % float(needs["energy"]))
	_check(_close(float(needs["hunger"]), 20.3), "rest hunger=20.3（实际 %f）" % float(needs["hunger"]))


## SIM-02：15/30/60 FPS 的 60 秒序列应得到几乎相同的需求
func _test_sim02_fps_equivalence() -> void:
	print("SIM-02: FPS 等价性")
	var results: Array[float] = []
	for fps: int in [15, 30, 60]:
		var dt: float = 1.0 / float(fps)
		var ctx: Dictionary = _make_sim(PetState.ACTION_IDLE)
		var sim: PetSimulation = ctx["sim"]
		var total: float = 0.0
		while total < 60.0:
			var step: float = minf(dt, 60.0 - total)
			sim.advance_time(step)
			total += step
		results.append(float(sim.get_snapshot()["needs"]["energy"]))
	_check(_close(results[0], results[1], 0.002), "15FPS vs 30FPS energy 接近（%f vs %f）" % [results[0], results[1]])
	_check(_close(results[1], results[2], 0.002), "30FPS vs 60FPS energy 接近（%f vs %f）" % [results[1], results[2]])


## PET-03①：energy=20 运行 30 秒，应开始 rest 且 energy 恢复
func _test_pet03_low_energy_rest() -> void:
	print("PET-03①: 低精力进入休息")
	var state := PetState.new()
	state.needs["energy"] = 20.0
	var ai := UtilityAI.new()
	var exec := ActionExecutor.new()
	var sim := PetSimulation.new(state, ai, exec)
	# 前 1 秒决策点应选择 rest
	var saw_rest_action := [false]
	sim.action_started.connect(func(action: StringName, _id: int) -> void:
		if action == PetState.ACTION_REST:
			saw_rest_action[0] = true
	)
	for i: int in range(300):
		sim.advance_time(0.1)
	var snap: Dictionary = sim.get_snapshot()
	_check(saw_rest_action[0], "低精力时开始 rest")
	# 30 秒后 energy 应 >20（rest +0.1/s 恢复）
	_check(float(snap["needs"]["energy"]) > 20.0, "rest 后 energy 恢复（实际 %f）" % float(snap["needs"]["energy"]))


## PET-03②：energy=80 activity=1 curiosity=0 → 首个决策选 walk
func _test_pet03_high_activity_walk() -> void:
	print("PET-03②: activity=1 → walk")
	var state := PetState.new()
	state.needs["energy"] = 80.0
	state.personality["activity"] = 1.0
	state.personality["curiosity"] = 0.0
	var ai := UtilityAI.new()
	var exec := ActionExecutor.new()
	var sim := PetSimulation.new(state, ai, exec)
	var first: Array[StringName] = [&""]
	sim.action_started.connect(func(action: StringName, _id: int) -> void:
		if first[0] == &"":
			first[0] = action
	)
	for i: int in range(15):
		sim.advance_time(0.1)
	_check(first[0] == PetState.ACTION_WALK, "首个决策选 walk（实际 %s）" % first[0])


## PET-03②：walk 满 6 秒后进入冷却，不会每帧重启
func _test_pet03_walk_cooldown_after_6s() -> void:
	print("PET-03②: walk 6 秒后冷却")
	var state := PetState.new()
	state.needs["energy"] = 80.0
	state.personality["activity"] = 1.0
	state.personality["curiosity"] = 0.0
	var ai := UtilityAI.new()
	var exec := ActionExecutor.new()
	var sim := PetSimulation.new(state, ai, exec)
	# 60 秒：首个决策 walk，6 秒后进入冷却，随后应回 idle 而非每帧重启 walk
	var walk_starts := [0]
	sim.action_started.connect(func(action: StringName, _id: int) -> void:
		if action == PetState.ACTION_WALK:
			walk_starts[0] += 1
	)
	for i: int in range(600):
		sim.advance_time(0.1)
	_check(walk_starts[0] == 1, "walk 只启动一次（实际 %d）" % walk_starts[0])


## PET-03③：energy=80 activity=0 curiosity=1 → 首个决策选 look_around
func _test_pet03_high_curiosity_look() -> void:
	print("PET-03③: curiosity=1 → look_around")
	var state := PetState.new()
	state.needs["energy"] = 80.0
	state.personality["activity"] = 0.0
	state.personality["curiosity"] = 1.0
	var ai := UtilityAI.new()
	var exec := ActionExecutor.new()
	var sim := PetSimulation.new(state, ai, exec)
	var first: Array[StringName] = [&""]
	sim.action_started.connect(func(action: StringName, _id: int) -> void:
		if first[0] == &"":
			first[0] = action
	)
	for i: int in range(15):
		sim.advance_time(0.1)
	_check(first[0] == PetState.ACTION_LOOK_AROUND, "首个决策选 look_around（实际 %s）" % first[0])


## PET-04①: 正常点击一次 → comfort+2 social_need-5 只一次
func _test_pet04_happy_reward_once() -> void:
	print("PET-04: happy 奖励只一次")
	var state := PetState.new()
	state.needs["energy"] = 80.0
	state.needs["comfort"] = 50.0
	state.needs["social_need"] = 50.0
	var ai := UtilityAI.new()
	var exec := ActionExecutor.new()
	var sim := PetSimulation.new(state, ai, exec)
	var result: Dictionary = sim.request_action(PetState.ACTION_REACT_HAPPY)
	_check(bool(result["accepted"]), "happy 请求被接受")
	var instance_id := int(result["instance_id"])
	# 让 happy 跑完 2 秒
	for i: int in range(20):
		sim.advance_time(0.1)
	var snap: Dictionary = sim.get_snapshot()
	var needs: Dictionary = snap["needs"]
	# 架构 §5.2：一次成功 happy 应用 comfort+2、social_need-5；
	# 但 2 秒运行期间另有真实 tick 变化（comfort -0.002/s、social +0.005/s）
	_check(_close(float(needs["comfort"]), 51.996), "comfort=51.996（实际 %f）" % float(needs["comfort"]))
	_check(_close(float(needs["social_need"]), 45.01), "social_need=45.01（实际 %f）" % float(needs["social_need"]))
	# 重复事件不应重复奖励
	sim.on_action_event({"action": PetState.ACTION_REACT_HAPPY, "instance_id": instance_id, "success": true, "reason": "dup"})
	var snap2: Dictionary = sim.get_snapshot()
	_check(_close(float(snap2["needs"]["comfort"]), 51.996), "重复事件不重复奖励（comfort=%f）" % float(snap2["needs"]["comfort"]))


## PET-04③: happy 启动失败 → 无奖励
func _test_pet04_happy_failure_no_reward() -> void:
	print("PET-04: happy 失败无奖励")
	var state := PetState.new()
	state.needs["energy"] = 80.0
	state.needs["comfort"] = 50.0
	state.needs["social_need"] = 50.0
	var ai := UtilityAI.new()
	var exec := ActionExecutor.new()
	var sim := PetSimulation.new(state, ai, exec)
	# 模拟动画缺失：先请求，然后立刻以失败事件结束
	var result: Dictionary = sim.request_action(PetState.ACTION_REACT_HAPPY)
	sim.on_action_event({"action": PetState.ACTION_REACT_HAPPY, "instance_id": int(result["instance_id"]), "success": false, "reason": "missing animation"})
	var snap: Dictionary = sim.get_snapshot()
	_check(_close(float(snap["needs"]["comfort"]), 50.0), "失败无 comfort 奖励（%f）" % float(snap["needs"]["comfort"]))
	_check(_close(float(snap["needs"]["social_need"]), 50.0), "失败无 social 奖励（%f）" % float(snap["needs"]["social_need"]))


## SIM-03: 时间断点（>5s）不补算、无惩罚
func _test_gap_no_punishment() -> void:
	print("SIM-03: 时间断点无惩罚")
	var ctx: Dictionary = _make_sim(PetState.ACTION_IDLE)
	var sim: PetSimulation = ctx["sim"]
	sim.advance_time(0.1)
	var before: Dictionary = sim.get_snapshot()
	var gap_logged := [false]
	sim.time_gap_detected.connect(func(_gap: float) -> void:
		gap_logged[0] = true
	)
	sim.advance_time(6.0)  # 6 秒断点
	var after: Dictionary = sim.get_snapshot()
	_check(gap_logged[0], "time_gap 被记录")
	_check(_close(float(before["needs"]["energy"]), float(after["needs"]["energy"]), 0.001), "断点不扣需求")


## SIM-04: 墙钟回拨（模拟注入）不产生负 tick / 惩罚
func _test_wall_clock_rollback() -> void:
	print("SIM-04: 墙钟回拨无惩罚")
	var ctx: Dictionary = _make_sim(PetState.ACTION_IDLE)
	var sim: PetSimulation = ctx["sim"]
	for i: int in range(100):
		sim.advance_time(0.1)
	var before_ticks := sim.get_tick_count()
	# 注入一个 24h 墙钟回拨 → 用大 dt 模拟（>5s 断点，不补算）
	sim.advance_time(86400.0)
	_check(sim.get_tick_count() == before_ticks, "回拨后 tick 不异常增加（%d == %d）" % [sim.get_tick_count(), before_ticks])
