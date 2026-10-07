extends RefCounted
## HandCementerioAbilityHandler — Patrones especiales de habilidades
## ACTIVADAS usables DESDE LA MANO o el CEMENTERIO, antes de jugar la carta
## (Tyet — 2 habilidades, Ramón Freire, Espada del Juicio, Drácula —
## cancela ataque, Estaca — robo+barajado). Detectados en
## CardInspectionLayer._build_ability_buttons() y ruteados aquí en vez de al
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
		"Elige un Oro: pierde su habilidad este turno y va a su Oro Pagado", filter, true, owner_id)
	if not target or not is_instance_valid(target):
		return
	# 2026-09-06, bug real reportado por el usuario: validado 'source_card' UNA
	# sola vez al entrar, pero el await de arriba es tiempo real de espera del
	# jugador — si la carta salió de juego mientras el selector estaba abierto,
	# quedaba una referencia colgante que crasheaba más abajo (turn_registry,
	# _mover_oro_a_pagado). Mismo fix aplicado a todas las funciones de este
	# archivo que usan 'source_card' después de un await.
	if not is_instance_valid(source_card):
		return
	if await TriggerSystem.open_response_window(source_card, str(source_card.card_name), owner_id):
		return
	await _inspector._main._gold_manager._mover_oro_a_pagado(source_card)
	await KeywordManager.silence_card(target, source_card, "turn")
	await _inspector._main._gold_manager._mover_oro_a_pagado(target)


func _activate_tyet_mill_and_draw(source_card: Node, ability: Dictionary) -> void:
	"""'Puedes poner esta y otra carta de tu mano en el fondo de tu Castillo
	y Robar dos cartas' (Tyet). Solo usable DESDE LA MANO (2026-09-09,
	revertido a pedido explícito del usuario — hubo un vaivén: se restringió
	a solo-mano el 2026-08-31, se abrió también a Reserva de Oro el
	2026-09-06 razonando que 'esta' no implica zona, y ahora se confirma que
	la restricción original era la correcta: Tyet ya en juego NO puede usar
	esta habilidad). Costo: esta misma carta + una elegida de la mano, ambas
	al FONDO del mazo (deck.append(), no pop_front() — el índice 0 es el
	tope)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var source_zone = source_card.get("current_zone")
	var hand_container_tyet = _inspector._main.player_hand if owner_id == 0 else _inspector._main._opponent_fan
	if not hand_container_tyet or source_zone != Constants.Zone.MANO:
		return

	var other_hand_cards: Array = []
	for c in hand_container_tyet.cards:
		if c != source_card and is_instance_valid(c):
			other_hand_cards.append(c)
	if other_hand_cards.is_empty():
		_inspector._main._update_debug("Necesitas otra carta en tu mano para usar esta habilidad")
		return

	if not _inspector._main._card_interaction:
		return
	# 2026-09-13, a pedido del usuario: click directo en la mano en vez del
	# modal de lista viejo.
	var other_filter := func(c: Node) -> bool: return c in other_hand_cards
	var other_node: Node = await _inspector._main._card_interaction.await_target(
		"Elige otra carta de tu mano para poner en el fondo de tu Castillo", other_filter, true, owner_id)
	if not other_node or not is_instance_valid(other_node):
		return
	if not is_instance_valid(source_card):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	if await TriggerSystem.open_response_window(source_card, str(source_card.card_name), owner_id):
		return

	var source_data: Dictionary = source_card.card_data.duplicate()
	var other_data: Dictionary = other_node.card_data.duplicate()
	source_data["esta_oculta"] = true
	other_data["esta_oculta"] = true
	hand_container_tyet.remove_card(other_node, true)
	hand_container_tyet.remove_card(source_card, true)
	var deck: Array = CardManager.get_deck(owner_id)
	deck.append(source_data)
	deck.append(other_data)

	await ActionModule.draw(owner_id, 2, "activated_ability", true)


func _activate_sandraudiga_banish_pair_and_peek(source_card: Node, ability: Dictionary) -> void:
	"""'Puedes pagar un Oro para Desterrar este y otro Aliado Sacerdote de
	tu mano. Mira la mano de tu oponente, Destierra una carta que no sea
	Aliado ni Oro de ahí' (sandraudiga, 2026-09-06) — usable DESDE LA MANO
	(ver _ability_is_hand_usable()). 'Si está en tu Destierro, puedes
	Desterrar una carta de tu mano para Barajarlo en tu Castillo' NO
	implementado (necesitaría una categoría nueva de zona-usable: desde el
	Destierro)."""
	if not is_instance_valid(source_card) or not _inspector._main.player_hand or not _inspector._main._gold_manager:
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0 or source_card.get("current_zone") != Constants.Zone.MANO:
		# 2026-10-05: costo real de 1 Oro (puede_pagar()/pagar_coste(), de un
		# solo jugador, ver §22) Y usa SelectionManager.await_single_pick()
		# para "mira la mano rival" (sin chooser_id, ver §22) — dos motivos
		# independientes para dejarla sin desbloquear.
		return  # el Remoto no puede usar esta habilidad todavía

	var other_priests: Array = []
	for c in _inspector._main.player_hand.cards:
		if c != source_card and is_instance_valid(c) and c.get("card_type") == Constants.CardType.ALIADO \
				and "sacerdote" in str(c.get("card_raza")).to_lower():
			other_priests.append(c)
	if other_priests.is_empty():
		_inspector._main._update_debug("Necesitas otro Aliado Sacerdote en tu mano para usar esta habilidad")
		return
	if not _inspector._main._gold_manager.puede_pagar(1):
		_inspector._main._update_debug("Oro insuficiente (necesitas 1)")
		return

	if not _inspector._main._card_interaction:
		return
	# 2026-09-13, a pedido del usuario: click directo en la mano en vez del
	# modal de lista viejo.
	var priest_filter := func(c: Node) -> bool: return c in other_priests
	var other_node: Node = await _inspector._main._card_interaction.await_target(
		"Elige otro Aliado Sacerdote de tu mano para Desterrar", priest_filter)
	if not other_node or not is_instance_valid(other_node):
		return
	if not is_instance_valid(source_card):
		return
	# Ventana ANTES del auto-costo (2026-09-10): source_card se destierra a sí
	# misma como parte del costo un poco más abajo, y open_response_window()
	# exige que 'source_card' siga siendo un Node válido — abrirla aquí, con la
	# carta todavía en la mano, es lo único seguro (después de esto queue_free()
	# la invalida, y el picker de la mano rival que sigue tarda varios frames).
	if await TriggerSystem.open_response_window(source_card, "sandraudiga", owner_id):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	await _inspector._main._gold_manager.pagar_coste(1)

	var self_data: Dictionary = source_card.card_data.duplicate()
	var other_data: Dictionary = other_node.card_data.duplicate()
	_inspector._main.player_hand.remove_card(other_node, true)
	_inspector._main.player_hand.remove_card(source_card, true)
	CardManager.add_to_exile(owner_id, self_data)
	CardManager.add_to_exile(owner_id, other_data)

	var opponent_id: int = 1 - owner_id
	if not _inspector._main._opponent_fan or not _inspector._main._opponent_fan.has_method("get_cards"):
		return
	var opponent_hand: Array = _inspector._main._opponent_fan.get_cards()
	var candidates: Array = []
	for c in opponent_hand:
		if is_instance_valid(c) and c.get("card_type") != Constants.CardType.ALIADO and c.get("card_type") != Constants.CardType.ORO:
			candidates.append(c)
	if candidates.is_empty():
		return
	var not_ally_or_gold := func(d: Dictionary) -> bool:
		return d.get("tipo") != Constants.CardType.ALIADO and d.get("tipo") != Constants.CardType.ORO
	var picked_opp: Dictionary = await SelectionManager.await_single_pick(
		candidates.map(func(c): return c.card_data), "Mira la mano rival: elige una carta (que no sea Aliado ni Oro) para Desterrar", true, 1, not_ally_or_gold)
	if picked_opp.is_empty():
		return
	var opp_node: Node = null
	for c in candidates:
		if c.card_data == picked_opp:
			opp_node = c
			break
	if opp_node:
		var cemetery_before_size: int = CardManager.get_cemetery(opponent_id).size()
		await ActionModule.discard(opponent_id, [opp_node], "activated_ability", true)
		var cemetery: Array = CardManager.get_cemetery(opponent_id)
		if cemetery.size() > cemetery_before_size:
			var discarded_data: Dictionary = cemetery.back()
			CardManager.remove_from_cemetery(opponent_id, cemetery.size() - 1)
			CardManager.add_to_exile(opponent_id, discarded_data)


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

	var has_big_ally := false
	var own_fields_ramon: Array = [_inspector._main.player_field, _inspector._main.player_linea_ataque] if owner_id == 0 \
		else [_inspector._main.opponent_field, _inspector._main.opponent_linea_ataque]
	for field in own_fields_ramon:
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
	if await TriggerSystem.open_response_window(source_card, "Ramón Freire", owner_id):
		return

	var predicate := func(card_type: int, _card_race: String, _card_cost: int) -> bool:
		return card_type == Constants.CardType.ARMA
	# 2026-10-06: generar_oro_virtual_restringido() ya es por jugador (ver
	# arquitectura.md §33) — esta habilidad se desbloquea.
	_inspector._main._gold_manager.generar_oro_virtual_restringido(1, predicate, "Armas", owner_id)

	var zone = source_card.get("current_zone")
	if zone == Constants.Zone.MANO:
		var card_data: Dictionary = source_card.card_data.duplicate()
		var hand_container_ramon = _inspector._main.player_hand if owner_id == 0 else _inspector._main._opponent_fan
		if hand_container_ramon:
			hand_container_ramon.remove_card(source_card, true)
		CardManager.add_to_exile(owner_id, card_data)
	else:
		await EffectController.exile_card(owner_id, source_card, true)


func _activate_espada_juicio_banish_cemetery_for_buff(source_card: Node, ability: Dictionary) -> void:
	"""'Puedes Desterrarla de tu Cementerio para que un Aliado gane o
	pierda 2 de Fuerza permanentemente' (Espada del Juicio, 2026-08-30) —
	primera habilidad usable DESDE EL CEMENTERIO de esta sesión. source_card
	aquí es un Card node de SOLO VISTA (ZoneViewerModule lo arma fresco a
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

	var cemetery: Array = CardManager.get_cemetery(owner_id)
	var idx: int = cemetery.find(source_card.card_data)
	if idx < 0:
		return  # ya no está ahí (algo más la movió mientras se inspeccionaba)

	var target: Node = await TriggerSystem._targeted_executor._select_ally_target(
		"Elige un Aliado para que gane o pierda 2 de Fuerza", null, owner_id)
	if not target or not is_instance_valid(target):
		return

	var gains: bool = await SelectionManager.await_two_choice(
		_inspector._main, "Espada del Juicio", "Ganar 2 de Fuerza", "Perder 2 de Fuerza", owner_id)
	if not is_instance_valid(source_card):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	if await TriggerSystem.open_response_window(source_card, "Espada del Juicio", owner_id):
		return

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
	var zone = source_card.get("current_zone")
	if zone != Constants.Zone.MANO and zone != Constants.Zone.CEMENTERIO:
		return  # el texto solo cubre mano/Cementerio, no en juego

	if GameManager.attackers.is_empty():
		_inspector._main._update_debug("No hay ningún Aliado atacando ahora mismo")
		return

	if not _inspector._main._card_interaction:
		return
	# 2026-09-13, a pedido del usuario: click directo sobre los Aliados
	# atacando en vez del modal de lista viejo.
	var candidates: Array = []
	for a in GameManager.attackers:
		if is_instance_valid(a):
			candidates.append(a)
	var chosen: Array = await _inspector._main._card_interaction.await_multi_target(
		"Cancela el ataque de hasta dos Aliados", candidates, 2, Callable(), Callable(), true, null, owner_id)
	if chosen.is_empty():
		return
	if not is_instance_valid(source_card):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	if await TriggerSystem.open_response_window(source_card, "Drácula", owner_id):
		return

	if zone == Constants.Zone.MANO:
		var card_data: Dictionary = source_card.card_data.duplicate()
		var hand_container_dracula = _inspector._main.player_hand if owner_id == 0 else _inspector._main._opponent_fan
		if hand_container_dracula:
			hand_container_dracula.remove_card(source_card, true)
		CardManager.add_to_exile(owner_id, card_data)
	else:
		var cemetery: Array = CardManager.get_cemetery(owner_id)
		var idx: int = cemetery.find(source_card.card_data)
		if idx >= 0:
			var removed_data: Dictionary = CardManager.remove_from_cemetery(owner_id, idx)
			if not removed_data.is_empty():
				CardManager.add_to_exile(owner_id, removed_data)

	var cancelled: Array = chosen.filter(func(a): return is_instance_valid(a))
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
	# Ventana única para toda la habilidad (2026-09-10): sin declare real
	# todavía en este punto (el objetivo rival se elige solo más abajo) —
	# se gatea aquí, al principio, igual que el resto de efectos compuestos
	# sin un punto de declare limpio antes de arrancar.
	if await TriggerSystem.open_response_window(source_card, "Estaca", owner_id):
		return

	await ActionModule.draw(owner_id, 3, "ability_activated", true)
	if not is_instance_valid(source_card):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	var opponent_id: int = 1 - owner_id
	var opp_fields: Array = [_inspector._main.opponent_field, _inspector._main.opponent_linea_ataque, _inspector._main.opponent_linea_apoyo] if owner_id == 0 \
		else [_inspector._main.player_field, _inspector._main.player_linea_ataque, _inspector._main.player_linea_apoyo]
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
		"Elige una carta rival en juego (que no sea Oro) para barajar", filter, true, owner_id)
	if not target or not is_instance_valid(target):
		return

	var opp_cost: int = int(target.card_cost) if target.get("card_cost") != null else 0

	await ActionModule.return_to_deck(target, opponent_id, true, source_card)
	CardManager.shuffle_deck(opponent_id)
	AnimationQueue.add_command(AnimationQueue.CommandType.CUSTOM, {
		"callable": Callable(AnimationQueue, "animate_shuffle").bind(opponent_id),
		"description": "Barajar mazo (Estaca)"
	})

	var hand_container_estaca = _inspector._main.player_hand if owner_id == 0 else _inspector._main._opponent_fan
	if opp_cost > 0 and hand_container_estaca and not hand_container_estaca.cards.is_empty() \
			and _inspector._main._card_interaction:
		var hand_cards: Array = hand_container_estaca.cards.duplicate()
		var pick_amount: int = mini(opp_cost, hand_cards.size())
		# 2026-09-13, a pedido del usuario: click directo en la mano en vez
		# del modal de lista viejo. Costo TODO o NADA de 'pick_amount'
		# cartas exactas (mismo criterio que Belta, §10.19).
		var chosen: Array = await _inspector._main._card_interaction.await_multi_target(
			"Baraja %d carta(s) de tu mano en tu Castillo" % pick_amount, hand_cards, pick_amount, Callable(), Callable(), true, null, owner_id)
		if chosen.size() >= pick_amount:
			for c in chosen:
				if is_instance_valid(c):
					var data: Dictionary = c.card_data
					hand_container_estaca.remove_card(c, true)
					CardManager.get_deck(owner_id).append(data)
			CardManager.shuffle_deck(owner_id)
			AnimationQueue.add_command(AnimationQueue.CommandType.CUSTOM, {
				"callable": Callable(AnimationQueue, "animate_shuffle").bind(owner_id),
				"description": "Barajar mazo (Estaca)"
			})


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
		# 2026-10-05: reusa GoldManager.play_card() completo (de un solo
		# jugador — ver §23) y lee CardManager.get_cemetery(0) hardcodeado
		# más abajo — se deja sin desbloquear.
		return  # el Remoto no puede usar esta habilidad todavía
	if source_card.get("current_zone") != Constants.Zone.RESERVA_ORO:
		_inspector._main._update_debug("%s ya no está en tu Reserva" % str(source_card.get("card_name")))
		return

	# 2026-09-13, a pedido del usuario: reemplaza el modal de lista viejo por
	# click directo sobre cartas reales — un popup con las cartas del propio
	# Cementerio MÁS una carta temporal extra representando 'el tope de tu
	# Castillo' (revelada de una: el propio texto de La Ouija dice 'Juega
	# mostrando la primera carta de tu Castillo', así que no hay nada oculto
	# que preservar mostrándola en el picker). Todo vive en UN solo
	# await_multi_target() — evita el problema de correr dos mecanismos de
	# selección en carrera a la vez (ver arquitectura.md §10.14).
	var deck: Array = _inspector._main.player_deck
	var own_cemetery: Array = CardManager.get_cemetery(0)
	if own_cemetery.is_empty() and deck.is_empty():
		_inspector._main._update_debug("No tienes cartas en tu Cementerio ni en tu Castillo para jugar con La Ouija")
		return

	var popup_canvas := CanvasLayer.new()
	popup_canvas.layer = 55
	_inspector._main.add_child(popup_canvas)
	var bg := ColorRect.new()
	bg.size = _inspector._main.get_viewport().get_visible_rect().size
	bg.color = Color(0.01, 0.01, 0.02, 0.78)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	bg.gui_input.connect(func(ev):
		if ev is InputEventMouseButton and ev.pressed and _inspector._main._card_interaction.is_selecting_target:
			_inspector._main._card_interaction.cancel_target_selection()
	)
	popup_canvas.add_child(bg)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	grid.set_anchors_preset(Control.PRESET_CENTER)
	popup_canvas.add_child(grid)

	var CardScene = load("res://scenes/cards/Card.tscn")
	var node_from_info: Dictionary = {}  # instance_id -> "cemetery"/"deck_top"
	var candidates: Array = []
	for data in own_cemetery:
		var wrapper := Control.new()
		wrapper.custom_minimum_size = Vector2(110.0, 154.0)
		var c_node = CardScene.instantiate()
		c_node.load_from_data(data)
		c_node.set_zone(Constants.Zone.CEMENTERIO)
		c_node.owner_id = 0
		c_node.controller_id = 0
		c_node.can_interact = true
		c_node.drag_enabled = false
		c_node.custom_minimum_size = Vector2(150.0, 210.0)
		c_node.size = Vector2(150.0, 210.0)
		c_node.scale = Vector2(0.733, 0.733)
		c_node.base_scale = Vector2(0.733, 0.733)
		_inspector._main._connect_card_signals(c_node)
		wrapper.add_child(c_node)
		grid.add_child(wrapper)
		node_from_info[c_node.get_instance_id()] = "cemetery"
		candidates.append(c_node)
	if not deck.is_empty():
		var wrapper2 := Control.new()
		wrapper2.custom_minimum_size = Vector2(110.0, 154.0)
		var top_node = CardScene.instantiate()
		top_node.load_from_data(deck[0])
		top_node.set_zone(Constants.Zone.CASTILLO)
		top_node.owner_id = 0
		top_node.controller_id = 0
		top_node.can_interact = true
		top_node.drag_enabled = false
		top_node.custom_minimum_size = Vector2(150.0, 210.0)
		top_node.size = Vector2(150.0, 210.0)
		top_node.scale = Vector2(0.733, 0.733)
		top_node.base_scale = Vector2(0.733, 0.733)
		_inspector._main._connect_card_signals(top_node)
		wrapper2.add_child(top_node)
		grid.add_child(wrapper2)
		node_from_info[top_node.get_instance_id()] = "deck_top"
		candidates.append(top_node)

	var chosen_nodes: Array = await _inspector._main._card_interaction.await_multi_target(
		"Elige una carta de tu Cementerio o el tope de tu Castillo para jugar", candidates, 1)
	if is_instance_valid(popup_canvas):
		popup_canvas.queue_free()
	if chosen_nodes.is_empty():
		return
	var chosen_node: Node = chosen_nodes[0]
	var chosen_data: Dictionary = chosen_node.card_data
	var chosen_from: String = node_from_info.get(chosen_node.get_instance_id(), "cemetery")

	if not is_instance_valid(source_card):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	if chosen_from == "cemetery":
		var idx: int = CardManager.get_cemetery(0).find(chosen_data)
		if idx < 0:
			return
		CardManager.remove_from_cemetery(0, idx)
	else:
		deck.pop_front()
		if _inspector._main._zone_manager:
			_inspector._main._zone_manager._update_castillo_counts()
		_inspector._main._update_debug("La Ouija: mostrando la primera carta de tu Castillo (%s)" % str(chosen_data.get("nombre", "?")))

	var card_node: Node = _inspector._main._create_card(chosen_data, false)
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
	if source_card.get("current_zone") != Constants.Zone.MANO:
		return

	# 2026-10-06: GoldManager.puede_pagar()/pagar_coste() ya son por jugador
	# (ver arquitectura.md §33) — esta habilidad se desbloquea.
	if not _inspector._main._gold_manager.puede_pagar(1, -1, "", -1, owner_id):
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
		"Elige una carta en juego de coste 2 o menos", filter, true, owner_id)
	if not target or not is_instance_valid(target):
		return

	var choose_banish: bool = await SelectionManager.await_two_choice(
		_inspector._main, "Sacrificio Solar",
		"Desterrar la carta elegida", "Barajar la carta elegida en su Castillo", owner_id)

	await _inspector._main._gold_manager.pagar_coste(1, -1, "", -1, owner_id)
	if not is_instance_valid(source_card):
		return
	if await TriggerSystem.open_response_window(source_card, "Sacrificio Solar", owner_id):
		return

	var target_owner: int = target.owner_id if target.get("owner_id") != null else 0
	if choose_banish:
		await ActionModule.banish([target], source_card, true)
	else:
		await ActionModule.return_to_deck(target, target_owner, true, source_card)
		CardManager.shuffle_deck(target_owner)
		AnimationQueue.add_command(AnimationQueue.CommandType.CUSTOM, {
			"callable": Callable(AnimationQueue, "animate_shuffle").bind(target_owner),
			"description": "Barajar mazo (Sacrificio Solar)"
		})

	var hand_container_sacrificio = _inspector._main.player_hand if owner_id == 0 else _inspector._main._opponent_fan
	if hand_container_sacrificio and hand_container_sacrificio.cards.find(source_card) >= 0:
		var self_data: Dictionary = source_card.card_data
		hand_container_sacrificio.remove_card(source_card, true)
		CardManager.get_deck(owner_id).append(self_data)
		CardManager.shuffle_deck(owner_id)
		AnimationQueue.add_command(AnimationQueue.CommandType.CUSTOM, {
			"callable": Callable(AnimationQueue, "animate_shuffle").bind(owner_id),
			"description": "Barajar mazo (Sacrificio Solar)"
		})

	await ActionModule.draw(owner_id, 1, "ability_activated", true)
