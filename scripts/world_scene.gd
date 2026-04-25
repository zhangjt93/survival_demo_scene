extends Node3D


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	change_mouse_mode() # Replace with function body.
	
func change_mouse_mode():
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("quit"):
		change_mouse_mode()
