extends RefCounted
## SearchAbilityHandler_JV — Mitad J-V (alfabético por nombre de carta) de
## SearchAbilityHandler.gd, dividido por tamaño (2026-09-06, "módulos gordos"
## — mismo corte que ya separó BernardoAbilityHandler/HandCementerioAbilityHandler
## del propio CardInspectionLayer.gd). Ver SearchAbilityHandler.gd para el
## facade que reune esta mitad y SearchAbilityHandler_AI.gd bajo los mismos
## nombres públicos que antes — CardInspectionLayer.gd no cambió una sola
## línea por este split. Opera sobre CardInspectionLayer via _inspector (y
## sobre el Main del juego via _inspector._main).

var _inspector: CardInspectionLayer


func setup(inspector: CardInspectionLayer) -> void:
	_inspector = inspector


func _activate_jinete_peste_search_banish_two(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, busca en un Castillo dos cartas de distinto
	nombre y Destiérralas. Si controlas otro Jinete, además Roba una
	carta' (Jinete de la Peste, 2026-09-06) — 'un Castillo' sin posesivo =
	a elección. 'Si controlas cuatro Aliados Jinete, tu oponente no puede
	poner cartas en su mano por efectos' NO implementado (restricción
	global nueva)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0 or not TriggerSystem._targeted_executor:
		return  # el bot no usa esta habilidad todavía

	if await TriggerSystem.open_response_window(source_card, "Jinete de la Peste", owner_id):
		return
	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	var zone_owner: int = await TriggerSystem._targeted_executor._choose_search_zone_owner(owner_id, Constants.Zone.CASTILLO)
	await ActionModule.search(zone_owner, Constants.Zone.CASTILLO, {}, 2, true, false, false, source_card, Constants.Zone.DESTIERRO, true)

	var main := _inspector._main
	var controls_other_jinete := false
	for field in [main.player_field, main.player_linea_ataque]:
		if not field:
			continue
		for c in field.get_children():
			if is_instance_valid(c) and c != source_card and "jinete" in str(c.get("card_name")).to_lower():
				controls_other_jinete = true
	if controls_other_jinete:
		await ActionModule.draw(owner_id, 1, "activated_ability", true)


func _activate_kotaix_draw_and_shuffle_opponent(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, Roba dos cartas y Baraja una carta oponente que
	no sea Oro. Esta habilidad no puede ser cancelada.' (Espíritu Kotaix,
	2026-09-02 — segunda habilidad, verificada contra la API, sin
	discrepancias con el cache local). 'Una carta oponente' sin zona = EN
	JUEGO (ver [[project_no_zone_means_in_play]]), excluyendo Oro. Sin
	'puedes': el Robo es incondicional; unido por 'y' (no 'Luego'), así que
	sucede siempre sin importar si hay o no un objetivo rival válido para
	barajar — mismo criterio ya usado en Estaca (idéntico patrón, ver
	_activate_estaca_draw_and_shuffle() en HandCementerioAbilityHandler.gd)
	y en Espada de O'Higgins/Aho. 'No puede ser cancelada' queda satisfecho
	por construcción: esta habilidad se resuelve directo acá, sin pasar por
	la Pila/ActionPipeline (igual que el resto de patrones especiales de
	este archivo), así que nunca entra al camino que StackVisualizer.gd usa
	para poder cancelar una habilidad de la pila."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía
	# Ventana única para toda la habilidad (2026-09-10): sin declare real
	# todavía acá (el objetivo rival recién se elige más abajo), mismo
	# criterio que Estaca (HandCementerioAbilityHandler.gd).
	if await TriggerSystem.open_response_window(source_card, "Espíritu Kotaix", owner_id):
		return

	await ActionModule.draw(owner_id, 2, "activated_ability", true)

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

	await ActionModule.return_to_deck(target, opponent_id, true, source_card)
	CardManager.shuffle_deck(opponent_id)


func _activate_kuchiku_cazador_search_and_play_discount(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez en tu turno, busca en tu Castillo o Cementerio un Aliado y
	juégalo reduciendo su coste en un Oro, hasta un mínimo de 0' (Kuchiku
	El Cazador, myl_id 20593, edición kvsm_titanes). 'Castillo o
	Cementerio' es 'y/o' entre zonas ([[project_y_o_means_choose_one_zone]])
	— el jugador elige UNA, no se combinan en un solo pool. Reusa
	ActionModule.search() para la mecánica de búsqueda/UI/barajado del
	Castillo (must_shuffle ya incluido), con may_play=false para poder
	aplicar el descuento de coste ANTES de intentar jugarla — mismo
	mecanismo puntual que Miguel (_activate_miguel_discount_play): -1 Oro,
	piso 0 (acá con allow_zero=true porque el texto SÍ dice explícitamente
	'hasta un mínimo de 0'). La carta encontrada se identifica comparando
	la mano antes/después de la búsqueda (ActionModule.search() no
	devuelve el Card node creado, solo el Dictionary de datos)."""
	if not is_instance_valid(source_card) or not _inspector._main._gold_manager:
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0 or not _inspector._main.player_hand:
		return  # el bot no usa esta habilidad todavía

	var search_castillo: bool = await SelectionManager.await_two_choice(
		_inspector._main, "¿Dónde buscar un Aliado?", "Tu Castillo", "Tu Cementerio")
	var zone := Constants.Zone.CASTILLO if search_castillo else Constants.Zone.CEMENTERIO

	var hand_before: Array = _inspector._main.player_hand.cards.duplicate()
	var result: Dictionary = await ActionModule.search(
		owner_id, zone, {"type": Constants.CardType.ALIADO}, 1, true, false, false, source_card, Constants.Zone.MANO)
	if result.get("selected", []).is_empty():
		_inspector._main._update_debug("No se encontró ningún Aliado ahí")
		return

	var card_node: Node = null
	for c in _inspector._main.player_hand.cards:
		if c not in hand_before:
			card_node = c
			break
	if not is_instance_valid(card_node):
		return

	var applies_to_this_card := func(c: Node) -> bool:
		return c == card_node
	PaymentManager.agregar_modificador_coste(card_node, -1, applies_to_this_card, true)
	if card_node.has_method("refresh_cost_badge"):
		card_node.refresh_cost_badge()

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	await _inspector._main._gold_manager.play_card(card_node)


func _activate_kuchiku_cazador_destroy_and_discard(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez en tu turno, puedes Destruir hasta una carta de coste 3 o
	menos y tu oponente Bota cartas igual a la Fuerza de este Aliado'
	(Kuchiku El Cazador). Objetivo genérico en juego (Aliado/Arma/Tótem/
	Oro, ambos jugadores) con tope de coste 3 — a diferencia de
	_select_annul_target_cost_filter() (que excluye Oro porque 'anular' un
	Oro no tiene sentido), acá SÍ puede ser Oro (destruirlo sí tiene
	sentido). 'Hasta una carta' = el Destruir es opcional (0 o 1, cancelar
	el picker = 0), pero el descarte del oponente NO está condicionado a
	que el Destruir se concrete — son dos cláusulas independientes unidas
	por 'y', ambas dentro del mismo 'puedes' de activar la habilidad
	(clickear el botón ya es esa confirmación, mismo criterio que Espada
	de O'Higgins). Cantidad de descarte dinámica: la Fuerza ACTUAL de este
	Aliado (con modificadores continuos aplicados) — reusa
	_execute_targeted_discard() para el descarte en sí (mano del
	oponente; si el humano es quien descarta, él elige cuáles)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía
	var main := _inspector._main
	if not main or not main._card_interaction:
		return

	var filter := func(c: Node) -> bool:
		if c.get("card_type") not in [Constants.CardType.ALIADO, Constants.CardType.ARMA, Constants.CardType.TOTEM, Constants.CardType.ORO]:
			return false
		var parent = c.get_parent()
		var valid_zones = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
			main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo,
			main.player_gold, main.opponent_gold]
		if parent not in valid_zones:
			return false
		# get_modified_cost(), no card_cost crudo (2026-09-04, a pedido del
		# usuario: una carta en juego puede tener el coste reducido de forma
		# continua, p.ej. Samael — el filtro tiene que verlo).
		return ContinuousEffectManager.get_modified_cost(c) <= 3
	var chosen_target: Node = await main._card_interaction.await_target(
		"Elige una carta de coste 3 o menos para destruir (opcional)", filter)

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	if chosen_target and is_instance_valid(chosen_target):
		if not TriggerSystem._targeted_executor._target_text_denies(chosen_target, ["no puede ser destruid"]):
			await ActionModule.destroy([chosen_target], source_card, true, true)

	var strength: int = ContinuousEffectManager.get_modified_strength(source_card)
	if strength > 0:
		await TriggerSystem._targeted_executor._execute_targeted_discard(source_card, owner_id, strength)


func _activate_lider_del_comite_discard_look_name_lock(source_card: Node, ability: Dictionary) -> void:
	"""'En tu Vigilia, una vez por turno, puedes Descartar una carta para
	mirar la mano de tu oponente y nombrar una carta. Las cartas con ese
	nombre pierden su habilidad y tu oponente no puede jugarlas el próximo
	turno' (lider del comite, 2026-09-04). Costo: Descartar 1 carta propia.
	Efecto: revelado informativo de la mano rival (SelectionManager.
	open_reveal, no interactivo — 'mirar' no exige elegir de ahí, el nombre
	puede ser cualquier carta) + KeywordManager.lock_ability_by_name()
	(TODAS las copias, presentes o futuras, mientras esta carta siga en
	juego) + GoldManager.lock_card_from_playing() sobre cada copia YA
	visible en la mano rival con ese nombre (las que lleguen después vía
	robo no quedan bloqueadas — límite conocido, caso borde poco común)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0 or not _inspector._main.player_hand or _inspector._main.player_hand.cards.is_empty():
		return  # el bot no usa esta habilidad todavía; sin mano no hay costo que pagar

	var hand_cards: Array = _inspector._main.player_hand.cards.duplicate()
	var card_data_list: Array = []
	for c in hand_cards:
		card_data_list.append(c.card_data)
	var picked_to_discard: Dictionary = await SelectionManager.await_single_pick(
		card_data_list, "Descarta 1 carta de tu mano")
	if picked_to_discard.is_empty():
		return  # canceló — no paga el costo

	var to_discard_node: Node = null
	for c in hand_cards:
		if c.card_data == picked_to_discard:
			to_discard_node = c
			break
	if not to_discard_node:
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	await ActionModule.discard(owner_id, [to_discard_node], "activated_ability", true)

	var opponent_hand: Array = []
	if _inspector._main._opponent_fan and _inspector._main._opponent_fan.has_method("get_cards"):
		opponent_hand = _inspector._main._opponent_fan.get_cards()
	var opponent_hand_data: Array = []
	for c in opponent_hand:
		if is_instance_valid(c):
			opponent_hand_data.append(c.card_data)
	if not opponent_hand_data.is_empty():
		SelectionManager.open_reveal(opponent_hand_data, "Mano de tu oponente")

	var picked_card: Dictionary = await TriggerSystem._card_name_search.open_and_wait(
		"Nombra una carta: pierde su habilidad y tu oponente no puede jugarla el próximo turno"
	)
	if picked_card.is_empty():
		return
	var picked_name: String = str(picked_card.get("nombre", ""))
	if picked_name.is_empty():
		return
	if await TriggerSystem.open_response_window(source_card, "lider del comite", owner_id):
		return

	KeywordManager.lock_ability_by_name(picked_name, source_card)
	for c in opponent_hand:
		if is_instance_valid(c) and str(c.get("card_name")).to_lower() == picked_name.to_lower():
			# owner_id (activador), no el rival: lock_card_from_playing() limpia
			# el candado cuando empieza el turno de 'locking_player_id' — igual
			# que Chakram, "hasta tu próximo turno" = dura el turno rival
			# intermedio completo, se limpia al iniciar mi turno siguiente.
			_inspector._main._gold_manager.lock_card_from_playing(c, owner_id)
	_inspector._main._update_debug("'%s' pierde su habilidad y no puede jugarse el próximo turno" % picked_name)


func _activate_miguel_discount_play(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez en tu turno, juega una carta de tu mano o de un Cementerio
	reduciendo su coste en un Oro, hasta un mínimo de 0' (Miguel,
	2026-08-29). 'Un Cementerio' sin posesivo = cualquiera de los dos, el
	propio o el rival (confirmado por el usuario) — jugarla la vuelve TUYA
	(owner_id del activador), sea de donde sea que salió. Reusa
	GoldManager.play_card() completo (fases, portador de Armas, Talismanes,
	pago real) con un descuento de -1/piso 0 aplicado solo a la carta
	elegida — mismo mecanismo que 'Muestra X para reducir el coste' (El Rey
	y el Verdugo, ya resuelto dentro de GoldManager.play_card())."""
	if not is_instance_valid(source_card) or not _inspector._main._gold_manager:
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0 or not _inspector._main.player_hand:
		return  # el bot no usa esta habilidad todavía

	var candidates: Array = []
	for c in _inspector._main.player_hand.cards:
		candidates.append({"data": c.card_data, "from": "hand", "node": c, "cemetery_owner": -1})
	for cemetery_owner in [0, 1]:
		for data in CardManager.get_cemetery(cemetery_owner):
			candidates.append({"data": data, "from": "cemetery", "node": null, "cemetery_owner": cemetery_owner})

	# Filtro de asequibilidad ANTES de ofrecer la carta como opción (2026-09-08,
	# bug real reportado por el usuario: dejaba elegir un Arma que no podía
	# pagar ni con el descuento, y GoldManager.play_card() la rechazaba recién
	# al final sin buena UX) — mismo criterio que Tangata Manu/
	# _make_look_play_free_filter ya usan para no ofrecer nunca una opción
	# que se sabe de antemano que no se puede pagar. Aproximado con el dato
	# crudo de coste (no hay nodo todavía para las candidatas de Cementerio,
	# así que no se puede calcular_coste_real() con modificadores reales).
	var available_gold: int = GameState.get_oro_reserva(0) + _inspector._main._gold_manager.oros_virtuales
	candidates = candidates.filter(func(c: Dictionary) -> bool:
		var raw_cost = c.data.get("coste")
		if raw_cost == null or not (raw_cost is int or raw_cost is float or (raw_cost is String and raw_cost.is_valid_int())):
			return true  # Oro u otra carta sin coste numérico real
		var discounted: int = maxi(int(raw_cost) - 1, 0)
		return discounted <= available_gold
	)
	if candidates.is_empty():
		_inspector._main._update_debug("No tienes ninguna carta que puedas pagar ni con el descuento")
		return

	var display_data: Array = []
	for c in candidates:
		display_data.append(c.data)

	var picked: Dictionary = await SelectionManager.await_single_pick(
		display_data, "Elige una carta (tu mano o cualquier Cementerio) para jugar con 1 Oro de descuento")
	if picked.is_empty():
		return

	var chosen: Dictionary = {}
	for c in candidates:
		if c.data == picked:
			chosen = c
			break
	if chosen.is_empty():
		return

	var card_node: Node = chosen.node
	if chosen.from == "cemetery":
		var cemetery_owner: int = chosen.cemetery_owner
		var idx: int = CardManager.get_cemetery(cemetery_owner).find(chosen.data)
		if idx < 0:
			return
		CardManager.remove_from_cemetery(cemetery_owner, idx)
		card_node = _inspector._main._create_card(chosen.data, false)
		# Dueño real = de qué Cementerio salió, NO quien la juega (2026-08-29,
		# corregido a pedido del usuario): jugar una carta ajena te vuelve
		# CONTROLADOR, no dueño — si es Aliado/Tótem/Arma/Oro pelea de tu
		# lado, pero si sale de juego (destruida/desterrada) vuelve al
		# Cementerio/Destierro de su dueño original, no al tuyo. GoldManager.
		# play_card() coloca todo del lado del jugador 0 sin mirar owner_id
		# (siempre fue solo para el jugador humano), así que esto no afecta
		# en qué lado del tablero aparece — solo a dónde vuelve si muere.
		card_node.owner_id = cemetery_owner
		card_node.controller_id = owner_id
		_inspector._main.player_hand.add_card(card_node)
		_inspector._main._connect_card_signals(card_node)

	if not is_instance_valid(card_node):
		return

	var applies_to_this_card := func(c: Node) -> bool:
		return c == card_node
	PaymentManager.agregar_modificador_coste(card_node, -1, applies_to_this_card, true)
	if card_node.has_method("refresh_cost_badge"):
		card_node.refresh_cost_badge()

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	await _inspector._main._gold_manager.play_card(card_node)


func _activate_padre_patria_gold(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez en tu turno, genera un Oro para jugar Armas o Aliados
	Caballero por el turno' (Padre de la Patria, 2026-08-28). Sin coste ni
	objetivo — se genera directo como Oro Virtual restringido
	(GoldManager.restricted_gold_pools) y se marca usada este turno."""
	if not is_instance_valid(source_card) or not _inspector._main._gold_manager:
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if await TriggerSystem.open_response_window(source_card, "Padre de la Patria", owner_id):
		return
	var predicate := func(card_type: int, card_race: String, _card_cost: int) -> bool:
		if card_type == Constants.CardType.ARMA:
			return true
		if card_type == Constants.CardType.ALIADO:
			return "caballero" in card_race.to_lower()
		return false
	_inspector._main._gold_manager.generar_oro_virtual_restringido(1, predicate, "Armas o Aliados Caballero")

	# instance_id (2026-08-30), no card_data.id — cada copia física necesita
	# su propio cupo de 'una vez por turno'.
	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)


func _activate_quimera_voragh_mill_and_revive(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez en tu turno, cada jugador Bota tres cartas. Si se Botaron
	Aliados u Oros, pon en juego una carta de un Cementerio como un Aliado
	de Fuerza 2 con la habilidad "Furia"' (quimera voragh, 2026-09-06).
	Botar (mill a Cementerio) manipulado directo sobre CardManager, no
	ActionModule.mill() — su fallback sin GameBoard no informa tipos por
	carta (ver el comentario de ea poe), y acá SÍ hace falta saber si algo
	Aliado/Oro cayó para condicionar el resto. La conversión reusa el
	mismo mecanismo que leon indiferente/Sherlock Holmes (Fuerza fijada +
	KeywordManager.silence_card para quitar la habilidad original +
	Furia)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía

	if await TriggerSystem.open_response_window(source_card, "quimera voragh", owner_id):
		return
	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	var ally_or_gold_milled := false
	for player_id in [0, 1]:
		var deck: Array = CardManager.get_deck(player_id)
		var cemetery: Array = CardManager.get_cemetery(player_id)
		for i in range(3):
			if deck.is_empty():
				break
			var card_data: Dictionary = deck.pop_front()
			card_data["esta_oculta"] = false
			var tipo: int = card_data.get("tipo", -1)
			if tipo == Constants.CardType.ALIADO or tipo == Constants.CardType.ORO:
				ally_or_gold_milled = true
			cemetery.append(card_data)
		CardManager._emit_deck_changed(player_id)
		CardManager._emit_cemetery_changed(player_id)

	if not ally_or_gold_milled:
		return

	var cemetery_candidates: Array = []
	for player_id in [0, 1]:
		for d in CardManager.get_cemetery(player_id):
			cemetery_candidates.append({"data": d, "owner": player_id})
	if cemetery_candidates.is_empty():
		return
	var display_data: Array = cemetery_candidates.map(func(c): return c.data)
	var picked: Dictionary = await SelectionManager.await_single_pick(
		display_data, "Elige una carta de un Cementerio para poner en juego como Aliado de Fuerza 2 con Furia", true, 0)
	if picked.is_empty():
		return
	var chosen: Dictionary = {}
	for c in cemetery_candidates:
		if c.data == picked:
			chosen = c
			break
	if chosen.is_empty():
		return

	var idx: int = CardManager.get_cemetery(chosen.owner).find(picked)
	if idx < 0:
		return
	CardManager.remove_from_cemetery(chosen.owner, idx)

	var new_data: Dictionary = picked.duplicate()
	new_data["tipo"] = Constants.CardType.ALIADO
	new_data["esta_oculta"] = false
	var token_node = main._create_card(new_data, false)
	token_node.owner_id = owner_id
	main._connect_card_signals(token_node)
	var target_field: HBoxContainer = main.player_field if owner_id == 0 else main.opponent_field
	target_field.add_child(token_node)
	token_node.can_interact = (owner_id == 0)
	token_node.top_level = false
	token_node.set_zone(Constants.Zone.LINEA_DEFENSA)
	token_node.is_converted = true
	await KeywordManager.silence_card(token_node, source_card, "permanent")
	ContinuousEffectManager.register_modifier({
		"source": source_card,
		"target": token_node,
		"type": ContinuousEffectManager.ModifierType.STRENGTH,
		"stat": "strength",
		"value": 2,
		"operation": "set",
		"duration": ContinuousEffectManager.ModifierDuration.PERMANENT,
		"layer": ContinuousEffectManager.ModifierLayer.LAYER_7A_CHAR_SETTING,
		"description": "Convertido por quimera voragh (Fuerza fija 2)",
	})
	ContinuousEffectManager.register_modifier({
		"source": source_card,
		"target": token_node,
		"type": ContinuousEffectManager.ModifierType.KEYWORDS,
		"stat": "",
		"value": 0,
		"operation": "add",
		"duration": ContinuousEffectManager.ModifierDuration.PERMANENT,
		"layer": ContinuousEffectManager.ModifierLayer.LAYER_6_ABILITIES,
		"keywords_add": [Constants.Keyword.FURIA],
		"description": "Convertido por quimera voragh (Furia)",
	})
	if token_node.has_method("refresh_strength_badge"):
		token_node.refresh_strength_badge()


func _activate_tenshi_z_shuffle_hand_to_annul(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, puedes Barajar una carta de tu mano para Anular
	una carta' (Tenshi Z, 2026-09-06) — costo: barajar UNA carta elegida
	de la propia mano de vuelta al mazo; efecto: Anular (~destruir, misma
	simplificación de todo el proyecto) cualquier carta en juego. Se
	confirma primero que hay objetivo válido antes de cobrar el costo
	(mismo orden que el resto de habilidades con costo+objetivo de esta
	sesión)."""
	if not is_instance_valid(source_card) or not _inspector._main._card_interaction or not _inspector._main.player_hand:
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía
	var main := _inspector._main
	if main.player_hand.cards.is_empty():
		return

	var target: Node = await TriggerSystem._targeted_executor._select_annul_target_cost_filter(
		"Elige una carta para anular", 999)
	if not target or not is_instance_valid(target):
		return
	if TriggerSystem._targeted_executor._target_text_denies(target, ["no puede ser anulad"]):
		main._update_debug("%s no puede ser anulada" % str(target.get("card_name")))
		return

	var hand_cards: Array = main.player_hand.cards.duplicate()
	var picked_data: Dictionary = await SelectionManager.await_single_pick(
		hand_cards.map(func(c): return c.card_data), "Baraja una carta de tu mano para pagar la habilidad", true, 0)
	if picked_data.is_empty():
		return
	var hand_node: Node = null
	for c in hand_cards:
		if c.card_data == picked_data:
			hand_node = c
			break
	if not hand_node:
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	var data: Dictionary = hand_node.card_data.duplicate()
	main.player_hand.remove_card(hand_node, true)
	CardManager.get_deck(owner_id).append(data)
	CardManager.shuffle_deck(owner_id)

	await ActionModule.destroy([target], source_card, true, true)


func _activate_tesoro_cesares_name_tax(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, puedes Barajar una carta de tu mano para nombrar
	una carta. Esa carta cuesta un Oro adicional el próximo turno' (Tesoro
	de los Césares, 2026-08-29). Costo: barajar (no descartar) 1 carta
	elegida de la mano de vuelta al mazo. Efecto: nombrar cualquier carta
	del juego (buscador de texto, CardNameSearchDialog — mismo mecanismo
	que Alicia en Wonderland) con un recargo de +1 Oro que recién arranca
	el turno SIGUIENTE (PaymentManager.add_named_surcharge_next_turn(),
	registro aparte de oros_mas_modifiers porque ese Array se limpia entero
	en cada turno y acá el efecto todavía no debe estar activo ahora)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0 or not _inspector._main.player_hand or _inspector._main.player_hand.cards.is_empty():
		return  # el bot no juega esta carta todavía; sin mano no hay costo que pagar

	var hand_cards: Array = _inspector._main.player_hand.cards.duplicate()
	var card_data_list: Array = []
	for c in hand_cards:
		card_data_list.append(c.card_data)

	var picked_to_shuffle: Dictionary = await SelectionManager.await_single_pick(
		card_data_list, "Baraja 1 carta de tu mano en tu mazo")
	if picked_to_shuffle.is_empty():
		return  # canceló — no paga el costo, no nombra nada

	var to_shuffle_node: Node = null
	for c in hand_cards:
		if c.card_data == picked_to_shuffle:
			to_shuffle_node = c
			break
	if not to_shuffle_node:
		return

	# HandManager.remove_card(card, true) en vez de sacarla a mano (2026-08-29,
	# corrige bug real: remove_child()+queue_free() manual, copiado del
	# patrón de GoldManager._equip_weapon(), no desconectaba las señales de
	# la carta (card_hovered/card_clicked/etc.) antes de liberarla — un
	# hover que seguía apuntando a este nodo después de queue_free() tiraba
	# "Invalid access... on a base object of type 'previously freed'" al
	# tocar .modulate. remove_card() sí desconecta todo antes de destruir.
	var shuffled_data: Dictionary = to_shuffle_node.card_data
	_inspector._main.player_hand.remove_card(to_shuffle_node, true)
	CardManager.get_deck(owner_id).append(shuffled_data)
	ActionModule.shuffle_deck(owner_id)

	var picked_card: Dictionary = await TriggerSystem._card_name_search.open_and_wait(
		"Nombra una carta: cuesta 1 Oro adicional el próximo turno"
	)

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	if picked_card.is_empty():
		return
	var picked_name: String = str(picked_card.get("nombre", ""))
	if picked_name.is_empty():
		return
	if await TriggerSystem.open_response_window(source_card, "Tesoro de los Césares", owner_id):
		return

	PaymentManager.add_named_surcharge_next_turn(picked_name, GameManager.current_turn + 1)
	_inspector._main._update_debug("'%s' cuesta 1 Oro adicional el próximo turno" % picked_name)


func _activate_voragh_devorador_search_to_cemetery(source_card: Node, ability: Dictionary) -> void:
	"""'En tu Vigilia, una vez por turno, busca en un Castillo dos cartas y
	ponlas en el Cementerio' (voragh el devorador, 2026-09-06) — 'un
	Castillo' sin posesivo = a elección."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0 or not TriggerSystem._targeted_executor:
		return  # el bot no usa esta habilidad todavía

	if await TriggerSystem.open_response_window(source_card, "voragh el devorador", owner_id):
		return
	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	var zone_owner: int = await TriggerSystem._targeted_executor._choose_search_zone_owner(owner_id, Constants.Zone.CASTILLO)
	await ActionModule.search(zone_owner, Constants.Zone.CASTILLO, {}, 2, true, false, false, source_card, Constants.Zone.CEMENTERIO)


func _activate_voragh_devorador_destroy_own_for_gold(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, puedes Destruir una de tus cartas para generar
	un Oro para jugar Aliados' (voragh el devorador, 2026-09-06) — costo
	de Destruir una carta PROPIA (elegida, cualquier zona de campo/Oro),
	efecto: Oro Virtual restringido a Aliados (mismo mecanismo que Padre de
	la Patria)."""
	if not is_instance_valid(source_card) or not _inspector._main._gold_manager or not _inspector._main._card_interaction:
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía

	var main := _inspector._main
	var filter := func(c: Node) -> bool:
		if c.get("owner_id") != owner_id and c.get("controller_id") != owner_id:
			return false
		var parent = c.get_parent()
		return parent in [main.player_field, main.player_linea_ataque, main.player_linea_apoyo, main.player_gold]
	var target: Node = await main._card_interaction.await_target("Elige una de tus cartas para Destruir", filter)
	if not target or not is_instance_valid(target):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	await ActionModule.destroy([target], source_card, true, true)
	if await TriggerSystem.open_response_window(source_card, "voragh el devorador", owner_id):
		return
	var predicate := func(card_type: int, _card_race: String, _card_cost: int) -> bool:
		return card_type == Constants.CardType.ALIADO
	main._gold_manager.generar_oro_virtual_restringido(1, predicate, "Aliados")
