extends RefCounted
## ActionSearch — SEARCH (Buscar en zona, DAR Sección 8).
## Opera sobre ActionModule via _main (game board, trigger collection,
## validador, filtro de cartas compartido).
## Extraído de ActionModule.gd (Fase 4 de reestructuración, "módulos gordos").

var _main: Node


func setup(main: Node) -> void:
	_main = main


func _get_searchable_zone_data(player_id: int, zone: int) -> Variant:
	"""Devuelve el Array de datos (Dictionary) de la zona buscable, o null si
	la zona no es buscable. El Castillo y el Cementerio son las únicas zonas
	con datos de carta reales (no nodos) — Mano/Campo son nodos Card, y
	buscar ahí no tiene sentido en DAR (ya están a la vista).
	Se lee vía CardManager, que está sincronizado por referencia con
	Main.player_deck/player_cemetery (ver CardManager.sync_from_main) — así
	que remover una entrada aquí remueve la carta de verdad."""
	match zone:
		Constants.Zone.CASTILLO:
			return CardManager.get_deck(player_id)
		Constants.Zone.CEMENTERIO:
			return CardManager.get_cemetery(player_id)
		_:
			return null


func search(player_id: int, zone: int, filter: Dictionary, amount: int = 1, can_fail: bool = true, skip_validation: bool = false, may_play: bool = false, source_card: Node = null, destination: int = Constants.Zone.MANO, distinct_names: bool = false, chooser_id: int = -1) -> Dictionary:
	"""Busca cartas en el Castillo o Cementerio que cumplan el filtro (DAR
	Sección 8). El jugador elige cuáles llevarse (o todas, si hay menos que
	amount). Si may_play es true, cada carta encontrada se juega de inmediato
	pagando su coste normal en vez de ir a la mano (si no se puede pagar,
	queda en la mano igual — nunca se pierde la carta encontrada).

	Args:
		player_id: ID del jugador dueño de la zona buscada (el destino
			también es SUYO — buscar en el Castillo rival y desterrar manda
			al Destierro del rival, no al propio; DAR: la carta sigue siendo
			del jugador de quien salió)
		chooser_id (2026-09-30, Fase 3 del plan de paridad remota): quién
			HACE la elección — no siempre es player_id. 'Busca en el Castillo
			OPONENTE y destiérralas' tiene player_id=oponente (es SU zona/
			destino) pero quien elige qué desterrar es el CONTROLADOR de la
			habilidad, no la víctima. Default -1 = usar player_id (todo
			llamador existente que no lo pasa sigue viéndose exactamente
			igual que antes de agregar este parámetro).
		zone: Zona donde buscar (CASTILLO o CEMENTERIO — únicas zonas con datos)
		filter: Filtro de cartas {type, raza, cost_max, cost_min, strength_min,
			name_contains, keyword}
		amount: Cantidad máxima a seleccionar
		can_fail: Si puede fallar sin encontrar (false = obligatorio)
		skip_validation: Si omitir validación previa
		destination: Zona final de las cartas encontradas (2026-08-25).
			Constants.Zone.MANO (default, puede jugarse si may_play) o
			Constants.Zone.DESTIERRO (p.ej. Rey de Amarillo: 'busca en un
			Castillo... y Destiérralas' — va directo, sin pasar por la mano).
		distinct_names: Si true, las cartas elegidas no pueden repetir nombre
			entre sí (2026-08-25, p.ej. necro-titan: 'busca... dos cartas de
			distinto nombre').
		may_play: Si true, intenta jugar cada carta encontrada en vez de solo
			guardarla en mano (DAR: 'puedes ponerla en juego pagando su coste')
		source_card: Carta que causa la búsqueda (para triggers/log)

	Returns: {success, selected, matching, searched_zone}
	"""
	var result = {
		"success": true,
		"selected": [],
		"matching": [],
		"searched_zone": zone,
		"must_shuffle": zone == Constants.Zone.CASTILLO
	}

	# DAR Sección 6: Validar estado del juego
	if not skip_validation:
		var validation = _main._validator._validate_search(player_id, zone, filter, amount)
		if not validation.valid:
			result.success = can_fail
			result.error = validation.reason
			result.validation_failed = true
			print("[ActionModule] SEARCH rechazado: %s" % validation.reason)
			return result
		if not validation.warnings.is_empty():
			result.warnings = validation.warnings

	var zone_data = _get_searchable_zone_data(player_id, zone)
	if zone_data == null:
		push_warning("[ActionModule] SEARCH: zona no buscable (%s)" % zone)
		result.success = false
		result.error = "unsupported_zone"
		return result

	_main._begin_trigger_collection()

	_main.emit_signal("action_search_started", player_id, zone, filter)

	# Aplicar filtro sobre los datos de la zona
	var matching: Array = _main._apply_card_filter(zone_data, filter)
	result.matching = matching

	_main.emit_signal("action_search_revealed", player_id, matching)

	if matching.is_empty():
		result.success = can_fail
		if not can_fail:
			result.error = "no_matching_cards"
		_main.emit_signal("action_search_completed", player_id, result)
		await _main._end_trigger_collection_and_resolve()
		return result

	# Si hay cartas, el jugador debe elegir (o se toman todas si hay ≤ amount)
	var to_select = mini(amount, matching.size())
	var effective_chooser: int = chooser_id if chooser_id >= 0 else player_id
	var selected_data: Array = await _select_search_results(matching, to_select, distinct_names, effective_chooser)
	result.selected = selected_data

	_main.emit_signal("action_search_selected", player_id, selected_data)

	var main := _main.get_node_or_null("/root/Main")
	for card_data in selected_data:
		# Remover de la zona de origen (misma referencia que Main.player_deck/
		# player_cemetery — ver _get_searchable_zone_data).
		zone_data.erase(card_data)
		card_data["esta_oculta"] = false

		if destination == Constants.Zone.DESTIERRO:
			# Va directo al Destierro, sin pasar por la mano ni crear un
			# nodo Card (2026-08-25, p.ej. Rey de Amarillo).
			CardManager.add_to_exile(player_id, card_data)
			_main._notify_trigger("on_search_found", {
				"player_id": player_id, "card": card_data, "from_zone": zone
			})
		elif destination == Constants.Zone.RESERVA_ORO and main and main._gold_manager:
			# Va directo a la Reserva de Oro, sin pasar por la mano ni pagar
			# coste (2026-08-29, p.ej. Don de Amma: 'busca un Oro en tu
			# Castillo y ponlo en tu Reserva').
			var card_node = await main._gold_manager.put_gold_directly_in_reserva(player_id, card_data)
			_main._notify_trigger("on_search_found", {
				"player_id": player_id, "card": card_node, "from_zone": zone
			})
		elif destination == Constants.Zone.CEMENTERIO:
			# Va directo al Cementerio, sin pasar por la mano ni crear un
			# nodo Card (2026-09-04, p.ej. kitsune - sp: 'busca en tu
			# Castillo un Aliado y ponlo en tu mano o Cementerio') — mismo
			# patrón que DESTIERRO de arriba.
			CardManager.add_to_cemetery(player_id, card_data)
			_main._notify_trigger("on_search_found", {
				"player_id": player_id, "card": card_data, "from_zone": zone
			})
		elif destination == Constants.Zone.ORO_PAGADO and main and main._gold_manager:
			# Va directo al Oro Pagado (ya-gastado), sin pasar por la mano
			# (2026-09-04, p.ej. Aurora de Chile: 'pon uno en tu Oro Pagado y
			# otro en tu mano') — mismo patrón que RESERVA_ORO de arriba, pero
			# usando put_gold_directly_in_pagado() en vez de _in_reserva().
			var card_node = await main._gold_manager.put_gold_directly_in_pagado(player_id, card_data)
			_main._notify_trigger("on_search_found", {
				"player_id": player_id, "card": card_node, "from_zone": zone
			})
		elif main:
			var card_node = await _put_found_card_into_play(main, player_id, card_data, may_play)
			_main._notify_trigger("on_search_found", {
				"player_id": player_id, "card": card_node, "from_zone": zone
			})

	# Barajar si buscó en el Castillo (DAR: siempre se baraja tras buscar en el mazo)
	if result.must_shuffle:
		zone_data.shuffle()
		AnimationQueue.add_command(AnimationQueue.CommandType.CUSTOM, {
			"callable": Callable(AnimationQueue, "animate_shuffle").bind(player_id),
			"description": "Barajar mazo"
		})

	# 2026-09-14, a pedido del usuario (La Ouija): buscar en el Castillo saca
	# cartas del tope y después lo baraja (arriba), pero a diferencia de
	# CASI todo el resto del código que toca player_deck (ZoneManager.
	# draw_card(), la propia habilidad de La Ouija en DSR_SearchGoldCombos.gd,
	# y ~20 sitios más en los archivos de triggers), esta función genérica
	# — la que de verdad usan la mayoría de las cartas "busca en tu
	# Castillo" — nunca llamaba a ZoneManager._update_castillo_counts(), el
	# único punto de verdad real para refrescar tanto el contador visible
	# del Castillo como el revelado del tope de La Ouija (ver
	# ZoneViewerModule.refresh_castillo_top_reveal()). Resultado: con La
	# Ouija en juego, buscar dejaba la carta revelada vieja en pantalla
	# hasta que algo MÁS disparara el refresco por otro lado.
	if zone == Constants.Zone.CASTILLO and main and main.get("_zone_manager"):
		main._zone_manager._update_castillo_counts()

	_main.emit_signal("action_search_completed", player_id, result)

	await _main._end_trigger_collection_and_resolve()

	return result


func _select_search_results(matching: Array, to_select: int, distinct_names: bool = false, player_id: int = 0) -> Array:
	"""Abre el overlay de selección (SelectionManager) y espera a que el
	jugador elija. Si hay ≤ to_select coincidencias, se toman todas sin
	abrir UI (salvo con distinct_names, ver más abajo). Si el jugador
	cancela, no se toma ninguna.

	IMPORTANTE: con max_selections == 1, SelectionManager cierra en el
	primer clic y emite 'card_selected' (un solo Dictionary) en vez de
	'selection_completed' (un Array) — hay que escuchar ambas señales o el
	await se queda colgado para siempre.

	'player_id' (2026-09-30, Fase 3 del plan de paridad remota — pasado como
	chooser_id a open_search(), ver ese comentario en SelectionManager.gd):
	de quién es esta búsqueda, para que si es el jugador 1 Y es un Remoto
	real, la elección se le pregunte a él por red en vez de al Anfitrión."""
	if distinct_names:
		# No se puede usar el atajo "tomar todas" ni un multi-select de un
		# solo tiro: aunque matching.size() <= to_select, puede haber
		# nombres repetidos entre esas pocas coincidencias. Se elige de a
		# una (2026-08-25, p.ej. necro-titan: 'dos cartas de distinto
		# nombre'), sacando del resto cualquier carta que comparta nombre
		# con la ya elegida antes de ofrecer la siguiente ronda.
		var picked: Array = []
		var pool: Array = matching.duplicate()
		while picked.size() < to_select and not pool.is_empty():
			var one := await _select_search_results(pool, 1, false, player_id)
			if one.is_empty():
				break  # el jugador canceló esta ronda — se queda con lo ya elegido
			var chosen: Dictionary = one[0]
			picked.append(chosen)
			var chosen_name = chosen.get("nombre", chosen.get("name", ""))
			pool = pool.filter(func(c): return c.get("nombre", c.get("name", "")) != chosen_name)
		return picked

	if to_select >= matching.size():
		return matching.duplicate()

	var sel_mgr = SelectionManager

	# state es Dictionary a propósito (2026-08-22): los lambdas de GDScript
	# capturan variables locales POR VALOR — reasignar 'picked'/'resolved'
	# DENTRO del lambda solo movía la copia local del lambda, la de afuera
	# nunca se enteraba y 'while not resolved' colgaba para siempre en
	# silencio (confirmado con un test aislado en Godot).
	var state := {"resolved": false, "picked": []}
	var on_completed := func(cards: Array):
		state.picked = cards
		state.resolved = true
	var on_single_selected := func(card_data: Dictionary):
		state.picked = [card_data]
		state.resolved = true
	var on_cancelled := func():
		state.resolved = true

	sel_mgr.selection_completed.connect(on_completed, CONNECT_ONE_SHOT)
	sel_mgr.card_selected.connect(on_single_selected, CONNECT_ONE_SHOT)
	sel_mgr.selection_cancelled.connect(on_cancelled, CONNECT_ONE_SHOT)
	sel_mgr.open_search(matching, to_select, Callable(), player_id)

	while not state.resolved:
		await _main.get_tree().process_frame

	if sel_mgr.selection_completed.is_connected(on_completed):
		sel_mgr.selection_completed.disconnect(on_completed)
	if sel_mgr.card_selected.is_connected(on_single_selected):
		sel_mgr.card_selected.disconnect(on_single_selected)
	if sel_mgr.selection_cancelled.is_connected(on_cancelled):
		sel_mgr.selection_cancelled.disconnect(on_cancelled)

	return state.picked


func _put_found_card_into_play(main: Node, player_id: int, card_data: Dictionary, may_play: bool) -> Node:
	"""Instancia la carta encontrada y la mete en juego: a la mano, o jugada
	de inmediato (pagando su coste normal) si may_play lo pide y se puede
	pagar. Mismo patrón que ZoneManager.draw_card()/MulliganController — la
	única forma real de que una carta aparezca en la mano/campo de verdad."""
	var is_hidden := player_id != 0
	var card_node = main._create_card(card_data, is_hidden)

	if player_id == 0:
		main.player_hand.add_card(card_node)
		main._connect_card_signals(card_node)
	else:
		main._opponent_fan.add_card(card_node)
		# 2026-09-14, mismo bug real que ZoneManager.draw_card() (ver ese
		# comentario) — faltaba aquí también.
		main._connect_card_signals(card_node)

	if may_play and player_id == 0:
		await _main.get_tree().create_timer(0.3).timeout
		if PaymentManager.puede_jugar_carta(card_node, player_id):
			await main._gold_manager.play_card(card_node)
		# Si no puede pagarla, se queda en la mano — nunca se pierde.

	return card_node
