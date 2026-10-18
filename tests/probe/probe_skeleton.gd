extends SceneTree
## 探针：定位 Skeleton2D 的 det==0 来源，并验证显式设置 rest 后可消除。


func _initialize() -> void:
	var root_node := Node2D.new()
	root.add_child(root_node)

	var sk_a := Skeleton2D.new()
	root_node.add_child(sk_a)
	var b1 := Bone2D.new()
	b1.name = "Root"
	b1.position = Vector2(100, 200)
	b1.rest = Transform2D(0.0, Vector2(100.0, 200.0))
	sk_a.add_child(b1)
	var b2 := Bone2D.new()
	b2.name = "Body"
	b2.position = Vector2(0, -50)
	b2.rest = Transform2D(0.0, Vector2(0.0, -50.0))
	b1.add_child(b2)

	print("--- 显式 rest 场景构建完成 ---")
	print("b1.rest det=", b1.rest.determinant(), " b2.rest det=", b2.rest.determinant())
	quit(0)
