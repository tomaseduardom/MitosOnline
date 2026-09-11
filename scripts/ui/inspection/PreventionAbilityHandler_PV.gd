extends RefCounted
## PreventionAbilityHandler_PV — Mitad P-V (alfabético por nombre de carta) de
## PreventionAbilityHandler.gd, dividido por tamaño (2026-09-06, "módulos
## gordos" — mismo corte que ya separó SearchAbilityHandler_AI.gd/
## SearchAbilityHandler_JV.gd del propio SearchAbilityHandler.gd). Ver
## PreventionAbilityHandler.gd para el facade que reune esta parte con
## PreventionAbilityHandler_AE.gd y PreventionAbilityHandler_EP.gd bajo los
## mismos nombres públicos que antes — CardInspectionLayer.gd no cambió una
## sola línea por este split. Opera sobre CardInspectionLayer via _inspector
## (y sobre el Main del juego via _inspector._main).

var _inspector: CardInspectionLayer


func setup(inspector: CardInspectionLayer) -> void:
	_inspector = inspector


func _activate_perla_de_sangre_convert_barajar_desterrar_draw(source_card: Node, ability: Dictionary) -> void:
	"""'Puedes convertirlo en un Oro sin habilidad para Barajar y/o
	Desterrar hasta cuatro cartas de los Cementerios y Robar hasta dos
	cartas' (Perla de Sangre, 2026-09-04). Costo: convertirse (is_converted
	+ silenciarse permanentemente, mismo molde que Capitán O'Brien).
	Efecto: reusa GoldManager._resolve_armeria_barajar_desterrar(4) +
	Roba hasta 2 (ActionModule.draw ya maneja un mazo con menos cartas
	disponibles sin problema)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0:
		return
	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	source_card.is_converted = true
	await KeywordManager.silence_card(source_card, source_card, "permanent")
	if await TriggerSystem.open_response_window(source_card, "Perla de Sangre", owner_id):
		return
	await main._gold_manager._resolve_armeria_barajar_desterrar(4, "Perla de Sangre")
	await ActionModule.draw(owner_id, 2, "activated_ability", true)


func _activate_perla_de_sangre_search_hand_or_play(source_card: Node, ability: Dictionary) -> void:
	"""'En tu Vigilia, una vez por turno, puedes pagarlo para buscar en tu
	Castillo un Aliado y ponerlo en tu mano o jugarlo reduciendo su coste
	en un Oro, hasta un mínimo de 1' (Perla de Sangre, 2026-09-04). Costo:
	gastar este Oro (GoldManager._mover_oro_a_pagado()). Efecto: buscar un
	Aliado en el Castillo y elegir entre ponerlo en la mano o jugarlo con
	-1 Oro (piso 1, allow_zero=false — el texto NO dice 'hasta un mínimo
	de 0')."""
	if not is_instance_valid(source_card) or not _inspector._main._gold_manager:
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0:
		return
	if source_card.get("current_zone") != Constants.Zone.RESERVA_ORO:
		main._update_debug("%s ya no está en tu Reserva" % str(source_card.get("card_name")))
		return

	var deck: Array = CardManager.get_deck(owner_id)
	var candidates: Array = deck.filter(func(d): return d.get("tipo", -1) == Constants.CardType.ALIADO)
	if candidates.is_empty():
		main._update_debug("No tienes ningún Aliado en tu Castillo")
		return
	var picked_data: Dictionary = await SelectionManager.await_single_pick(
		candidates, "Elige un Aliado de tu Castillo", false)
	if picked_data.is_empty():
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	await main._gold_manager._mover_oro_a_pagado(source_card)
	# Ventana única para todo lo que sigue (2026-09-10): la rama "jugarlo" ya
	# queda cubierta por play_card() más abajo (CARD_PLAYED), pero la rama "a
	# la mano" no tiene ninguna cobertura propia — se gatea ACÁ, antes de
	# sacar la carta encontrada del Castillo, para no tener que revertir una
	# búsqueda ya completa si se anula después.
	if await TriggerSystem.open_response_window(source_card, "Perla de Sangre", owner_id):
		return

	var idx: int = deck.find(picked_data)
	if idx >= 0:
		deck.remove_at(idx)
	CardManager.shuffle_deck(owner_id)

	var to_hand: bool = await SelectionManager.await_two_choice(
		main, "Perla de Sangre", "Ponerlo en tu mano", "Jugarlo con 1 Oro de descuento (piso 1)")
	var ally_node = main._create_card(picked_data, false)
	main._connect_card_signals(ally_node)
	if to_hand:
		main.player_hand.add_card(ally_node)
	else:
		main.player_hand.add_card(ally_node)
		var applies_to_this_card := func(c: Node) -> bool:
			return c == ally_node
		PaymentManager.agregar_modificador_coste(ally_node, -1, applies_to_this_card, false)
		await main._gold_manager.play_card(ally_node)


func _activate_piruquina_pay_bottom_deck_prevent(source_card: Node, ability: Dictionary) -> void:
	"""'Si está en tu mano, puedes pagar un Oro y ponerlo en el fondo de tu
	Castillo para reducir a cero el próximo daño a tu Castillo' (Piruquina,
	2026-09-04) — costo: 1 Oro real (PaymentManager). Efecto: ella misma
	va al fondo del Castillo (no al Cementerio) y se registra una
	prevención de daño total, un solo uso (DamageManager.
	add_damage_prevention, amount=-1/one_shot=true)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0 or not main._gold_manager or not main.player_hand:
		return  # el bot no usa esta habilidad todavía
	if not main.player_hand.cards.has(source_card):
		return
	if not main._gold_manager.puede_pagar(1):
		main._update_debug("Oro insuficiente (necesitas 1)")
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	await main._gold_manager.pagar_coste(1)
	# Ventana ANTES de que se vaya al fondo del Castillo (2026-09-10): después
	# de remove_card(..., true) queda inválida para open_response_window().
	if await TriggerSystem.open_response_window(source_card, "Piruquina", owner_id):
		return

	var card_data: Dictionary = source_card.card_data.duplicate()
	main.player_hand.remove_card(source_card, true)
	CardManager.get_deck(owner_id).append(card_data)

	DamageManager.add_damage_prevention(owner_id, -1, -1, true, source_card)


func _activate_quantum_megumi(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, Baraja una carta de tu mano para Barajar hasta
	tres cartas de tu Cementerio y Robar una carta' (Quantum Megumi,
	2026-09-04). Costo: barajar 1 carta CUALQUIERA de la mano al Castillo.
	Efecto: elegir hasta 3 cartas del propio Cementerio para barajar de
	vuelta, y robar 1."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0 or not main.player_hand or main.player_hand.cards.is_empty():
		return  # el bot no usa esta habilidad todavía

	var hand_cards: Array = main.player_hand.cards.duplicate()
	var hand_data_list: Array = []
	for c in hand_cards:
		hand_data_list.append(c.card_data)
	var to_shuffle_data: Dictionary = await SelectionManager.await_single_pick(
		hand_data_list, "Baraja 1 carta de tu mano para barajar tu Cementerio y robar", false)
	if to_shuffle_data.is_empty():
		return
	var hand_node: Node = null
	for c in hand_cards:
		if c.card_data == to_shuffle_data:
			hand_node = c
			break
	if not hand_node:
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	main.player_hand.remove_card(hand_node, true)
	CardManager.get_deck(owner_id).append(to_shuffle_data)
	CardManager.shuffle_deck(owner_id)

	var cemetery: Array = CardManager.get_cemetery(owner_id)
	if not cemetery.is_empty():
		var result: Dictionary = await SelectionManager.await_multi_pick(
			cemetery.duplicate(), "Elige hasta 3 cartas de tu Cementerio para barajar", mini(3, cemetery.size()), 0, true)
		if await TriggerSystem.open_response_window(source_card, "Quantum Megumi", owner_id):
			return
		var shuffled := 0
		for picked_data in result.get("picked", []):
			var idx: int = cemetery.find(picked_data)
			if idx >= 0:
				CardManager.remove_from_cemetery(owner_id, idx)
				CardManager.get_deck(owner_id).append(picked_data)
				shuffled += 1
		if shuffled > 0:
			CardManager.shuffle_deck(owner_id)
		await ActionModule.draw(owner_id, 1, "activated_ability", true)
		return

	# Cementerio vacío: sin declare adicional, la ventana cubre solo el Robo.
	if await TriggerSystem.open_response_window(source_card, "Quantum Megumi", owner_id):
		return
	await ActionModule.draw(owner_id, 1, "activated_ability", true)


func _activate_quimera_voragh_banish_annul_talisman_draw(source_card: Node, ability: Dictionary) -> void:
	"""'Puedes Desterrarlo para Anular un Talismán de coste 1 o menos y
	Roba una carta' (quimera voragh, 2026-09-06) — mismo molde que akari
	(auto-Destierro como costo + Anular ~ destruir un objetivo de coste
	efectivo ≤1), acá el objetivo es un Talismán específicamente y se suma
	un Robo al final. Los Talismanes se resuelven y van al Cementerio de
	inmediato (DAR Sección 8), así que 'un Talismán' en juego solo tiene
	sentido durante su propia ventana de resolución — en la práctica el
	objetivo real disponible normalmente es uno YA en el Cementerio/
	Destierro esperando Exhumar, pero el texto no lo dice explícito, así
	que el filtro busca en las mismas zonas de campo que el resto de estos
	patrones por consistencia."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0 or not main._card_interaction:
		return  # el bot no usa esta habilidad todavía

	var filter := func(c: Node) -> bool:
		if c.get("card_type") != Constants.CardType.TALISMAN:
			return false
		var parent = c.get_parent()
		var valid_zones = [main.player_field, main.player_linea_apoyo,
			main.opponent_field, main.opponent_linea_apoyo]
		if parent not in valid_zones:
			return false
		return ContinuousEffectManager.get_modified_cost(c) <= 1
	var target: Node = await main._card_interaction.await_target("Elige un Talismán de coste 1 o menos para anular", filter)
	if not target or not is_instance_valid(target):
		return
	# Ventana ANTES del autodestierro (2026-09-10): el Robo de más abajo no
	# tiene cobertura propia, y después de banish() source_card ya no sirve
	# como referencia válida para open_response_window().
	if await TriggerSystem.open_response_window(source_card, "quimera voragh", owner_id):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	await ActionModule.banish([source_card], source_card, true)

	if TriggerSystem._targeted_executor._target_text_denies(target, ["no puede ser anulad"]):
		main._update_debug("%s no puede ser anulada" % str(target.get("card_name")))
	else:
		await ActionModule.destroy([target], source_card, true, true)
	await ActionModule.draw(owner_id, 1, "activated_ability", true)


func _activate_sake(source_card: Node, ability: Dictionary) -> void:
	"""'En tu Vigilia, una vez por turno, si no controlas más Oros que tu
	oponente, puedes pagar un Oro para poner un Oro en juego desde tu mano
	o Cementerio' (Sake, 2026-09-04). Condición: tu total de Oros
	(Reserva+Oro Pagado) <= el del oponente. Costo: pagar 1 Oro. Efecto:
	elegir un Oro de tu mano o Cementerio y ponerlo directo en tu Reserva
	(GoldManager.put_gold_directly_in_reserva() — DAR 'poner en juego', no
	'jugar', ver [[reference_myl_external_api]] y la conversación con el
	usuario 2026-09-04 sobre 'jugar' vs 'poner en juego').

	'Tu oponente debe pagar un Oro adicional para afectar a tus demás
	Oros' queda SIN implementar: sería un impuesto sobre AFECTAR (targeting
	de un efecto ajeno), no sobre JUGAR — un tipo de restricción que este
	motor no modela todavía (los impuestos existentes, Bernardo O'Higgins/
	Fuente de la Juventud, son siempre sobre jugar/usar una habilidad
	propia, nunca sobre que el rival te apunte)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía

	var my_gold: HBoxContainer = main.player_gold if owner_id == 0 else main.opponent_gold
	var my_pagado: HBoxContainer = main.player_oro_pagado if owner_id == 0 else main.opponent_oro_pagado
	var opp_gold: HBoxContainer = main.opponent_gold if owner_id == 0 else main.player_gold
	var opp_pagado: HBoxContainer = main.opponent_oro_pagado if owner_id == 0 else main.player_oro_pagado
	var my_oros: int = my_gold.get_child_count() + my_pagado.get_child_count()
	var opp_oros: int = opp_gold.get_child_count() + opp_pagado.get_child_count()
	if my_oros > opp_oros:
		main._update_debug("Sake: solo se puede usar si no controlas más Oros que tu oponente")
		return
	if not main._gold_manager.puede_pagar(1):
		main._update_debug("Necesitas 1 Oro disponible para esta habilidad")
		return

	var candidates: Array = []
	for c in main.player_hand.cards:
		if is_instance_valid(c) and c.get("card_type") == Constants.CardType.ORO:
			candidates.append({"data": c.card_data, "from_hand": true, "node": c})
	for d in CardManager.get_cemetery(owner_id):
		if d.get("tipo", -1) == Constants.CardType.ORO:
			candidates.append({"data": d, "from_hand": false, "node": null})
	if candidates.is_empty():
		main._update_debug("No tienes ningún Oro en tu mano o Cementerio")
		return

	var display_data: Array = []
	for c in candidates:
		display_data.append(c.data)
	var picked_data: Dictionary = await SelectionManager.await_single_pick(
		display_data, "Elige un Oro de tu mano o Cementerio para poner en juego", false)
	if picked_data.is_empty():
		return
	var chosen: Dictionary = {}
	for c in candidates:
		if c.data == picked_data:
			chosen = c
			break
	if chosen.is_empty():
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	await main._gold_manager.pagar_coste(1)
	PaymentManager.registrar_pago(1)

	if chosen.from_hand:
		main.player_hand.remove_card(chosen.node, true)
	else:
		var idx: int = CardManager.get_cemetery(owner_id).find(chosen.data)
		if idx >= 0:
			CardManager.remove_from_cemetery(owner_id, idx)

	await main._gold_manager.put_gold_directly_in_reserva(owner_id, chosen.data)


func _activate_shub_niggurath_gold_for_totem_draw(source_card: Node, ability: Dictionary) -> void:
	"""'En tu Vigilia, una vez por turno, puedes generar un Oro para jugar
	un Tótem de coste 2 o más y Robar una carta' (Shub-Niggurath,
	2026-09-04)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0 or not main._gold_manager:
		return  # el bot no usa esta habilidad todavía

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	if await TriggerSystem.open_response_window(source_card, "Shub-Niggurath", owner_id):
		return
	var predicate := func(card_type: int, _card_race: String, card_cost: int) -> bool:
		return card_type == Constants.CardType.TOTEM and card_cost >= 2
	main._gold_manager.generar_oro_virtual_restringido(1, predicate, "Tótem de coste 2 o más")
	await ActionModule.draw(owner_id, 1, "activated_ability", true)


func _activate_shub_niggurath_shuffle_or_mill_opponent(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez en tu turno, Baraja una carta de coste 3 o menos o tu
	oponente Bota dos cartas por cada Aliado y/o Tótem que controles'
	(Shub-Niggurath, 2026-09-04) — elección A/B."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0 or not main._card_interaction:
		return  # el bot no usa esta habilidad todavía

	var choose_shuffle: bool = await SelectionManager.await_two_choice(
		main, "Shub-Niggurath", "Barajar una carta de coste 3 o menos", "Tu oponente Bota cartas")

	if choose_shuffle:
		var filter := func(c: Node) -> bool:
			var parent = c.get_parent()
			var valid_zones = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
				main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]
			if parent not in valid_zones:
				return false
			return ContinuousEffectManager.get_modified_cost(c) <= 3
		var target: Node = await main._card_interaction.await_target("Elige una carta de coste 3 o menos para barajar", filter)
		if not target or not is_instance_valid(target):
			return
		UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
		var target_owner: int = target.controller_id if target.get("controller_id") != null else owner_id
		if await ActionModule.return_to_deck(target, target_owner, true, source_card):
			CardManager.shuffle_deck(target_owner)
	else:
		UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
		var count: int = 0
		for field in [main.player_field, main.player_linea_ataque, main.player_linea_apoyo]:
			if not field:
				continue
			for c in field.get_children():
				if c.get("card_type") in [Constants.CardType.ALIADO, Constants.CardType.TOTEM]:
					count += 1
		var mill_amount: int = count * 2
		if mill_amount > 0 and not await TriggerSystem.open_response_window(source_card, "Shub-Niggurath", owner_id):
			await ActionModule.mill(1 - owner_id, mill_amount, false, "activated_ability", true)


func _activate_skofnung_shuffle_self_search_gold(source_card: Node, ability: Dictionary) -> void:
	"""'Puedes Barajarla de tu mano para buscar un Oro en tu Castillo y
	ponerlo en tu mano' (skofnung, 2026-09-04) — costo: ella misma vuelve
	al mazo (barajada) desde la mano."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0 or not main.player_hand or not main.player_hand.cards.has(source_card):
		return  # el bot no usa esta habilidad todavía

	# Ventana ANTES del autobarajado (2026-09-10): sin esto, source_card queda
	# inválida (remove_card(..., true)) para cuando haría falta abrirla.
	if await TriggerSystem.open_response_window(source_card, "skofnung", owner_id):
		return
	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	var card_data: Dictionary = source_card.card_data.duplicate()
	main.player_hand.remove_card(source_card, true)
	CardManager.get_deck(owner_id).append(card_data)
	CardManager.shuffle_deck(owner_id)
	await ActionModule.search(owner_id, Constants.Zone.CASTILLO, {"type": Constants.CardType.ORO}, 1, true, false, false, null, Constants.Zone.MANO)


func _activate_sumi_discard_grant_exhumar(source_card: Node, ability: Dictionary) -> void:
	"""'Puedes Descartarlo de tu mano para que una carta de coste 1 en tu
	Cementerio gane Exhumar por el turno' (sumi el terrible, 2026-09-04) —
	habilidad usable desde la MANO (esta carta se descarta a sí misma como
	costo). Exhumar temporal: se agrega al array 'keywords' del propio
	Dictionary de datos en el Cementerio (ExhumarSystem._card_has_exhumar()
	ya lo detecta ahí) y se saca al terminar el turno."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía

	var own_cemetery: Array = CardManager.get_cemetery(owner_id)
	var eligible: Array = own_cemetery.filter(func(d): return int(d.get("coste", -1)) == 1)
	if eligible.is_empty():
		main._update_debug("No hay ninguna carta de coste 1 en tu Cementerio")
		return
	var picked_data: Dictionary = await SelectionManager.await_single_pick(
		eligible, "Elige una carta de coste 1 en tu Cementerio para que gane Exhumar por el turno")
	if picked_data.is_empty():
		return
	# Ventana ANTES del autodescarte (2026-09-10): después de discard(),
	# source_card queda inválida para open_response_window().
	if await TriggerSystem.open_response_window(source_card, "sumi el terrible", owner_id):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	if main.player_hand and main.player_hand.cards.has(source_card):
		await ActionModule.discard(owner_id, [source_card], "activated_ability", true)

	var keywords: Array = picked_data.get("keywords", []).duplicate()
	if Constants.Keyword.EXHUMAR not in keywords and "EXHUMAR" not in keywords:
		keywords.append(Constants.Keyword.EXHUMAR)
	picked_data["keywords"] = keywords
	var clear_it: Callable
	clear_it = func(started_player_id: int, _turn: int) -> void:
		if started_player_id != owner_id:
			return
		var current_keywords: Array = picked_data.get("keywords", [])
		current_keywords = current_keywords.filter(func(k): return k != Constants.Keyword.EXHUMAR and k != "EXHUMAR")
		picked_data["keywords"] = current_keywords
		if GameManager.turn_started.is_connected(clear_it):
			GameManager.turn_started.disconnect(clear_it)
	GameManager.turn_started.connect(clear_it)
	if PaymentManager.get("_exhumar") and PaymentManager._exhumar.has_method("invalidate_cache"):
		PaymentManager._exhumar.invalidate_cache()


func _activate_torre_babel_shuffle_hand_for_cemeteries_draw(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, puedes Barajar una carta de tu mano para
	Barajar y/o Desterrar hasta cinco cartas de los Cementerios y Robar
	dos cartas' (Torre de Babel, 2026-09-04)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0 or not main.player_hand or main.player_hand.cards.is_empty():
		return  # el bot no usa esta habilidad todavía

	var hand_cards: Array = main.player_hand.cards.duplicate()
	var card_data_list: Array = []
	for c in hand_cards:
		card_data_list.append(c.card_data)
	var picked: Dictionary = await SelectionManager.await_single_pick(
		card_data_list, "Baraja 1 carta de tu mano")
	if picked.is_empty():
		return
	var to_shuffle_node: Node = null
	for c in hand_cards:
		if c.card_data == picked:
			to_shuffle_node = c
			break
	if not to_shuffle_node:
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	var shuffled_data: Dictionary = to_shuffle_node.card_data
	main.player_hand.remove_card(to_shuffle_node, true)
	CardManager.get_deck(owner_id).append(shuffled_data)
	ActionModule.shuffle_deck(owner_id)

	if await TriggerSystem.open_response_window(source_card, "Torre de Babel", owner_id):
		return
	await main._gold_manager._resolve_armeria_barajar_desterrar(5, "Torre de Babel")
	await ActionModule.draw(owner_id, 2, "activated_ability", true)


func _activate_totem_dragon_ancestral_shuffle_self_annul_or_cancel(source_card: Node, ability: Dictionary) -> void:
	"""'En tu turno, puedes Barajarlo para Anular un Aliado o cancelar una
	habilidad' (Tótem del Dragón Ancestral, 2026-09-04) — autobarajar
	(vuelve al Castillo del dueño), elección A/B."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0 or not main._card_interaction:
		return  # el bot no usa esta habilidad todavía

	var choose_annul: bool = await SelectionManager.await_two_choice(
		main, str(source_card.get("card_name")), "Anular un Aliado", "Cancelar una habilidad")

	var target: Node = null
	if choose_annul:
		var filter := func(c: Node) -> bool:
			if c.get("card_type") != Constants.CardType.ALIADO:
				return false
			var parent = c.get_parent()
			var valid_zones = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
				main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]
			return parent in valid_zones
		target = await main._card_interaction.await_target("Elige un Aliado para anular", filter)
	else:
		var filter2 := func(c: Node) -> bool:
			var parent = c.get_parent()
			var valid_zones = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
				main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo,
				main.player_gold, main.opponent_gold]
			return parent in valid_zones
		target = await main._card_interaction.await_target("Elige una carta para cancelar su habilidad", filter2)
	if not target or not is_instance_valid(target):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	var self_owner: int = owner_id
	if await ActionModule.return_to_deck(source_card, self_owner, true, source_card):
		CardManager.shuffle_deck(self_owner)

	if choose_annul:
		if TriggerSystem._targeted_executor._target_text_denies(target, ["no puede ser anulad"]):
			main._update_debug("%s no puede ser anulada" % str(target.get("card_name")))
		else:
			await ActionModule.destroy([target], source_card, true, true)
	else:
		if TriggerSystem._targeted_executor._target_text_denies(target, ["no puede perder su habilidad", "no pierde su habilidad"]):
			main._update_debug("%s no pierde su habilidad" % str(target.get("card_name")))
		else:
			await KeywordManager.silence_card(target, source_card, "permanent")


func _activate_uriel_shuffle_banish_draw_discard(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, Baraja y/o Destierra hasta tres cartas de los
	Cementerios, Roba una carta y Destierra una carta de tu mano' (uriel,
	2026-09-04) — reusa GoldManager._resolve_armeria_barajar_desterrar()
	genérica para la primera cláusula, luego Roba 1 y Destierra 1 de la
	propia mano (elegida por el jugador)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	if await TriggerSystem.open_response_window(source_card, "uriel", owner_id):
		return
	await main._gold_manager._resolve_armeria_barajar_desterrar(3, "uriel")
	await ActionModule.draw(owner_id, 1, "activated_ability", true)

	if main.player_hand and not main.player_hand.cards.is_empty():
		var hand_cards: Array = main.player_hand.cards.duplicate()
		var card_data_list: Array = []
		for c in hand_cards:
			card_data_list.append(c.card_data)
		var picked: Dictionary = await SelectionManager.await_single_pick(
			card_data_list, "Destierra 1 carta de tu mano", false)
		if not picked.is_empty():
			var to_exile_node: Node = null
			for c in hand_cards:
				if c.card_data == picked:
					to_exile_node = c
					break
			if to_exile_node:
				# Destierra desde la MANO (no en juego): banish() asume una
				# carta en juego y no actualiza la bookkeeping de player_hand
				# (mismo motivo documentado en HandManager.remove_card() vs
				# remove_child()+queue_free() manual) — se saca de la mano
				# primero y se agregan sus datos al Destierro a mano.
				var exile_data: Dictionary = to_exile_node.card_data.duplicate()
				main.player_hand.remove_card(to_exile_node, true)
				CardManager.add_to_exile(owner_id, exile_data)


func _activate_vision_heroica_pay_raise_draw(source_card: Node, ability: Dictionary) -> void:
	"""'Puedes pagar un Oro para subir esta carta de tu Cementerio a tu
	mano y Robar una carta' (vision heroica, 2026-09-06) — usable desde el
	Cementerio."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0 or not main._gold_manager:
		return  # el bot no usa esta habilidad todavía
	if not main._gold_manager.puede_pagar(1):
		main._update_debug("Oro insuficiente (necesitas 1)")
		return

	var own_cemetery: Array = CardManager.get_cemetery(owner_id)
	var card_data: Dictionary = source_card.card_data
	var idx: int = own_cemetery.find(card_data)
	if idx < 0:
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	await main._gold_manager.pagar_coste(1)
	if await TriggerSystem.open_response_window(source_card, "vision heroica", owner_id):
		return
	CardManager.remove_from_cemetery(owner_id, idx)
	var card_node = main._create_card(card_data, false)
	main.player_hand.add_card(card_node)
	main._connect_card_signals(card_node)
	await ActionModule.draw(owner_id, 1, "activated_ability", true)
