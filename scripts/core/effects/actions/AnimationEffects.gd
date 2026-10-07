extends RefCounted
class_name AnimationEffects
## AnimationEffects — Biblioteca de animaciones visuales concretas (mover carta
## entre zonas, destruir, desterrar, daño, buff/heal, flip, entrada en
## juego, mensajes). Opera sobre AnimationQueue via _main (animation_speed,
## delays, create_tween/get_tree — RefCounted no los tiene propios).
## Extraído de AnimationQueue.gd (Fase 4 de reestructuración).

var _main: Node


func setup(main: Node) -> void:
	_main = main


func animate_card_move(card: Node, from_zone: int, to_zone: int, player_id: int) -> void:
	"""Anima el movimiento de una carta entre zonas con arco visual

	IMPORTANTE: También actualiza las propiedades internas de la carta
	(current_zone, controller_id) para que los triggers detecten el cambio.
	"""
	var game_board = _main._get_game_board()
	if not game_board:
		return

	# Guardar zona anterior para triggers
	var previous_zone = card.current_zone if card.get("current_zone") != null else from_zone
	var previous_controller = card.controller_id if card.get("controller_id") != null else player_id

	# Obtener posiciones
	var start_pos = card.global_position if card.get("global_position") else Vector2.ZERO
	var end_container = game_board.get_zone_container(to_zone, player_id)
	var end_pos = end_container.global_position if end_container else start_pos

	# Calcular duración basada en distancia
	var distance = start_pos.distance_to(end_pos)
	var base_duration = 0.25 / _main.animation_speed
	var duration = clampf(base_duration + (distance / 2000.0), 0.15, 0.6) / _main.animation_speed

	if card.has_method("animate_to"):
		await card.animate_to(end_pos, duration)
	else:
		# Crear tween con movimiento en arco
		var tween = _main.create_tween()
		tween.set_ease(Tween.EASE_OUT)
		tween.set_trans(Tween.TRANS_CUBIC)

		# Calcular punto medio elevado para el arco
		var mid_pos = (start_pos + end_pos) / 2.0
		var arc_height = min(distance * 0.3, 100)  # Arco proporcional a distancia
		mid_pos.y -= arc_height

		# Fase 1: Subir y moverse hacia el medio
		tween.tween_property(card, "global_position", mid_pos, duration * 0.5)
		tween.set_ease(Tween.EASE_OUT)

		# Fase 2: Bajar hacia el destino
		tween.tween_property(card, "global_position", end_pos, duration * 0.5)
		tween.set_ease(Tween.EASE_IN)

		# Esperar a que termine completamente
		await tween.finished

	# ACTUALIZAR PROPIEDADES INTERNAS DE LA CARTA (para triggers)
	_update_card_zone_properties(card, to_zone, player_id, previous_zone, previous_controller)

	# Mover físicamente en el game_board
	game_board.move_card(card, to_zone, player_id, true)


func _update_card_zone_properties(card: Node, new_zone: int, new_controller: int, prev_zone: int, prev_controller: int) -> void:
	"""Actualiza las propiedades internas de zona de una carta

	Esto es CRÍTICO para que:
	- TriggerSystem detecte cambios de zona (ETB, LTB)
	- CardEffectSystem sepa dónde está la carta
	- Las habilidades continuas se activen/desactiven correctamente
	"""
	# Actualizar zona actual
	if "current_zone" in card:
		card.current_zone = new_zone

	# Actualizar controlador
	if "controller_id" in card:
		card.controller_id = new_controller

	# Actualizar owner si es diferente (para efectos de robo de cartas)
	# owner_id NO cambia - siempre es el dueño original

	# Timestamp de cuando entró a la zona (para "enfermedad de invocación")
	if "zone_entered_turn" in card and GameManager:
		card.zone_entered_turn = GameManager.current_turn

	# (2026-08-28, "módulos gordos" punto 1): aquí había un intento de emitir
	# 'card_left_zone'/'card_entered_zone' en TriggerSystem — ninguna de las
	# dos señales existe ni existió nunca ahí, el has_signal() que las
	# envolvía siempre daba falso. Se sacó.

	# Log para debugging
	var card_name = card.card_name if card.get("card_name") else "Carta"
	var prev_zone_name = Constants.ZONE_NAMES.get(prev_zone, "?")
	var new_zone_name = Constants.ZONE_NAMES.get(new_zone, "?")

	if prev_zone != new_zone:
		print("[AnimationQueue] %s: %s → %s (ctrl: %d)" % [card_name, prev_zone_name, new_zone_name, new_controller])


func animate_cards_sequentially(cards: Array, from_zone: int, to_zone: int, player_id: int, delay_between: float = -1) -> void:
	"""Anima múltiples cartas en secuencia, esperando que cada una termine antes de la siguiente

	Args:
		cards: Array de cartas a mover
		from_zone: Zona origen
		to_zone: Zona destino
		player_id: ID del jugador
		delay_between: Delay opcional entre cartas (-1 usa el valor por defecto)
	"""
	if delay_between < 0:
		delay_between = _main.delay_between_cards

	for i in range(cards.size()):
		var card = cards[i]

		# Animar esta carta y ESPERAR a que termine
		await animate_card_move(card, from_zone, to_zone, player_id)

		# Pequeño delay entre cartas para efecto visual
		if i < cards.size() - 1 and delay_between > 0:
			await _main.get_tree().create_timer(delay_between / _main.animation_speed).timeout

	print("[AnimationQueue] Secuencia de %d cartas completada" % cards.size())


func animate_card_with_callback(card: Node, from_zone: int, to_zone: int, player_id: int, on_complete: Callable = Callable()) -> void:
	"""Anima una carta y ejecuta callback al terminar

	Útil para encadenar animaciones sin bloquear
	"""
	await animate_card_move(card, from_zone, to_zone, player_id)

	if on_complete.is_valid():
		on_complete.call()


func create_chained_tween(card: Node, waypoints: Array[Vector2], durations: Array[float] = []) -> Tween:
	"""Crea un tween encadenado que pasa por múltiples puntos

	Args:
		card: Carta a animar
		waypoints: Array de posiciones a visitar en orden
		durations: Duraciones opcionales para cada segmento (se auto-calcula si está vacío)

	Returns: El Tween creado (para await tween.finished)
	"""
	if waypoints.is_empty():
		return null

	var tween = _main.create_tween()
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.set_trans(Tween.TRANS_CUBIC)

	var current_pos = card.global_position if card.get("global_position") else Vector2.ZERO

	for i in range(waypoints.size()):
		var target = waypoints[i]
		var duration: float

		if i < durations.size():
			duration = durations[i] / _main.animation_speed
		else:
			# Calcular duración basada en distancia
			var dist = current_pos.distance_to(target)
			duration = clampf(dist / 800.0, 0.1, 0.4) / _main.animation_speed

		tween.tween_property(card, "global_position", target, duration)
		current_pos = target

	return tween


func animate_card_flip(card: Node, face_up: bool) -> void:
	"""Anima el volteo de una carta"""
	var duration = 0.2 / _main.animation_speed

	var tween = _main.create_tween()
	tween.tween_property(card, "scale:x", 0.0, duration / 2)
	await tween.finished

	# Cambiar cara
	if card.has_method("set_face_up"):
		card.set_face_up(face_up)
	elif card.has_method("flip_face_up") and face_up:
		card.flip_face_up()
	elif card.has_method("flip_face_down") and not face_up:
		card.flip_face_down()

	tween = _main.create_tween()
	tween.tween_property(card, "scale:x", 1.0, duration / 2)
	await tween.finished


func animate_destruction(card: Node) -> void:
	"""Anima la destrucción de una carta"""
	var duration = 0.3 / _main.animation_speed

	# Efecto de sacudida y desvanecimiento
	var tween = _main.create_tween()
	tween.set_parallel(true)
	tween.tween_property(card, "modulate:a", 0.0, duration)
	tween.tween_property(card, "scale", Vector2(0.5, 0.5), duration)
	tween.tween_property(card, "rotation", 0.2, duration)
	await tween.finished

	# Restaurar para reutilización
	card.modulate.a = 1.0
	card.scale = Vector2.ONE
	card.rotation = 0


func animate_exile(card: Node) -> void:
	"""Anima el destierro de una carta"""
	var duration = 0.4 / _main.animation_speed

	# Efecto de desvanecimiento con brillo
	var tween = _main.create_tween()
	tween.set_parallel(true)
	tween.tween_property(card, "modulate", Color(2, 2, 2, 0), duration)
	tween.tween_property(card, "scale", Vector2(1.5, 1.5), duration)
	await tween.finished

	card.modulate = Color.WHITE
	card.scale = Vector2.ONE


func animate_damage(target: Node, damage: int) -> void:
	"""Anima el efecto de daño"""
	var duration = 0.15 / _main.animation_speed

	# Flash rojo y sacudida
	var original_modulate = target.modulate if target.get("modulate") else Color.WHITE
	var original_pos = target.position if target.get("position") else Vector2.ZERO

	var tween = _main.create_tween()
	tween.tween_property(target, "modulate", Color(1.5, 0.3, 0.3, 1), duration)
	await tween.finished

	# Sacudida
	for i in range(3):
		target.position = original_pos + Vector2(randf_range(-5, 5), randf_range(-5, 5))
		await _main.get_tree().create_timer(0.03).timeout

	target.position = original_pos

	tween = _main.create_tween()
	tween.tween_property(target, "modulate", original_modulate, duration)
	await tween.finished

	# Mostrar número de daño
	_show_damage_number(target, damage)


func _show_damage_number(target: Node, damage: int) -> void:
	"""Muestra el número de daño flotante"""
	var label = Label.new()
	label.text = "-%d" % damage
	label.add_theme_font_size_override("font_size", 24)
	label.modulate = Color(1, 0.2, 0.2, 1)

	if target.get("global_position"):
		label.global_position = target.global_position - Vector2(20, 40)

	_main.get_tree().current_scene.add_child(label)

	# Animación flotante
	var tween = _main.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y", label.position.y - 50, 0.8)
	tween.tween_property(label, "modulate:a", 0.0, 0.8)
	await tween.finished

	label.queue_free()


func play_visual_effect(data: Dictionary) -> void:
	"""Reproduce un efecto visual"""
	var effect_type = data.get("effect", "")
	var target = data.get("target")
	var color = data.get("color", Color.WHITE)
	var duration = data.get("duration", 0.5)

	match effect_type:
		"card_glow", "ability_glow":
			if target and is_instance_valid(target):
				await _animate_glow(target, color, duration)
		"flash":
			if target and is_instance_valid(target):
				await _animate_flash(target, color, duration)
		_:
			await _main.get_tree().create_timer(duration).timeout


func _animate_glow(target: Node, color: Color, duration: float) -> void:
	"""Efecto de brillo en una carta"""
	if not target.get("modulate"):
		return

	var original_modulate = target.modulate
	var glow_color = Color(
		1.0 + color.r * 0.5,
		1.0 + color.g * 0.5,
		1.0 + color.b * 0.5,
		1.0
	)

	var tween = _main.create_tween()
	tween.tween_property(target, "modulate", glow_color, duration * 0.3)
	tween.tween_property(target, "modulate", original_modulate, duration * 0.7)
	await tween.finished


func _animate_flash(target: Node, color: Color, duration: float) -> void:
	"""Efecto de flash rápido"""
	if not target.get("modulate"):
		return

	var original_modulate = target.modulate

	var tween = _main.create_tween()
	tween.tween_property(target, "modulate", color, duration * 0.2)
	tween.tween_property(target, "modulate", original_modulate, duration * 0.3)
	await tween.finished


func animate_buff(card: Node, amount: int, is_buff: bool) -> void:
	"""Anima efecto de buff o debuff"""
	var duration = 0.3 / _main.animation_speed
	var color = Color(0.3, 1.0, 0.3, 1) if is_buff else Color(1.0, 0.3, 0.3, 1)
	var scale_target = Vector2(1.15, 1.15) if is_buff else Vector2(0.9, 0.9)

	var original_scale = card.scale if card.get("scale") else Vector2.ONE
	var original_modulate = card.modulate if card.get("modulate") else Color.WHITE

	var tween = _main.create_tween()
	tween.set_parallel(true)
	tween.tween_property(card, "modulate", color, duration * 0.4)
	tween.tween_property(card, "scale", scale_target, duration * 0.4)
	await tween.finished

	tween = _main.create_tween()
	tween.set_parallel(true)
	tween.tween_property(card, "modulate", original_modulate, duration * 0.6)
	tween.tween_property(card, "scale", original_scale, duration * 0.6)
	await tween.finished

	# Mostrar número de buff/debuff
	_show_buff_number(card, amount, is_buff)


func _show_buff_number(target: Node, amount: int, is_buff: bool) -> void:
	"""Muestra número flotante de buff/debuff"""
	var label = Label.new()
	label.text = "%s%d" % ["+" if is_buff else "", amount]
	label.add_theme_font_size_override("font_size", 20)
	label.modulate = Color(0.3, 1.0, 0.3, 1) if is_buff else Color(1.0, 0.3, 0.3, 1)

	if target.get("global_position"):
		label.global_position = target.global_position - Vector2(15, 50)

	_main.get_tree().current_scene.add_child(label)

	var tween = _main.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y", label.position.y - 40, 0.7)
	tween.tween_property(label, "modulate:a", 0.0, 0.7)
	await tween.finished

	label.queue_free()


func animate_heal(target: Node, amount: int) -> void:
	"""Anima efecto de curación"""
	var duration = 0.4 / _main.animation_speed

	if target.get("modulate"):
		var original_modulate = target.modulate
		var heal_color = Color(0.4, 1.0, 0.6, 1)

		var tween = _main.create_tween()
		tween.tween_property(target, "modulate", heal_color, duration * 0.3)
		tween.tween_property(target, "modulate", original_modulate, duration * 0.7)
		await tween.finished

	# Mostrar número de curación
	var label = Label.new()
	label.text = "+%d" % amount
	label.add_theme_font_size_override("font_size", 22)
	label.modulate = Color(0.3, 1.0, 0.5, 1)

	if target.get("global_position"):
		label.global_position = target.global_position - Vector2(15, 40)

	_main.get_tree().current_scene.add_child(label)

	var tween = _main.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y", label.position.y - 50, 0.8)
	tween.tween_property(label, "modulate:a", 0.0, 0.8)
	await tween.finished

	label.queue_free()


func animate_enter_play(card: Node) -> void:
	"""Anima la entrada de una carta al campo de juego"""
	var duration = 0.3 / _main.animation_speed

	# Efecto de aparición con escala
	var original_scale = card.scale if card.get("scale") else Vector2.ONE
	card.scale = Vector2.ZERO
	card.modulate.a = 0 if card.get("modulate") else 1.0

	var tween = _main.create_tween()
	tween.set_parallel(true)
	tween.set_ease(Tween.EASE_OUT)
	tween.set_trans(Tween.TRANS_BACK)
	tween.tween_property(card, "scale", original_scale, duration)
	tween.tween_property(card, "modulate:a", 1.0, duration * 0.7)
	await tween.finished

	# Flash de entrada
	if card.get("modulate"):
		tween = _main.create_tween()
		tween.tween_property(card, "modulate", Color(1.3, 1.3, 1.0, 1), 0.1)
		tween.tween_property(card, "modulate", Color.WHITE, 0.15)
		await tween.finished


func show_message(data: Dictionary) -> void:
	"""Muestra un mensaje en la UI"""
	var message = data.get("message", "")
	var duration = data.get("duration", 2.0)

	print("[AnimationQueue] Mensaje: %s" % message)
	# TODO: Conectar con sistema de UI de mensajes


func play_sound(data: Dictionary) -> void:
	"""Reproduce un efecto de sonido"""
	var sound_name = data.get("sound", "")
	# TODO: Conectar con sistema de audio
