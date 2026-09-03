extends RefCounted
## HandCementerioAbilityHandler — Patrones especiales de habilidades
## ACTIVADAS usables DESDE LA MANO o el CEMENTERIO, antes de jugar la carta
## (Tyet — 2 habilidades, Ramón Freire, Espada del Juicio, Drácula —
## cancela ataque, Estaca — robo+barajado). Detectados en
## CardInspectionLayer._build_ability_buttons() y ruteados acá en vez de al
## pipeline genérico de habilidades activadas. Opera sobre CardInspectionLayer
## via _inspector (y sobre el Main del juego via _inspector._main).
## Extraído de CardInspectionLayer.gd (2026-08-30, "módulos gordos" — mismo
## corte que ya separó BernardoAbilityHandler/ResponseWindowHandler).

var _inspector: CardInspectionLayer


func setup(inspector: CardInspectionLayer) -> void:
	_inspector = inspector


func _activate_tyet_silence_and_pay(source_card: Node, ability: Dictionary) -> void:
	"""'Puedes pagar este Oro para que un Oro pierda su habilidad este turno
	y muévelo al Oro Pagado' (Tyet, 2026-08-29). Costo: esta misma carta (un
	Oro) se gasta como pago del turno — CostType.SELF_AS_GOLD, un concepto
	que ActionPipeline no conoce. Efecto sobre OTRO Oro elegido: pierde su
	habilidad SOLO este turno (KeywordManager.silence_card(..., 'turn') —
	se autolimpia sola al empezar el próximo turno, sin hook aparte) y se
	mueve a SU PROPIO Oro Pagado. 'un Oro' sin calificar (2026-08-31,
	corrige: el texto real no dice 'de tu Reserva' ni 'tuyo' — antes esta
	función restringía por error a la Reserva propia) — cualquier Oro en
	Reserva, propio o rival, ver [[project_no_zone_means_in_play]].
	GoldManager._mover_oro_a_pagado() ya resuelve la Reserva/Oro Pagado
	correctos según el controller_id del Oro elegido."""
	if not is_instance_valid(source_card) or not _inspector._main._gold_manager:
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía
	if source_card.get("current_zone") != Constants.Zone.RESERVA_ORO:
		_inspector._main._update_debug("%s ya no está en tu Reserva" % str(source_card.get("card_name")))
		return

	var candidates: Array = []
	if _inspector._main.player_gold:
		for c in _inspector._main.player_gold.get_children():
			if c != source_card and is_instance_valid(c):
				candidates.append(c)
	if _inspector._main.opponent_gold:
		for c in _inspector._main.opponent_gold.get_children():
			if is_instance_valid(c):
				candidates.append(c)
	if candidates.is_empty():
		_inspector._main._update_debug("No hay otro Oro en juego para elegir")
		return
	if not _inspector._main._card_interaction:
		return

	var filter := func(c: Node) -> bool:
		return c in candidates
	var target: Node = await _inspector._main._card_interaction.await_target(
		"Elige un Oro: pierde su habilidad este turno y va a su Oro Pagado", filter)
	if not target or not is_instance_valid(target):
		return
	await _inspector._main._gold_manager._mover_oro_a_pagado(source_card)
	KeywordManager.silence_card(target, source_card, "turn")
	await _inspector._main._gold_manager._mover_oro_a_pagado(target)


func _activate_tyet_mill_and_draw(source_card: Node, ability: Dictionary) -> void:
	"""'Puedes poner esta y otra carta de tu mano en el fondo de tu Castillo
	y Robar dos cartas' (Tyet, 2026-08-30) — usable DESDE LA MANO, antes de
	jugar la carta (ver _ability_is_hand_usable()). Costo: esta misma carta
	+ una elegida de la mano, ambas al FONDO del mazo (deck.append(), no
	pop_front() — el índice 0 es el tope)."""
	if not is_instance_valid(source_card) or not _inspector._main.player_hand:
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0 or source_card.get("current_zone") != Constants.Zone.MANO:
		return

	var other_hand_cards: Array = []
	for c in _inspector._main.player_hand.cards:
		if c != source_card and is_instance_valid(c):
			other_hand_cards.append(c)
	if other_hand_cards.is_empty():
		_inspector._main._update_debug("Necesitas otra carta en tu mano para usar esta habilidad")
		return

	var card_data_list: Array = []
	for c in other_hand_cards:
		card_data_list.append(c.card_data)
	var picked: Dictionary = await SelectionManager.await_single_pick(
		card_data_list, "Elige otra carta de tu mano para poner en el fondo de tu Castillo")
	if picked.is_empty():
		return

	var other_node: Node = null
	for c in other_hand_cards:
		if c.card_data == picked:
			other_node = c
			break
	if not other_node:
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	var source_data: Dictionary = source_card.card_data.duplicate()
	var other_data: Dictionary = other_node.card_data.duplicate()
	source_data["esta_oculta"] = true
	other_data["esta_oculta"] = true
	_inspector._main.player_hand.remove_card(other_node, true)
	_inspector._main.player_hand.remove_card(source_card, true)
	var deck: Array = CardManager.get_deck(owner_id)
	deck.append(source_data)
	deck.append(other_data)

	await ActionModule.draw(owner_id, 2, "activated_ability", true)


func _activate_ramon_freire_banish_for_gold(source_card: Node, ability: Dictionary) -> void:
	"""'Si controlas Aliados de coste 2 o más, puedes Desterrarlo de tu mano
	o en juego para generar un Oro para jugar Armas. Sólo puedes utilizar
	la habilidad de Ramón Freire una vez por turno' (2026-08-30). Usable
	DESDE LA MANO o ya en juego (ver _ability_is_hand_usable()). Condición
	previa (controlar un Aliado de coste ≥2) que ActionPipeline no sabe
	verificar. Oro Virtual RESTRINGIDO — mismo mecanismo que Padre de la
	Patria (GoldManager.generar_oro_virtual_restringido)."""
	if not is_instance_valid(source_card) or not _inspector._main._gold_manager:
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía

	var has_big_ally := false
	for field in [_inspector._main.player_field, _inspector._main.player_linea_ataque]:
		if not field:
			continue
		for c in field.get_children():
			if c != source_card and c.get("card_type") == Constants.CardType.ALIADO and c.get("card_cost") != null and int(c.card_cost) >= 2:
				has_big_ally = true
				break
		if has_big_ally:
			break
	if not has_big_ally:
		_inspector._main._update_debug("Necesitas controlar un Aliado de coste 2 o más para usar esta habilidad")
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	var predicate := func(card_type: int, _card_race: String, _card_cost: int) -> bool:
		return card_type == Constants.CardType.ARMA
	_inspector._main._gold_manager.generar_oro_virtual_restringido(1, predicate, "Armas")

	var zone = source_card.get("current_zone")
	if zone == Constants.Zone.MANO:
		var card_data: Dictionary = source_card.card_data.duplicate()
		_inspector._main.player_hand.remove_card(source_card, true)
		CardManager.add_to_exile(owner_id, card_data)
	else:
		await EffectController.exile_card(owner_id, source_card, true)


func _activate_espada_juicio_banish_cemetery_for_buff(source_card: Node, ability: Dictionary) -> void:
	"""'Puedes Desterrarla de tu Cementerio para que un Aliado gane o
	pierda 2 de Fuerza permanentemente' (Espada del Juicio, 2026-08-30) —
	primera habilidad usable DESDE EL CEMENTERIO de esta sesión. source_card
	acá es un Card node de SOLO VISTA (ZoneViewerModule lo arma fresco a
	partir de los datos crudos del Cementerio, no es el mismo objeto que
	vive en CardManager._zones[player_id].cemetery) — el costo (Desterrar)
	tiene que operar sobre el DATO real de esa lista, no sobre este nodo
	descartable. 'Permanentemente' con la Espada ya desterrada (fuente que
	ya no está en juego): el modificador se autorreferencia al Aliado
	elegido (source=target), dura mientras ÉL siga en juego — no tiene
	sentido atarlo a una fuente que ya no existe."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía

	var cemetery: Array = CardManager.get_cemetery(owner_id)
	var idx: int = cemetery.find(source_card.card_data)
	if idx < 0:
		return  # ya no está ahí (algo más la movió mientras se inspeccionaba)

	var target: Node = await TriggerSystem._targeted_executor._select_ally_target(
		"Elige un Aliado para que gane o pierda 2 de Fuerza")
	if not target or not is_instance_valid(target):
		return

	var gains: bool = await SelectionManager.await_two_choice(
		_inspector._main, "Espada del Juicio", "Ganar 2 de Fuerza", "Perder 2 de Fuerza")

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	var removed_data: Dictionary = CardManager.remove_from_cemetery(owner_id, idx)
	if not removed_data.is_empty():
		CardManager.add_to_exile(owner_id, removed_data)

	ContinuousEffectManager.register_modifier({
		"source": target,
		"target": target,
		"type": ContinuousEffectManager.ModifierType.STRENGTH,
		"stat": "strength",
		"value": 2 if gains else -2,
		"operation": "add",
		"duration": ContinuousEffectManager.ModifierDuration.PERMANENT,
		"layer": ContinuousEffectManager.ModifierLayer.LAYER_7B_CHAR_MODIFY,
		"description": "%s de Espada del Juicio" % ("Buff" if gains else "Debuff"),
	})
	if target.has_method("refresh_strength_badge"):
		target.refresh_strength_badge()


func _activate_dracula_cancel_attacks(source_card: Node, ability: Dictionary) -> void:
	"""'Puedes Desterrarlo de tu mano o Cementerio para cancelar el ataque
	de hasta dos Aliados' (Drácula, 2026-08-30) — usable DESDE LA MANO o el
	CEMENTERIO (ver _ability_is_hand_usable()/_ability_is_cementerio_usable()).
	Costo sobre la carta REAL de la zona correspondiente (mismo criterio que
	_activate_espada_juicio_banish_cemetery_for_buff() para Cementerio,
	_activate_ramon_freire_banish_for_gold() para mano). Efecto: sacar hasta
	2 Aliados de GameManager.attackers (cualquier bando — el texto no dice
	'que controla tu oponente') y revertir su aspecto visual de 'atacando'
	vía CardInteractionModule.unmark_attackers(), sin pasar por
	undeclare_attacker() (ese exige que sea el turno del propio controlador
	del atacante)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía
	var zone = source_card.get("current_zone")
	if zone != Constants.Zone.MANO and zone != Constants.Zone.CEMENTERIO:
		return  # el texto solo cubre mano/Cementerio, no en juego

	if GameManager.attackers.is_empty():
		_inspector._main._update_debug("No hay ningún Aliado atacando ahora mismo")
		return

	var candidates: Array = []
	for a in GameManager.attackers:
		if is_instance_valid(a):
			candidates.append(a.card_data)
	var result: Dictionary = await SelectionManager.await_multi_pick(
		candidates, "Cancela el ataque de hasta dos Aliados", 2, 0, true)
	if result.picked.is_empty():
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	if zone == Constants.Zone.MANO:
		var card_data: Dictionary = source_card.card_data.duplicate()
		_inspector._main.player_hand.remove_card(source_card, true)
		CardManager.add_to_exile(owner_id, card_data)
	else:
		var cemetery: Array = CardManager.get_cemetery(owner_id)
		var idx: int = cemetery.find(source_card.card_data)
		if idx >= 0:
			var removed_data: Dictionary = CardManager.remove_from_cemetery(owner_id, idx)
			if not removed_data.is_empty():
				CardManager.add_to_exile(owner_id, removed_data)

	var cancelled: Array = []
	for picked_data in result.picked:
		for a in GameManager.attackers:
			if is_instance_valid(a) and a.card_data == picked_data:
				cancelled.append(a)
				break
	for a in cancelled:
		GameManager.attackers.erase(a)
	if _inspector._main._card_interaction and _inspector._main._card_interaction.has_method("unmark_attackers"):
		await _inspector._main._card_interaction.unmark_attackers(cancelled)


func _activate_estaca_draw_and_shuffle(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, puedes Robar tres cartas, Barajar una carta
	oponente que no sea Oro y tantas cartas de tu mano como coste tenga'
	(Estaca, 2026-08-30). La carta oponente no menciona zona — es EN JUEGO
	(regla general del proyecto: sin 'de tu mano'/'de tu Castillo' =
	sucede en juego), excluyendo Oro. El robo (3) es independiente y
	siempre ocurre; el barajado de la carta rival y el de tu propia mano
	(tantas cartas como el COSTE de esa carta rival) están LIGADOS: sin
	objetivo rival válido, ninguno de los dos barajados ocurre."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía

	await ActionModule.draw(owner_id, 3, "ability_activated", true)

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	var opponent_id: int = 1 - owner_id
	var opp_fields: Array = [_inspector._main.opponent_field, _inspector._main.opponent_linea_ataque, _inspector._main.opponent_linea_apoyo]
	var candidates: Array = []
	for field in opp_fields:
		if not field:
			continue
		for c in field.get_children():
			if not is_instance_valid(c):
				continue
			if c.get("card_type") != Constants.CardType.ORO:
				candidates.append(c)
			var weapons = c.get("equipped_weapons")
			if weapons is Array:
				for w in weapons:
					if is_instance_valid(w) and w.get("card_type") != Constants.CardType.ORO:
						candidates.append(w)
	if candidates.is_empty():
		return

	var filter := func(c: Node) -> bool:
		return c in candidates
	var target: Node = await _inspector._main._card_interaction.await_target(
		"Elige una carta rival en juego (que no sea Oro) para barajar", filter)
	if not target or not is_instance_valid(target):
		return

	var opp_cost: int = int(target.card_cost) if target.get("card_cost") != null else 0

	ActionModule.return_to_deck(target, opponent_id, true)
	CardManager.shuffle_deck(opponent_id)

	if opp_cost > 0 and _inspector._main.player_hand and not _inspector._main.player_hand.cards.is_empty():
		var hand_cards: Array = _inspector._main.player_hand.cards.duplicate()
		var card_data_list: Array = []
		for c in hand_cards:
			card_data_list.append(c.card_data)
		var pick_amount: int = mini(opp_cost, hand_cards.size())
		var result: Dictionary = await SelectionManager.await_multi_pick(
			card_data_list, "Baraja %d carta(s) de tu mano en tu Castillo" % pick_amount,
			pick_amount, pick_amount, false)
		var shuffled := 0
		for picked_data in result.picked:
			for c in hand_cards:
				if is_instance_valid(c) and c.card_data == picked_data:
					_inspector._main.player_hand.remove_card(c, true)
					CardManager.get_deck(owner_id).append(picked_data)
					shuffled += 1
					break
		if shuffled > 0:
			CardManager.shuffle_deck(owner_id)


func _activate_ouija_play_from_cemetery_or_deck_top(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, puedes jugar una carta de tu Cementerio o del
	tope de tu Castillo. Juega mostrando la primera carta de tu Castillo.'
	(La Ouija, 2026-08-31 — carta promocional de 'IMP - Chile Oscuro 2', sin
	myl_id real: no está en la API externa — ver [[reference_myl_external_api]],
	el cache local es la única fuente para esta carta). 'de tu Cementerio' y
	'del tope de tu Castillo' llevan posesivo (solo el propio, a diferencia
	de Miguel, cuyo 'un Cementerio' sin posesivo sí incluye el rival — ver
	_activate_miguel_discount_play() en SearchAbilityHandler.gd, mismo
	esqueleto de esta función). La segunda oración es el aviso de que jugar
	desde el tope revela esa carta al hacerlo — no hay sistema de revelado
	real conectado en este motor (mismo caso ya resuelto para Levisterio:
	'puedes mostrar tu mano'), así que se deja constancia en el log en vez
	de abrir una UI de revelado nueva para un único caso. Reusa
	GoldManager.play_card() completo, igual que Miguel."""
	if not is_instance_valid(source_card) or not _inspector._main._gold_manager:
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía
	if source_card.get("current_zone") != Constants.Zone.RESERVA_ORO:
		_inspector._main._update_debug("%s ya no está en tu Reserva" % str(source_card.get("card_name")))
		return

	var candidates: Array = []
	for data in CardManager.get_cemetery(0):
		candidates.append({"data": data, "from": "cemetery"})
	var deck: Array = _inspector._main.player_deck
	if not deck.is_empty():
		candidates.append({"data": deck[0], "from": "deck_top"})
	if candidates.is_empty():
		_inspector._main._update_debug("No tienes cartas en tu Cementerio ni en tu Castillo para jugar con La Ouija")
		return

	var display_data: Array = []
	for c in candidates:
		display_data.append(c.data)

	var picked: Dictionary = await SelectionManager.await_single_pick(
		display_data, "Elige una carta de tu Cementerio o del tope de tu Castillo para jugar")
	if picked.is_empty():
		return

	var chosen: Dictionary = {}
	for c in candidates:
		if c.data == picked:
			chosen = c
			break
	if chosen.is_empty():
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	if chosen.from == "cemetery":
		var idx: int = CardManager.get_cemetery(0).find(chosen.data)
		if idx < 0:
			return
		CardManager.remove_from_cemetery(0, idx)
	else:
		deck.pop_front()
		if _inspector._main._zone_manager:
			_inspector._main._zone_manager._update_castillo_counts()
		_inspector._main._update_debug("La Ouija: mostrando la primera carta de tu Castillo (%s)" % str(chosen.data.get("nombre", "?")))

	var card_node: Node = _inspector._main._create_card(chosen.data, false)
	card_node.owner_id = 0
	card_node.controller_id = 0
	_inspector._main.player_hand.add_card(card_node)
	_inspector._main._connect_card_signals(card_node)

	await _inspector._main._gold_manager.play_card(card_node)


func _activate_sacrificio_solar_self_shuffle_banish_or_shuffle(source_card: Node, ability: Dictionary) -> void:
	"""'Puedes pagar un Oro y Barajar esta carta desde tu mano para
	Desterrar o Barajar una carta de coste 2 o menos y Robar una carta'
	(Sacrificio Solar, 2026-09-02 — verificado contra la API, sin
	discrepancias con el cache local). Costo: 1 Oro + esta misma carta,
	barajada desde la mano de vuelta al Castillo (no destierro ni
	descarte — mismo mecanismo que Aaru/Manuel Bulnes: remove_card(...,
	true) + CardManager.get_deck().append() + shuffle_deck()). 'Una carta
	de coste 2 o menos' sin zona ni dueño = EN JUEGO, de cualquier lado
	(ver [[project_no_zone_means_in_play]]) — se elige el objetivo Y si
	termina Desterrado o Barajado, la misma elección para ambos efectos.
	'Puedes X para Y' es atómico (ver [[project_puedes_x_para_y_atomic]]):
	no se ofrece nada si falta el Oro o no hay ningún objetivo válido —
	el pago y el autobarajado de esta carta se resuelven AL FINAL, después
	de resolver el objetivo, para no quedarse con una referencia a un nodo
	ya en cola de borrado mientras todavía hace falta."""
	if not is_instance_valid(source_card) or not _inspector._main._gold_manager:
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0 or source_card.get("current_zone") != Constants.Zone.MANO:
		return  # el bot no usa esta habilidad todavía

	if not _inspector._main._gold_manager.puede_pagar(1):
		_inspector._main._update_debug("No tienes 1 Oro disponible para Sacrificio Solar")
		return

	var candidates: Array = []
	for field in [_inspector._main.player_field, _inspector._main.player_linea_ataque, _inspector._main.player_linea_apoyo,
			_inspector._main.opponent_field, _inspector._main.opponent_linea_ataque, _inspector._main.opponent_linea_apoyo]:
		if not field:
			continue
		for c in field.get_children():
			if not is_instance_valid(c):
				continue
			var c_cost: int = int(c.card_cost) if c.get("card_cost") != null else 0
			if c_cost <= 2:
				candidates.append(c)
			var weapons = c.get("equipped_weapons")
			if weapons is Array:
				for w in weapons:
					if is_instance_valid(w):
						var w_cost: int = int(w.card_cost) if w.get("card_cost") != null else 0
						if w_cost <= 2:
							candidates.append(w)
	if candidates.is_empty():
		_inspector._main._update_debug("No hay ninguna carta en juego de coste 2 o menos para Sacrificio Solar")
		return

	if not _inspector._main._card_interaction:
		return
	var filter := func(c: Node) -> bool:
		return c in candidates
	var target: Node = await _inspector._main._card_interaction.await_target(
		"Elige una carta en juego de coste 2 o menos", filter)
	if not target or not is_instance_valid(target):
		return

	var choose_banish: bool = await SelectionManager.await_two_choice(
		_inspector._main, "Sacrificio Solar",
		"Desterrar la carta elegida", "Barajar la carta elegida en su Castillo")

	await _inspector._main._gold_manager.pagar_coste(1)

	var target_owner: int = target.owner_id if target.get("owner_id") != null else 0
	if choose_banish:
		await ActionModule.banish([target], source_card, true)
	else:
		ActionModule.return_to_deck(target, target_owner, true)
		CardManager.shuffle_deck(target_owner)

	if _inspector._main.player_hand.cards.find(source_card) >= 0:
		var self_data: Dictionary = source_card.card_data
		_inspector._main.player_hand.remove_card(source_card, true)
		CardManager.get_deck(owner_id).append(self_data)
		CardManager.shuffle_deck(owner_id)

	await ActionModule.draw(owner_id, 1, "ability_activated", true)
