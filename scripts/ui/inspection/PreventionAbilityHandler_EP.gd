extends RefCounted
## PreventionAbilityHandler_EP — Mitad E-P (alfabético por nombre de carta) de
## PreventionAbilityHandler.gd, dividido por tamaño (2026-09-06, "módulos
## gordos" — mismo corte que ya separó SearchAbilityHandler_AI.gd/
## SearchAbilityHandler_JV.gd del propio SearchAbilityHandler.gd). Ver
## PreventionAbilityHandler.gd para el facade que reune esta parte con
## PreventionAbilityHandler_AE.gd y PreventionAbilityHandler_PV.gd bajo los
## mismos nombres públicos que antes — CardInspectionLayer.gd no cambió una
## sola línea por este split. Opera sobre CardInspectionLayer via _inspector
## (y sobre el Main del juego via _inspector._main).

var _inspector: CardInspectionLayer


func setup(inspector: CardInspectionLayer) -> void:
	_inspector = inspector


## _activate_estaca_banish_for_prevention() eliminada (2026-09-09, "sistema
## de respuestas"): Estaca ya no se activa por botón — EffectController.
## offer_prevention() (registro en EffectController.gd) la detecta y ofrece
## reactivamente en el momento exacto en que un efecto rival amenaza a una
## carta, con el mismo costo (autodestierro) resuelto en su 'on_used'.


func _activate_frankenstein_discard_silence_turn(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, puedes Descartar una carta para que una carta
	pierda su habilidad por el turno' (Frankenstein o El Moderno
	Prometeo, 2026-09-04). Costo: descartar 1 carta CUALQUIERA. Objetivo:
	cualquier carta en juego, sin restricción de tipo/coste. Duración:
	solo este turno (KeywordManager.silence_card(..., 'turn'))."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0 or not main.player_hand or main.player_hand.cards.is_empty():
		return
	if not main._card_interaction:
		return

	var filter := func(c: Node) -> bool:
		var parent = c.get_parent()
		var valid_zones = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
			main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo,
			main.player_gold, main.opponent_gold, main.player_oro_pagado, main.opponent_oro_pagado]
		return parent in valid_zones
	var target: Node = await main._card_interaction.await_target(
		"Elige una carta que pierda su habilidad por el turno", filter)
	if not target or not is_instance_valid(target):
		return
	if TriggerSystem._targeted_executor._target_text_denies(target, ["no puede perder su habilidad"]):
		main._update_debug("%s no puede perder su habilidad" % str(target.card_name))
		return

	var hand_cards: Array = main.player_hand.cards.duplicate()
	var hand_data_list: Array = []
	for c in hand_cards:
		hand_data_list.append(c.card_data)
	var to_discard_data: Dictionary = await SelectionManager.await_single_pick(
		hand_data_list, "Descarta 1 carta para que %s pierda su habilidad por el turno" % str(target.card_name), false)
	if to_discard_data.is_empty():
		return
	var discard_node: Node = null
	for c in hand_cards:
		if c.card_data == to_discard_data:
			discard_node = c
			break
	if not discard_node:
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	await ActionModule.discard(owner_id, [discard_node], "ability_cost", true)
	await KeywordManager.silence_card(target, source_card, "turn")


func _activate_frankenstein_pay_shuffle_cancel(source_card: Node, ability: Dictionary) -> void:
	"""'En tu turno, puedes pagarlo y Barajar una carta de tu mano para
	cancelar la habilidad de un Oro o carta de coste 2 o menos'
	(Frankenstein o El Moderno Prometeo, 2026-09-04). Costo: gastar este
	Oro (a Oro Pagado, GoldManager._mover_oro_a_pagado(), mismo mecanismo
	que Tyet) + barajar 1 carta de la mano. Efecto: la objetivo pierde su
	habilidad de forma permanente ('cancela la habilidad' ~ silenciar,
	misma simplificación ya usada en Red de Plata/Sheut)."""
	if not is_instance_valid(source_card) or not _inspector._main._gold_manager:
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0 or not main.player_hand or main.player_hand.cards.is_empty():
		return
	if source_card.get("current_zone") != Constants.Zone.RESERVA_ORO:
		main._update_debug("%s ya no está en tu Reserva" % str(source_card.get("card_name")))
		return
	if not main._card_interaction:
		return

	var filter := func(c: Node) -> bool:
		if c.get("card_type") != Constants.CardType.ORO and ContinuousEffectManager.get_modified_cost(c) > 2:
			return false
		var parent = c.get_parent()
		var valid_zones = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
			main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo,
			main.player_gold, main.opponent_gold]
		return parent in valid_zones
	var target: Node = await main._card_interaction.await_target(
		"Elige un Oro o carta de coste 2 o menos para cancelar su habilidad", filter)
	if not target or not is_instance_valid(target):
		return
	if TriggerSystem._targeted_executor._target_text_denies(target, ["no puede ser cancelada", "no puede perder su habilidad"]):
		main._update_debug("%s no puede perder su habilidad" % str(target.card_name))
		return

	var hand_cards: Array = main.player_hand.cards.duplicate()
	var hand_data_list: Array = []
	for c in hand_cards:
		hand_data_list.append(c.card_data)
	var to_shuffle_data: Dictionary = await SelectionManager.await_single_pick(
		hand_data_list, "Baraja 1 carta de tu mano para cancelar esa habilidad", false)
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
	await main._gold_manager._mover_oro_a_pagado(source_card)
	await KeywordManager.silence_card(target, source_card, "permanent")


func _activate_gran_kraken_discard_destroy(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez en tu turno, puedes Descartar una carta para Destruir una
	carta de coste 3 o menos' (gran kraken, 2026-09-04). Costo: Descartar 1
	carta propia. Efecto: destruir una carta (Aliado/Arma/Tótem) de coste
	efectivo ≤3."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0 or not main.player_hand or main.player_hand.cards.is_empty():
		return

	var hand_cards: Array = main.player_hand.cards.duplicate()
	var card_data_list: Array = []
	for c in hand_cards:
		card_data_list.append(c.card_data)
	var picked_to_discard: Dictionary = await SelectionManager.await_single_pick(
		card_data_list, "Descarta 1 carta de tu mano")
	if picked_to_discard.is_empty():
		return

	var to_discard_node: Node = null
	for c in hand_cards:
		if c.card_data == picked_to_discard:
			to_discard_node = c
			break
	if not to_discard_node:
		return

	var target: Node = await TriggerSystem._targeted_executor._select_destroy_target_cost_filter(
		"Elige una carta de coste 3 o menos para destruir", 3)
	if not target or not is_instance_valid(target):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	await ActionModule.discard(owner_id, [to_discard_node], "activated_ability", true)
	await ActionModule.destroy([target], source_card, true, true)


func _activate_kuchiku_kan_discard_to_disable(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, puedes Descartar una carta para que una carta
	pierda su habilidad y no pueda atacar ni bloquear mientras este Aliado
	esté en juego' (Kuchiku Kan, 2026-09-03). 'Una carta' sin zona (DAR:
	sin zona explícita = en juego, [[project_no_zone_means_in_play]]) —
	cualquier carta en juego de cualquier jugador, no solo Aliados (Armas/
	Tótems/Oros también pueden 'perder su habilidad'; 'no pueda atacar ni
	bloquear' solo tiene efecto real sobre Aliados, pero no hace falta
	filtrar por tipo para el resto — simplemente no cambia nada visible).
	Costo: descartar 1 carta CUALQUIERA de la mano, sin relación con el
	objetivo. Efecto ligado a que ESTE Aliado se quede en juego: pérdida de
	habilidad vía KeywordManager.lock_ability_by_instance() (nuevo,
	2026-09-03 — NO el 'permanent' de silence_card(), que es indefinido de
	verdad) + dos modificadores RESTRICTION (CANT_ATTACK/CANT_BLOCK) con
	duration PERMANENT y source=source_card, que Continuous
	EffectManager._is_modifier_active() ya trata como 'mientras la fuente
	siga en juego'. El bloqueo de ataque queda realmente wireado (Turn
	Manager.can_attack() consulta ContinuousEffectManager.can_attack());
	el de bloqueo queda como dato correcto a la espera de que exista un
	flujo real de declarar bloqueadores (ver docs/audit — GameManager.
	declare_blocker()/blockers no está conectado a ninguna UI todavía)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0 or not main.player_hand or main.player_hand.cards.is_empty():
		return  # el bot no usa esta habilidad todavía
	if not main._card_interaction:
		return

	var filter := func(c: Node) -> bool:
		if c.get("card_type") not in [Constants.CardType.ALIADO, Constants.CardType.ARMA, Constants.CardType.TOTEM, Constants.CardType.ORO]:
			return false
		var parent = c.get_parent()
		var valid_zones = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
			main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo,
			main.player_gold, main.opponent_gold]
		return parent in valid_zones
	var chosen_target: Node = await main._card_interaction.await_target(
		"Elige una carta que pierda su habilidad y no pueda atacar ni bloquear", filter)
	if not chosen_target or not is_instance_valid(chosen_target):
		return

	if TriggerSystem._targeted_executor._target_text_denies(chosen_target, ["no puede perder su habilidad", "no pierde su habilidad"]):
		main._update_debug("%s no puede perder su habilidad" % str(chosen_target.card_name))
		return

	var hand_cards: Array = main.player_hand.cards.duplicate()
	var discard_data_list: Array = []
	for c in hand_cards:
		discard_data_list.append(c.card_data)
	var to_discard_data: Dictionary = await SelectionManager.await_single_pick(
		discard_data_list, "Descarta 1 carta para que %s pierda su habilidad" % str(chosen_target.card_name), false)
	if to_discard_data.is_empty():
		return
	var discard_node: Node = null
	for c in hand_cards:
		if c.card_data == to_discard_data:
			discard_node = c
			break
	if not discard_node:
		return
	# lock_ability_by_instance()/las 2 restricciones CANT_ATTACK-CANT_BLOCK de
	# abajo NO pasan por silence_card() ni por ningún choque protegido por
	# Prevención (2026-09-10) — a diferencia del resto de esta familia de
	# handlers, acá sí corresponde la ventana genérica.
	if await TriggerSystem.open_response_window(source_card, "Kuchiku Kan", owner_id):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	await ActionModule.discard(owner_id, [discard_node], "ability_cost", true)

	KeywordManager.lock_ability_by_instance(chosen_target, source_card)
	for restriction_type in ["CANT_ATTACK", "CANT_BLOCK"]:
		ContinuousEffectManager.register_modifier({
			"source": source_card,
			"target": chosen_target,
			"type": ContinuousEffectManager.ModifierType.RESTRICTION,
			"restriction_type": restriction_type,
			"duration": ContinuousEffectManager.ModifierDuration.PERMANENT,
			"description": "No puede atacar/bloquear por Kuchiku Kan",
		})


func _activate_lanza_argenta_destroy_self_cancel_or_draw(source_card: Node, ability: Dictionary) -> void:
	"""'Puedes Destruir esta Arma para cancelar una habilidad o Robar tres
	cartas' (lanza argenta, 2026-09-04) — autodestrucción (va al
	Cementerio, no al Destierro), elección A/B."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía

	var choose_cancel: bool = await SelectionManager.await_two_choice(
		main, "lanza argenta", "Destruirla para cancelar una habilidad", "Destruirla para Robar tres cartas")

	var target: Node = null
	if choose_cancel:
		if not main._card_interaction:
			return
		var filter := func(c: Node) -> bool:
			var parent = c.get_parent()
			var valid_zones = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
				main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo,
				main.player_gold, main.opponent_gold]
			return parent in valid_zones
		target = await main._card_interaction.await_target("Elige una carta para cancelar su habilidad", filter)
		if not target or not is_instance_valid(target):
			return

	# Rama "roba tres": a diferencia de la de cancelar (protegida después por
	# silence_card()), el Robo no tiene cobertura propia — la ventana tiene
	# que abrirse ACÁ, antes de la autodestrucción de más abajo (2026-09-10):
	# source_card se destruye a sí misma como costo, y open_response_window()
	# exige que siga siendo un Node válido.
	if not choose_cancel and await TriggerSystem.open_response_window(source_card, "lanza argenta", owner_id):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	await ActionModule.destroy([source_card], source_card, true, true)

	if choose_cancel and target:
		if TriggerSystem._targeted_executor._target_text_denies(target, ["no puede perder su habilidad", "no pierde su habilidad"]):
			main._update_debug("%s no pierde su habilidad" % str(target.get("card_name")))
		else:
			await KeywordManager.silence_card(target, source_card, "permanent")
	else:
		await ActionModule.draw(owner_id, 3, "activated_ability", true)


## _activate_legion_paladin_prevention() eliminada (2026-09-09, "sistema de
## respuestas"): igual que Estaca — ya no es un botón, EffectController.
## offer_prevention() la detecta y ofrece reactivamente (tag "leave_play").


func _activate_nu_galahad_look_play_weapon_and_ally_free(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, mira tantas cartas del tope de tu Castillo como
	Armas controles, juega un Arma y un Aliado de Fuerza 4 o menos de ahí,
	sin pagar su coste y Baraja el resto' (nu-galahad el bastion,
	2026-09-05) — 'Armas controles' cuenta TODAS las equipadas en
	cualquiera de tus Aliados, no solo las de esta carta."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0 or not main._gold_manager:
		return  # el bot no usa esta habilidad todavía

	var weapon_count := 0
	for field in [main.player_field, main.player_linea_ataque, main.player_linea_apoyo]:
		if not field:
			continue
		for c in field.get_children():
			var weapons = c.get("equipped_weapons")
			if weapons is Array:
				weapon_count += weapons.size()
	if weapon_count <= 0:
		main._update_debug("No controlas ninguna Arma")
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	var deck: Array = CardManager.get_deck(owner_id)
	var revealed: Array = []
	for i in range(mini(weapon_count, deck.size())):
		revealed.append(deck.pop_front())

	if not revealed.is_empty():
		SelectionManager.open_reveal(revealed, "nu-galahad el bastion: mira %d carta(s) del tope de tu Castillo" % revealed.size())

	var found_weapon: Dictionary = {}
	var found_ally: Dictionary = {}
	for d in revealed:
		var t: int = d.get("tipo", -1)
		if found_weapon.is_empty() and t == Constants.CardType.ARMA:
			found_weapon = d
		elif found_ally.is_empty() and t == Constants.CardType.ALIADO and int(d.get("fuerza", 99)) <= 4:
			found_ally = d

	for picked_data in [found_weapon, found_ally]:
		if picked_data.is_empty():
			continue
		revealed.erase(picked_data)
		await main._gold_manager.play_card_for_free(picked_data)

	for c in revealed:
		deck.append(c)
	CardManager.shuffle_deck(owner_id)
	if main.get("_zone_manager"):
		main._zone_manager._update_castillo_counts()


func _activate_nu_galahad_wear_cemetery_as_weapons(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, porta hasta tres cartas de un Cementerio como
	Armas sin habilidad' (nu-galahad el bastion, 2026-09-05) — 'porta' sin
	otro sujeto = ÉL mismo las porta (coherente con su pasivo 'Tus
	Aliados no tienen límite de Armas', ya moot: el motor no impone
	ningún límite de Armas por Aliado de por sí). Convierte cada carta
	elegida en un Arma sin habilidad (is_converted + silence_card, mismo
	mecanismo de conversión real usado en todo el proyecto) y la equipa
	de verdad vía GoldManager._equip_weapon()."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0 or not main._gold_manager:
		return  # el bot no usa esta habilidad todavía

	var zone_owner: int = await TriggerSystem._targeted_executor._choose_search_zone_owner(owner_id, Constants.Zone.CEMENTERIO)
	var cemetery: Array = CardManager.get_cemetery(zone_owner)
	if cemetery.is_empty():
		main._update_debug("Ese Cementerio está vacío")
		return
	var result: Dictionary = await SelectionManager.await_multi_pick(
		cemetery.duplicate(), "Elige hasta tres cartas para portar como Armas sin habilidad", 3, 0, true)
	var picked: Array = result.get("picked", [])
	if picked.is_empty():
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	for picked_data in picked:
		var idx: int = cemetery.find(picked_data)
		if idx < 0:
			continue
		CardManager.remove_from_cemetery(zone_owner, idx)
		var new_data: Dictionary = picked_data.duplicate()
		new_data["tipo"] = Constants.CardType.ARMA
		new_data["esta_oculta"] = false
		var weapon_node = main._create_card(new_data, false)
		weapon_node.owner_id = zone_owner
		main._connect_card_signals(weapon_node)
		weapon_node.is_converted = true
		await main._gold_manager._equip_weapon(weapon_node, source_card)
		await KeywordManager.silence_card(weapon_node, source_card, "permanent")


func _activate_paladin_bestiarium_discard_weapon_discount(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, puedes Descartar una carta para jugar un Arma de
	tu mano reduciendo su coste en un Oro, hasta un mínimo de 0' (Paladín
	Bestiarium, 2026-08-30). Costo: descartar 1 carta CUALQUIERA de la
	mano — no tiene que ser el Arma que se juega. Efecto: jugar OTRA carta
	de la mano (un Arma) con -1 Oro (piso 0), mismo mecanismo puntual que
	'Muestra X para reducir el coste' (El Rey y el Verdugo,
	GoldManager.play_card()).

	'Puedes X para Y' es atómico (2026-08-31, reportado por el usuario: con
	0 Oro en Reserva, intentar jugar un Arma de coste 2 con esta habilidad
	igual descartaba la carta de costo aunque play_card() rechazara el Arma
	después por Oro insuficiente — el jugador perdía la carta descartada
	sin obtener nada. Ver [[project_puedes_x_para_y_atomic]], mismo criterio
	ya aplicado a Padre de la Patria/Lobo Sagrado/Espada Vikinga): solo se
	ofrecen como candidatas las Armas que el jugador YA puede pagar con el
	descuento de -1 aplicado (piso 0), y esa asequibilidad se filtra ANTES
	de pedir qué carta descartar — no después."""
	if not is_instance_valid(source_card) or not _inspector._main._gold_manager:
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0 or not _inspector._main.player_hand or _inspector._main.player_hand.cards.is_empty():
		return  # el bot no usa esta habilidad todavía

	var hand_cards: Array = _inspector._main.player_hand.cards.duplicate()
	var gold_manager: GoldManager = _inspector._main._gold_manager

	var weapon_candidates: Array = []
	for c in hand_cards:
		if not is_instance_valid(c) or c.get("card_type") != Constants.CardType.ARMA:
			continue
		var base_cost: int = int(c.card_cost) if c.get("card_cost") != null else 0
		var discounted_cost: int = maxi(base_cost - 1, 0)
		if gold_manager.puede_pagar(discounted_cost, c.card_type, c.card_raza, base_cost):
			weapon_candidates.append(c)
	if weapon_candidates.is_empty():
		_inspector._main._update_debug("No tienes ningún Arma que puedas pagar en la mano, ni con el descuento")
		return

	var weapon_data_list: Array = []
	for c in weapon_candidates:
		weapon_data_list.append(c.card_data)
	var to_play_data: Dictionary = await SelectionManager.await_single_pick(
		weapon_data_list, "Elige el Arma a jugar con 1 Oro de descuento", false)
	if to_play_data.is_empty():
		return
	var weapon_node: Node = null
	for c in weapon_candidates:
		if c.card_data == to_play_data:
			weapon_node = c
			break
	if not weapon_node:
		return

	var discard_candidates: Array = []
	for c in hand_cards:
		if c != weapon_node:
			discard_candidates.append(c)
	if discard_candidates.is_empty():
		_inspector._main._update_debug("Necesitas otra carta en tu mano para descartar como costo")
		return
	var discard_data_list: Array = []
	for c in discard_candidates:
		discard_data_list.append(c.card_data)

	var to_discard_data: Dictionary = await SelectionManager.await_single_pick(
		discard_data_list, "Descarta 1 carta para jugar %s con 1 Oro de descuento" % str(weapon_node.card_name))
	if to_discard_data.is_empty():
		return

	var discard_node: Node = null
	for c in discard_candidates:
		if c.card_data == to_discard_data:
			discard_node = c
			break
	if not discard_node:
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	await ActionModule.discard(owner_id, [discard_node], "ability_cost", true)

	var applies_to_this_card := func(c: Node) -> bool:
		return c == weapon_node
	PaymentManager.agregar_modificador_coste(weapon_node, -1, applies_to_this_card, true)
	await gold_manager.play_card(weapon_node)


func _activate_paladin_bestiarium_weapon_annul(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez en tu turno, puedes Descartar o subir un Arma que controles
	a la mano para Anular una carta de coste 1 o menos' (Paladín
	Bestiarium, 2026-08-30). Costo: elegir un Arma que controles (en
	cualquiera de tus Aliados) y decidir si se descarta o vuelve a la
	mano. Efecto: Anular una carta en juego (Aliado/Arma/Tótem, de
	cualquier jugador) de coste ≤1 — mismo destino por defecto que
	_execute_targeted_annul() (Cementerio; Destierro solo si esta carta
	dijera 'destiérrala', que no es el caso acá)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía

	var controlled_weapons: Array = []
	for field in [_inspector._main.player_field, _inspector._main.player_linea_ataque, _inspector._main.player_linea_apoyo]:
		if not field:
			continue
		for ally in field.get_children():
			var weapons = ally.get("equipped_weapons")
			if weapons is Array:
				for w in weapons:
					if is_instance_valid(w):
						controlled_weapons.append(w)
	if controlled_weapons.is_empty():
		_inspector._main._update_debug("No controlas ningún Arma para usar esta habilidad")
		return

	var weapon_data_list: Array = []
	for w in controlled_weapons:
		weapon_data_list.append(w.card_data)
	var chosen_data: Dictionary = await SelectionManager.await_single_pick(
		weapon_data_list, "Elige el Arma a Descartar o subir a tu mano", false)
	if chosen_data.is_empty():
		return
	var chosen_weapon: Node = null
	for w in controlled_weapons:
		if w.card_data == chosen_data:
			chosen_weapon = w
			break
	if not chosen_weapon:
		return

	var discard_it: bool = await SelectionManager.await_two_choice(
		_inspector._main, "Paladín Bestiarium", "Descartar el Arma", "Subir el Arma a tu mano")

	var target: Node = await TriggerSystem._targeted_executor._select_annul_target_cost_filter(
		"Elige una carta de coste 1 o menos para anular", 1)
	if not target or not is_instance_valid(target):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	if discard_it:
		# Desvincular del Aliado portador ANTES de mandarla al Cementerio
		# (2026-08-30) — CardManager.add_card_to_cemetery() no sabe de
		# equipped_weapons, así que sin esto el Aliado se quedaba con una
		# referencia colgante a un nodo ya liberado.
		var wielder = chosen_weapon.get_parent()
		if wielder and wielder.get("equipped_weapons") is Array:
			wielder.equipped_weapons.erase(chosen_weapon)
		CardManager.add_card_to_cemetery(owner_id, chosen_weapon)
	else:
		# 'Sube a tu mano' — mismo movimiento que ya usa Padre de la Patria
		# para devolver un Arma equipada a su mano.
		TriggerSystem._targeted_executor._return_equipped_weapon_to_hand(chosen_weapon, _inspector._main)

	if TriggerSystem._targeted_executor._target_text_denies(target, ["no puede ser anulad"]):
		var blocked_name: String = target.get("card_name") if target.get("card_name") != null else "Esa carta"
		_inspector._main._update_debug("%s no puede ser anulada" % blocked_name)
		return
	await ActionModule.destroy([target], source_card, true, true)
