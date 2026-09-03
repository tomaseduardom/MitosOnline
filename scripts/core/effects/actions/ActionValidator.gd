extends RefCounted
class_name ActionValidator
## ActionValidator — Validación de estado de juego antes de ejecutar una
## acción (DAR Sección 6: "la acción debe poder resolverse en alguna medida
## mayor a 0%"). Opera sobre ActionModule via _main (GameBoard, señales).
## Extraído de ActionModule.gd (Fase 4 de reestructuración).

var _main: Node


func setup(main: Node) -> void:
	_main = main


func validate_action(action_type: String, params: Dictionary, context: Dictionary = {}) -> Dictionary:
	"""Valida si una acción puede resolverse en alguna medida > 0%
	DAR Sección 6: Verificar estado del juego antes de ejecutar

	Args:
		action_type: Tipo de acción (draw, search, mill, destroy, banish, discard)
		params: Parámetros de la acción
		context: Contexto adicional (player_id, source_card, etc.)

	Returns: {
		valid: bool,           # Si la acción puede ejecutarse
		can_resolve: float,    # Porcentaje estimado de resolución (0.0 - 1.0)
		reason: String,        # Razón si no es válida
		warnings: Array        # Advertencias (ejecución parcial probable)
	}
	"""
	var player_id = context.get("player_id", params.get("player_id", 0))

	match action_type:
		"draw":
			return _validate_draw(player_id, params.get("amount", 1))
		"search":
			return _validate_search(player_id, params.get("zone", Constants.Zone.CASTILLO), params.get("filter", {}), params.get("amount", 1))
		"mill":
			return _validate_mill(player_id, params.get("amount", 1))
		"destroy":
			return _validate_destroy(params.get("targets", []), context)
		"banish", "exile":
			return _validate_banish(params.get("targets", []))
		"discard":
			return _validate_discard(player_id, params.get("cards", []), params.get("amount", 0))
		"look":
			return _validate_look(player_id, params.get("amount", 1))
		"return_to_deck":
			return _validate_return_to_deck(params.get("cards", []))
		"damage":
			return _validate_damage(params.get("targets", []), params.get("amount", 1))
		"buff":
			return _validate_buff(params.get("targets", []))
		"shuffle":
			return _validate_shuffle(player_id)
		"virtual_gold":
			return {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}
		_:
			return {"valid": false, "can_resolve": 0.0, "reason": "unknown_action_type", "warnings": []}


func _validate_draw(player_id: int, amount: int) -> Dictionary:
	"""Valida si se puede robar al menos 1 carta"""
	var result = {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}

	var board = _main._get_game_board()
	if not board:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_game_board"
		return result

	var deck_size = board.get_cards_in_zone(Constants.Zone.CASTILLO, player_id).size()

	if deck_size == 0:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "deck_empty"
		_main.emit_signal("action_validation_failed", "draw", result.reason, {"player_id": player_id})
		return result

	if deck_size < amount:
		result.can_resolve = float(deck_size) / float(amount)
		result.warnings.append("partial_draw: only %d of %d available" % [deck_size, amount])

	_main.emit_signal("action_validation_passed", "draw", result.can_resolve)
	return result


func _validate_search(player_id: int, zone: int, filter: Dictionary, amount: int) -> Dictionary:
	"""Valida si hay cartas que cumplan el filtro en la zona"""
	var result = {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}

	var zone_cards = _main._get_searchable_zone_data(player_id, zone)
	if zone_cards == null:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "unsupported_zone"
		return result

	if zone_cards.is_empty():
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "zone_empty"
		_main.emit_signal("action_validation_failed", "search", result.reason, {"player_id": player_id, "zone": zone})
		return result

	# Aplicar filtro para ver cuántas coinciden
	var matching = _main._apply_card_filter(zone_cards, filter)

	if matching.is_empty():
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_matching_cards"
		_main.emit_signal("action_validation_failed", "search", result.reason, {"player_id": player_id, "filter": filter})
		return result

	if matching.size() < amount:
		result.can_resolve = float(matching.size()) / float(amount)
		result.warnings.append("partial_search: only %d of %d matching" % [matching.size(), amount])

	_main.emit_signal("action_validation_passed", "search", result.can_resolve)
	return result


func _validate_mill(player_id: int, amount: int) -> Dictionary:
	"""Valida si hay cartas para moler"""
	var result = {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}

	var board = _main._get_game_board()
	if not board:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_game_board"
		return result

	var deck_size = board.get_cards_in_zone(Constants.Zone.CASTILLO, player_id).size()

	if deck_size == 0:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "deck_empty"
		_main.emit_signal("action_validation_failed", "mill", result.reason, {"player_id": player_id})
		return result

	if deck_size < amount:
		result.can_resolve = float(deck_size) / float(amount)
		result.warnings.append("partial_mill: only %d of %d available" % [deck_size, amount])

	_main.emit_signal("action_validation_passed", "mill", result.can_resolve)
	return result


func _validate_destroy(targets: Array, context: Dictionary) -> Dictionary:
	"""Valida si hay objetivos válidos para destruir"""
	var result = {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}

	if targets.is_empty():
		# Sin objetivos predefinidos, verificar si hay cartas destruibles en juego
		var board = _main._get_game_board()
		if board:
			var has_destroyable = false
			for player_id in [0, 1]:
				for zone in Constants.ZONES_IN_PLAY:
					var cards = board.get_cards_in_zone(zone, player_id)
					for card in cards:
						if _can_be_destroyed(card, context.get("source_card", null)):
							has_destroyable = true
							break
					if has_destroyable:
						break
				if has_destroyable:
					break

			if not has_destroyable:
				result.valid = false
				result.can_resolve = 0.0
				result.reason = "no_valid_targets"
				_main.emit_signal("action_validation_failed", "destroy", result.reason, {})
				return result
		else:
			result.valid = false
			result.can_resolve = 0.0
			result.reason = "no_game_board"
			return result
	else:
		# Verificar objetivos específicos
		var valid_targets = 0
		for target in targets:
			if is_instance_valid(target) and _can_be_destroyed(target, context.get("source_card", null)):
				valid_targets += 1

		if valid_targets == 0:
			result.valid = false
			result.can_resolve = 0.0
			result.reason = "no_valid_targets"
			_main.emit_signal("action_validation_failed", "destroy", result.reason, {"targets": targets})
			return result

		result.can_resolve = float(valid_targets) / float(targets.size())
		if valid_targets < targets.size():
			result.warnings.append("partial_destroy: only %d of %d valid" % [valid_targets, targets.size()])

	_main.emit_signal("action_validation_passed", "destroy", result.can_resolve)
	return result


func _validate_banish(targets: Array) -> Dictionary:
	"""Valida si hay objetivos válidos para desterrar"""
	var result = {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}

	if targets.is_empty():
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_targets_specified"
		_main.emit_signal("action_validation_failed", "banish", result.reason, {})
		return result

	var valid_targets = 0
	for target in targets:
		if is_instance_valid(target):
			valid_targets += 1

	if valid_targets == 0:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_valid_targets"
		_main.emit_signal("action_validation_failed", "banish", result.reason, {"targets": targets})
		return result

	result.can_resolve = float(valid_targets) / float(targets.size())
	if valid_targets < targets.size():
		result.warnings.append("partial_banish: only %d of %d valid" % [valid_targets, targets.size()])

	_main.emit_signal("action_validation_passed", "banish", result.can_resolve)
	return result


func _validate_discard(player_id: int, cards: Array, amount: int) -> Dictionary:
	"""Valida si hay cartas para descartar"""
	var result = {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}

	var board = _main._get_game_board()
	if not board:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_game_board"
		return result

	if not cards.is_empty():
		# Cartas específicas
		var valid_cards = 0
		for card in cards:
			if is_instance_valid(card):
				valid_cards += 1

		if valid_cards == 0:
			result.valid = false
			result.can_resolve = 0.0
			result.reason = "no_valid_cards"
			_main.emit_signal("action_validation_failed", "discard", result.reason, {})
			return result

		result.can_resolve = float(valid_cards) / float(cards.size())
	elif amount > 0:
		# Cantidad a descartar - verificar mano
		var hand_size = board.get_cards_in_zone(Constants.Zone.MANO, player_id).size()

		if hand_size == 0:
			result.valid = false
			result.can_resolve = 0.0
			result.reason = "hand_empty"
			_main.emit_signal("action_validation_failed", "discard", result.reason, {"player_id": player_id})
			return result

		if hand_size < amount:
			result.can_resolve = float(hand_size) / float(amount)
			result.warnings.append("partial_discard: only %d of %d in hand" % [hand_size, amount])

	_main.emit_signal("action_validation_passed", "discard", result.can_resolve)
	return result


func _validate_look(player_id: int, amount: int) -> Dictionary:
	"""Valida si hay cartas para mirar"""
	var result = {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}

	var board = _main._get_game_board()
	if not board:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_game_board"
		return result

	var deck_size = board.get_cards_in_zone(Constants.Zone.CASTILLO, player_id).size()

	if deck_size == 0:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "deck_empty"
		_main.emit_signal("action_validation_failed", "look", result.reason, {"player_id": player_id})
		return result

	if deck_size < amount:
		result.can_resolve = float(deck_size) / float(amount)
		result.warnings.append("partial_look: only %d of %d available" % [deck_size, amount])

	_main.emit_signal("action_validation_passed", "look", result.can_resolve)
	return result


func _validate_return_to_deck(cards: Array) -> Dictionary:
	"""Valida si hay cartas para devolver al mazo"""
	var result = {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}

	if cards.is_empty():
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_cards_specified"
		_main.emit_signal("action_validation_failed", "return_to_deck", result.reason, {})
		return result

	var valid_cards = 0
	for card in cards:
		if is_instance_valid(card):
			valid_cards += 1

	if valid_cards == 0:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_valid_cards"
		_main.emit_signal("action_validation_failed", "return_to_deck", result.reason, {})
		return result

	result.can_resolve = float(valid_cards) / float(cards.size())
	_main.emit_signal("action_validation_passed", "return_to_deck", result.can_resolve)
	return result


func _validate_damage(targets: Array, amount: int) -> Dictionary:
	"""Valida si hay objetivos para recibir daño"""
	var result = {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}

	if amount <= 0:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "invalid_damage_amount"
		return result

	if targets.is_empty():
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_targets_specified"
		_main.emit_signal("action_validation_failed", "damage", result.reason, {})
		return result

	var valid_targets = 0
	for target in targets:
		if is_instance_valid(target):
			valid_targets += 1

	if valid_targets == 0:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_valid_targets"
		_main.emit_signal("action_validation_failed", "damage", result.reason, {})
		return result

	result.can_resolve = float(valid_targets) / float(targets.size())
	_main.emit_signal("action_validation_passed", "damage", result.can_resolve)
	return result


func _validate_buff(targets: Array) -> Dictionary:
	"""Valida si hay objetivos para buff/debuff"""
	var result = {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}

	if targets.is_empty():
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_targets_specified"
		_main.emit_signal("action_validation_failed", "buff", result.reason, {})
		return result

	var valid_targets = 0
	for target in targets:
		if is_instance_valid(target):
			valid_targets += 1

	if valid_targets == 0:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_valid_targets"
		_main.emit_signal("action_validation_failed", "buff", result.reason, {})
		return result

	result.can_resolve = float(valid_targets) / float(targets.size())
	_main.emit_signal("action_validation_passed", "buff", result.can_resolve)
	return result


func _validate_shuffle(player_id: int) -> Dictionary:
	"""Valida si se puede barajar (siempre válido si hay mazo)"""
	var result = {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}

	var board = _main._get_game_board()
	if not board:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_game_board"
		return result

	# Barajar siempre es válido, incluso con 0 cartas (no hace nada pero es válido)
	_main.emit_signal("action_validation_passed", "shuffle", result.can_resolve)
	return result


func _can_be_destroyed(card: Node, source: Node) -> bool:
	"""Verifica si una carta puede ser destruida.
	Pasa por KeywordManager.can_be_destroyed() (igual que BattleManager) en vez
	de leer card.has_keyword() directo — si no, un silenciado que le quite
	Indestructible vía KeywordManager no se respetaría acá."""
	if not is_instance_valid(card):
		return false

	if not KeywordManager.can_be_destroyed(card):
		return false

	# Verificar protección contra la fuente
	if source and card.has_method("has_protection_from"):
		if card.has_protection_from(source):
			return false

	return true
