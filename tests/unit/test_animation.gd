extends SceneTree
## PET-01/PET-02 自动部分：骨骼测试角色存在真实 Skeleton2D/Bone2D 运动，
## 且 AnimationController 的行为→动画映射与播放结果可判定。
## 运行：Godot --headless --path . --script res://tests/unit/test_animation.gd
##
## 注意：节点 _ready() 在 SceneTree 首帧才触发，因此断言在 _process 首帧执行。

var _failures: Array[String] = []
var _ran: bool = false
var _pet: Node


func _initialize() -> void:
	var scene: PackedScene = load("res://scenes/pet/pet.tscn") as PackedScene
	if scene == null:
		print("FAIL PET-01 加载 pet.tscn")
		quit(1)
		return
	_pet = scene.instantiate()
	root.add_child(_pet)


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_run_all()
	if _failures.is_empty():
		print("ALL ANIMATION TESTS PASSED")
		quit(0)
	else:
		print("FAILURES:")
		for f: String in _failures:
			print("  - ", f)
		quit(1)
	return false


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS ", label)
	else:
		print("FAIL ", label)
		_failures.append(label)


func _run_all() -> void:
	var pet := _pet
	_check(pet != null, "PET-01 实例化 pet.tscn")
	if pet == null:
		return

	# —— 结构：必须使用真实骨骼层级 ——
	var skeleton: Skeleton2D = pet.get_node_or_null("Skeleton2D") as Skeleton2D
	_check(skeleton != null, "PET-01 存在 Skeleton2D")
	var bone_body: Bone2D = pet.get_node_or_null("Skeleton2D/Root/Body") as Bone2D
	var bone_head: Bone2D = pet.get_node_or_null("Skeleton2D/Root/Body/Head") as Bone2D
	var bone_arm_l: Bone2D = pet.get_node_or_null("Skeleton2D/Root/Body/ArmLeft") as Bone2D
	var bone_arm_r: Bone2D = pet.get_node_or_null("Skeleton2D/Root/Body/ArmRight") as Bone2D
	_check(bone_body != null and bone_head != null, "PET-01 存在 Bone2D 层级 Root/Body/Head")
	_check(bone_arm_l != null and bone_arm_r != null, "PET-01 存在左右手臂骨骼")

	var player: AnimationPlayer = pet.get_node_or_null("AnimationPlayer") as AnimationPlayer
	_check(player != null, "PET-01 存在 AnimationPlayer")

	var controller := pet as AnimationController
	_check(controller != null, "PET-02 根节点为 AnimationController")
	if player == null or controller == null:
		return

	# —— 四种动画均已构建 ——
	for anim_name: String in ["idle", "walk", "rest", "happy"]:
		_check(player.has_animation(StringName(anim_name)), "PET-01 动画存在: %s" % anim_name)

	# —— 映射与播放结果 ——
	var mapping: Dictionary = {
		PetState.ACTION_IDLE: "idle",
		PetState.ACTION_WALK: "walk",
		PetState.ACTION_REST: "rest",
		PetState.ACTION_LOOK_AROUND: "idle",
		PetState.ACTION_REACT_HAPPY: "happy",
	}
	for action: StringName in mapping:
		var expected: String = mapping[action] as String
		var ok: bool = controller.play_action(action)
		_check(ok and String(controller.get_current_anim()) == expected,
			"PET-02 映射 %s -> %s" % [action, expected])

	# 未知行为回退 idle
	_check(controller.play_action(&"not_an_action"), "PET-02 未知行为回退 idle 且返回 true")

	# —— 真实骨骼运动：不同动画下骨骼旋转必须不同 ——
	var samples := {}
	for anim_name: String in ["idle", "walk", "rest", "happy"]:
		player.play(StringName(anim_name))
		player.seek(0.4, true)
		var body_rot: float = bone_body.rotation
		var arm_rot: float = bone_arm_l.rotation
		samples[anim_name] = [body_rot, arm_rot]
		print("  sample %s: body=%.4f arm=%.4f" % [anim_name, body_rot, arm_rot])

	var idle_body: float = (samples["idle"] as Array)[0]
	var rest_body: float = (samples["rest"] as Array)[0]
	var walk_arm: float = (samples["walk"] as Array)[1]
	var idle_arm: float = (samples["idle"] as Array)[1]
	_check(absf(rest_body - idle_body) > 0.01, "PET-01 rest 与 idle 的 Body 旋转不同")
	_check(absf(walk_arm - idle_arm) > 0.01, "PET-01 walk 与 idle 的 ArmLeft 旋转不同")
	_check(absf(rest_body) > 0.01, "PET-01 rest 存在非零骨骼旋转")
	_check(absf(walk_arm) > 0.01, "PET-01 walk 存在非零骨骼旋转")

	# —— 动画时长与循环模式 ——
	var happy: Animation = player.get_animation(&"happy")
	var idle: Animation = player.get_animation(&"idle")
	_check(happy != null and happy.loop_mode == Animation.LOOP_NONE, "PET-02 happy 为单次播放")
	_check(idle != null and idle.loop_mode != Animation.LOOP_NONE, "PET-02 idle 为循环播放")

	# —— 朝向 ——
	controller.set_facing(-1)
	_check(controller.get_facing() == -1 and skeleton.scale.x < 0.0, "PET-02 set_facing(-1) 翻转")
	controller.set_facing(1)
	_check(controller.get_facing() == 1 and skeleton.scale.x > 0.0, "PET-02 set_facing(1) 复位")

	# —— 失败路径：无 AnimationPlayer 时 play_action 返回 false ——
	var bare := AnimationController.new()
	_check(not bare.play_action(PetState.ACTION_WALK), "PET-02 缺少播放资源时返回 false")
	bare.free()
