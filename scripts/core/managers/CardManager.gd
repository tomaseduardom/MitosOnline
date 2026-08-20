extends Node
## CardManager - Singleton que gestiona el movimiento de cartas entre zonas
## Centraliza la lógica de deck, mano, cementerio y destierro

# =============================================================================
# SEÑALES
# =============================================================================
signal card_drawn(player_id: int, card_data: Dictionary)
signal card_discarded(player_id: int, card_data: Dictionary)
signal card_destroyed(player_id: int, card: Node)
signal card_exiled(player_id: int, card: Node)
signal damage_taken(player_id: int, amount: int, cards_milled: Array)
signal deck_empty(player_id: int)
signal zone_changed(card: Node, from_zone: int, to_zone: int, player_id: int)

# Señales para actualización de UI (contadores)
signal deck_count_changed(player_id: int, new_count: int)
signal hand_count_changed(player_id: int, new_count: int)
signal cemetery_count_changed(player_id: int, new_count: int)
signal exile_count_changed(player_id: int, new_count: int)
signal field_count_changed(player_id: int, new_count: int)

# =============================================================================
# REFERENCIAS
# =============================================================================
var _main: Node = null  # Referencia a Main.gd (se obtiene dinámicamente)

# =============================================================================
# DATOS DE ZONAS (por jugador)
# =============================================================================
# Estructura: { player_id: { zone: data } }
var _zones: Dictionary = {
	0: {
		"deck": [],        # Array[Dictionary] - datos de cartas
		"hand": [],        # Array[Node] - instancias de Card
		"field": [],       # Array[Node] - aliados en juego
		"cemetery": [],    # Array[Dictionary] - datos de cartas destruidas
		"exile": [],       # Array[Dictionary] - datos de cartas desterradas
		"gold": [],        # Array[Node] - oros en reserva
		"gold_paid": []    # Array[Node] - oros pagados este turno
	},
	1: {
		"deck": [],
		"hand": [],
		"field": [],
		"cemetery": [],
		"exile": [],
		"gold": [],
		"gold_paid": []
	}
}

# =============================================================================
# INICIALIZACIÓN
# =============================================================================
func _ready() -> void:
	print("[CardManager] Inicializado")


func _get_main() -> Node:
	"""Obtiene referencia a Main.gd de forma lazy"""
	if not _main or not is_instance_valid(_main):
		_main = get_tree().current_scene if get_tree() else null
	return _main


# =============================================================================
# SINCRONIZACIÓN CON MAIN.GD
# =============================================================================
func sync_from_main() -> void:
	"""Sincroniza los datos desde Main.gd (llamar al inicio del juego)"""
	var main = _get_main()
	if not main:
		push_warning("[CardManager] Main.gd no disponible para sincronizar")
		return

	# Sincronizar decks
	if main.get("player_deck"):
		_zones[0].deck = main.player_deck
	if main.get("opponent_deck"):
		_zones[1].deck = main.opponent_deck

	# Sincronizar cementerios
	if main.get("player_cemetery"):
		_zones[0].cemetery = main.player_cemetery
	if main.get("opponent_cemetery"):
		_zones[1].cemetery = main.opponent_cemetery

	print("[CardManager] Sincronizado - Deck P0: %d, Deck P1: %d" % [
		_zones[0].deck.size(), _zones[1].deck.size()
	])


func sync_to_main() -> void:
	"""Sincroniza los datos de vuelta a Main.gd"""
	var main = _get_main()
	if not main:
		return

	if main.get("player_deck") != null:
		main.player_deck = _zones[0].deck
	if main.get("opponent_deck") != null:
		main.opponent_deck = _zones[1].deck
	if main.get("player_cemetery") != null:
		main.player_cemetery = _zones[0].cemetery
	if main.get("opponent_cemetery") != null:
		main.opponent_cemetery = _zones[1].cemetery


# =============================================================================
# ACCESO A ZONAS
# =============================================================================
func get_deck(player_id: int) -> Array:
	"""Obtiene el mazo de un jugador"""
	return _zones[player_id].deck


func get_hand(player_id: int) -> Array:
	"""Obtiene la mano de un jugador (instancias)"""
	return _zones[player_id].hand


func get_cemetery(player_id: int) -> Array:
	"""Obtiene el cementerio de un jugador"""
	return _zones[player_id].cemetery


func get_exile(player_id: int) -> Array:
	"""Obtiene el destierro de un jugador"""
	return _zones[player_id].exile


func get_field(player_id: int) -> Array:
	"""Obtiene los aliados en campo de un jugador"""
	return _zones[player_id].field


func get_deck_count(player_id: int) -> int:
	"""Obtiene el número de cartas en el mazo"""
	return _zones[player_id].deck.size()


func get_hand_count(player_id: int) -> int:
	"""Obtiene el número de cartas en mano"""
	return _zones[player_id].hand.size()


func get_cemetery_count(player_id: int) -> int:
	"""Obtiene el número de cartas en cementerio"""
	return _zones[player_id].cemetery.size()


# =============================================================================
# MOVIMIENTO DE CARTAS - DECK
# =============================================================================
func draw_card(player_id: int) -> Dictionary:
	"""Roba una carta del tope del mazo

	Returns: Datos de la carta robada, o {} si el mazo está vacío
	"""
	var deck = _zones[player_id].deck

	if deck.is_empty():
		emit_signal("deck_empty", player_id)
		return {}

	# Robar del tope (último elemento = tope del mazo)
	var card_data = deck.pop_back()

	emit_signal("card_drawn", player_id, card_data)
	_update_deck_visual(player_id)

	return card_data


func draw_cards(player_id: int, count: int) -> Array:
	"""Roba múltiples cartas del mazo

	Returns: Array de datos de cartas robadas
	"""
	var drawn: Array = []

	for i in range(count):
		var card_data = draw_card(player_id)
		if card_data.is_empty():
			break
		drawn.append(card_data)

	return drawn


func add_to_deck_top(player_id: int, card_data: Dictionary) -> void:
	"""Añade una carta al tope del mazo"""
	_zones[player_id].deck.append(card_data)
	_update_deck_visual(player_id)


func add_to_deck_bottom(player_id: int, card_data: Dictionary) -> void:
	"""Añade una carta al fondo del mazo"""
	_zones[player_id].deck.insert(0, card_data)
	_update_deck_visual(player_id)


func shuffle_deck(player_id: int) -> void:
	"""Baraja el mazo de un jugador"""
	_zones[player_id].deck.shuffle()
	print("[CardManager] Mazo de jugador %d barajado" % player_id)


# =============================================================================
# MOVIMIENTO DE CARTAS - MANO
# =============================================================================
func add_to_hand(player_id: int, card: Node) -> void:
	"""Añade una instancia de carta a la mano"""
	_zones[player_id].hand.append(card)
	emit_signal("zone_changed", card, -1, Constants.Zone.MANO, player_id)


func remove_from_hand(player_id: int, card: Node) -> bool:
	"""Remueve una carta de la mano

	Returns: true si se removió exitosamente
	"""
	var hand = _zones[player_id].hand
	var idx = hand.find(card)

	if idx >= 0:
		hand.remove_at(idx)
		return true
	return false


func discard_from_hand(player_id: int, card: Node) -> void:
	"""Descarta una carta de la mano al cementerio"""
	if remove_from_hand(player_id, card):
		# Guardar datos antes de destruir el nodo
		var card_data = card.card_data.duplicate() if card.get("card_data") else {}
		card_data["esta_oculta"] = false
		_zones[player_id].cemetery.append(card_data)

		emit_signal("card_discarded", player_id, card_data)
		emit_signal("zone_changed", card, Constants.Zone.MANO, Constants.Zone.CEMENTERIO, player_id)

		_update_cemetery_visual(player_id)
		card.queue_free()


# =============================================================================
# MOVIMIENTO DE CARTAS - CEMENTERIO
# =============================================================================
func add_to_cemetery(player_id: int, card_data: Dictionary) -> void:
	"""Añade datos de carta al cementerio (desde mazo o efecto)"""
	card_data["esta_oculta"] = false
	_zones[player_id].cemetery.append(card_data)
	_update_cemetery_visual(player_id)


func add_card_to_cemetery(player_id: int, card: Node) -> void:
	"""Mueve una instancia de carta al cementerio (la destruye)
	NOTA: Usar destroy_card() para respetar la regla de exhumación
	"""
	var card_data = card.card_data.duplicate() if card.get("card_data") else {}
	card_data["esta_oculta"] = false
	_zones[player_id].cemetery.append(card_data)

	emit_signal("card_destroyed", player_id, card)
	_update_cemetery_visual(player_id)

	card.queue_free()


func destroy_card(player_id: int, card: Node) -> void:
	"""Destruye una carta respetando la regla de exhumación (DAR)

	Si la carta fue exhumada (is_exhumed = true), va al destierro.
	Si no fue exhumada, va al cementerio normalmente.
	"""
	var card_data = card.card_data.duplicate() if card.get("card_data") else {}

	# Cartas exhumadas van al destierro, no al cementerio
	card_data["esta_oculta"] = false
	if card.get("is_exhumed") == true:
		_zones[player_id].exile.append(card_data)
		emit_signal("card_exiled", player_id, card)
		_emit_exile_changed(player_id)
		print("[CardManager] Carta exhumada '%s' desterrada (no vuelve al cementerio)" % card_data.get("nombre", "?"))
	else:
		_zones[player_id].cemetery.append(card_data)
		emit_signal("card_destroyed", player_id, card)
		_update_cemetery_visual(player_id)

	card.queue_free()


func remove_from_cemetery(player_id: int, index: int = -1) -> Dictionary:
	"""Remueve una carta del cementerio (para Exhumar)

	Args:
		player_id: ID del jugador
		index: Índice de la carta (-1 = última/tope)

	Returns: Datos de la carta removida
	"""
	var cemetery = _zones[player_id].cemetery

	if cemetery.is_empty():
		return {}

	if index < 0:
		index = cemetery.size() - 1

	if index >= 0 and index < cemetery.size():
		var card_data = cemetery[index]
		cemetery.remove_at(index)
		_update_cemetery_visual(player_id)
		return card_data

	return {}


# =============================================================================
# MOVIMIENTO DE CARTAS - DESTIERRO
# =============================================================================
func exile_card(player_id: int, card: Node) -> void:
	"""Destierra una carta (la remueve del juego)"""
	var card_data = card.card_data.duplicate() if card.get("card_data") else {}
	card_data["esta_oculta"] = false
	_zones[player_id].exile.append(card_data)

	emit_signal("card_exiled", player_id, card)
	_emit_exile_changed(player_id)
	card.queue_free()


func exile_from_cemetery(player_id: int, index: int = -1) -> Dictionary:
	"""Destierra una carta del cementerio"""
	var card_data = remove_from_cemetery(player_id, index)
	if not card_data.is_empty():
		card_data["esta_oculta"] = false
		_zones[player_id].exile.append(card_data)
		_emit_exile_changed(player_id)
	return card_data


func exhume_card(player_id: int, index: int = -1) -> Dictionary:
	"""Exhuma una carta del cementerio (DAR - Exhumar)

	La carta exhumada debe marcarse con is_exhumed = true al instanciarla.
	Cuando la carta deje el campo, irá al destierro en lugar de al cementerio.

	Returns: Datos de la carta exhumada (marcar is_exhumed al instanciar)
	"""
	var card_data = remove_from_cemetery(player_id, index)
	if not card_data.is_empty():
		# Marcar en los datos que fue exhumada (para referencia)
		card_data["_was_exhumed"] = true
		print("[CardManager] Carta '%s' exhumada del cementerio" % card_data.get("nombre", "?"))
	return card_data


# =============================================================================
# SISTEMA DE DAÑO (DAR 2025)
# =============================================================================
func take_damage(player_id: int, amount: int) -> Dictionary:
	"""Aplica daño a un jugador moviendo cartas del mazo al cementerio

	Args:
		player_id: ID del jugador que recibe daño
		amount: Cantidad de daño (cartas a mover)

	Returns: {
		requested: int,      # Daño solicitado
		actual: int,         # Daño real aplicado
		cards: Array,        # Cartas movidas al cementerio
		deck_empty: bool,    # Si el mazo quedó vacío
		defeated: bool       # Si el jugador perdió (mazo vacío después del daño)
	}
	"""
	var deck = _zones[player_id].deck
	var result = {
		"requested": amount,
		"actual": 0,
		"cards": [],
		"deck_empty": false,
		"defeated": false
	}

	if amount <= 0:
		return result

	# Mover cartas del tope del mazo al cementerio
	for i in range(amount):
		if deck.is_empty():
			result.deck_empty = true
			break

		var card_data = deck.pop_back()
		card_data["esta_oculta"] = false
		_zones[player_id].cemetery.append(card_data)
		result.cards.append(card_data)
		result.actual += 1

	# Actualizar visuales
	_update_deck_visual(player_id)
	_update_cemetery_visual(player_id)

	# Verificar derrota
	if deck.is_empty():
		result.defeated = true
		emit_signal("deck_empty", player_id)

	# Emitir señal de daño
	emit_signal("damage_taken", player_id, result.actual, result.cards)

	# Log
	var card_names = result.cards.map(func(c): return c.get("nombre", "?"))
	print("[CardManager] Jugador %d recibe %d daño: %s" % [
		player_id, result.actual, card_names
	])

	# Log parcial si no se pudo hacer todo el daño
	if result.actual < result.requested:
		var combat_log = get_node_or_null("/root/CombatLog")
		if combat_log and combat_log.has_method("log_partial_damage"):
			combat_log.log_partial_damage(result.requested, result.actual, player_id)

	return result


func mill_cards(player_id: int, amount: int) -> Dictionary:
	"""Muele cartas del mazo al cementerio (alias para take_damage sin ser daño)

	Usado para efectos que mueven cartas sin ser considerado daño
	"""
	return take_damage(player_id, amount)


# =============================================================================
# ACTUALIZACIÓN VISUAL (vía señales)
# =============================================================================
func _emit_deck_changed(player_id: int) -> void:
	"""Emite señal de cambio en el mazo"""
	var count = _zones[player_id].deck.size()
	emit_signal("deck_count_changed", player_id, count)


func _emit_hand_changed(player_id: int) -> void:
	"""Emite señal de cambio en la mano"""
	var count = _zones[player_id].hand.size()
	emit_signal("hand_count_changed", player_id, count)


func _emit_cemetery_changed(player_id: int) -> void:
	"""Emite señal de cambio en el cementerio"""
	var count = _zones[player_id].cemetery.size()
	emit_signal("cemetery_count_changed", player_id, count)


func _emit_exile_changed(player_id: int) -> void:
	"""Emite señal de cambio en el destierro"""
	var count = _zones[player_id].exile.size()
	emit_signal("exile_count_changed", player_id, count)


func _emit_field_changed(player_id: int) -> void:
	"""Emite señal de cambio en el campo"""
	var count = _zones[player_id].field.size()
	emit_signal("field_count_changed", player_id, count)


# Aliases para compatibilidad
func _update_deck_visual(player_id: int) -> void:
	_emit_deck_changed(player_id)


func _update_cemetery_visual(player_id: int) -> void:
	_emit_cemetery_changed(player_id)


func update_all_visuals() -> void:
	"""Emite señales para todos los contadores"""
	for player_id in [0, 1]:
		_emit_deck_changed(player_id)
		_emit_hand_changed(player_id)
		_emit_cemetery_changed(player_id)
		_emit_exile_changed(player_id)
		_emit_field_changed(player_id)


# =============================================================================
# UTILIDADES
# =============================================================================
func find_card_in_cemetery(player_id: int, card_name: String) -> int:
	"""Busca una carta por nombre en el cementerio

	Returns: Índice de la carta o -1 si no se encuentra
	"""
	var cemetery = _zones[player_id].cemetery
	for i in range(cemetery.size()):
		if cemetery[i].get("nombre", "") == card_name:
			return i
	return -1


func get_cemetery_cards_by_type(player_id: int, card_type: int) -> Array:
	"""Obtiene cartas del cementerio filtradas por tipo"""
	var cemetery = _zones[player_id].cemetery
	return cemetery.filter(func(c): return c.get("tipo", -1) == card_type)


func can_draw(player_id: int) -> bool:
	"""Verifica si el jugador puede robar"""
	return not _zones[player_id].deck.is_empty()


func is_defeated(player_id: int) -> bool:
	"""Verifica si el jugador está derrotado (mazo vacío)"""
	return _zones[player_id].deck.is_empty()
