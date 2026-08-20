extends Node
## TurnManager - Autoload reducido a sus dos responsabilidades reales
## dentro del flujo de turno/fase (DAR Sección 5).
##
## CONSOLIDACIÓN (2026-08-19): este archivo tenía una máquina de fases
## completa propia (change_phase, prioridad, pila de efectos, atacantes/
## bloqueadores declarados, robo y límite de mano) que solo se ejecutaba
## una vez en toda la partida — el arranque del Turno 1 — y nunca volvía a
## dispararse. GameManager._change_phase()/advance_to_phase() es y era el
## único conductor real de fases (ver docs/audit-2026-08-13.html). Esa
## máquina muerta se eliminó junto con active_player_id/current_turn_number,
## que quedaban congelados en el valor del Turno 1 pero se leían como datos
## en vivo desde TriggerSystem (orden APNAP) y AnimationQueue
## (zone_entered_turn) — ahora esos lugares leen GameManager directamente.
## El arranque del Turno 1 ya no pasa por este archivo: GameManager.start_game()
## llama a _start_turn() directamente.
##
## Lo que queda es lo único que tenía llamadores reales:
##   - Sistema de Oro (can_place_oro/on_card_played/_reset_oro_tracking),
##     usado por GoldManager y CardInteractionModule.
##   - Validación de enfermedad de invocación / Furia (can_attack), usada
##     por GameManager.declare_attacker() y DropZone.

# =============================================================================
# SISTEMA DE OROS (DAR Sección 5.B)
# =============================================================================
# Regla 5.B: El oro DEBE ser la primera carta jugada en Vigilia
# Si se juega cualquier otra carta primero, se pierde la oportunidad de poner oro
var oro_placed_this_turn: bool = false      # ¿Ya se puso oro este turno?
var any_card_played_this_turn: bool = false  # ¿Se jugó alguna carta? (bloquea oro)
var oro_chance_lost: bool = false       # ¿Se perdió la oportunidad de poner oro?


func _ready() -> void:
	print("[TurnManager] Inicializado")


func can_place_oro(phase_override: int = -1) -> bool:
	"""Verifica si el jugador puede poner un Oro desde la mano (DAR 5.B)
	Condiciones:
	- Estar en Fase de Vigilia
	- No haber puesto oro este turno
	- No haber jugado ninguna otra carta antes (oro debe ser la primera acción)

	Args:
		phase_override: Si es >= 0, usa esta fase en lugar de GameManager.current_phase
	"""
	var phase = phase_override if phase_override >= 0 else GameManager.current_phase
	if phase != Constants.Phase.VIGILIA:
		return false
	if oro_placed_this_turn:
		return false
	if oro_chance_lost:
		return false
	return true


func on_card_played(card: Node) -> void:
	"""Llamar cuando se juega cualquier carta que NO sea oro (DAR 5.B)
	Esto marca que se perdió la oportunidad de poner oro este turno
	"""
	if GameManager.current_phase != Constants.Phase.VIGILIA:
		return

	if not oro_placed_this_turn and not any_card_played_this_turn:
		# Primera carta jugada y no fue oro → se pierde la oportunidad
		oro_chance_lost = true
		print("[TurnManager] Jugador %d perdió la oportunidad de poner Oro este turno" % (GameManager.active_player_id + 1))

	any_card_played_this_turn = true


func _reset_oro_tracking() -> void:
	"""Resetea el tracking de oros para un nuevo turno"""
	oro_placed_this_turn = false
	any_card_played_this_turn = false
	oro_chance_lost = false


# =============================================================================
# ENFERMEDAD DE INVOCACIÓN / FURIA (DAR 3.1 y 8)
# =============================================================================
func can_attack(ally: Node) -> Dictionary:
	"""Verifica si un Aliado puede atacar (DAR 3.1 y 8)

	Returns: {can_attack: bool, reason: String, has_furia: bool}
	"""
	var result = {"can_attack": true, "reason": "", "has_furia": false}

	# Verificar si entró este turno (enfermedad de invocación)
	var entered_this_turn = ally.get("entered_this_turn") if ally.get("entered_this_turn") != null else false

	if entered_this_turn:
		# Verificar si tiene Furia
		var keyword_mgr = get_node_or_null("/root/KeywordManager")

		if keyword_mgr:
			result.has_furia = keyword_mgr.can_attack_immediately(ally)
		else:
			# Fallback: verificar directamente
			result.has_furia = _has_furia_fallback(ally)

		if not result.has_furia:
			result.can_attack = false
			result.reason = "Entró este turno (necesita Furia para atacar)"

	return result


func _has_furia_fallback(ally: Node) -> bool:
	"""Verificación directa de Furia (fallback si KeywordManager no está)"""
	# Flag directo
	if ally.get("has_furia") == true:
		return true

	# Verificar keywords array
	if ally.get("card_keywords") != null:
		var keywords = ally.card_keywords
		if keywords is Array:
			for kw in keywords:
				if kw is String and kw.to_lower() == "furia":
					return true

	# Verificar texto de habilidad
	if ally.get("card_ability") != null:
		var ability_lower = ally.card_ability.to_lower()
		if "furia" in ability_lower or "puede atacar el turno que entra" in ability_lower:
			return true

	return false
