extends Node3D
class_name Portal

const EXIT_CAMERA_NEAR_MIN: float = 0.01

@export var target_portal:Portal
## 传送门渲染的视觉层。设置为与关卡和模型不同的层。
## 用于在相机视图中隐藏目标传送门，这样就能透过传送门看到另一侧。
@export_flags_3d_render var cull_layer : int = 4
## 近裁面偏移量，从四个角投影距离的最小值中减去此值，提供安全边际防止边缘裁切。
@export var exit_near_subtract: float = 0.05
## 传送门碰撞体的边距（前后/左右/上下）
@export var portal_x_margin : = 0.1
@export var portal_y_margin : = 0.1
@export var portal_z_margin : = 1.0

#初始化引用节点
@onready var virtual_camera:Camera3D =  %VirtualCamera
@onready var virtual_viewport:SubViewport = %SubViewport
@onready var portal_visual:CSGBox3D = %CSGBox3D
@onready var front_area:PortalArea = %FrontArea
@onready var rear_area:PortalArea = %RearArea

# 如果物体在穿过传送门时移动超过此距离，则认为是传送（而非行走穿过）
# 用于防止通过其他能力传送时误触传送门移动
const MOVE_WAS_TELEPORT_THRESHOLD = 5.0

# 处理边界情况：防止物体刚好落在传送门平面时传送两次
func _nonzero_sign(value):
	var s = sign(value)
	if s == 0:
		s = 1
	return s

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	# - 关闭层1（让传送门在主相机中不可见）
	portal_visual.set_layer_mask_value(1, false)
	# - 开启cull_layer层（用于渲染传送门视觉效果）
	portal_visual.set_layer_mask_value(cull_layer, true)
	
	# 设置传送门相机的剔除掩码，关闭目标传送门所在层
	# 这样相机就看不到目标传送门，可以渲染另一侧的画面
	virtual_camera.set_cull_mask_value(target_portal.cull_layer, false)
	# 初始化检测区域大小
	_update_portal_area_size()
	# 设置传送门相机环境
	_set_portal_camera_env()
	
# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	_update_virtual_camera()
	
#region 显示画面
# 设置传送门相机环境：复制世界环境但禁用色调映射
func _set_portal_camera_env():
	var world_3d = get_viewport().world_3d
	if not world_3d or not world_3d.environment or not virtual_camera:
		return
	# 必须禁用色调映射/设为线性模式，避免在主相机渲染时重复应用
	virtual_camera.environment = world_3d.environment.duplicate()
	virtual_camera.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		
# 更新传送门相机的近裁剪平面
# 由于Godot不支持自定义投影矩阵（set_override_projection仅在部分定制化分支可用），
# 改用四角点投影法计算近裁面距离：
# 将出口传送门四边形的四个角投影到虚拟相机forward方向，
# 取最小投影距离作为near值，确保整个传送门画面不被裁切。
# TODO: 但需要明确注意，这个方案，还有可能会裁剪到不需要的画面，标准姿势还是自定义投影矩阵
func _update_camera_near(camera: Camera3D):
	var portal_size = target_portal.portal_visual.size
	var half_w = portal_size.x / 2.0
	var half_h = portal_size.y / 2.0

	var corners_local = [
		target_portal.global_transform * Vector3(-half_w, -half_h, 0),
		target_portal.global_transform * Vector3( half_w, -half_h, 0),
		target_portal.global_transform * Vector3( half_w,  half_h, 0),
		target_portal.global_transform * Vector3(-half_w,  half_h, 0),
	]

	var cam_forward = -camera.global_transform.basis.z.normalized()
	var cam_pos = camera.global_position

	var min_dist = INF
	for corner in corners_local:
		var dist = (corner - cam_pos).dot(cam_forward)
		if dist < min_dist:
			min_dist = dist

	camera.near = max(EXIT_CAMERA_NEAR_MIN, min_dist - exit_near_subtract)

# 更新传送门相机位置，使其显示目标传送门视角的内容
func _update_virtual_camera():
	var cur_camera = get_viewport().get_camera_3d()
	if not cur_camera:
		return
		
	# 首先，计算相机相对于当前传送门的位置/旋转
	var cur_camera_transform_rel_to_this_portal = self.global_transform.affine_inverse() * cur_camera.global_transform
	# 然后，将这个相对变换应用到目标传送门，得到传送门相机应有的位置
	var moved_to_other_portal = target_portal.global_transform * cur_camera_transform_rel_to_this_portal
	
	# 设置传送门相机的变换
	virtual_camera.global_transform = moved_to_other_portal
	virtual_camera.fov = cur_camera.fov
	
	# 复制相机的剔除掩码，但隐藏目标传送门层
	virtual_camera.cull_mask = cur_camera.cull_mask
	virtual_camera.set_cull_mask_value(target_portal.cull_layer, false)
	
	# 复制主视口的渲染设置（抗锯齿、TAA等）
	virtual_viewport.size = get_viewport().get_visible_rect().size
	virtual_viewport.msaa_3d = get_viewport().msaa_3d
	virtual_viewport.screen_space_aa = get_viewport().screen_space_aa
	virtual_viewport.use_taa = get_viewport().use_taa
	virtual_viewport.use_debanding = get_viewport().use_debanding
	virtual_viewport.use_occlusion_culling = get_viewport().use_occlusion_culling
	virtual_viewport.mesh_lod_threshold = get_viewport().mesh_lod_threshold
	
	# 更新近裁剪平面处理
	_update_camera_near(virtual_camera)
#endregion

#region 物理检测
# 更新传送门碰撞体
func _update_portal_area_size():
	# 碰撞体比视觉元素稍大（加上边距），确保能检测到靠近的物体
	var shape_size = Vector3(
		portal_visual.size.x + self.portal_x_margin * 2,
		portal_visual.size.y + self.portal_y_margin * 2,
		self.portal_z_margin)
	var z_offset = self.portal_z_margin/2
	front_area.set_area_size_and_position(shape_size,-z_offset)
	rear_area.set_area_size_and_position(shape_size,z_offset)
#endregion

#region 传送

#endregion
