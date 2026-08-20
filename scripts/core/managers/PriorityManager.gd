extends Node
## PriorityManager - Gestiona el sistema de prioridad (DAR Sección 5.C3)
## Controla quién puede actuar en la Guerra de Talismanes y ventanas de respuesta

# =============================================================================
# SIGNALS
# =============================================================================
signal priority_changed(player_id: int)
signal priority_passed(player_id: int)
signal both_players_passed  # Ambos pasaron consecutivamente → resolver pila
signal priority_window_opened(player_id: int, context: String)
signal priority_window_closed
signal action_taken(player_id: int, action: Dictionary)

# Pila de efectos (The Stack)
signal effect_added_to_stack(effect: Dictionary)
signal effect_resolving(effect: Dictionary)
signal effect_resolved(effect: Dictionary, result: Dictionary)
signal stack_empty
signal stack_resolving_started
signal stack_resolving_finished

# =============================================================================
# ESTADO DE PRIORIDAD
# =============================================================================
## Jugador que tiene prioridad actualmente
var current_priority_player: int = -1

## Tracking de quién ha pasado prioridad
var player_passed: Array[bool] = [false, false]

## Indica si hay una ventana de prioridad activa
var priority_window_active: bool = false

## Contexto actual de la prioridad (para UI)
var current_context: String = ""

## Acciones válidas en el contexto actual
var valid_actions: Array[String] = []

# =============================================================================
# PILA DE EFECTOS (THE STACK) - DAR Sección 5.C3
# =============================================================================
## Pila de efectos pendientes (LIFO - último en entrar, primero en resolver)
var effect_stack: Array[Dictionary] = []

## Flag para saber si estamos resolviendo la pila
var is_resolving_stack: bool = false

## Tipos de efectos en la pila
enum EffectType {
	TALISMAN,           # Talismán jugado
	ACTIVATED_ABILITY,  # Habilidad activada
	TRIGGERED_ABILITY,  # Habilidad disparada
	CANCEL,             # Efecto de cancelación
	REDIRECT,           # Efecto de redirección
	NULLIFY             # Efecto de anulación
}

# =============================================================================
# CONSTANTES
# =============================================================================
enum PriorityContext {
	NONE,
	GUERRA_TALISMANES,    # 5.C3 - Jugar talismanes y habilidades
	RESPONSE_WINDOW,      # Respuesta a habilidad/efecto
	DISCARD_PHASE,        # Descarte en fase final
	BLOCK_DECLARATION     # Declaración de bloqueadores
}

var current_priority_context: int = PriorityContext.NONE


func _ready() -> void:
	# GameManager es el único conductor de fases (ver consolidación
	# 2026-08-19, docs/audit-2026-08-13.html) — la ventana de Bloqueo/Guerra
	# de Talismanes se abre automáticamente al escuchar su phase_changed.
	if GameManager and GameManager.has_signal("phase_changed"):
		GameManager.phase_changed.connect(_on_phase_changed)


# =============================================================================
# INICIALIZACIÓN DE PRIORIDAD
# =============================================================================
func start_priority_window(context: int, starting_player: int = -1) -> void:
	"""Inicia una ventana de prioridad
	context: PriorityContext enum
	starting_player: -1 para usar regla por defecto según contexto
	"""
	current_priority_context = context
	player_passed = [false, false]
	priority_window_active = true

	# Determinar quién empieza según contexto
	if starting_player >= 0:
		current_priority_player = starting_player
	else:
		current_priority_player = _get_starting_priority_player(context)

	# Configurar acciones válidas según contexto
	valid_actions = _get_valid_actions_for_context(context)
	current_context = _get_context_name(context)

	print("[PriorityManager] Ventana de prioridad: %s - Jugador %d" % [
		current_context, current_priority_player + 1
	])

	emit_signal("priority_window_opened", current_priority_player, current_context)
	emit_signal("priority_changed", current_priority_player)


func _get_starting_priority_player(context: int) -> int:
	"""Determina quién tiene prioridad inicial según el contexto"""
	var active_player = GameManager.active_player_id if GameManager else 0
	var inactive_player = 1 - active_player

	match context:
		PriorityContext.GUERRA_TALISMANES:
			# DAR 5.C3: El defensor (jugador inactivo) tiene prioridad primero
			return inactive_player
		PriorityContext.RESPONSE_WINDOW:
			# El oponente del que activó el efecto
			return inactive_player
		PriorityContext.BLOCK_DECLARATION:
			# El defensor declara bloqueadores
			return inactive_player
		PriorityContext.DISCARD_PHASE:
			# El jugador activo descarta
			return active_player
		_:
			return active_player


func _get_valid_actions_for_context(context: int) -> Array[String]:
	"""Retorna las acciones válidas para un contexto"""
	match context:
		PriorityContext.GUERRA_TALISMANES:
			return ["play_talisman", "activate_ability", "pass"]
		PriorityContext.RESPONSE_WINDOW:
			return ["play_instant", "activate_ability", "cancel", "pass"]
		PriorityContext.BLOCK_DECLARATION:
			return ["declare_blocker", "pass"]
		PriorityContext.DISCARD_PHASE:
			return ["discard", "pass"]
		_:
			return ["pass"]


func _get_context_name(context: int) -> String:
	"""Retorna nombre legible del contexto"""
	match context:
		PriorityContext.GUERRA_TALISMANES:
			return "Guerra de Talismanes"
		PriorityContext.RESPONSE_WINDOW:
			return "Ventana de Respuesta"
		PriorityContext.BLOCK_DECLARATION:
			return "Declarar Bloqueadores"
		PriorityContext.DISCARD_PHASE:
			return "Fase de Descarte"
		_:
			return "Prioridad"


# =============================================================================
# PASO DE PRIORIDAD (DAR 5.C3)
# =============================================================================
func pass_priority() -> void:
	"""El jugador actual pasa su prioridad
	Si ambos pasan consecutivamente, la ventana se cierra y se resuelve
	"""
	if not priority_window_active:
		return

	var passing_player = current_priority_player
	player_passed[passing_player] = true

	print("[PriorityManager] Jugador %d pasa prioridad" % (passing_player + 1))
	emit_signal("priority_passed", passing_player)

	# Verificar si ambos han pasado consecutivamente
	if player_passed[0] and player_passed[1]:
		print("[PriorityManager] Ambos jugadores pasaron consecutivamente")

		# Si hay efectos en la pila, resolver el tope
		if not effect_stack.is_empty():
			await _resolve_top_of_stack()
			# Después de resolver, el jugador activo recupera prioridad
			current_priority_player = GameManager.active_player_id if GameManager else 0
			player_passed = [false, false]
			emit_signal("priority_changed", current_priority_player)
		else:
			# Pila vacía → fase termina
			print("[PriorityManager] Pila vacía → Fase termina")
			emit_signal("both_players_passed")
			_close_priority_window(false)  # false: señal ya emitida arriba, evitar doble disparo
		return

	# Pasar prioridad al otro jugador
	_switch_priority()


func take_action(player_id: int, action: Dictionary) -> bool:
	"""El jugador toma una acción durante su prioridad
	action: {type: String, data: Dictionary}
	Returns: true si la acción fue válida
	"""
	if not priority_window_active:
		push_warning("[PriorityManager] No hay ventana de prioridad activa")
		return false

	if player_id != current_priority_player:
		push_warning("[PriorityManager] No es el turno de prioridad del jugador %d" % (player_id + 1))
		return false

	var action_type = action.get("type", "")

	if action_type not in valid_actions:
		push_warning("[PriorityManager] Acción '%s' no válida en contexto actual" % action_type)
		return false

	# Si el jugador toma una acción (no pasar), resetear los flags de "pasado"
	if action_type != "pass":
		player_passed = [false, false]
		print("[PriorityManager] Jugador %d toma acción: %s" % [player_id + 1, action_type])

		# Añadir a la pila si es un efecto que va a la pila
		if action_type in ["play_talisman", "activate_ability", "cancel", "redirect", "nullify"]:
			var effect = _create_effect_from_action(player_id, action)
			add_to_stack(effect)

		emit_signal("action_taken", player_id, action)

		# Después de una acción, el otro jugador recibe prioridad para responder (Paso D)
		_switch_priority()
		return true

	# Si es "pass", usar la función dedicada
	pass_priority()
	return true


func _switch_priority() -> void:
	"""Cambia la prioridad al otro jugador"""
	var old_player = current_priority_player
	current_priority_player = 1 - current_priority_player

	print("[PriorityManager] Prioridad: Jugador %d → Jugador %d" % [
		old_player + 1, current_priority_player + 1
	])

	emit_signal("priority_changed", current_priority_player)


func _close_priority_window(both_passed: bool) -> void:
	"""Cierra la ventana de prioridad actual"""
	priority_window_active = false
	current_priority_context = PriorityContext.NONE
	current_context = ""
	valid_actions.clear()

	emit_signal("priority_window_closed")

	if both_passed:
		emit_signal("both_players_passed")


# =============================================================================
# INTEGRACIÓN CON FASES
# =============================================================================
func _on_phase_changed(new_phase: int) -> void:
	"""Responde a cambios de fase del TurnManager"""
	var constants = get_node_or_null("/root/Constants")
	if not constants:
		return

	# Cerrar cualquier ventana de prioridad activa al cambiar de fase
	if priority_window_active:
		_close_priority_window(false)

	# Iniciar ventana de prioridad según la fase
	match new_phase:
		Constants.Phase.GUERRA_TALISMANES:
			start_priority_window(PriorityContext.GUERRA_TALISMANES)
		Constants.Phase.BLOQUEO:
			start_priority_window(PriorityContext.BLOCK_DECLARATION)


# =============================================================================
# CONSULTAS
# =============================================================================
func has_priority(player_id: int) -> bool:
	"""Verifica si un jugador tiene prioridad actualmente"""
	return priority_window_active and current_priority_player == player_id


func can_act(player_id: int) -> bool:
	"""Verifica si un jugador puede tomar acciones"""
	return has_priority(player_id)


func get_valid_actions() -> Array[String]:
	"""Retorna las acciones válidas en el contexto actual"""
	return valid_actions.duplicate()


func is_action_valid(action_type: String) -> bool:
	"""Verifica si una acción es válida en el contexto actual"""
	return action_type in valid_actions


# =============================================================================
# UTILIDADES PARA GUERRA DE TALISMANES
# =============================================================================
func start_guerra_talismanes() -> void:
	"""Inicia la Guerra de Talismanes (atajo)"""
	start_priority_window(PriorityContext.GUERRA_TALISMANES)


func start_response_window(triggering_player: int) -> void:
	"""Inicia una ventana de respuesta (el oponente puede responder)"""
	var responding_player = 1 - triggering_player
	start_priority_window(PriorityContext.RESPONSE_WINDOW, responding_player)


func force_close() -> void:
	"""Fuerza el cierre de la ventana de prioridad"""
	if priority_window_active:
		_close_priority_window(false)


# =============================================================================
# PILA DE EFECTOS (THE STACK) - DAR Sección 5.C3
# =============================================================================
func add_to_stack(effect: Dictionary) -> void:
	"""Añade un efecto a la pila
	Resetea la prioridad para permitir respuestas (Paso D)
	"""
	# Asignar ID único al efecto
	effect["stack_id"] = "%d_%d" % [Time.get_ticks_msec(), effect_stack.size()]
	effect["timestamp"] = Time.get_ticks_msec()

	effect_stack.append(effect)

	print("[PriorityManager] Añadido a pila: %s (pila: %d efectos)" % [
		effect.get("name", "Efecto"),
		effect_stack.size()
	])

	emit_signal("effect_added_to_stack", effect)

	# Paso D: Resetear prioridad para permitir respuestas
	player_passed = [false, false]

	# El oponente del que añadió el efecto recibe prioridad
	var controller = effect.get("controller_id", current_priority_player)
	current_priority_player = 1 - controller

	print("[PriorityManager] Ventana de respuesta - Prioridad: Jugador %d" % (current_priority_player + 1))
	emit_signal("priority_changed", current_priority_player)


func _create_effect_from_action(player_id: int, action: Dictionary) -> Dictionary:
	"""Crea un objeto de efecto a partir de una acción"""
	var action_type = action.get("type", "")
	var data = action.get("data", {})

	var effect_type = EffectType.ACTIVATED_ABILITY
	match action_type:
		"play_talisman":
			effect_type = EffectType.TALISMAN
		"activate_ability":
			effect_type = EffectType.ACTIVATED_ABILITY
		"cancel":
			effect_type = EffectType.CANCEL
		"redirect":
			effect_type = EffectType.REDIRECT
		"nullify":
			effect_type = EffectType.NULLIFY

	return {
		"type": effect_type,
		"action_type": action_type,
		"controller_id": player_id,
		"source_card": data.get("card", null),
		"targets": data.get("targets", []),
		"name": data.get("name", action_type),
		"data": data
	}


func _resolve_top_of_stack() -> void:
	"""Resuelve el efecto del tope de la pila (LIFO)
	Si la carta fue anulada, va al cementerio sin ejecutar efecto
	"""
	if effect_stack.is_empty():
		emit_signal("stack_empty")
		return

	is_resolving_stack = true

	# Sacar el último efecto (LIFO - último en entrar, primero en resolver)
	var effect = effect_stack.pop_back()
	var source_card = effect.get("source_card")
	var controller_id = effect.get("controller_id", 0)

	print("[PriorityManager] Resolviendo: %s" % effect.get("name", "Efecto"))
	emit_signal("effect_resolving", effect)

	# Verificar si fue ANULADO → mover carta al cementerio sin ejecutar
	if effect.get("nullified", false):
		print("[PriorityManager] Efecto ANULADO - carta va al Cementerio sin resolver")
		if source_card:
			await _move_card_to_cemetery(source_card, controller_id)
		emit_signal("effect_resolved", effect, {"nullified": true, "moved_to_cemetery": true})
		is_resolving_stack = false
		return

	# Verificar si fue CANCELADO → no se resuelve pero carta no va al cementerio
	if effect.get("cancelled", false):
		print("[PriorityManager] Efecto CANCELADO - no se resuelve")
		emit_signal("effect_resolved", effect, {"cancelled": true})
		is_resolving_stack = false
		return

	# Ejecutar el efecto normalmente
	var result = await _execute_effect(effect)

	# Si es un Talismán, va al cementerio después de resolver
	if effect.get("type") == EffectType.TALISMAN and source_card:
		print("[PriorityManager] Talismán resuelto → va al Cementerio")
		await _move_card_to_cemetery(source_card, controller_id)
		result["moved_to_cemetery"] = true

	emit_signal("effect_resolved", effect, result)

	# Si la pila quedó vacía
	if effect_stack.is_empty():
		emit_signal("stack_empty")

	is_resolving_stack = false


func _move_card_to_cemetery(card: Node, player_id: int) -> void:
	"""Mueve una carta al cementerio"""
	var effect_ctrl = get_node_or_null("/root/EffectController")

	if effect_ctrl and effect_ctrl.has_method("destroy_card"):
		await effect_ctrl.destroy_card(player_id, card)
	else:
		push_warning("[PriorityManager] No se pudo mover carta al cementerio")


func _execute_effect(effect: Dictionary) -> Dictionary:
	"""Ejecuta un efecto de la pila"""
	var result = {
		"success": true,
		"effect_type": effect.get("type", -1)
	}

	var effect_ctrl = get_node_or_null("/root/EffectController")
	var source_card = effect.get("source_card")

	match effect.get("type"):
		EffectType.TALISMAN:
			# Ejecutar efecto del talismán
			if source_card and source_card.has_method("_on_trigger_event"):
				var effect_result = await source_card._on_trigger_event("on_talisman_resolve", effect.data)
				result.merge(effect_result, true)
			print("[PriorityManager] Talismán resuelto: %s" % effect.get("name"))

		EffectType.ACTIVATED_ABILITY:
			# Ejecutar habilidad activada
			if source_card and source_card.has_method("_on_trigger_event"):
				var effect_result = await source_card._on_trigger_event("on_ability_resolve", effect.data)
				result.merge(effect_result, true)
			print("[PriorityManager] Habilidad resuelta: %s" % effect.get("name"))

		EffectType.CANCEL:
			# Cancelar el efecto objetivo en la pila
			var target_stack_id = effect.data.get("target_stack_id", "")
			if _cancel_effect_in_stack(target_stack_id):
				print("[PriorityManager] Efecto cancelado: %s" % target_stack_id)
				result["cancelled_effect"] = target_stack_id
			else:
				result["success"] = false

		EffectType.NULLIFY:
			# Anular efecto → carta va al cementerio sin resolver
			var target_stack_id = effect.data.get("target_stack_id", "")
			if _nullify_effect_in_stack(target_stack_id):
				print("[PriorityManager] Efecto ANULADO: %s → irá al Cementerio" % target_stack_id)
				result["nullified_effect"] = target_stack_id
			else:
				result["success"] = false

		EffectType.REDIRECT:
			# Redirigir objetivo de un efecto
			var target_stack_id = effect.data.get("target_stack_id", "")
			var new_targets = effect.data.get("new_targets", [])
			if _redirect_effect_in_stack(target_stack_id, new_targets):
				print("[PriorityManager] Efecto redirigido: %s" % target_stack_id)
				result["redirected_effect"] = target_stack_id

	return result


func _cancel_effect_in_stack(stack_id: String) -> bool:
	"""Marca un efecto en la pila como cancelado
	Cancelar: el efecto no se resuelve pero la carta NO va al cementerio
	"""
	for effect in effect_stack:
		if effect.get("stack_id") == stack_id:
			effect["cancelled"] = true
			return true
	return false


func _nullify_effect_in_stack(stack_id: String) -> bool:
	"""Marca un efecto en la pila como anulado
	Anular: el efecto no se resuelve Y la carta VA al cementerio
	"""
	for effect in effect_stack:
		if effect.get("stack_id") == stack_id:
			effect["nullified"] = true
			return true
	return false


func _redirect_effect_in_stack(stack_id: String, new_targets: Array) -> bool:
	"""Redirige los objetivos de un efecto en la pila"""
	for effect in effect_stack:
		if effect.get("stack_id") == stack_id:
			effect["targets"] = new_targets
			effect["redirected"] = true
			return true
	return false


func resolve_entire_stack() -> void:
	"""Resuelve toda la pila de efectos (usado cuando ambos pasan con pila llena)"""
	emit_signal("stack_resolving_started")

	while not effect_stack.is_empty():
		await _resolve_top_of_stack()
		# Pequeña pausa entre resoluciones para animaciones
		await get_tree().create_timer(0.2).timeout

	emit_signal("stack_resolving_finished")


# =============================================================================
# CONSULTAS DE LA PILA
# =============================================================================
func get_stack_size() -> int:
	"""Retorna el número de efectos en la pila"""
	return effect_stack.size()


func is_stack_empty() -> bool:
	"""Verifica si la pila está vacía"""
	return effect_stack.is_empty()


func get_top_of_stack() -> Dictionary:
	"""Retorna el efecto en el tope de la pila sin sacarlo"""
	if effect_stack.is_empty():
		return {}
	return effect_stack.back()


func get_stack_contents() -> Array[Dictionary]:
	"""Retorna una copia de la pila completa"""
	return effect_stack.duplicate()


func get_effect_by_id(stack_id: String) -> Dictionary:
	"""Busca un efecto por su ID"""
	for effect in effect_stack:
		if effect.get("stack_id") == stack_id:
			return effect
	return {}


func clear_stack() -> void:
	"""Limpia la pila de efectos"""
	effect_stack.clear()
	emit_signal("stack_empty")
