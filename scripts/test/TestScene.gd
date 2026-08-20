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


func _ready() -> void:
	# Esperar un frame para que los nodos estén listos
	await get_tree().process_frame

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
	var combat_log = get_node_or_null("/root/CombatLog")
	if combat_log:
		combat_log._on_turn_manager_turn_started(active_player, current_turn)
		combat_log._on_turn_phase_changed(Constants.Phase.VIGILIA)

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
	var dl := get_node_or_null("/root/DeckLoader")
	if not dl:
		_log("[ERROR] DeckLoader no encontrado")
		return

	if not dl.deck_loaded.is_connected(_on_deck_dragon_loaded):
		dl.deck_loaded.connect(_on_deck_dragon_loaded)
	if not dl.deck_load_failed.is_connected(_on_deck_dragon_failed):
		dl.deck_load_failed.connect(_on_deck_dragon_failed)

	dl.load_deck_for_player(0, slug)


func _on_deck_dragon_loaded(player_id: int, card_count: int) -> void:
	if player_id != 0:
		return
	var dl := get_node("/root/DeckLoader")
	dl.deck_loaded.disconnect(_on_deck_dragon_loaded)
	dl.deck_load_failed.disconnect(_on_deck_dragon_failed)

	player_deck = dl.loaded_decks[0].duplicate()
	_log("✓ Mazo real cargado: %d cartas" % card_count)
	_update_state_display()

	# Diagnóstico de imágenes por carta
	CardDatabase.check_deck_images(player_deck)


func _on_deck_dragon_failed(player_id: int, error: String) -> void:
	if player_id != 0:
		return
	var dl := get_node("/root/DeckLoader")
	dl.deck_loaded.disconnect(_on_deck_dragon_loaded)
	dl.deck_load_failed.disconnect(_on_deck_dragon_failed)
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
		await _resolve_talisman(card_data)
	else:
		# Otras cartas van al campo
		_move_card_to_zone(selected_card, card_data, "field")

	_update_state_display()


func _on_end_turn_pressed() -> void:
	"""Termina el turno actual"""
	# Notificar fin de turno al CombatLog
	var combat_log = get_node_or_null("/root/CombatLog")
	if combat_log:
		combat_log._on_turn_manager_turn_ended(active_player)

	current_turn += 1
	active_player = 1 - active_player
	cards_played_this_turn.clear()

	# Notificar inicio de nuevo turno al CombatLog
	if combat_log:
		combat_log._on_turn_manager_turn_started(active_player, current_turn)
		# Simular fase de Vigilia al inicio del turno
		combat_log._on_turn_phase_changed(Constants.Phase.VIGILIA)

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

	await _show_choice_ui("Selecciona efecto a probar:", options, 1)

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
	var hacer_bien_data = _load_card_json("res://hacer_el_bien.json")

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
# RESOLUCIÓN DE CARTAS
# =============================================================================
func _resolve_talisman(card_data: Dictionary) -> void:
	"""Resuelve un talismán y sus efectos siguiendo el flujo DAR"""
	var card_name = card_data.get("name", "???")

	_log("═══════════════════════════════════════════════")
	_log("RESOLVIENDO TALISMÁN: %s" % card_name)
	_log("═══════════════════════════════════════════════")

	# Verificar si tiene choice_config
	var choice_config = card_data.get("choice_config", {})

	if not choice_config.is_empty():
		await _resolve_choice_card(card_data)
	else:
		_log("Talismán resuelto (sin efectos especiales)")

	# =========================================================================
	# DESTINO FINAL (Sección 8 vs Sección 17)
	# =========================================================================
	_log("───────────────────────────────────────────────")
	_log("DESTINO FINAL:")

	# Sección 8: Si fue anulada, el destino propio de la carta tiene prioridad
	if _was_annulled:
		# El destino ya fue calculado considerando BANISH_SELF
		var final_dest = _response_result.get("annul_destination", "CEMENTERIO")

		match final_dest:
			"DESTIERRO":
				_move_to_exile(card_data)
				_log("[SECCIÓN 8] %s → DESTIERRO (anulada, pero carta dice destiérrala)" % card_name)
			_:
				_move_to_grave(card_data)
				_log("[SECCIÓN 8] %s → CEMENTERIO (anulada)" % card_name)

		_log("  • El pipeline fue cancelado")
		_log("  • Efectos no se resolvieron")
		_was_annulled = false  # Reset flag
	else:
		# Sección 17: Destino según condición on_resolution
		# Usar ActionExecutor para determinar destino correcto
		var executor = _get_action_executor()
		var final_dest = "CEMENTERIO"

		if executor:
			final_dest = executor.get_final_destination(card_data)

		match final_dest:
			"DESTIERRO":
				_move_to_exile(card_data)
				if executor and executor.is_played_via_exhumar():
					_log("[EXHUMAR] %s → DESTIERRO (jugada via Exhumar)" % card_name)
				else:
					_log("[SECCIÓN 17] %s → DESTIERRO" % card_name)
					_log("  • Condición: BANISH_SELF cumplida")
			"MANO":
				# TODO: Implementar retorno a mano
				_log("[SECCIÓN 17] %s → MANO (no implementado)" % card_name)
			"CASTILLO":
				# TODO: Implementar retorno al mazo
				_log("[SECCIÓN 17] %s → MAZO (no implementado)" % card_name)
			_:
				_move_to_grave(card_data)
				_log("[SECCIÓN 17] %s → CEMENTERIO (por defecto)" % card_name)

	_log("═══════════════════════════════════════════════")

	# Remover carta visual de la mano
	if selected_card:
		selected_card.queue_free()
		selected_card = null

	# Remover de player_hand
	var idx = -1
	for i in range(player_hand.size()):
		if player_hand[i].get("name", "") == card_name or player_hand[i].get("nombre", "") == card_name:
			idx = i
			break
	if idx >= 0:
		player_hand.remove_at(idx)


func _resolve_choice_card(card_data: Dictionary) -> void:
	"""Resuelve una carta con sistema de elección"""
	var choice_config = card_data.get("choice_config", {})
	var amount_to_choose = choice_config.get("amount_to_choose", 1)
	var options = choice_config.get("options", [])
	var card_name = card_data.get("name", "???")

	if options.is_empty():
		_log("[ERROR] Carta sin opciones definidas")
		return

	# Guardar referencia a carta actual
	_current_card_data = card_data
	_was_annulled = false

	# =========================================================================
	# REGISTRAR EN PIPELINE (expuesta a respuestas)
	# =========================================================================
	var executor = _get_action_executor()
	if executor:
		executor.enter_pipeline(card_data, {
			"controller_id": active_player,
			"phase": "choice"
		})

	# =========================================================================
	# PASO A: Jugador elige efectos
	# =========================================================================
	_log("[PASO A] Elige %d opción(es):" % amount_to_choose)

	var formatted_options: Array = []
	for opt in options:
		formatted_options.append({
			"id": opt.get("id", ""),
			"text": opt.get("text", "???")
		})

	await _show_choice_ui("Elige %d efectos:" % amount_to_choose, formatted_options, amount_to_choose)

	if _selected_choices.size() < amount_to_choose:
		_log("[WARN] Selección incompleta")
		return

	# Guardar efectos pendientes
	_pending_effects.clear()
	for choice_id in _selected_choices:
		for opt in options:
			if opt.get("id", "") == choice_id:
				_pending_effects.append(opt)
				break

	_log("[PASO A] Efectos elegidos: %s" % str(_selected_choices))

	# =========================================================================
	# ACTUALIZAR PIPELINE con efectos pendientes
	# =========================================================================
	if executor:
		var ctx = executor.get_pipeline_context()
		ctx["pending_effects"] = _pending_effects.duplicate()
		ctx["phase"] = "waiting_response"

	# =========================================================================
	# SINCRONIZACIÓN: Enviar efectos al oponente
	# =========================================================================
	_sync_effects_to_opponent(card_data, _pending_effects)

	# =========================================================================
	# PASO D: Ventana de respuesta del oponente
	# =========================================================================
	_log("[PASO D] Ventana de respuesta - Oponente puede responder...")

	var response_result = await _open_response_window(card_name, _pending_effects)

	# =========================================================================
	# SECCIÓN 8: Verificar si hubo ANULACIÓN
	# =========================================================================
	if response_result.had_response and response_result.get("is_annullment", false):
		_log("[ANULACIÓN] ¡%s fue ANULADA!" % card_name)
		_was_annulled = true
		_pending_effects.clear()
		# La carta va al cementerio, no al destierro
		return

	if response_result.had_response:
		_log("[PASO D] Oponente respondió (no fue anulación)")
	else:
		_log("[PASO D] Oponente pasó")

	# =========================================================================
	# PASO E: Resolución - Ejecutar efectos (Sección 17 - Condición)
	# =========================================================================
	if not _was_annulled:
		_log("[PASO E] ═══════════════════════════════════════")
		_log("[PASO E] RESOLUCIÓN - Oponente pasó prioridad")
		_log("[PASO E] Ejecutando %d efecto(s)..." % _pending_effects.size())

		# Emitir señal de inicio de resolución
		_get_action_executor_emit("resolution_started", null, _pending_effects)

		var effects_resolved: int = 0
		for effect_opt in _pending_effects:
			effects_resolved += 1
			_log("[PASO E] Efecto %d/%d:" % [effects_resolved, _pending_effects.size()])
			await _execute_choice_action(effect_opt)
			# Pequeña pausa entre efectos para visualización
			await get_tree().create_timer(0.3).timeout

		_log("[PASO E] ✓ Todos los efectos resueltos (%d/%d)" % [effects_resolved, _pending_effects.size()])
		_log("[PASO E] ═══════════════════════════════════════")

		# Emitir señal de resolución completada
		_get_action_executor_emit("resolution_completed", null, true, effects_resolved)

		# Sección 17: Verificar condición post-resolución
		_check_post_resolution_condition(card_data)

	_pending_effects.clear()
	_current_card_data = {}

	# =========================================================================
	# SALIR DEL PIPELINE
	# =========================================================================
	var executor_exit = _get_action_executor()
	if executor_exit:
		executor_exit.exit_pipeline()


func _execute_choice_action(option: Dictionary) -> void:
	"""Ejecuta la acción de una opción elegida"""
	var action = option.get("action", {})
	var action_type = action.get("type", "")
	var value = action.get("value", 1)
	var target = action.get("target", "SELF")

	_log("Ejecutando: %s" % option.get("text", "???"))

	var player_id = 0 if target == "SELF" else 1

	match action_type:
		"DRAW":
			await _execute_draw(player_id, value)
		"MILL":
			await _execute_mill(player_id, value)
		"SEARCH":
			var zone = action.get("zone", "DECK")
			var filter = action.get("filter", {})
			await _execute_search(player_id, zone, filter, value)
		"DESTROY":
			_log("[TODO] Destruir implementación")
		"DAMAGE":
			_log("[TODO] Daño implementación")
		_:
			_log("[WARN] Acción no implementada: %s" % action_type)


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
	var combat_log = get_node_or_null("/root/CombatLog")
	if combat_log:
		combat_log._on_draw(player_id, drawn_cards, drawn)

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
	var combat_log = get_node_or_null("/root/CombatLog")
	if combat_log:
		combat_log._on_mill(player_id, milled_cards, false)

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
		if _card_matches_filter(card, filter):
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
	var combat_log = get_node_or_null("/root/CombatLog")
	if combat_log:
		combat_log._on_search(player_id, found_cards, Constants.Zone.CASTILLO)

	# Barajar mazo
	deck.shuffle()
	_log("Mazo barajado", "info")
	_update_state_display()


func _card_matches_filter(card: Dictionary, filter: Dictionary) -> bool:
	"""Verifica si una carta coincide con un filtro"""
	if filter.is_empty():
		return true

	# Filtro exclude_type
	if filter.has("exclude_type"):
		var card_type = card.get("type", card.get("tipo", ""))
		var exclude = filter.exclude_type

		# Normalizar card_type a String para comparación
		var card_type_str: String = ""
		if card_type is int:
			match card_type:
				Constants.CardType.TALISMAN: card_type_str = "Talisman"
				Constants.CardType.ALIADO: card_type_str = "Aliado"
				Constants.CardType.ARMA: card_type_str = "Arma"
				Constants.CardType.TOTEM: card_type_str = "Totem"
				Constants.CardType.ORO: card_type_str = "Oro"
		else:
			card_type_str = str(card_type)

		# Comparar como strings (case insensitive)
		if card_type_str.to_lower() == str(exclude).to_lower():
			return false

	return true


# =============================================================================
# UI DE ELECCIÓN
# =============================================================================
func _show_choice_ui(title: String, options: Array, amount: int) -> void:
	"""Muestra la UI de selección de opciones"""
	if not choice_panel or not choice_title or not choice_container:
		_log("[ERROR] UI de elección no disponible")
		return

	choice_title.text = title
	_choice_amount = amount
	_selected_choices.clear()

	# Limpiar opciones anteriores
	for child in choice_container.get_children():
		child.queue_free()

	# Crear botones de opción
	for opt in options:
		var btn = Button.new()
		btn.text = opt.get("text", "???")
		btn.custom_minimum_size = Vector2(300, 40)
		btn.set_meta("option_id", opt.get("id", ""))
		btn.pressed.connect(_on_choice_selected.bind(btn))
		choice_container.add_child(btn)

	# Botón confirmar
	var confirm_btn = Button.new()
	confirm_btn.text = "Confirmar Selección"
	confirm_btn.custom_minimum_size = Vector2(300, 50)
	confirm_btn.pressed.connect(_on_choice_confirmed)
	confirm_btn.set_meta("is_confirm", true)
	choice_container.add_child(confirm_btn)

	choice_panel.visible = true

	# Esperar a que el usuario confirme
	await _wait_for_choice()


func _on_choice_selected(btn: Button) -> void:
	"""Maneja selección de opción"""
	var opt_id = btn.get_meta("option_id", "")

	if opt_id in _selected_choices:
		_selected_choices.erase(opt_id)
		btn.modulate = Color.WHITE
	else:
		if _selected_choices.size() < _choice_amount:
			_selected_choices.append(opt_id)
			btn.modulate = Color(0.5, 1.0, 0.5)
		else:
			_log("[INFO] Ya seleccionaste %d opción(es)" % _choice_amount)


func _on_choice_confirmed() -> void:
	"""Confirma la selección"""
	if _selected_choices.size() < _choice_amount:
		_log("[WARN] Debes seleccionar %d opción(es)" % _choice_amount)
		return

	if choice_panel:
		choice_panel.visible = false


func _wait_for_choice() -> void:
	"""Espera hasta que el panel de elección se cierre"""
	if not choice_panel:
		return
	while choice_panel.visible:
		await get_tree().process_frame


# =============================================================================
# PASO D - VENTANA DE RESPUESTA
# =============================================================================
var _response_result: Dictionary = {}  # Resultado de la ventana de respuesta

func _open_response_window(card_name: String, pending_effects: Array) -> Dictionary:
	"""Abre la ventana de respuesta para el oponente (Paso D)

	Returns: {had_response, response_card, passed, is_annullment}
	"""
	_response_result = {
		"had_response": false,
		"response_card": null,
		"passed": false,
		"is_annullment": false
	}

	_waiting_for_response = true

	# Emitir señal para sistemas externos
	_get_action_executor_emit("waiting_for_opponent_response", null, {
		"card_name": card_name,
		"effects": pending_effects
	})

	# Mostrar UI de respuesta
	_show_response_ui(card_name, pending_effects)

	# Esperar decisión
	await _wait_for_response()

	return _response_result


func _show_response_ui(card_name: String, effects: Array) -> void:
	"""Muestra la UI para que el oponente responda o pase"""
	# Crear panel de respuesta si no existe
	if not response_panel:
		_create_response_panel()

	if not response_panel:
		# Fallback: usar timer automático
		_log("[INFO] Panel de respuesta no disponible - auto-pass en 3s")
		await get_tree().create_timer(3.0).timeout
		_waiting_for_response = false
		return

	# Verificar cartas con Exhumar disponibles
	var executor = _get_action_executor()
	var exhumar_available = false
	var exhumar_text = ""

	if executor:
		var exhumable = executor.get_exhumable_cards(1, opp_grave)
		if not exhumable.is_empty():
			exhumar_available = true
			exhumar_text = "\n\n💀 EXHUMAR disponible:\n"
			for card in exhumable:
				exhumar_text += "• %s (desde Cementerio)\n" % card.get("name", "???")

	# Verificar coste de carta en pipeline para mostrar si Hacer el Bien puede usarse
	var target_cost = 0
	var can_annul = false
	if executor and executor.is_pipeline_active():
		var target = executor.get_card_in_pipeline()
		target_cost = target.get("cost", target.get("coste", 0))
		can_annul = target_cost <= 3

	# Configurar texto
	var effects_text = ""
	for eff in effects:
		effects_text += "• %s\n" % eff.get("text", "???")

	var cost_info = "\n\nCoste de %s: %d %s" % [
		card_name,
		target_cost,
		"(puede anularse ≤3)" if can_annul else "(NO puede anularse >3)"
	]

	if response_label:
		response_label.text = "OPONENTE: %s jugó\n\n%s\n\nEfectos:\n%s%s%s" % [
			"Jugador 1",
			card_name,
			effects_text,
			cost_info,
			exhumar_text
		]

	response_panel.visible = true


func _create_response_panel() -> void:
	"""Crea el panel de respuesta dinámicamente"""
	var ui = get_node_or_null("UI")
	if not ui:
		return

	response_panel = Panel.new()
	response_panel.name = "ResponsePanel"
	# Tamaño y posición centrada en el área de juego (no en el panel lateral)
	# Viewport: 1920x1080, Panel lateral derecho: 340px
	# Área de juego: 1580x1080, centro del área de juego: x=790
	var panel_width = 520
	var panel_height = 400
	response_panel.size = Vector2(panel_width, panel_height)
	response_panel.position = Vector2(
		(1580 - panel_width) / 2,  # Centrado en área de juego
		(1080 - panel_height) / 2  # Centrado verticalmente
	)

	# Estilo con fondo más opaco
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.15, 0.98)
	style.border_color = Color(1.0, 0.8, 0.2)
	style.set_border_width_all(4)
	style.set_corner_radius_all(12)
	style.shadow_color = Color(0, 0, 0, 0.5)
	style.shadow_size = 8
	response_panel.add_theme_stylebox_override("panel", style)

	# Contenedor vertical con scroll para contenido largo
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 12)
	vbox.set_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 20)

	# Título
	var title = Label.new()
	title.text = "⚔️ VENTANA DE RESPUESTA"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	vbox.add_child(title)

	# ScrollContainer para contenido largo
	var scroll = ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(400, 160)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	# Label de info
	response_label = Label.new()
	response_label.name = "ResponseLabel"
	response_label.text = "Esperando..."
	response_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	response_label.custom_minimum_size = Vector2(380, 0)
	response_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	response_label.add_theme_font_size_override("font_size", 13)

	scroll.add_child(response_label)
	vbox.add_child(scroll)

	# Botones
	var btn_container = HBoxContainer.new()
	btn_container.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_container.add_theme_constant_override("separation", 10)

	# Botón Hacer el Bien (para probar Sección 8)
	var annul_btn = Button.new()
	annul_btn.text = "🚫 Hacer el Bien"
	annul_btn.custom_minimum_size = Vector2(130, 45)
	annul_btn.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	annul_btn.tooltip_text = "Anula cartas de coste ≤3"
	annul_btn.pressed.connect(_on_opponent_annul)
	btn_container.add_child(annul_btn)

	var respond_btn = Button.new()
	respond_btn.text = "🎴 Responder"
	respond_btn.custom_minimum_size = Vector2(110, 45)
	respond_btn.pressed.connect(_on_opponent_respond)
	btn_container.add_child(respond_btn)

	var pass_btn = Button.new()
	pass_btn.text = "⏭️ Pasar"
	pass_btn.custom_minimum_size = Vector2(110, 45)
	pass_btn.pressed.connect(_on_opponent_pass)
	btn_container.add_child(pass_btn)

	vbox.add_child(btn_container)
	response_panel.add_child(vbox)
	ui.add_child(response_panel)


func _on_opponent_annul() -> void:
	"""El oponente juega Hacer el Bien (Sección 8)

	Puede jugarse desde la mano O desde el Cementerio via Exhumar.
	"""
	var executor = _get_action_executor()
	var hacer_bien_data: Dictionary = {}
	var played_from_cemetery: bool = false

	# Buscar Hacer el Bien en el cementerio del oponente (Exhumar)
	if executor:
		var exhumable = executor.get_exhumable_cards(1, opp_grave)
		for card in exhumable:
			if card.get("name", "") == "Hacer el Bien":
				hacer_bien_data = card
				played_from_cemetery = true
				break

	# Si no está en cementerio, cargar del archivo
	if hacer_bien_data.is_empty():
		hacer_bien_data = _load_card_json("res://hacer_el_bien.json")

	if hacer_bien_data.is_empty():
		# Fallback a carta genérica
		hacer_bien_data = {
			"name": "Hacer el Bien",
			"type": "Talisman",
			"cost": 1,
			"traits": {"has_exhumar": true},
			"hability_blocks": [{
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

	# Log de origen
	if played_from_cemetery:
		_log("[EXHUMAR] ¡Oponente juega HACER EL BIEN desde el Cementerio!")
		_log("[EXHUMAR] Destino final forzado: DESTIERRO")
	else:
		_log("[SECCIÓN 8] ¡Oponente juega HACER EL BIEN!")

	# Validar coste de la carta objetivo (Sección 6)
	if executor:
		var validation = executor.validate_annul_target(hacer_bien_data, executor.get_card_in_pipeline())

		_log("[SECCIÓN 6] Validación de coste:")
		for check in validation.conditions_checked:
			var status = "✓" if check.met else "✗"
			_log("  %s %s %s %s (actual: %s)" % [
				status,
				check.attribute,
				check.operator,
				str(check.required_value),
				str(check.actual_value)
			])

		if not validation.valid:
			_log("[SECCIÓN 6] ✗ No puede anular: %s" % validation.reason)
			return

		_log("[SECCIÓN 6] ✓ Validación exitosa")

		# Ejecutar anulación
		var annul_result = executor.annul_card_in_pipeline(hacer_bien_data)

		if annul_result.success:
			_log("[SECCIÓN 8] ✓ %s ANULADA por Hacer el Bien" % annul_result.annulled_card.get("name", "???"))
			_log("[SECCIÓN 8] Efectos cancelados: %d" % annul_result.cancelled_effects.size())
			_log("[SECCIÓN 8] Destino de carta anulada: %s" % annul_result.destination)

			_response_result.had_response = true
			_response_result.is_annullment = true
			_response_result.response_card = hacer_bien_data

			# El destino ya respeta BANISH_SELF de la carta anulada
			_response_result.annul_destination = annul_result.destination

			# Determinar destino de Hacer el Bien
			var hacer_bien_destination = "CEMENTERIO"
			if played_from_cemetery:
				hacer_bien_destination = "DESTIERRO"
				# Remover del cementerio
				opp_grave.erase(hacer_bien_data)
				opp_exile.append(hacer_bien_data)
				_log("[EXHUMAR] Hacer el Bien → DESTIERRO (jugada via Exhumar)")
			else:
				opp_grave.append(hacer_bien_data)
				_log("[RESOLUCIÓN] Hacer el Bien → CEMENTERIO")

			# Marcar anulación
			_was_annulled = true
			_pending_effects.clear()

			_update_state_display()

	_waiting_for_response = false
	if response_panel:
		response_panel.visible = false


func _on_opponent_respond() -> void:
	"""El oponente elige responder (no anulación)"""
	_log("[RESPUESTA] Oponente quiere responder")
	# TODO: Abrir selección de carta de respuesta del oponente
	# Por ahora simulamos que no tiene cartas válidas
	_log("[RESPUESTA] (Sin cartas de respuesta válidas - simulado)")
	_on_opponent_pass()


func _on_opponent_pass() -> void:
	"""El oponente pasa"""
	_response_result.passed = true
	_response_result.had_response = false

	_waiting_for_response = false
	if response_panel:
		response_panel.visible = false

	_get_action_executor_pass()


func _wait_for_response() -> void:
	"""Espera hasta que el oponente decida"""
	while _waiting_for_response:
		await get_tree().process_frame


# =============================================================================
# SECCIÓN 17 - CONDICIÓN POST-RESOLUCIÓN
# =============================================================================
func _check_post_resolution_condition(card_data: Dictionary) -> void:
	"""Verifica y aplica condiciones post-resolución (Sección 17)

	Después de que todos los efectos se resuelven, se verifican
	las condiciones especiales de la carta (ej: BANISH_SELF).
	"""
	var card_name = card_data.get("name", card_data.get("nombre", "???"))
	var on_resolution = card_data.get("on_resolution", "")

	if on_resolution.is_empty():
		return

	_log("[SECCIÓN 17] Verificando condición post-resolución...")

	var destination = "GRAVEYARD"

	match on_resolution:
		"BANISH_SELF":
			destination = "EXILE"
			_log("[SECCIÓN 17] Condición: BANISH_SELF")
			_log("[SECCIÓN 17] → '%s' será desterrada tras resolución" % card_name)
		"RETURN_TO_HAND":
			destination = "HAND"
			_log("[SECCIÓN 17] Condición: RETURN_TO_HAND")
			_log("[SECCIÓN 17] → '%s' volverá a la mano tras resolución" % card_name)
		"RETURN_TO_DECK":
			destination = "DECK"
			_log("[SECCIÓN 17] Condición: RETURN_TO_DECK")
			_log("[SECCIÓN 17] → '%s' volverá al mazo tras resolución" % card_name)
		"DESTROY_SELF":
			destination = "GRAVEYARD"
			_log("[SECCIÓN 17] Condición: DESTROY_SELF")
			_log("[SECCIÓN 17] → '%s' será destruida tras resolución" % card_name)
		_:
			_log("[SECCIÓN 17] Condición: %s (default → cementerio)" % on_resolution)

	# Emitir señal para sistemas externos
	_get_action_executor_emit("post_resolution_condition", null, on_resolution, destination)


# =============================================================================
# HELPERS PARA AUTOLOADS
# =============================================================================
func _get_action_executor() -> Node:
	return get_node_or_null("/root/ActionExecutor")


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


func _sync_effects_to_opponent(card_data: Dictionary, effects: Array) -> void:
	"""Sincroniza la selección de efectos con el cliente del oponente

	En una partida real, esto enviaría los datos por red.
	El oponente verá qué efectos se intentarán resolver.
	"""
	var card_name = card_data.get("name", card_data.get("nombre", "???"))

	_log("[SYNC] Enviando efectos al oponente:")
	for eff in effects:
		_log("  → %s" % eff.get("text", "???"))

	# Usar ActionExecutor para emitir señal de sincronización
	_get_action_executor_sync(active_player, card_data, effects)


func _process_annullment(annuller_card_data: Dictionary) -> void:
	"""Procesa una anulación del oponente (Sección 8)

	Args:
		annuller_card_data: Datos de la carta de anulación
	"""
	var card_name = _current_card_data.get("name", "???")
	var annuller_name = annuller_card_data.get("name", "Anulación")

	_log("[SECCIÓN 8] %s ANULA a %s" % [annuller_name, card_name])

	# Marcar como anulada
	_was_annulled = true

	# Cancelar efectos pendientes
	_log("[ANULACIÓN] Pipeline cancelado - %d efectos no se resolverán" % _pending_effects.size())
	_pending_effects.clear()

	# Emitir señal
	_get_action_executor_emit("spell_annulled", null, null)


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
		"tipo": _map_type(card_data.get("type", card_data.get("tipo", ""))),
		"habilidad": card_data.get("ability", card_data.get("habilidad", ""))
	}

	card.load_from_data(mapped_data)
	card.owner_id = player_id
	card.esta_oculta = (player_id == 1)  # Ocultar cartas del oponente
	card.set_meta("card_data", card_data)

	# Conectar click
	card.card_clicked.connect(_on_card_clicked)

	container.add_child(card)


func _map_type(type_val) -> int:
	if type_val is int:
		return type_val
	match str(type_val).to_lower():
		"talisman", "talismán": return Constants.CardType.TALISMAN
		"aliado", "ally": return Constants.CardType.ALIADO
		"arma", "weapon": return Constants.CardType.ARMA
		"totem", "tótem": return Constants.CardType.TOTEM
		"oro", "gold": return Constants.CardType.ORO
	return Constants.CardType.ALIADO


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


func _load_card_json(path: String) -> Dictionary:
	"""Carga un archivo JSON de carta"""
	if not FileAccess.file_exists(path):
		_log("[ERROR] Archivo no encontrado: %s" % path)
		return {}

	var file = FileAccess.open(path, FileAccess.READ)
	var json_text = file.get_as_text()
	file.close()

	var json = JSON.new()
	var error = json.parse(json_text)

	if error != OK:
		_log("[ERROR] JSON inválido: %s" % json.get_error_message())
		return {}

	return json.data


func _find_json_files(path: String) -> Array:
	"""Busca archivos JSON en un directorio"""
	var files: Array = []
	var dir = DirAccess.open(path)

	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if file_name.ends_with(".json"):
				files.append(path.path_join(file_name))
			file_name = dir.get_next()
		dir.list_dir_end()

	return files


func _log(message: String, type: String = "info") -> void:
	"""Agrega mensaje al log local y al CombatLog global"""
	# Log local
	if log_text:
		var timestamp = Time.get_time_string_from_system()
		log_text.append_text("[%s] %s\n" % [timestamp.substr(0, 5), message])
		log_text.scroll_to_line(log_text.get_line_count())
	else:
		print("[TestScene] %s" % message)

	# También enviar al CombatLog global (si existe)
	var combat_log = get_node_or_null("/root/CombatLog")
	if combat_log:
		# Detectar tipo de mensaje por contenido
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

		combat_log.add_entry(log_type, message)


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
