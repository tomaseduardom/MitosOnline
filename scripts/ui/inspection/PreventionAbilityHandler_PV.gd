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


func _open_cemetery_reveal_popup_oro(main: Node, owner_id: int) -> Dictionary:
	"""Popup liviano (sin oscurecer el resto de la pantalla, mano sigue
	clickeable) mostrando los Oros del Cementerio propio como Nodos
	temporales interactivos — mismo patrón que GoldManagerTax._open_
	cemetery_reveal_popup() (2026-09-13, El Rey y el Verdugo/Shiji, ver
	arquitectura.md §10.17), usado aquí para Sake ('Oro de tu mano o
	Cementerio'). Returns: {popup: CanvasLayer, nodes: Array[Node]}."""
	var own_cemetery: Array = CardManager.get_cemetery(owner_id).filter(func(d): return d.get("tipo", -1) == Constants.CardType.ORO)
	var nodes: Array = []
	if own_cemetery.is_empty():
		return {"popup": null, "nodes": nodes}

	var CardScene = load("res://scenes/cards/Card.tscn")
	var popup := CanvasLayer.new()
	popup.layer = 40
	main.add_child(popup)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	panel.position = Vector2(20, -240)
	var pstyle := StyleBoxFlat.new()
	pstyle.bg_color = Color(0.04, 0.03, 0.06, 0.92)
	pstyle.border_color = Color(0.85, 0.72, 0.28, 0.85)
	pstyle.set_border_width_all(2)
	pstyle.set_corner_radius_all(12)
	pstyle.content_margin_left = 10
	pstyle.content_margin_right = 10
	pstyle.content_margin_top = 8
	pstyle.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", pstyle)
	popup.add_child(panel)
	var vbox := VBoxContainer.new()
	panel.add_child(vbox)
	var lbl := Label.new()
	lbl.text = "Tu Cementerio"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(lbl)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 190)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	scroll.add_child(hbox)

	for data in own_cemetery:
		var wrapper := Control.new()
		wrapper.custom_minimum_size = Vector2(80.0, 112.0)
		var c_node = CardScene.instantiate()
		c_node.load_from_data(data)
		c_node.set_zone(Constants.Zone.CEMENTERIO)
		c_node.owner_id = owner_id
		c_node.controller_id = owner_id
		c_node.can_interact = true
		c_node.drag_enabled = false
		c_node.custom_minimum_size = Vector2(150.0, 210.0)
		c_node.size = Vector2(150.0, 210.0)
		c_node.scale = Vector2(0.533, 0.533)
		c_node.base_scale = Vector2(0.533, 0.533)
		main._connect_card_signals(c_node)
		wrapper.add_child(c_node)
		hbox.add_child(wrapper)
		nodes.append(c_node)

	return {"popup": popup, "nodes": nodes}


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
	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	source_card.is_converted = true
	await KeywordManager.silence_card(source_card, source_card, "permanent")
	if await TriggerSystem.open_response_window(source_card, "Perla de Sangre", owner_id):
		return
	await main._gold_manager._resolve_armeria_barajar_desterrar(4, "Perla de Sangre", owner_id)
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
		# 2026-10-05: a diferencia del resto de este archivo, esta NO se
		# desbloquea — usa SelectionManager.await_single_pick() (modal de
		# lista con Dictionary crudos), un QUINTO tipo de diálogo sin puente
		# de red (no es ninguno de los 4 sistemas de la Fase 3: no es open_
		# selection/open_search, ni await_choice/await_two_choice, ni el
		# picker de Zonas, ni CardInteractionModule) — se deja documentado
		# como gap nuevo en vez de intentar un bridge improvisado sin probar.
		return  # el Remoto no puede usar esta habilidad todavía
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
	# la mano" no tiene ninguna cobertura propia — se gatea AQUÍ, antes de
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
	if not main._gold_manager:
		return
	var hand_container_piru = main.player_hand if owner_id == 0 else main._opponent_fan
	if not hand_container_piru or not hand_container_piru.cards.has(source_card):
		return
	# 2026-10-06: GoldManager.puede_pagar()/pagar_coste() ya son por jugador
	# (ver arquitectura.md §33) — esta habilidad se desbloquea.
	if not main._gold_manager.puede_pagar(1, -1, "", -1, owner_id):
		main._update_debug("Oro insuficiente (necesitas 1)")
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	await main._gold_manager.pagar_coste(1, -1, "", -1, owner_id)
	# Ventana ANTES de que se vaya al fondo del Castillo (2026-09-10): después
	# de remove_card(..., true) queda inválida para open_response_window().
	if await TriggerSystem.open_response_window(source_card, "Piruquina", owner_id):
		return

	var card_data: Dictionary = source_card.card_data.duplicate()
	hand_container_piru.remove_card(source_card, true)
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
	var hand_container_qm = main.player_hand if owner_id == 0 else main._opponent_fan
	if not hand_container_qm or hand_container_qm.cards.is_empty():
		return

	# 2026-09-13, a pedido del usuario: click directo en la mano en vez del
	# modal de lista viejo. Filtro restringido a owner_id (mismo bug que
	# gran kraken, ver PreventionAbilityHandler_EP.gd).
	if not main._card_interaction:
		return
	var hand_filter := func(c: Node) -> bool:
		return c.get("current_zone") == Constants.Zone.MANO and c.get("owner_id") == owner_id
	var hand_node: Node = await main._card_interaction.await_target(
		"Baraja 1 carta de tu mano para barajar tu Cementerio y robar", hand_filter, true, owner_id)
	if not hand_node or not is_instance_valid(hand_node):
		return
	var to_shuffle_data: Dictionary = hand_node.card_data

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	hand_container_qm.remove_card(hand_node, true)
	CardManager.get_deck(owner_id).append(to_shuffle_data)
	CardManager.shuffle_deck(owner_id)
	AnimationQueue.add_command(AnimationQueue.CommandType.CUSTOM, {
		"callable": Callable(AnimationQueue, "animate_shuffle").bind(owner_id),
		"description": "Barajar mazo (Quantum Megumi)"
	})

	if not CardManager.get_cemetery(owner_id).is_empty() and main._zone_viewer:
		# 2026-09-13: click directo en el propio Cementerio en vez del modal
		# de lista viejo.
		var own_only := func(c: Node) -> bool: return c.owner_id == owner_id
		var picked: Array = await main._zone_viewer.open_cemetery_target_picker(
			"Elige hasta 3 cartas de tu Cementerio para barajar", own_only, 3, "cemetery", false, false, owner_id)
		if await TriggerSystem.open_response_window(source_card, "Quantum Megumi", owner_id):
			return
		var shuffled := 0
		for entry in picked:
			var idx: int = CardManager.get_cemetery(owner_id).find(entry.data)
			if idx >= 0:
				CardManager.remove_from_cemetery(owner_id, idx)
				CardManager.get_deck(owner_id).append(entry.data)
				shuffled += 1
		if shuffled > 0:
			CardManager.shuffle_deck(owner_id)
			AnimationQueue.add_command(AnimationQueue.CommandType.CUSTOM, {
				"callable": Callable(AnimationQueue, "animate_shuffle").bind(owner_id),
				"description": "Barajar mazo (Quantum Megumi)"
			})
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
	efectivo ≤1), aquí el objetivo es un Talismán específicamente y se suma
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
	if not main._card_interaction:
		return

	var filter := func(c: Node) -> bool:
		if c.get("card_type") != Constants.CardType.TALISMAN:
			return false
		# 2026-09-12: current_zone en vez de get_parent() (ver §10.5)
		if c.get("current_zone") not in [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_APOYO]:
			return false
		return ContinuousEffectManager.get_modified_cost(c) <= 1
	var target: Node = await main._card_interaction.await_target("Elige un Talismán de coste 1 o menos para anular", filter, true, owner_id)
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
	if not main._gold_manager:
		return

	var my_gold: HBoxContainer = main.player_gold if owner_id == 0 else main.opponent_gold
	var my_pagado: HBoxContainer = main.player_oro_pagado if owner_id == 0 else main.opponent_oro_pagado
	var opp_gold: HBoxContainer = main.opponent_gold if owner_id == 0 else main.player_gold
	var opp_pagado: HBoxContainer = main.opponent_oro_pagado if owner_id == 0 else main.player_oro_pagado
	var my_oros: int = my_gold.get_child_count() + my_pagado.get_child_count()
	var opp_oros: int = opp_gold.get_child_count() + opp_pagado.get_child_count()
	if my_oros > opp_oros:
		main._update_debug("Sake: solo se puede usar si no controlas más Oros que tu oponente")
		return
	# 2026-10-06: GoldManager.puede_pagar()/pagar_coste() ya son por jugador
	# (ver arquitectura.md §33) — esta habilidad se desbloquea.
	if not main._gold_manager.puede_pagar(1, -1, "", -1, owner_id):
		main._update_debug("Necesitas 1 Oro disponible para esta habilidad")
		return
	if not main._card_interaction:
		return

	# 2026-09-13, a pedido del usuario: click directo — mano (Nodos ya
	# visibles) + un popup liviano con el Cementerio propio (mismo patrón
	# que El Rey y el Verdugo, arquitectura.md §10.17), en vez del modal de
	# lista viejo combinando ambas zonas.
	var hand_container_sake = main.player_hand if owner_id == 0 else main._opponent_fan
	var hand_oros: Array = []
	if hand_container_sake:
		for c in hand_container_sake.cards:
			if is_instance_valid(c) and c.get("card_type") == Constants.CardType.ORO:
				hand_oros.append(c)
	var cemetery_popup_result: Dictionary = _open_cemetery_reveal_popup_oro(main, owner_id)
	var cemetery_popup: CanvasLayer = cemetery_popup_result.get("popup")
	var candidates: Array = hand_oros + cemetery_popup_result.get("nodes", [])
	if candidates.is_empty():
		if is_instance_valid(cemetery_popup):
			cemetery_popup.queue_free()
		main._update_debug("No tienes ningún Oro en tu mano o Cementerio")
		return

	var filter := func(c: Node) -> bool: return c in candidates
	var chosen_node: Node = await main._card_interaction.await_target(
		"Elige un Oro de tu mano o Cementerio para poner en juego", filter, true, owner_id)
	if is_instance_valid(cemetery_popup):
		cemetery_popup.queue_free()
	if not chosen_node or not is_instance_valid(chosen_node):
		return
	var chosen_data: Dictionary = chosen_node.card_data
	var from_hand: bool = chosen_node in hand_oros

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	await main._gold_manager.pagar_coste(1, -1, "", -1, owner_id)
	PaymentManager.registrar_pago(1)

	if from_hand:
		hand_container_sake.remove_card(chosen_node, true)
	else:
		var idx: int = CardManager.get_cemetery(owner_id).find(chosen_data)
		if idx >= 0:
			CardManager.remove_from_cemetery(owner_id, idx)

	await main._gold_manager.put_gold_directly_in_reserva(owner_id, chosen_data)


func _activate_shub_niggurath_gold_for_totem_draw(source_card: Node, ability: Dictionary) -> void:
	"""'En tu Vigilia, una vez por turno, puedes generar un Oro para jugar
	un Tótem de coste 2 o más y Robar una carta' (Shub-Niggurath,
	2026-09-04)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if not main._gold_manager:
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	if await TriggerSystem.open_response_window(source_card, "Shub-Niggurath", owner_id):
		return
	var predicate := func(card_type: int, _card_race: String, card_cost: int) -> bool:
		return card_type == Constants.CardType.TOTEM and card_cost >= 2
	# 2026-10-06: generar_oro_virtual_restringido() ya es por jugador (ver
	# arquitectura.md §33) — esta habilidad se desbloquea.
	main._gold_manager.generar_oro_virtual_restringido(1, predicate, "Tótem de coste 2 o más", owner_id)
	await ActionModule.draw(owner_id, 1, "activated_ability", true)


func _activate_shub_niggurath_shuffle_or_mill_opponent(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez en tu turno, Baraja una carta de coste 3 o menos o tu
	oponente Bota dos cartas por cada Aliado y/o Tótem que controles'
	(Shub-Niggurath, 2026-09-04) — elección A/B."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if not main._card_interaction:
		return

	var choose_shuffle: bool = await SelectionManager.await_two_choice(
		main, "Shub-Niggurath", "Barajar una carta de coste 3 o menos", "Tu oponente Bota cartas", owner_id)

	if choose_shuffle:
		var filter := func(c: Node) -> bool:
			# 2026-09-12: current_zone en vez de get_parent() (ver §10.5)
			if c.get("current_zone") not in [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE, Constants.Zone.LINEA_APOYO]:
				return false
			return ContinuousEffectManager.get_modified_cost(c) <= 3
		var target: Node = await main._card_interaction.await_target("Elige una carta de coste 3 o menos para barajar", filter, true, owner_id)
		if not target or not is_instance_valid(target):
			return
		UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
		var target_owner: int = target.controller_id if target.get("controller_id") != null else owner_id
		if await ActionModule.return_to_deck(target, target_owner, true, source_card):
			CardManager.shuffle_deck(target_owner)
			AnimationQueue.add_command(AnimationQueue.CommandType.CUSTOM, {
				"callable": Callable(AnimationQueue, "animate_shuffle").bind(target_owner),
				"description": "Barajar mazo (Shub-Niggurath)"
			})
	else:
		UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
		var count: int = 0
		var own_fields_shub: Array = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo] if owner_id == 0 else [main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]
		for field in own_fields_shub:
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
	var hand_container_skof = main.player_hand if owner_id == 0 else main._opponent_fan
	if not hand_container_skof or not hand_container_skof.cards.has(source_card):
		return

	# Ventana ANTES del autobarajado (2026-09-10): sin esto, source_card queda
	# inválida (remove_card(..., true)) para cuando haría falta abrirla.
	if await TriggerSystem.open_response_window(source_card, "skofnung", owner_id):
		return
	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	var card_data: Dictionary = source_card.card_data.duplicate()
	hand_container_skof.remove_card(source_card, true)
	CardManager.get_deck(owner_id).append(card_data)
	CardManager.shuffle_deck(owner_id)
	AnimationQueue.add_command(AnimationQueue.CommandType.CUSTOM, {
		"callable": Callable(AnimationQueue, "animate_shuffle").bind(owner_id),
		"description": "Barajar mazo (skofnung)"
	})
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

	# 2026-09-13, a pedido del usuario: click directo en el propio
	# Cementerio en vez del modal de lista viejo.
	if not main._zone_viewer:
		return
	var eligible_filter := func(c: Node) -> bool:
		return c.owner_id == owner_id and int(c.card_data.get("coste", -1)) == 1
	var picked: Array = await main._zone_viewer.open_cemetery_target_picker(
		"Elige una carta de coste 1 en tu Cementerio para que gane Exhumar por el turno", eligible_filter, 1, "cemetery", false, false, owner_id)
	if picked.is_empty():
		return
	var picked_data: Dictionary = picked[0].data
	# Ventana ANTES del autodescarte (2026-09-10): después de discard(),
	# source_card queda inválida para open_response_window().
	if await TriggerSystem.open_response_window(source_card, "sumi el terrible", owner_id):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	var hand_container_sumi = main.player_hand if owner_id == 0 else main._opponent_fan
	if hand_container_sumi and hand_container_sumi.cards.has(source_card):
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
	var hand_container = main.player_hand if owner_id == 0 else main._opponent_fan
	if not hand_container or hand_container.cards.is_empty():
		return

	if not main._card_interaction:
		return
	# 2026-09-13, a pedido del usuario: click directo en la mano en vez del
	# modal de lista viejo. Filtro restringido a owner_id (mismo bug que
	# gran kraken, ver PreventionAbilityHandler_EP.gd).
	var hand_filter := func(c: Node) -> bool:
		return c.get("current_zone") == Constants.Zone.MANO and c.get("owner_id") == owner_id
	var to_shuffle_node: Node = await main._card_interaction.await_target(
		"Baraja 1 carta de tu mano", hand_filter, true, owner_id)
	if not to_shuffle_node or not is_instance_valid(to_shuffle_node):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	var shuffled_data: Dictionary = to_shuffle_node.card_data
	hand_container.remove_card(to_shuffle_node, true)
	CardManager.get_deck(owner_id).append(shuffled_data)
	ActionModule.shuffle_deck(owner_id)
	AnimationQueue.add_command(AnimationQueue.CommandType.CUSTOM, {
		"callable": Callable(AnimationQueue, "animate_shuffle").bind(owner_id),
		"description": "Barajar mazo (Torre de Babel)"
	})

	if await TriggerSystem.open_response_window(source_card, "Torre de Babel", owner_id):
		return
	await main._gold_manager._resolve_armeria_barajar_desterrar(5, "Torre de Babel", owner_id)
	await ActionModule.draw(owner_id, 2, "activated_ability", true)


func _activate_totem_dragon_ancestral_shuffle_self_annul_or_cancel(source_card: Node, ability: Dictionary) -> void:
	"""'En tu turno, puedes Barajarlo para Anular un Aliado o cancelar una
	habilidad' (Tótem del Dragón Ancestral, 2026-09-04) — autobarajar
	(vuelve al Castillo del dueño), elección A/B."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if not main._card_interaction:
		return

	var choose_annul: bool = await SelectionManager.await_two_choice(
		main, str(source_card.get("card_name")), "Anular un Aliado", "Cancelar una habilidad", owner_id)

	var target: Node = null
	if choose_annul:
		var filter := func(c: Node) -> bool:
			if c.get("card_type") != Constants.CardType.ALIADO:
				return false
			# 2026-09-12: current_zone en vez de get_parent() (ver §10.5)
			return c.get("current_zone") in [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE, Constants.Zone.LINEA_APOYO]
		target = await main._card_interaction.await_target("Elige un Aliado para anular", filter, true, owner_id)
	else:
		var filter2 := func(c: Node) -> bool:
			# 2026-09-12: current_zone en vez de get_parent() (ver §10.5)
			return c.get("current_zone") in [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE,
				Constants.Zone.LINEA_APOYO, Constants.Zone.RESERVA_ORO]
		target = await main._card_interaction.await_target("Elige una carta para cancelar su habilidad", filter2, true, owner_id)
	if not target or not is_instance_valid(target):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	var self_owner: int = owner_id
	if await ActionModule.return_to_deck(source_card, self_owner, true, source_card):
		CardManager.shuffle_deck(self_owner)
		AnimationQueue.add_command(AnimationQueue.CommandType.CUSTOM, {
			"callable": Callable(AnimationQueue, "animate_shuffle").bind(self_owner),
			"description": "Barajar mazo (Tótem del Dragón Ancestral)"
		})

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

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	if await TriggerSystem.open_response_window(source_card, "uriel", owner_id):
		return
	await main._gold_manager._resolve_armeria_barajar_desterrar(3, "uriel", owner_id)
	await ActionModule.draw(owner_id, 1, "activated_ability", true)

	var hand_container = main.player_hand if owner_id == 0 else main._opponent_fan
	if hand_container and not hand_container.cards.is_empty() and main._card_interaction:
		# 2026-09-13, a pedido del usuario: click directo en la mano en vez
		# del modal de lista viejo. Filtro restringido a owner_id (mismo
		# bug que gran kraken, ver PreventionAbilityHandler_EP.gd).
		var hand_filter := func(c: Node) -> bool:
			return c.get("current_zone") == Constants.Zone.MANO and c.get("owner_id") == owner_id
		var to_exile_node: Node = await main._card_interaction.await_target(
			"Destierra 1 carta de tu mano", hand_filter, true, owner_id)
		if to_exile_node and is_instance_valid(to_exile_node):
			# Destierra desde la MANO (no en juego): banish() asume una
			# carta en juego y no actualiza la bookkeeping de player_hand
			# (mismo motivo documentado en HandManager.remove_card() vs
			# remove_child()+queue_free() manual) — se saca de la mano
			# primero y se agregan sus datos al Destierro a mano.
			var exile_data: Dictionary = to_exile_node.card_data.duplicate()
			hand_container.remove_card(to_exile_node, true)
			CardManager.add_to_exile(owner_id, exile_data)


func _activate_vision_heroica_pay_raise_draw(source_card: Node, ability: Dictionary) -> void:
	"""'Puedes pagar un Oro para subir esta carta de tu Cementerio a tu
	mano y Robar una carta' (vision heroica, 2026-09-06) — usable desde el
	Cementerio."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if not main._gold_manager:
		return
	# 2026-10-06 (ver arquitectura.md §33): GoldManager.puede_pagar()/
	# pagar_coste() ya son por jugador — esta habilidad se desbloquea.
	if not main._gold_manager.puede_pagar(1, -1, "", -1, owner_id):
		main._update_debug("Oro insuficiente (necesitas 1)")
		return

	var own_cemetery: Array = CardManager.get_cemetery(owner_id)
	var card_data: Dictionary = source_card.card_data
	var idx: int = own_cemetery.find(card_data)
	if idx < 0:
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	await main._gold_manager.pagar_coste(1, -1, "", -1, owner_id)
	if await TriggerSystem.open_response_window(source_card, "vision heroica", owner_id):
		return
	CardManager.remove_from_cemetery(owner_id, idx)
	var card_node = main._create_card(card_data, false)
	var hand_container_visionh = main.player_hand if owner_id == 0 else main._opponent_fan
	hand_container_visionh.add_card(card_node)
	main._connect_card_signals(card_node)
	await ActionModule.draw(owner_id, 1, "activated_ability", true)
