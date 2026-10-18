extends SceneTree
## 探针：真实渲染截图，用于人工核对 FULL 面板布局（复验 §5 的裁切质疑）。
## 运行：Godot.exe --path . --script res://tests/probe/probe_screenshot.gd
## 输出：user://shots/full_panel.png、floating.png

var _frames: int = 0
var _main: Node = null
var _app: AppController = null


func _initialize() -> void:
	SaveService.use_sandbox("user://test_sandbox/probe_shot")
	var scene: PackedScene = load("res://scenes/app/main.tscn") as PackedScene
	_main = scene.instantiate()
	root.add_child(_main)
	DirAccess.make_dir_recursive_absolute("user://shots")


func _process(_d: float) -> bool:
	_frames += 1
	_app = _main as AppController
	if _frames == 4:
		_app.switch_mode(AppMode.FULL)
		return false
	if _frames == 10:
		_save_png("full_panel")
		_app.switch_mode(AppMode.FLOATING)
		return false
	if _frames == 16:
		_save_png("floating")
		print("shots at ", ProjectSettings.globalize_path("user://shots/"))
		quit(0)
		return true
	return false


func _save_png(name: String) -> void:
	var img: Image = root.get_texture().get_image()
	if img == null:
		print("FAIL 无法取到帧图像（", name, "）")
		return
	var path := "user://shots/%s.png" % name
	var err: Error = img.save_png(path)
	print("saved %s (%dx%d) err=%d" % [path, img.get_width(), img.get_height(), err])
