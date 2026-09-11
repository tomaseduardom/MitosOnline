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


func _ready() -> void:
	# (2026-08-28, "módulos gordos" punto 1): acá había una conexión a
	# 'TurnManager.phase_changed' para auto-disparar calculate_combat_damage()
	# en ASIGNACION_DANIO — TurnManager.gd NO tiene (ni tuvo nunca) esa señal,
	# así que el 'has_signal()' que la envolvía siempre daba falso y esto
	# jamás se conectó. No hacía falta: PhaseFlowController.gd sí llama
	# BattleManager.calculate_combat_damage() directo al entrar a esa fase
	# (ver PhaseFlowController.gd línea ~273) — ese es el camino real. Se
	# sacó la conexión rota y el handler _on_phase_changed() que quedaba
	# huérfano sin ella.
	pass


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
		# Daño de atacantes con "hace doble daño de combate al Destierro"
		# (2026-09-04, a pedido del usuario — p.ej. atenea en wonderland,
		# manuel rodriguez) — YA VIENE DOBLADO acá, separado del pool normal
		# porque va a una zona distinta (Destierro, no Cementerio) al
		# aplicarse más abajo.
		"total_damage_to_exile": 0,
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

					# DAR 5.C4: el daño excedente siempre pasa al Castillo — no es
					# una keyword especial ("Arrollar" no existe en Mitos y
					# Leyendas), es el comportamiento por defecto del combate.
					_accumulate_castle_damage(result, attacker, overflow_damage)
					result.damage_sources.append({
						"source": attacker,
						"damage": overflow_damage,
						"type": "overflow"
					})

					print("[BattleManager] %s (F:%d) > %s (F:%d) → Bloqueador destruido, %d daño pasa" % [
						attacker_name, attacker_strength, blocker_name, blocker_strength, overflow_damage
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
			_accumulate_castle_damage(result, attacker, attacker_strength)
			result.damage_sources.append({
				"source": attacker,
				"damage": attacker_strength,
				"type": "unblocked"
			})
			print("[BattleManager] %s (F:%d) sin bloquear → %d daño directo" % [
				attacker_name, attacker_strength, attacker_strength
			])
			emit_signal("unblocked_damage", attacker, attacker_strength)

	# Emitir señal con el daño total calculado (ambos pools combinados —
	# 2026-09-04: total_damage_to_exile ya viene doblado, ver
	# _accumulate_castle_damage())
	var total_damage_combined: int = result.total_damage_to_castle + result.total_damage_to_exile
	emit_signal("on_damage_assigned", total_damage_combined)
	print("[BattleManager] Daño asignado: %d normal + %d al Destierro (de %d fuentes)" % [
		result.total_damage_to_castle, result.total_damage_to_exile, result.damage_sources.size()
	])

	# Aplicar daño "hace doble daño de combate al Destierro" PRIMERO (pool
	# separado, siempre a Destierro sin importar _check_damage_to_exile_effect)
	if result.total_damage_to_exile > 0:
		print("[BattleManager] === DAÑO AL DESTIERRO: %d ===" % result.total_damage_to_exile)
		emit_signal("damage_to_castle", defender_id, result.total_damage_to_exile, result.damage_sources)
		var exile_damage_result = await _apply_castle_damage(defender_id, result.total_damage_to_exile, true)
		result["damage_applied_to_exile"] = exile_damage_result
		if exile_damage_result.player_defeated:
			result["game_ended"] = true
			result["loser"] = defender_id
			last_combat_result = result
			combat_in_progress = false
			emit_signal("combat_finished", result)
			return result

	# Aplicar daño total normal al Castillo del defensor
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
	#
	# Protección "no son Destruidos cuando bloquean" (2026-08-24, p.ej.
	# Patria Vieja): solo se filtra de blockers_destroyed, NUNCA de
	# attackers_destroyed — la protección es específicamente por bloquear,
	# no una Indestructible general.
	var protected_blockers = result.blockers_destroyed.filter(
		func(b): return ContinuousEffectManager.has_protection(b, "BLOCK_DESTROY")
	)
	var blockers_to_destroy = result.blockers_destroyed.filter(
		func(b): return b not in protected_blockers
	)
	if not protected_blockers.is_empty():
		for b in protected_blockers:
			print("[BattleManager] %s no fue destruido al bloquear (protección continua)" % _get_card_name(b))

	var cards_to_destroy = result.attackers_destroyed + blockers_to_destroy
	var destroyed_cards = await _destroy_cards_with_indestructible_check(cards_to_destroy)
	result["actually_destroyed"] = destroyed_cards

	# Limpiar keywords temporales de combate
	KeywordManager.cleanup_combat_keywords()

	last_combat_result = result
	combat_in_progress = false

	emit_signal("combat_finished", result)

	return result


func _check_damage_to_exile_effect(player_id: int) -> bool:
	"""Verifica si hay un efecto activo que envíe el daño al Destierro
	DAR Sección 8: Algunos efectos pueden cambiar el destino del daño
	"""
	# Verificar efectos continuos en TriggerSystem
	var effects = TriggerSystem.get_active_continuous_effects("damage_to_exile")
	for effect in effects:
		# Verificar si aplica a este jugador
		var targets = effect.get("targets", [])
		if targets.is_empty() or player_id in targets or "all" in targets:
			return true

	# También verificar en cartas en juego del oponente
	var opponent_id = 1 - player_id
	var main = get_node_or_null("/root/Main")
	if main:
		var fields = [main.player_field, main.player_linea_ataque] if opponent_id == 0 else [main.opponent_field, main.opponent_linea_ataque]
		for field in fields:
			if not field:
				continue
			for card in field.get_children():
				if card.get("damage_goes_to_exile") == true:
					return true

	return false


func _accumulate_castle_damage(result: Dictionary, attacker: Node, amount: int) -> void:
	"""Suma 'amount' al pool correcto según si 'attacker' tiene 'hace doble
	daño de combate al Destierro' (2026-09-04, a pedido del usuario — p.ej.
	atenea en wonderland, manuel rodriguez): ese daño se DOBLA y va a un
	pool separado que _apply_castle_damage() manda al Destierro en vez del
	Cementerio. El resto de atacantes en el mismo combate sigue sumando al
	pool normal sin verse afectado."""
	if is_instance_valid(attacker) and attacker.get("doubles_damage_to_exile") == true:
		result.total_damage_to_exile += amount * 2
	else:
		result.total_damage_to_castle += amount


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
			GameManager.player_loses(defender_id, "castle_empty_combat")
			break

		# Botar una carta
		var mill_result = await EffectController.mill_cards(defender_id, 1, destination)
		if mill_result.actual > 0:
			result.cards_milled += 1
			result.milled_cards.append_array(mill_result.milled_cards)

		# Pequeña pausa para efecto visual
		await get_tree().create_timer(0.1).timeout

		# Verificar derrota después de cada carta botada
		if _get_castle_count(defender_id) <= 0:
			print("[BattleManager] ¡CASTILLO VACÍO! Jugador %d PIERDE" % (defender_id + 1))
			result.player_defeated = true
			emit_signal("player_defeated", defender_id)
			GameManager.player_loses(defender_id, "castle_empty_combat")
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
	return CardManager.get_deck_count(player_id)


func _destroy_cards_with_indestructible_check(cards: Array) -> Array:
	"""Destruye las cartas indicadas, respetando Indestructible (DAR Sección 8)
	Returns: Array de cartas que fueron efectivamente destruidas
	"""
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
		await EffectController.destroy_card(controller, card)

		destroyed.append(card)
		await get_tree().create_timer(0.15).timeout

	return destroyed


func _has_indestructible(card: Node) -> bool:
	"""Verifica si una carta tiene Indestructible (DAR Sección 8)
	Delegado a KeywordManager para centralización.
	(2026-08-28, "módulos gordos" punto 1: esto llamaba a _keyword_mgr, una
	referencia cacheada en _ready() ANTES de que KeywordManager (autoload
	#22) terminara de cargar — BattleManager es autoload #11, así que
	_keyword_mgr quedaba null para siempre y esta función corría el
	fallback manual de abajo toda la partida, nunca la lógica real
	centralizada de KeywordManager. Confirmado y corregido junto con
	can_be_blocked() más abajo, mismo bug.)
	"""
	return not KeywordManager.can_be_destroyed(card)


func can_be_blocked(attacker: Node, blocker: Node = null) -> bool:
	"""DAR Sección 8: Verifica si un atacante puede ser bloqueado.
	Imbloqueable: no puede ser bloqueado, sin excepción por keyword general
	(no existe 'Alcance' en Mitos y Leyendas) — solo si el propio texto del
	bloqueador dice explícitamente que puede bloquear Imbloqueables."""
	return KeywordManager.can_be_blocked(attacker, blocker)


func is_valid_block(attacker: Node, blocker: Node) -> Dictionary:
	"""Valida si una asignación de bloqueo es válida

	Returns: {valid: bool, reason: String}
	"""
	if not can_be_blocked(attacker, blocker):
		var attacker_name = _get_card_name(attacker)
		var blocker_name = _get_card_name(blocker)
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
	return ContinuousEffectManager.get_modified_strength(card)


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


# NOTA (2026-09-08): Se eliminó un segundo sistema de "modificadores de
# combate" (combat_strength_modifiers/add_combat_modifier()/get_modified_
# strength()/clear_combat_modifiers()) que vivía acá, paralelo y desconectado
# del real: calculate_combat_damage() siempre calculó la Fuerza vía
# ContinuousEffectManager.get_modified_strength(card) (ver _get_strength()
# más arriba), nunca a través de este — auditoría 2026-09-07 confirmó cero
# llamadores reales en todo el proyecto. Cualquier efecto de "+X de Fuerza
# este combate" debe registrarse en ContinuousEffectManager (duration
# UNTIL_END_TURN o similar), no acá.

# NOTA (2026-08-20): "Golpe Primero" y "Arrollar" no son keywords en Mitos y
# Leyendas — se eliminó has_first_strike()/has_trample()/
# calculate_first_strike_damage() (sin llamadores reales, siempre un TODO
# que devolvía 0). El daño excedente al Castillo ya se aplica por defecto
# en _resolve_combat_pair() (DAR 5.C4), sin necesidad de ninguna keyword.
