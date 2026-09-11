extends Node
class_name RemoteMirrorController
## RemoteMirrorController — instanciado siempre en Main.gd (Anfitrión y
## Remoto por igual), pero SOLO hace algo si esta instancia concreta es el
## Remoto de una sala de red activa (NetworkClient.room_code != "" and not
## NetworkClient.is_host). En ese caso, GameBootstrap ya se detiene solo
## después de mandar el mazo propio (ver GameBootstrap._send_own_deck_and_
## wait_for_host()) — no hay doble simulación corriendo (el Remoto nunca
## llega a GameManager.setup_game()/start_game() de forma local), pero
## tampoco hay nada más que pase: esta clase es lo que hace que después de
## esa espera, la persona real pueda seguir jugando.
##
## Escucha los mensajes {"op":"prompt","kind":...} que manda
## RemotePlayerController (scripts/core/ai/RemotePlayerController.gd) desde
## el lado del Anfitrión y muestra una UI mínima para que la persona elija,
## devolviendo {"op":"intent","kind":...} — mismo protocolo documentado ahí.
##
## Alcance de este incremento (2026-09-11, Fase B): cubre los 4 tipos de
## prompt que RemotePlayerController ya manda (mulligan/vigilia/ataque/
## response_window), CON diálogos de texto (nombre/coste, sin arte). Además
## aplica las instrucciones "move_card"/"remove_card" que manda
## GameStateBroadcaster desde el lado del Anfitrión — esto SÍ crea Nodos
## Card reales (con arte) en los contenedores correctos del tablero, para
## las 5 zonas públicas "en juego" (Reserva de Oro/Oro Pagado/Línea de
## Defensa/Ataque/Apoyo). Mano/Castillo (privados) y Cementerio/Destierro
## (públicos pero sin Nodos visibles, solo contador) quedan fuera de este
## streaming por ahora — ver GameStateBroadcaster.gd.

var _main: Node = null
var _active: bool = false
var _current_overlay: Control = null
var _card_nodes: Dictionary = {}  # card_id (String) -> Node local (ghost)


func setup(main: Node) -> void:
	_main = main
	_active = NetworkClient.room_code != "" and not NetworkClient.is_host
	if not _active:
		return
	NetworkClient.message_received.connect(_on_message)


func _on_message(data: Dictionary) -> void:
	match data.get("op", ""):
		"prompt":
			_close_current_overlay()
			match data.get("kind", ""):
				"mulligan":
					_show_mulligan_prompt(data)
				"vigilia":
					_show_vigilia_prompt(data)
				"ataque":
					_show_ataque_prompt(data)
				"response_window":
					_show_response_window_prompt(data)
		"move_card":
			_apply_move_card(data)
		"remove_card":
			_apply_remove_card(data)


# =============================================================================
# TABLERO — aplica move_card/remove_card creando/moviendo/liberando Nodos
# Card reales en los contenedores player_*/opponent_* correctos
# =============================================================================
func _apply_move_card(data: Dictionary) -> void:
	var card_id: String = str(data.get("card_id", ""))
	var zone: int = int(data.get("zone", -1))
	if card_id.is_empty() or zone == -1:
		return
	var own: bool = data.get("own", false)
	var card_data: Dictionary = data.get("data", {})

	var node: Node = _card_nodes.get(card_id, null)
	if node and is_instance_valid(node):
		var old_parent = node.get_parent()
		if old_parent:
			old_parent.remove_child(node)
	else:
		node = _main._create_card(card_data, false)
		# can_interact queda en false a propósito (2026-09-11): la
		# inspección/targeting de cartas mirroreadas es Fase C (todavía no
		# hay forma de que un click acá dispare nada por red) — mostrarlas
		# como no-interactivas evita clicks muertos confusos.
		node.can_interact = false
		node.owner_id = 0 if own else 1
		node.controller_id = 0 if own else 1
		_card_nodes[card_id] = node

	var container: Node = _container_for(own, zone)
	if not container:
		node.queue_free()
		_card_nodes.erase(card_id)
		return

	container.add_child(node)
	node.top_level = false
	node.set_zone(zone)

	var card_type: int = int(card_data.get("tipo", -1))
	var target_scale: Vector2 = Vector2.ONE
	if zone in [Constants.Zone.RESERVA_ORO, Constants.Zone.ORO_PAGADO]:
		target_scale = Constants.GOLD_CARD_SCALE
	elif zone == Constants.Zone.LINEA_APOYO and card_type == Constants.CardType.TOTEM:
		target_scale = Vector2(0.8, 0.8)
	node.scale = target_scale
	node.base_scale = target_scale


func _apply_remove_card(data: Dictionary) -> void:
	var card_id: String = str(data.get("card_id", ""))
	if card_id.is_empty():
		return
	var node: Node = _card_nodes.get(card_id, null)
	if node and is_instance_valid(node):
		var parent = node.get_parent()
		if parent:
			parent.remove_child(node)
		node.queue_free()
	_card_nodes.erase(card_id)


func _container_for(own: bool, zone: int) -> Node:
	match zone:
		Constants.Zone.RESERVA_ORO:
			return _main.player_gold if own else _main.opponent_gold
		Constants.Zone.ORO_PAGADO:
			return _main.player_oro_pagado if own else _main.opponent_oro_pagado
		Constants.Zone.LINEA_DEFENSA:
			return _main.player_field if own else _main.opponent_field
		Constants.Zone.LINEA_ATAQUE:
			return _main.player_linea_ataque if own else _main.opponent_linea_ataque
		Constants.Zone.LINEA_APOYO:
			return _main.player_linea_apoyo if own else _main.opponent_linea_apoyo
		_:
			return null


func _close_current_overlay() -> void:
	if _current_overlay and is_instance_valid(_current_overlay):
		_current_overlay.queue_free()
	_current_overlay = null


# =============================================================================
# CONSTRUCCIÓN DE LA UI (overlay genérico + filas de botones)
# =============================================================================
func _build_overlay(title: String) -> VBoxContainer:
	var overlay := ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.6)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_main.inspection_layer.add_child(overlay)
	_current_overlay = overlay

	var panel := PanelContainer.new()
	panel.set_anchor(SIDE_LEFT, 0.5); panel.set_anchor(SIDE_TOP, 0.5)
	panel.set_anchor(SIDE_RIGHT, 0.5); panel.set_anchor(SIDE_BOTTOM, 0.5)
	panel.set_offset(SIDE_LEFT, -260); panel.set_offset(SIDE_TOP, -230)
	panel.set_offset(SIDE_RIGHT, 260); panel.set_offset(SIDE_BOTTOM, 230)
	overlay.add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(500, 400)
	panel.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(vbox)

	var lbl := Label.new()
	lbl.text = title
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 18)
	vbox.add_child(lbl)

	var sep := HSeparator.new()
	vbox.add_child(sep)

	return vbox


func _add_row_button(container: Container, text: String, on_pressed: Callable) -> void:
	var btn := Button.new()
	btn.text = text
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.pressed.connect(on_pressed)
	container.add_child(btn)


func _send_intent_and_close(intent: Dictionary) -> void:
	NetworkClient.send_message(intent)
	_close_current_overlay()


# =============================================================================
# MULLIGAN
# =============================================================================
func _show_mulligan_prompt(data: Dictionary) -> void:
	var hand: Array = data.get("hand", [])
	var vbox := _build_overlay("Tu mano inicial (%d cartas) — ¿la mantienes?" % hand.size())
	for card in hand:
		var lbl := Label.new()
		lbl.text = "%s (coste %s)" % [str(card.get("nombre", "?")), str(card.get("coste", "?"))]
		vbox.add_child(lbl)

	var button_row := HBoxContainer.new()
	button_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(button_row)
	_add_row_button(button_row, "Mantener", func():
		_send_intent_and_close({"op": "intent", "kind": "mulligan_choice", "keep": true}))
	_add_row_button(button_row, "Mulligan (redibujar)", func():
		_send_intent_and_close({"op": "intent", "kind": "mulligan_choice", "keep": false}))


# =============================================================================
# VIGILIA
# =============================================================================
func _show_vigilia_prompt(data: Dictionary) -> void:
	var gold_reserva: int = int(data.get("gold_reserva", 0))
	var gold_candidates: Array = data.get("gold_candidates", [])
	var ally_candidates: Array = data.get("ally_candidates", [])
	var vbox := _build_overlay("Tu Vigilia — Oro disponible: %d" % gold_reserva)

	if not gold_candidates.is_empty():
		var gold_lbl := Label.new()
		gold_lbl.text = "Poner Oro:"
		vbox.add_child(gold_lbl)
		for card in gold_candidates:
			var card_id: String = str(card.get("card_id", ""))
			_add_row_button(vbox, "Oro: %s" % str(card.get("nombre", "?")), func():
				_send_intent_and_close({"op": "intent", "kind": "place_gold", "card_id": card_id}))

	if not ally_candidates.is_empty():
		var ally_lbl := Label.new()
		ally_lbl.text = "Jugar Aliado:"
		vbox.add_child(ally_lbl)
		for card in ally_candidates:
			var card_id: String = str(card.get("card_id", ""))
			_add_row_button(vbox, "%s (coste %s)" % [str(card.get("nombre", "?")), str(card.get("coste", "?"))], func():
				_send_intent_and_close({"op": "intent", "kind": "play_card", "card_id": card_id}))

	var sep := HSeparator.new()
	vbox.add_child(sep)
	_add_row_button(vbox, "Terminar Vigilia / Atacar", func():
		_send_intent_and_close({"op": "intent", "kind": "end_vigilia"}))


# =============================================================================
# ATAQUE
# =============================================================================
func _show_ataque_prompt(data: Dictionary) -> void:
	var attackable: Array = data.get("attackable", [])
	var vbox := _build_overlay("Declara atacantes")
	if attackable.is_empty():
		var lbl := Label.new()
		lbl.text = "No tienes ningún Aliado que pueda atacar."
		vbox.add_child(lbl)
		_add_row_button(vbox, "Continuar", func():
			_send_intent_and_close({"op": "intent", "kind": "declare_attackers", "card_ids": []}))
		return

	var checkboxes: Dictionary = {}  # card_id -> CheckBox
	for card in attackable:
		var card_id: String = str(card.get("card_id", ""))
		var row := HBoxContainer.new()
		vbox.add_child(row)
		var cb := CheckBox.new()
		row.add_child(cb)
		checkboxes[card_id] = cb
		var lbl := Label.new()
		lbl.text = "%s (Fuerza/coste %s)" % [str(card.get("nombre", "?")), str(card.get("coste", "?"))]
		row.add_child(lbl)

	var sep := HSeparator.new()
	vbox.add_child(sep)
	_add_row_button(vbox, "Confirmar ataque", func():
		var chosen_ids: Array = []
		for card_id in checkboxes:
			if checkboxes[card_id].button_pressed:
				chosen_ids.append(card_id)
		_send_intent_and_close({"op": "intent", "kind": "declare_attackers", "card_ids": chosen_ids}))


# =============================================================================
# VENTANA DE RESPUESTA (habilidades activadas — Capa 2 de la Pila de
# Respuesta Universal)
# =============================================================================
func _show_response_window_prompt(data: Dictionary) -> void:
	var candidates: Array = data.get("candidates", [])
	var vbox := _build_overlay("¿Quieres responder?")
	if candidates.is_empty():
		var lbl := Label.new()
		lbl.text = "No tienes ninguna habilidad activada disponible."
		vbox.add_child(lbl)

	for c in candidates:
		var card_id: String = str(c.get("card_id", ""))
		var ability_index: int = int(c.get("ability_index", 0))
		var label_text: String = str(c.get("effect_text", c.get("cost_text", "Usar habilidad")))
		_add_row_button(vbox, "Usar: %s" % label_text, func():
			_send_intent_and_close({
				"op": "intent", "kind": "activate_ability",
				"card_id": card_id, "ability_index": ability_index,
			}))

	var sep := HSeparator.new()
	vbox.add_child(sep)
	_add_row_button(vbox, "Pasar", func():
		_send_intent_and_close({"op": "intent", "kind": "pass"}))
