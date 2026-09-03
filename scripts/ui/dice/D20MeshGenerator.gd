class_name D20MeshGenerator
extends RefCounted
## D20MeshGenerator — Generador de dados D20 hiperrealistas con Atlas de Textura PBR y números de metal fundido grabados en cada cara.

# Texture Atlases HD con las 20 caras grabadas idénticas a la foto de referencia
const TEX_ATLAS_GOLD := preload("res://assets/dice/d20_atlas_gold.png")
const TEX_ATLAS_SILVER := preload("res://assets/dice/d20_atlas_silver.png")
const TEX_ATLAS_NORMAL := preload("res://assets/dice/d20_atlas_normal.png")
const TEX_ATLAS_ROUGH := preload("res://assets/dice/d20_atlas_roughness.png")

# Asignación estándar de números para las 20 caras (caras opuestas suman 21)
const FACE_NUMBERS: Array[int] = [
	20, 1, 14, 8, 11,
	2, 19, 7, 13, 10,
	18, 3, 15, 6, 9,
	12, 5, 17, 4, 16
]


static func create_d20_node(radius: float = 0.78, is_player: bool = true) -> Node3D:
	"""Crea y retorna un Node3D con el D20 de metal forjado hiperrealista texturizado con Atlas PBR."""
	var root = Node3D.new()
	root.name = "D20_Player" if is_player else "D20_Opponent"

	var mesh_instance = MeshInstance3D.new()
	mesh_instance.name = "D20Mesh"

	var data = _build_atlas_icosahedron(radius)
	mesh_instance.mesh = data["mesh"]

	# Material PBR de Metal Forjado Envejecido (Oro Antiguo / Plata de Hierro Fundido)
	var mat = StandardMaterial3D.new()
	if is_player:
		# Skin Oro Forjado Antiguo
		mat.albedo_texture = TEX_ATLAS_GOLD
		mat.metallic = 0.70
		mat.roughness = 0.28
		mat.roughness_texture = TEX_ATLAS_ROUGH
		mat.normal_enabled = true
		mat.normal_texture = TEX_ATLAS_NORMAL
		mat.rim_enabled = true
		mat.rim = 0.6
		mat.rim_tint = 0.4
	else:
		# Skin Hierro Fundido / Plata Envejecida
		mat.albedo_texture = TEX_ATLAS_SILVER
		mat.metallic = 0.75
		mat.roughness = 0.28
		mat.roughness_texture = TEX_ATLAS_ROUGH
		mat.normal_enabled = true
		mat.normal_texture = TEX_ATLAS_NORMAL
		mat.rim_enabled = true
		mat.rim = 0.6
		mat.rim_tint = 0.4

	mesh_instance.material_override = mat
	root.add_child(mesh_instance)

	root.set_meta("face_normals", data["face_normals"])
	root.set_meta("face_ups", data["face_ups"])
	root.set_meta("face_numbers", FACE_NUMBERS)

	return root


static func get_quaternion_for_value(d20_node: Node3D, target_value: int, target_facing_dir: Vector3, world_up: Vector3 = Vector3.UP) -> Quaternion:
	"""Calcula la orientación exacta del dado para que la cara con target_value quede mirando hacia la cámara y completamente erguida."""
	var face_numbers: Array = d20_node.get_meta("face_numbers", FACE_NUMBERS)
	var face_normals: Array = d20_node.get_meta("face_normals", [])
	var face_ups: Array = d20_node.get_meta("face_ups", [])

	var face_idx = face_numbers.find(target_value)
	if face_idx < 0 or face_idx >= face_normals.size():
		return Quaternion.IDENTITY

	var n_local: Vector3 = (face_normals[face_idx] as Vector3).normalized()
	var u_local: Vector3 = (face_ups[face_idx] as Vector3).normalized()
	var r_local: Vector3 = u_local.cross(n_local).normalized()
	u_local = n_local.cross(r_local).normalized()

	var basis_local = Basis(r_local, u_local, n_local)

	var n_target: Vector3 = target_facing_dir.normalized()
	var u_target: Vector3 = (world_up - n_target * world_up.dot(n_target)).normalized()
	if u_target.length_squared() < 0.01:
		u_target = Vector3.UP
	var r_target: Vector3 = u_target.cross(n_target).normalized()
	u_target = n_target.cross(r_target).normalized()

	var basis_target = Basis(r_target, u_target, n_target)
	var basis_result = basis_target * basis_local.transposed()
	return basis_result.orthonormalized().get_rotation_quaternion()


static func _build_atlas_icosahedron(radius: float) -> Dictionary:
	var phi = (1.0 + sqrt(5.0)) / 2.0
	var raw_vertices: Array[Vector3] = [
		Vector3(-1,  phi,  0), Vector3( 1,  phi,  0),
		Vector3(-1, -phi,  0), Vector3( 1, -phi,  0),
		Vector3( 0, -1,  phi), Vector3( 0,  1,  phi),
		Vector3( 0, -1, -phi), Vector3( 0,  1, -phi),
		Vector3( phi,  0, -1), Vector3( phi,  0,  1),
		Vector3(-phi,  0, -1), Vector3(-phi,  0,  1),
	]

	var norm_vertices: Array[Vector3] = []
	for rv in raw_vertices:
		norm_vertices.append(rv.normalized() * radius)

	var faces_indices: Array[Vector3i] = [
		Vector3i(0, 11, 5), Vector3i(0, 5, 1), Vector3i(0, 1, 7), Vector3i(0, 7, 10), Vector3i(0, 10, 11),
		Vector3i(1, 5, 9), Vector3i(5, 11, 4), Vector3i(11, 10, 2), Vector3i(10, 7, 6), Vector3i(7, 1, 8),
		Vector3i(3, 9, 4), Vector3i(3, 4, 2), Vector3i(3, 2, 6), Vector3i(3, 6, 8), Vector3i(3, 8, 9),
		Vector3i(4, 9, 5), Vector3i(2, 4, 11), Vector3i(6, 2, 10), Vector3i(8, 6, 7), Vector3i(9, 8, 1)
	]

	var face_normals: Array[Vector3] = []
	var face_ups: Array[Vector3] = []

	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var cols = 5.0
	var rows = 4.0

	for i in range(faces_indices.size()):
		var tri = faces_indices[i]
		var v0 = norm_vertices[tri.x]
		var v1 = norm_vertices[tri.y]
		var v2 = norm_vertices[tri.z]

		var center = (v0 + v1 + v2) / 3.0
		var normal = ((v1 - v0).cross(v2 - v0)).normalized()
		if normal.dot(center) < 0:
			normal = -normal
			var temp = v1
			v1 = v2
			v2 = temp

		face_normals.append(normal)

		var up_vec = (v0 - center).normalized()
		face_ups.append(up_vec)

		# Coordenadas UV en el Atlas 5x4
		var row = float(i / 5)
		var col = float(i % 5)

		var u_min = col / cols
		var u_max = (col + 1.0) / cols
		var u_mid = (u_min + u_max) / 2.0

		var v_min = row / rows
		var v_max = (row + 1.0) / rows

		var uv0 = Vector2(u_mid, v_min + 0.02)
		var uv1 = Vector2(u_max - 0.015, v_max - 0.02)
		var uv2 = Vector2(u_min + 0.015, v_max - 0.02)

		st.set_normal(normal)
		st.set_uv(uv0)
		st.add_vertex(v0)

		st.set_normal(normal)
		st.set_uv(uv1)
		st.add_vertex(v1)

		st.set_normal(normal)
		st.set_uv(uv2)
		st.add_vertex(v2)

	var mesh = st.commit()

	return {
		"mesh": mesh,
		"face_normals": face_normals,
		"face_ups": face_ups
	}
