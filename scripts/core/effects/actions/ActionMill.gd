extends RefCounted
## ActionMill — MILL (Moler cartas, DAR Sección 8).
## Opera sobre ActionModule via _main (game board, trigger collection,
## validador).
## Extraído de ActionModule.gd (Fase 4 de reestructuración, "módulos gordos").

var _main: Node


func setup(main: Node) -> void:
	_main = main


func mill(player_id: int, amount: int, to_exile: bool = false, source: String = "", skip_validation: bool = false) -> Dictionary:
	"""Envía cartas del tope del Castillo al Cementerio/Destierro

	Args:
		player_id: ID del jugador afectado
		amount: Cantidad de cartas a moler
		to_exile: Si true, van al Destierro en vez del Cementerio
		source: Origen del efecto
		skip_validation: Si omitir validación previa

	Returns: {success, cards, actual, destination}
	"""
	var destination = Constants.Zone.DESTIERRO if to_exile else Constants.Zone.CEMENTERIO
	var result = {
		"success": true,
		"cards": [],
		"requested": amount,
		"actual": 0,
		"destination": destination
	}

	# DAR Sección 6: Validar estado del juego
	if not skip_validation:
		var validation = _main._validator._validate_mill(player_id, amount)
		if not validation.valid:
			result.success = false
			result.error = validation.reason
			result.validation_failed = true
			print("[ActionModule] MILL rechazado: %s" % validation.reason)
			return result
		if not validation.warnings.is_empty():
			result.warnings = validation.warnings

	var board = _main._get_game_board()
	if not board:
		# GameBoard legacy no disponible — delegar en el fallback de
		# EffectController.mill_cards() (ver docs/audit, hallazgo 2/4).
		var ec_result: Dictionary = await EffectController.mill_cards(player_id, amount, destination)
		result.success = ec_result.get("success", false)
		result.actual = ec_result.get("actual", 0)
		result.cards = ec_result.get("milled_cards", [])
		if result.actual < result.requested and result.actual > 0:
			result.partial = true
		return result

	_main._begin_trigger_collection()

	_main.emit_signal("action_mill_started", player_id, amount, to_exile)

	var deck_cards = board.get_cards_in_zone(Constants.Zone.CASTILLO, player_id)

	for i in range(amount):
		if deck_cards.is_empty():
			break

		var card = deck_cards.pop_front()

		_main.emit_signal("action_mill_card", player_id, card, destination, i)

		AnimationQueue.add_command(AnimationQueue.CommandType.MILL_CARD, {
			"card": card,
			"player_id": player_id,
			"to_exile": to_exile,
			"index": i
		})

		# Revelar la carta antes de enviarla
		card.esta_oculta = false

		board.move_card(card, destination, player_id)
		result.cards.append(card)
		result.actual += 1

		# Trigger según destino
		var trigger_type = "on_exiled" if to_exile else "on_milled"
		_main._notify_trigger(trigger_type, {
			"player_id": player_id,
			"card": card,
			"from_zone": Constants.Zone.CASTILLO,
			"source": source
		})

	_main.emit_signal("action_mill_completed", player_id, result.cards)

	# ─────────────────────────────────────────────────────────────────────────
	# LOG DE EFECTO PARCIAL (DAR Sección 6 - "en medida de lo posible")
	# ─────────────────────────────────────────────────────────────────────────
	if result.actual < result.requested and result.actual > 0:
		CombatLog.log_partial_mill(result.requested, result.actual, player_id, result.cards)
		result.partial = true

	# ─────────────────────────────────────────────────────────────────────────
	# DETECCIÓN DE DERROTA: Verificar si el mazo quedó vacío
	# ─────────────────────────────────────────────────────────────────────────
	result.defeated = DamageManager.check_defeat_condition(player_id)

	await _main._end_trigger_collection_and_resolve()

	return result
