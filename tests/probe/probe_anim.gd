extends SceneTree
## 环境探针：确认 Godot 版本的动画轨道常量与 2D 旋转轨道写法（ENV-01 证据）。


func _initialize() -> void:
	print("version=", Engine.get_version_info())
	var anim := Animation.new()
	print("has TYPE_ROTATION: ", "TYPE_ROTATION" in Animation)
	print("has TYPE_ROTATION_3D: ", "TYPE_ROTATION_3D" in Animation)
	print("has TYPE_VALUE: ", "TYPE_VALUE" in Animation)
	var t: int = anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(t, NodePath("Skeleton2D/Root/Body:rotation"))
	anim.track_insert_key(t, 0.0, 0.05)
	print("value_track_ok keys=", anim.track_get_key_count(t))
	var t2: int = anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(t2, NodePath("Node3D"))
	anim.track_insert_key(t2, 0.0, Quaternion.from_euler(Vector3(0, 0, 0.05)))
	print("rot3d_track_ok keys=", anim.track_get_key_count(t2))
	print("display_server=", DisplayServer.get_name())
	quit(0)
