extends RefCounted
## DSR_DiscardChoicePatterns — Slice de DrawShuffleResolver.gd: patrones de
## descarte compuesto y dispatchers de elección A/B (Tempilcahue, Golpe
## Solar, Escamas de Dragón). Uno de 4 hermanos separados de
## DrawShuffleResolver.gd (2026-09-06, "módulos gordos") — ver también
## DSR_ShuffleDrawCombos.gd, DSR_CemeteryBanishDraw.gd y
## DSR_SearchGoldCombos.gd. Opera sobre TriggerSystem via _executor._main
## (mismo Node que TargetedEffectExecutor._main — ver ese archivo).
## DrawShuffleResolver.gd queda como FACADE — cada función de este archivo es
## llamada por un reenvío de una sola línea desde ahí, con el mismo nombre y
## firma de siempre, así que TriggerResolution.gd (único llamador) no
## necesitó cambiar una sola línea por este split.

var _executor: TargetedEffectExecutor


func setup(executor: TargetedEffectExecutor) -> void:
	_executor = executor


func try_execute_tempilcahue_choice_pattern(full_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando lo juegues, Destiérralo. Elige un efecto:
	- Busca una carta en tu Castillo, ponla en tu mano y Roba una carta. No
	  puedes jugar más cartas este turno.
	- Paga dos Oros para Barajar cartas cuyos costes sumen hasta 4 y Robar
	  dos cartas.' (Tempilcahue, 2026-08-30) — Talismán, se resuelve directo
	  vía TriggerSystem.resolve_talisman(). El autodestierro ya lo maneja
	  GoldManager._play_talisman() genérico (self_exile detecta 'destierr'
	  en el texto completo de la carta) — acá solo se resuelve la elección
	  entre las dos ramas. 'Barajar cartas cuyos costes sumen...' sin 'de tu
	  mano' = cartas EN JUEGO de cualquier lado (ver
	  [[project_no_zone_means_in_play]]), no de la mano — a diferencia de
	  try_execute_shuffle_hand_and_draw_plus_two_pattern() (Aaru), cuyo texto
	  SÍ dice 'de tu mano' explícito."""
	var lower := full_text.to_lower()
	if not ("elige un efecto" in lower and "no puedes jugar más cartas" in lower and "paga dos oros" in lower):
		return false
	if controller_id != 0:
		return false  # el bot no usa esta habilidad todavía

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return true

	var choose_search: bool = await SelectionManager.await_two_choice(
		main, "Tempilcahue",
		"Buscar una carta en tu Castillo y robar una (no juegas más cartas este turno)",
		"Pagar 2 Oros: barajar cartas en juego (coste ≤4) y robar 2")

	if choose_search:
		# Sin ventana genérica acá (2026-09-09): Tempilcahue es un Talismán —
		# TriggerSystem.resolve_talisman() ya abrió UNA ventana para toda la
		# carta antes de llegar hasta acá (Pila de Respuesta Universal).
		await ActionModule.search(controller_id, Constants.Zone.CASTILLO, {}, 1, true, false, false, card, Constants.Zone.MANO, false)
		await ActionModule.draw(controller_id, 1, "talisman_resolve", true)
		main._gold_manager.set_no_more_cards_this_turn(controller_id)
		return true

	if not main._gold_manager.puede_pagar(2):
		main._update_debug("No tienes 2 Oros disponibles para esta opción")
		return true
	await main._gold_manager.pagar_coste(2)

	var candidates: Array = []
	for field in [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
			main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]:
		if not field:
			continue
		for c in field.get_children():
			if is_instance_valid(c) and c != card:
				candidates.append(c)

	var chosen: Array = await _executor._select_cards_by_cost_budget(candidates, 4,
		"Baraja cualquier cantidad de cartas en juego cuyos costes sumen hasta 4 (puedes no elegir ninguna)")
	# Sin ventana genérica acá (2026-09-09): return_to_deck() (dentro del
	# loop) ya consulta Prevención adentro por cada carta.
	for c in chosen:
		if not is_instance_valid(c):
			continue
		var owner_id: int = c.owner_id if c.get("owner_id") != null else controller_id
		await ActionModule.return_to_deck(c, owner_id, true, card)
		CardManager.shuffle_deck(owner_id)

	await ActionModule.draw(controller_id, 2, "talisman_resolve", true)
	return true


# =============================================================================
# PATRÓN "CUANDO JUEGUES ESTA CARTA, DESTIÉRRALO. DESCARTA HASTA DOS CARTAS Y
# JUEGA UN ALIADO DE TU MANO O CEMENTERIO REDUCIENDO SU COSTE... BARAJA HASTA
# UNA CARTA OPONENTE DE COSTE 2 O MENOS" (Golpe Solar)
# =============================================================================
func try_execute_golpe_solar_pattern(full_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando juegues esta carta, Destiérralo. Descarta hasta dos cartas y
	juega un Aliado de tu mano o Cementerio reduciendo su coste en tantos
	Oros como cartas hayas Descartado, hasta un mínimo de 0. Baraja hasta
	una carta oponente de coste 2 o menos.' (Golpe Solar, 2026-08-31,
	confirmado contra la API — Ángeles y Demonios: Vigilantes / su Mazo
	Dragón / Kaiju vs Mecha: Titanes, mismo texto en las tres). Talismán,
	se resuelve directo vía TriggerSystem.resolve_talisman(). El
	autodestierro ya lo maneja GoldManager._play_talisman() genérico
	(self_exile detecta 'destierr' en el texto completo de la carta) — acá
	solo se resuelve el efecto en sí, en el orden impreso.

	El descuento de coste reusa el mismo molde que
	TargetedEffectExecutor._execute_play_weapon_discount_draw() (Lobo
	Sagrado): calcular con un modificador temporal, sacarlo enseguida, y
	pagar el número fijo resultante a mano — pero para un Aliado (sin
	elegir portador) en vez de un Arma.

	'Baraja... una carta oponente...' sin 'de tu mano'/'de tu Castillo' =
	carta EN JUEGO (ver [[project_no_zone_means_in_play]]), mismo criterio
	y candidatos que Espada Vikinga
	(try_execute_draw_and_shuffle_opponent_card_pattern), pero con umbral
	de coste fijo (2) en vez de por cantidad de Aliados, y OPCIONAL ('hasta
	una', no 'una') — se puede declinar con ESC (await_target).

	Reordenado (2026-09-09, Pila de Respuesta Universal — ver docs/plans/
	2026-09-09-pila-respuesta-universal-design.md, caso de estudio original
	del usuario): las 3 elecciones del texto (qué descartar, qué Aliado
	jugar, qué carta rival barajar) se DECLARAN primero, sin tocar nada
	todavía — recién con las 3 ya decididas se abre UNA sola ventana de
	respuesta real, y solo si nadie anula/cancela se ejecutan las 3 partes,
	en el orden impreso. Antes se elegía y ejecutaba de a una, sin ninguna
	ventana real entremedio."""
	var lower := full_text.to_lower()
	if not ("descarta hasta dos cartas" in lower and "reduciendo su coste" in lower
			and "baraja hasta una carta oponente" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return true

	# ============ DECLARAR (nada se ejecuta todavía) ============

	# --- Declarar "Descarta hasta dos cartas" (0-2, elección del jugador) ---
	var to_discard: Array = []
	var just_discarded_data: Array = []
	if main.player_hand and not main.player_hand.cards.is_empty():
		var hand_cards: Array = main.player_hand.cards.duplicate()
		var card_data_list: Array = []
		for c in hand_cards:
			card_data_list.append(c.card_data)
		var discard_result: Dictionary = await SelectionManager.await_multi_pick(
			card_data_list, "Descarta hasta dos cartas (reduce el coste del Aliado por cada una)", 2, 0, true)
		for picked_data in discard_result.picked:
			for c in hand_cards:
				if is_instance_valid(c) and c.card_data == picked_data and not (c in to_discard):
					to_discard.append(c)
					just_discarded_data.append(picked_data)
					break
	var discount: int = to_discard.size()

	# --- Declarar "juega un Aliado de tu mano o Cementerio" con ese descuento ---
	# Un Aliado recién descartado por ESTE mismo efecto no puede ser el
	# elegido acá (2026-08-31, a pedido del usuario): _discard() lo manda
	# directo al Cementerio, así que sin esta exclusión aparecía como
	# candidata de 'Cementerio' en la misma resolución que lo descartó.
	var hand_allies: Array = []
	for c in main.player_hand.cards:
		if is_instance_valid(c) and c.get("card_type") == Constants.CardType.ALIADO and not (c in to_discard):
			hand_allies.append(c)
	var cemetery_allies: Array = []
	for d in CardManager.get_cemetery(controller_id):
		if d.get("tipo") == Constants.CardType.ALIADO and not (d in just_discarded_data):
			cemetery_allies.append(d)

	var picked_ally: Dictionary = {}
	var ally_node: Node = null
	var from_hand := false
	var coste_real := 0
	var puede_pagar := false
	if not (hand_allies.is_empty() and cemetery_allies.is_empty()):
		var ally_data_list: Array = []
		for c in hand_allies:
			ally_data_list.append(c.card_data)
		for d in cemetery_allies:
			ally_data_list.append(d)

		var title: String = "Juega un Aliado con -%d Oro (mín 0)" % discount
		picked_ally = await SelectionManager.await_single_pick(ally_data_list, title, true, 0)
		if not picked_ally.is_empty():
			for c in hand_allies:
				if is_instance_valid(c) and c.card_data == picked_ally:
					ally_node = c
					from_hand = true
					break
			if not ally_node:
				# Nodo temporal solo para el chequeo de coste de abajo — si al
				# final no se puede pagar, o la ventana de respuesta anula el
				# efecto entero, se libera sin haber tocado nada real.
				ally_node = main._create_card(picked_ally, false)
				main._connect_card_signals(ally_node)

			var applies_to_this_ally := func(c: Node) -> bool:
				return c == ally_node
			PaymentManager.agregar_modificador_coste(ally_node, -discount, applies_to_this_ally, true)
			coste_real = PaymentManager.calcular_coste_real(ally_node)
			puede_pagar = PaymentManager.puede_jugar_carta(ally_node, controller_id)
			PaymentManager.remover_modificador_coste(ally_node)
			if not puede_pagar and not from_hand:
				ally_node.queue_free()
				ally_node = null

	# --- Declarar "Baraja hasta una carta oponente de coste 2 o menos" ---
	var opponent_id: int = 1 - controller_id
	var opp_fields: Array = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo] if opponent_id == 0 \
		else [main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]
	var shuffle_candidates: Array = []
	for field in opp_fields:
		if not field:
			continue
		for c in field.get_children():
			if not is_instance_valid(c):
				continue
			if ContinuousEffectManager.get_modified_cost(c) <= 2:
				shuffle_candidates.append(c)
			var weapons = c.get("equipped_weapons")
			if weapons is Array:
				for w in weapons:
					if is_instance_valid(w) and ContinuousEffectManager.get_modified_cost(w) <= 2:
						shuffle_candidates.append(w)

	var shuffle_chosen: Node = null
	if not shuffle_candidates.is_empty() and main._card_interaction:
		var shuffle_filter := func(c: Node) -> bool:
			return c in shuffle_candidates
		shuffle_chosen = await main._card_interaction.await_target(
			"Baraja hasta una carta rival en juego (coste 2 o menos) — ESC para no barajar ninguna", shuffle_filter)

	# Sin ventana genérica acá (2026-09-09): Golpe Solar es un Talismán —
	# TriggerSystem.resolve_talisman() ya abrió UNA ventana para toda la
	# carta antes de siquiera llegar a este patrón (si hubiera anulado/
	# cancelado ahí, esta función ni se habría llamado — el "declarar todo
	# primero" de arriba sigue siendo correcto, solo cambió DÓNDE se
	# pregunta, no el orden de las partes).
	# ============ RESOLVER, en el orden impreso ============
	if not to_discard.is_empty():
		await ActionModule.discard(controller_id, to_discard, "talisman_resolve")

	if hand_allies.is_empty() and cemetery_allies.is_empty():
		main._update_debug("No tienes ningún Aliado en tu mano o Cementerio para jugar")
	elif not picked_ally.is_empty() and ally_node:
		if not puede_pagar:
			main._update_debug("No puedes pagar el Aliado con descuento (%d Oro)" % coste_real)
		else:
			if from_hand:
				var hidx = main.player_hand.cards.find(ally_node)
				if hidx >= 0:
					main.player_hand.cards.remove_at(hidx)
				if ally_node.get_parent() == main.player_hand:
					main.player_hand.remove_child(ally_node)
			else:
				var cidx: int = CardManager.get_cemetery(controller_id).find(picked_ally)
				if cidx >= 0:
					CardManager.remove_from_cemetery(controller_id, cidx)

			if coste_real > 0:
				var ally_race: String = str(ally_node.get("card_raza")) if ally_node.get("card_raza") != null else ""
				await main._gold_manager.pagar_coste(coste_real, ally_node.card_type, ally_race, ally_node.card_cost)
				PaymentManager.registrar_pago(coste_real)

			await main._gold_manager._play_card_to_field(ally_node)

	if shuffle_chosen and is_instance_valid(shuffle_chosen):
		var true_owner: int = shuffle_chosen.owner_id if shuffle_chosen.get("owner_id") != null else opponent_id
		await ActionModule.return_to_deck(shuffle_chosen, true_owner, true, card)
		CardManager.shuffle_deck(true_owner)

	return true


func try_execute_each_player_discard_then_draw_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'Cada jugador Bota N carta(s) y tú Robas M carta(s)' (2026-09-04,
	p.ej. Escamas de Dragón: 'cada jugador Bota tres cartas y tú Robas una
	carta') — mandatorio, sin 'puedes'. El jugador humano elige cuáles de
	las suyas descarta; el bot descarta al azar (mismo criterio que
	_execute_targeted_discard())."""
	var lower := ability_text.to_lower()
	if not ("cada jugador bota" in lower and "tú robas" in lower):
		return false

	var discard_rx := RegEx.new()
	discard_rx.compile("cada jugador bota (\\w+) cartas?")
	var dm := discard_rx.search(lower)
	var discard_amount: int = UniversalCardParser._parse_amount(dm.get_string(1)) if dm else 1

	var draw_rx := RegEx.new()
	draw_rx.compile("tú robas (\\w+) cartas?")
	var rm := draw_rx.search(lower)
	var draw_amount: int = UniversalCardParser._parse_amount(rm.get_string(1)) if rm else 1

	if await TriggerSystem.open_response_window(card, str(card.get("card_name")) if card else "Escamas de Dragón", controller_id):
		return true

	var main := _executor._main.get_node_or_null("/root/Main")
	if main:
		for pid in [0, 1]:
			var hand_cards: Array = (main.player_hand.cards if pid == 0 else main._opponent_fan.get_cards()).duplicate()
			var amount := mini(discard_amount, hand_cards.size())
			if amount <= 0:
				continue
			var to_discard: Array
			if pid == 0:
				to_discard = await _executor._select_hand_cards_for_discard(hand_cards, amount)
			else:
				hand_cards.shuffle()
				to_discard = hand_cards.slice(0, amount)
			if not to_discard.is_empty():
				await ActionModule.discard(pid, to_discard, "etb_trigger", true)

	await ActionModule.draw(controller_id, draw_amount, "etb_trigger", true)
	return true
