extends Node
class_name SelectionModule
## SelectionModule — Gestiona selecciones de cartas: Exhumar y Buscar en mazo.
## Se instancia como hijo de Main en _ready().

var _main: Node = null
var _pending_exhume_player_id: int = 0
var _pending_search_player_id: int = 0
var _pending_search_callback: Callable = Callable()


func setup(main: Node) -> void:
	_main = main


# =============================================================================
# EXHUMAR
# =============================================================================
func open_exhume_selection(player_id: int = 0) -> void:
	var cemetery = CardManager.get_cemetery(player_id)
	if cemetery.is_empty():
		_main._update_debug("El cementerio está vacío")
		return
	_pending_exhume_player_id = player_id
	if not SelectionManager.card_selected.is_connected(_on_exhume_card_selected):
		SelectionManager.card_selected.connect(_on_exhume_card_selected)
	if not SelectionManager.selection_cancelled.is_connected(_on_exhume_selection_cancelled):
		SelectionManager.selection_cancelled.connect(_on_exhume_selection_cancelled)
	SelectionManager.open_exhumar(cemetery, 1)


func _on_exhume_card_selected(card_data: Dictionary) -> void:
	_disconnect_exhume_signals()
	var player_id = _pending_exhume_player_id
	var card_name = card_data.get("nombre", "?")
	var card_cost = card_data.get("coste", 0)
	_main._update_debug("Exhumando: %s (Coste: %d)" % [card_name, card_cost])
	var puede = GameState.puede_pagar(player_id, card_cost)
	if not puede:
		var oro_actual = GameState.get_oro_reserva(player_id)
		_main._update_debug("Oro insuficiente para exhumar %s (necesitas %d, tienes %d)" % [
			card_name, card_cost, oro_actual])
		return
	var cemetery = CardManager.get_cemetery(player_id)
	var index = _find_card_in_array(cemetery, card_data)
	if index < 0:
		push_error("[SelectionModule] Carta no encontrada en cementerio")
		return
	if card_cost > 0:
		if player_id == 0:
			var paid = await _main._gold_manager.pagar_coste(card_cost)
			if not paid:
				_main._update_debug("Error al pagar coste de exhumar")
				return
		else:
			GameState.pagar_oro(player_id, card_cost)
	var exhumed_data = CardManager.exhume_card(player_id, index)
	exhumed_data["is_exhumed"] = true
	exhumed_data["via_exhumar"] = true
	var ability_data = {
		"name": "Exhumar: %s" % exhumed_data.get("nombre", "?"),
		"type": "exhume",
		"card_to_exhume": exhumed_data,
		"effect": "Poner en juego desde el cementerio"
	}
	var context = {
		"controller_id": player_id,
		"source_zone": Constants.Zone.CEMENTERIO,
		"target_zone": Constants.Zone.LINEA_DEFENSA,
		"cost_paid": card_cost
	}
	var stack_id = ActionPipeline.add_triggered_ability_to_stack(ability_data, exhumed_data, context)
	_main._update_debug("'%s' añadido a la Pila (ID: %d) - Pagado: %d oro" % [
		exhumed_data.get("nombre", "?"), stack_id, card_cost])
	if not ActionPipeline.stack_object_resolved.is_connected(_on_exhume_resolved):
		ActionPipeline.stack_object_resolved.connect(_on_exhume_resolved)


func _on_exhume_resolved(stack_object: Dictionary, _result: Dictionary) -> void:
	var ability_data = stack_object.get("card_data", {})
	if ability_data.get("type") != "exhume":
		return
	var exhumed_data = ability_data.get("card_to_exhume", {})
	if exhumed_data.is_empty():
		return
	var player_id = stack_object.get("context", {}).get("controller_id", 0)
	var card = _main._create_card(exhumed_data)
	card.is_exhumed = true
	_main.player_field.add_child(card)
	card.set_zone(Constants.Zone.LINEA_DEFENSA)
	_main._connect_card_signals(card)
	# Slot fijo (2026-08-31) — ver ZoneManager.pin_card_to_field_slot() y el
	# mismo motivo en GoldManager._play_card_to_field(): sin esto, un Aliado
	# exhumado reordenaba (vía el HBoxContainer) a los que ya estaban en
	# Línea de Defensa.
	if _main.get("_zone_manager"):
		_main._zone_manager.pin_card_to_field_slot(card, _main.player_field)
	_main._update_debug("'%s' entra al campo (exhumado - irá al destierro si muere)" % card.card_name)
	if ActionPipeline.is_stack_empty():
		if ActionPipeline.stack_object_resolved.is_connected(_on_exhume_resolved):
			ActionPipeline.stack_object_resolved.disconnect(_on_exhume_resolved)


func _on_exhume_selection_cancelled() -> void:
	_disconnect_exhume_signals()
	_main._update_debug("Exhumación cancelada")


func _disconnect_exhume_signals() -> void:
	if SelectionManager.card_selected.is_connected(_on_exhume_card_selected):
		SelectionManager.card_selected.disconnect(_on_exhume_card_selected)
	if SelectionManager.selection_cancelled.is_connected(_on_exhume_selection_cancelled):
		SelectionManager.selection_cancelled.disconnect(_on_exhume_selection_cancelled)


# =============================================================================
# BUSCAR EN MAZO
# =============================================================================
func open_search_deck(player_id: int = 0, filter: Callable = Callable(), on_selected: Callable = Callable()) -> void:
	var deck = CardManager.get_deck(player_id)
	if deck.is_empty():
		_main._update_debug("El mazo está vacío")
		return
	_pending_search_player_id = player_id
	_pending_search_callback = on_selected
	if not SelectionManager.card_selected.is_connected(_on_search_card_selected):
		SelectionManager.card_selected.connect(_on_search_card_selected)
	if not SelectionManager.selection_cancelled.is_connected(_on_search_cancelled):
		SelectionManager.selection_cancelled.connect(_on_search_cancelled)
	SelectionManager.open_search(deck, 1, filter)


func _on_search_card_selected(card_data: Dictionary) -> void:
	_disconnect_search_signals()
	_main._update_debug("Buscado: %s" % card_data.get("nombre", "?"))
	if _pending_search_callback.is_valid():
		_pending_search_callback.call(card_data)


func _on_search_cancelled() -> void:
	_disconnect_search_signals()
	_main._update_debug("Búsqueda cancelada")


func _disconnect_search_signals() -> void:
	if SelectionManager.card_selected.is_connected(_on_search_card_selected):
		SelectionManager.card_selected.disconnect(_on_search_card_selected)
	if SelectionManager.selection_cancelled.is_connected(_on_search_cancelled):
		SelectionManager.selection_cancelled.disconnect(_on_search_cancelled)
	_pending_search_callback = Callable()


# =============================================================================
# DESCARTE POR LÍMITE DE MANO (DAR 5.D.4)
# =============================================================================
func open_discard_selection(player_id: int, amount: int) -> void:
	"""Abre la UI para que el jugador elija qué carta(s) descartar por exceder
	el límite de mano. Solo aplica al jugador humano (id 0) — el oponente se
	descarta automáticamente vía PhaseFlowController._opponent_auto_discard()."""
	if player_id != 0:
		return
	var hand_cards: Array = _main.player_hand.cards.duplicate()
	if hand_cards.is_empty():
		return
	amount = mini(amount, hand_cards.size())
	var card_data_list: Array = []
	for card in hand_cards:
		card_data_list.append(card.card_data)
	SelectionManager.open_selection(card_data_list, SelectionManager.SelectionMode.DISCARD, {
		"title": "Descarta %d (límite %d)" % [amount, Constants.MAX_HAND_SIZE],
		"max_selections": amount,
		"min_selections": amount,
		"can_cancel": false
	})
	# max_selections == 1 hace que SelectionManager cierre en el primer clic y
	# emita card_selected en vez de selection_completed (ver _on_card_clicked) —
	# hay que escuchar la señal correcta o el await se queda colgado para siempre.
	var selected_data: Array = []
	if amount == 1:
		selected_data = [await SelectionManager.card_selected]
	else:
		selected_data = await SelectionManager.selection_completed
	var hand_data_list: Array = hand_cards.map(func(c): return c.card_data)
	for data in selected_data:
		var index = _find_card_in_array(hand_data_list, data)
		if index < 0:
			continue
		var card = hand_cards[index]
		var discard_data: Dictionary = data.duplicate()
		discard_data["esta_oculta"] = false
		CardManager.add_to_cemetery(player_id, discard_data)
		_main.player_hand.remove_card(card)
	_main._update_debug("Descarte por límite de mano completado (%d carta(s))" % selected_data.size())
	_main._zone_manager._update_castillo_counts()


# =============================================================================
# REVELAR CARTAS DE DAÑO
# =============================================================================
func reveal_damage_cards(cards: Array) -> void:
	if cards.is_empty():
		return
	SelectionManager.open_reveal(cards, "Cartas enviadas al Cementerio")


# =============================================================================
# UTILIDADES
# =============================================================================
func _find_card_in_array(array: Array, card_data: Dictionary) -> int:
	var search_id = card_data.get("id", "")
	var search_uuid = card_data.get("uuid", "")
	for i in range(array.size()):
		var item = array[i]
		if (search_id and item.get("id") == search_id) or \
		   (search_uuid and item.get("uuid") == search_uuid):
			return i
	return -1
