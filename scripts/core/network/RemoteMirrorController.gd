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
	if Constants.VERBOSE_DIAG_LOGS:
		print("[RemoteMirrorController] Mensaje recibido: op=%s kind=%s" % [
			str(data.get("op", "")), str(data.get("kind", ""))
		])
	match data.get("op", ""):
		"prompt":
			_close_current_overlay()
			# 2026-09-23, bug real reportado por el usuario: cualquier prompt
			# real que llegue (mulligan/vigilia/ataque/etc.) tiene que tapar
			# la pantalla "ESPERANDO JUGADOR" que dejó el duelo de dados — sin
			# esto, el diálogo real se construía IGUAL, pero por debajo de esa
			# pantalla de carga (otra capa, nunca se ocultaba sola), dejando
			# al jugador Remoto viéndola para siempre sin ninguna forma de
			# llegar al prompt real ni de que este vuelva a intentarlo.
			var loading_overlay := _main.get_node_or_null("/root/MatchLoadingOverlay")
			if loading_overlay:
				loading_overlay.hide_loading()
			match data.get("kind", ""):
				"mulligan":
					_show_mulligan_prompt(data)
				"vigilia":
					_show_vigilia_prompt(data)
				"ataque":
					_show_ataque_prompt(data)
				"response_window":
					_show_response_window_prompt(data)
				"choose_wielder":
					_show_choose_wielder_prompt(data)
				"select_cards":
					_show_select_cards_prompt(data)
				"choose_option":
					_show_choose_option_prompt(data)
				"select_cemetery_cards":
					_show_select_cemetery_cards_prompt(data)
				"await_target":
					_show_await_target_prompt(data)
				"await_multi_target":
					_show_await_multi_target_prompt(data)
		"move_card":
			_apply_move_card(data)
		"remove_card":
			_apply_remove_card(data)
		"dice_roll":
			_show_dice_roll_mirror(data)


# =============================================================================
# DUELO DE DADOS — reproduce del lado Remoto la MISMA tirada que el
# Anfitrión ya resolvió (2026-09-20, a pedido del usuario: antes cada
# pantalla tiraba sus propios dados por separado, sin relación entre sí —
# ver GameBootstrap._show_dice_roll()/DiceDuel3D.forced_result1/2).
# =============================================================================
func _show_dice_roll_mirror(data: Dictionary) -> void:
	var r1: int = int(data.get("result1", 0))
	var r2: int = int(data.get("result2", 0))
	if r1 <= 0 or r2 <= 0:
		return
	var loading_overlay := _main.get_node_or_null("/root/MatchLoadingOverlay")
	if loading_overlay:
		loading_overlay.hide_loading()
	var dice_duel = DiceDuel3D.new()
	dice_duel.forced_result1 = r1
	dice_duel.forced_result2 = r2
	# El dado izquierdo (result1) siempre es el del Anfitrión — mismo
	# convenio fijo que usa GameBootstrap._show_dice_roll() del otro lado,
	# no "el tuyo siempre a la izquierda". Aquí solo cambia el texto de "quién
	# parte": "TÚ"/"OPONENTE" no tendría sentido en esta vista espejo, que no
	# corre su propio GameManager.
	dice_duel.winner_text_p0 = "¡EMPIEZA EL ANFITRIÓN!"
	dice_duel.winner_text_p1 = "¡EMPIEZAS TÚ!"
	_main.add_child(dice_duel)
	# 2026-09-23, bug real reportado por el usuario (Anfitrión): el Remoto se
	# quedaba pegado para siempre en "ESPERANDO JUGADOR" — causa real: si el
	# mensaje "prompt"/"mulligan" (el Anfitrión llama a RemotePlayerController.
	# run_mulligan() apenas termina SU PROPIO mulligan) llegaba DURANTE esta
	# animación (tarda unos segundos), _show_mulligan_prompt() ya construía
	# el diálogo real sobre inspection_layer — pero este callback, un
	# instante después, tapaba ese diálogo con la pantalla de carga
	# (MatchLoadingOverlay, otra capa por encima), dejando el prompt real
	# invisible/inaccesible sin ningún mensaje nuevo en camino que lo
	# destapara. Ahora solo se muestra la espera si ningún prompt real llegó
	# todavía mientras corría la animación.
	dice_duel.duel_completed.connect(func(_winner_id: int):
		if loading_overlay and not (_current_overlay and is_instance_valid(_current_overlay)):
			loading_overlay.show_loading(_main, "ESPERANDO JUGADOR",
				"El Anfitrión está preparando su mano...")
	)


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
		# hay forma de que un click aquí dispare nada por red) — mostrarlas
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
	var weapon_candidates: Array = data.get("weapon_candidates", [])
	var talisman_candidates: Array = data.get("talisman_candidates", [])
	var totem_candidates: Array = data.get("totem_candidates", [])
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

	if not weapon_candidates.is_empty():
		var weapon_lbl := Label.new()
		weapon_lbl.text = "Jugar Arma:"
		vbox.add_child(weapon_lbl)
		for card in weapon_candidates:
			var card_id: String = str(card.get("card_id", ""))
			_add_row_button(vbox, "%s (coste %s)" % [str(card.get("nombre", "?")), str(card.get("coste", "?"))], func():
				_send_intent_and_close({"op": "intent", "kind": "play_card", "card_id": card_id}))

	if not talisman_candidates.is_empty():
		var talisman_lbl := Label.new()
		talisman_lbl.text = "Jugar Talismán:"
		vbox.add_child(talisman_lbl)
		for card in talisman_candidates:
			var card_id: String = str(card.get("card_id", ""))
			_add_row_button(vbox, "%s (coste %s)" % [str(card.get("nombre", "?")), str(card.get("coste", "?"))], func():
				_send_intent_and_close({"op": "intent", "kind": "play_card", "card_id": card_id}))

	if not totem_candidates.is_empty():
		var totem_lbl := Label.new()
		totem_lbl.text = "Jugar Tótem:"
		vbox.add_child(totem_lbl)
		for card in totem_candidates:
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


# =============================================================================
# ELEGIR PORTADOR DE ARMA (RemotePlayerController._choose_wielder_remote())
# =============================================================================
func _show_choose_wielder_prompt(data: Dictionary) -> void:
	var weapon: Dictionary = data.get("weapon", {})
	var candidates: Array = data.get("candidates", [])
	var vbox := _build_overlay("Elige quién porta %s" % str(weapon.get("nombre", "el Arma")))
	if candidates.is_empty():
		var lbl := Label.new()
		lbl.text = "No hay ningún Aliado en juego que pueda portarla."
		vbox.add_child(lbl)
		return

	for card in candidates:
		var card_id: String = str(card.get("card_id", ""))
		_add_row_button(vbox, str(card.get("nombre", "?")), func():
			_send_intent_and_close({"op": "intent", "kind": "choose_wielder", "card_id": card_id}))


# =============================================================================
# SELECCIÓN DE CARTAS GENÉRICA (SelectionManager._delegate_selection_to_
# remote(), Fase 3 del plan de paridad remota) — cubre de taquito cualquier
# "busca una carta"/"elige del cementerio"/etc. que ya use SelectionManager
# del lado del motor de efectos, sin que cada patrón nuevo necesite su propio
# caso de prompt acá. Las cartas se identifican por ÍNDICE en 'candidates'
# (son Dictionary de datos crudos, no nodos Card con instance_id).
# =============================================================================
func _show_select_cards_prompt(data: Dictionary) -> void:
	var title: String = str(data.get("title", "Elige carta(s)"))
	var candidates: Array = data.get("candidates", [])
	var max_sel: int = int(data.get("max_selections", 1))
	var min_sel: int = int(data.get("min_selections", 0))
	var can_cancel: bool = bool(data.get("can_cancel", true))
	var vbox := _build_overlay(title)

	if candidates.is_empty():
		var lbl := Label.new()
		lbl.text = "No hay ninguna carta para elegir."
		vbox.add_child(lbl)
		_add_row_button(vbox, "Continuar", func():
			_send_intent_and_close({"op": "intent", "kind": "select_cards_choice", "indices": []}))
		return

	if max_sel <= 0:
		# Solo mostrar (SelectionMode.REVEAL) — sin elección real.
		for card in candidates:
			var lbl := Label.new()
			lbl.text = "%s (coste %s)" % [str(card.get("nombre", "?")), str(card.get("coste", "?"))]
			vbox.add_child(lbl)
		_add_row_button(vbox, "Continuar", func():
			_send_intent_and_close({"op": "intent", "kind": "select_cards_choice", "indices": []}))
		return

	if max_sel == 1:
		# Un clic elige y cierra — mismo criterio que el panel local
		# (SelectionManager._on_card_clicked() con max_selections == 1).
		for i in range(candidates.size()):
			var card: Dictionary = candidates[i]
			var idx: int = i
			_add_row_button(vbox, "%s (coste %s)" % [str(card.get("nombre", "?")), str(card.get("coste", "?"))], func():
				_send_intent_and_close({"op": "intent", "kind": "select_cards_choice", "indices": [idx]}))
		if can_cancel:
			var sep := HSeparator.new()
			vbox.add_child(sep)
			_add_row_button(vbox, "Cancelar", func():
				_send_intent_and_close({"op": "intent", "kind": "select_cards_choice", "cancelled": true, "indices": []}))
		return

	# Multi-selección: checkboxes + Confirmar, mismo criterio que _show_ataque_prompt().
	var checkboxes: Dictionary = {}  # índice (int) -> CheckBox
	for i in range(candidates.size()):
		var card: Dictionary = candidates[i]
		var row := HBoxContainer.new()
		vbox.add_child(row)
		var cb := CheckBox.new()
		row.add_child(cb)
		checkboxes[i] = cb
		var lbl := Label.new()
		lbl.text = "%s (coste %s)" % [str(card.get("nombre", "?")), str(card.get("coste", "?"))]
		row.add_child(lbl)

	var sep2 := HSeparator.new()
	vbox.add_child(sep2)
	var button_row := HBoxContainer.new()
	button_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(button_row)
	_add_row_button(button_row, "Confirmar", func():
		var chosen: Array = []
		for i in checkboxes:
			if checkboxes[i].button_pressed:
				chosen.append(i)
		if chosen.size() > max_sel:
			chosen = chosen.slice(0, max_sel)
		if chosen.size() < min_sel:
			return  # mismo criterio que el panel local: no confirma bajo el mínimo
		_send_intent_and_close({"op": "intent", "kind": "select_cards_choice", "indices": chosen}))
	if can_cancel:
		_add_row_button(button_row, "Cancelar", func():
			_send_intent_and_close({"op": "intent", "kind": "select_cards_choice", "cancelled": true, "indices": []}))


# =============================================================================
# SELECCIÓN DE CARTAS DE CEMENTERIO/DESTIERRO/CASTILLO REVELADO
# (ZoneViewerModule._delegate_cemetery_picker_to_remote()/_delegate_reveal_
# picker_to_remote(), Fase 3 del plan de paridad remota) — mismo protocolo
# que "select_cards" pero con etiquetas extra de zona/lado cuando vienen
# (el picker de Cementerios las manda, el de revelado del Castillo no, al
# ser un solo pool sin "lado rival").
# =============================================================================
func _show_select_cemetery_cards_prompt(data: Dictionary) -> void:
	var title: String = str(data.get("title", "Elige carta(s)"))
	var candidates: Array = data.get("candidates", [])
	var max_sel: int = int(data.get("max_selections", 1))
	var vbox := _build_overlay(title)

	if candidates.is_empty():
		var lbl := Label.new()
		lbl.text = "No hay ninguna carta para elegir."
		vbox.add_child(lbl)
		_add_row_button(vbox, "Continuar", func():
			_send_intent_and_close({"op": "intent", "kind": "select_cemetery_cards_choice", "indices": []}))
		return

	var zone_words := {"cemetery": "Cementerio", "exile": "Destierro"}
	var side_words := {"own": "tuyo", "opponent": "rival"}
	var label_for := func(card: Dictionary) -> String:
		var base: String = "%s (coste %s)" % [str(card.get("nombre", "?")), str(card.get("coste", "?"))]
		var extra := ""
		if card.has("zone_type"):
			extra += str(zone_words.get(str(card.get("zone_type", "")), str(card.get("zone_type", ""))))
		if card.has("side"):
			extra += (" · " if not extra.is_empty() else "") + str(side_words.get(str(card.get("side", "")), str(card.get("side", ""))))
		return "%s [%s]" % [base, extra] if not extra.is_empty() else base

	if max_sel == 1:
		for i in range(candidates.size()):
			var idx: int = i
			_add_row_button(vbox, label_for.call(candidates[i]), func():
				_send_intent_and_close({"op": "intent", "kind": "select_cemetery_cards_choice", "indices": [idx]}))
		return

	var checkboxes2: Dictionary = {}  # índice (int) -> CheckBox
	for i in range(candidates.size()):
		var row := HBoxContainer.new()
		vbox.add_child(row)
		var cb := CheckBox.new()
		row.add_child(cb)
		checkboxes2[i] = cb
		var lbl2 := Label.new()
		lbl2.text = label_for.call(candidates[i])
		row.add_child(lbl2)

	_add_row_button(vbox, "Confirmar", func():
		var chosen: Array = []
		for i in checkboxes2:
			if checkboxes2[i].button_pressed:
				chosen.append(i)
		if chosen.size() > max_sel:
			chosen = chosen.slice(0, max_sel)
		_send_intent_and_close({"op": "intent", "kind": "select_cemetery_cards_choice", "indices": chosen}))


# =============================================================================
# OBJETIVO SOBRE CARTAS YA EN JUEGO (CardInteractionModule.await_target()/
# await_multi_target(), Fase 3 del plan de paridad remota, cuarto sistema) —
# a diferencia de los otros 3 prompts de elegir cartas, acá 'card_id' es un
# get_instance_id() real (Nodos persistentes del tablero), no un índice.
# =============================================================================
func _show_await_target_prompt(data: Dictionary) -> void:
	var title: String = str(data.get("title", "Elige un objetivo"))
	var candidates: Array = data.get("candidates", [])
	var cancellable: bool = bool(data.get("cancellable", true))
	var vbox := _build_overlay(title)

	if candidates.is_empty():
		var lbl := Label.new()
		lbl.text = "No hay ningún objetivo válido ahora mismo."
		vbox.add_child(lbl)
		_add_row_button(vbox, "Continuar", func():
			_send_intent_and_close({"op": "intent", "kind": "await_target_choice", "cancelled": true}))
		return

	for c in candidates:
		var card_id: String = str(c.get("card_id", ""))
		_add_row_button(vbox, "%s (coste %s)" % [str(c.get("nombre", "?")), str(c.get("coste", "?"))], func():
			_send_intent_and_close({"op": "intent", "kind": "await_target_choice", "card_id": card_id}))
	if cancellable:
		var sep := HSeparator.new()
		vbox.add_child(sep)
		_add_row_button(vbox, "Cancelar", func():
			_send_intent_and_close({"op": "intent", "kind": "await_target_choice", "cancelled": true}))


func _show_await_multi_target_prompt(data: Dictionary) -> void:
	var title: String = str(data.get("title", "Elige objetivo(s)"))
	var candidates: Array = data.get("candidates", [])
	var max_sel: int = int(data.get("max_selections", -1))
	var vbox := _build_overlay(title)

	if candidates.is_empty():
		var lbl := Label.new()
		lbl.text = "No hay ningún objetivo válido ahora mismo."
		vbox.add_child(lbl)
		_add_row_button(vbox, "Continuar", func():
			_send_intent_and_close({"op": "intent", "kind": "await_multi_target_choice", "card_ids": []}))
		return

	var checkboxes3: Dictionary = {}  # card_id (String) -> CheckBox
	for c in candidates:
		var card_id: String = str(c.get("card_id", ""))
		var row := HBoxContainer.new()
		vbox.add_child(row)
		var cb := CheckBox.new()
		row.add_child(cb)
		checkboxes3[card_id] = cb
		var lbl2 := Label.new()
		lbl2.text = "%s (coste %s)" % [str(c.get("nombre", "?")), str(c.get("coste", "?"))]
		row.add_child(lbl2)

	_add_row_button(vbox, "Confirmar", func():
		var chosen_ids: Array = []
		for card_id in checkboxes3:
			if checkboxes3[card_id].button_pressed:
				chosen_ids.append(card_id)
		if max_sel >= 0 and chosen_ids.size() > max_sel:
			chosen_ids = chosen_ids.slice(0, max_sel)
		_send_intent_and_close({"op": "intent", "kind": "await_multi_target_choice", "card_ids": chosen_ids}))


# =============================================================================
# ELECCIÓN DE OPCIÓN DE TEXTO (SelectionDialogs.await_choice()/await_two_
# choice(), Fase 3 del plan de paridad remota) — la otra familia de UI
# aparte de "elegir cartas": popups de botones de texto (A/B, o N opciones),
# sin cartas de por medio. Mismo criterio de bajo pulido que el resto.
# =============================================================================
func _show_choose_option_prompt(data: Dictionary) -> void:
	var title: String = str(data.get("title", "Elige una opción"))
	var options: Array = data.get("options", [])
	var vbox := _build_overlay(title)
	for i in range(options.size()):
		var idx: int = i
		_add_row_button(vbox, str(options[i]), func():
			_send_intent_and_close({"op": "intent", "kind": "choose_option_choice", "index": idx}))
