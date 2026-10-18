extends SceneTree
## 独立验收补充：验证真实推进量与过期动作事件，而非仅比较结果相等。
## 不访问存档，不访问网络；可用 --headless --script 执行。

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	for fps: int in [15, 30, 60]:
		var state := PetState.new()
		var executor := ActionExecutor.new()
		var simulation := PetSimulation.new(state, UtilityAI.new(), executor)
		simulation.set_fixed_action(PetState.ACTION_IDLE)
		for frame: int in range(fps * 60):
			simulation.advance_time(1.0 / float(fps))
		var snapshot: Dictionary = simulation.get_snapshot()
		var elapsed: float = float(snapshot["simulation_elapsed_seconds"])
		var energy: float = float((snapshot["needs"] as Dictionary)["energy"])
		print("MEASURE SIM-02 fps=%d ticks=%d elapsed=%.6f energy=%.6f" % [fps, simulation.get_tick_count(), elapsed, energy])
		_check(absi(simulation.get_tick_count() - 600) <= 1, "SIM-02 %dFPS: 60s must advance 600 +/- 1 ticks" % fps)
		_check(absf(elapsed - 60.0) <= 0.101, "SIM-02 %dFPS: simulated elapsed must reach 60s" % fps)
		_check(absf(energy - 79.4) <= 0.002, "SIM-02 %dFPS: idle energy must reach 79.4" % fps)
	_test_stale_completion()
	print("AUDIT RESULT: checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _test_stale_completion() -> void:
	var state := PetState.new()
	state.needs["comfort"] = 50.0
	state.needs["social_need"] = 50.0
	var executor := ActionExecutor.new()
	var simulation := PetSimulation.new(state, UtilityAI.new(), executor)
	var request: Dictionary = simulation.request_action(PetState.ACTION_REACT_HAPPY)
	_check(bool(request["accepted"]), "PET-04: initial happy request accepted")
	var old_instance: int = int(request["instance_id"])
	executor.cancel_current_action("audit_cancel")
	var new_instances: Array[int] = []
	simulation.action_started.connect(func(_action: StringName, instance_id: int) -> void: new_instances.append(instance_id))
	simulation.set_fixed_action(PetState.ACTION_WALK)
	_check(simulation.get_current_action() == PetState.ACTION_WALK, "PET-04: replacement walk started")
	_check(not new_instances.is_empty() and new_instances[0] > old_instance, "PET-04: action instance IDs increase even within one tick")
	var before: Dictionary = simulation.get_snapshot()
	simulation.on_action_event({"action": PetState.ACTION_REACT_HAPPY, "instance_id": old_instance, "success": true, "reason": "late completion after cancel"})
	var after: Dictionary = simulation.get_snapshot()
	print("MEASURE PET-04 old_id=%d new_ids=%s before_action=%s after_action=%s comfort_before=%.3f comfort_after=%.3f" % [old_instance, str(new_instances), before["current_action"], after["current_action"], float((before["needs"] as Dictionary)["comfort"]), float((after["needs"] as Dictionary)["comfort"])])
	_check(after["current_action"] == before["current_action"], "PET-04: stale completion must not stop replacement action")
	_check(after["needs"] == before["needs"], "PET-04: cancelled old action must not earn a late reward")


func _check(condition: bool, label: String) -> void:
	_checks += 1
	print(("PASS " if condition else "FAIL ") + label)
	if not condition:
		_failures += 1
