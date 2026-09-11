extends RefCounted
## ActionDraw — DRAW (Robar cartas, DAR Sección 8).
## Opera sobre ActionModule via _main (game board, trigger collection,
## validador, señales de AnimationQueue).
## Extraído de ActionModule.gd (Fase 4 de reestructuración, "módulos gordos").

var _main: Node


func setup(main: Node) -> void:
	_main = main


func draw(player_id: int, amount: int, source: String = "", skip_validation: bool = false) -> Dictionary:
	"""Roba cartas del Castillo a la Mano, una a una
	DAR: 'En medida de lo posible' - roba hasta que el mazo se vacíe
	DAR 2.1: Si intenta robar con mazo vacío, PIERDE
	DAR Sección 6: Valida que puede resolverse en alguna medida > 0%

	Args:
		player_id: ID del jugador que roba
		amount: Cantidad de cartas a robar
		source: Origen del robo (para triggers)
		skip_validation: Si omitir validación previa

	Returns: {success, cards, actual, deck_empty, triggered_loss}
	"""
	var result = {
		"success": true,
		"cards": [],
		"requested": amount,
		"actual": 0,
		"deck_empty": false,
		"triggered_loss": false
	}

	# DAR Sección 6: Validar estado del juego
	if not skip_validation:
		var validation = _main._validator._validate_draw(player_id, amount)
		if not validation.valid:
			result.success = false
			result.error = validation.reason
			result.validation_failed = true
			print("[ActionModule] DRAW rechazado: %s" % validation.reason)
			return result
		if not validation.warnings.is_empty():
			result.warnings = validation.warnings

	var board = _main._get_game_board()
	if not board:
		# GameBoard legacy no disponible (docs/audit, hallazgo 2/4) — usar el
		# camino real del juego en vez de fallar en silencio.
		return await _draw_fallback(player_id, amount, source)

	# Iniciar recolección de triggers
	_main._begin_trigger_collection()

	_main.emit_signal("action_draw_started", player_id, amount, source)

	# Añadir comando a AnimationQueue
	AnimationQueue.add_command(AnimationQueue.CommandType.SHOW_MESSAGE, {
		"text": "Robando %d carta(s)..." % amount,
		"duration": 0.5
	})

	var deck_cards = board.get_cards_in_zone(Constants.Zone.CASTILLO, player_id)

	for i in range(amount):
		if deck_cards.is_empty():
			result.deck_empty = true
			# DAR 2.1: Intentar robar con mazo vacío = PERDER
			if i == 0 and amount > 0:
				result.triggered_loss = true
				result.success = false
				print("[ActionModule] DERROTA: Jugador %d intentó robar con mazo vacío" % player_id)
				# (2026-08-28): 'GameManager.trigger_loss' nunca existió — el
				# fallback de abajo era código muerto siempre (DamageManager
				# es autoload garantizado y check_defeat_condition() sí existe).
				DamageManager.check_defeat_condition(player_id)
			break

		# Tomar carta del tope
		var card = deck_cards.pop_front()

		# Emitir señal individual para animación
		_main.emit_signal("action_draw_card", player_id, card, i, amount)

		# Añadir animación
		AnimationQueue.add_command(AnimationQueue.CommandType.DRAW_CARD, {
			"card": card,
			"player_id": player_id,
			"from_zone": Constants.Zone.CASTILLO,
			"to_zone": Constants.Zone.MANO
		})

		# Mover carta
		board.move_card(card, Constants.Zone.MANO, player_id)
		card.esta_oculta = false

		result.cards.append(card)
		result.actual += 1

		# Notificar trigger on_draw
		_main._notify_trigger("on_draw", {
			"player_id": player_id,
			"card": card,
			"source": source
		})

	_main.emit_signal("action_draw_completed", player_id, result.cards, result.actual)

	# ─────────────────────────────────────────────────────────────────────────
	# LOG DE EFECTO PARCIAL (DAR Sección 6 - "en medida de lo posible")
	# ─────────────────────────────────────────────────────────────────────────
	if result.actual < result.requested and result.actual > 0:
		CombatLog.log_partial_draw(result.requested, result.actual, player_id)
		result.partial = true

	# Finalizar y procesar triggers
	await _main._end_trigger_collection_and_resolve()

	return result


func _draw_fallback(player_id: int, amount: int, source: String) -> Dictionary:
	"""GameBoard legacy no disponible — usa Main.draw_card(), el camino que
	realmente mueve cartas en la escena actual (ver docs/audit, hallazgo 2/4).
	Limitación conocida: sin nodos de Card trackeados por zona no hay
	animación de robo individual ni 'cards' poblado, pero el conteo y la
	derrota por Castillo vacío (DAR 2.1) sí se aplican de verdad."""
	var result = {
		"success": true, "cards": [], "requested": amount, "actual": 0,
		"deck_empty": false, "triggered_loss": false
	}
	var main = _main.get_node_or_null("/root/Main")
	if not main or not main.get("_zone_manager"):
		result.success = false
		result.error = "no_main"
		return result

	for i in range(amount):
		var drew: bool = await main._zone_manager.draw_card(player_id)
		if not drew:
			result.deck_empty = true
			if i == 0:
				result.triggered_loss = true
				result.success = false
			break
		result.actual += 1

	if result.actual < result.requested and result.actual > 0:
		result.partial = true

	return result
