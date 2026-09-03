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


func can_place_oro(phase_override: int = -1, card: Node = null) -> bool:
	"""Verifica si el jugador puede poner un Oro desde la mano (DAR 5.B)
	Condiciones:
	- Estar en Fase de Vigilia
	- No haber puesto oro este turno
	- No haber jugado ninguna otra carta antes (oro debe ser la primera acción),
	  SALVO que la propia carta traiga una excepción explícita a esa regla
	  (ver ignores_oro_chance_lost()).

	Args:
		phase_override: Si es >= 0, usa esta fase en lugar de GameManager.current_phase
		card: la carta que se está por colocar como Oro (opcional) — solo se
			usa para chequear si tiene la excepción de texto propia.
	"""
	var phase = phase_override if phase_override >= 0 else GameManager.current_phase
	if phase != Constants.Phase.VIGILIA:
		return false
	if oro_placed_this_turn:
		return false
	if oro_chance_lost and not ignores_oro_chance_lost(card):
		return false
	return true


func ignores_oro_chance_lost(card: Node) -> bool:
	"""'En tu Vigilia, si no pusiste Oros en juego este turno, ponlo de tu
	mano en tu Reserva' (2026-08-30, p.ej. Infernum Vox) — a diferencia de
	la regla general (DAR 5.B: el Oro debe ser la PRIMERA carta jugada; si
	juegas cualquier otra cosa antes, se pierde la oportunidad para el resto
	del turno), esta carta se puede colocar como Oro en cualquier momento
	de tu Vigilia mientras tú mismo no hayas puesto un Oro todavía este
	turno — no le importa si ya jugaste otra carta antes. Es una EXCEPCIÓN
	puntual de ESTA carta, no el comportamiento general, así que se detecta
	por texto en vez de agregar un flag nuevo al motor."""
	if not card or card.get("card_data") == null:
		return false
	var habilidad: String = str(card.card_data.get("habilidad", "")).to_lower()
	return "si no pusiste oros en juego este turno" in habilidad


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
		result.has_furia = KeywordManager.can_attack_immediately(ally)

		if not result.has_furia:
			result.can_attack = false
			result.reason = "no puede atacar aún — no ha pasado por tu Agrupación (sin Furia)"

	return result


# _has_furia_fallback() se eliminó acá (2026-08-28, "módulos gordos" punto
# 1): KeywordManager es autoload — siempre existe, esta rama nunca corría.
