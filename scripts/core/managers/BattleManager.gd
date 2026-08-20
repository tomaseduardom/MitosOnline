extends Node
## BattleManager - Gestiona el combate y asignación de daño (DAR Sección 5.C4)
## Calcula el resultado de combate entre atacantes y bloqueadores

# =============================================================================
# SIGNALS
# =============================================================================
signal combat_started
signal combat_pair_resolved(attacker: Node, blocker: Node, result: Dictionary)
signal attacker_destroyed(attacker: Node, by_blocker: Node)
signal blocker_destroyed(blocker: Node, by_attacker: Node)
signal both_destroyed(attacker: Node, blocker: Node)
signal unblocked_damage(attacker: Node, damage: int)
signal damage_to_castle(player_id: int, total_damage: int, sources: Array)
signal on_damage_assigned(total_damage: int)  # Emitida con el daño total calculado
signal destruction_prevented(card: Node, reason: String)  # Carta salvada por Indestructible
signal player_defeated(player_id: int)  # Jugador perdió por Castillo vacío (DAR 2.1)
signal card_milled_as_damage(player_id: int, card: Node, destination: int)
signal combat_finished(result: Dictionary)

# =============================================================================
# ESTADO DEL COMBATE
# =============================================================================
## Resultado del último combate calculado
var last_combat_result: Dictionary = {}

## Flag para indicar si hay combate en curso
var combat_in_progress: bool = false


## Referencia al KeywordManager
var _keyword_mgr: Node = null


func _ready() -> void:
	# Obtener referencia a KeywordManager
	_keyword_mgr = get_node_or_null("/root/KeywordManager")

	# Conectar a TurnManager para automatizar combate
	var turn_mgr = get_node_or_null("/root/TurnManager")
	if turn_mgr and turn_mgr.has_signal("phase_changed"):
		turn_mgr.phase_changed.connect(_on_phase_changed)


func _on_phase_changed(new_phase: int) -> void:
	"""Responde a cambios de fase"""
	if new_phase == Constants.Phase.ASIGNACION_DANIO:
		# Iniciar cálculo de daño automáticamente
		await calculate_combat_damage()


# =============================================================================
# CÁLCULO DE DAÑO DE COMBATE (DAR Sección 5.C4)
# =============================================================================
func calculate_combat_damage() -> Dictionary:
	"""Calcula el daño de combate entre todos los pares atacante-bloqueador

	DAR 5.C4 - Tres condiciones:
	1. Atacante > Bloqueador: Bloqueador destruido, diferencia = daño al Castillo
	2. Atacante = Bloqueador: Ambos destruidos, 0 daño
	3. Atacante < Bloqueador: Atacante destruido, 0 daño

	El daño de todos los atacantes se suma como UN SOLO daño total
	"""
	# GameManager.attackers/blockers son los que la UI real llena (ver
	# CardInteractionModule._declare_attacker → GameManager.declare_attacker).
	# TurnManager.declared_attackers/declared_blockers son un sistema de
	# tracking paralelo cuyos declare_attacker()/declare_blocker() nunca se
	# llaman desde ningún flujo de juego real — leer de ahí significaba que
	# el combate calculaba 0 atacantes siempre. Ver docs/audit, hallazgo 3.
	combat_in_progress = true
	emit_signal("combat_started")

	var attackers = GameManager.attackers.duplicate()
	var blockers = GameManager.blockers.duplicate()
	var active_player = GameManager.active_player_id
	var defender_id = 1 - active_player

	var result = {
		"total_damage_to_castle": 0,
		"attackers_destroyed": [],
		"blockers_destroyed": [],
		"unblocked_attackers": [],
		"combat_pairs": [],
		"damage_sources": []
	}

	print("[BattleManager] === ASIGNACIÓN DE DAÑO ===")
	print("[BattleManager] Atacantes: %d, Bloqueadores: %d" % [attackers.size(), blockers.size()])

	# Procesar cada atacante
	for attacker in attackers:
		var attacker_strength = _get_strength(attacker)
		var attacker_name = _get_card_name(attacker)

		# Verificar si tiene bloqueador asignado
		if blockers.has(attacker):
			var blocker = blockers[attacker]
			var blocker_strength = _get_strength(blocker)
			var blocker_name = _get_card_name(blocker)

			var pair_result = _resolve_combat_pair(attacker, blocker, attacker_strength, blocker_strength)
			result.combat_pairs.append(pair_result)

			emit_signal("combat_pair_resolved", attacker, blocker, pair_result)

			# Aplicar resultado según DAR 5.C4
			match pair_result.outcome:
				"attacker_wins":
					# Atacante > Bloqueador: Bloqueador destruido, diferencia = daño
					result.blockers_destroyed.append(blocker)
					var overflow_damage = attacker_strength - blocker_strength

					# DAR Sección 8: Arrollar - daño excedente pasa al Castillo
					# (Este es el comportamiento por defecto en DAR 5.C4)
					result.total_damage_to_castle += overflow_damage
					result.damage_sources.append({
						"source": attacker,
						"damage": overflow_damage,
						"type": "overflow"
					})

					var trample_note = " (Arrollar)" if has_trample(attacker) else ""
					print("[BattleManager] %s (F:%d) > %s (F:%d) → Bloqueador destruido, %d daño pasa%s" % [
						attacker_name, attacker_strength, blocker_name, blocker_strength, overflow_damage, trample_note
					])
					emit_signal("blocker_destroyed", blocker, attacker)

				"tie":
					# Atacante = Bloqueador: Ambos destruidos, 0 daño
					result.attackers_destroyed.append(attacker)
					result.blockers_destroyed.append(blocker)
					print("[BattleManager] %s (F:%d) = %s (F:%d) → Ambos destruidos" % [
						attacker_name, attacker_strength, blocker_name, blocker_strength
					])
					emit_signal("both_destroyed", attacker, blocker)

				"blocker_wins":
					# Atacante < Bloqueador: Atacante destruido, 0 daño
					result.attackers_destroyed.append(attacker)
					print("[BattleManager] %s (F:%d) < %s (F:%d) → Atacante destruido" % [
						attacker_name, attacker_strength, blocker_name, blocker_strength
					])
					emit_signal("attacker_destroyed", attacker, blocker)
		else:
			# Sin bloqueador: todo el daño pasa al Castillo
			result.unblocked_attackers.append(attacker)
			result.total_damage_to_castle += attacker_strength
			result.damage_sources.append({
				"source": attacker,
				"damage": attacker_strength,
				"type": "unblocked"
			})
			print("[BattleManager] %s (F:%d) sin bloquear → %d daño directo" % [
				attacker_name, attacker_strength, attacker_strength
			])
			emit_signal("unblocked_damage", attacker, attacker_strength)

	# Emitir señal con el daño total calculado
	emit_signal("on_damage_assigned", result.total_damage_to_castle)
	print("[BattleManager] Daño asignado: %d (de %d fuentes)" % [
		result.total_damage_to_castle, result.damage_sources.size()
	])

	# Aplicar daño total al Castillo del defensor
	if result.total_damage_to_castle > 0:
		print("[BattleManager] === DAÑO TOTAL AL CASTILLO: %d ===" % result.total_damage_to_castle)
		emit_signal("damage_to_castle", defender_id, result.total_damage_to_castle, result.damage_sources)

		# Verificar si hay un efecto que envíe el daño al Destierro
		var to_exile = _check_damage_to_exile_effect(defender_id)

		# Procesar daño una carta a la vez (DAR Sección 8)
		var damage_result = await _apply_castle_damage(defender_id, result.total_damage_to_castle, to_exile)
		result["damage_applied"] = damage_result

		# Si el jugador fue derrotado, terminar combate inmediatamente
		if damage_result.player_defeated:
			result["game_ended"] = true
			result["loser"] = defender_id
			last_combat_result = result
			combat_in_progress = false
			emit_signal("combat_finished", result)
			return result

	# Destruir cartas (respetando Indestructible)
	var cards_to_destroy = result.attackers_destroyed + result.blockers_destroyed
	var destroyed_cards = await _destroy_cards_with_indestructible_check(cards_to_destroy)
	result["actually_destroyed"] = destroyed_cards

	# Limpiar keywords temporales de combate
	if _keyword_mgr:
		_keyword_mgr.cleanup_combat_keywords()

	last_combat_result = result
	combat_in_progress = false

	emit_signal("combat_finished", result)

	return result


func _check_damage_to_exile_effect(player_id: int) -> bool:
	"""Verifica si hay un efecto activo que envíe el daño al Destierro
	DAR Sección 8: Algunos efectos pueden cambiar el destino del daño
	"""
	# Verificar efectos continuos en TriggerSystem
	var trigger_sys = get_node_or_null("/root/TriggerSystem")
	if trigger_sys and trigger_sys.has_method("get_active_continuous_effects"):
		var effects = trigger_sys.get_active_continuous_effects("damage_to_exile")
		for effect in effects:
			# Verificar si aplica a este jugador
			var targets = effect.get("targets", [])
			if targets.is_empty() or player_id in targets or "all" in targets:
				return true

	# También verificar en cartas en juego del oponente
	var opponent_id = 1 - player_id
	var main = get_node_or_null("/root/Main")
	if main:
		var field = main.player_field if opponent_id == 0 else main.opponent_field
		if field:
			for card in field.get_children():
				if card.get("damage_goes_to_exile") == true:
					return true

	return false


func _resolve_combat_pair(attacker: Node, blocker: Node, atk_str: int, blk_str: int) -> Dictionary:
	"""Resuelve el combate entre un par atacante-bloqueador"""
	var outcome: String
	var damage_to_castle: int = 0

	if atk_str > blk_str:
		outcome = "attacker_wins"
		damage_to_castle = atk_str - blk_str
	elif atk_str == blk_str:
		outcome = "tie"
	else:
		outcome = "blocker_wins"

	return {
		"attacker": attacker,
		"blocker": blocker,
		"attacker_strength": atk_str,
		"blocker_strength": blk_str,
		"outcome": outcome,
		"damage_to_castle": damage_to_castle
	}


# =============================================================================
# APLICAR RESULTADOS
# =============================================================================
func _apply_castle_damage(defender_id: int, damage: int, to_exile: bool = false) -> Dictionary:
	"""Aplica daño al Castillo botando cartas una a una (DAR Sección 8)

	Args:
		defender_id: ID del jugador que recibe daño
		damage: Cantidad de daño (cartas a botar)
		to_exile: Si true, cartas van al Destierro en lugar de Cementerio

	Returns: {cards_milled: int, player_defeated: bool}
	"""
	var result = {
		"cards_milled": 0,
		"player_defeated": false,
		"milled_cards": []
	}

	var effect_ctrl = get_node_or_null("/root/EffectController")
	var game_mgr = get_node_or_null("/root/GameManager")
	var destination = Constants.Zone.DESTIERRO if to_exile else Constants.Zone.CEMENTERIO
	var dest_name = "Destierro" if to_exile else "Cementerio"

	print("[BattleManager] Procesando %d daño al Castillo del Jugador %d → %s" % [
		damage, defender_id + 1, dest_name
	])

	# Procesar daño UNA CARTA A LA VEZ
	for i in range(damage):
		# Verificar si el Castillo tiene cartas ANTES de botar
		var deck_count = _get_castle_count(defender_id)

		if deck_count <= 0:
			# DAR Sección 2.1: Castillo vacío = derrota inmediata
			print("[BattleManager] ¡CASTILLO VACÍO! Jugador %d PIERDE" % (defender_id + 1))
			result.player_defeated = true
			emit_signal("player_defeated", defender_id)

			if game_mgr:
				game_mgr.player_loses(defender_id, "castle_empty_combat")
			break

		# Botar una carta
		if effect_ctrl:
			var mill_result = await effect_ctrl.mill_cards(defender_id, 1, destination)
			if mill_result.actual > 0:
				result.cards_milled += 1
				result.milled_cards.append_array(mill_result.milled_cards)
		else:
			# Fallback manual
			await _mill_one_card_manually(defender_id, destination)
			result.cards_milled += 1

		# Pequeña pausa para efecto visual
		await get_tree().create_timer(0.1).timeout

		# Verificar derrota después de cada carta botada
		if _get_castle_count(defender_id) <= 0:
			print("[BattleManager] ¡CASTILLO VACÍO! Jugador %d PIERDE" % (defender_id + 1))
			result.player_defeated = true
			emit_signal("player_defeated", defender_id)

			if game_mgr:
				game_mgr.player_loses(defender_id, "castle_empty_combat")
			break

	print("[BattleManager] Daño aplicado: %d/%d cartas botadas" % [result.cards_milled, damage])

	return result


func _get_castle_count(player_id: int) -> int:
	"""Obtiene el número de cartas en el Castillo (mazo) de un jugador.
	Antes dependía de GameManager.game_board, que siempre es null (era el
	GameBoard.gd huérfano) — devolvía 0 SIEMPRE, así que la primera carta
	de daño a Castillo disparaba 'Castillo vacío, derrota inmediata' de
	forma incorrecta en cualquier combate real. CardManager sí lleva la
	cuenta real del mazo."""
	var card_mgr = get_node_or_null("/root/CardManager")
	if card_mgr and card_mgr.has_method("get_deck_count"):
		return card_mgr.get_deck_count(player_id)
	return 0


func _mill_one_card_manually(player_id: int, destination: int) -> void:
	"""Bota una carta manualmente (fallback — solo se usa si EffectController,
	que es un autoload siempre presente, no estuviera disponible)."""
	var card_mgr = get_node_or_null("/root/CardManager")
	if not card_mgr or not card_mgr.has_method("get_deck"):
		return

	var deck = card_mgr.get_deck(player_id)
	if deck.is_empty():
		return

	var card = deck[0]
	var effect_ctrl = get_node_or_null("/root/EffectController")
	if effect_ctrl and effect_ctrl.has_method("move_card"):
		effect_ctrl.move_card(card, destination, player_id, true)


func _destroy_cards_with_indestructible_check(cards: Array) -> Array:
	"""Destruye las cartas indicadas, respetando Indestructible (DAR Sección 8)
	Returns: Array de cartas que fueron efectivamente destruidas
	"""
	var effect_ctrl = get_node_or_null("/root/EffectController")
	var destroyed: Array = []

	for card in cards:
		if not is_instance_valid(card):
			continue

		# Verificar si la carta tiene Indestructible
		if _has_indestructible(card):
			print("[BattleManager] %s tiene INDESTRUCTIBLE - no se destruye" % _get_card_name(card))
			emit_signal("destruction_prevented", card, "indestructible")
			continue

		var controller = card.controller_id if card.get("controller_id") != null else 0

		if effect_ctrl:
			await effect_ctrl.destroy_card(controller, card)

		destroyed.append(card)
		await get_tree().create_timer(0.15).timeout

	return destroyed


func _has_indestructible(card: Node) -> bool:
	"""Verifica si una carta tiene Indestructible (DAR Sección 8)
	Delegado a KeywordManager para centralización
	"""
	if _keyword_mgr:
		return not _keyword_mgr.can_be_destroyed(card)

	# Fallback si KeywordManager no está disponible
	if card.get("is_indestructible") == true:
		return true
	if card.get("card_ability") != null:
		var ability_lower = card.card_ability.to_lower()
		if "indestructible" in ability_lower or "no puede ser destruid" in ability_lower:
			return true
	return false


func can_be_blocked(attacker: Node, blocker: Node = null) -> bool:
	"""DAR Sección 8: Verifica si un atacante puede ser bloqueado

	- Imbloqueable: No puede ser bloqueado
	- Alcance: Bloqueador con Alcance puede bloquear Imbloqueables
	"""
	if _keyword_mgr:
		return _keyword_mgr.can_be_blocked(attacker, blocker)

	# Fallback: verificar flag directo
	if attacker.get("is_unblockable") == true:
		return false
	if attacker.get("card_ability") != null:
		if "imbloqueable" in attacker.card_ability.to_lower():
			# Verificar si bloqueador tiene Alcance
			if blocker and blocker.get("card_ability") != null:
				if "alcance" in blocker.card_ability.to_lower():
					return true
			return false
	return true


func is_valid_block(attacker: Node, blocker: Node) -> Dictionary:
	"""Valida si una asignación de bloqueo es válida

	Returns: {valid: bool, reason: String}
	"""
	# Verificar Imbloqueable
	if not can_be_blocked(attacker, blocker):
		var attacker_name = _get_card_name(attacker)
		var blocker_name = _get_card_name(blocker)

		# Verificar si el bloqueador tiene Alcance
		var has_reach = false
		if _keyword_mgr:
			has_reach = _keyword_mgr.has_keyword(blocker, _keyword_mgr.Keyword.ALCANCE)

		if has_reach:
			print("[BattleManager] %s bloquea a %s (Imbloqueable) gracias a ALCANCE" % [
				blocker_name, attacker_name
			])
			return {"valid": true, "reason": ""}
		else:
			print("[BattleManager] %s no puede bloquear a %s (IMBLOQUEABLE)" % [
				blocker_name, attacker_name
			])
			return {"valid": false, "reason": "El atacante es Imbloqueable"}

	return {"valid": true, "reason": ""}


# =============================================================================
# UTILIDADES
# =============================================================================
func _get_strength(card: Node) -> int:
	"""Obtiene la fuerza actual de una carta, incluyendo modificadores continuos
	(buffs/debuffs) registrados en ContinuousEffectManager — sin esto, cualquier
	efecto de '+X/+X a un Aliado' sería invisible en combate sin importar qué
	tan bien se parseara el texto de la carta."""
	var cem = get_node_or_null("/root/ContinuousEffectManager")
	if cem and cem.has_method("get_modified_strength"):
		return cem.get_modified_strength(card)
	if card.has_method("get_strength"):
		return card.get_strength()
	elif card.get("card_strength") != null:
		return card.card_strength
	return 0


func _get_card_name(card: Node) -> String:
	"""Obtiene el nombre de una carta"""
	if card.get("card_name") != null:
		return card.card_name
	return "Carta"


# =============================================================================
# CONSULTAS
# =============================================================================
func get_last_combat_result() -> Dictionary:
	"""Retorna el resultado del último combate"""
	return last_combat_result


func is_combat_active() -> bool:
	"""Verifica si hay combate en curso"""
	return combat_in_progress


func get_potential_damage(attackers: Array, blockers: Dictionary) -> int:
	"""Calcula el daño potencial sin aplicarlo (para preview)"""
	var total = 0

	for attacker in attackers:
		var atk_str = _get_strength(attacker)

		if blockers.has(attacker):
			var blocker = blockers[attacker]
			var blk_str = _get_strength(blocker)

			if atk_str > blk_str:
				total += atk_str - blk_str
			# Si empatan o bloqueador gana, 0 daño pasa
		else:
			total += atk_str

	return total


# =============================================================================
# MODIFICADORES DE COMBATE
# =============================================================================
## Modificadores de fuerza temporales para el combate
var combat_strength_modifiers: Array[Dictionary] = []


func add_combat_modifier(card: Node, modifier: int, source: Node = null) -> void:
	"""Añade un modificador de fuerza para el combate actual"""
	combat_strength_modifiers.append({
		"target": card,
		"modifier": modifier,
		"source": source
	})
	print("[BattleManager] Modificador +%d a %s" % [modifier, _get_card_name(card)])


func get_modified_strength(card: Node) -> int:
	"""Obtiene la fuerza con modificadores de combate aplicados"""
	var base = _get_strength(card)
	var total_mod = 0

	for mod in combat_strength_modifiers:
		if mod.target == card:
			total_mod += mod.modifier

	return maxi(0, base + total_mod)  # Fuerza no puede ser negativa


func clear_combat_modifiers() -> void:
	"""Limpia los modificadores de combate (al final de la fase)"""
	combat_strength_modifiers.clear()


# =============================================================================
# FIRST STRIKE / GOLPE PRIMERO (DAR Sección 8)
# =============================================================================
func has_first_strike(card: Node) -> bool:
	"""Verifica si una carta tiene Golpe Primero"""
	if _keyword_mgr:
		return _keyword_mgr.has_first_strike(card)

	# Fallback
	if card.get("card_ability") != null:
		return "golpe primero" in card.card_ability.to_lower()
	return false


func has_trample(card: Node) -> bool:
	"""Verifica si una carta tiene Arrollar (daño excedente al Castillo)"""
	if _keyword_mgr:
		return _keyword_mgr.has_trample(card)
	return false


func calculate_first_strike_damage(attackers: Array, blockers: Dictionary) -> Dictionary:
	"""Calcula daño de Golpe Primero por separado (fase 1)"""
	var first_strikers = attackers.filter(func(a): return has_first_strike(a))

	if first_strikers.is_empty():
		return {"total": 0, "pairs": []}

	# TODO: Implementar lógica de Golpe Primero
	return {"total": 0, "pairs": []}
