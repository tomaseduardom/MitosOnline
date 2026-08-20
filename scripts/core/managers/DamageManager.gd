extends Node
## DamageManager - Sistema unificado de daño (DAR 2025)
##
## Maneja:
## - Daño de combate (con modificadores de fuerza)
## - Daño directo (habilidades, talismanes)
## - Detección de derrota por mazo vacío
## - Prevención y reducción de daño

# =============================================================================
# SEÑALES
# =============================================================================
signal damage_dealt(target_id: int, amount: int, actual: int, type: String)
signal damage_prevented(target_id: int, amount: int, source: Dictionary)
signal damage_reduced(target_id: int, original: int, reduced: int, source: Dictionary)
signal lethal_damage(target_id: int, card: Node, damage: int)

## Derrota
signal game_over(winner_id: int, loser_id: int, reason: String)
signal deck_empty(player_id: int)

## Combate
signal combat_damage_calculated(attacker: Node, defender: Node, damage: int)
signal combat_damage_applied(attacker: Node, target_id: int, damage: int)

# =============================================================================
# ENUMS
# =============================================================================
enum DamageType {
	COMBAT,         # Daño de combate (usa Fuerza)
	DIRECT,         # Daño directo (habilidades)
	ABILITY,        # Daño por habilidad de carta
	EFFECT,         # Daño por efecto (talismán, tótem)
	UNBLOCKABLE,    # Daño que no puede ser prevenido
	SELF            # Autodaño (costes alternativos)
}

enum DamageTarget {
	CASTLE,         # Daño al Castillo (mazo)
	CARD,           # Daño a una carta
	PLAYER          # Daño al jugador (vida, si aplica)
}

const TYPE_NAMES: Dictionary = {
	DamageType.COMBAT: "Combate",
	DamageType.DIRECT: "Directo",
	DamageType.ABILITY: "Habilidad",
	DamageType.EFFECT: "Efecto",
	DamageType.UNBLOCKABLE: "Imbloqueable",
	DamageType.SELF: "Autodaño"
}

# =============================================================================
# ESTADO
# =============================================================================
## Modificadores de daño activos: [{source, modifier, type, expires_at}]
var _damage_modifiers: Array[Dictionary] = []

## Prevenciones activas: [{source, amount, type, one_shot}]
var _damage_preventions: Array[Dictionary] = []

## Escudos de daño: {player_id: amount}
var _damage_shields: Dictionary = {}

## Tracking de daño por turno
var _damage_this_turn: Dictionary = {0: 0, 1: 0}
var _combat_damage_this_turn: Dictionary = {0: 0, 1: 0}

# =============================================================================
# REFERENCIAS
# =============================================================================
var _game_manager: Node = null
var _game_board: Node = null
var _action_module: Node = null
var _combat_log: Node = null
var _trigger_system: Node = null


func _ready() -> void:
	call_deferred("_get_references")
	call_deferred("_connect_signals")
	print("[DamageManager] Inicializado")


func _get_references() -> void:
	# _game_board queda siempre null: no existe autoload '/root/GameBoard'
	# ni método GameManager.get_game_board() (era el GameBoard.gd huérfano,
	# eliminado). _apply_damage_to_castle() (única consumidora real de
	# _get_board()) no la llama nadie hoy — el daño de combate real lo
	# resuelve BattleManager, que ya usa CardManager.
	_game_manager = get_node_or_null("/root/GameManager")
	_action_module = get_node_or_null("/root/ActionModule")
	_combat_log = get_node_or_null("/root/CombatLog")
	_trigger_system = get_node_or_null("/root/TriggerSystem")


func _connect_signals() -> void:
	# GameManager es el único conductor de turnos (ver consolidación 2026-08-19).
	if GameManager and GameManager.has_signal("turn_ended"):
		GameManager.turn_ended.connect(_on_turn_ended)


# =============================================================================
# FUNCIÓN PRINCIPAL: apply_damage()
# =============================================================================
func apply_damage(target, amount: int, type: int = DamageType.DIRECT, context: Dictionary = {}) -> Dictionary:
	"""Aplica daño unificado a un objetivo

	Mueve cartas del Castillo al Cementerio según el daño.
	Detecta derrota si el mazo queda vacío.

	Args:
		target: ID del jugador (int) o nodo de carta (Node)
		amount: Cantidad de daño base
		type: DamageType enum
		context: {source, attacker, can_prevent, instance_x, etc.}

	Returns:
		{success, actual_damage, cards_milled, prevented, reduced, defeated}
	"""
	var result = {
		"success": true,
		"requested": amount,
		"actual_damage": 0,
		"cards_milled": [],
		"prevented": 0,
		"reduced": 0,
		"defeated": false,
		"partial": false,
		"type": type,
		"type_name": TYPE_NAMES.get(type, "Desconocido")
	}

	if amount <= 0:
		return result

	var target_id: int = -1
	var target_card: Node = null
	var target_type: int = DamageTarget.CASTLE

	# ─────────────────────────────────────────────────────────────────────────
	# DETERMINAR OBJETIVO
	# ─────────────────────────────────────────────────────────────────────────
	if target is int:
		target_id = target
		target_type = DamageTarget.CASTLE
	elif target is Node:
		target_card = target
		target_type = DamageTarget.CARD
		# Obtener controlador de la carta
		if target_card.has_method("get_controller"):
			target_id = target_card.get_controller()
		else:
			var ctrl = target_card.get("controller_id")
			target_id = ctrl if ctrl != null else (target_card.get("owner_id") if target_card.get("owner_id") != null else 0)
	else:
		result.success = false
		result.error = "invalid_target"
		return result

	var working_damage = amount

	# ─────────────────────────────────────────────────────────────────────────
	# PASO 1: MODIFICADORES DE COMBATE (Solo para COMBAT)
	# ─────────────────────────────────────────────────────────────────────────
	if type == DamageType.COMBAT:
		var attacker = context.get("attacker")
		if attacker:
			working_damage = _apply_combat_modifiers(attacker, working_damage, context)
			emit_signal("combat_damage_calculated", attacker, target, working_damage)

	# ─────────────────────────────────────────────────────────────────────────
	# PASO 2: PREVENCIÓN DE DAÑO (excepto UNBLOCKABLE)
	# ─────────────────────────────────────────────────────────────────────────
	if type != DamageType.UNBLOCKABLE and context.get("can_prevent", true):
		var prevention = _apply_damage_prevention(target_id, working_damage, type, context)
		result.prevented = prevention.prevented
		working_damage = prevention.remaining

		if prevention.prevented > 0:
			emit_signal("damage_prevented", target_id, prevention.prevented, context.get("source", {}))

	# ─────────────────────────────────────────────────────────────────────────
	# PASO 3: REDUCCIÓN DE DAÑO
	# ─────────────────────────────────────────────────────────────────────────
	var reduction = _apply_damage_reduction(target_id, working_damage, type, context)
	result.reduced = reduction.reduced
	working_damage = reduction.remaining

	if reduction.reduced > 0:
		emit_signal("damage_reduced", target_id, amount, working_damage, context.get("source", {}))

	# ─────────────────────────────────────────────────────────────────────────
	# PASO 4: ESCUDOS DE DAÑO
	# ─────────────────────────────────────────────────────────────────────────
	if _damage_shields.has(target_id) and _damage_shields[target_id] > 0:
		var shield = _damage_shields[target_id]
		var absorbed = mini(shield, working_damage)
		_damage_shields[target_id] -= absorbed
		working_damage -= absorbed
		result.reduced += absorbed

		_log_action("shield", "Escudo absorbe %d daño (restante: %d)" % [absorbed, _damage_shields[target_id]], {
			"player": target_id,
			"absorbed": absorbed
		})

	# ─────────────────────────────────────────────────────────────────────────
	# PASO 5: APLICAR DAÑO FINAL
	# ─────────────────────────────────────────────────────────────────────────
	if working_damage > 0:
		match target_type:
			DamageTarget.CASTLE:
				result = await _apply_damage_to_castle(target_id, working_damage, result, context)

			DamageTarget.CARD:
				result = await _apply_damage_to_card(target_card, working_damage, result, context)

	result.actual_damage = working_damage

	# ─────────────────────────────────────────────────────────────────────────
	# TRACKING Y LOGGING
	# ─────────────────────────────────────────────────────────────────────────
	_damage_this_turn[target_id] = _damage_this_turn.get(target_id, 0) + result.actual_damage
	if type == DamageType.COMBAT:
		_combat_damage_this_turn[target_id] = _combat_damage_this_turn.get(target_id, 0) + result.actual_damage

	emit_signal("damage_dealt", target_id, amount, result.actual_damage, TYPE_NAMES.get(type, ""))

	# Log detallado
	_log_damage_result(target_id, result, type, context)

	# ─────────────────────────────────────────────────────────────────────────
	# TRIGGERS POST-DAÑO
	# ─────────────────────────────────────────────────────────────────────────
	if _trigger_system and result.actual_damage > 0:
		await _trigger_system.trigger_event("on_damage_dealt", {
			"target_id": target_id,
			"amount": result.actual_damage,
			"type": type,
			"source": context.get("source"),
			"attacker": context.get("attacker")
		})

	return result


# =============================================================================
# APLICAR DAÑO AL CASTILLO (Mazo)
# =============================================================================
func _apply_damage_to_castle(player_id: int, amount: int, result: Dictionary, context: Dictionary) -> Dictionary:
	"""Aplica daño al Castillo moviendo cartas al Cementerio

	DAR 2025: Cada punto de daño = 1 carta del tope del Castillo al Cementerio
	Si el mazo se vacía, el jugador PIERDE.
	"""
	var board = _get_board()
	if not board:
		result.success = false
		result.error = "no_board"
		return result

	var deck = board.get_cards_in_zone(Constants.Zone.CASTILLO, player_id)
	var actual_damage = mini(amount, deck.size())

	print("[DamageManager] ═══ DAÑO AL CASTILLO ═══")
	print("[DamageManager] Jugador %d recibe %d daño (mazo: %d cartas)" % [
		player_id + 1, amount, deck.size()
	])

	# Verificar si es parcial
	if actual_damage < amount:
		result.partial = true
		_log_partial_damage(amount, actual_damage, player_id)

	# Mover cartas una por una
	for i in range(actual_damage):
		if deck.is_empty():
			break

		var card = deck.pop_front()

		# Revelar carta antes de enviar al cementerio
		if card.has_method("set_face_up"):
			card.set_face_up(true)
		else:
			card.esta_oculta = false

		board.move_card(card, Constants.Zone.CEMENTERIO, player_id)
		result.cards_milled.append(card)

		# Trigger por carta enviada al cementerio
		if _trigger_system:
			_trigger_system.queue_trigger("on_card_milled_by_damage", {
				"card": card,
				"player_id": player_id,
				"damage_index": i,
				"source": context.get("source")
			})

	result.actual_damage = actual_damage

	print("[DamageManager] → %d cartas enviadas al Cementerio" % actual_damage)

	# ─────────────────────────────────────────────────────────────────────────
	# DETECCIÓN DE DERROTA: Mazo vacío
	# ─────────────────────────────────────────────────────────────────────────
	var remaining_deck = board.get_cards_in_zone(Constants.Zone.CASTILLO, player_id)
	if remaining_deck.size() == 0:
		result.defeated = true
		var winner_id = 1 - player_id

		print("[DamageManager] ╔═══════════════════════════════════════╗")
		print("[DamageManager] ║  ☠ DERROTA: Jugador %d sin cartas    ║" % (player_id + 1))
		print("[DamageManager] ║  🏆 VICTORIA: Jugador %d              ║" % (winner_id + 1))
		print("[DamageManager] ╚═══════════════════════════════════════╝")

		emit_signal("deck_empty", player_id)
		emit_signal("game_over", winner_id, player_id, "deck_empty")

		# Notificar al GameManager
		if _game_manager and _game_manager.has_method("end_game"):
			_game_manager.end_game(winner_id, "deck_empty")

		# Log
		_log_action("game_over", "🏆 Jugador %d GANA - Jugador %d se quedó sin cartas" % [
			winner_id + 1, player_id + 1
		], {
			"winner": winner_id,
			"loser": player_id,
			"reason": "deck_empty"
		})

	return result


# =============================================================================
# APLICAR DAÑO A CARTA
# =============================================================================
func _apply_damage_to_card(card: Node, amount: int, result: Dictionary, context: Dictionary) -> Dictionary:
	"""Aplica daño a una carta en juego

	Si el daño >= resistencia de la carta, se destruye.
	Algunos tipos de carta acumulan daño marcado.
	"""
	if not card:
		result.success = false
		return result

	var card_data: Dictionary = card.get("card_data") if card.get("card_data") else {}
	var card_name = card_data.get("nombre", card_data.get("name", "???"))
	var resistance = _get_card_resistance(card)
	var dmg_marked = card.get("damage_marked")
	var current_damage: int = dmg_marked if dmg_marked != null else 0

	print("[DamageManager] Daño a carta: %s (%d → %d, resistencia: %d)" % [
		card_name, current_damage, current_damage + amount, resistance
	])

	# Marcar daño en la carta
	var total_damage = current_damage + amount
	card.set("damage_marked", total_damage)

	result.actual_damage = amount

	# Verificar daño letal
	if total_damage >= resistance:
		var ctrl = card.get("controller_id")
		emit_signal("lethal_damage", ctrl if ctrl != null else 0, card, total_damage)

		# La carta se destruye
		if _action_module and _action_module.has_method("destroy"):
			var destroy_context = {
				"source": context.get("source"),
				"cause": "damage",
				"damage_amount": total_damage
			}
			await _action_module.destroy([card], context.get("source"), true, false)

		_log_action("lethal", "%s destruido por %d daño" % [card_name, total_damage], {
			"card": card_name,
			"damage": total_damage
		})

	return result


# =============================================================================
# MODIFICADORES DE COMBATE
# =============================================================================
func _apply_combat_modifiers(attacker: Node, base_damage: int, context: Dictionary) -> int:
	"""Aplica modificadores de fuerza para daño de combate

	Considera:
	- Fuerza base del atacante
	- Buffs/debuffs activos
	- Armas equipadas
	- Modificadores temporales
	"""
	var damage = base_damage

	# Obtener fuerza del atacante
	var attacker_force = _get_card_force(attacker)
	if attacker_force > 0:
		damage = attacker_force

	# Aplicar modificadores activos
	for mod in _damage_modifiers:
		if mod.get("type") == DamageType.COMBAT or mod.get("type") == -1:  # -1 = all
			var source = mod.get("source")

			# Verificar si el modificador aplica a este atacante
			if mod.get("attacker_filter"):
				if not _modifier_applies_to(attacker, mod.attacker_filter):
					continue

			var modifier_value = mod.get("modifier", 0)
			var modifier_type = mod.get("modifier_type", "add")

			match modifier_type:
				"add":
					damage += modifier_value
				"multiply":
					damage = int(damage * modifier_value)
				"set":
					damage = modifier_value

	# Mínimo 0 daño
	damage = maxi(0, damage)

	if damage != base_damage:
		print("[DamageManager] Daño de combate modificado: %d → %d" % [base_damage, damage])

	return damage


func _get_card_force(card: Node) -> int:
	"""Obtiene la fuerza de una carta (para combate)"""
	if not card:
		return 0

	# Intentar obtener fuerza de varias formas
	if card.has_method("get_force"):
		return card.get_force()

	if card.has_method("get_current_force"):
		return card.get_current_force()

	var card_data: Dictionary = card.get("card_data") if card.get("card_data") else {}

	# Fuerza modificada > Fuerza base
	var force = card.get("current_force")
	if force == null:
		force = card_data.get("fuerza", card_data.get("force", 0))

	return int(force) if force else 0


func _get_card_resistance(card: Node) -> int:
	"""Obtiene la resistencia de una carta"""
	if not card:
		return 0

	if card.has_method("get_resistance"):
		return card.get_resistance()

	var card_data: Dictionary = card.get("card_data") if card.get("card_data") else {}
	var resistance = card.get("current_resistance")
	if resistance == null:
		resistance = card_data.get("resistencia", card_data.get("resistance", 1))

	return int(resistance) if resistance else 1


# =============================================================================
# PREVENCIÓN DE DAÑO
# =============================================================================
func _apply_damage_prevention(player_id: int, damage: int, type: int, context: Dictionary) -> Dictionary:
	"""Aplica prevenciones de daño activas"""
	var result = {"prevented": 0, "remaining": damage}

	var to_remove: Array[int] = []

	for i in range(_damage_preventions.size()):
		var prevention = _damage_preventions[i]

		# Verificar si aplica a este tipo de daño
		if prevention.get("type") != -1 and prevention.get("type") != type:
			continue

		# Verificar si aplica a este jugador
		if prevention.get("player_id", -1) != -1 and prevention.get("player_id") != player_id:
			continue

		var prevent_amount = prevention.get("amount", 0)

		if prevent_amount == -1:
			# Prevención total
			result.prevented += result.remaining
			result.remaining = 0
		else:
			var actual_prevent = mini(prevent_amount, result.remaining)
			result.prevented += actual_prevent
			result.remaining -= actual_prevent

			# Reducir el pool de prevención
			prevention["amount"] -= actual_prevent

		# Marcar para remover si se agotó o es one-shot
		if prevention.get("one_shot", false) or prevention.get("amount", 0) <= 0:
			to_remove.append(i)

		if result.remaining <= 0:
			break

	# Remover prevenciones usadas (en orden inverso)
	to_remove.reverse()
	for idx in to_remove:
		_damage_preventions.remove_at(idx)

	return result


func _apply_damage_reduction(player_id: int, damage: int, type: int, context: Dictionary) -> Dictionary:
	"""Aplica reducciones de daño (diferentes a prevención)"""
	var result = {"reduced": 0, "remaining": damage}

	# Buscar modificadores de reducción
	for mod in _damage_modifiers:
		if mod.get("reduction", false) and mod.get("player_id", -1) in [-1, player_id]:
			var reduce_amount = mod.get("amount", 0)
			var actual_reduce = mini(reduce_amount, result.remaining)
			result.reduced += actual_reduce
			result.remaining -= actual_reduce

	result.remaining = maxi(0, result.remaining)

	return result


# =============================================================================
# API DE MODIFICADORES
# =============================================================================
func add_damage_modifier(source: Node, modifier: int, modifier_type: String = "add", damage_type: int = -1, duration: int = -1) -> int:
	"""Agrega un modificador de daño

	Args:
		source: Carta/efecto que otorga el modificador
		modifier: Valor del modificador
		modifier_type: "add", "multiply", "set"
		damage_type: Tipo de daño afectado (-1 = todos)
		duration: Turnos de duración (-1 = permanente)

	Returns: ID del modificador
	"""
	var mod = {
		"id": _damage_modifiers.size(),
		"source": source,
		"modifier": modifier,
		"modifier_type": modifier_type,
		"type": damage_type,
		"duration": duration,
		"turns_remaining": duration
	}

	_damage_modifiers.append(mod)

	print("[DamageManager] Modificador añadido: %+d (%s)" % [modifier, modifier_type])

	return mod.id


func remove_damage_modifier(mod_id: int) -> bool:
	"""Remueve un modificador por ID"""
	for i in range(_damage_modifiers.size()):
		if _damage_modifiers[i].get("id") == mod_id:
			_damage_modifiers.remove_at(i)
			return true
	return false


func add_damage_prevention(player_id: int, amount: int, damage_type: int = -1, one_shot: bool = false, source: Node = null) -> void:
	"""Agrega prevención de daño

	Args:
		player_id: Jugador protegido (-1 = ambos)
		amount: Cantidad a prevenir (-1 = todo)
		damage_type: Tipo de daño (-1 = todos)
		one_shot: Si se consume en un uso
		source: Fuente de la prevención
	"""
	_damage_preventions.append({
		"player_id": player_id,
		"amount": amount,
		"type": damage_type,
		"one_shot": one_shot,
		"source": source
	})

	print("[DamageManager] Prevención añadida: %d para J%d" % [
		amount if amount >= 0 else -1, player_id + 1 if player_id >= 0 else 0
	])


func add_damage_shield(player_id: int, amount: int) -> void:
	"""Agrega escudo de daño a un jugador"""
	_damage_shields[player_id] = _damage_shields.get(player_id, 0) + amount
	print("[DamageManager] Escudo +%d para J%d (total: %d)" % [
		amount, player_id + 1, _damage_shields[player_id]
	])


func get_damage_shield(player_id: int) -> int:
	"""Obtiene el escudo de daño actual"""
	return _damage_shields.get(player_id, 0)


# =============================================================================
# DAÑO DE COMBATE SIMPLIFICADO
# =============================================================================
func apply_combat_damage(attacker: Node, defender_id: int, context: Dictionary = {}) -> Dictionary:
	"""Aplica daño de combate de un atacante

	Calcula automáticamente el daño basado en la fuerza del atacante.
	"""
	var force = _get_card_force(attacker)

	var ctx = context.duplicate()
	ctx["attacker"] = attacker
	ctx["source"] = attacker

	var attacker_data: Dictionary = attacker.get("card_data") if attacker.get("card_data") else {}
	var attacker_name = attacker_data.get("nombre", attacker_data.get("name", "???"))

	print("[DamageManager] Daño de combate: %s (Fuerza %d) → Jugador %d" % [
		attacker_name, force, defender_id + 1
	])

	var result = await apply_damage(defender_id, force, DamageType.COMBAT, ctx)

	emit_signal("combat_damage_applied", attacker, defender_id, result.actual_damage)

	return result


func apply_combat_damage_to_card(attacker: Node, defender: Node, context: Dictionary = {}) -> Dictionary:
	"""Aplica daño de combate entre dos cartas"""
	var force = _get_card_force(attacker)

	var ctx = context.duplicate()
	ctx["attacker"] = attacker
	ctx["source"] = attacker

	return await apply_damage(defender, force, DamageType.COMBAT, ctx)


# =============================================================================
# DAÑO CON X VARIABLE
# =============================================================================
func apply_x_damage(target_id: int, instance_x: int, type: int = DamageType.ABILITY, context: Dictionary = {}) -> Dictionary:
	"""Aplica daño donde la cantidad es X

	Args:
		target_id: ID del jugador objetivo
		instance_x: Valor de X elegido
		type: Tipo de daño
		context: Contexto adicional

	Returns: Resultado del daño
	"""
	var ctx = context.duplicate()
	ctx["instance_x"] = instance_x
	ctx["is_x_damage"] = true

	print("[DamageManager] Daño X=%d a Jugador %d" % [instance_x, target_id + 1])

	var result = await apply_damage(target_id, instance_x, type, ctx)

	# Log especial para daño X
	if _combat_log and _combat_log.has_method("log_x_effect_result"):
		var target_name = "Jugador %d" % (target_id + 1)
		_combat_log.log_x_effect_result("damage", instance_x, result.actual_damage, target_name, result.success)

	return result


# =============================================================================
# UTILIDADES
# =============================================================================
func _get_board() -> Node:
	"""Obtiene referencia al tablero"""
	if _game_board:
		return _game_board

	if _game_manager:
		if _game_manager.has_method("get_game_board"):
			return _game_manager.get_game_board()
		return _game_manager.get("_game_board")

	return null


func _modifier_applies_to(card: Node, filter: Dictionary) -> bool:
	"""Verifica si un modificador aplica a una carta"""
	if filter.is_empty():
		return true

	var card_data: Dictionary = card.get("card_data") if card.get("card_data") else {}

	# Filtro por tipo
	if filter.has("card_type"):
		if card_data.get("tipo") != filter.card_type:
			return false

	# Filtro por raza
	if filter.has("race"):
		if card_data.get("raza") != filter.race:
			return false

	# Filtro por nombre
	if filter.has("name"):
		var name = card_data.get("nombre", card_data.get("name", ""))
		if name != filter.name:
			return false

	return true


func _log_action(action_type: String, message: String, data: Dictionary = {}) -> void:
	"""Envía entrada al CombatLog"""
	if _combat_log and _combat_log.has_method("add_entry"):
		_combat_log.add_entry(action_type, message, data)


func _log_damage_result(target_id: int, result: Dictionary, type: int, context: Dictionary) -> void:
	"""Loguea el resultado del daño"""
	var type_name = TYPE_NAMES.get(type, "Desconocido")
	var target_str = "Jugador %d" % (target_id + 1)

	var message = ""
	if result.prevented > 0 or result.reduced > 0:
		message = "Daño %s a %s: %d (-%d prev, -%d red) = %d efectivo" % [
			type_name, target_str, result.requested,
			result.prevented, result.reduced, result.actual_damage
		]
	else:
		message = "Daño %s a %s: %d" % [type_name, target_str, result.actual_damage]

	if result.partial:
		message += " [color=#FFC107](parcial)[/color]"

	_log_action("damage", message, {
		"target": target_id,
		"type": type_name,
		"requested": result.requested,
		"actual": result.actual_damage,
		"prevented": result.prevented,
		"reduced": result.reduced,
		"partial": result.partial
	})


func _log_partial_damage(requested: int, actual: int, player_id: int) -> void:
	"""Loguea daño parcial (mazo con menos cartas que daño)"""
	if _combat_log and _combat_log.has_method("log_partial_effect"):
		_combat_log.log_partial_effect("damage", requested, actual, "Jugador %d" % (player_id + 1), {
			"reason": "deck_size"
		})


func _on_turn_ended(player_id: int) -> void:
	"""Callback al terminar turno - limpiar modificadores temporales"""
	# Reducir duración de modificadores
	var to_remove: Array[int] = []
	for i in range(_damage_modifiers.size()):
		var mod = _damage_modifiers[i]
		if mod.get("turns_remaining", -1) > 0:
			mod["turns_remaining"] -= 1
			if mod["turns_remaining"] <= 0:
				to_remove.append(i)

	to_remove.reverse()
	for idx in to_remove:
		_damage_modifiers.remove_at(idx)

	# Resetear tracking de daño por turno
	_damage_this_turn = {0: 0, 1: 0}
	_combat_damage_this_turn = {0: 0, 1: 0}


# =============================================================================
# API PÚBLICA DE CONSULTA
# =============================================================================
func get_damage_this_turn(player_id: int) -> int:
	"""Obtiene el daño total recibido este turno"""
	return _damage_this_turn.get(player_id, 0)


func get_combat_damage_this_turn(player_id: int) -> int:
	"""Obtiene el daño de combate recibido este turno"""
	return _combat_damage_this_turn.get(player_id, 0)


func get_deck_size(player_id: int) -> int:
	"""Obtiene el tamaño actual del mazo de un jugador. Antes usaba
	_get_board() (siempre null — dependía del GameBoard.gd huérfano) y
	devolvía 0 SIEMPRE, lo que hacía que check_defeat_condition() pudiera
	declarar derrota con el mazo lleno. CardManager lleva la cuenta real."""
	var card_mgr = get_node_or_null("/root/CardManager")
	if card_mgr and card_mgr.has_method("get_deck_count"):
		return card_mgr.get_deck_count(player_id)
	return 0


func is_player_alive(player_id: int) -> bool:
	"""Verifica si un jugador sigue en el juego (tiene cartas en mazo)"""
	return get_deck_size(player_id) > 0


func check_defeat_condition(player_id: int) -> bool:
	"""Verifica y dispara derrota si el mazo está vacío

	Llamar después de cualquier operación que mueva cartas del Castillo.
	"""
	if get_deck_size(player_id) == 0:
		var winner_id = 1 - player_id

		emit_signal("deck_empty", player_id)
		emit_signal("game_over", winner_id, player_id, "deck_empty")

		if _game_manager and _game_manager.has_method("end_game"):
			_game_manager.end_game(winner_id, "deck_empty")

		return true

	return false
