extends Area3D
class_name PortalArea

@onready var portal_collision:CollisionShape3D = %CollisionShape3D

func _ready() -> void:
	monitoring = true
	monitorable = false
	collision_mask = 2

func set_area_size_and_position(shape_size:Vector3, z_offset:float):
	portal_collision.shape.size = shape_size
	position = Vector3(position.x, position.y, position.z + z_offset)

func connect_body_signals(on_entered: Callable, on_exited: Callable):
	body_entered.connect(on_entered)
	body_exited.connect(on_exited)
