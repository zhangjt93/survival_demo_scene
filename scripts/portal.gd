extends Node3D
class_name Portal

## 虚拟相机近裁面允许的最小值，防止设为 0 导致渲染异常
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

# 初始化引用节点
@onready var virtual_camera:Camera3D =  %VirtualCamera
@onready var virtual_viewport:SubViewport = %SubViewport
@onready var portal_visual:CSGBox3D = %CSGBox3D
@onready var front_area:PortalArea = %FrontArea
@onready var rear_area:PortalArea = %RearArea

# 本传送门专属的 Ghost 渲染层编号（Layer 5, 6, ...），
# 由 _all_ghost_layers 静态计数器在 _ready 时自动分配。
# Ghost 节点只设此层，主摄像机关闭此层，仅 VirtualCamera 开启此层，
# 从而确保 Ghost 只在传送门画面中可见，不会被主摄像机直接看到。
var _my_ghost_layer: int

# 如果物体在穿过传送门时移动超过此距离，则认为是传送（而非行走穿过）
# 用于防止通过其他能力传送时误触传送门移动
const MOVE_WAS_TELEPORT_THRESHOLD = 5.0
# 传送后目标传送门的冷却帧数，防止因信号时序问题导致的同帧重复传送
const TELEPORT_COOLDOWN_FRAMES := 2
# 当角色进入传送门区域时，将主相机近裁面缩小到此值（0.001），
# 防止近裁面裁剪掉传送门视觉面（CSGBox3D），暴露传送门背后的环境。
# 这是消除传送瞬间视觉抖动的核心手段。
const CAM_NEAR_FIX := 0.001
# 全局 Ghost 层注册表，每个 Portal 实例在 _ready 中注册自己的层号。
# 用于在 _update_virtual_camera 中批量关闭主摄像机上的所有 Ghost 层。
static var _all_ghost_layers: Array = []

# 处理边界情况：防止物体刚好落在传送门平面时传送两次。
# sign(0) 返回 0 会导致穿越检测误判，这里强制返回 1 或 -1。
func _nonzero_sign(value):
	var s = sign(value)
	if s == 0:
		s = 1
	return s

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	# 分配本传送门专属的 Ghost 渲染层（第一个 Portal 得到 Layer 5，第二个 Layer 6，以此类推）
	_my_ghost_layer = 5 + _all_ghost_layers.size()
	_all_ghost_layers.append(_my_ghost_layer)
	# - 关闭层1（让传送门在主相机中不可见）
	portal_visual.set_layer_mask_value(1, false)
	# - 开启cull_layer层（用于渲染传送门视觉效果）
	portal_visual.set_layer_mask_value(cull_layer, true)
	
	# 设置传送门相机的剔除掩码，关闭目标传送门所在层
	# 这样相机就看不到目标传送门，可以渲染另一侧的画面
	virtual_camera.set_cull_mask_value(target_portal.cull_layer, false)
	_update_portal_area_size()
	_set_portal_camera_env()
	_connect_area_signals()
	
# 渲染帧回调：更新虚拟相机位置 + 同步所有 Ghost 节点变换
func _process(delta: float) -> void:
	_update_virtual_camera()
	_update_ghosts()

# 物理帧回调：更新虚拟相机位置 + 检测传送门平面穿越并执行传送。
# 虚拟相机在物理帧也更新，可以减少物理帧与渲染帧之间的延迟，
# 确保传送后 VirtualCamera 在同一帧内完成重定位。
func _physics_process(_delta: float) -> void:
	_update_virtual_camera()
	_check_teleportations()
	
#region 显示画面
# 设置传送门相机环境：复制世界环境但禁用色调映射
func _set_portal_camera_env():
	var world_3d = get_viewport().world_3d
	if not world_3d or not world_3d.environment or not virtual_camera:
		return
	# 必须禁用色调映射/设为线性模式，避免在主相机渲染时重复应用
	virtual_camera.environment = world_3d.environment.duplicate()
	virtual_camera.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		
# 更新传送门相机的近裁剪平面。
# 原理：将目标传送门四边形的四个角投影到虚拟相机 forward 方向，
# 取最小投影距离作为 near 值，确保整个传送门画面不被裁切。
# 局限：可能会裁剪到不需要的画面，理想方案是自定义投影矩阵（倾斜近裁面）。
func _update_camera_near(camera: Camera3D):
	var portal_size = target_portal.portal_visual.size
	var half_w = portal_size.x / 2.0
	var half_h = portal_size.y / 2.0
	# 计算目标传送门四个角在世界坐标中的位置
	var corners_local = [
		target_portal.global_transform * Vector3(-half_w, -half_h, 0),
		target_portal.global_transform * Vector3( half_w, -half_h, 0),
		target_portal.global_transform * Vector3( half_w,  half_h, 0),
		target_portal.global_transform * Vector3(-half_w,  half_h, 0),
	]
	# 将四个角投影到相机前方向，取最小距离作为近裁面
	var cam_forward = -camera.global_transform.basis.z.normalized()
	var cam_pos = camera.global_position
	var min_dist = INF
	for corner in corners_local:
		var dist = (corner - cam_pos).dot(cam_forward)
		if dist < min_dist:
			min_dist = dist
	camera.near = max(EXIT_CAMERA_NEAR_MIN, min_dist - exit_near_subtract)

# 更新传送门相机位置，使其显示目标传送门视角的内容。
# 核心变换公式（与传送物体使用相同的仿射变换数学）：
#   VirtualCamera 变换 = 目标传送门全局变换 × (当前传送门全局变换的逆 × 主相机全局变换)
func _update_virtual_camera():
	var cur_camera = get_viewport().get_camera_3d()
	if not cur_camera:
		return
	
	# 关闭主摄像机上所有已注册的 Ghost 层，防止 Ghost 被主摄像机直接渲染
	for layer in _all_ghost_layers:
		cur_camera.set_cull_mask_value(layer, false)
		
	# 首先，计算相机相对于当前传送门的位置/旋转
	var cur_camera_transform_rel_to_this_portal = self.global_transform.affine_inverse() * cur_camera.global_transform
	# 然后，将这个相对变换应用到目标传送门，得到传送门相机应有的位置
	var moved_to_other_portal = target_portal.global_transform * cur_camera_transform_rel_to_this_portal
	
	# 设置传送门相机的变换
	virtual_camera.global_transform = moved_to_other_portal
	virtual_camera.fov = cur_camera.fov
	
	# 复制相机的剔除掩码，隐藏目标传送门层 + 开启本传送门的 Ghost 层
	virtual_camera.cull_mask = cur_camera.cull_mask
	virtual_camera.set_cull_mask_value(target_portal.cull_layer, false)
	virtual_camera.set_cull_mask_value(_my_ghost_layer, true)
	
	# 同步主视口的渲染设置（抗锯齿、TAA等），保证传送门画面与主画面一致
	virtual_viewport.size = get_viewport().get_visible_rect().size
	virtual_viewport.msaa_3d = get_viewport().msaa_3d
	virtual_viewport.screen_space_aa = get_viewport().screen_space_aa
	virtual_viewport.use_taa = get_viewport().use_taa
	virtual_viewport.use_debanding = get_viewport().use_debanding
	virtual_viewport.use_occlusion_culling = get_viewport().use_occlusion_culling
	virtual_viewport.mesh_lod_threshold = get_viewport().mesh_lod_threshold
	
	_update_camera_near(virtual_camera)
	# 当主相机靠近传送门时加厚传送门视觉体，防止被近裁面裁剪
	_thicken_portal_if_necessary()
#endregion

#region 物理检测
# 根据传送门视觉尺寸和边距，设置前后两个检测区域（Area3D）的大小和位置。
# front_area 在传送门本地 z 负方向（玩家靠近的一侧），
# rear_area 在 z 正方向（传送门背后一侧）。
func _update_portal_area_size():
	var shape_size = Vector3(
		portal_visual.size.x + self.portal_x_margin * 2,
		portal_visual.size.y + self.portal_y_margin * 2,
		self.portal_z_margin)
	var z_offset = self.portal_z_margin / 2
	front_area.set_area_size_and_position(shape_size, -z_offset)
	rear_area.set_area_size_and_position(shape_size, z_offset)
#endregion

#region 传送
# --- 追踪状态 ---
# _in_front / _in_rear: 记录哪些 CharacterBody3D 当前在前/后检测区域内
var _in_front: Dictionary = {}
var _in_rear: Dictionary = {}
# _prev_z: 每个被追踪物体在上一帧的本地 z 坐标（使用相机位置计算），
# 用于检测物体是否穿越了传送门平面（z=0）
var _prev_z: Dictionary = {}
# _cooldowns: 传送后的帧冷却计数，防止因 Area3D 信号时序问题导致的同帧重复传送
var _cooldowns: Dictionary = {}
# _ghosts: 物体实例 ID → Ghost 根节点，用于在传送门画面中显示物体的镜像
var _ghosts: Dictionary = {}
# _camera_near_backup: 物体实例 ID → 主相机原始 near 值，
# 进入传送门区域时备份并在离开时恢复
var _camera_near_backup: Dictionary = {}

# 连接前后检测区域的 body_entered / body_exited 信号
func _connect_area_signals():
	front_area.connect_body_signals(_on_front_entered, _on_front_exited)
	rear_area.connect_body_signals(_on_rear_entered, _on_rear_exited)

# 物体进入前方检测区域：注册追踪、缩小相机近裁面、创建 Ghost
func _on_front_entered(body: Node3D):
	if not body is CharacterBody3D:
		return
	var id = body.get_instance_id()
	_in_front[id] = true
	if not _prev_z.has(id):
		_prev_z[id] = _get_local_z(body)
	_apply_camera_near_fix(body)
	_try_create_ghost(body)

# 物体离开前方检测区域：如果不在任何区域中则清理所有追踪状态
func _on_front_exited(body: Node3D):
	if not body is CharacterBody3D:
		return
	_in_front.erase(body.get_instance_id())
	_check_cleanup(body)

# 物体进入后方检测区域：逻辑与 _on_front_entered 相同
func _on_rear_entered(body: Node3D):
	if not body is CharacterBody3D:
		return
	var id = body.get_instance_id()
	_in_rear[id] = true
	if not _prev_z.has(id):
		_prev_z[id] = _get_local_z(body)
	_apply_camera_near_fix(body)
	_try_create_ghost(body)

# 物体离开后方检测区域
func _on_rear_exited(body: Node3D):
	if not body is CharacterBody3D:
		return
	_in_rear.erase(body.get_instance_id())
	_check_cleanup(body)

# 清理检查：当物体同时不在前后区域中时，清除所有追踪数据、
# 恢复相机近裁面、销毁 Ghost 节点。
func _check_cleanup(body: Node3D):
	var id = body.get_instance_id()
	if not _in_front.has(id) and not _in_rear.has(id):
		_prev_z.erase(id)
		_cooldowns.erase(id)
		_restore_camera_near(body)
		_remove_ghost(body)

# 计算物体（优先使用其子相机位置）在传送门本地坐标系中的 z 分量。
# 使用相机位置而非物体中心是因为玩家通过相机视角感知穿越时刻，
# 相机在 y=1.232 处与物体中心有偏移，用相机位置可以更精确地在
# "玩家眼睛穿过传送门平面" 的那一帧触发传送。
func _get_local_z(body: Node3D) -> float:
	var cam = _find_camera(body)
	var pos = cam.global_position if cam else body.global_position
	return (self.global_transform.affine_inverse() * pos).z

# 递归查找节点树中的 Camera3D 子节点
func _find_camera(node: Node) -> Camera3D:
	if node is Camera3D:
		return node
	for child in node.get_children():
		var found = _find_camera(child)
		if found:
			return found
	return null

# 每个物理帧检测是否有物体穿越了传送门平面（本地 z=0）。
# 穿越判定：比较物体本帧与上帧的本地 z 坐度符号是否翻转。
# 检测到穿越后立即执行传送，并同步更新双方 VirtualCamera。
func _check_teleportations():
	var to_teleport = []
	# 第一遍：检测穿越，收集需要传送的物体 ID
	for id in _prev_z.keys():
		# 冷却期内只更新 prev_z，不做穿越判定
		if _cooldowns.get(id, 0) > 0:
			_cooldowns[id] -= 1
			var b = instance_from_id(id)
			if is_instance_valid(b):
				_prev_z[id] = _get_local_z(b)
			continue
		var body = instance_from_id(id) as Node3D
		if not is_instance_valid(body):
			continue
		var current_z = _get_local_z(body)
		var prev = _prev_z.get(id, 0.0)
		# z 坐标符号翻转 = 穿越了传送门平面
		if _nonzero_sign(prev) != _nonzero_sign(current_z):
			to_teleport.append(id)
		else:
			_prev_z[id] = current_z

	# 第二遍：对穿越的物体执行传送
	for id in to_teleport:
		var body = instance_from_id(id) as CharacterBody3D
		if not is_instance_valid(body):
			continue
		_remove_ghost(body)
		# 传送前先恢复相机近裁面，这样目标传送门可以重新保存正确的原始值
		_restore_camera_near(body)
		var prev_pos = body.global_position
		_apply_teleport(body)
		# 传送后立即同步更新双方 VirtualCamera，避免一帧延迟导致的画面跳变
		_update_virtual_camera()
		if is_instance_valid(target_portal):
			target_portal._update_virtual_camera()
		# 清除源传送门的追踪数据
		_in_front.erase(id)
		_in_rear.erase(id)
		_prev_z.erase(id)
		_cooldowns.erase(id)
		_camera_near_backup.erase(id)
		# 仅当移动距离超过阈值时才通知目标传送门接收（排除被其他能力瞬移误触）
		if body.global_position.distance_to(prev_pos) > MOVE_WAS_TELEPORT_THRESHOLD:
			if is_instance_valid(target_portal):
				target_portal._receive_body(body)

# 目标传送门接收刚传送过来的物体：初始化 z 追踪、设置冷却帧、
# 重新应用相机近裁面修复、创建 Ghost。
# 冷却帧用于防止因 Area3D body_entered 信号时序不确定导致的误传送。
func _receive_body(body: CharacterBody3D):
	var id = body.get_instance_id()
	_prev_z[id] = _get_local_z(body)
	_cooldowns[id] = TELEPORT_COOLDOWN_FRAMES
	_apply_camera_near_fix(body)
	_try_create_ghost(body)

# 执行实际的空间变换传送。
# 变换公式（与 VirtualCamera 位置计算使用相同的仿射变换数学）：
#   新全局变换 = 目标传送门全局变换 × (当前传送门全局变换的逆 × 物体全局变换)
# 同时将物体的线速度通过两个传送门之间的旋转变换进行映射。
func _apply_teleport(body: CharacterBody3D):
	var rel_transform = self.global_transform.affine_inverse() * body.global_transform
	body.global_transform = target_portal.global_transform * rel_transform
	var rel_vel = self.global_transform.basis.inverse() * body.velocity
	body.velocity = target_portal.global_transform.basis * rel_vel

# --- Ghost 系统 ---
# Ghost 是物体的纯视觉镜像副本，放置在目标传送门侧的对应位置。
# 当物体部分穿过传送门平面时，Ghost 让另一侧的 VirtualCamera 能看到
# 物体"探出"传送门的部分。Ghost 仅复制 MeshInstance3D（不复制碰撞体），
# 并设置为专属 Ghost 渲染层，确保只在 VirtualCamera 中可见。

# 为物体创建 Ghost 节点（如果尚未创建）
func _try_create_ghost(body: Node3D):
	var id = body.get_instance_id()
	if _ghosts.has(id):
		return
	if not is_instance_valid(target_portal):
		return
	var ghost_root = Node3D.new()
	ghost_root.name = "Ghost_" + body.name
	_clone_visual_nodes(body, ghost_root)
	# Ghost 挂载到目标传送门下，位置通过变换公式计算
	target_portal.add_child(ghost_root)
	_ghosts[id] = ghost_root
	_update_single_ghost(body)

# 递归克隆源节点的 MeshInstance3D 子节点到 Ghost 根节点
func _clone_visual_nodes(source: Node, target_parent: Node):
	for child in source.get_children():
		if child is MeshInstance3D:
			var dupe = child.duplicate()
			_set_ghost_layer_recursive(dupe)
			target_parent.add_child(dupe)
		else:
			_clone_visual_nodes(child, target_parent)

# 将 Ghost 节点（及其子节点）的渲染层设为仅本传送门专属的 Ghost 层。
# 主摄像机关闭此层 → 看不到 Ghost；VirtualCamera 开启此层 → 能看到 Ghost。
func _set_ghost_layer_recursive(node: Node):
	if node is VisualInstance3D:
		node.layers = 0
		node.set_layer_mask_value(_my_ghost_layer, true)
	for child in node.get_children():
		_set_ghost_layer_recursive(child)

# 立即更新单个 Ghost 的变换（创建时调用一次）
func _update_single_ghost(body: Node3D):
	var ghost = _ghosts.get(body.get_instance_id())
	if not ghost or not is_instance_valid(ghost):
		return
	var rel = self.global_transform.affine_inverse() * body.global_transform
	ghost.global_transform = target_portal.global_transform * rel

# 每帧同步所有 Ghost 的变换，使其与对应物体保持镜像关系
func _update_ghosts():
	for id in _ghosts:
		var ghost = _ghosts[id]
		if not is_instance_valid(ghost):
			continue
		var body = instance_from_id(id)
		if not is_instance_valid(body):
			continue
		var rel = self.global_transform.affine_inverse() * body.global_transform
		ghost.global_transform = target_portal.global_transform * rel

# 销毁指定物体的 Ghost 节点
func _remove_ghost(body: Node3D):
	var id = body.get_instance_id()
	var ghost = _ghosts.get(id)
	if ghost:
		if is_instance_valid(ghost):
			ghost.queue_free()
		_ghosts.erase(id)

# --- 相机近裁面修复 ---
# 当角色进入传送门检测区域时，将主相机 near 缩小到 0.001。
# 这是因为传送门视觉面（CSGBox3D）深度很小（约 0.05），
# 当相机靠近传送门时默认近裁面（0.05）会裁掉视觉面，
# 导致玩家看到传送门背后的墙壁/环境，产生视觉抖动。

# 备份并缩小相机近裁面（仅在首次进入时备份原始值）
func _apply_camera_near_fix(body: Node3D):
	var id = body.get_instance_id()
	if _camera_near_backup.has(id):
		return
	var cam = _find_camera(body)
	if not cam:
		return
	_camera_near_backup[id] = cam.near
	cam.near = CAM_NEAR_FIX

# 恢复相机近裁面到原始值，并清除备份
func _restore_camera_near(body: Node3D):
	var id = body.get_instance_id()
	if not _camera_near_backup.has(id):
		return
	var cam = _find_camera(body)
	if cam:
		cam.near = _camera_near_backup[id]
	_camera_near_backup.erase(id)

# --- 传送门视觉加厚 ---
# 当主相机非常靠近传送门时（距离 < 1.0），将 CSGBox3D 的深度从 0.05 增到 0.3，
# 并向相机所在侧的反方向偏移，作为近裁面修复的双重保险。
# 远离时恢复为极小值（0.00001），保持正常视觉效果。
func _thicken_portal_if_necessary():
	var cur_camera = get_viewport().get_camera_3d()
	if not cur_camera:
		return
	var forward := self.global_transform.basis.z
	var right := self.global_transform.basis.x
	var up := self.global_transform.basis.y
	var offset: Vector3 = cur_camera.global_position - self.global_position
	var dist_forward: float = offset.dot(forward)
	var dist_right: float = offset.dot(right)
	var dist_up: float = offset.dot(up)
	var half_w := portal_visual.size.x / 2.0
	var half_h := portal_visual.size.y / 2.0
	# 相机距离足够远或不在传送门范围内 → 恢复为极薄
	if abs(dist_forward) > 1.0 or abs(dist_right) > half_w + 0.3 or dist_up > half_h + 0.3:
		portal_visual.size.z = 0.00001
		portal_visual.position.z = 0.0
		return
	# 相机靠近 → 加厚并向相机反方向偏移
	var thickness := 0.3
	portal_visual.size.z = thickness
	if _nonzero_sign(dist_forward) == 1:
		portal_visual.position.z = -thickness / 2.0
	else:
		portal_visual.position.z = thickness / 2.0
#endregion
