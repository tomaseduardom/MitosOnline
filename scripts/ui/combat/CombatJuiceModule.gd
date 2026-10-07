extends Control
class_name CombatJuiceModule
## CombatJuiceModule — Módulo de impacto cinemático y retroalimentación táctica en combate.
## Gestiona:
## 1. Flechas tácticas rúnicas de ataque y bloqueo (curvas bezier, puntas dinámicas y pulso místico).
## 2. Animación física de acometida y choque entre Aliados ("Clash Shake & Sparks").
## 3. Impacto devastador al Castillo (números flotantes de daño, sacudida de pedestal y destello carmesí).

const FONT_TITLE = preload("res://assets/fonts/Cinzel-Bold.ttf")
const FONT_REGULAR = preload("res://assets/fonts/Marcellus-Regular.ttf")

var _main: Node = null
var _pulse_time: float = 0.0
var _is_combat_resolving: bool = false


func _init() -> void:
	name = "CombatJuiceModule"
	z_index = 450
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func setup(main: Node) -> void:
	_main = main
	if is_inside_tree():
		_connect_signals()


func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		_connect_signals()


func _connect_signals() -> void:
	if not is_inside_tree():
		return
	var bm = get_node_or_null("/root/BattleManager")
	if bm:
		if bm.has_signal("damage_to_castle") and not bm.damage_to_castle.is_connected(_on_battle_damage_to_castle):
			bm.damage_to_castle.connect(_on_battle_damage_to_castle)
		if bm.has_signal("combat_finished") and not bm.combat_finished.is_connected(_on_combat_finished):
			bm.combat_finished.connect(_on_combat_finished)


func _process(delta: float) -> void:
	_pulse_time += delta * 3.5
	if _should_draw_combat_arrows():
		queue_redraw()
	else:
		# Si ya no hay combate activo, un redibujado limpia la pantalla
		queue_redraw()


# =============================================================================
# 1. FLECHAS TÁCTICAS RÚNICAS (ATAQUE Y BLOQUEO)
# =============================================================================
func _should_draw_combat_arrows() -> bool:
	if not is_instance_valid(_main):
		return false
	if _is_combat_resolving:
		return false
	var gm = get_node_or_null("/root/GameManager")
	if not gm:
		return false
	var phase = gm.current_phase
	if phase not in [Constants.Phase.ATAQUE, Constants.Phase.BLOQUEO, Constants.Phase.GUERRA_TALISMANES]:
		return false
	return not gm.attackers.is_empty()


func _draw() -> void:
	if not _should_draw_combat_arrows():
		return

	var gm = get_node_or_null("/root/GameManager")
	if not gm:
		return

	# 1. Flechas de Atacantes hacia el Castillo rival (si no están bloqueados)
	for attacker in gm.attackers:
		if not is_instance_valid(attacker) or not attacker.is_inside_tree() or not attacker.is_visible_in_tree():
			continue

		var is_blocked = gm.blockers.has(attacker)
		if not is_blocked:
			var target_castle = _get_enemy_castle_panel(attacker)
			if target_castle and is_instance_valid(target_castle):
				var start_pt = _get_card_center(attacker)
				var end_pt = _get_node_center(target_castle)
				
				# Tono dorado/fuego mítico con pulso respirante
				var alpha = 0.70 + 0.25 * sin(_pulse_time)
				var gold_color = Color(1.0, 0.80, 0.28, alpha)
				_draw_curved_arrow(start_pt, end_pt, gold_color, 3.2, 0.12)

	# 2. Líneas rúnicas de Bloqueo / Duelo (Bloqueador -> Atacante)
	for attacker in gm.blockers:
		var blocker = gm.blockers[attacker]
		if not is_instance_valid(attacker) or not is_instance_valid(blocker):
			continue
		if not attacker.is_inside_tree() or not blocker.is_inside_tree():
			continue

		var start_pt = _get_card_center(blocker)
		var end_pt = _get_card_center(attacker)

		# Tono zafiro/eléctrico de intercepción
		var alpha = 0.80 + 0.20 * cos(_pulse_time)
		var cyan_color = Color(0.30, 0.82, 1.0, alpha)
		_draw_curved_arrow(start_pt, end_pt, cyan_color, 3.6, -0.10)

		# Emblema central de choque (rombo o runa en el punto medio)
		var mid_pt = (start_pt + end_pt) / 2.0
		_draw_clash_marker(mid_pt, cyan_color)


func _draw_curved_arrow(start: Vector2, target: Vector2, color: Color, width: float, curve_intensity: float) -> void:
	var diff = target - start
	var dist = diff.length()
	if dist < 40.0:
		return

	var dir = diff.normalized()
	var perp = Vector2(-dir.y, dir.x)

	# El objetivo se frena unos 28px antes del centro del panel para no tapar iconos
	var visual_target = target - dir * 28.0
	var mid = (start + visual_target) / 2.0 + perp * (dist * curve_intensity)

	# Generar puntos de la curva cuadrática Bezier
	var points: PackedVector2Array = []
	var steps = 22
	for i in range(steps + 1):
		var t = float(i) / float(steps)
		var p = (1.0 - t) * (1.0 - t) * start + 2.0 * (1.0 - t) * t * mid + t * t * visual_target
		points.append(p)

	# 1. Halo difuso exterior
	draw_polyline(points, Color(color.r, color.g, color.b, color.a * 0.25), width + 4.5, true)
	# 2. Núcleo luminoso
	draw_polyline(points, color, width, true)

	# 3. Punta de flecha estilizada
	var end_dir = (visual_target - points[points.size() - 2]).normalized()
	var arrow_size = 14.0
	var arrow_p1 = visual_target - end_dir * arrow_size + Vector2(-end_dir.y, end_dir.x) * (arrow_size * 0.50)
	var arrow_p2 = visual_target - end_dir * arrow_size - Vector2(-end_dir.y, end_dir.x) * (arrow_size * 0.50)
	var arrow_pts = PackedVector2Array([visual_target, arrow_p1, visual_target - end_dir * (arrow_size * 0.70), arrow_p2])
	draw_colored_polygon(arrow_pts, color)


func _draw_clash_marker(pos: Vector2, color: Color) -> void:
	var radius = 7.0 + 1.5 * sin(_pulse_time * 2.0)
	var pts = PackedVector2Array([
		pos + Vector2(0, -radius),
		pos + Vector2(radius, 0),
		pos + Vector2(0, radius),
		pos + Vector2(-radius, 0)
	])
	# Halo y núcleo
	draw_colored_polygon(pts, Color(color.r, color.g, color.b, 0.40))
	draw_polyline(pts, Color.WHITE, 1.8, true)


func _get_card_center(card: Node) -> Vector2:
	if card is Control:
		return card.global_position + card.size / 2.0
	return card.global_position


func _get_node_center(node: Control) -> Vector2:
	return node.global_position + node.size / 2.0


func get_castle_panel(player_id: int) -> Control:
	if not is_instance_valid(_main):
		return null
	if player_id == 1:
		var opp = _main.get("_panel_opp_castillo")
		if not opp:
			opp = _main.get("_panel_opp_cas")
		if not opp and _main.has_meta("_panel_opp_cas"):
			opp = _main.get_meta("_panel_opp_cas")
		if not opp and _main.has_node("GameBoard/OpponentArea/OpponentCastillo"):
			opp = _main.get_node("GameBoard/OpponentArea/OpponentCastillo")
		return opp
	else:
		var plr = _main.get("_panel_player_castillo")
		if not plr:
			plr = _main.get("_panel_player_cas")
		if not plr and _main.has_meta("_panel_player_cas"):
			plr = _main.get_meta("_panel_player_cas")
		if not plr and _main.has_node("GameBoard/PlayerArea/PlayerCastillo"):
			plr = _main.get_node("GameBoard/PlayerArea/PlayerCastillo")
		return plr


func _get_enemy_castle_panel(attacker: Node) -> Control:
	if not _main:
		return null
	var cid = attacker.get("controller_id")
	if cid == null and attacker.has_meta("controller_id"):
		cid = attacker.get_meta("controller_id")
	var is_player: bool = true
	if cid != null:
		is_player = (int(cid) == 0)
	elif attacker.get_parent() != null:
		var opp_atk = _main.get("opponent_linea_ataque")
		var opp_fld = _main.get("opponent_field")
		if (opp_atk and attacker.get_parent() == opp_atk) or (opp_fld and attacker.get_parent() == opp_fld):
			is_player = false

	return get_castle_panel(1 if is_player else 0)


# =============================================================================
# 2. ACOMETIDA Y CHOQUE FÍSICO ("CLASH SHAKE & SPARKS")
# =============================================================================
func play_all_clashes(combat_pairs: Array) -> void:
	"""Ejecuta en paralelo el choque cinemático de todos los pares enfrentados."""
	if not is_inside_tree() or combat_pairs.is_empty():
		return

	_is_combat_resolving = true
	queue_redraw()

	for pair in combat_pairs:
		var attacker = pair.get("attacker")
		var blocker = pair.get("blocker")
		if is_instance_valid(attacker) and is_instance_valid(blocker):
			_play_single_clash(attacker, blocker)

	# Duración total de la cinemática de choque
	var tree = get_tree()
	if tree:
		await tree.create_timer(0.34).timeout


func _play_single_clash(attacker: Node, blocker: Node) -> void:
	if not is_instance_valid(attacker) or not is_instance_valid(blocker):
		return
	if not attacker.is_inside_tree() or not blocker.is_inside_tree():
		return

	var atk_orig: Vector2 = attacker.position
	var blk_orig: Vector2 = blocker.position
	var atk_g: Vector2 = attacker.global_position
	var blk_g: Vector2 = blocker.global_position

	var dir: Vector2 = (blk_g - atk_g).normalized()
	var mid: Vector2 = (atk_g + blk_g) / 2.0
	var lunge_dist: float = 24.0

	# 1. Acometida rápida hacia el rival (0.09s)
	var tw = create_tween()
	tw.set_parallel(true)
	tw.tween_property(attacker, "position", atk_orig + dir * lunge_dist, 0.09).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(blocker, "position", blk_orig - dir * lunge_dist, 0.09).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)

	# 2. Destello de impacto y chispas al momento de chocar
	tw.chain().tween_callback(func():
		_spawn_clash_sparks(mid)
		if is_instance_valid(attacker):
			attacker.modulate = Color(1.5, 1.4, 1.1, 1.0)
		if is_instance_valid(blocker):
			blocker.modulate = Color(1.5, 1.4, 1.1, 1.0)
	)

	# 3. Rebote / Recoil elástico hacia la posición original (0.16s)
	tw.tween_property(attacker, "position", atk_orig, 0.16).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tw.tween_property(blocker, "position", blk_orig, 0.16).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tw.tween_property(attacker, "modulate", Color.WHITE, 0.16)
	tw.tween_property(blocker, "modulate", Color.WHITE, 0.16)


func play_unblocked_surges(unblocked_attackers: Array) -> void:
	"""Pequeña acometida triunfal de los Aliados sin bloquear hacia el Castillo."""
	if not is_inside_tree() or unblocked_attackers.is_empty():
		return

	_is_combat_resolving = true
	queue_redraw()

	for attacker in unblocked_attackers:
		if not is_instance_valid(attacker) or not attacker.is_inside_tree():
			continue
		var orig = attacker.position
		var dir = Vector2(0, -18.0) if (attacker.get("controller_id") == 0) else Vector2(0, 18.0)

		var tw = create_tween()
		tw.tween_property(attacker, "position", orig + dir, 0.10).set_ease(Tween.EASE_OUT)
		tw.tween_property(attacker, "position", orig, 0.14).set_ease(Tween.EASE_IN)

	var tree = get_tree()
	if tree:
		await tree.create_timer(0.24).timeout


func _spawn_clash_sparks(pos: Vector2) -> void:
	if not is_inside_tree():
		return

	var sparks = CPUParticles2D.new()
	sparks.position = pos
	sparks.amount = 16
	sparks.lifetime = 0.28
	sparks.one_shot = true
	sparks.explosiveness = 0.95
	sparks.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	sparks.emission_sphere_radius = 4.0
	sparks.spread = 180.0
	sparks.gravity = Vector2.ZERO
	sparks.initial_velocity_min = 70.0
	sparks.initial_velocity_max = 140.0
	sparks.scale_amount_min = 2.0
	sparks.scale_amount_max = 4.5
	sparks.color = Color(1.0, 0.92, 0.45, 0.90)
	add_child(sparks)
	sparks.emitting = true

	var tree = get_tree()
	if tree:
		tree.create_timer(0.40).timeout.connect(func():
			if is_instance_valid(sparks):
				sparks.queue_free()
		)


# =============================================================================
# 3. IMPACTO DE DAÑO AL CASTILLO (SACUDIDA, DESTELLO Y NÚMEROS FLOTANTES)
# =============================================================================
func _on_battle_damage_to_castle(player_id: int, total_damage: int, _sources: Array) -> void:
	play_castle_damage(player_id, total_damage)


func play_castle_damage(player_id: int, total_damage: int) -> void:
	"""Dispara la cinemática de impacto sobre el Castillo receptor del daño."""
	if not is_inside_tree() or not _main or total_damage <= 0:
		return

	var castle: Control = get_castle_panel(player_id)
	if not castle or not is_instance_valid(castle):
		return

	# 1. Sacudida del pedestal del Castillo
	_shake_node(castle, 4.5, 0.28)

	# 2. Sacudida de mesa si el daño es considerable (>= 2 cartas)
	if total_damage >= 2 and _main.get("game_board") != null:
		_shake_node(_main.get("game_board"), 3.0, 0.20)

	# 3. Destello carmesí en el marco del Castillo
	_flash_castle_damage(castle)

	# 4. Número flotante emergente (-X)
	_spawn_floating_damage_number(castle, total_damage)


func _shake_node(node: Control, intensity: float, duration: float) -> void:
	var orig_pos = node.position
	var tw = create_tween()
	var steps = int(duration / 0.04)
	for i in range(steps):
		var decay = 1.0 - (float(i) / float(steps))
		var offset = Vector2(randf_range(-intensity, intensity), randf_range(-intensity * 0.7, intensity * 0.7)) * decay
		tw.tween_property(node, "position", orig_pos + offset, 0.04)
	tw.tween_property(node, "position", orig_pos, 0.04)


func _flash_castle_damage(castle: Control) -> void:
	var flash = ColorRect.new()
	flash.color = Color(0.85, 0.15, 0.15, 0.45)
	flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	castle.add_child(flash)

	var tw = create_tween()
	tw.tween_property(flash, "modulate:a", 0.0, 0.32).set_ease(Tween.EASE_OUT)
	tw.finished.connect(func():
		if is_instance_valid(flash):
			flash.queue_free()
	)


func _spawn_floating_damage_number(castle: Control, damage: int) -> void:
	var label = Label.new()
	label.text = "-%d" % damage
	label.add_theme_font_override("font", FONT_TITLE)
	label.add_theme_font_size_override("font_size", 36)
	label.add_theme_color_override("font_color", Color(1.0, 0.22, 0.18, 1.0))
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.top_level = true
	label.z_index = 600

	var c_rect = castle.get_global_rect()
	var start_pos = Vector2(c_rect.get_center().x - 25.0, c_rect.position.y - 12.0)
	label.global_position = start_pos
	label.scale = Vector2(0.4, 0.4)
	label.pivot_offset = Vector2(25.0, 18.0)
	add_child(label)

	var tw = create_tween()
	tw.set_parallel(true)
	# Rebote elástico
	tw.tween_property(label, "scale", Vector2(1.35, 1.35), 0.10).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tw.tween_property(label, "scale", Vector2.ONE, 0.15).set_delay(0.10)
	# Ascenso flotante
	tw.tween_property(label, "global_position:y", start_pos.y - 48.0, 0.85).set_ease(Tween.EASE_OUT)
	# Desvanecimiento
	tw.tween_property(label, "modulate:a", 0.0, 0.30).set_delay(0.55)

	tw.finished.connect(func():
		if is_instance_valid(label):
			label.queue_free()
	)


func _on_combat_finished(_result: Dictionary) -> void:
	_is_combat_resolving = false
	queue_redraw()
