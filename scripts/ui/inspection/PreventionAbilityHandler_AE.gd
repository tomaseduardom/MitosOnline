extends RefCounted
## PreventionAbilityHandler_AE — Mitad A-E (alfabético por nombre de carta) de
## PreventionAbilityHandler.gd, dividido por tamaño (2026-09-06, "módulos
## gordos" — mismo corte que ya separó SearchAbilityHandler_AI.gd/
## SearchAbilityHandler_JV.gd del propio SearchAbilityHandler.gd). Ver
## PreventionAbilityHandler.gd para el facade que reune esta parte con
## PreventionAbilityHandler_EP.gd y PreventionAbilityHandler_PV.gd bajo los
## mismos nombres públicos que antes — CardInspectionLayer.gd no cambió una
## sola línea por este split. Opera sobre CardInspectionLayer via _inspector
## (y sobre el Main del juego via _inspector._main).

var _inspector: CardInspectionLayer


func setup(inspector: CardInspectionLayer) -> void:
	_inspector = inspector


func _activate_akari_banish_annul_non_ally(source_card: Node, ability: Dictionary) -> void:
	"""'Puedes Desterrarlo para Anular una carta de coste 1 o menos que no
	sea Aliado' (akari, 2026-09-04) — 'Anular' ~ destruir (misma
	simplificación usada en todo el proyecto), objetivo Arma/Tótem (no
	Aliado, no Oro) de coste efectivo ≤1."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0 or not main._card_interaction:
		return  # el bot no usa esta habilidad todavía

	var filter := func(c: Node) -> bool:
		if c.get("card_type") not in [Constants.CardType.ARMA, Constants.CardType.TOTEM]:
			return false
		var parent = c.get_parent()
		var valid_zones = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
			main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]
		if parent not in valid_zones:
			return false
		return ContinuousEffectManager.get_modified_cost(c) <= 1
	var target: Node = await main._card_interaction.await_target("Elige un Arma o Tótem de coste 1 o menos para anular", filter)
	if not target or not is_instance_valid(target):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	await ActionModule.banish([source_card], source_card, true)

	if TriggerSystem._targeted_executor._target_text_denies(target, ["no puede ser anulad"]):
		main._update_debug("%s no puede ser anulada" % str(target.get("card_name")))
	else:
		await ActionModule.destroy([target], source_card, true, true)


func _activate_akuma_banish_or_draw(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, puedes Desterrar hasta dos cartas de los
	Cementerio o Roba una carta' (akuma el terrible, 2026-09-04) —
	elección A/B; 'los Cementerios' = ambos jugadores
	([[project_no_zone_means_in_play]])."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía

	var choose_banish: bool = await SelectionManager.await_two_choice(
		_inspector._main, "akuma el terrible", "Desterrar hasta dos cartas de los Cementerios", "Robar una carta")

	if choose_banish:
		var candidates: Array = []
		for player_id in [0, 1]:
			for d in CardManager.get_cemetery(player_id):
				candidates.append({"data": d, "owner": player_id})
		if candidates.is_empty():
			return
		var display_data: Array = []
		for c in candidates:
			display_data.append(c.data)
		var result: Dictionary = await SelectionManager.await_multi_pick(
			display_data, "Destierra hasta dos carta(s) de los Cementerios", 2, 0, true)
		if await TriggerSystem.open_response_window(source_card, "akuma el terrible", owner_id):
			return
		UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
		for picked_data in result.get("picked", []):
			var owner_of_picked: int = 0
			for c in candidates:
				if c.data == picked_data:
					owner_of_picked = c.owner
					break
			var idx: int = CardManager.get_cemetery(owner_of_picked).find(picked_data)
			if idx < 0:
				continue
			CardManager.remove_from_cemetery(owner_of_picked, idx)
			CardManager.add_to_exile(owner_of_picked, picked_data)
	else:
		if await TriggerSystem.open_response_window(source_card, "akuma el terrible", owner_id):
			return
		UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
		await ActionModule.draw(owner_id, 1, "activated_ability", true)


## _activate_almirante_akari_shuffle_annul_or_prevent() eliminada
## (2026-09-09, "sistema de respuestas" — corregido a pedido del usuario:
## Akari no es una elección A/B proactiva, son dos disparadores reactivos
## distintos). "Prevenir" ahora vive en EffectController._prevention_registry
## (mismo mecanismo que Estaca, solo Aliados); "Anular cuando el rival juega
## una carta" vive en EffectController.offer_counter_annul(), llamado desde
## GoldManager._trigger_enter_play()/EasyBotController._play_ally() justo
## después de que la carta jugada entra en juego. Ambas comparten el costo
## (barajar 1 carta propia) vía EffectController._pay_akari_shuffle_cost().


## _activate_angel_redentor_prevent() eliminada (2026-09-09, "sistema de
## respuestas"): ya no es un botón — EffectController.offer_prevention()
## la detecta y ofrece reactivamente (tags "annul"/"cancel"), con su propio
## candado de una vez por turno vía turn_registry en el 'is_available' del
## registro (ver EffectController.gd).


func _activate_atenea_grant_double_damage_exile(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, un Aliado hace doble daño de combate al
	Destierro este turno' (atenea en wonderland, 2026-09-04) — otorga
	Card.doubles_damage_to_exile TEMPORALMENTE (solo este turno) a un
	Aliado elegido (propio o rival, el texto no lo restringe), vía
	GameManager.turn_started para limpiarlo (mismo patrón que el Exhumar
	temporal de sumi el terrible)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0 or not main._card_interaction:
		return  # el bot no usa esta habilidad todavía

	var filter := func(c: Node) -> bool:
		if c.get("card_type") != Constants.CardType.ALIADO:
			return false
		var parent = c.get_parent()
		var valid_zones = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
			main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]
		return parent in valid_zones
	var target: Node = await main._card_interaction.await_target("Elige un Aliado que haga doble daño de combate al Destierro este turno", filter)
	if not target or not is_instance_valid(target):
		return
	if await TriggerSystem.open_response_window(source_card, "atenea en wonderland", owner_id):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	target.doubles_damage_to_exile = true
	var clear_it: Callable
	clear_it = func(started_player_id: int, _turn: int) -> void:
		if started_player_id != owner_id:
			return
		if is_instance_valid(target):
			target.doubles_damage_to_exile = false
		if GameManager.turn_started.is_connected(clear_it):
			GameManager.turn_started.disconnect(clear_it)
	GameManager.turn_started.connect(clear_it)


func _activate_belta_barajar_desterrar(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, Baraja y/o Destierra hasta dos cartas de los
	Cementerios' (Belta, 2026-09-04) — reusa GoldManager._resolve_armeria_
	barajar_desterrar() genérica, sin costo (a diferencia de Armería, acá
	no hay condición previa)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía
	# _resolve_armeria_barajar_desterrar() resuelve elección intercalada
	# carta-por-carta sin un punto limpio de "declarar todo antes de
	# ejecutar" (mismo motivo por el que quedó diferida en el barrido de
	# triggers) — se gatea con UNA ventana ANTES de arrancar toda la
	# resolución en vez de reescribir el helper compartido.
	if await TriggerSystem.open_response_window(source_card, "Belta", owner_id):
		return
	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	await _inspector._main._gold_manager._resolve_armeria_barajar_desterrar(2, "Belta")


func _activate_belta_self_banish_revive(source_card: Node, ability: Dictionary) -> void:
	"""'Puedes Desterrar dos cartas de tu Cementerio para ponerlo en juego
	desde tu Cementerio como un Aliado sin habilidad de Fuerza 2' (Belta,
	2026-09-04) — costo: desterrar 2 cartas CUALQUIERA de tu Cementerio
	(no incluye a Belta misma, que está siendo jugada desde ahí). Efecto:
	Belta deja de ser el Oro y pasa a ser un Aliado Fuerza 2 sin
	habilidad, en juego."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía
	if source_card.get("current_zone") != Constants.Zone.CEMENTERIO:
		main._update_debug("Belta ya no está en tu Cementerio")
		return

	var cemetery: Array = CardManager.get_cemetery(owner_id)
	var others: Array = cemetery.filter(func(d): return d != source_card.card_data)
	if others.size() < 2:
		main._update_debug("Necesitas otras 2 cartas en tu Cementerio para desterrar")
		return
	var result: Dictionary = await SelectionManager.await_multi_pick(
		others, "Destierra 2 cartas de tu Cementerio para poner a Belta en juego", 2, 2, true)
	if result.get("picked", []).size() < 2:
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	for picked_data in result.picked:
		var idx: int = CardManager.get_cemetery(owner_id).find(picked_data)
		if idx >= 0:
			CardManager.remove_from_cemetery(owner_id, idx)
			CardManager.add_to_exile(owner_id, picked_data)

	var self_idx: int = CardManager.get_cemetery(owner_id).find(source_card.card_data)
	if self_idx >= 0:
		CardManager.remove_from_cemetery(owner_id, self_idx)

	var ally_data: Dictionary = source_card.card_data.duplicate()
	ally_data["tipo"] = Constants.CardType.ALIADO
	ally_data["fuerza"] = 2
	ally_data["habilidad"] = ""
	var ally_node = main._create_card(ally_data, false)
	ally_node.owner_id = owner_id
	main._connect_card_signals(ally_node)
	await main._gold_manager._play_card_to_field(ally_node)


func _activate_campanita_banish_cancel_or_draw(source_card: Node, ability: Dictionary) -> void:
	"""'Puedes Desterrarlo para cancelar una habilidad o Robar dos cartas'
	(Campanita, 2026-09-04) — elección A/B. 'Cancelar la habilidad' ~
	silenciar (misma simplificación de Frankenstein/Red de Plata/Sheut),
	sin restricción de coste ni tipo (a diferencia de Frankenstein, que sí
	las tiene en su propio texto)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía

	var choose_cancel: bool = await SelectionManager.await_two_choice(
		main, "Campanita", "Desterrarla para cancelar una habilidad", "Desterrarla para Robar dos cartas")

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

	# Rama "roba dos": a diferencia de la de cancelar (protegida después por
	# silence_card()), el Robo no tiene cobertura propia — la ventana va ACÁ,
	# antes del autodestierro de más abajo (2026-09-10), porque después
	# source_card queda inválida para open_response_window().
	if not choose_cancel and await TriggerSystem.open_response_window(source_card, "Campanita", owner_id):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	await ActionModule.banish([source_card], source_card, true)

	if choose_cancel and target:
		if TriggerSystem._targeted_executor._target_text_denies(target, ["no puede perder su habilidad", "no pierde su habilidad"]):
			main._update_debug("%s no pierde su habilidad" % str(target.get("card_name")))
		else:
			await KeywordManager.silence_card(target, source_card, "permanent")
	else:
		await ActionModule.draw(owner_id, 2, "activated_ability", true)


func _activate_crono_diamante_discard_ally_discount(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, si jugaste un Aliado de coste 2 o más este
	turno puedes Descartar una carta para jugar un Aliado reduciendo su
	coste en un Oro, hasta un mínimo de 1' (Crono Diamante, 2026-09-02 —
	verificado contra la API, sin discrepancias con el cache local).
	Condición previa (GoldManager._play_card_to_field() registra
	'played_ally_cost2plus:0' cada vez que se juega un Aliado de coste ≥2,
	sin importar el origen — mano/Exhumar/gratis). Costo: descartar 1
	carta CUALQUIERA de la mano. Efecto: jugar OTRA carta de la mano (un
	Aliado) con -1 Oro, piso 1 — a diferencia de Paladín Bestiarium
	(_activate_paladin_bestiarium_discard_weapon_discount(), mismo
	esqueleto), el texto NO dice 'hasta un mínimo de 0', así que
	allow_zero queda en false. 'Puedes X para Y' es atómico (2026-08-31,
	mismo criterio ya aplicado a Padre de la Patria/Paladín Bestiarium):
	solo se ofrecen como candidatas las Aliados que YA son pagables con
	el descuento aplicado, filtrado antes de preguntar qué descartar."""
	if not is_instance_valid(source_card) or not _inspector._main._gold_manager:
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0 or not _inspector._main.player_hand or _inspector._main.player_hand.cards.is_empty():
		return  # el bot no usa esta habilidad todavía

	if not UniversalCardParser.turn_registry.was_used("played_ally_cost2plus:%d" % owner_id, 0, GameManager.current_turn):
		_inspector._main._update_debug("Necesitas haber jugado un Aliado de coste 2 o más este turno")
		return

	var hand_cards: Array = _inspector._main.player_hand.cards.duplicate()
	var gold_manager: GoldManager = _inspector._main._gold_manager

	var ally_candidates: Array = []
	for c in hand_cards:
		if not is_instance_valid(c) or c.get("card_type") != Constants.CardType.ALIADO:
			continue
		var base_cost: int = int(c.card_cost) if c.get("card_cost") != null else 0
		var discounted_cost: int = maxi(base_cost - 1, 1)
		if gold_manager.puede_pagar(discounted_cost, c.card_type, c.card_raza, base_cost):
			ally_candidates.append(c)
	if ally_candidates.is_empty():
		_inspector._main._update_debug("No tienes ningún Aliado que puedas pagar en la mano, ni con el descuento")
		return

	var ally_data_list: Array = []
	for c in ally_candidates:
		ally_data_list.append(c.card_data)
	var to_play_data: Dictionary = await SelectionManager.await_single_pick(
		ally_data_list, "Elige el Aliado a jugar con 1 Oro de descuento", false)
	if to_play_data.is_empty():
		return
	var ally_node: Node = null
	for c in ally_candidates:
		if c.card_data == to_play_data:
			ally_node = c
			break
	if not ally_node:
		return

	var discard_candidates: Array = []
	for c in hand_cards:
		if c != ally_node:
			discard_candidates.append(c)
	if discard_candidates.is_empty():
		_inspector._main._update_debug("Necesitas otra carta en tu mano para descartar como costo")
		return
	var discard_data_list: Array = []
	for c in discard_candidates:
		discard_data_list.append(c.card_data)

	var to_discard_data: Dictionary = await SelectionManager.await_single_pick(
		discard_data_list, "Descarta 1 carta para jugar %s con 1 Oro de descuento" % str(ally_node.card_name))
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
		return c == ally_node
	PaymentManager.agregar_modificador_coste(ally_node, -1, applies_to_this_card, false)
	await gold_manager.play_card(ally_node)


## _activate_dracula_convert_for_prevention() eliminada (2026-09-09,
## "sistema de respuestas"): ya no es un botón — EffectController.
## offer_prevention()/offer_prevention_for_player() detecta a Drácula
## (sin convertir, en juego) y ofrece reactivamente (tags "cancel"/"annul")
## en el momento exacto; el 'on_used' del registro hace el auto-convertir +
## silenciar que antes pasaba acá.


func _activate_dulce_canasta(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, un Aliado gana o pierde 2 de Fuerza
	permanentemente' (Dulce Canasta, 2026-09-04). Sin costo. Cualquier
	Aliado en juego, propio o rival (sin calificador de dueño en el
	texto). 'permanentemente' = mismo molde que Espada del Juicio:
	source=target, sobrevive aunque Dulce Canasta salga de juego."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía
	var target: Node = await TriggerSystem._targeted_executor._select_ally_target(
		"Elige un Aliado que gane o pierda 2 de Fuerza permanentemente", source_card)
	if not target or not is_instance_valid(target):
		return
	var gains: bool = await SelectionManager.await_two_choice(
		_inspector._main, "Dulce Canasta", "Gana 2 de Fuerza", "Pierde 2 de Fuerza")
	# Solo el débuff es prevenible (2026-09-09 — Estaca, tag "strength_change")
	# — un buff no es un efecto hostil que valga la pena bloquear.
	if not gains and await EffectController.offer_prevention(target, source_card, "strength_change"):
		return
	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	ContinuousEffectManager.register_modifier({
		"source": target,
		"target": target,
		"type": ContinuousEffectManager.ModifierType.STRENGTH,
		"stat": "strength",
		"value": 2 if gains else -2,
		"operation": "add",
		"duration": ContinuousEffectManager.ModifierDuration.PERMANENT,
		"layer": ContinuousEffectManager.ModifierLayer.LAYER_7B_CHAR_MODIFY,
		"description": "%s de Dulce Canasta" % ("Buff" if gains else "Debuff"),
	})


func _activate_ereshkigal_banish_cost1_or_cemeteries(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, puedes Desterrar una carta de coste 1 o menos o
	Barajar y/o Desterrar dos cartas de los Cementerios' (ereshkigal,
	2026-09-04) — elección A/B; B reusa GoldManager._resolve_armeria_
	barajar_desterrar() genérica (ya generalizada para Belta/Perla de
	Sangre)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía

	var choose_banish: bool = await SelectionManager.await_two_choice(
		_inspector._main, "ereshkigal", "Desterrar una carta de coste 1 o menos", "Barajar y/o Desterrar hasta dos cartas de los Cementerios")

	if choose_banish:
		var target: Node = await TriggerSystem._targeted_executor._select_banish_target_cost_filter(
			"Elige una carta de coste 1 o menos para desterrar", 1)
		if not target or not is_instance_valid(target):
			return
		UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
		await ActionModule.banish([target], source_card, true)
	else:
		if await TriggerSystem.open_response_window(source_card, "ereshkigal", owner_id):
			return
		UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
		await _inspector._main._gold_manager._resolve_armeria_barajar_desterrar(2, "ereshkigal")


func _activate_espada_ohiggins_shuffle_or_search_gold(source_card: Node, ability: Dictionary) -> void:
	"""'En tu Vigilia, una vez por turno, puedes Barajar una carta que no
	sea Oro o buscar un Oro en tu Castillo y ponerlo en tu mano' (Espada
	de O'Higgins, 2026-09-04) — elección A/B."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0 or not main._card_interaction:
		return  # el bot no usa esta habilidad todavía

	var choose_shuffle: bool = await SelectionManager.await_two_choice(
		main, "Espada de O'Higgins", "Barajar una carta que no sea Oro", "Buscar un Oro en tu Castillo")

	if choose_shuffle:
		var filter := func(c: Node) -> bool:
			if c.get("card_type") == Constants.CardType.ORO:
				return false
			var parent = c.get_parent()
			var valid_zones = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
				main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]
			return parent in valid_zones
		var target: Node = await main._card_interaction.await_target("Elige una carta que no sea Oro para barajar", filter)
		if not target or not is_instance_valid(target):
			return
		UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
		var target_owner: int = target.controller_id if target.get("controller_id") != null else owner_id
		if await ActionModule.return_to_deck(target, target_owner, true, source_card):
			CardManager.shuffle_deck(target_owner)
	else:
		if await TriggerSystem.open_response_window(source_card, "Espada de O'Higgins", owner_id):
			return
		UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
		await ActionModule.search(owner_id, Constants.Zone.CASTILLO, {"type": Constants.CardType.ORO}, 1, true, false, false, source_card, Constants.Zone.MANO)


func _activate_espiritu_maquina_shuffle_or_banish_cemetery(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, puedes Barajar o Desterrar una carta de un
	Cementerio' (Espíritu de la Máquina, 2026-09-04) — 'un Cementerio' =
	elegí CUÁL (propio o rival), no ambos ([[project_y_o_means_choose_one_zone]]
	mismo criterio aplicado a 'un' singular). Macu comparte el mismo texto
	('Una vez en tu turno, ...') y este mismo handler (2026-09-07, bug real
	encontrado en auditoría: el diálogo de Barajar/Desterrar tenía el título
	'Espíritu de la Máquina' hardcodeado, mostrándose igual cuando activaba
	Macu — ahora usa el nombre real de la carta)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía
	var pick_own: bool = await SelectionManager.await_two_choice(
		main, "¿En qué Cementerio?", "Tu Cementerio", "Cementerio del oponente")
	var target_owner: int = owner_id if pick_own else 1 - owner_id
	var cemetery: Array = CardManager.get_cemetery(target_owner)
	if cemetery.is_empty():
		main._update_debug("Ese Cementerio está vacío")
		return
	var picked_data: Dictionary = await SelectionManager.await_single_pick(
		cemetery.duplicate(), "Elige una carta de ese Cementerio", false)
	if picked_data.is_empty():
		return
	var barajar: bool = await SelectionManager.await_two_choice(
		main, source_card.card_name if source_card.get("card_name") else "Esa carta", "Barajarla", "Desterrarla")
	var idx: int = CardManager.get_cemetery(target_owner).find(picked_data)
	if idx < 0:
		return
	if await TriggerSystem.open_response_window(source_card, str(source_card.card_name) if source_card.get("card_name") else "Espíritu de la Máquina", owner_id):
		return
	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	CardManager.remove_from_cemetery(target_owner, idx)
	if barajar:
		CardManager.get_deck(target_owner).append(picked_data)
		CardManager.shuffle_deck(target_owner)
	else:
		CardManager.add_to_exile(target_owner, picked_data)
