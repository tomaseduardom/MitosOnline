extends Control
## TestScene - Escenario de pruebas para cartas y efectos
## Permite cargar cartas desde JSON, ejecutar efectos y ver el estado del juego

# =============================================================================
# REFERENCIAS UI
# =============================================================================
var log_text: RichTextLabel
var state_label: Label
var hand_container: HBoxContainer
var field_container: HBoxContainer
var deck_count: Label
var grave_count: Label
var exile_count: Label
var opp_hand_container: HBoxContainer
var opp_field_container: HBoxContainer
var opp_deck_count: Label
var choice_panel: Panel
var choice_container: VBoxContainer
var choice_title: Label
var response_panel: Panel
var response_label: Label


func _get_ui_references() -> void:
	"""Obtiene referencias a nodos UI de forma segura"""
	# UI Layer nodes
	var ui = get_node_or_null("UI")
	if ui:
		log_text = ui.get_node_or_null("LogPanel/LogText")
		state_label = ui.get_node_or_null("StatePanel/StateLabel")
		choice_panel = ui.get_node_or_null("ChoicePanel")
		if choice_panel:
			choice_container = choice_panel.get_node_or_null("ChoiceContainer")
			choice_title = choice_panel.get_node_or_null("ChoiceTitle")
		response_panel = ui.get_node_or_null("ResponsePanel")
		if response_panel:
			response_label = response_panel.get_node_or_null("ResponseLabel")

	# Game area nodes
	var game_area = get_node_or_null("GameArea")
	if game_area:
		var player_zones = game_area.get_node_or_null("PlayerZones")
		if player_zones:
			hand_container = player_zones.get_node_or_null("HandZone/HandContainer")
			field_container = player_zones.get_node_or_null("FieldZone/FieldContainer")
			var side_zones = player_zones.get_node_or_null("SideZones")
			if side_zones:
				deck_count = side_zones.get_node_or_null("DeckZone/DeckCount")
				grave_count = side_zones.get_node_or_null("GraveZone/GraveCount")
				exile_count = side_zones.get_node_or_null("ExileZone/ExileCount")

		var opp_zones = game_area.get_node_or_null("OpponentZones")
		if opp_zones:
			opp_hand_container = opp_zones.get_node_or_null("OppHandZone/OppHandContainer")
			opp_field_container = opp_zones.get_node_or_null("OppFieldZone/OppFieldContainer")
			var opp_side = opp_zones.get_node_or_null("OppSideZones")
			if opp_side:
				opp_deck_count = opp_side.get_node_or_null("OppDeckZone/OppDeckCount")

# =============================================================================
# ESTADO DE PRUEBA
# =============================================================================
var card_scene: PackedScene = preload("res://scenes/cards/Card.tscn")

## Zonas simuladas
var player_deck: Array = []
var player_hand: Array = []
var player_field: Array = []
var player_grave: Array = []
var player_exile: Array = []

var opp_deck: Array = []
var opp_hand: Array = []
var opp_field: Array = []
var opp_grave: Array = []
var opp_exile: Array = []

## Tracking de cartas jugadas este turno (para restricción ONLY_ONE_PER_TURN)
var cards_played_this_turn: Dictionary = {}  # {card_name: count}

## Exhumar - tracking de cartas jugadas desde cementerio
var _playing_from_cemetery: bool = false

## Turno actual
var current_turn: int = 1
var active_player: int = 0  # 0 = player, 1 = opponent

## Carta actualmente seleccionada
var selected_card: Node = null

## Callback para selección de opciones
var _choice_callback: Callable = Callable()
var _choice_amount: int = 0
var _selected_choices: Array = []

## Ventana de respuesta (Paso D)
var _waiting_for_response: bool = false
var _pending_effects: Array = []  # Efectos pendientes de ejecutar tras respuesta
var _current_card_data: Dictionary = {}  # Carta siendo resuelta
var _was_annulled: bool = false  # Si la carta fue anulada
var _response_result: Dictionary = {}  # Resultado de la ventana de respuesta

## Módulos extraídos (Fase 4 de reestructuración)
var _ui_builder: TestUIBuilder
var _card_resolvers: TestCardResolvers


func _ready() -> void:
	# Esperar un frame para que los nodos estén listos
	await get_tree().process_frame

	# Inicializar módulos extraídos
	_ui_builder = TestUIBuilder.new()
	_ui_builder.setup(self)
	_card_resolvers = TestCardResolvers.new()
	_card_resolvers.setup(self)

	# Obtener referencias UI
	_get_ui_references()

	_log("=== ESCENARIO DE PRUEBAS INICIADO ===")
	_log("Usa los botones para cargar cartas y ejecutar acciones")

	# Ocultar paneles
	if choice_panel:
		choice_panel.visible = false
	if response_panel:
		response_panel.visible = false

	# Conectar botones
	_connect_buttons()

	# Inicializar mazo con cartas dummy
	_setup_test_decks()

	# Inicializar CombatLog con turno 1
	CombatLog._on_turn_manager_turn_started(active_player, current_turn)
	CombatLog._on_turn_phase_changed(Constants.Phase.VIGILIA)

	# Actualizar UI
	_update_state_display()


func _connect_buttons() -> void:
	var btn_panel = get_node_or_null("UI/ButtonPanel")
	if not btn_panel:
		push_error("[TestScene] ButtonPanel no encontrado")
		return

	var load_btn = btn_panel.get_node_or_null("LoadCardBtn")
	var draw_btn = btn_panel.get_node_or_null("DrawBtn")
	var play_btn = btn_panel.get_node_or_null("PlayCardBtn")
	var end_btn = btn_panel.get_node_or_null("EndTurnBtn")
	var test_btn = btn_panel.get_node_or_null("TestEffectBtn")
	var clear_btn = btn_panel.get_node_or_null("ClearLogBtn")
	var reset_btn = btn_panel.get_node_or_null("ResetBtn")

	if load_btn: load_btn.pressed.connect(_on_load_card_pressed)
	if draw_btn: draw_btn.pressed.connect(_on_draw_pressed)
	if play_btn: play_btn.pressed.connect(_on_play_card_pressed)
	if end_btn: end_btn.pressed.connect(_on_end_turn_pressed)
	if test_btn: test_btn.pressed.connect(_on_test_effect_pressed)
	if clear_btn: clear_btn.pressed.connect(_on_clear_log_pressed)
	if reset_btn: reset_btn.pressed.connect(_on_reset_pressed)


func _setup_test_decks() -> void:
	"""Crea mazos de prueba con cartas dummy"""
	# Crear 30 cartas dummy para cada jugador
	for i in range(30):
		player_deck.append({
			"id": "dummy_%d" % i,
			"nombre": "Carta Dummy %d" % (i + 1),
			"tipo": Constants.CardType.ALIADO,
			"coste": (i % 5) + 1,
			"fuerza": (i % 4) + 1,
			"habilidad": ""
		})
		opp_deck.append({
			"id": "opp_dummy_%d" % i,
			"nombre": "Carta Oponente %d" % (i + 1),
			"tipo": Constants.CardType.ALIADO,
			"coste": (i % 5) + 1,
			"fuerza": (i % 4) + 1,
			"habilidad": ""
		})

	# Barajar
	player_deck.shuffle()
	opp_deck.shuffle()

	_log("Mazos inicializados: 30 cartas cada uno")


# =============================================================================
# ACCIONES DE PRUEBA
# =============================================================================
func _on_load_card_pressed() -> void:
	"""Busca un mazo 'dragon' en la API y lo carga con DeckLoader"""
	_log("Buscando mazo dragon en la API...")

	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_search_dragon_completed.bind(http))
	var err := http.request("http://localhost:3000/api/mazos/publicos?search=dragon&limit=5")
	if err != OK:
		_log("[ERROR] No se pudo iniciar la request HTTP: %d" % err)
		http.queue_free()


func _on_search_dragon_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest) -> void:
	http.queue_free()

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_log("[ERROR] Búsqueda fallida (HTTP %d, result %d)" % [response_code, result])
		return

	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		_log("[ERROR] JSON inválido en respuesta de búsqueda")
		return

	var data: Dictionary = json.get_data()
	var mazos: Array = data.get("mazos", [])
	if mazos.is_empty():
		_log("[WARN] No se encontró ningún mazo con 'dragon'")
		return

	var primer_mazo: Dictionary = mazos[0]
	var slug: String = primer_mazo.get("slug", "")
	var nombre: String = primer_mazo.get("nombre", slug)
	_log("Mazo encontrado: %s (%s)" % [nombre, slug])

	# Conectar señal de DeckLoader y cargar
	if not DeckLoader.deck_loaded.is_connected(_on_deck_dragon_loaded):
		DeckLoader.deck_loaded.connect(_on_deck_dragon_loaded)
	if not DeckLoader.deck_load_failed.is_connected(_on_deck_dragon_failed):
		DeckLoader.deck_load_failed.connect(_on_deck_dragon_failed)

	DeckLoader.load_deck_for_player(0, slug)


func _on_deck_dragon_loaded(player_id: int, card_count: int) -> void:
	if player_id != 0:
		return
	DeckLoader.deck_loaded.disconnect(_on_deck_dragon_loaded)
	DeckLoader.deck_load_failed.disconnect(_on_deck_dragon_failed)

	player_deck = DeckLoader.loaded_decks[0].duplicate()
	_log("✓ Mazo real cargado: %d cartas" % card_count)
	_update_state_display()

	# Diagnóstico de imágenes por carta
	CardDatabase.check_deck_images(player_deck)


func _on_deck_dragon_failed(player_id: int, error: String) -> void:
	if player_id != 0:
		return
	DeckLoader.deck_loaded.disconnect(_on_deck_dragon_loaded)
	DeckLoader.deck_load_failed.disconnect(_on_deck_dragon_failed)
	_log("[ERROR] Falló la carga del mazo: %s" % error)


func _on_draw_pressed() -> void:
	"""Roba una carta"""
	if not hand_container:
		_log("[ERROR] Hand container no disponible")
		return

	if player_deck.is_empty():
		_log("[WARN] Mazo vacío!")
		return

	var card_data = player_deck.pop_front()
	player_hand.append(card_data)
	_create_card_visual(card_data, hand_container, 0)

	_log("Robaste: %s" % card_data.get("nombre", card_data.get("name", "???")))
	_update_state_display()


func _on_play_card_pressed() -> void:
	"""Juega la carta seleccionada"""
	if not selected_card:
		_log("[WARN] Selecciona una carta primero (clic en ella)")
		return

	var card_data = selected_card.get_meta("card_data", {})
	var card_name = card_data.get("name", card_data.get("nombre", "???"))

	# Verificar restricción ONLY_ONE_PER_TURN
	var restrictions = card_data.get("restrictions", [])
	if "ONLY_ONE_PER_TURN" in restrictions:
		if cards_played_this_turn.has(card_name):
			_log("[BLOQUEADO] Ya jugaste '%s' este turno!" % card_name)
			return

	_log("Jugando: %s" % card_name)

	# Registrar carta jugada
	cards_played_this_turn[card_name] = cards_played_this_turn.get(card_name, 0) + 1

	# Procesar carta según su tipo
	var card_type = card_data.get("type", card_data.get("tipo", ""))

	if card_type == "Talisman" or card_type == Constants.CardType.TALISMAN:
		# Los talismanes se resuelven y van al destino indicado
		await _card_resolvers.resolve_talisman(card_data)
	else:
		# Otras cartas van al campo
		_move_card_to_zone(selected_card, card_data, "field")

	_update_state_display()


func _on_end_turn_pressed() -> void:
	"""Termina el turno actual"""
	# Notificar fin de turno al CombatLog
	CombatLog._on_turn_manager_turn_ended(active_player)

	current_turn += 1
	active_player = 1 - active_player
	cards_played_this_turn.clear()

	# Notificar inicio de nuevo turno al CombatLog
	CombatLog._on_turn_manager_turn_started(active_player, current_turn)
	# Simular fase de Vigilia al inicio del turno
	CombatLog._on_turn_phase_changed(Constants.Phase.VIGILIA)

	_log("Turno %d iniciado" % current_turn)
	_update_state_display()


func _on_test_effect_pressed() -> void:
	"""Ejecuta un efecto de prueba"""
	# Mostrar menú de efectos de prueba
	var options = [
		{"id": "draw2", "text": "Robar 2 cartas"},
		{"id": "mill3", "text": "Oponente bota 3"},
		{"id": "destroy", "text": "Destruir carta del campo"},
		{"id": "search", "text": "Buscar en mazo"},
		{"id": "add_hacer_bien", "text": "Añadir Hacer el Bien al cementerio oponente"},
		{"id": "show_exhumar", "text": "Ver cartas con Exhumar"}
	]

	await _ui_builder.show_choice_ui("Selecciona efecto a probar:", options, 1)

	if _selected_choices.is_empty():
		return

	var choice = _selected_choices[0]
	match choice:
		"draw2":
			await _execute_draw(0, 2)
		"mill3":
			await _execute_mill(1, 3)
		"destroy":
			_log("Selecciona carta del campo a destruir")
		"search":
			await _execute_search(0, "DECK", {}, 1)
		"add_hacer_bien":
			_add_hacer_bien_to_cemetery()
		"show_exhumar":
			_show_exhumable_cards()


func _add_hacer_bien_to_cemetery() -> void:
	"""Añade Hacer el Bien al cementerio del oponente para probar Exhumar"""
	var hacer_bien_data = TestCardLoader.load_card_json("res://hacer_el_bien.json")

	if hacer_bien_data.is_empty():
		hacer_bien_data = {
			"id": "tk22-09",
			"name": "Hacer el Bien",
			"type": "Talisman",
			"cost": 1,
			"traits": {"is_unique": true, "has_exhumar": true},
			"hability_blocks": [{
				"trigger": "ON_PLAY",
				"type": "RESPONSE",
				"target_type": "CARD_IN_STACK",
				"conditions": [{"attribute": "cost", "operator": "<=", "value": 3}],
				"effect": {"action": "ANNUL", "destination": "CEMENTERIO"}
			}],
			"resolution_rules": {
				"on_resolve": "MOVE_TO_CEMENTERIO",
				"on_exhumar_resolve": "MOVE_TO_DESTIERRO"
			}
		}

	opp_grave.append(hacer_bien_data)
	_log("[TEST] Hacer el Bien añadida al cementerio del oponente")
	_log("[TEST] El oponente puede jugarla via EXHUMAR")
	_update_state_display()


func _show_exhumable_cards() -> void:
	"""Muestra las cartas con Exhumar en ambos cementerios"""
	var executor = _get_action_executor()

	_log("═══════════════════════════════════════")
	_log("CARTAS CON EXHUMAR EN CEMENTERIOS:")
	_log("───────────────────────────────────────")

	# Cementerio del jugador
	if executor:
		var player_exhumable = executor.get_exhumable_cards(0, player_grave)
		_log("Jugador 1 (%d cartas):" % player_exhumable.size())
		for card in player_exhumable:
			_log("  • %s (Coste: %d)" % [card.get("name", "???"), card.get("cost", 0)])

		# Cementerio del oponente
		var opp_exhumable = executor.get_exhumable_cards(1, opp_grave)
		_log("Jugador 2 (%d cartas):" % opp_exhumable.size())
		for card in opp_exhumable:
			_log("  • %s (Coste: %d)" % [card.get("name", "???"), card.get("cost", 0)])
	else:
		# Fallback manual
		_log("Jugador 1: %d cartas en cementerio" % player_grave.size())
		_log("Jugador 2: %d cartas en cementerio" % opp_grave.size())

	_log("═══════════════════════════════════════")


func _on_clear_log_pressed() -> void:
	if log_text:
		log_text.text = ""


func _on_reset_pressed() -> void:
	"""Reinicia el escenario de pruebas"""
	# Limpiar zonas
	if hand_container:
		for child in hand_container.get_children():
			child.queue_free()
	if field_container:
		for child in field_container.get_children():
			child.queue_free()
	if opp_hand_container:
		for child in opp_hand_container.get_children():
			child.queue_free()
	if opp_field_container:
		for child in opp_field_container.get_children():
			child.queue_free()

	player_deck.clear()
	player_hand.clear()
	player_field.clear()
	player_grave.clear()
	player_exile.clear()
	opp_deck.clear()
	opp_hand.clear()
	opp_field.clear()
	opp_grave.clear()
	opp_exile.clear()

	cards_played_this_turn.clear()
	current_turn = 1
	active_player = 0
	selected_card = null

	_setup_test_decks()
	_log("=== ESCENARIO REINICIADO ===")
	_update_state_display()


# =============================================================================
# ACCIONES BÁSICAS
# =============================================================================
func _execute_draw(player_id: int, amount: int) -> void:
	"""Ejecuta robo de cartas (privado - no público)"""
	var deck = player_deck if player_id == 0 else opp_deck
	var hand = player_hand if player_id == 0 else opp_hand
	var container = hand_container if player_id == 0 else opp_hand_container

	var drawn = 0
	var drawn_cards: Array = []

	for i in range(amount):
		if deck.is_empty():
			_log("[WARN] Mazo vacío, solo se robaron %d" % drawn, "warning")
			break

		var card = deck.pop_front()
		hand.append(card)
		drawn_cards.append(card)
		_create_card_visual(card, container, player_id)
		drawn += 1

		await get_tree().create_timer(0.15).timeout

	# Robar NO es público (oponente solo ve cantidad, no cartas)
	CombatLog._on_draw(player_id, drawn_cards, drawn)

	_log("Jugador %d robó %d carta(s)" % [player_id + 1, drawn], "draw")
	_update_state_display()


func _execute_mill(player_id: int, amount: int) -> void:
	"""Ejecuta botar cartas del mazo al cementerio (ACCIÓN PÚBLICA)"""
	var deck = player_deck if player_id == 0 else opp_deck
	var grave = player_grave if player_id == 0 else opp_grave

	var milled = 0
	var milled_cards: Array = []

	for i in range(amount):
		if deck.is_empty():
			break

		var card = deck.pop_front()
		grave.append(card)
		milled += 1
		milled_cards.append(card)

		var card_name = card.get("nombre", card.get("name", "???"))
		_log("  Botada: %s" % card_name, "mill")

		await get_tree().create_timer(0.1).timeout

	# Registrar en CombatLog como acción pública (visible para ambos)
	CombatLog._on_mill(player_id, milled_cards, false)

	_log("Jugador %d botó %d carta(s)" % [player_id + 1, milled], "mill")
	_update_state_display()


func _execute_search(player_id: int, zone: String, filter: Dictionary, amount: int) -> void:
	"""Ejecuta búsqueda en zona (ACCIÓN PÚBLICA - oponente ve resultado)"""
	var deck = player_deck if player_id == 0 else opp_deck
	var hand = player_hand if player_id == 0 else opp_hand
	var container = hand_container if player_id == 0 else opp_hand_container

	# Filtrar cartas
	var matching: Array = []
	for card in deck:
		if TestCardLoader.card_matches_filter(card, filter):
			matching.append(card)

	if matching.is_empty():
		_log("No se encontraron cartas que coincidan", "search")
		return

	# Mostrar opciones de búsqueda (simplificado: toma las primeras N)
	var to_take = mini(amount, matching.size())
	var found_cards: Array = []

	for i in range(to_take):
		var card = matching[i]
		deck.erase(card)
		hand.append(card)
		found_cards.append(card)
		_create_card_visual(card, container, player_id)

		var card_name = card.get("nombre", card.get("name", "???"))
		_log("  Encontrada: %s" % card_name, "search")

	# Registrar en CombatLog como acción pública
	CombatLog._on_search(player_id, found_cards, Constants.Zone.CASTILLO)

	# Barajar mazo
	deck.shuffle()
	_log("Mazo barajado", "info")
	_update_state_display()


# =============================================================================
# HELPERS PARA AUTOLOADS
# =============================================================================
func _get_action_executor() -> Node:
	return ActionExecutor


func _get_action_executor_emit(signal_name: String, arg1 = null, arg2 = null, arg3 = null) -> void:
	var executor = _get_action_executor()
	if executor:
		if arg3 != null:
			executor.emit_signal(signal_name, arg1, arg2, arg3)
		elif arg2 != null:
			executor.emit_signal(signal_name, arg1, arg2)
		elif arg1 != null:
			executor.emit_signal(signal_name, arg1)
		else:
			executor.emit_signal(signal_name)


func _get_action_executor_pass() -> void:
	var executor = _get_action_executor()
	if executor:
		executor.pass_response()


func _get_action_executor_sync(player_id: int, card_data: Dictionary, effects: Array) -> void:
	var executor = _get_action_executor()
	if executor:
		executor.sync_effects_to_opponent(player_id, card_data, effects)


# =============================================================================
# UTILIDADES
# =============================================================================
func _create_card_visual(card_data: Dictionary, container: Node, player_id: int) -> void:
	"""Crea representación visual de una carta"""
	if not container:
		_log("[ERROR] Container no disponible")
		return

	var card = card_scene.instantiate()
	# Mantener el tamaño natural de la carta (150×210) para que
	# toda la superficie sea clickeable. Reducirlo causa que solo
	# la porción superior responda a gui_input.
	card.custom_minimum_size = Vector2(150, 210)

	# Mapear datos
	var mapped_data = {
		"id": card_data.get("id", "test"),
		"nombre": card_data.get("name", card_data.get("nombre", "???")),
		"coste": card_data.get("cost", card_data.get("coste", 0)),
		"fuerza": card_data.get("strength", card_data.get("fuerza", 0)),
		"tipo": TestCardLoader.map_type(card_data.get("type", card_data.get("tipo", ""))),
		"habilidad": card_data.get("ability", card_data.get("habilidad", ""))
	}

	card.load_from_data(mapped_data)
	card.owner_id = player_id
	card.esta_oculta = (player_id == 1)  # Ocultar cartas del oponente
	card.set_meta("card_data", card_data)

	# Conectar click
	card.card_clicked.connect(_on_card_clicked)

	container.add_child(card)


func _on_card_clicked(card: Node) -> void:
	"""Maneja clic en una carta"""
	# Deseleccionar anterior
	if selected_card and is_instance_valid(selected_card):
		selected_card.deselect()

	selected_card = card
	card.select()

	var card_data = card.get_meta("card_data", {})
	var name = card_data.get("name", card_data.get("nombre", "???"))
	_log("Seleccionada: %s" % name)


func _move_card_to_zone(card_visual: Node, card_data: Dictionary, zone: String) -> void:
	"""Mueve una carta a una zona"""
	match zone:
		"field":
			player_field.append(card_data)
			var idx = player_hand.find(card_data)
			if idx >= 0:
				player_hand.remove_at(idx)
			card_visual.reparent(field_container)


func _move_to_grave(card_data: Dictionary) -> void:
	player_grave.append(card_data)


func _move_to_exile(card_data: Dictionary) -> void:
	player_exile.append(card_data)


func _log(message: String, type: String = "info") -> void:
	"""Agrega mensaje al log local y al CombatLog global"""
	# Log local
	if log_text:
		var timestamp = Time.get_time_string_from_system()
		log_text.append_text("[%s] %s\n" % [timestamp.substr(0, 5), message])
		log_text.scroll_to_line(log_text.get_line_count())
	else:
		print("[TestScene] %s" % message)

	# También enviar al CombatLog global
	var log_type = type
	if "PASO A" in message or "PASO D" in message or "PASO E" in message:
		log_type = "phase"
	elif "ANULACIÓN" in message or "ANULÓ" in message:
		log_type = "annul"
	elif "robó" in message.to_lower() or "robar" in message.to_lower():
		log_type = "draw"
	elif "botó" in message.to_lower() or "mill" in message.to_lower():
		log_type = "mill"
	elif "SECCIÓN" in message:
		log_type = "resolution"

	CombatLog.add_entry(log_type, message)


func _update_state_display() -> void:
	"""Actualiza la visualización del estado"""
	var state_text = """TURNO: %d | Jugador Activo: %d

JUGADOR:
  Mazo: %d | Mano: %d | Campo: %d
  Cementerio: %d | Destierro: %d

OPONENTE:
  Mazo: %d | Mano: %d | Campo: %d
  Cementerio: %d | Destierro: %d

Cartas jugadas este turno: %s""" % [
		current_turn, active_player + 1,
		player_deck.size(), player_hand.size(), player_field.size(),
		player_grave.size(), player_exile.size(),
		opp_deck.size(), opp_hand.size(), opp_field.size(),
		opp_grave.size(), opp_exile.size(),
		str(cards_played_this_turn.keys())
	]

	if state_label:
		state_label.text = state_text

	# Actualizar contadores
	if deck_count:
		deck_count.text = str(player_deck.size())
	if grave_count:
		grave_count.text = str(player_grave.size())
	if exile_count:
		exile_count.text = str(player_exile.size())
	if opp_deck_count:
		opp_deck_count.text = str(opp_deck.size())
