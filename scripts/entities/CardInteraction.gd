extends RefCounted
class_name CardInteraction
## CardInteraction — Hover, click, drag & drop de una carta.
## Opera sobre el nodo Card via _card. Card.gd reenvía las señales de mouse/gui
## y expone return_to_hand()/_can_declare_attack_drag() como wrappers públicos
## porque otros sistemas (DropZone, GoldManager, CardInteractionModule) los
## llaman directamente sobre la carta.
## Extraído de Card.gd (Fase 4 de reestructuración).

var _card: Card

## Timestamp del último press simple (double_click=false) de ESTA carta —
## distingue el eco genuino (ver on_gui_input) de un doble-click real sobre
## la misma carta, para no emitir card_clicked de más en ese segundo caso.
var _last_plain_click_ms: int = -100000
const DOUBLE_CLICK_ECHO_WINDOW_MS: int = 700


func setup(card: Card) -> void:
	_card = card


func process(_delta: float) -> void:
	"""Red de seguridad contra hover perdido (2026-08-22): mouse_entered/
	mouse_exited de Godot a veces no se disparan para estas cartas —
	reparentado entre contenedores al declarar ataque/agrupar, reflow del
	HBoxContainer de la mano al jugar/robar cartas, o movimiento rápido del
	mouse — dejando una carta con la que 'no se puede targetear ni hacer
	zoom' aunque el mouse esté encima. Se corrige el estado cada frame
	comparando contra la posición real del mouse."""
	if _card.is_dragging or not _card.can_interact:
		return
	# get_global_rect() NO tiene en cuenta la escala del nodo (limitación
	# conocida de Godot) — con pivot_offset != (0,0), escalar en hover corre
	# la posición global real para mantener el pivote fijo, pero este rect
	# sigue siendo el de antes de escalar. Cerca de un borde (2026-08-26,
	# reportado por el usuario: pasaba sobre todo abajo de la carta), ese
	# desfase hacía que el rect "viejo" quedara justo afuera del mouse →
	# se disparaba mouse_exited → la escala volvía a 1 → el rect volvía a
	# su lugar → mouse_entered de nuevo → loop infinito de "salto".
	# get_local_mouse_position() sí invierte la transform completa (posición,
	# escala, pivote), así que no tiene este problema. _has_point() además respeta
	# _click_clip_right cuando las cartas están solapadas (en mano o en escalera de oros).
	var local_mouse = _card.get_local_mouse_position()
	var mouse_over := _card._has_point(local_mouse)
	# Si esta carta es un Arma equipada a un Aliado (wielder), el Aliado que está encima
	# tiene prioridad absoluta sobre el mouse. El Arma solo se activa si el mouse está
	# sobre la parte expuesta del arma (fuera del área del Aliado).
	if mouse_over and _card.wielder != null and is_instance_valid(_card.wielder):
		var mouse_over_wielder := Rect2(Vector2.ZERO, _card.wielder.size).has_point(_card.wielder.get_local_mouse_position())
		if mouse_over_wielder:
			mouse_over = false

	if mouse_over and not _card.is_hovered:
		_on_mouse_entered()
	elif not mouse_over and _card.is_hovered:
		_on_mouse_exited()


func _on_mouse_entered() -> void:
	if not _card.can_interact or _card.is_dragging:
		return

	_card.is_hovered = true
	if _card.hover_effect:
		_card.hover_effect.visible = true

	# Guardar z_index original (si no estaba ya elevado) y ponerlo encima de las demás
	# (Las armas equipadas deben permanecer detrás de su portador en z_index = 0)
	if _card.wielder == null:
		if _card.z_index < 100:
			_card.original_z_index = _card.z_index
		_card.z_index = 100

	# Quitar temporalmente el recorte de click en hover para que responda completa
	if _card.has_method("set_click_clip_right"):
		_card.set_click_clip_right(-1.0)

	_card.emit_signal("card_hovered", _card)

	# Animación de hover (proporcional a base_scale)
	var tween = _card.create_tween()
	tween.tween_property(_card, "scale", _card.base_scale * _card.card_scale_hover, _card.animation_speed)


func _on_mouse_exited() -> void:
	if _card.is_dragging:
		return

	# Si no puede interactuar, no hacer nada (evita resetear escala en inspección)
	if not _card.can_interact:
		return

	_card.is_hovered = false
	if _card.hover_effect:
		_card.hover_effect.visible = false

	# Restaurar z_index y recorte de solapamiento si pertenece a un contenedor con recorte (mano o fila de oros)
	var parent = _card.get_parent()
	if parent and parent.has_method("get_card_clip_right"):
		_card.z_index = _card.get_meta("hand_base_z_index", _card.original_z_index)
		if _card.has_method("set_click_clip_right"):
			_card.set_click_clip_right(parent.get_card_clip_right(_card))
	elif _card.has_meta("gold_click_clip"):
		_card.z_index = _card.original_z_index
		if _card.has_method("set_click_clip_right"):
			_card.set_click_clip_right(_card.get_meta("gold_click_clip", -1.0))
	else:
		_card.z_index = _card.original_z_index

	_card.emit_signal("card_unhovered", _card)

	# Volver a escala normal (proporcional a base_scale)
	var tween = _card.create_tween()
	var target_scale_val = _card.base_scale * (_card.card_scale_selected if _card.is_selected else _card.card_scale_normal)
	tween.tween_property(_card, "scale", target_scale_val, _card.animation_speed)


func on_gui_input(event: InputEvent) -> void:
	# Si es un arma equipada y el mouse está dentro del área del Aliado, ceder el input al Aliado
	if _card.wielder != null and is_instance_valid(_card.wielder):
		var mouse_over_wielder := Rect2(Vector2.ZERO, _card.wielder.size).has_point(_card.wielder.get_local_mouse_position())
		if mouse_over_wielder:
			return
	if event is InputEventMouseButton:
		# Right-click siempre funciona para inspección
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			if Constants.VERBOSE_DIAG_LOGS:
				print("[DIAG] gui_input RIGHT-CLICK llegó a: %s (zona=%s, equipada_en=%s)" % [
					_card.card_name if _card.get("card_name") else "?",
					_card.current_zone if _card.get("current_zone") != null else "?",
					_card.get_parent().name if _card.get_parent() else "sin padre"
				])
			_card.emit_signal("card_right_clicked", _card)
			return

		# 2026-09-14, diagnóstico temporal a pedido del usuario ("no puedo
		# hacer objetivo a los Aliados oponentes, mis Aliados sí") — mismo
		# criterio que el DIAG de right-click de arriba (§10.7): imprime ANTES
		# del corte por can_interact para distinguir "el click nunca llegó aquí"
		# de "llegó pero can_interact era false" o "llegó, pasó, pero el
		# filtro de la habilidad lo rechazó" (ese último caso ya avisa con su
		# propio mensaje en CardInteractionModule._resolve_target_selection()).
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if Constants.VERBOSE_DIAG_LOGS:
				print("[DIAG] gui_input LEFT-CLICK llegó a: %s (owner=%s, controller=%s, can_interact=%s, zona=%s)" % [
					_card.card_name if _card.get("card_name") else "?",
					_card.owner_id if _card.get("owner_id") != null else "?",
					_card.controller_id if _card.get("controller_id") != null else "?",
					str(_card.can_interact),
					_card.current_zone if _card.get("current_zone") != null else "?"
				])

		# Otras interacciones requieren can_interact
		if not _card.can_interact:
			return

		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if event.double_click:
					# Godot decide 'double_click' por tiempo+posición GLOBAL del
					# mouse, no por nodo (2026-08-22): si el jugador acaba de
					# doble-clickear OTRA carta (p.ej. jugar un Arma) y enseguida
					# hace un solo click en ÉSTA (p.ej. el Aliado pedido como
					# portador), Godot puede marcar ese primer press de ESTA
					# carta como double_click=true directamente, sin pasar nunca
					# por un evento con double_click=false — quien solo escucha
					# card_clicked (selección de objetivo) nunca se enteraba.
					# Se emite card_clicked también para que ese listener reciba
					# su evento igual.
					# PERO (2026-08-23): en un doble-click REAL sobre ESTA MISMA carta, el
					# primer press (double_click=false) ya emitio card_clicked -- emitirlo
					# de nuevo aquí duplica el evento y dispara handlers como
					# _declare_attacker() dos veces en paralelo (bug real: un Aliado
					# atacando "teletransportado" al bando rival por la carrera entre
					# ambas llamadas). Solo se emite el eco si NO hubo un press simple
					# reciente de esta misma carta -- cubre el caso huerfano sin
					# duplicar el gesto genuino.
					var is_orphan_double_click := Time.get_ticks_msec() - _last_plain_click_ms > DOUBLE_CLICK_ECHO_WINDOW_MS
					if is_orphan_double_click:
						_card.emit_signal("card_clicked", _card)
					_card.emit_signal("card_double_clicked", _card)
				else:
					# NO llamar _start_drag() inmediatamente -- esperar movimiento
					_card._drag_pending = true
					_card._drag_start_pos = event.position
					_last_plain_click_ms = Time.get_ticks_msec()
					_card.emit_signal("card_clicked", _card)
			else:
				if _card._drag_pending:
					# El usuario soltó sin arrastrar — solo fue un click
					_card._drag_pending = false
				elif _card.is_dragging:
					_end_drag()

	elif event is InputEventMouseMotion:
		if not _card.can_interact:
			return
		if _card._drag_pending:
			var distance = event.position.distance_to(_card._drag_start_pos)
			if distance >= _card.DRAG_THRESHOLD:
				_card._drag_pending = false
				_start_drag(_card._drag_start_pos)
		elif _card.is_dragging:
			_update_drag(event.position)


func can_declare_attack_drag() -> bool:
	"""Verifica si un Aliado en el campo puede arrastrarse para declarar
	ataque.

	DAR (2026-08-28, reemplaza el diseño de 2026-08-23 a pedido del
	usuario): ya no existe el atajo Vigilia→Ataque por declarar un atacante
	directo — ahora hay un botón "Atacar" explícito que termina Vigilia y
	empieza la Batalla Mitológica, y declarar atacantes (con o sin Furia)
	solo es posible una vez que la fase YA es Ataque. Furia deja de ser un
	atajo de fase; sigue siendo el keyword que evita la enfermedad de
	invocación, validado por TurnManager.can_attack()."""
	if _card.card_type != Constants.CardType.ALIADO:
		return false
	if _card.current_zone != Constants.Zone.LINEA_DEFENSA:
		return false
	return GameManager.current_phase == Constants.Phase.ATAQUE


func _start_drag(mouse_pos: Vector2) -> void:
	"""Inicia el arrastre de la carta"""
	if not _card.drag_enabled:
		return
	if _card.wielder != null:
		return
	if _card.current_state != Card.CardState.IN_HAND:
		if not can_declare_attack_drag():
			return

	_card.is_dragging = true
	_card.current_state = Card.CardState.DRAGGING
	_card.drag_offset = mouse_pos
	_card.original_position = _card.global_position  # Guardar posición global antes de top_level
	_card.original_z_index = _card.z_index
	_card.z_index = 100
	# Desacoplar del Container para que global_position no sea sobreescrita por el layout
	_card.top_level = true
	# Godot NO preserva la posición visual al activar top_level: 'position'
	# pasaba a interpretarse como absoluta de pantalla sin ningún ajuste, así
	# que la carta saltaba de inmediato a donde sea que ese valor apuntara
	# (por eso 'se iba a la esquina inferior derecha' apenas se la tomaba).
	# Hay que reaplicar la posición global recién guardada para que el
	# arrastre empiece exactamente donde la carta ya estaba.
	_card.global_position = _card.original_position

	var tween = _card.create_tween()
	tween.tween_property(_card, "scale", Vector2.ONE * _card.card_scale_selected, _card.animation_speed)


func _update_drag(mouse_pos: Vector2) -> void:
	"""Actualiza la posición durante el arrastre"""
	if not _card.is_dragging:
		return

	_card.global_position = _card.get_global_mouse_position() - _card.drag_offset
	_card.emit_signal("card_dragged", _card, _card.global_position)


func _end_drag() -> void:
	"""Finaliza el arrastre"""
	if not _card.is_dragging:
		return

	_card.is_dragging = false
	_card.emit_signal("card_dropped", _card, _card.global_position)

	# Verificar si hay zona de drop válida debajo
	var drop_zone = _get_drop_zone_under_mouse()
	if drop_zone and drop_zone.has_method("on_card_dropped"):
		# La zona de drop maneja la carta
		drop_zone.on_card_dropped(_card)
	else:
		# Regresar a la posición original con animación
		await return_to_hand()


func return_to_hand() -> void:
	"""Regresa la carta a su posición original (mano o campo) con animación"""
	if _card.wielder != null and is_instance_valid(_card.wielder):
		# Arma equipada: anclada a su portador sin top_level
		_card.current_state = Card.CardState.IN_PLAY
		_card.top_level = false
		var slot_idx: int = _card.wielder.equipped_weapons.find(_card) if "equipped_weapons" in _card.wielder else 0
		if slot_idx < 0:
			slot_idx = 0
		var target_pos := Vector2(0.0, Constants.WEAPON_OFFSET_Y + slot_idx * Constants.WEAPON_STACK_STEP_Y)
		var tween = _card.create_tween()
		tween.set_parallel(true)
		tween.tween_property(_card, "position", target_pos, 0.2).set_ease(Tween.EASE_OUT)
		tween.tween_property(_card, "rotation_degrees", 0.0, 0.2).set_ease(Tween.EASE_OUT)
		tween.tween_property(_card, "scale", _card.base_scale, 0.2).set_ease(Tween.EASE_OUT)
		await tween.finished
		_card.position = target_pos
		_card.top_level = false
		_card.z_index = _card.original_z_index
		return

	# Rotación de destino real (2026-08-30): _card.target_rotation es siempre
	# 0.0 (la inclinación de descanso en la mano), pero si la carta está
	# Convertida o Silenciada debe seguir mostrando el giro de 180° — sin esto,
	# cualquier llamada a return_to_hand() (p.ej. el 'soltar' genérico que usa
	# _declare_attacker() al declarar un atacante) pisaba ese giro y la carta
	# 'se enderezaba' sola aunque siguiera convertida/silenciada."""
	var is_opp: bool = (_card.owner_id == 1 or _card.controller_id == 1)
	var is_opp_in_play: bool = is_opp and _card.current_zone in [
		Constants.Zone.RESERVA_ORO, Constants.Zone.ORO_PAGADO,
		Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE, Constants.Zone.LINEA_APOYO
	]
	if _card.current_zone in [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE, Constants.Zone.LINEA_APOYO]:
		# Carta del campo: mantener top_level=true y regresar a su posición guardada en su slot
		_card.current_state = Card.CardState.IN_PLAY
		_card.top_level = true
		var return_pos: Vector2 = _card.get_meta("field_slot_pos", _card.global_position)
		var tween = _card.create_tween()
		tween.set_parallel(true)
		tween.tween_property(_card, "global_position", return_pos, 0.2).set_ease(Tween.EASE_OUT)
		tween.tween_property(_card, "rotation_degrees", 0.0, 0.2).set_ease(Tween.EASE_OUT)
		tween.tween_property(_card, "scale", _card.base_scale, 0.2).set_ease(Tween.EASE_OUT)
		await tween.finished
		_card._refresh_disabled_rotation()
	else:
		# Carta de la mano: animar de vuelta a la posición guardada
		_card.current_state = Card.CardState.IN_HAND
		_card.top_level = false
		var tween = _card.create_tween()
		tween.set_parallel(true)
		tween.tween_property(_card, "global_position", _card.original_position, 0.25).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
		tween.tween_property(_card, "rotation_degrees", _card.target_rotation, 0.25).set_ease(Tween.EASE_OUT)
		tween.tween_property(_card, "scale", _card.base_scale, 0.25).set_ease(Tween.EASE_OUT)
		await tween.finished
		_card._refresh_disabled_rotation()

	_card.z_index = _card.original_z_index


func _get_drop_zone_under_mouse() -> Node:
	"""Detecta la zona de drop más específica bajo el mouse.

	La zona de batalla (LINEA_ATAQUE, ~700x96) está geométricamente contenida
	dentro de la zona de campo (LINEA_DEFENSA, ~800x240) — ver
	SceneSetupModule._setup_drop_zones(). Antes se devolvía la primera zona
	del grupo "drop_zones" que contuviera el mouse, y como field_drop se
	registra antes que battle_drop, soltar una carta cerca del centro del
	tablero (para declarar un atacante) siempre caía en field_drop → volvía
	a pagarse el coste como si se jugara de nuevo. Ahora gana la zona de
	área más chica entre todas las que contienen el punto (la más
	específica), sin depender del orden de registro."""
	var mouse_pos = _card.get_global_mouse_position()
	var best_zone: Node = null
	var best_area := INF

	for zone in _card.get_tree().get_nodes_in_group("drop_zones"):
		if zone is Control:
			var rect: Rect2 = zone.get_global_rect()
			if rect.has_point(mouse_pos):
				var area: float = rect.size.x * rect.size.y
				if area < best_area:
					best_area = area
					best_zone = zone

	return best_zone
