extends SceneTree
## 探针：FULL 面板布局实测（复验报告 §5 指出的右侧按钮裁切）。
## 测量 viewport / FullPanel / 按钮行的实际矩形，判断是"容器不够宽"还是"锚点没撑开"。
## 运行：Godot.exe --headless --path . --script res://tests/probe/probe_layout.gd
## （Control 布局是纯矩形计算，headless 下数值有效。）

var _frames: int = 0
var _main: Node = null
var _switched: bool = false


func _initialize() -> void:
	SaveService.use_sandbox("user://test_sandbox/probe_layout")
	var scene: PackedScene = load("res://scenes/app/main.tscn") as PackedScene
	_main = scene.instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1

	# 先切模式，再多等几帧让容器完成重排，否则测到的是重排前的最小尺寸
	if not _switched:
		if _frames < 4:
			return false
		var app: AppController = _main as AppController
		app.switch_mode(AppMode.FULL)
		_switched = true
		return false
	if _frames < 8:
		return false

	var app2: AppController = _main as AppController
	print("=== viewport ===")
	print("root.size=", root.size, "  content_scale=", root.content_scale_size, "  mode=", app2.get_mode())

	var panel: Control = _main.get_node("FullPanel") as Control
	if panel == null:
		print("FAIL 未取得 FullPanel")
		quit(1)
		return true

	# 进入 FULL 以触发真实布局
	print("=== FullPanel ===")
	print("size=", panel.size, " position=", panel.position, " visible=", panel.visible)

	print("=== 容器层级 ===")
	_dump(panel, 0)

	print("=== 所有 Button 的实际矩形 ===")
	for node: Node in _walk(panel):
		if node is Button:
			var b: Button = node as Button
			print("  [%s] pos=%s size=%s 右边界=%.0f" % [b.text, b.position, b.size, b.position.x + b.size.x])

	print("=== 是否越界（右边界 > viewport 宽）===")
	var vw: float = float(root.size.x)
	for node: Node in _walk(panel):
		if node is Button:
			var b: Button = node as Button
			var right: float = b.global_position.x + b.size.x
			print("  [%s] global_right=%.0f  viewport_w=%.0f  越界=%s" % [b.text, right, vw, right > vw])

	quit(0)
	return true


func _walk(n: Node) -> Array[Node]:
	var out: Array[Node] = []
	for c: Node in n.get_children():
		out.append(c)
		out.append_array(_walk(c))
	return out


func _dump(n: Node, depth: int) -> void:
	var pad: String = "  ".repeat(depth)
	if n is Control:
		var c: Control = n as Control
		print("%s%s(%s) size=%s min=%s" % [pad, n.name, n.get_class(), c.size, c.get_combined_minimum_size()])
	else:
		print("%s%s(%s)" % [pad, n.name, n.get_class()])
	if depth > 3:
		return
	for child: Node in n.get_children():
		_dump(child, depth + 1)
