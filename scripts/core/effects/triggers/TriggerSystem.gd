extends Node
## TriggerSystem - Gestiona la cola de habilidades disparadas (DAR 7.4)
## Orden: Primero jugador activo elige orden, luego oponente

# =============================================================================
# SIGNALS
# =============================================================================
signal triggers_pending(active_player_triggers: Array, opponent_triggers: Array)
signal trigger_ordering_requested(player_id: int, triggers: Array)
signal trigger_resolved(card: Node, trigger_type: String, result: Dictionary)
signal trigger_cancelled(card: Node, trigger_type: String, cancelled_by: Node)
signal all_triggers_resolved

# Ventana de respuesta (DAR Sección 8 - Cancelar)
signal waiting_for_responses(trigger: Dictionary, responding_player: int)
signal response_window_closed(trigger: Dictionary, was_cancelled: bool)

# =============================================================================
# ESTADO
# =============================================================================
## Cola de triggers pendientes (se resuelven en orden FIFO)
var trigger_queue: Array[Dictionary] = []

## Triggers recolectados durante un evento (antes de ordenar)
var pending_active_triggers: Array[Dictionary] = []
var pending_opponent_triggers: Array[Dictionary] = []

## Flag para saber si estamos recolectando triggers
var is_collecting: bool = false

## Flag para saber si estamos resolviendo
var is_resolving: bool = false

## Ventana de respuesta
var awaiting_response: bool = false
var current_trigger_for_response: Dictionary = {}
var response_timeout: float = 10.0  # Segundos para responder

## Efectos continuos activos (para resolver conflictos de prioridad)
var continuous_effects: Array[Dictionary] = []

## Buffs/Debuffs temporales con duración específica
## Cada buff: {source: Node, target: Node, type: String, value: int, duration: String, turn_applied: int}
## Duraciones: "this_turn", "until_final", "until_next_turn", "permanent"
var temporary_buffs: Array[Dictionary] = []

## Señales para buffs
signal buff_applied(target: Node, buff: Dictionary)
signal buff_expired(target: Node, buff: Dictionary)
signal buffs_cleared(count: int, duration: String)

## Callback de cancelación pendiente
var pending_cancel_callback: Callable = Callable()


func _ready() -> void:
	# Conectar a señales de EffectController para recolectar triggers.
	# on_card_entered_play y on_card_attacks NO se conectan acá — esos dos
	# los llama el código que juega/ataca directamente (GoldManager,
	# GameManager) con 'await', para que el trigger termine de resolverse
	# ANTES de que el juego siga de fase. Conectados por señal (fire-and-
	# forget, como el resto de abajo) el emisor no espera a que el handler
	# async termine, y el trigger podía resolverse varias fases después de
	# jugarse la carta (se vio con Drácula y Signo Amarillo resolviendo en
	# Bloqueo). Ver _collect_triggers_for_event(), llamado directo con await.
	if EffectController:
		EffectController.on_card_drawn.connect(_on_global_event.bind("on_card_drawn"))
		EffectController.on_card_milled.connect(_on_global_event_with_dest.bind("on_card_milled"))
		EffectController.on_card_discarded.connect(_on_global_event.bind("on_discard"))
		EffectController.on_card_left_play.connect(_on_global_event_with_zone.bind("on_leave_play"))
		EffectController.on_card_destroyed.connect(_on_global_event.bind("on_destroyed"))
		EffectController.on_card_exiled.connect(_on_global_event.bind("on_exiled"))


# =============================================================================
# RECOLECCIÓN DE TRIGGERS
# =============================================================================
func begin_collecting() -> void:
	"""Inicia la recolección de triggers para un evento"""
	is_collecting = true
	pending_active_triggers.clear()
	pending_opponent_triggers.clear()


func end_collecting_and_queue() -> void:
	"""Finaliza recolección y encola los triggers en orden correcto (DAR 7.4)"""
	is_collecting = false

	if pending_active_triggers.is_empty() and pending_opponent_triggers.is_empty():
		return

	var active_player = GameManager.active_player_id if GameManager else 0

	# Notificar que hay triggers pendientes
	emit_signal("triggers_pending", pending_active_triggers, pending_opponent_triggers)

	# Si hay múltiples triggers del jugador activo, debe elegir orden
	if pending_active_triggers.size() > 1:
		# TODO: Mostrar UI para ordenar
		# Por ahora, usar orden de llegada
		print("[TriggerSystem] Jugador activo tiene %d triggers - ordenar" % pending_active_triggers.size())
		emit_signal("trigger_ordering_requested", active_player, pending_active_triggers)

	# Añadir triggers del jugador activo primero
	for trigger in pending_active_triggers:
		trigger_queue.append(trigger)

	# Si hay múltiples triggers del oponente, debe elegir orden
	var opponent = 1 - active_player
	if pending_opponent_triggers.size() > 1:
		print("[TriggerSystem] Oponente tiene %d triggers - ordenar" % pending_opponent_triggers.size())
		emit_signal("trigger_ordering_requested", opponent, pending_opponent_triggers)

	# Añadir triggers del oponente después
	for trigger in pending_opponent_triggers:
		trigger_queue.append(trigger)

	print("[TriggerSystem] Cola de triggers: %d total" % trigger_queue.size())


func register_trigger(card: Node, trigger_type: String, event_data: Dictionary) -> void:
	"""Registra un trigger disparado por una carta"""
	var trigger_data = {
		"card": card,
		"trigger_type": trigger_type,
		"event_data": event_data,
		"controller_id": card.controller_id if card.get("controller_id") != null else 0
	}

	var active_player = GameManager.active_player_id if GameManager else 0

	if is_collecting:
		# Durante recolección, separar por jugador
		if trigger_data.controller_id == active_player:
			pending_active_triggers.append(trigger_data)
		else:
			pending_opponent_triggers.append(trigger_data)
	else:
		# Fuera de recolección, añadir directo a la cola
		trigger_queue.append(trigger_data)


# =============================================================================
# ORDENAMIENTO DE TRIGGERS
# =============================================================================
func set_trigger_order(player_id: int, ordered_triggers: Array) -> void:
	"""Establece el orden de los triggers del jugador
	Llamado por la UI cuando el jugador termina de ordenar
	"""
	var active_player = GameManager.active_player_id if GameManager else 0

	if player_id == active_player:
		pending_active_triggers = ordered_triggers
	else:
		pending_opponent_triggers = ordered_triggers

	print("[TriggerSystem] Jugador %d ordenó %d triggers" % [player_id + 1, ordered_triggers.size()])


# =============================================================================
# RESOLUCIÓN DE TRIGGERS
# =============================================================================
func resolve_next_trigger() -> Dictionary:
	"""Resuelve el siguiente trigger en la cola con ventana de respuesta
	DAR Sección 8: Permite cancelación antes de resolver
	Returns: El trigger resuelto o {} si no hay más
	"""
	if trigger_queue.is_empty():
		is_resolving = false
		emit_signal("all_triggers_resolved")
		return {}

	is_resolving = true
	var trigger = trigger_queue.pop_front()

	var card: Node = trigger.card
	var trigger_type: String = trigger.trigger_type
	var event_data: Dictionary = trigger.event_data
	var controller_id: int = trigger.get("controller_id", 0)

	# Verificar que la carta sigue en juego
	if not is_instance_valid(card):
		print("[TriggerSystem] Carta ya no existe, saltando trigger")
		return await resolve_next_trigger()

	if not card.is_in_play():
		print("[TriggerSystem] %s ya no está en juego, saltando trigger" % card.card_name)
		return await resolve_next_trigger()

	# Verificar si un efecto continuo negativo bloquea este trigger
	if _is_blocked_by_continuous_effect(card, trigger_type):
		print("[TriggerSystem] %s bloqueado por efecto continuo" % trigger_type)
		return await resolve_next_trigger()

	# === PASO D: VENTANA DE RESPUESTA (DAR Sección 8 - Cancelar) ===
	var opponent_id = 1 - controller_id
	current_trigger_for_response = trigger
	awaiting_response = true

	print("[TriggerSystem] Resolviendo trigger de inmediato: %s" % card.card_name)
	emit_signal("waiting_for_responses", trigger, opponent_id)

	# Esperar respuesta o timeout
	var was_cancelled = await _wait_for_response_window()

	awaiting_response = false
	emit_signal("response_window_closed", trigger, was_cancelled)

	if was_cancelled:
		print("[TriggerSystem] %s fue CANCELADO" % trigger_type)
		emit_signal("trigger_cancelled", card, trigger_type, null)
		return await resolve_next_trigger()

	# === RESOLVER "EN MEDIDA DE LO POSIBLE" (DAR Sección 8) ===
	print("[TriggerSystem] Resolviendo: %s de %s" % [trigger_type, card.card_name])

	var result = await _execute_trigger_effect(card, trigger_type, event_data)
	result["card"] = card
	result["type"] = trigger_type

	emit_signal("trigger_resolved", card, trigger_type, result)

	return trigger


func _wait_for_response_window() -> bool:
	"""Resuelve el trigger de inmediato, sin abrir una ventana de prioridad.
	Returns: true si fue cancelado, false si pasó

	Antes abría una ventana real vía PriorityManager y esperaba a que el
	oponente (bot) le pasara la prioridad — mecánicamente funcionaba, pero
	el bot nunca responde nada de verdad todavía (no hay IA real), así que
	esa espera era pura fricción: obligaba al jugador a presionar ¿Paso?
	para cada carta con 'cuando entra en juego'/'cuando ataque' antes de
	poder seguir jugando, sin ningún beneficio (nadie iba a cancelar nada).
	A pedido del usuario (2026-08-17), los triggers ahora se resuelven de
	inmediato. Cuando exista una IA real que pueda cancelar/responder, volver
	a abrir la ventana acá (ver el historial de este archivo para la
	versión anterior basada en PriorityManager.start_response_window())."""
	if pending_cancel_callback.is_valid():
		pending_cancel_callback = Callable()
		return true
	return false


func cancel_current_trigger(cancelling_card: Node = null) -> bool:
	"""Cancela el trigger actual en la ventana de respuesta
	Llamado cuando el oponente usa una habilidad de cancelación
	"""
	if not awaiting_response:
		return false

	if current_trigger_for_response.is_empty():
		return false

	pending_cancel_callback = func(): pass  # Flag para indicar cancelación
	var card = current_trigger_for_response.get("card")
	var trigger_type = current_trigger_for_response.get("trigger_type", "")

	print("[TriggerSystem] Cancelando %s con %s" % [
		trigger_type,
		cancelling_card.card_name if cancelling_card else "efecto"
	])

	emit_signal("trigger_cancelled", card, trigger_type, cancelling_card)
	return true


func pass_response() -> void:
	"""El jugador pasa su oportunidad de responder"""
	awaiting_response = false


func _execute_trigger_effect(card: Node, trigger_type: String, event_data: Dictionary) -> Dictionary:
	"""Ejecuta el efecto del trigger usando Callable
	Resuelve 'en medida de lo posible' (DAR Sección 8)
	"""
	var result = {
		"resolved": true,
		"partial": false,
		"blocked_by": null
	}

	# Verificar si la carta tiene un handler para este trigger
	if card.has_method("_on_trigger_event"):
		# Usar Callable para ejecutar dinámicamente
		var effect_callable: Callable = card._on_trigger_event
		var effect_result = await effect_callable.call(trigger_type, event_data)

		if effect_result is Dictionary:
			result.merge(effect_result, true)
	elif card.has_method("execute_ability"):
		await card.execute_ability(trigger_type, event_data)
	else:
		# ── Fallback: parsear texto de la carta con extract_action() ─────────
		# Cubre habilidades ETB declaradas en texto plano ("Cuando entra: Roba dos cartas")
		result["no_handler"] = true
		if trigger_type in ["on_enter_play", "on_ally_enters"]:
			var ability_text: String = ""
			if card.get("card_data") != null:
				ability_text = card.card_data.get("habilidad", "")
			if not ability_text.is_empty():
				var controller_id: int = card.get("owner_id") if card.get("owner_id") != null else 0
				# Patrón compuesto "Mira N... una a tu mano, otra al Cementerio"
				# (p.ej. Signo Amarillo) — extract_action() solo reconoce UNA
				# acción simple a la vez, así que este patrón se resuelve aparte.
				if await _try_execute_look_pick_pattern(ability_text, controller_id):
					result["no_handler"] = false
				else:
					var action := UniversalCardParser.extract_action(ability_text)
					if action.get("matched", false):
						await _execute_parsed_action(action, card, event_data)
						result["no_handler"]    = false
						result["parsed_action"] = action
		elif trigger_type == "on_attack":
			# No usar extract_action() sobre el texto completo: una carta puede
			# tener "Cuando entra en juego, Roba dos cartas. Cuando ataque, ..."
			# en el mismo bloque, y extract_action() encuentra la PRIMERA acción
			# reconocible en todo el texto sin importar bajo qué disparador
			# está — dispararía de nuevo el robo de la entrada. Por eso acá se
			# aísla primero la oración que contiene la frase de "ataque".
			var ability_text: String = ""
			if card.get("card_data") != null:
				ability_text = card.card_data.get("habilidad", "")
			var clause := _isolate_trigger_clause(ability_text, ["cuando ataque", "cuando atac", "al atacar"])
			if not clause.is_empty():
				var action := UniversalCardParser.extract_action(clause)
				if action.get("matched", false):
					await _execute_parsed_action(action, card, event_data)
					result["no_handler"]    = false
					result["parsed_action"] = action
		elif trigger_type == "on_damage_dealt":
			# 'Cuando inflija daño'/'si hizo daño' (DAR) — mismo aislamiento
			# de oración que on_attack, por la misma razón: una carta puede
			# tener varios disparadores distintos en el mismo bloque de texto.
			var ability_text: String = ""
			if card.get("card_data") != null:
				ability_text = card.card_data.get("habilidad", "")
			var clause := _isolate_trigger_clause(ability_text, [
				"cuando inflija daño", "al infligir daño", "si hizo daño",
				"cuando haga daño", "si inflige daño"
			])
			if not clause.is_empty():
				var action := UniversalCardParser.extract_action(clause)
				if action.get("matched", false):
					await _execute_parsed_action(action, card, event_data)
					result["no_handler"]    = false
					result["parsed_action"] = action

	return result


func _isolate_trigger_clause(ability_text: String, trigger_phrases: Array) -> String:
	"""Devuelve solo la oración (separada por '.') que contiene alguna de las
	frases disparadoras dadas, para no interpretar el texto de OTRO
	disparador de la misma carta como si fuera el de este evento."""
	if ability_text.is_empty():
		return ""
	for raw_sentence in ability_text.split("."):
		var sentence: String = raw_sentence.strip_edges()
		if sentence.is_empty():
			continue
		var lower_s := sentence.to_lower()
		for phrase in trigger_phrases:
			if phrase in lower_s:
				return sentence
	return ""


# =============================================================================
# PATRÓN "MIRA N... UNA A TU MANO, OTRA AL CEMENTERIO" (p.ej. Signo Amarillo)
# =============================================================================
func _try_execute_look_pick_pattern(ability_text: String, controller_id: int) -> bool:
	"""Detecta y resuelve el patrón 'Mira N cartas del tope de tu Castillo.
	Pon una en tu mano, otra en tu Cementerio [y ordena el resto]' — común a
	varias cartas de Mitos y Leyendas, no solo Signo Amarillo. No es un motor
	genérico de acciones compuestas (extract_action() solo maneja una acción
	simple a la vez): es un patrón reconocido a mano por regex.
	'Ordena el resto' queda pendiente — las cartas no elegidas vuelven al
	tope en su orden actual.
	Returns: true si el patrón aplicaba (se haya podido resolver o no)."""
	var lower := ability_text.to_lower()
	if not ("tu mano" in lower and "cementerio" in lower):
		return false

	var look_rx := RegEx.new()
	look_rx.compile("(?i)mira[s]?\\s+(\\d+|una|dos|tres|cuatro|cinco|seis|siete|ocho)\\s+cartas?\\s+del\\s+tope")
	var m := look_rx.search(ability_text)
	if not m:
		return false

	var amount: int = UniversalCardParser._parse_amount(m.get_string(1))
	var cm = get_node_or_null("/root/CardManager")
	if not cm:
		return true

	var deck: Array = cm.get_deck(controller_id)
	var top_cards: Array = deck.slice(0, mini(amount, deck.size()))
	if top_cards.is_empty():
		return true

	await _resolve_look_pick_hand_and_mill(controller_id, top_cards)
	return true


func _resolve_look_pick_hand_and_mill(player_id: int, top_cards: Array) -> void:
	"""Muestra las cartas miradas (privado, vía SelectionManager — el mismo
	panel que usa Exhumar/límite de mano), deja elegir 1 para la mano y 1
	para el Cementerio, y devuelve el resto al tope del Castillo en su
	orden actual."""
	var cm = get_node_or_null("/root/CardManager")
	var deck: Array = cm.get_deck(player_id) if cm else []

	# Sacar del mazo las cartas miradas — su destino se decide a continuación
	for i in range(top_cards.size()):
		if not deck.is_empty():
			deck.pop_front()

	var remaining: Array = top_cards.duplicate()

	SelectionManager.open_selection(remaining, SelectionManager.SelectionMode.CUSTOM, {
		"title": "Elige 1 carta para tu mano (de %d miradas)" % remaining.size(),
		"max_selections": 1,
		"min_selections": 1,
		"can_cancel": false
	})
	var to_hand: Dictionary = await SelectionManager.card_selected
	_remove_data_from_array(remaining, to_hand)

	var to_cemetery: Dictionary = {}
	if not remaining.is_empty():
		SelectionManager.open_selection(remaining, SelectionManager.SelectionMode.CUSTOM, {
			"title": "Elige 1 carta para el Cementerio",
			"max_selections": 1,
			"min_selections": 1,
			"can_cancel": false
		})
		to_cemetery = await SelectionManager.card_selected
		_remove_data_from_array(remaining, to_cemetery)

	var main = get_node_or_null("/root/Main")
	if main and not to_hand.is_empty() and main.has_method("_create_card"):
		var card_node = main._create_card(to_hand)
		main.player_hand.add_card(card_node)
		main._connect_card_signals(card_node)

	if cm and not to_cemetery.is_empty():
		cm.add_to_cemetery(player_id, to_cemetery)

	# "Ordena el resto" queda pendiente — se devuelven al tope en su orden actual
	for i in range(remaining.size() - 1, -1, -1):
		deck.push_front(remaining[i])

	if main and main.has_method("_update_castillo_counts"):
		main._update_castillo_counts()


func _remove_data_from_array(array: Array, data: Dictionary) -> void:
	"""Quita de 'array' el diccionario de carta que coincide por id/uuid con 'data'."""
	if data.is_empty():
		return
	var search_id = data.get("id", "")
	var search_uuid = data.get("uuid", "")
	for i in range(array.size()):
		var item = array[i]
		if (search_id and item.get("id") == search_id) or (search_uuid and item.get("uuid") == search_uuid):
			array.remove_at(i)
			return


func _execute_parsed_action(action: Dictionary, card: Node, _event_data: Dictionary) -> void:
	"""Ejecuta un GameAction retornado por extract_action().
	Ruta principal: ActionModule.draw(N).
	Fallback: ZoneManager.draw_card() × N (como especificado en el DAR).
	"""
	var controller_id: int = card.get("controller_id") if card.get("controller_id") != null else 0
	var amount: int = action.get("value", 1)

	match action.get("type", ""):
		"DRAW":
			var am := get_node_or_null("/root/ActionModule")
			if am and am.has_method("draw"):
				await am.draw(controller_id, amount, "etb_trigger")
			else:
				# Fallback directo a ZoneManager.draw_card()
				var zm := get_node_or_null("/root/ZoneManager")
				if zm and zm.has_method("draw_card"):
					for _i in range(amount):
						zm.draw_card(controller_id)
				else:
					push_warning("[TriggerSystem] No se pudo ejecutar DRAW: ActionModule y ZoneManager no disponibles")

		"DESTROY":
			await _execute_targeted_destroy(card)

		"BANISH":
			await _execute_targeted_banish(card)

		"DISCARD":
			await _execute_targeted_discard(card, controller_id, amount)

		"SHUFFLE":
			var am_shuffle := get_node_or_null("/root/ActionModule")
			if am_shuffle and am_shuffle.has_method("shuffle_deck"):
				am_shuffle.shuffle_deck(controller_id)
			else:
				push_warning("[TriggerSystem] ActionModule.shuffle_deck no disponible")

		"MILL":
			var am_mill := get_node_or_null("/root/ActionModule")
			if am_mill and am_mill.has_method("mill"):
				var ability_text_mill: String = card.get("card_ability") if card.get("card_ability") != null else ""
				var to_exile_mill: bool = "destierro" in ability_text_mill.to_lower()
				# skip_validation=true: _validate_mill() depende del GameBoard
				# legacy (siempre null) y rechazaría la acción antes de
				# llegar al fallback real de mill() (vía EffectController).
				await am_mill.mill(controller_id, amount, to_exile_mill, "etb_trigger", true)
			else:
				push_warning("[TriggerSystem] ActionModule.mill no disponible")

		"SEARCH":
			await _execute_targeted_search(card, controller_id)

		"LOOK":
			# Cartas simples "Mira N cartas del tope" sin el patrón compuesto
			# de elegir 1 a mano / 1 a Cementerio (ese lo resuelve
			# _try_execute_look_pick_pattern() antes de llegar acá) — solo
			# las muestra, en privado, sin mover nada.
			var cm := get_node_or_null("/root/CardManager")
			if cm:
				var deck: Array = cm.get_deck(controller_id)
				var top_cards: Array = deck.slice(0, mini(amount, deck.size()))
				if not top_cards.is_empty():
					SelectionManager.open_reveal(top_cards, "Mirando %d carta(s) del tope de tu Castillo" % top_cards.size())

		"REVEAL":
			# Igual que LOOK pero es información pública (DAR): ambos
			# jugadores "ven" las cartas reveladas, no solo el controlador.
			# El overlay es local (SelectionManager no distingue jugadores en
			# red), así que la diferencia real es el título mostrado.
			var cm_reveal := get_node_or_null("/root/CardManager")
			if cm_reveal:
				var deck_reveal: Array = cm_reveal.get_deck(controller_id)
				var top_cards_reveal: Array = deck_reveal.slice(0, mini(amount, deck_reveal.size()))
				if not top_cards_reveal.is_empty():
					SelectionManager.open_reveal(top_cards_reveal, "Revelando %d carta(s) del tope del Castillo (público)" % top_cards_reveal.size())

		"BUFF", "DEBUFF":
			await _execute_targeted_buff(action, card, controller_id, amount)

		"SILENCE":
			await _execute_targeted_silence(card)

		"ANNUL":
			await _execute_targeted_annul(card)

		"PREVENT_DAMAGE":
			var dm := get_node_or_null("/root/DamageManager")
			if dm and dm.has_method("add_damage_prevention"):
				# type -1 = cualquier tipo de daño (convención ya usada en
				# DamageManager para "aplica a todo"); one_shot: se consume
				# con el primer daño que prevenga, no dura el turno completo.
				dm.add_damage_prevention(controller_id, amount, -1, true, card)
			else:
				push_warning("[TriggerSystem] DamageManager.add_damage_prevention no disponible")

		_:
			push_warning("[TriggerSystem] Tipo de acción ETB no implementado: %s" % action.get("type", "?"))


func _select_ally_target(prompt: String) -> Node:
	"""Pide al jugador elegir un Aliado en juego (propio o enemigo) con clic,
	reutilizando el modo de selección que ya usa 'colocar Oro'
	(CardInteractionModule.is_selecting_target). Devuelve null si no hay
	forma de abrir el modo de selección (Main/CardInteractionModule ausentes)."""
	var main := get_node_or_null("/root/Main")
	if not main or not main._card_interaction:
		push_warning("[TriggerSystem] No se pudo abrir selección de objetivo")
		return null

	var chosen_target: Node = null
	var done := false
	var filter := func(c: Node) -> bool:
		if c.get("card_type") != Constants.CardType.ALIADO:
			return false
		var parent = c.get_parent()
		return parent == main.player_field or parent == main.opponent_field
	var on_selected := func(c: Node) -> void:
		chosen_target = c
		done = true

	main._card_interaction.start_target_selection(prompt, filter, on_selected)
	while not done:
		await get_tree().process_frame

	return chosen_target


func _execute_targeted_buff(action: Dictionary, card: Node, _controller_id: int, amount: int) -> void:
	"""Modifica la Fuerza de UN Aliado elegido por el jugador (DAR 7.2).
	Los Aliados tienen un único indicador de Fuerza (que también es su vida/
	resistencia) — no hay par ataque/defensa. El modificador se registra en
	ContinuousEffectManager — BattleManager._get_strength() ya lo consulta,
	así que se refleja de inmediato en el cálculo de combate."""
	var is_debuff: bool = action.get("type", "") == "DEBUFF"
	var value: int = -amount if is_debuff else amount
	var sign := "-" if is_debuff else "+"
	var chosen_target := await _select_ally_target("Elige un Aliado: %s%d de Fuerza" % [sign, amount])

	if not chosen_target or not is_instance_valid(chosen_target):
		return

	var duration = ContinuousEffectManager.ModifierDuration.PERMANENT
	var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
	var ability_lower := ability_text.to_lower()
	if "este turno" in ability_lower or "final del turno" in ability_lower:
		duration = ContinuousEffectManager.ModifierDuration.UNTIL_END_TURN

	var card_name: String = card.get("card_name") if card.get("card_name") != null else "carta"
	ContinuousEffectManager.register_modifier({
		"source": card,
		"target": chosen_target,
		"type": ContinuousEffectManager.ModifierType.STRENGTH,
		"stat": "strength",
		"value": value,
		"operation": "add",
		"duration": duration,
		"layer": ContinuousEffectManager.ModifierLayer.LAYER_7B_CHAR_MODIFY,
		"description": "%s de %s" % [("Debuff" if is_debuff else "Buff"), card_name],
	})


func _execute_targeted_destroy(card: Node) -> void:
	"""Destruye UN Aliado en juego elegido por el jugador — va al Cementerio
	(a diferencia de ANNUL/BANISH, que van a Destierro)."""
	var chosen_target := await _select_ally_target("Elige un Aliado para destruir")
	if not chosen_target or not is_instance_valid(chosen_target):
		return
	var am := get_node_or_null("/root/ActionModule")
	if am and am.has_method("destroy"):
		await am.destroy([chosen_target], card)
	else:
		push_warning("[TriggerSystem] ActionModule.destroy no disponible")


func _execute_targeted_banish(card: Node) -> void:
	"""Destierra UN Aliado en juego elegido por el jugador — va a Destierro,
	no se puede recuperar por medios normales (DAR Sección 8)."""
	var chosen_target := await _select_ally_target("Elige un Aliado para desterrar")
	if not chosen_target or not is_instance_valid(chosen_target):
		return
	var am := get_node_or_null("/root/ActionModule")
	if am and am.has_method("banish"):
		await am.banish([chosen_target], card)
	else:
		push_warning("[TriggerSystem] ActionModule.banish no disponible")


func _execute_targeted_discard(card: Node, controller_id: int, amount: int) -> void:
	"""Descarta N cartas de una mano (DAR Sección 8). Por defecto la mano del
	controlador; si el texto menciona 'oponente'/'rival', la del rival. Si
	dice 'al azar' se eligen al azar; si no, y es la mano del jugador humano,
	él elige con la UI (mismo overlay que el descarte por límite de mano)."""
	var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
	var ability_lower := ability_text.to_lower()
	var random_pick := "al azar" in ability_lower
	var target_player := controller_id
	if "oponente" in ability_lower or "rival" in ability_lower:
		target_player = 1 - controller_id

	var main := get_node_or_null("/root/Main")
	if not main:
		return

	var hand_cards: Array = []
	if target_player == 0:
		if main.player_hand and main.player_hand.get("cards") != null:
			hand_cards = main.player_hand.cards.duplicate()
	else:
		if main._opponent_fan and main._opponent_fan.has_method("get_cards"):
			hand_cards = main._opponent_fan.get_cards().duplicate()
	if hand_cards.is_empty():
		return

	amount = mini(amount, hand_cards.size())
	var to_discard: Array
	if target_player == 0 and not random_pick:
		to_discard = await _select_hand_cards_for_discard(hand_cards, amount)
	else:
		hand_cards.shuffle()
		to_discard = hand_cards.slice(0, amount)

	if to_discard.is_empty():
		return

	var am := get_node_or_null("/root/ActionModule")
	if am and am.has_method("discard"):
		await am.discard(target_player, to_discard, "etb_trigger", true)
	else:
		push_warning("[TriggerSystem] ActionModule.discard no disponible")


func _select_hand_cards_for_discard(hand_cards: Array, amount: int) -> Array:
	"""Pide al jugador humano elegir qué cartas descartar de su propia mano,
	reutilizando el overlay SelectionManager en modo DISCARD (mismo patrón
	de espera de señal que ActionModule._select_search_results())."""
	var card_data_list: Array = []
	for c in hand_cards:
		card_data_list.append(c.card_data)

	var picked_data: Array = []
	var resolved := false
	var on_completed := func(cards: Array):
		picked_data = cards
		resolved = true
	var on_single := func(data: Dictionary):
		picked_data = [data]
		resolved = true

	SelectionManager.selection_completed.connect(on_completed, CONNECT_ONE_SHOT)
	SelectionManager.card_selected.connect(on_single, CONNECT_ONE_SHOT)
	SelectionManager.open_selection(card_data_list, SelectionManager.SelectionMode.DISCARD, {
		"title": "Descarta %d carta(s)" % amount,
		"max_selections": amount,
		"min_selections": amount,
		"can_cancel": false,
	})
	while not resolved:
		await get_tree().process_frame
	if SelectionManager.selection_completed.is_connected(on_completed):
		SelectionManager.selection_completed.disconnect(on_completed)
	if SelectionManager.card_selected.is_connected(on_single):
		SelectionManager.card_selected.disconnect(on_single)

	# Traducir datos elegidos de vuelta a los nodos Card reales
	var chosen_nodes: Array = []
	for data in picked_data:
		for c in hand_cards:
			if c.card_data == data:
				chosen_nodes.append(c)
				break
	return chosen_nodes


func _execute_targeted_silence(card: Node) -> void:
	"""Silencia UN Aliado elegido por el jugador: pierde todas sus keywords
	(KeywordManager.silence_card) y deja de disparar sus habilidades
	activadas/disparadas (KeywordManager.is_silenced(), consultado en
	_check_trigger_conditions())."""
	var chosen_target := await _select_ally_target("Elige un Aliado para silenciar")
	if not chosen_target or not is_instance_valid(chosen_target):
		return

	var kw_mgr = get_node_or_null("/root/KeywordManager")
	if kw_mgr and kw_mgr.has_method("silence_card"):
		kw_mgr.silence_card(chosen_target, card, "permanent")
	else:
		push_warning("[TriggerSystem] KeywordManager.silence_card no disponible")


func _execute_targeted_search(card: Node, controller_id: int) -> void:
	"""Busca en el Castillo o Cementerio (DAR Sección 8): relee el texto
	completo de la carta (no solo el fragmento que capturó ABILITY_PATTERNS)
	para extraer zona, tipo de carta buscado, cantidad y si la carta
	encontrada se juega directamente pagando su coste o va a la mano."""
	var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
	var ability_lower := ability_text.to_lower()

	var zone := Constants.Zone.CASTILLO
	if "cementerio" in ability_lower:
		zone = Constants.Zone.CEMENTERIO

	var filter: Dictionary = {}
	if "aliado" in ability_lower:
		filter["type"] = Constants.CardType.ALIADO
	elif "talismán" in ability_lower or "talisman" in ability_lower:
		filter["type"] = Constants.CardType.TALISMAN
	elif "tótem" in ability_lower or "totem" in ability_lower:
		filter["type"] = Constants.CardType.TOTEM
	elif "arma" in ability_lower:
		filter["type"] = Constants.CardType.ARMA
	elif "oro" in ability_lower:
		filter["type"] = Constants.CardType.ORO

	var amount := 1
	var amount_rx := RegEx.new()
	amount_rx.compile("busca (\\d+)")
	var amount_match := amount_rx.search(ability_lower)
	if amount_match:
		amount = int(amount_match.get_string(1))

	var may_play := (
		"puedes jugarla" in ability_lower
		or "puedes ponerla en juego" in ability_lower
		or "juégala" in ability_lower
		or "pagando su coste" in ability_lower
	)

	var am := get_node_or_null("/root/ActionModule")
	if am and am.has_method("search"):
		await am.search(controller_id, zone, filter, amount, true, false, may_play, card)
	else:
		push_warning("[TriggerSystem] ActionModule.search no disponible")


func _execute_targeted_annul(card: Node) -> void:
	"""Anula UN Aliado en juego elegido por el jugador (DAR): por defecto va
	al Cementerio, igual que cualquier destrucción — solo va al Destierro si
	el propio texto de ESTA carta lo dice explícitamente (p.ej. 'destiérralo
	en su lugar'). Resolución directa, sin ventana de respuesta (ver alcance
	acordado): no intercepta nada en la pila, actúa sobre algo que YA está
	en juego."""
	var chosen_target := await _select_ally_target("Elige un Aliado para anular")
	if not chosen_target or not is_instance_valid(chosen_target):
		return

	var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
	var ability_lower := ability_text.to_lower()
	var goes_to_banish := "destierr" in ability_lower or "destierro" in ability_lower

	var am := get_node_or_null("/root/ActionModule")
	if not am:
		push_warning("[TriggerSystem] ActionModule no disponible")
		return

	if goes_to_banish and am.has_method("banish"):
		await am.banish([chosen_target], card)
	elif am.has_method("destroy"):
		await am.destroy([chosen_target], card)
	else:
		push_warning("[TriggerSystem] ActionModule.destroy/banish no disponible")


func resolve_all_triggers() -> void:
	"""Resuelve todos los triggers en la cola secuencialmente"""
	while not trigger_queue.is_empty():
		var trigger = await resolve_next_trigger()
		if trigger.is_empty():
			break
		# Esperar un frame entre triggers para permitir animaciones
		await get_tree().process_frame

	is_resolving = false
	emit_signal("all_triggers_resolved")


func has_pending_triggers() -> bool:
	"""Verifica si hay triggers pendientes"""
	return not trigger_queue.is_empty()


func clear_triggers() -> void:
	"""Limpia todos los triggers pendientes"""
	trigger_queue.clear()
	pending_active_triggers.clear()
	pending_opponent_triggers.clear()
	is_collecting = false
	is_resolving = false


# =============================================================================
# HANDLERS DE EVENTOS GLOBALES
# =============================================================================
func _on_global_event(player_id: int, card: Node, event_type: String) -> void:
	"""Handler genérico para eventos de 2 parámetros"""
	_collect_triggers_for_event(event_type, {
		"player_id": player_id,
		"card": card
	})


func _on_global_event_with_zone(player_id: int, card: Node, zone: int, event_type: String) -> void:
	"""Handler para eventos con zona"""
	_collect_triggers_for_event(event_type, {
		"player_id": player_id,
		"card": card,
		"zone": zone
	})


func _on_global_event_with_dest(player_id: int, card: Node, destination: int, event_type: String) -> void:
	"""Handler para eventos con destino"""
	_collect_triggers_for_event(event_type, {
		"player_id": player_id,
		"card": card,
		"destination": destination
	})


func _collect_triggers_for_event(event_type: String, event_data: Dictionary) -> void:
	"""Recolecta todos los triggers que responden a un evento.

	GUARDIA DE REENTRADA (2026-08-16): esta función se llama con 'await' desde
	varios sitios (GoldManager al jugar una carta, GameManager al declarar un
	atacante). trigger_queue/pending_* son variables de módulo COMPARTIDAS —
	si un jugador dispara un segundo evento (p.ej. declara un ataque) mientras
	la ventana de respuesta del trigger anterior (p.ej. 'roba 2' de un oro
	recién jugado) sigue abierta, la segunda llamada empezaba a recolectar y
	encolar SOBRE la misma cola que el primer resolve_all_triggers() todavía
	estaba vaciando en su propio bucle — dos bucles compitiendo por el mismo
	trigger_queue. Resultado real reportado: el efecto del oro se resolvía
	recién al intentar atacar, y la ventana de prioridad quedaba en un estado
	que ya no dejaba pasar. Se espera a que la recolección/resolución anterior
	termine antes de empezar una nueva — así siempre queda serializado."""
	while is_collecting or is_resolving:
		await get_tree().process_frame
	begin_collecting()

	var event_card = event_data.get("card", null)

	# ── Camino directo: el propio disparador de la carta del evento ────────
	# (p.ej. "Cuando entra en juego" de la carta que se acaba de jugar). No
	# depende de GameManager.game_board — ese es el GameBoard legacy huérfano
	# (docs/audit-2026-08-13.html, hallazgo 2/4), nunca registrado en la
	# escena real; exigirlo aquí hacía que NINGUNA carta disparara NUNCA
	# ningún trigger por este camino.
	if event_card and is_instance_valid(event_card) and event_card.has_method("has_trigger"):
		if event_card.has_trigger(event_type):
			if _check_trigger_conditions(event_card, event_type, event_data):
				register_trigger(event_card, event_type, event_data)

	# ── Camino completo: triggers de OTRAS cartas que reaccionan a este
	# evento (p.ej. "Cuando otro Aliado entre al juego..."). Antes dependía
	# de GameManager.game_board (el GameBoard legacy huérfano, siempre null)
	# y nunca se ejecutaba — usa el campo real de Main (un solo contenedor
	# por jugador, no hay zonas separadas de Defensa/Ataque/Apoyo).
	#
	# CORRECCIÓN (2026-08-17): este bucle también revisaba si OTRAS cartas
	# tenían el mismo event_type ("on_enter_play", "on_attack", etc.) que
	# la carta que disparó el evento — pero esos triggers son propios de
	# CADA carta ("cuando ESTA carta entra en juego"), no algo que otra
	# carta deba compartir solo por tener una frase parecida en su propio
	# texto. Resultado real: cada vez que se jugaba una carta nueva, TODAS
	# las demás cartas del campo con su propio 'cuando entra en juego' (ya
	# resuelto hace turnos) volvían a dispararse. Solo debe revisarse
	# related_triggers (p.ej. on_ally_enters), que sí está pensado para
	# difundirse a otras cartas bajo un trigger_type distinto.
	var main = get_node_or_null("/root/Main")
	if main:
		var related_triggers = _get_related_triggers(event_type, event_card)

		if not related_triggers.is_empty():
			for player_id in [0, 1]:
				var field = main.player_field if player_id == 0 else main.opponent_field
				if not field:
					continue
				for card in field.get_children():
					if card == event_card:
						continue  # ya se registró arriba
					if not card.has_method("has_trigger"):
						continue
					for related in related_triggers:
						if card.has_trigger(related):
							if _check_trigger_conditions(card, related, event_data):
								register_trigger(card, related, event_data)

	end_collecting_and_queue()

	# Si hay triggers, resolverlos — con 'await': sin esto, esta función
	# volvía a quien la llamó apenas EMPEZABA a resolver, no cuando terminaba
	# (ese era el resto del bug de Drácula/Signo Amarillo resolviendo fases
	# después de jugarse — la cadena de espera se cortaba justo acá).
	if has_pending_triggers():
		await resolve_all_triggers()


func _get_related_triggers(event_type: String, event_card: Node) -> Array:
	"""Retorna triggers relacionados que se activan con un evento"""
	var related: Array = []

	# Si una carta entra al juego y es un aliado
	if event_type == "on_enter_play":
		if event_card and event_card.get("card_type") == Constants.CardType.ALIADO:
			related.append("on_ally_enters")

	# Si una carta es destruida y es un aliado
	if event_type == "on_destroyed":
		if event_card and event_card.get("card_type") == Constants.CardType.ALIADO:
			related.append("on_ally_dies")

	return related


func _check_trigger_conditions(card: Node, trigger_type: String, event_data: Dictionary) -> bool:
	"""Verifica las condiciones del trigger"""
	var kw_mgr = get_node_or_null("/root/KeywordManager")
	if kw_mgr and kw_mgr.has_method("is_silenced") and kw_mgr.is_silenced(card):
		return false
	if card.has_method("_trigger_conditions_met"):
		return card._trigger_conditions_met(trigger_type, event_data)
	return true


# =============================================================================
# EFECTOS CONTINUOS Y PRIORIDAD NEGATIVA (DAR - Restricciones)
# =============================================================================
func register_continuous_effect(source_card: Node, effect: Dictionary) -> void:
	"""Registra un efecto continuo activo
	effect debe contener:
	- type: String (ej: "prevent_draw", "prevent_damage", "block_triggers")
	- is_negative: bool (las restricciones son negativas y ganan conflictos)
	- condition: Callable opcional para verificar si aplica
	- targets: Array de tipos de carta o "all"
	"""
	effect["source"] = source_card
	effect["id"] = "%s_%d" % [source_card.get_instance_id(), Time.get_ticks_msec()]
	continuous_effects.append(effect)
	print("[TriggerSystem] Efecto continuo registrado: %s de %s" % [effect.type, source_card.card_name])


func unregister_continuous_effect(source_card: Node) -> void:
	"""Elimina todos los efectos continuos de una carta"""
	continuous_effects = continuous_effects.filter(func(e): return e.source != source_card)


func _is_blocked_by_continuous_effect(card: Node, trigger_type: String) -> bool:
	"""Verifica si un trigger está bloqueado por un efecto continuo negativo
	DAR: El efecto negativo (restricción) siempre gana
	"""
	for effect in continuous_effects:
		if not effect.get("is_negative", false):
			continue

		if effect.type == "block_triggers":
			# Verificar si bloquea este tipo de trigger
			var blocked_types = effect.get("blocked_triggers", [])
			if trigger_type in blocked_types or "all" in blocked_types:
				# Verificar condición si existe
				if effect.has("condition"):
					var condition: Callable = effect.condition
					if condition.is_valid() and condition.call(card):
						return true
				else:
					return true

		if effect.type == "block_card":
			# Bloquea triggers de una carta específica
			var target_card = effect.get("target_card")
			if target_card == card:
				return true

	return false


func get_active_continuous_effects(filter_type: String = "") -> Array:
	"""Retorna efectos continuos activos, opcionalmente filtrados por tipo"""
	if filter_type.is_empty():
		return continuous_effects.duplicate()

	return continuous_effects.filter(func(e): return e.type == filter_type)


func check_continuous_prevention(action_type: String, target: Node = null) -> Dictionary:
	"""Verifica si una acción está prevenida por efectos continuos
	Retorna: {prevented: bool, by: Node, effect: Dictionary}
	"""
	for effect in continuous_effects:
		if effect.type != action_type:
			continue

		if effect.get("is_negative", false):
			# Verificar si aplica al target
			var applies = true
			if target and effect.has("condition"):
				var condition: Callable = effect.condition
				applies = condition.is_valid() and condition.call(target)

			if applies:
				return {
					"prevented": true,
					"by": effect.source,
					"effect": effect
				}

	return {"prevented": false, "by": null, "effect": {}}


# =============================================================================
# UTILIDADES PARA CALLABLE EN CARTAS
# =============================================================================
func create_trigger_handler(card: Node) -> Callable:
	"""Crea un handler de triggers para una carta
	Usado cuando la carta entra al juego para conectar dinámicamente
	"""
	return func(trigger_type: String, event_data: Dictionary) -> Dictionary:
		return await card._on_trigger_event(trigger_type, event_data)


func bind_card_to_triggers(card: Node) -> void:
	"""Vincula una carta al sistema de triggers cuando entra al juego
	Llama a _on_trigger_event de la carta con Callable
	"""
	if not card.has_method("_on_trigger_event"):
		return

	# Parsear triggers del texto de habilidad
	if card.has_method("parse_triggers_from_ability"):
		card.parse_triggers_from_ability()

	print("[TriggerSystem] Carta %s vinculada al sistema de triggers" % card.card_name)


# =============================================================================
# SISTEMA DE BUFFS/DEBUFFS TEMPORALES
# =============================================================================
func apply_buff(source: Node, target: Node, buff_type: String, value: int, duration: String = "this_turn") -> Dictionary:
	"""Aplica un buff/debuff temporal a una carta

	Args:
		source: Carta que genera el efecto
		target: Carta afectada
		buff_type: Tipo de modificador ("attack", "defense", "cost", etc.)
		value: Valor del modificador (positivo = buff, negativo = debuff)
		duration: Duración ("this_turn", "until_final", "until_next_turn", "permanent")

	Returns: El buff creado
	"""
	var current_turn = GameManager.current_turn if GameManager else 0

	var buff = {
		"id": "%s_%d_%d" % [buff_type, target.get_instance_id(), Time.get_ticks_msec()],
		"source": source,
		"target": target,
		"type": buff_type,
		"value": value,
		"duration": duration,
		"turn_applied": current_turn
	}

	temporary_buffs.append(buff)

	# Aplicar el modificador a la carta
	if target.has_method("apply_modifier"):
		target.apply_modifier(buff_type, value, buff.id)

	print("[TriggerSystem] Buff aplicado: %s %+d a %s (duración: %s)" % [
		buff_type, value, target.card_name if target.get("card_name") else str(target), duration
	])

	emit_signal("buff_applied", target, buff)
	return buff


func remove_buff(buff_id: String) -> bool:
	"""Elimina un buff específico por ID"""
	for i in range(temporary_buffs.size() - 1, -1, -1):
		var buff = temporary_buffs[i]
		if buff.id == buff_id:
			var target = buff.target

			# Quitar el modificador de la carta
			if is_instance_valid(target) and target.has_method("remove_modifier"):
				target.remove_modifier(buff.type, buff.id)

			emit_signal("buff_expired", target, buff)
			temporary_buffs.remove_at(i)
			return true

	return false


func remove_buffs_from_source(source: Node) -> int:
	"""Elimina todos los buffs de una fuente específica"""
	var removed = 0

	for i in range(temporary_buffs.size() - 1, -1, -1):
		var buff = temporary_buffs[i]
		if buff.source == source:
			var target = buff.target

			if is_instance_valid(target) and target.has_method("remove_modifier"):
				target.remove_modifier(buff.type, buff.id)

			emit_signal("buff_expired", target, buff)
			temporary_buffs.remove_at(i)
			removed += 1

	return removed


func remove_buffs_from_target(target: Node) -> int:
	"""Elimina todos los buffs que afectan a una carta"""
	var removed = 0

	for i in range(temporary_buffs.size() - 1, -1, -1):
		var buff = temporary_buffs[i]
		if buff.target == target:
			if target.has_method("remove_modifier"):
				target.remove_modifier(buff.type, buff.id)

			emit_signal("buff_expired", target, buff)
			temporary_buffs.remove_at(i)
			removed += 1

	return removed


func clear_expired_buffs(duration: String) -> int:
	"""Limpia todos los buffs que expiran con la duración especificada
	Llamado por TurnManager al final del turno o fase

	Args:
		duration: "this_turn", "until_final", "until_next_turn"

	Returns: Cantidad de buffs eliminados
	"""
	var removed = 0
	var current_turn = GameManager.current_turn if GameManager else 0

	for i in range(temporary_buffs.size() - 1, -1, -1):
		var buff = temporary_buffs[i]
		var should_remove = false

		match duration:
			"this_turn":
				# Expiran al final del turno actual
				should_remove = buff.duration == "this_turn"

			"until_final":
				# Expiran al inicio de la Fase Final
				should_remove = buff.duration == "until_final"

			"until_next_turn":
				# Expiran al inicio del siguiente turno del controlador
				if buff.duration == "until_next_turn":
					should_remove = current_turn > buff.turn_applied

		if should_remove:
			var target = buff.target

			if is_instance_valid(target):
				if target.has_method("remove_modifier"):
					target.remove_modifier(buff.type, buff.id)

				print("[TriggerSystem] Buff expirado: %s de %s" % [
					buff.type, target.card_name if target.get("card_name") else str(target)
				])

			emit_signal("buff_expired", target, buff)
			temporary_buffs.remove_at(i)
			removed += 1

	if removed > 0:
		print("[TriggerSystem] %d buffs con duración '%s' eliminados" % [removed, duration])
		emit_signal("buffs_cleared", removed, duration)

	return removed


func get_buffs_on_target(target: Node) -> Array[Dictionary]:
	"""Obtiene todos los buffs activos en una carta"""
	var result: Array[Dictionary] = []

	for buff in temporary_buffs:
		if buff.target == target:
			result.append(buff)

	return result


func get_total_modifier(target: Node, buff_type: String) -> int:
	"""Calcula el modificador total de un tipo para una carta"""
	var total = 0

	for buff in temporary_buffs:
		if buff.target == target and buff.type == buff_type:
			total += buff.value

	return total


func has_buff_type(target: Node, buff_type: String) -> bool:
	"""Verifica si una carta tiene un buff/debuff de un tipo"""
	for buff in temporary_buffs:
		if buff.target == target and buff.type == buff_type:
			return true
	return false
