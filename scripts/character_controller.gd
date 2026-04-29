extends CharacterBody3D
class_name CharacterController

const SPEED = 5.0
const JUMP_VELOCITY = 4.5
const ACCELERATION = 15.0
const FRICTION = 15.0
const CAMERA_SMOOTH_SPEED = 10.0
const CAMERA_Y_OFFSET = 1.232

@export var camera_mouse_rotation_speed:float = 0.001
@export var camera_x_rot_min:float = -89.9
@export var camera_x_rot_max:float = 70

@onready var camera:Camera3D = get_viewport().get_camera_3d()

func _ready() -> void:
	pass

func _process(delta: float) -> void:
	camera.position.y = lerp(camera.position.y, CAMERA_Y_OFFSET, 1.0 - exp(-CAMERA_SMOOTH_SPEED * delta))

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity += get_gravity() * delta

	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction:
		velocity.x = move_toward(velocity.x, direction.x * SPEED, ACCELERATION * delta)
		velocity.z = move_toward(velocity.z, direction.z * SPEED, ACCELERATION * delta)
	else:
		velocity.x = move_toward(velocity.x, 0, FRICTION * delta)
		velocity.z = move_toward(velocity.z, 0, FRICTION * delta)

	move_and_slide()

func _unhandled_input(event: InputEvent) -> void:
	var scale_factor:float = min(
		(float(get_viewport().size.x) / get_viewport().get_visible_rect().size.x),
		(float(get_viewport().size.y) / get_viewport().get_visible_rect().size.y)
	)
	if event is InputEventMouseMotion:
		var camera_rotation = event.relative * camera_mouse_rotation_speed * scale_factor
		rotate_node(-camera_rotation)

func rotate_node(move:Vector2):
	rotate_y(move.x)
	#暂时改一下，这里直接转父节点
	#rotate_y(move.x)
	orthonormalize()
	camera.rotation.x = clamp(camera.rotation.x + move.y,deg_to_rad(camera_x_rot_min),deg_to_rad(camera_x_rot_max))
