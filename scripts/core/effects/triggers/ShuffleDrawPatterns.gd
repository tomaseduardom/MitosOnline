extends RefCounted
## ShuffleDrawPatterns — 4 de 7 mitades de LookAndPlayResolver.gd, dividido por
## tamaño el 2026-09-06 ("módulos gordos"). Cubre combos de Barajar/Robar sobre
## recursos propios (sin apuntar al oponente): Caín (x2), vision heroica, el
## caleuche, manuel rodriguez (ataca solo), amazona desafiante, Abrazo de
## Maipú, Príncipe Orión, blanca nieves, kaitai, rafael, Escarapela Nacional,
## Tótem del Dragón Ancestral. Llamada solo desde LookAndPlayResolver.gd
## (facade) — ver ese archivo para la lista completa de las 7 mitades
## hermanas.

var _main: Node


func setup(main: Node) -> void:
	_main = main


func try_execute_shuffle_or_draw_choice_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'Baraja hasta una carta de coste 2 o menos o Roba dos cartas' (Caín,
	myl_id cbg001, edición Angeles y Demonios: Vigilantes). Elección A/B
	entre dos efectos que no comparten nada — ActionPipeline solo resuelve
	un tipo de acción por habilidad. 'Baraja... de coste N o menos' sin
	zona ni posesivo = EN JUEGO, cualquier lado
	([[project_no_zone_means_in_play]]), 'hasta una' = opcional (ESC =
	no barajar ninguna, pero la elección A/B en sí ya se hizo)."""
	var lower := ability_text.to_lower()
	if not ("baraja hasta una carta de coste" in lower and "o roba dos cartas" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return true

	var choose_shuffle: bool = await SelectionManager.await_two_choice(
		main, "Caín", "Barajar hasta una carta en juego (coste 2 o menos)", "Robar dos cartas")

	if not choose_shuffle:
		if await TriggerSystem.open_response_window(card, "Caín", controller_id):
			return true
		await ActionModule.draw(controller_id, 2, "etb_trigger", true)
		return true

	if not main._card_interaction:
		return true
	var filter := func(c: Node) -> bool:
		if c.get("card_cost") == null or ContinuousEffectManager.get_modified_cost(c) > 2:
			return false
		var parent = c.get_parent()
		var valid_zones = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
			main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]
		return parent in valid_zones
	var target: Node = await main._card_interaction.await_target(
		"Baraja hasta una carta en juego (coste 2 o menos) — ESC para no barajar ninguna", filter)
	# Sin ventana genérica acá: return_to_deck() ya consulta Prevención adentro.
	if target and is_instance_valid(target):
		var owner: int = target.owner_id if target.get("owner_id") != null else controller_id
		await ActionModule.return_to_deck(target, owner, true)
		CardManager.shuffle_deck(owner)
	return true




func try_execute_cain_damage_shuffle_search_pattern(isolated_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando haga daño de combate, puedes Barajalo para buscar dos
	Aliados de coste 2 o menos en tu Castillo. Juega uno sin pagar su
	coste y pon el otro en tu mano.' (Caín). 'Puedes X (barajar a Caín
	mismo) para Y (buscar)' es atómico (project_puedes_x_para_y_atomic):
	no se ofrece la barajada si no hay al menos un Aliado de coste 2 o
	menos en el Castillo para encontrar. Si se encuentran 2, el jugador
	elige cuál de las dos se juega gratis (la otra va a la mano); si solo
	se encuentra 1, elige entre jugarla gratis o mandarla a la mano."""
	var lower := isolated_text.to_lower()
	if not ("puedes barajalo" in lower and "buscar dos aliados de coste" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _main.get_node_or_null("/root/Main")
	if not main or not is_instance_valid(card):
		return true

	var deck: Array = CardManager.get_deck(controller_id)
	var matching: Array = []
	for d in deck:
		if d.get("tipo", -1) == Constants.CardType.ALIADO and int(d.get("coste", 99)) <= 2:
			matching.append(d)
	if matching.is_empty():
		return true  # nada que buscar — la barajada ni se ofrece (atómico)

	var confirm: bool = await SelectionManager.await_two_choice(
		main, "Caín", "Barajarlo para buscar hasta 2 Aliados de coste 2 o menos", "No hacer nada")
	if not confirm:
		return true

	var pick_amount: int = mini(2, matching.size())
	var result: Dictionary = await SelectionManager.await_multi_pick(
		matching, "Elige hasta 2 Aliados de coste 2 o menos", pick_amount, pick_amount, false)
	var found: Array = result.get("picked", [])
	if found.is_empty():
		return true

	# Barajar a Caín mismo AHORA (el costo ya se pagó al elegir buscar) —
	# vuelve a su Castillo y se mezcla.
	await ActionModule.return_to_deck(card, controller_id, false, card)
	CardManager.shuffle_deck(controller_id)

	for picked_data in found:
		deck.erase(picked_data)

	var to_play_data: Dictionary = {}
	if found.size() == 2:
		to_play_data = await SelectionManager.await_single_pick(
			found, "Elige cuál de las dos jugar sin pagar su coste (la otra va a tu mano)", false)
	else:
		var play_it: bool = await SelectionManager.await_two_choice(
			main, "Caín", "Jugarla sin pagar su coste", "Ponerla en tu mano")
		if play_it:
			to_play_data = found[0]

	if await TriggerSystem.open_response_window(card, str(card.get("card_name")), controller_id):
		return true
	for picked_data in found:
		if picked_data == to_play_data:
			await main._gold_manager.play_card_for_free(picked_data)
		else:
			var hand_node = main._create_card(picked_data, false)
			main.player_hand.add_card(hand_node)
			main._connect_card_signals(hand_node)

	if main.get("_zone_manager"):
		main._zone_manager._update_castillo_counts()
	return true




func try_execute_shuffle_cost_max_three_pattern(ability_text: String, controller_id: int) -> bool:
	"""'Baraja una carta de coste 3 o menos o Anula un Talismán oponente'
	(vision heroica, 2026-09-06) — SOLO la primera rama ('Anula un
	Talismán oponente' es contramagia real de pila, no implementada); no
	se ofrece elección, siempre Baraja."""
	var lower := ability_text.to_lower()
	if not ("baraja una carta de coste 3 o menos o anula un talismán oponente" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._card_interaction:
		return true
	var filter := func(c: Node) -> bool:
		var parent = c.get_parent()
		var valid_zones = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
			main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]
		if parent not in valid_zones:
			return false
		return ContinuousEffectManager.get_modified_cost(c) <= 3
	var target: Node = await main._card_interaction.await_target("Elige una carta de coste 3 o menos para barajar", filter)
	if target and is_instance_valid(target):
		var target_owner: int = target.controller_id if target.get("controller_id") != null else controller_id
		if await ActionModule.return_to_deck(target, target_owner, true):
			CardManager.shuffle_deck(target_owner)
	return true




func try_execute_shuffle_cost_max_two_draw_two_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'Elige un efecto: - En respuesta a que se juegue una carta sin pagar
	su coste... - Baraja una carta de coste 2 o menos y Roba dos cartas'
	(el caleuche, 2026-09-06) — SOLO se implementa la segunda rama (la
	primera depende de la ventana de respuesta reactiva, que no existe);
	no se ofrece elección, se resuelve siempre como la rama B."""
	var lower := ability_text.to_lower()
	if not ("baraja una carta de coste 2 o menos y roba dos cartas" in lower and "en respuesta a que se juegue una carta sin pagar su coste" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._card_interaction:
		return true
	var filter := func(c: Node) -> bool:
		var parent = c.get_parent()
		var valid_zones = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
			main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]
		if parent not in valid_zones:
			return false
		return ContinuousEffectManager.get_modified_cost(c) <= 2
	var target: Node = await main._card_interaction.await_target("Elige una carta de coste 2 o menos para barajar", filter)
	if await TriggerSystem.open_response_window(card, "el caleuche", controller_id):
		return true
	if target and is_instance_valid(target):
		var target_owner: int = target.controller_id if target.get("controller_id") != null else controller_id
		if await ActionModule.return_to_deck(target, target_owner, true):
			CardManager.shuffle_deck(target_owner)
	await ActionModule.draw(controller_id, 2, "etb_trigger", true)
	return true




func try_execute_attacks_alone_draw_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'Cuando ataque solo, Roba una carta...' (manuel rodriguez, 2026-09-04)
	— condición 'ataca solo' (único atacante declarado este combate), sin
	precedente en el motor. Solo cubre el Robo; la sobretasa 'a tu
	oponente le cuesta un Oro adicional afectar a tus Aliados' queda fuera
	(demasiado ambigua qué cuenta como 'afectar' para modelarla ahora)."""
	var lower := ability_text.to_lower()
	if not ("cuando ataque solo" in lower and "roba una carta" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía
	if GameManager.attackers.size() != 1:
		return true  # condición 'solo' no cumplida
	if await TriggerSystem.open_response_window(card, "manuel rodriguez", controller_id):
		return true
	await ActionModule.draw(controller_id, 1, "on_attack_trigger", true)
	return true




func try_execute_shuffle_one_in_play_and_four_cemetery_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'Cuando entra en juego o en tu Fase Final, Baraja hasta una carta de
	coste 2 o menos y hasta cuatro cartas de los Cementerios' (amazona
	desafiante, 2026-09-06) — solo la parte de ETB; el repetir esto TODAS
	las Fases Finales (no solo la primera vez) no está implementado (no
	hay un trigger recurrente de Aliado para Fase Final todavía, solo el
	de un uso de EffectController.schedule_next_final_phase_effect())."""
	var lower := ability_text.to_lower()
	if not ("baraja hasta una carta de coste 2 o menos y hasta cuatro cartas de los cementerios" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía
	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return true
	if await TriggerSystem.open_response_window(card, "amazona desafiante", controller_id):
		return true

	# Parte 1: hasta una carta EN JUEGO de coste ≤2 (sin zona = en juego).
	var in_play_candidates: Array = []
	for field in [main.player_field, main.opponent_field, main.player_linea_ataque,
			main.opponent_linea_ataque, main.player_linea_apoyo, main.opponent_linea_apoyo,
			main.player_gold, main.opponent_gold]:
		if not field:
			continue
		for c in field.get_children():
			if is_instance_valid(c) and int(ContinuousEffectManager.get_modified_cost(c)) <= 2:
				in_play_candidates.append(c)
	if not in_play_candidates.is_empty():
		var display1: Array = in_play_candidates.map(func(c): return c.card_data)
		var picked1: Dictionary = await SelectionManager.await_single_pick(
			display1, "Elige hasta una carta de coste 2 o menos para Barajar (ESC para omitir)", true, 0)
		if not picked1.is_empty():
			for c in in_play_candidates:
				if c.card_data == picked1 and is_instance_valid(c):
					var owner_id: int = c.owner_id if c.get("owner_id") != null else 0
					var data: Dictionary = c.card_data.duplicate()
					data["esta_oculta"] = true
					var parent = c.get_parent()
					if parent:
						parent.remove_child(c)
					c.queue_free()
					CardManager.get_deck(owner_id).append(data)
					CardManager.shuffle_deck(owner_id)
					break

	# Parte 2: hasta cuatro cartas de los Cementerios (barajar, no desterrar
	# — a diferencia de Ofrendas al Dragón, esta carta no ofrece la opción
	# de Destierro).
	var cemetery_candidates: Array = []
	for owner_id in [0, 1]:
		for d in CardManager.get_cemetery(owner_id):
			cemetery_candidates.append({"data": d, "owner": owner_id})
	if not cemetery_candidates.is_empty():
		var display2: Array = cemetery_candidates.map(func(c): return c.data)
		var result2: Dictionary = await SelectionManager.await_multi_pick(
			display2, "Elige hasta cuatro cartas de los Cementerios para Barajar", 4, 0, true)
		var chosen2: Array = result2.get("picked", [])
		for picked_data in chosen2:
			for c in cemetery_candidates:
				if c.data == picked_data:
					var idx: int = CardManager.get_cemetery(c.owner).find(picked_data)
					if idx >= 0:
						CardManager.remove_from_cemetery(c.owner, idx)
						var data2: Dictionary = picked_data.duplicate()
						data2["esta_oculta"] = true
						CardManager.get_deck(c.owner).append(data2)
						CardManager.shuffle_deck(c.owner)
					break
	return true




func try_execute_shuffle_any_cemetery_or_exile_into_castillo_then_draw_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'Baraja cualquier cantidad de cartas de tu Cementerio y Destierro en
	tu Castillo y Roba tres cartas' (Abrazo de Maipú, 2026-09-04) — 'tu'
	restringe el pool al propio Cementerio+Destierro (a diferencia de 'los
	Cementerios'), cada carta vuelve a SU Castillo (siempre el mismo,
	propio, acá)."""
	var lower := ability_text.to_lower()
	if not ("baraja cualquier cantidad de cartas de tu cementerio y destierro en tu castillo" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía
	if await TriggerSystem.open_response_window(card, "Abrazo de Maipú", controller_id):
		return true

	var cemetery: Array = CardManager.get_cemetery(controller_id)
	var exile: Array = CardManager.get_exile(controller_id)
	var pool: Array = []
	for d in cemetery:
		pool.append({"data": d, "from": "cemetery"})
	for d in exile:
		pool.append({"data": d, "from": "exile"})
	if not pool.is_empty():
		var display_data: Array = []
		for p in pool:
			display_data.append(p.data)
		var result: Dictionary = await SelectionManager.await_multi_pick(
			display_data, "Baraja cualquier cantidad de cartas de tu Cementerio y Destierro en tu Castillo", pool.size(), 0, true)
		for picked_data in result.get("picked", []):
			for p in pool:
				if p.data == picked_data:
					if p.from == "cemetery":
						var idx: int = cemetery.find(picked_data)
						if idx >= 0:
							CardManager.remove_from_cemetery(controller_id, idx)
					else:
						exile.erase(picked_data)
					CardManager.get_deck(controller_id).append(picked_data)
					break
		CardManager.shuffle_deck(controller_id)

	await ActionModule.draw(controller_id, 3, "etb_trigger", true)
	return true




func try_execute_shuffle_banish_four_cemeteries_pattern(ability_text: String, controller_id: int) -> bool:
	"""'Baraja y/o Destierra hasta cuatro cartas de los Cementerios. Si
	Barajaste y/o Desterraste cuatro cartas de distinto tipo, genera un
	Oro por el turno' (Ofrendas al Dragón, 2026-09-04) — solo la primera
	oración; el bono condicionado a 4 tipos distintos NO implementado
	(_resolve_armeria_barajar_desterrar() no informa qué tipos se
	eligieron)."""
	var lower := ability_text.to_lower()
	if not ("baraja y/o destierra hasta cuatro cartas de los cementerios" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía
	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return true
	await main._gold_manager._resolve_armeria_barajar_desterrar(4, "Ofrendas al Dragón")
	return true




func try_execute_shuffle_banish_cemeteries_then_destroy_or_draw_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando entra en juego, Baraja y/o Destierra hasta tres cartas de
	los Cementerios y elige entre Destruir una carta de coste 2 o menos o
	Robar dos cartas' (Tótem del Dragón Ancestral, 2026-09-04)."""
	var lower := ability_text.to_lower()
	if not ("baraja y/o destierra hasta tres cartas de los cementerios y elige entre destruir una carta de coste 2 o menos o robar dos cartas" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager or not main._card_interaction:
		return true
	await main._gold_manager._resolve_armeria_barajar_desterrar(3, str(card.get("card_name")))

	var choose_destroy: bool = await SelectionManager.await_two_choice(
		main, str(card.get("card_name")), "Destruir una carta de coste 2 o menos", "Robar dos cartas")
	if choose_destroy:
		var target: Node = await TriggerSystem._targeted_executor._select_destroy_target_cost_filter(
			"Elige una carta de coste 2 o menos para destruir", 2)
		if target and is_instance_valid(target):
			await ActionModule.destroy([target], card, true, true)
	else:
		if await TriggerSystem.open_response_window(card, str(card.get("card_name")), controller_id):
			return true
		await ActionModule.draw(controller_id, 2, "etb_trigger", true)
	return true




func try_execute_draw_or_raise_cemetery_ally_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'Cuando entra en juego, Roba una carta o sube un Aliado de tu
	Cementerio a tu mano' (Príncipe Orión, 2026-09-04) — elección A/B."""
	var lower := ability_text.to_lower()
	if not ("roba una carta o sube un aliado de tu cementerio a tu mano" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return true
	var choose_draw: bool = await SelectionManager.await_two_choice(
		main, "Príncipe Orión", "Robar una carta", "Subir un Aliado de tu Cementerio a tu mano")
	if await TriggerSystem.open_response_window(card, "Príncipe Orión", controller_id):
		return true
	if choose_draw:
		await ActionModule.draw(controller_id, 1, "etb_trigger", true)
	else:
		var own_cemetery: Array = CardManager.get_cemetery(controller_id)
		var eligible: Array = own_cemetery.filter(func(d): return d.get("tipo", -1) == Constants.CardType.ALIADO)
		if eligible.is_empty():
			return true
		var picked_data: Dictionary = await SelectionManager.await_single_pick(
			eligible, "Sube un Aliado de tu Cementerio a tu mano")
		if picked_data.is_empty():
			return true
		var idx: int = own_cemetery.find(picked_data)
		if idx < 0:
			return true
		CardManager.remove_from_cemetery(controller_id, idx)
		var card_node = main._create_card(picked_data, false)
		main.player_hand.add_card(card_node)
		main._connect_card_signals(card_node)
	return true




func try_execute_shuffle_up_to_one_ally_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando entra en juego, Baraja hasta un Aliado' (blanca nieves,
	2026-09-04) — objetivo opcional (0 o 1), cualquier Aliado en juego."""
	var lower := ability_text.to_lower()
	if not ("cuando entra en juego, baraja hasta un aliado" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._card_interaction:
		return true
	var target: Node = await main._card_interaction.await_target(
		"Elige un Aliado para barajar (opcional)", func(c: Node) -> bool:
			if c.get("card_type") != Constants.CardType.ALIADO:
				return false
			var parent = c.get_parent()
			return parent in [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
				main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo])
	# Sin ventana genérica acá (2026-09-09): return_to_deck() ya consulta
	# Prevención adentro por su cuenta.
	if target and is_instance_valid(target):
		var target_owner: int = target.controller_id if target.get("controller_id") != null else controller_id
		if await ActionModule.return_to_deck(target, target_owner, true, card):
			CardManager.shuffle_deck(target_owner)
	return true




func try_execute_draw_then_discard_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'Roba N carta(s) y Descarta M carta(s)' (2026-09-04, p.ej. kaitai:
	'Cuando entra en juego, Roba tres cartas y Descarta dos cartas') — el
	genérico extract_action() solo reconoce la PRIMERA acción de una
	oración compuesta, así que sin esto el Descarte se perdía siempre."""
	var lower := ability_text.to_lower()
	var rx := RegEx.new()
	rx.compile("roba (\\w+) cartas? y descarta (\\w+) cartas?")
	var m := rx.search(lower)
	if not m:
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var draw_amount: int = UniversalCardParser._parse_amount(m.get_string(1))
	var discard_amount: int = UniversalCardParser._parse_amount(m.get_string(2))
	if await TriggerSystem.open_response_window(card, str(card.get("card_name")) if card else "kaitai", controller_id):
		return true
	if draw_amount > 0:
		await ActionModule.draw(controller_id, draw_amount, "etb_trigger", true)
	if discard_amount > 0:
		var main := _main.get_node_or_null("/root/Main")
		if main and main.player_hand:
			var hand_cards: Array = main.player_hand.cards.duplicate()
			discard_amount = mini(discard_amount, hand_cards.size())
			if discard_amount > 0:
				var to_discard: Array = await _main._targeted_executor._select_hand_cards_for_discard(hand_cards, discard_amount)
				if not to_discard.is_empty():
					await ActionModule.discard(controller_id, to_discard, "etb_trigger", true)
	return true




func try_execute_shuffle_non_gold_or_draw_two_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando entra en juego, Baraja hasta una carta que no sea Oro o Roba
	dos cartas' (rafael, 2026-09-04) — elección A/B; 'hasta una' = el
	Barajar es opcional (cancelar el picker = 0 elegidas)."""
	var lower := ability_text.to_lower()
	if not ("baraja hasta una carta que no sea oro o roba dos cartas" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._card_interaction:
		return true
	var choose_shuffle: bool = await SelectionManager.await_two_choice(
		main, "rafael", "Barajar hasta una carta que no sea Oro", "Robar dos cartas")

	if choose_shuffle:
		var filter := func(c: Node) -> bool:
			if c.get("card_type") == Constants.CardType.ORO:
				return false
			var parent = c.get_parent()
			var valid_zones = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
				main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]
			return parent in valid_zones
		var target: Node = await main._card_interaction.await_target("Elige una carta que no sea Oro para barajar (opcional)", filter)
		# Sin ventana genérica acá (2026-09-09): return_to_deck() ya consulta
		# Prevención adentro por su cuenta.
		if target and is_instance_valid(target):
			var target_owner: int = target.controller_id if target.get("controller_id") != null else controller_id
			if await ActionModule.return_to_deck(target, target_owner, true, card):
				CardManager.shuffle_deck(target_owner)
	elif not await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		await ActionModule.draw(controller_id, 2, "etb_trigger", true)
	return true




func try_execute_draw_or_search_ally_or_gold_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Roba dos cartas o busca un Aliado u Oro en tu Castillo y ponlo en
	tu mano' (2026-09-04, p.ej. Escarapela Nacional) — elección A/B."""
	var lower := ability_text.to_lower()
	if not ("roba dos cartas o busca un aliado u oro en tu castillo" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return true
	var choose_draw: bool = await SelectionManager.await_two_choice(
		main, "Escarapela Nacional", "Robar dos cartas", "Buscar un Aliado u Oro en tu Castillo")
	if await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		return true
	if choose_draw:
		await ActionModule.draw(controller_id, 2, "etb_trigger", true)
	else:
		await ActionModule.search(controller_id, Constants.Zone.CASTILLO,
			{"type": [Constants.CardType.ALIADO, Constants.CardType.ORO]}, 1, true, false, false, card, Constants.Zone.MANO)
	return true




