extends RefCounted
## LookRevealPatternsA — mitad A (alfabética) de LookRevealPatterns.gd,
## dividido por tamaño el 2026-09-06 ("módulos gordos", split anidado: este
## archivo es una de las 2 mitades de una de las 7 mitades de
## LookAndPlayResolver.gd). Cubre de try_execute_look_dynamic_gold_count_pattern
## a try_execute_look_play_or_hand_pattern (alfabético) — el corte no cae
## justo a la mitad de los 16 patrones (6 aquí, 10 en la mitad B) porque los
## try_execute_look_play_* (free/or_gold/or_hand) son, con su filtro
## compartido _make_look_play_free_filter(), los 3 patrones más largos de
## todo el grupo; agruparlos aquí balancea el tamaño real de ambos archivos
## en vez del simple conteo de funciones. Llamada solo desde
## LookRevealPatterns.gd (facade) — ver ese archivo para la lista completa y
## la mitad hermana (LookRevealPatternsB.gd).

var _main: Node


func setup(main: Node) -> void:
	_main = main


# =============================================================================
# PATRÓN "MIRA CARTAS... COMO OROS CONTROLES. PON N EN TU MANO Y ORDENA EL
# RESTO" (cantidad de MIRADO dinámica, p.ej. Tesoro de los Césares)
# =============================================================================
func try_execute_look_dynamic_gold_count_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""Detecta 'Mira cartas del tope de tu Castillo como Oros controles. Pon
	dos cartas de ahí en tu mano y ordena el resto' (2026-08-29, Tesoro de
	los Césares) — a diferencia de try_execute_look_pick_pattern() (cantidad
	FIJA a mirar, reparto 1 mano/1 Cementerio), aquí la cantidad a MIRAR es
	dinámica (= Oros que el jugador controla, Reserva + Oro Pagado) y las no
	elegidas vuelven TODAS al Castillo, no hay Cementerio involucrado.
	'Ordena el resto' queda pendiente (mismo gap ya documentado en
	try_execute_look_pick_pattern) — vuelven al tope en su orden actual.
	Returns: true si el patrón aplicaba (se haya podido resolver o no)."""
	var lower := ability_text.to_lower()
	if "cementerio" in lower:
		return false  # eso es try_execute_look_pick_pattern
	if not ("como oros" in lower or "como oro " in lower):
		return false
	if not ("del tope" in lower and "castillo" in lower):
		return false

	var pick_rx := RegEx.new()
	pick_rx.compile("(?i)pon\\s+(\\d+|una|dos|tres|cuatro|cinco)\\s+cartas?\\s+de\\s+ah[ií]\\s+en\\s+tu\\s+mano")
	var m_pick := pick_rx.search(ability_text)
	if not m_pick:
		return false
	var pick_amount: int = UniversalCardParser._parse_amount(m_pick.get_string(1))

	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return true

	var gold_reserva: int = (main.player_gold if controller_id == 0 else main.opponent_gold).get_child_count()
	var gold_pagado: int = (main.player_oro_pagado if controller_id == 0 else main.opponent_oro_pagado).get_child_count()
	var look_amount: int = gold_reserva + gold_pagado
	if look_amount <= 0:
		return true  # nada que mirar, pero el trigger se considera resuelto

	var cm = CardManager
	var deck: Array = cm.get_deck(controller_id)
	var top_cards: Array = deck.slice(0, mini(look_amount, deck.size()))
	if top_cards.is_empty():
		return true
	if await TriggerSystem.open_response_window(card, str(card.card_name) if card else "Tesoro de los Césares", controller_id):
		return true

	await _resolve_look_pick_hand_only(controller_id, top_cards, pick_amount)
	return true




func _resolve_look_pick_hand_only(player_id: int, top_cards: Array, pick_amount: int) -> void:
	"""Como _resolve_look_pick_hand_and_mill() pero para N cartas a la mano
	(no fijo a 1) y sin Cementerio de por medio — todas las no elegidas
	vuelven al tope del Castillo en su orden actual (ver nota de 'ordena el
	resto' pendiente más arriba)."""
	var cm = CardManager
	var deck: Array = cm.get_deck(player_id)
	for i in range(top_cards.size()):
		if not deck.is_empty():
			deck.pop_front()

	var remaining: Array = top_cards.duplicate()
	pick_amount = mini(pick_amount, remaining.size())

	var main = _main.get_node_or_null("/root/Main")
	# 2026-09-14, a pedido del usuario: click directo sobre las cartas
	# reveladas (open_reveal_picker) en vez del modal de lista viejo.
	var to_hand: Array = []
	if main and main._zone_viewer:
		to_hand = await main._zone_viewer.open_reveal_picker(
			"Elige %d carta(s) para tu mano (de %d miradas)" % [pick_amount, remaining.size()],
			remaining, player_id, Callable(), pick_amount, false)
	for picked_data in to_hand:
		_remove_data_from_array(remaining, picked_data)

	if main and main.has_method("_create_card"):
		for picked_data in to_hand:
			var card_node = main._create_card(picked_data)
			main.player_hand.add_card(card_node)
			main._connect_card_signals(card_node)

	for i in range(remaining.size() - 1, -1, -1):
		deck.push_front(remaining[i])

	if main and main.get("_zone_manager"):
		main._zone_manager._update_castillo_counts()




func try_execute_look_opponent_hand_discard_then_search_ally_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando entra en juego, mira la mano de tu oponente y Descarta una
	carta que no sea Oro. Si Descartaste un Aliado, busca en tu Castillo un
	Aliado y ponlo en tu mano o Cementerio' (kitsune - sp, 2026-09-04) —
	mismo picker de mano rival que _activate_chakram_look_and_lock()
	(SearchAbilityHandler.gd), aquí sin costo/candado, con Descarte real."""
	var lower := ability_text.to_lower()
	if not ("mira la mano de tu oponente y descarta una carta que no sea oro" in lower):
		return false
	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return true
	var opponent_id: int = 1 - controller_id
	var opponent_hand_container = main.player_hand if opponent_id == 0 else main._opponent_fan
	if not opponent_hand_container or not opponent_hand_container.has_method("get_cards"):
		return true
	var opponent_hand: Array = opponent_hand_container.get_cards()
	var candidates: Array = []
	for c in opponent_hand:
		if is_instance_valid(c):
			candidates.append(c)
	if candidates.is_empty():
		return true
	if not candidates.any(func(c): return c.get("card_type") != Constants.CardType.ORO):
		return true

	# 2026-09-14, a pedido del usuario: click directo sobre la mano rival
	# (Nodos ya visibles en el abanico) en vez del modal de lista viejo.
	if not main._card_interaction:
		return true
	var not_oro_filter := func(c: Node) -> bool:
		return c in candidates and c.get("card_type") != Constants.CardType.ORO
	var chosen: Node = await main._card_interaction.await_target(
		"Mira la mano rival: elige una carta que no sea Oro para Descartar", not_oro_filter, true, controller_id)
	if not chosen or not is_instance_valid(chosen):
		return true
	if await TriggerSystem.open_response_window(card, "kitsune - sp", controller_id):
		return true

	var discarded_was_ally: bool = chosen.get("card_type") == Constants.CardType.ALIADO
	await ActionModule.discard(opponent_id, [chosen], "etb_trigger", true)

	if discarded_was_ally:
		var to_hand: bool = await SelectionManager.await_two_choice(
			main, "kitsune - sp", "Poner el Aliado encontrado en tu mano", "Ponerlo en tu Cementerio", controller_id)
		var destination: int = Constants.Zone.MANO if to_hand else Constants.Zone.CEMENTERIO
		await ActionModule.search(controller_id, Constants.Zone.CASTILLO, {"type": Constants.CardType.ALIADO}, 1, true, false, false, card, destination)
	return true




# =============================================================================
# PATRÓN "MIRA N... UNA A TU MANO, OTRA AL CEMENTERIO" (p.ej. Signo Amarillo)
# =============================================================================
func try_execute_look_pick_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""Detecta y resuelve el patrón 'Mira N cartas del tope de tu Castillo.
	Pon una en tu mano, otra en tu Cementerio [y ordena el resto]' — común a
	varias cartas de Mitos y Leyendas, no solo Signo Amarillo. No es un motor
	genérico de acciones compuestas (extract_action() solo maneja una acción
	simple a la vez): es un patrón reconocido a mano por regex.
	'Ordena el resto' queda pendiente — las cartas no elegidas vuelven al
	tope en su orden actual.
	Returns: true si el patrón aplicaba (se haya podido resolver o no)."""
	var lower := ability_text.to_lower()
	if not ("tu mano" in lower and "cementerio" in lower):
		return false

	var look_rx := RegEx.new()
	look_rx.compile("(?i)mira[s]?\\s+(\\d+|una|dos|tres|cuatro|cinco|seis|siete|ocho)\\s+cartas?\\s+del\\s+tope")
	var m := look_rx.search(ability_text)
	if not m:
		return false

	var amount: int = UniversalCardParser._parse_amount(m.get_string(1))
	var cm = CardManager

	var deck: Array = cm.get_deck(controller_id)
	var top_cards: Array = deck.slice(0, mini(amount, deck.size()))
	if top_cards.is_empty():
		return true
	if await TriggerSystem.open_response_window(card, str(card.card_name) if card else "Signo Amarillo", controller_id):
		return true

	await _resolve_look_pick_hand_and_mill(controller_id, top_cards)
	return true




func _resolve_look_pick_hand_and_mill(player_id: int, top_cards: Array) -> void:
	"""Muestra las cartas miradas (privado, vía SelectionManager — el mismo
	panel que usa Exhumar/límite de mano), deja elegir 1 para la mano y 1
	para el Cementerio, y devuelve el resto al tope del Castillo en su
	orden actual."""
	var cm = CardManager
	var deck: Array = cm.get_deck(player_id)

	# Sacar del mazo las cartas miradas — su destino se decide a continuación
	for i in range(top_cards.size()):
		if not deck.is_empty():
			deck.pop_front()

	var remaining: Array = top_cards.duplicate()
	var main = _main.get_node_or_null("/root/Main")

	# 2026-09-14, a pedido del usuario: click directo sobre las cartas
	# reveladas (open_reveal_picker) en vez del modal de lista viejo.
	var to_hand: Dictionary = {}
	if main and main._zone_viewer:
		var picked1: Array = await main._zone_viewer.open_reveal_picker(
			"Elige 1 carta para tu mano (de %d miradas)" % remaining.size(), remaining, player_id, Callable(), 1, false)
		if not picked1.is_empty():
			to_hand = picked1[0]
	_remove_data_from_array(remaining, to_hand)

	var to_cemetery: Dictionary = {}
	if not remaining.is_empty() and main and main._zone_viewer:
		var picked2: Array = await main._zone_viewer.open_reveal_picker(
			"Elige 1 carta para el Cementerio", remaining, player_id, Callable(), 1, false)
		if not picked2.is_empty():
			to_cemetery = picked2[0]
		_remove_data_from_array(remaining, to_cemetery)

	if main and not to_hand.is_empty() and main.has_method("_create_card"):
		var card_node = main._create_card(to_hand)
		main.player_hand.add_card(card_node)
		main._connect_card_signals(card_node)

	if cm and not to_cemetery.is_empty():
		cm.add_to_cemetery(player_id, to_cemetery)

	# "Ordena el resto" queda pendiente — se devuelven al tope en su orden actual
	for i in range(remaining.size() - 1, -1, -1):
		deck.push_front(remaining[i])

	if main and main.get("_zone_manager"):
		main._zone_manager._update_castillo_counts()




# =============================================================================
# PATRÓN "MUESTRA N... JUEGA UNA DE COSTE X O MENOS SIN PAGAR SU COSTE"
# (p.ej. Tangata Manu)
# =============================================================================
func try_execute_look_play_free_pattern(ability_text: String, source_card: Node, controller_id: int) -> bool:
	"""Detecta y resuelve 'Muestra N cartas del tope de tu Castillo y juega
	una carta de coste X o menos de ahí sin pagar su coste' (2026-08-25,
	p.ej. Tangata Manu). Simplificaciones a propósito, documentadas al
	usuario: no cuenta Oros entre las candidatas (su 'coste' no es
	numérico en los datos de la API) y no hay tracking de 'una vez por
	turno' para esta habilidad EN CONCRETO — es un disparador de 'cuando
	entra en juego', que ya solo se dispara una vez por entrada normalmente.
	Returns: true si el patrón aplicaba (se haya podido resolver o no)."""
	# 2026-08-25: la palabra antes de "de tu Castillo" NO se exige literal
	# ("tope") — los datos de la API traen typos reales (Tangata Manu:
	# "del topde de tu Castillo", con la 'd' de más). Se tolera cualquier
	# palabra ahí (\\S+) para no depender de que la fuente esté bien escrita.
	var lower := ability_text.to_lower()
	if not ("sin pagar su coste" in lower and "de tu castillo" in lower and "juega" in lower):
		return false

	var rx := RegEx.new()
	rx.compile("(?i)muestra[s]?\\s+(\\w+)\\s+cartas?\\s+del\\s+\\S+\\s+de\\s+tu\\s+castillo.*?juega\\s+una\\s+carta\\s+de\\s+coste\\s+(\\d+)\\s+o\\s+menos")
	var m := rx.search(ability_text)
	if not m:
		return false

	var reveal_count: int = UniversalCardParser._parse_amount(m.get_string(1))
	var max_cost: int = int(m.get_string(2))

	var cm = CardManager
	var deck: Array = cm.get_deck(controller_id)
	var top_cards: Array = deck.slice(0, mini(reveal_count, deck.size()))
	if top_cards.is_empty():
		return true

	var is_eligible := _make_look_play_free_filter(source_card, max_cost)

	# Sacar del mazo TODAS las miradas — vuelven al tope salvo la jugada
	for i in range(top_cards.size()):
		if not deck.is_empty():
			deck.pop_front()
	var remaining: Array = top_cards.duplicate()

	var main := _main.get_node_or_null("/root/Main")
	var to_play: Dictionary = {}
	if controller_id == 0:
		# Una sola ventana (2026-08-26, a pedido del usuario — "más visual,
		# menos texto"): antes eran dos ventanas seguidas, una de solo mirar
		# (sin poder hacer click en nada) y solo en la segunda se podía
		# elegir. Ahora se ven las N cartas reveladas de una — es información
		# pública (DAR) — con las que cumplen coste ya clickeables a color, y
		# el resto atenuada como cualquier carta no seleccionable.
		# 2026-09-14, a pedido del usuario: click directo (open_reveal_picker)
		# en vez del modal de lista viejo.
		if main and main._zone_viewer:
			var node_filter := func(c: Node) -> bool: return is_eligible.call(c.card_data)
			var picked: Array = await main._zone_viewer.open_reveal_picker(
				"Juega una carta de coste %d o menos gratis" % max_cost, top_cards, controller_id, node_filter, 1, true)
			if not picked.is_empty():
				to_play = picked[0]
	else:
		# El bot resuelve solo, sin abrir el diálogo al jugador humano
		# (2026-09-09, bug real reportado por el usuario: SelectionManager no
		# distingue de quién es la carta, así que este trigger del BOT
		# terminaba dejando elegir al humano en su lugar). Solo Aliados
		# (mismo alcance v1 que EasyBotController — un Arma aquí necesitaría
		# elegir portador, algo que el bot no resuelve todavía), al azar
		# entre lo elegible.
		var bot_eligible: Array = top_cards.filter(func(c: Dictionary) -> bool:
			return c.get("tipo", -1) == Constants.CardType.ALIADO and is_eligible.call(c))
		if not bot_eligible.is_empty():
			bot_eligible.shuffle()
			to_play = bot_eligible[0]

	if not to_play.is_empty():
		_remove_data_from_array(remaining, to_play)

	# El resto se baraja de vuelta al mazo (2026-08-26, regla del usuario):
	# "Muestra"/"revela" del tope sin instrucción explícita de orden
	# obliga a barajar el Castillo después — a diferencia de "Mira", que sí
	# deja al jugador elegir el orden en el que vuelven, y de Destierra/
	# Bota, que no importa porque esas cartas ya no vuelven al mazo.
	for c in remaining:
		deck.append(c)
	cm.shuffle_deck(controller_id)

	if main and main.get("_zone_manager"):
		main._zone_manager._update_castillo_counts()

	if not to_play.is_empty() and not await TriggerSystem.open_response_window(source_card, str(source_card.card_name), controller_id):
		if controller_id == 0:
			if main and main._gold_manager and main._gold_manager.has_method("play_card_for_free"):
				await main._gold_manager.play_card_for_free(to_play)
		elif main and main._easy_bot:
			await main._easy_bot.play_free_ally_from_data(to_play)

	return true




func _make_look_play_free_filter(source_card: Node, max_cost: int, exclude_self: bool = true) -> Callable:
	"""Filtro de elegibilidad compartido por los patrones 'muestra N... juega
	una de coste ≤X sin pagar su coste' (Tangata Manu, Presente, y
	cualquier otro con el mismo molde): sin Oros (su 'coste' no es
	comparable en los datos de la API), sin Talismanes de solo-respuesta
	(Red de Plata, Sacrificio Solar, etc. — misma detección que
	GoldManager._is_response_only_talisman(), adaptada a Dictionary porque
	aquí todavía no existe el nodo Card). exclude_self controla si además se
	excluye una copia de la carta fuente misma entre lo revelado — por
	defecto sí (Tangata Manu, Presente), pero Perder la Razón sí puede
	jugarse a sí mismo (2026-08-27, a pedido del usuario)."""
	var self_name: String = str(source_card.card_name if source_card.get("card_name") != null else "").to_lower()
	return func(c: Dictionary) -> bool:
		if c.get("tipo", -1) == Constants.CardType.ORO:
			return false
		# Un Arma sin ningún Aliado libre en juego para portarla no es una
		# jugada válida (2026-08-29, a pedido del usuario) — antes se ofrecía
		# igual como clickeable, y GoldManager.play_card_for_free() la
		# rechazaba solo AL EJECUTAR (chequea _player_has_ally_in_play()),
		# momento en el que la carta ya se había sacado de 'remaining' dando
		# por hecho que la jugada iba a funcionar — quedaba destruida
		# (card.queue_free()) sin ir a ningún lado. Se descarta aquí antes,
		# para que ni siquiera aparezca como opción.
		if c.get("tipo", -1) == Constants.CardType.ARMA:
			var main := _main.get_node_or_null("/root/Main")
			if not main or not main._gold_manager or not main._gold_manager._player_has_ally_in_play():
				return false
		if exclude_self:
			var c_name: String = str(c.get("nombre", c.get("name", ""))).to_lower()
			if not self_name.is_empty() and c_name == self_name:
				return false
		var cost_val = c.get("coste", null)
		if not (cost_val is int or cost_val is float or (cost_val is String and cost_val.is_valid_int())):
			return false
		if int(cost_val) > max_cost:
			return false
		if c.get("tipo", -1) == Constants.CardType.TALISMAN:
			var candidate_ability_text: String = str(c.get("habilidad", ""))
			for raw_sentence in candidate_ability_text.split("."):
				var sentence: String = raw_sentence.strip_edges().to_lower()
				if sentence.begins_with("anula") or sentence.begins_with("cancela"):
					return false
		return true




# =============================================================================
# PATRÓN "MUESTRA N... JUEGA UNA DE COSTE X O MENOS SIN PAGAR SU COSTE O
# PONER UN ORO DE AHÍ EN TU ORO PAGADO" (p.ej. Perder la Razón)
# =============================================================================
func try_execute_look_play_or_gold_pattern(ability_text: String, source_card: Node, controller_id: int) -> bool:
	"""Detecta y resuelve 'Muestra seis cartas del tope de tu Castillo.
	Puedes jugar una carta de coste X o menos de ahí sin pagar su coste o
	poner un Oro de ahí en tu Oro Pagado' (2026-08-27, p.ej. Perder la
	Razón). Variante de look_play_free: la alternativa aquí es tomar UN Oro
	puntual de lo revelado y ponerlo directo en la Reserva, no toda la
	pila ni a la mano. Misma ventana única: los no-Oro jugables (coste ≤X)
	y CUALQUIER Oro revelado quedan clickeables a la vez — según qué tipo
	sea la carta elegida se resuelve como 'jugar gratis' o 'a Oro Pagado'.
	Returns: true si el patrón aplicaba (se haya podido resolver o no)."""
	var lower := ability_text.to_lower()
	if not ("en tu oro pagado" in lower and "sin pagar su coste" in lower):
		return false

	var rx := RegEx.new()
	rx.compile("(?i)muestra\\s+(\\w+)\\s+cartas\\s+del\\s+\\S+\\s+de\\s+tu\\s+\\S+.*?jugar\\s+una\\s+carta\\s+de\\s+coste\\s+(\\d+)\\s+o\\s+menos")
	var m := rx.search(ability_text)
	if not m:
		return false

	var reveal_count: int = UniversalCardParser._parse_amount(m.get_string(1))
	var max_cost: int = int(m.get_string(2))

	var cm = CardManager
	var deck: Array = cm.get_deck(controller_id)
	var top_cards: Array = deck.slice(0, mini(reveal_count, deck.size()))
	if top_cards.is_empty():
		return true

	var play_filter := _make_look_play_free_filter(source_card, max_cost, false)
	var is_pickable := func(c: Dictionary) -> bool:
		if c.get("tipo", -1) == Constants.CardType.ORO:
			return true
		return play_filter.call(c)

	# Igual que Presente (2026-08-29, a pedido del usuario): el 'Puedes' aquí
	# también autoriza la alternativa de jugar gratis, no autoriza declinar
	# el efecto entero — mientras exista AL MENOS UNA acción legal (un Oro
	# revelado, o una carta jugable gratis), can_cancel queda en false. Pero
	# a diferencia de Presente, aquí no hay un tercer botón de respaldo tipo
	# 'Poner' — si de las 6 reveladas ninguna es un Oro y ninguna es jugable
	# gratis (p.ej. 6 Armas sin ningún portador libre), no hay NINGUNA acción
	# legal posible. Ahí can_cancel SÍ va en true (2026-08-29, corregido a
	# pedido del usuario: mostrar igual el panel con lo revelado, para que
	# el jugador tenga certeza de qué salió, en vez de resolver en silencio
	# sin mostrar nada — Cancelar queda como única salida posible, no como
	# alternativa a una acción legal disponible).
	var any_legal_action := false
	for c in top_cards:
		if is_pickable.call(c):
			any_legal_action = true
			break

	var main := _main.get_node_or_null("/root/Main")
	var picked: Dictionary = {}
	if controller_id == 0:
		# 2026-09-14, a pedido del usuario: click directo (open_reveal_picker)
		# en vez del modal de lista viejo.
		if main and main._zone_viewer:
			var node_filter := func(c: Node) -> bool: return is_pickable.call(c.card_data)
			var picked_list: Array = await main._zone_viewer.open_reveal_picker(
				"Juega una carta de coste %d o menos gratis, o pon un Oro directo en tu Oro Pagado" % max_cost,
				top_cards, controller_id, node_filter, 1, not any_legal_action)
			if not picked_list.is_empty():
				picked = picked_list[0]
	else:
		# El bot resuelve solo (mismo criterio que try_execute_look_play_free_
		# pattern) — al azar entre lo pickeable (Oro directo, o un Aliado
		# jugable gratis; sin Armas, mismo alcance v1 del bot).
		var bot_pickable: Array = top_cards.filter(func(c: Dictionary) -> bool:
			if c.get("tipo", -1) == Constants.CardType.ORO:
				return true
			return c.get("tipo", -1) == Constants.CardType.ALIADO and is_pickable.call(c))
		if not bot_pickable.is_empty():
			bot_pickable.shuffle()
			picked = bot_pickable[0]
	var remaining: Array = top_cards.duplicate()
	if not picked.is_empty():
		_remove_data_from_array(remaining, picked)

	for i in range(top_cards.size()):
		if not deck.is_empty():
			deck.pop_front()
	# El resto se baraja de vuelta (misma regla que Tangata Manu: "muestra"
	# del tope sin instrucción de orden obliga a barajar después).
	for c in remaining:
		deck.append(c)
	cm.shuffle_deck(controller_id)

	if main and main.get("_zone_manager"):
		main._zone_manager._update_castillo_counts()

	if picked.is_empty():
		return true
	if await TriggerSystem.open_response_window(source_card, str(source_card.card_name), controller_id):
		return true

	if controller_id != 0:
		# GoldManager._trigger_enter_play()/play_card_for_free() están
		# hardcodeados a jugador 0 — ver comentario en
		# EasyBotController.play_free_ally_from_data(), mismo motivo por el
		# que este trigger del bot necesita su propio camino.
		if main and main._easy_bot:
			if picked.get("tipo", -1) == Constants.CardType.ORO:
				await main._easy_bot.put_free_gold_in_pagado_from_data(picked)
			else:
				await main._easy_bot.play_free_ally_from_data(picked)
		return true

	if picked.get("tipo", -1) == Constants.CardType.ORO:
		if main and main.has_method("_create_card") and main._gold_manager:
			# Va directo a Oro Pagado, NO a Reserva (2026-08-28, corrección —
			# el texto de la carta dice literal 'poner un Oro de ahí en tu
			# Oro Pagado', no en la Reserva; a diferencia de _place_card_as_gold()
			# este Oro nunca estuvo disponible para pagar nada, entra ya-gastado).
			var data: Dictionary = picked.duplicate()
			data["esta_oculta"] = false
			var gold_node = main._create_card(data)
			gold_node.can_interact = true
			gold_node.scale = Constants.GOLD_CARD_SCALE
			gold_node.base_scale = Constants.GOLD_CARD_SCALE
			main._connect_card_signals(gold_node)
			main.player_oro_pagado.add_child(gold_node)
			gold_node.top_level = false
			gold_node.modulate = Color(0.6, 0.6, 0.6, 1.0)
			gold_node.set_zone(Constants.Zone.ORO_PAGADO)
			GameState.agregar_oro_pagado(controller_id, 1)
			main.gold_cards.append(gold_node)
			# Los Oros también pueden disparar "cuando entra en juego", sea
			# cual sea la zona donde entren (2026-08-26, regla del usuario) —
			# mismo camino que _place_card_as_gold().
			await main._gold_manager._trigger_enter_play(gold_node, Constants.Zone.ORO_PAGADO)
	elif main and main._gold_manager and main._gold_manager.has_method("play_card_for_free"):
		await main._gold_manager.play_card_for_free(picked)

	return true




# =============================================================================
# PATRÓN "MUESTRA LAS PRIMERAS N... JUEGA UNA DE COSTE X O MENOS SIN PAGAR
# SU COSTE O PONERLAS EN TU MANO" (p.ej. Presente)
# =============================================================================
func try_execute_look_play_or_hand_pattern(ability_text: String, source_card: Node, controller_id: int) -> bool:
	"""Detecta y resuelve 'Muestra las primeras N cartas de tu Castillo.
	Puedes jugar una carta de coste X o menos de ahí sin pagar su coste o
	ponerlas en tu mano' (2026-08-26, p.ej. Presente). Variante de
	try_execute_look_play_free_pattern() con una alternativa extra: en vez
	de jugar una gratis, el jugador puede llevarse las N cartas completas a
	la mano — o declinar del todo (nada gratis en 'Puedes').
	Returns: true si el patrón aplicaba (se haya podido resolver o no)."""
	var lower := ability_text.to_lower()
	if not ("ponerlas en tu mano" in lower and "sin pagar su coste" in lower):
		return false

	var rx := RegEx.new()
	rx.compile("(?i)muestra\\s+las\\s+primeras\\s+(\\w+)\\s+cartas\\s+de\\s+tu\\s+\\S+.*?jugar\\s+una\\s+carta\\s+de\\s+coste\\s+(\\d+)\\s+o\\s+menos")
	var m := rx.search(ability_text)
	if not m:
		return false

	var reveal_count: int = UniversalCardParser._parse_amount(m.get_string(1))
	var max_cost: int = int(m.get_string(2))

	var cm = CardManager
	var deck: Array = cm.get_deck(controller_id)
	var top_cards: Array = deck.slice(0, mini(reveal_count, deck.size()))
	if top_cards.is_empty():
		return true

	# exclude_self=false (2026-09-19, bug real reportado por el usuario: "no
	# puedo jugar presente con el presente"). Texto real (card_cache/cards.json,
	# id 19936): "Puedes jugar una carta de coste 3 o menos de ahí sin pagar su
	# coste o ponerlas en tu mano" — sin ninguna cláusula que excluya otra
	# copia de sí misma. El default true de _make_look_play_free_filter()
	# (pensado originalmente para Presente, según el comentario de la función)
	# no tiene base en el texto real de la carta — mismo caso que Perder la
	# Razón, que ya pasa false explícito. No se tocó el default compartido de
	# la función ni el llamador de Tangata Manu (línea ~293): ese sí usa el
	# default sin haberse verificado todavía contra su propio texto — no
	# cambiar sin que el usuario lo confirme primero (mismo criterio que
	# arquitectura.md §10.3).
	var is_eligible := _make_look_play_free_filter(source_card, max_cost, false)
	var to_play: Dictionary = {}
	var to_hand: bool = false

	if controller_id == 0:
		# Una sola ventana (2026-08-27, a pedido del usuario): las N cartas se
		# ven de una — las que cumplen coste ya clickeables a color para jugar
		# gratis (mismo filtro/estilo que Tangata Manu) — y se agrega un botón
		# extra "Poner en tu mano" al panel de SelectionManager para la otra
		# alternativa, sin abrir un popup de elección aparte primero.
		# DEJADO A PROPÓSITO en SelectionManager (2026-09-14, barrido de
		# pickers modales → click directo): este panel inyecta un tercer
		# botón custom ("Poner", ver más abajo) que open_reveal_picker() no
		# soporta (solo pick-por-click puro) — mismo criterio de complejidad
		# real que Duelo de Dragones/Ofrendas al Dragón en el barrido de
		# triggers (ver docs/plans/2026-09-09-pila-respuesta-universal-design.md).
		SelectionManager.open_selection(top_cards, SelectionManager.SelectionMode.CUSTOM, {
			"title": "Juega una carta de coste %d o menos gratis, o llévate las %d a tu mano" % [max_cost, top_cards.size()],
			"max_selections": 1,
			"min_selections": 0,
			# can_cancel=false a propósito (2026-08-29, a pedido del usuario): el
			# 'Puedes' del texto de esta carta autoriza la alternativa de jugar
			# gratis, NO autoriza declinar el efecto entero — la obligación real
			# es elegir UNA de las dos acciones (jugar gratis o llevarse todo a
			# la mano). Antes, con can_cancel=true, "Cancelar" resolvía exacto
			# igual que 0 elegidas + no tocar 'Poner' — un tercer camino ilegal
			# que no debería existir. El botón 'Poner' de abajo sigue siendo
			# obligatorio si nada es elegible para jugar gratis.
			"can_cancel": false,
			"filter": is_eligible,
		})

		var state := {"resolved": false, "picked": {}, "to_hand": false}
		var on_single := func(d: Dictionary):
			state.picked = d
			state.resolved = true
		var on_completed := func(cards: Array):
			if not cards.is_empty():
				state.picked = cards[0]
			state.resolved = true
		var on_cancelled := func():
			state.resolved = true

		# Ocultar el botón "Confirmar" base (2026-08-29, a pedido del usuario:
		# 'debe tener 1 botón nada más que diga Poner'): con min_selections=0 y
		# max_selections=1, Confirmar con 0 elegidas y Cancelar terminaban en
		# EXACTAMENTE el mismo resultado (to_play/to_hand ambos vacíos, el resto
		# se baraja de vuelta) — un botón redundante de más. Clickear una carta
		# ya auto-confirma sola (elige y juega gratis); Cancelar cubre 'declinar
		# del todo'; el único botón propio que aporta algo distinto es 'Poner en
		# tu mano'. Se restaura la visibilidad al cerrar — es el mismo botón
		# compartido por TODOS los diálogos de SelectionManager.
		var confirm_btn = SelectionManager.get("_confirm_button")
		if confirm_btn:
			confirm_btn.visible = false

		var btn_hand: Button = null
		if SelectionManager.get("_buttons_container"):
			btn_hand = Button.new()
			btn_hand.text = "Poner"
			btn_hand.pressed.connect(func():
				state.to_hand = true
				state.resolved = true
				SelectionManager.close_selection()
			)
			SelectionManager._buttons_container.add_child(btn_hand)

		SelectionManager.card_selected.connect(on_single, CONNECT_ONE_SHOT)
		SelectionManager.selection_completed.connect(on_completed, CONNECT_ONE_SHOT)
		SelectionManager.selection_cancelled.connect(on_cancelled, CONNECT_ONE_SHOT)
		while not state.resolved:
			await _main.get_tree().process_frame
		if SelectionManager.card_selected.is_connected(on_single):
			SelectionManager.card_selected.disconnect(on_single)
		if SelectionManager.selection_completed.is_connected(on_completed):
			SelectionManager.selection_completed.disconnect(on_completed)
		if SelectionManager.selection_cancelled.is_connected(on_cancelled):
			SelectionManager.selection_cancelled.disconnect(on_cancelled)
		if btn_hand and is_instance_valid(btn_hand):
			btn_hand.queue_free()
		if confirm_btn:
			confirm_btn.visible = true

		to_play = state.picked
		to_hand = state.to_hand
	else:
		# El bot resuelve solo (2026-09-09, mismo bug real que ya se corrigió
		# en Tangata Manu/Perder la Razón: esto abría el mismo diálogo de
		# arriba sin fijarse de quién era la carta, dejando elegir al humano
		# en su lugar). Solo Aliados para jugar gratis (mismo alcance v1 que
		# el resto del bot); si no hay ninguno elegible, la única alternativa
		# legal es llevarse todo a la mano.
		var bot_eligible: Array = top_cards.filter(func(c: Dictionary) -> bool:
			return c.get("tipo", -1) == Constants.CardType.ALIADO and is_eligible.call(c))
		if not bot_eligible.is_empty() and randf() < 0.5:
			bot_eligible.shuffle()
			to_play = bot_eligible[0]
		else:
			to_hand = true

	var main = _main.get_node_or_null("/root/Main")

	if to_hand:
		if await TriggerSystem.open_response_window(source_card, str(source_card.card_name), controller_id):
			return true
		for i in range(top_cards.size()):
			if not deck.is_empty():
				deck.pop_front()
		if main and main.has_method("_create_card"):
			for card_data in top_cards:
				var data: Dictionary = card_data.duplicate()
				data["esta_oculta"] = controller_id != 0
				var node = main._create_card(data, controller_id != 0)
				if controller_id == 0:
					main.player_hand.add_card(node)
				elif main._opponent_fan:
					main._opponent_fan.add_card(node)
				main._connect_card_signals(node)
		if main and main.get("_zone_manager"):
			main._zone_manager._update_castillo_counts()
		return true

	var remaining: Array = top_cards.duplicate()
	if not to_play.is_empty():
		_remove_data_from_array(remaining, to_play)

	for i in range(top_cards.size()):
		if not deck.is_empty():
			deck.pop_front()
	# El resto se baraja de vuelta (misma regla que Tangata Manu: "muestra"
	# del tope sin instrucción de orden obliga a barajar después).
	for c in remaining:
		deck.append(c)
	cm.shuffle_deck(controller_id)

	if main and main.get("_zone_manager"):
		main._zone_manager._update_castillo_counts()

	if not to_play.is_empty() and not await TriggerSystem.open_response_window(source_card, str(source_card.card_name), controller_id):
		if controller_id == 0:
			if main and main._gold_manager and main._gold_manager.has_method("play_card_for_free"):
				await main._gold_manager.play_card_for_free(to_play)
		elif main and main._easy_bot:
			await main._easy_bot.play_free_ally_from_data(to_play)

	return true




func _remove_data_from_array(array: Array, data: Dictionary) -> void:
	"""Quita de 'array' el diccionario de carta que coincide por id/uuid con 'data'.
	Duplicado idéntico en LookRevealPatternsB.gd — helper trivial (11
	líneas) usado por funciones de ambas mitades del split alfabético."""
	if data.is_empty():
		return
	var search_id = data.get("id", "")
	var search_uuid = data.get("uuid", "")
	for i in range(array.size()):
		var item = array[i]
		if (search_id and item.get("id") == search_id) or (search_uuid and item.get("uuid") == search_uuid):
			array.remove_at(i)
			return
