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

# =============================================================================
# ESTADO DE PRIORIDAD
# =============================================================================
## Jugador que tiene prioridad actualmente
var current_priority_player: int = -1

## Tracking de quién ha pasado prioridad
var player_passed: Array[bool] = [false, false]

## Indica si hay una ventana de prioridad activa
var priority_window_active: bool = false

## 2026-09-11: true mientras hay un diálogo reactivo real esperando decisión
## del humano (p.ej. Signo Amarillo, ResponseWindowHandler) — el auto-pase
## "no hay nada que decidir aquí" (PhaseFlowController/ResponseWindowHandler)
## lo respeta para no cerrar la ventana por abajo mientras el diálogo sigue
## abierto esperando un click.
var suppress_human_autopass: bool = false

## Contexto actual de la prioridad (para UI)
var current_context: String = ""

## Acciones válidas en el contexto actual
var valid_actions: Array[String] = []

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

## Contador que sube en CADA start_priority_window() (2026-09-15, bug real
## reportado por el usuario: "se traba en Guerra de Talismanes" — con log
## en vivo confirmando visible=true dos veces seguidas y luego, sin ningún
## click del jugador, priority_window_active=false). Causa real:
## PhaseFlowController._human_pass_after()/_bot_pass_after() son timers de
## 0.2s "fire and forget" — si la ventana para la que se programaron (p.ej.
## la Ventana de Respuesta corta de un trigger 'cuando entra en juego') ya
## se cerró SOLA antes de que el timer termine, el timer sigue vivo y
## dispara tarde sobre lo que sea que esté activo en ESE momento — si para
## entonces ya abrió una ventana NUEVA (p.ej. Guerra de Talismanes) con el
## mismo jugador con prioridad, el timer viejo le pasa la prioridad SIN que
## el jugador haya hecho nada. Los llamadores capturan esta generación al
## programarse y la comparan al disparar — si cambió, la ventana para la
## que se programaron ya no es la actual, no hacen nada.
var _window_generation: int = 0


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
	_window_generation += 1

	# Determinar quién empieza según contexto
	if starting_player >= 0:
		current_priority_player = starting_player
	else:
		current_priority_player = _get_starting_priority_player(context)

	# Configurar acciones válidas según contexto
	valid_actions = _get_valid_actions_for_context(context)
	current_context = _get_context_name(context)

	if Constants.VERBOSE_DIAG_LOGS:
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
			# "Tu tienes la prioridad en Guerra de Talismanes" (2026-08-30,
			# p.ej. Garfio Pirata) — anula la regla DAR 5.C3 por defecto
			# (defensor primero) si algún jugador controla una carta que se
			# la otorgue.
			var override_player := _player_with_guerra_talismanes_priority()
			if override_player >= 0:
				return override_player
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


func _player_with_guerra_talismanes_priority() -> int:
	"""Busca, entre ambos jugadores, si alguno controla una carta (o Arma
	equipada) cuyo texto le otorga la prioridad en Guerra de Talismanes
	(2026-08-30, p.ej. Garfio Pirata: 'tu tienes la prioridad en Guerra de
	Talismanes'). Devuelve el player_id o -1 si nadie la tiene."""
	var main := get_node_or_null("/root/Main")
	if not main:
		return -1
	for player_id in [0, 1]:
		var fields = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo] if player_id == 0 \
			else [main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]
		for field in fields:
			if not field:
				continue
			for card in field.get_children():
				if not is_instance_valid(card):
					continue
				if _card_grants_guerra_talismanes_priority(card):
					return player_id
				var weapons = card.get("equipped_weapons")
				if weapons is Array:
					for w in weapons:
						if is_instance_valid(w) and _card_grants_guerra_talismanes_priority(w):
							return player_id
	return -1


func _card_grants_guerra_talismanes_priority(card: Node) -> bool:
	var text: String = str(card.get("card_ability")) if card.get("card_ability") != null else ""
	return "prioridad en guerra de talismanes" in text.to_lower()


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

	if Constants.VERBOSE_DIAG_LOGS:
		print("[PriorityManager] Jugador %d pasa prioridad" % (passing_player + 1))
	emit_signal("priority_passed", passing_player)

	# Verificar si ambos han pasado consecutivamente (DAR 5.C3: pila vacía →
	# la fase termina — este motor no usa una pila de efectos real en
	# PriorityManager, ver ActionPipeline para la pila LIFO que sí se usa).
	if player_passed[0] and player_passed[1]:
		if Constants.VERBOSE_DIAG_LOGS:
			print("[PriorityManager] Ambos jugadores pasaron consecutivamente → Fase termina")
		emit_signal("both_players_passed")
		_close_priority_window(false)  # false: señal ya emitida arriba, evitar doble disparo
		return

	# Pasar prioridad al otro jugador
	_switch_priority()


func _switch_priority() -> void:
	"""Cambia la prioridad al otro jugador"""
	var old_player = current_priority_player
	current_priority_player = 1 - current_priority_player

	if Constants.VERBOSE_DIAG_LOGS:
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


