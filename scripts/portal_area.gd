extends Area3D
class_name PortalArea

@onready var portal_collision:CollisionShape3D = %CollisionShape3D
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass

func set_area_size_and_position(shape_size:Vector3,z_offset:float):
	portal_collision.shape.size = shape_size
	position = Vector3(position.x,position.y,position.z+z_offset)
	print(shape_size,z_offset)
