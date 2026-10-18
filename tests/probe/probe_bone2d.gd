extends SceneTree

var _ran := false

func _process(_d: float) -> bool:
	if _ran: return true
	_ran = true
	var b: Node = Bone2D.new()
	var base: Node = Node2D.new()
	var base_props := {}
	for p: Dictionary in base.get_property_list():
		base_props[str(p["name"])] = true
	print("=== Bone2D 自有属性（Node2D 没有的）===")
	for p: Dictionary in b.get_property_list():
		var n := str(p["name"])
		if not base_props.has(n):
			print("  ", n, "  (type ", p["type"], ")")
	print("=== 含 length/angle/rest 的方法 ===")
	for m: Dictionary in b.get_method_list():
		var n := str(m["name"])
		if n.contains("length") or n.contains("angle") or n.contains("rest"):
			print("  ", n)
	base.free()
	b.free()
	quit(0)
	return false
