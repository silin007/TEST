extends SceneTree

## 验证：叶子骨骼关闭自动计算并显式 set_length 后，
## (a) skeleton_2d.cpp:451 的 WARNING 是否消失
## (b) 动画驱动 rotation 是否仍然生效

const LENGTHS := {
	"Root": 56.0,
	"Root/Body": 34.0,
	"Root/Body/Head": 20.0,
	"Root/Body/ArmLeft": 26.0,
	"Root/Body/ArmRight": 26.0,
}

var _frames: int = 0
var _pet: Node = null
var _arm: Bone2D = null


func _initialize() -> void:
	var scene: PackedScene = load("res://scenes/pet/pet.tscn") as PackedScene
	_pet = scene.instantiate()
	root.add_child(_pet)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		var skel: Node = _pet.get_node("Skeleton2D")
		print("=== 修复前 autocalc/length ===")
		for name: String in LENGTHS:
			var b: Bone2D = skel.get_node(name) as Bone2D
			print("  %-9s autocalc=%s length=%.2f angle=%.3f" % [
				name, b.get_autocalculate_length_and_angle(), b.get_length(), b.get_bone_angle()
			])

		print("=== 应用修复 ===")
		for name: String in LENGTHS:
			var b2: Bone2D = skel.get_node(name) as Bone2D
			b2.set_autocalculate_length_and_angle(false)
			b2.set_length(float(LENGTHS[name]))
		# 触发一次 Skeleton2D 重算
		skel.propagate_notification(Skeleton2D.NOTIFICATION_TRANSFORM_CHANGED)
		for name2: String in LENGTHS:
			var b3: Bone2D = skel.get_node(name2) as Bone2D
			print("  %-9s length=%.2f angle=%.3f" % [name2, b3.get_length(), b3.get_bone_angle()])
		_arm = skel.get_node("Root/Body/ArmLeft") as Bone2D

	if _frames == 4:
		# 验证动画仍能驱动骨骼旋转
		var player: AnimationPlayer = _pet.get_node("AnimationPlayer") as AnimationPlayer
		print("=== 动画 ===")
		print("  animations=", player.get_animation_list())
		player.play("walk")
		print("  playing=", player.current_animation, " at=", player.current_animation_position)

	if _frames > 4 and _frames < 30:
		if _frames % 8 == 0:
			print("  frame %d: ArmLeft.rotation=%.4f" % [_frames, _arm.rotation])

	if _frames >= 32:
		print("=== 结论：ArmLeft 最终 rotation=%.4f（非 0 说明动画仍生效）===" % _arm.rotation)
		quit(0)
		return true
	return false
