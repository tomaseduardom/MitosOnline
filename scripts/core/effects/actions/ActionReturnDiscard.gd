extends RefCounted
## ActionReturnDiscard — RETURN TO DECK + DISCARD (DAR Sección 8).
## Opera sobre ActionModule via _main (game board, trigger collection,
## validador, señales de AnimationQueue).
## Extraído de ActionModule.gd (Fase 4 de reestructuración, "módulos gordos").

var _main: Node


func setup(main: Node) -> void:
	_main = main


func return_to_deck(card: Node, player_id: int, to_top: bool = true, source: Node = null) -> bool:
	"""Devuelve una carta que está EN JUEGO a su Castillo (tope o fondo del
	mazo — 'devuelve al mazo'/'pon en el fondo del mazo'). El patrón real de
	ABILITY_PATTERNS['RETURN_DECK'] ya existía pero apuntaba a esta función,
	que nunca se había escrito. Si tenía Armas equipadas, también vuelven al
	mazo con ella (el Arma sigue al portador, igual que al destruir/desterrar
	— ver CardManager.destroy_card()/exile_card()).

	source (2026-09-09, "sistema de respuestas" — a pedido del usuario,
	cerrando un hueco real: esto no chequeaba NADA de Prevención antes):
	tag "leave_play" — Legión Paladín puede prevenir esto (Estaca NO,
	'barajar de vuelta al mazo' no es destruir/desterrar/debuff/silenciar,
	su alcance confirmado no lo cubre). Se revisa ANTES de tocar las Armas
	equipadas — si se previene, la carta y sus Armas se quedan exactamente
	como estaban."""
	if not is_instance_valid(card):
		return false
	if await EffectController.offer_prevention(card, source, "leave_play"):
		return false

	if card.get("equipped_weapons"):
		for weapon in card.equipped_weapons.duplicate():
			if is_instance_valid(weapon):
				await return_to_deck(weapon, player_id, to_top, source)

	var card_data: Dictionary = card.card_data.duplicate() if card.get("card_data") else {}
	card_data["esta_oculta"] = true  # el Castillo es una zona privada, a diferencia del Cementerio/Destierro
	if to_top:
		CardManager.add_to_deck_top(player_id, card_data)
	else:
		CardManager.add_to_deck_bottom(player_id, card_data)

	# on_card_returned_to_deck estaba declarada en EffectController.gd pero
	# nunca se emitía desde ningún lado (2026-09-11, encontrado al construir
	# GameStateBroadcaster para el multiplayer remoto — sin esto, una carta
	# "barajada de vuelta al mazo" dejaba un fantasma visual permanente del
	# lado del Remoto, sin ninguna instrucción de red que la sacara del
	# tablero). Se emite ANTES de desconectar/liberar, mismo orden que
	# destroy_card()/exile_card() en EffectController.gd.
	EffectController.emit_signal("on_card_returned_to_deck", player_id, card, to_top)

	# Desconectar señales de interacción ANTES de liberar (2026-08-29, mismo
	# bug que CardManager.destroy_card()/exile_card()) — sin esto, un hover
	# que sigue apuntando al nodo después de queue_free() tira "Invalid
	# access... on a base object of type previously freed" al tocar
	# .modulate en el próximo evento de mouse.
	CardManager._disconnect_card_interaction_signals(card)
	card.queue_free()
	return true


func discard(player_id: int, cards: Array, source: String = "", skip_validation: bool = false) -> Dictionary:
	"""Descarta cartas de la mano al cementerio

	Args:
		player_id: ID del jugador que descarta
		cards: Array de cartas a descartar
		source: Origen del descarte
		skip_validation: Si omitir validación previa

	Returns: {success, discarded, actual}
	"""
	var result = {
		"success": true,
		"discarded": [],
		"actual": 0
	}

	# DAR Sección 6: Validar estado del juego
	if not skip_validation:
		var validation = _main._validator._validate_discard(player_id, cards, 0)
		if not validation.valid:
			result.success = false
			result.error = validation.reason
			result.validation_failed = true
			print("[ActionModule] DISCARD rechazado: %s" % validation.reason)
			return result
		if not validation.warnings.is_empty():
			result.warnings = validation.warnings

	var board = _main._get_game_board()

	_main._begin_trigger_collection()

	_main.emit_signal("action_discard_started", player_id, cards)

	for i in range(cards.size()):
		var card = cards[i]
		if not is_instance_valid(card):
			continue

		_main.emit_signal("action_discard_card", player_id, card, i)

		AnimationQueue.add_command(AnimationQueue.CommandType.DISCARD_CARD, {
			"card": card,
			"player_id": player_id,
			"index": i
		})

		card.esta_oculta = false
		if not board:
			# GameBoard legacy no disponible (docs/audit, hallazgo 2/4) —
			# mismo camino que PhaseFlowController._opponent_auto_discard()/
			# SelectionModule.open_discard_selection(): sacar la carta de la
			# mano real y mandar sus datos al cementerio vía CardManager.
			_discard_card_fallback(player_id, card)
			result.discarded.append(card)
			result.actual += 1
			_main._notify_trigger("on_discard", {"player_id": player_id, "card": card, "source": source})
			continue
		board.move_card(card, Constants.Zone.CEMENTERIO, player_id)
		result.discarded.append(card)
		result.actual += 1

		_main._notify_trigger("on_discard", {
			"player_id": player_id,
			"card": card,
			"source": source
		})

	_main.emit_signal("action_discard_completed", player_id, result.discarded)

	await _main._end_trigger_collection_and_resolve()

	return result


func _discard_card_fallback(player_id: int, card: Node) -> void:
	"""Descarta una carta de la mano real al Cementerio sin pasar por el
	GameBoard legacy (siempre null) — mismo camino usado por
	PhaseFlowController._opponent_auto_discard()/SelectionModule.
	open_discard_selection()."""
	var data: Dictionary = card.card_data.duplicate() if card.get("card_data") else {}
	data["esta_oculta"] = false
	CardManager.add_to_cemetery(player_id, data)
	var main := _main.get_node_or_null("/root/Main")
	if player_id == 0 and main and main.player_hand and main.player_hand.has_method("remove_card"):
		main.player_hand.remove_card(card, true)
	elif main and main.get("_opponent_fan") and main._opponent_fan.has_method("remove_card"):
		main._opponent_fan.remove_card(card, true)
