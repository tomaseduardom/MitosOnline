extends RefCounted
## SearchAbilityHandler — Patrones especiales de habilidades ACTIVADAS que
## buscan/miran/reordenan cartas del Castillo, generan Oro Virtual
## restringido, o juegan otra carta con descuento (Padre de la Patria, Don de
## Amma, Tesoro de los Césares, Miguel, Espada de O'Higgins, Infernum Vox,
## Aho). Detectados en CardInspectionLayer._build_ability_buttons() y
## ruteados acá en vez de al pipeline genérico de habilidades activadas.
## Opera sobre CardInspectionLayer via _inspector (y sobre el Main del juego
## via _inspector._main).
## Extraído de CardInspectionLayer.gd (2026-08-30, "módulos gordos" — mismo
## corte que ya separó BernardoAbilityHandler/ResponseWindowHandler).

var _inspector: CardInspectionLayer


func setup(inspector: CardInspectionLayer) -> void:
	_inspector = inspector


func _activate_padre_patria_gold(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez en tu turno, genera un Oro para jugar Armas o Aliados
	Caballero por el turno' (Padre de la Patria, 2026-08-28). Sin coste ni
	objetivo — se genera directo como Oro Virtual restringido
	(GoldManager.restricted_gold_pools) y se marca usada este turno."""
	if not is_instance_valid(source_card) or not _inspector._main._gold_manager:
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


func _activate_don_de_amma(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, puedes Desterrar un Oro con habilidad de tu
	Reserva. Luego, busca un Oro en tu Castillo y ponlo en tu Reserva' (Don
	de Amma — texto verificado 2026-08-29 contra la API, estable en 7
	reimpresiones). El Oro a Desterrar puede ser cualquier Oro-con-habilidad
	en Reserva, no necesariamente esta misma carta — si hay más de uno se
	elige; si solo hay uno (lo normal: esta misma) se ahorra el diálogo. La
	búsqueda posterior reutiliza _execute_targeted_search() genérico (ya
	entiende 'ponlo en tu Reserva' como destino RESERVA_ORO, agregado para
	esta misma carta) en vez de un camino separado."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var reserva_container = _inspector._main.player_gold if owner_id == 0 else _inspector._main.opponent_gold
	if not reserva_container:
		return
	var ability_oros: Array = []
	for c in reserva_container.get_children():
		if is_instance_valid(c) and c.get("card_type") == Constants.CardType.ORO \
				and str(c.get("card_ability")) != "":
			ability_oros.append(c)
	if ability_oros.is_empty():
		return

	var to_exile: Node = ability_oros[0]
	if ability_oros.size() > 1 and owner_id == 0:
		var candidates: Array = []
		for c in ability_oros:
			candidates.append(c.card_data)
		var picked: Dictionary = await SelectionManager.await_single_pick(
			candidates, "Elige qué Oro con habilidad Desterrar de tu Reserva")
		if picked.is_empty():
			return  # Canceló — no paga el costo, no hay búsqueda
		for c in ability_oros:
			if c.card_data == picked:
				to_exile = c
				break

	# Registrar ANTES de Desterrar (2026-08-29): to_exile suele ser la propia
	# source_card — tras exile_card() el Node puede quedar inválido, así que
	# no se puede seguir leyendo de source_card/ability después de este punto.
	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	await EffectController.exile_card(owner_id, to_exile, true)

	# Búsqueda directa (no _execute_targeted_search(), que relee card_ability
	# desde el Node — puede haber quedado inválido si to_exile == source_card):
	# 'busca un Oro en tu Castillo y ponlo en tu Reserva', ya soportado por
	# ActionModule.search() con destination=RESERVA_ORO (agregado para esta
	# misma carta).
	await ActionModule.search(owner_id, Constants.Zone.CASTILLO, {"type": Constants.CardType.ORO}, 1, true, false, false, null, Constants.Zone.RESERVA_ORO, false)


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

	PaymentManager.add_named_surcharge_next_turn(picked_name, GameManager.current_turn + 1)
	_inspector._main._update_debug("'%s' cuesta 1 Oro adicional el próximo turno" % picked_name)


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
	if candidates.is_empty():
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


func _activate_espada_ohiggins_vigilia_choice(source_card: Node, ability: Dictionary) -> void:
	"""'En tu Vigilia, una vez por turno, puedes Barajar una carta que no
	sea Oro o buscar un Oro en tu Castillo y ponerlo en tu mano' (Espada de
	O'Higgins, 2026-08-30). Elección A/B entre dos efectos que no comparten
	nada — ActionPipeline solo resuelve un tipo de acción por habilidad, no
	una elección genérica entre dos. Restricción de fase ('en tu Vigilia')
	ya validada de forma genérica en _validate_ability(). Clickear el botón
	ya es la confirmación de uso (mismo criterio que el resto de
	ACTIVATED), así que el uso se registra apenas se resuelve la elección
	A/B, sin importar si la rama elegida después no encuentra objetivos."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía

	var choose_shuffle: bool = await SelectionManager.await_two_choice(
		_inspector._main, "Espada de O'Higgins",
		"Barajar una carta (no Oro) de tu mano", "Buscar un Oro en tu Castillo")

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	if choose_shuffle:
		# "Barajar una carta que no sea Oro" se refiere a una carta EN JUEGO
		# que controlás (2026-08-30, corrección del usuario — el texto no
		# dice 'de tu mano', a diferencia de Tesoro de los Césares, que sí
		# lo dice explícito). Reserva de Oro y Oro Pagado quedan FUERA del
		# barrido (2026-08-30, a pedido del usuario: la propia carta ya lo
		# dice — 'que no sea Oro' — así que esas dos zonas, que solo
		# contienen Oro, ni se recorren); solo Campo, Línea de Ataque y
		# Línea de Apoyo, más las Armas equipadas de cada Aliado.
		var in_play_containers: Array = [
			_inspector._main.player_field, _inspector._main.player_linea_ataque, _inspector._main.player_linea_apoyo
		]
		var candidates: Array = []
		for container in in_play_containers:
			if not container:
				continue
			for c in container.get_children():
				if not is_instance_valid(c) or not (c is Card):
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
		var card_data_list: Array = []
		for c in candidates:
			card_data_list.append(c.card_data)
		var picked: Dictionary = await SelectionManager.await_single_pick(
			card_data_list, "Baraja una carta (que no sea Oro) que controles en juego", false)
		if picked.is_empty():
			return
		var to_shuffle_node: Node = null
		for c in candidates:
			if c.card_data == picked:
				to_shuffle_node = c
				break
		if not to_shuffle_node:
			return
		ActionModule.return_to_deck(to_shuffle_node, owner_id, true)
		ActionModule.shuffle_deck(owner_id)
	else:
		await ActionModule.search(owner_id, Constants.Zone.CASTILLO, {"type": Constants.CardType.ORO}, 1, true, false, false, null, Constants.Zone.MANO, false)


func _activate_infernum_vox_look_reorder(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, puedes mirar seis cartas del tope de un Castillo
	y devolverlas en cualquier orden en el tope y/o fondo del Castillo'
	(Infernum Vox, 2026-08-30). 'Un Castillo' sin posesivo = el propio o el
	rival, a elección (mismo criterio ya confirmado para 'un Cementerio' de
	Miguel). El orden se resuelve con DOS selecciones múltiples de
	SelectionManager.await_multi_pick(), reutilizando que selected_cards
	preserva el ORDEN DE CLICK (ver SelectionManager._select_card()) — no
	hace falta ninguna UI de arrastrar/reordenar. (La que ya existía en el
	proyecto, SelectionCanvas.gd/SelectionReorder.gd con su SelectionMode.
	LOOK/REORDER, resultó ser código MUERTO al revisarla — no es autoload,
	no está en ninguna escena, y OpponentUI.gd la busca en /root/
	SelectionCanvas reintentando para siempre sin encontrarla nunca; no se
	tocó, pero tampoco se reusó acá.)
	  1) Elegir cuáles de las 6 van al FONDO, EN EL ORDEN que se quieran
	     (0 a todas) — el orden de click ya es el orden final de ese grupo
	     (primero clickeado = más arriba DENTRO del grupo que va al fondo).
	  2) Con las que quedan (van al TOPE), una segunda selección forzando
	     TODAS (min = max = las que quedan) solo para capturar el orden de
		 click — ya no hay 'elegir cuáles', quedaron decididas por descarte
	     del paso 1."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía

	var look_own: bool = await SelectionManager.await_castillo_pick(_inspector._main, "Infernum Vox — mira 6 cartas")
	var target_player: int = owner_id if look_own else (1 - owner_id)

	var deck: Array = CardManager.get_deck(target_player)
	var amount: int = mini(6, deck.size())
	if amount <= 0:
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	# pop_front() = tope real (2026-08-30, corregido — el camino de robo
	# que de verdad usa la partida es ZoneManager.draw_card(), que hace
	# pop_front() sobre este mismo array; CardManager.draw_card() con
	# pop_back() nunca se llama desde ningún lado, quedó con la
	# convención vieja). La primera carta sacada es la más arriba del
	# mazo, la sexta la más profunda de las 6.
	var peeked: Array = []
	for i in range(amount):
		peeked.append(deck.pop_front())

	var result_bottom: Dictionary = await SelectionManager.await_multi_pick(
		peeked, "Elige, EN ORDEN, las cartas que van al FONDO del Castillo (puedes no elegir ninguna)",
		amount, 0, false)
	var ordered_bottom: Array = result_bottom.picked

	var ordered_top: Array = peeked.duplicate()
	for card_data in ordered_bottom:
		ordered_top.erase(card_data)

	if ordered_top.size() > 1:
		var result_top: Dictionary = await SelectionManager.await_multi_pick(
			ordered_top, "Ordena las cartas que quedan en el TOPE (elegilas de arriba hacia abajo)",
			ordered_top.size(), ordered_top.size(), false)
		ordered_top = result_top.picked

	# add_to_deck_bottom() = append (2026-08-30, tras corregir CardManager):
	# el ÚLTIMO en agregarse queda como fondo absoluto — pasando
	# ordered_bottom en su orden tal cual (primero = más arriba del grupo)
	# el último en insertarse (ordered_bottom.back()) termina siendo el
	# fondo absoluto. Correcto.
	for card_data in ordered_bottom:
		CardManager.add_to_deck_bottom(target_player, card_data)

	# add_to_deck_top() = insert(0, ...): el ÚLTIMO en agregarse queda como
	# tope absoluto — hay que recorrer ordered_top AL REVÉS (el que va más
	# abajo del grupo primero) para que ordered_top[0] (el que el jugador
	# quiere más arriba) termine siendo el último en agregarse.
	for i in range(ordered_top.size() - 1, -1, -1):
		CardManager.add_to_deck_top(target_player, ordered_top[i])


func _activate_aho_banish_ally_and_deck(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, Destierra un Aliado o Tótem y cinco cartas del
	tope de un Castillo' (Aho, 2026-08-30). Sin 'puedes': mandatorio una
	vez activada — clickear el botón ya es la confirmación de uso, mismo
	criterio que el resto de ACTIVATED. 'Un Aliado o Tótem'/'un Castillo'
	sin posesivo = cualquiera de los dos jugadores, a elección (mismo
	criterio ya confirmado para 'un Cementerio' de Miguel). Dos destierros
	independientes unidos por 'y' (no 'Luego'): ambos ocurren sin
	condicionarse entre sí, aunque el objetivo elegido no exista."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía

	var target: Node = await TriggerSystem._targeted_executor._select_ally_or_totem_target(
		"Elige un Aliado o Tótem para desterrar")

	var look_own: bool = await SelectionManager.await_castillo_pick(_inspector._main, "Aho — destierra 5 del tope")
	var deck_owner: int = owner_id if look_own else (1 - owner_id)

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	if target and is_instance_valid(target):
		await ActionModule.banish([target], source_card, true)

	var deck: Array = CardManager.get_deck(deck_owner)
	var amount: int = mini(5, deck.size())
	for i in range(amount):
		var card_data: Dictionary = deck.pop_front()
		CardManager.add_to_exile(deck_owner, card_data)
	# El contador visual del Castillo no se refresca solo al vaciar el Array
	# del mazo a mano (2026-08-31, a pedido del usuario: 'destierro 5 del
	# tope pero el contador del castillo sigue igual') — mismo llamado que
	# ya usan el resto de patrones que tocan el mazo directo (ver
	# LookAndPlayResolver/DrawShuffleResolver, _update_castillo_counts()).
	if amount > 0 and _inspector._main.get("_zone_manager"):
		_inspector._main._zone_manager._update_castillo_counts()


func _activate_chakram_look_and_lock(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, puedes mirar la mano de tu oponente y elegir una
	carta de ahí que no sea Oro para que no pueda ser jugada hasta tu
	próximo turno y Roba una carta' (Chakram, 2026-08-30). 'Mirar' no
	necesita un overlay de revelado aparte — el picker de SelectionManager
	ya muestra el arte/nombre real de cada candidata, alcanza para 'ver' la
	mano rival y elegir. main._opponent_fan.get_cards() son Nodos reales
	(mismo camino que usa _execute_targeted_discard() para la mano rival),
	así que el elegido se candada como Nodo puntual, no por nombre —
	GoldManager.lock_card_from_playing().

	Se muestra la mano COMPLETA, Oro incluido (2026-08-31, a pedido del
	usuario: 'mirar' debería mostrar toda la información real, no solo lo
	elegible) — antes los Oro se sacaban de la lista antes de abrir el
	picker, así que ni se veían. Ahora se pasan todos y el filtro de
	SelectionManager.await_single_pick() los deja visibles pero sin poder
	clickearlos (mismo patrón gris/no-interactivo que cualquier otro picker
	con 'filter' — ver SelectionManager._create_selection_card())."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía

	var opponent_hand: Array = []
	if _inspector._main._opponent_fan and _inspector._main._opponent_fan.has_method("get_cards"):
		opponent_hand = _inspector._main._opponent_fan.get_cards()
	var candidates: Array = []
	for c in opponent_hand:
		if is_instance_valid(c):
			candidates.append(c)
	if candidates.is_empty():
		_inspector._main._update_debug("Tu oponente no tiene cartas en la mano")
		return
	if not candidates.any(func(c): return c.get("card_type") != Constants.CardType.ORO):
		_inspector._main._update_debug("Tu oponente no tiene ninguna carta (que no sea Oro) en la mano")
		return

	var candidate_data: Array = candidates.map(func(c): return c.card_data)
	var not_oro_filter := func(d: Dictionary) -> bool:
		return d.get("tipo") != Constants.CardType.ORO
	var picked: Dictionary = await SelectionManager.await_single_pick(
		candidate_data, "Mira la mano rival: elige una carta que no sea Oro", true, 0, not_oro_filter)
	if picked.is_empty():
		return  # canceló — no se marca 'una vez por turno'

	var chosen: Node = null
	for c in candidates:
		if is_instance_valid(c) and c.card_data == picked:
			chosen = c
			break
	if not chosen:
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	if _inspector._main._gold_manager:
		_inspector._main._gold_manager.lock_card_from_playing(chosen, owner_id)

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

	ActionModule.return_to_deck(target, opponent_id, true)
	CardManager.shuffle_deck(opponent_id)
