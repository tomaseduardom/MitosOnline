extends RefCounted
## WeaponSearchShuffleExecutor — Slice de TargetedEffectExecutor.gd dividido
## por tamaño (2026-09-06, "módulos gordos"). Agrupa el cluster compuesto de
## Buscar/Barajar-para-robar/Arma-con-descuento: _execute_targeted_search,
## _execute_shuffle_for_draw (+ su helper _select_cards_by_cost_budget),
## _execute_play_weapon_discount_draw, _execute_return_weapon_swap_free (+ su
## helper _return_equipped_weapon_to_hand) y _count_allies_in_play. Opera
## sobre TriggerSystem via _main (mismo Node que TargetedEffectExecutor._main
## — ver ese archivo para el facade que reune este slice, el de
## MiscTargetedPatterns.gd, y el resto del toolkit de selección de un solo
## objetivo que se quedó en TargetedEffectExecutor.gd por ser el cluster de
## mayor tráfico externo de todo este archivo).

var _main: Node


func setup(main: Node) -> void:
	_main = main


func _execute_targeted_search(card: Node, controller_id: int) -> void:
	"""Busca en el Castillo o Cementerio (DAR Sección 8): relee el texto
	completo de la carta (no solo el fragmento que capturó ABILITY_PATTERNS)
	para extraer zona, dueño de esa zona, tipo de carta buscado, cantidad
	(fija o 'por cada Aliado que controles'), destino (mano/Destierro) y si
	la carta encontrada se juega directamente pagando su coste."""
	var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
	var ability_lower := ability_text.to_lower()

	var zone := Constants.Zone.CASTILLO
	if "cementerio" in ability_lower:
		zone = Constants.Zone.CEMENTERIO

	# Dueño de la zona a buscar (2026-08-25): 'tu Castillo'/'tu Cementerio'
	# es siempre propio; 'Castillo/Cementerio de tu oponente' (o 'rival') es
	# siempre del rival; 'un Castillo' sin posesivo (p.ej. Rey de Amarillo)
	# es AMBIGUO — el jugador elige a cuál apunta.
	var opponent_id := 1 - controller_id
	var zone_owner := controller_id
	var owner_is_ambiguous := false
	if "oponente" in ability_lower or "rival" in ability_lower:
		zone_owner = opponent_id
	elif "tu castillo" in ability_lower or "tu cementerio" in ability_lower:
		zone_owner = controller_id
	elif "un castillo" in ability_lower or "un cementerio" in ability_lower:
		owner_is_ambiguous = true

	if owner_is_ambiguous and controller_id == 0:
		zone_owner = await _main._targeted_executor._choose_search_zone_owner(controller_id, zone)
	elif owner_is_ambiguous:
		zone_owner = controller_id  # el bot no elige de verdad todavía — busca lo propio

	# Tipos mencionados (no 'elif' — 2026-08-22): "busca un Arma o un Oro"
	# (p.ej. Tyet) menciona DOS tipos válidos a la vez, un elif que corta en
	# el primero que encuentra (antes 'arma' ganaba siempre sobre 'oro')
	# dejaba la búsqueda incompleta.
	var wanted_types: Array = []
	if "aliado" in ability_lower:
		wanted_types.append(Constants.CardType.ALIADO)
	if "talismán" in ability_lower or "talisman" in ability_lower:
		wanted_types.append(Constants.CardType.TALISMAN)
	if "tótem" in ability_lower or "totem" in ability_lower:
		wanted_types.append(Constants.CardType.TOTEM)
	if "arma" in ability_lower:
		wanted_types.append(Constants.CardType.ARMA)
	if "oro" in ability_lower:
		wanted_types.append(Constants.CardType.ORO)

	var filter: Dictionary = {}
	if wanted_types.size() == 1:
		filter["type"] = wanted_types[0]
	elif wanted_types.size() > 1:
		filter["type"] = wanted_types

	# Cantidad: fija ("busca 2 cartas") o dinámica "una carta por cada
	# Aliado que controles (más N)" (2026-08-25, p.ej. Rey de Amarillo:
	# 'una carta por cada Aliado que controles más una').
	var amount := 1
	var per_ally_rx := RegEx.new()
	per_ally_rx.compile("por cada aliado que controles(?:\\s+m[aá]s\\s+(\\w+))?")
	var per_ally_match := per_ally_rx.search(ability_lower)
	if per_ally_match:
		amount = _count_allies_in_play(controller_id)
		var bonus_str := per_ally_match.get_string(1)
		if not bonus_str.is_empty():
			amount += UniversalCardParser._parse_amount(bonus_str)
	else:
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

	# Destino: Destierro directo si el texto lo dice (p.ej. 'y Destiérralas'),
	# Reserva de Oro directa si dice 'ponlo/ponla en tu Reserva' (2026-08-29,
	# p.ej. Don de Amma: 'busca un Oro en tu Castillo y ponlo en tu
	# Reserva' — va derecho a Reserva, no a la mano), si no, el default de
	# siempre (mano / juego con may_play).
	var destination := Constants.Zone.MANO
	if "destiérra" in ability_lower or "destierra" in ability_lower:
		destination = Constants.Zone.DESTIERRO
	elif "en tu reserva" in ability_lower or "en su reserva" in ability_lower:
		destination = Constants.Zone.RESERVA_ORO

	# 'de distinto nombre'/'distintos nombres' (2026-08-25, p.ej. necro-titan:
	# 'busca... dos cartas de distinto nombre') — no puede repetirse nombre
	# entre las elegidas.
	var distinct_names := "distinto nombre" in ability_lower or "distintos nombres" in ability_lower

	# search() no consulta Prevención internamente (confirmado en el resto
	# del proyecto) — sí le corresponde la ventana genérica acá.
	if await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		return
	await ActionModule.search(zone_owner, zone, filter, amount, true, false, may_play, card, destination, distinct_names)


func _count_allies_in_play(player_id: int) -> int:
	"""Cuenta los Aliados que controla un jugador (Línea de Defensa +
	Ataque) — usado por cantidades dinámicas tipo 'por cada Aliado que
	controles' (2026-08-25)."""
	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return 0
	var fields = [main.player_field, main.player_linea_ataque] if player_id == 0 \
		else [main.opponent_field, main.opponent_linea_ataque]
	var count := 0
	for field in fields:
		if not field:
			continue
		for c in field.get_children():
			if c.get("card_type") == Constants.CardType.ALIADO:
				count += 1
	return count


func _execute_shuffle_for_draw(action: Dictionary, controller_id: int, card: Node = null) -> void:
	"""'Puedes Barajar cartas de tu mano cuyos costes sumen hasta N y Roba M
	cartas' (p.ej. Bernardo O'Higgins) — DAR: como dice 'puedes', el robo
	queda condicionado a barajar de verdad, no es gratis. Solo el jugador
	humano por ahora (controller_id == 0); el bot simplemente declina."""
	if controller_id != 0:
		return
	var params: Dictionary = action.get("params", {})
	var max_sum: int = params.get("max_cost_sum", 0)
	var draw_amount: int = params.get("draw_amount", 0)
	var main := _main.get_node_or_null("/root/Main")
	if not main or not main.player_hand:
		return
	var hand_cards: Array = main.player_hand.cards.duplicate()
	if hand_cards.is_empty():
		return

	var chosen := await _select_cards_by_cost_budget(hand_cards, max_sum,
		"Puedes barajar cartas cuyos costes sumen hasta %d para robar %d (confirma sin elegir para declinar)" % [max_sum, draw_amount])
	if chosen.is_empty():
		return

	for c in chosen:
		if not is_instance_valid(c):
			continue
		var idx = main.player_hand.cards.find(c)
		if idx >= 0:
			main.player_hand.cards.remove_at(idx)
		if c.get_parent() == main.player_hand:
			main.player_hand.remove_child(c)
		await ActionModule.return_to_deck(c, controller_id, false)
	if main.player_hand.has_method("_arrange_cards"):
		main.player_hand._arrange_cards()

	CardManager.shuffle_deck(controller_id)
	# El barajado (costo) ya se pagó arriba — la ventana va acá, antes del
	# Robo (el efecto en sí), no antes del costo.
	if await TriggerSystem.open_response_window(card, str(card.get("card_name")) if card else "Bernardo O'Higgins", controller_id):
		return
	await ActionModule.draw(controller_id, draw_amount, "etb_trigger", true)


func _select_cards_by_cost_budget(hand_cards: Array, max_sum: int, title: String) -> Array:
	"""Selección múltiple OPCIONAL (0 a N cartas) de la propia mano,
	validando que la suma de costes de lo elegido no supere max_sum.
	Reintenta si se pasa del presupuesto. Array vacío = el jugador declinó."""
	while true:
		var card_data_list: Array = []
		for c in hand_cards:
			if is_instance_valid(c):
				card_data_list.append(c.card_data)
		if card_data_list.is_empty():
			return []

		# state es Dictionary a propósito (2026-08-22): los lambdas de GDScript
		# capturan variables locales POR VALOR — reasignar 'picked_data'/
		# 'resolved'/'declined' DENTRO del lambda solo movía la copia local
		# del lambda, la de afuera nunca se enteraba y 'while not resolved'
		# colgaba para siempre en silencio (confirmado con un test aislado
		# en Godot).
		var state := {"resolved": false, "declined": false, "picked_data": []}
		var on_completed := func(cards: Array):
			state.picked_data = cards
			state.resolved = true
		var on_cancelled := func():
			state.declined = true
			state.resolved = true
		SelectionManager.selection_completed.connect(on_completed, CONNECT_ONE_SHOT)
		SelectionManager.selection_cancelled.connect(on_cancelled, CONNECT_ONE_SHOT)
		SelectionManager.open_selection(card_data_list, SelectionManager.SelectionMode.DISCARD, {
			"title": title,
			"max_selections": card_data_list.size(),
			"min_selections": 0,
			"can_cancel": true,
		})
		while not state.resolved:
			await _main.get_tree().process_frame
		if SelectionManager.selection_completed.is_connected(on_completed):
			SelectionManager.selection_completed.disconnect(on_completed)
		if SelectionManager.selection_cancelled.is_connected(on_cancelled):
			SelectionManager.selection_cancelled.disconnect(on_cancelled)

		if state.declined or state.picked_data.is_empty():
			return []

		var sum_cost := 0
		for d in state.picked_data:
			sum_cost += int(d.get("coste", d.get("cost", 0)))
		if sum_cost <= max_sum:
			var chosen_nodes: Array = []
			for data in state.picked_data:
				for c in hand_cards:
					if is_instance_valid(c) and c.card_data == data:
						chosen_nodes.append(c)
						break
			return chosen_nodes

		var main := _main.get_node_or_null("/root/Main")
		if main:
			main._update_debug("La suma de costes (%d) supera el máximo permitido (%d) — elige de nuevo" % [sum_cost, max_sum])
		# Inalcanzable en la práctica (el while true: solo sale por return),
		# pero el analizador de GDScript no lo sabe y exige un retorno
		# explícito al final de la función — sin esto: "Parse Error: Not all
		# code paths return a value" (confirmado con Godot --check-only).
	return []


func _execute_play_weapon_discount_draw(action: Dictionary, controller_id: int, card: Node = null) -> void:
	"""'Puedes jugar un Arma desde tu mano o Cementerio reduciendo su coste
	en N Oros, hasta un mínimo de M, y Robar K cartas' (p.ej. Lobo Sagrado)
	— NO es "hasta" un Arma: jugarla es obligatorio para robar, el texto no
	permite jugar 0 Armas y robar igual (confirmado por el usuario,
	2026-08-26 — revertido un intento anterior de hacer el robo
	incondicional). Orden: primero se confirma que hay portador y qué Arma
	jugar; recién con eso resuelto se paga y se retira de su zona de
	origen, para que cancelar a mitad de camino no deje nada a medio mover
	ni cobre Oro de más.

	Variante 'hand_only' (p.ej. Hanta: 'puedes jugar un Arma de tu mano
	reduciendo su coste...' sin Cementerio ni robo) reusa toda esta lógica
	— solo cambia el origen elegible y si al final se roba o no."""
	if controller_id != 0:
		return
	var params: Dictionary = action.get("params", {})
	var discount: int = params.get("discount", 0)
	var floor_val: int = params.get("floor", 1)
	var draw_amount: int = params.get("draw_amount", 0)
	var hand_only: bool = params.get("hand_only", false)

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return

	var hand_weapons: Array = []
	for c in main.player_hand.cards:
		if is_instance_valid(c) and c.get("card_type") == Constants.CardType.ARMA:
			hand_weapons.append(c)
	var cemetery_weapons: Array = []
	if not hand_only:
		for d in CardManager.get_cemetery(controller_id):
			if d.get("tipo") == Constants.CardType.ARMA:
				cemetery_weapons.append(d)
	if hand_weapons.is_empty() and cemetery_weapons.is_empty():
		return

	var card_data_list: Array = []
	for c in hand_weapons:
		card_data_list.append(c.card_data)
	for d in cemetery_weapons:
		card_data_list.append(d)

	# Título corto (2026-08-26, a pedido del usuario — "más visual, menos
	# texto"): el botón Cancelar ya cubre "declinar", no hace falta
	# explicarlo en el título.
	var title: String = "Arma con -%d oro (mín %d), roba %d" % [discount, floor_val, draw_amount]
	if draw_amount <= 0:
		title = "Arma con -%d oro (mín %d)" % [discount, floor_val]
	var picked_data: Dictionary = await SelectionManager.await_single_pick(card_data_list, title, true, 0)
	if picked_data.is_empty():
		return

	# Portador ANTES de tocar el origen del Arma (mismo orden que GoldManager.play_card)
	var ally = await main._gold_manager._select_weapon_wielder()
	if not ally or not is_instance_valid(ally):
		return

	var weapon_node: Node = null
	var from_hand := false
	for c in hand_weapons:
		if is_instance_valid(c) and c.card_data == picked_data:
			weapon_node = c
			from_hand = true
			break
	if not weapon_node:
		weapon_node = main._create_card(picked_data, false)
		main._connect_card_signals(weapon_node)

	var applies_to_this_weapon := func(c: Node) -> bool:
		return c == weapon_node
	PaymentManager.agregar_modificador_coste(weapon_node, -discount, applies_to_this_weapon, floor_val <= 0)
	var coste_real: int = PaymentManager.calcular_coste_real(weapon_node)
	var puede_pagar: bool = PaymentManager.puede_jugar_carta(weapon_node, controller_id)
	PaymentManager.remover_modificador_coste(weapon_node)

	if not puede_pagar:
		main._update_debug("No puedes pagar el Arma con descuento (%d Oro)" % coste_real)
		if not from_hand:
			weapon_node.queue_free()
		return

	if await TriggerSystem.open_response_window(card, str(card.get("card_name")) if card else "Lobo Sagrado", controller_id):
		if not from_hand:
			weapon_node.queue_free()
		return

	if from_hand:
		var idx = main.player_hand.cards.find(weapon_node)
		if idx >= 0:
			main.player_hand.cards.remove_at(idx)
		if weapon_node.get_parent() == main.player_hand:
			main.player_hand.remove_child(weapon_node)
	else:
		var cemetery: Array = CardManager.get_cemetery(controller_id)
		var cidx: int = cemetery.find(picked_data)
		if cidx >= 0:
			CardManager.remove_from_cemetery(controller_id, cidx)

	if coste_real > 0:
		var weapon_race: String = str(weapon_node.get("card_raza")) if weapon_node.get("card_raza") != null else ""
		await main._gold_manager.pagar_coste(coste_real, weapon_node.card_type, weapon_race, weapon_node.card_cost)
		PaymentManager.registrar_pago(coste_real)

	await main._gold_manager._equip_weapon(weapon_node, ally)

	if draw_amount > 0:
		await ActionModule.draw(controller_id, draw_amount, "etb_trigger", true)


func _execute_return_weapon_swap_free(controller_id: int, card: Node = null) -> void:
	"""'Puedes subir un Arma que controles a la mano de su dueño para jugar
	un Arma del mismo o menor coste desde tu mano sin pagar su coste'
	(Padre de la Patria, 2026-08-28). Dos elecciones encadenadas: primero
	qué Arma equipada devolver, después qué Arma de la mano (coste ≤ la
	devuelta) jugar gratis con play_card_for_free() — mismo camino final
	que usan los patrones de LookAndPlayResolver."""
	if controller_id != 0:
		return
	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return

	var equipped_weapons: Array = []
	for field in [main.player_field, main.player_linea_ataque]:
		if not field:
			continue
		for ally in field.get_children():
			if not is_instance_valid(ally):
				continue
			var weapons = ally.get("equipped_weapons")
			if weapons is Array:
				for w in weapons:
					if is_instance_valid(w):
						equipped_weapons.append(w)
	if equipped_weapons.is_empty():
		return

	# Hace falta un Arma YA en la mano para que la habilidad tenga algo que
	# jugar gratis — sin esto no vale la pena ni ofrecer el "puedes"
	# (2026-08-28, a pedido del usuario, mismo criterio que Lobo Sagrado).
	var hand_weapons: Array = []
	for c in main.player_hand.cards:
		if is_instance_valid(c) and c.get("card_type") == Constants.CardType.ARMA:
			hand_weapons.append(c)
	if hand_weapons.is_empty():
		return

	# 1) Elegir qué Arma equipada devolver.
	var return_candidates: Array = equipped_weapons.map(func(w): return w.card_data)
	var picked1: Dictionary = await SelectionManager.await_single_pick(
		return_candidates, "Sube un Arma que controles a la mano de su dueño", true, 0)
	if picked1.is_empty():
		return

	var weapon_to_return: Node = null
	for w in equipped_weapons:
		if is_instance_valid(w) and w.card_data == picked1:
			weapon_to_return = w
			break
	if not weapon_to_return:
		return

	# get_modified_cost(), no card_cost crudo (2026-09-04) — weapon_to_return
	# está EN JUEGO en este punto (recién se devuelve a la mano en la línea
	# de abajo), así que puede tener el coste reducido de forma continua
	# (p.ej. Samael).
	var returned_cost: int = ContinuousEffectManager.get_modified_cost(weapon_to_return)
	_return_equipped_weapon_to_hand(weapon_to_return, main)

	# 2) Elegir qué Arma de la mano (coste ≤ la devuelta) jugar gratis. Debe
	# ser OTRA Arma, distinta de la que se acaba de devolver (2026-08-30, a
	# pedido del usuario) — weapon_to_return ya quedó insertada en
	# main.player_hand.cards por _return_equipped_weapon_to_hand() (línea de
	# arriba), así que sin esta exclusión aparecía como su propio candidato
	# válido (cualquier carta cumple costo ≤ su propio costo).
	var eligible_hand: Array = []
	for c in main.player_hand.cards:
		if is_instance_valid(c) and c != weapon_to_return and c.get("card_type") == Constants.CardType.ARMA and int(c.card_cost) <= returned_cost:
			eligible_hand.append(c)
	if eligible_hand.is_empty():
		main._update_debug("No tienes otra Arma de coste %d o menos en la mano" % returned_cost)
		return

	var eligible_data: Array = eligible_hand.map(func(c): return c.card_data)
	var picked2: Dictionary = await SelectionManager.await_single_pick(
		eligible_data, "Juega un Arma de coste %d o menos gratis" % returned_cost, true, 0)
	if picked2.is_empty():
		return

	# El costo (subir el Arma equipada a la mano) ya se pagó arriba — la
	# ventana va acá, antes de jugar la nueva gratis (el efecto en sí).
	if await TriggerSystem.open_response_window(card, str(card.get("card_name")) if card else "Padre de la Patria", controller_id):
		return
	await main._gold_manager.play_card_for_free(picked2)


func _return_equipped_weapon_to_hand(weapon: Node, main: Node) -> void:
	"""Desequipa 'weapon' de su Aliado portador y la manda a la mano —
	inserción directa (no player_hand.add_card()): _equip_weapon() nunca
	desconectó las señales card_hovered/card_clicked de HandManager al
	sacarla de la mano para equiparla (bypasea remove_card(), que sí las
	desconecta), así que siguen conectadas — add_card() volvería a
	conectarlas y Godot tira un error de 'señal ya conectada'."""
	var ally = weapon.get_parent()
	if ally and ally.get("equipped_weapons") is Array:
		ally.equipped_weapons.erase(weapon)
	if ally:
		ally.remove_child(weapon)
	weapon.can_interact = true
	weapon.set_zone(Constants.Zone.MANO)
	main.player_hand.cards.append(weapon)
	main.player_hand.add_child(weapon)
	main.player_hand._arrange_cards()
