extends RefCounted
## WeaponSearchShuffleExecutor — Slice de TargetedEffectExecutor.gd dividido
## por tamaño (2026-09-06, "módulos gordos"). Agrupa el cluster compuesto de
## Buscar/Barajar-para-robar/Arma-con-descuento: _execute_targeted_search,
## _execute_shuffle_for_draw (selección de presupuesto de coste vía
## CardInteractionModule.await_multi_target() con dynamic_filter — 2026-09-13,
## reemplazó al helper _select_cards_by_cost_budget() de modal, eliminado por
## quedar sin llamadores),
## _execute_play_weapon_discount_draw, _execute_return_weapon_swap_free (+ su
## helper _return_equipped_weapon_to_hand) y _count_allies_in_play. Opera
## sobre TriggerSystem via _main (mismo Node que TargetedEffectExecutor._main
## — ver ese archivo para el facade que reune este slice, el de
## MiscTargetedPatterns.gd, y el resto del toolkit de selección de un solo
## objetivo que se quedó en TargetedEffectExecutor.gd por ser el cluster de
## mayor tráfico externo de todo este archivo).

var _main: Node


func setup(main: Node) -> void:
	_main = main


func _execute_targeted_search(card: Node, controller_id: int) -> void:
	"""Busca en el Castillo o Cementerio (DAR Sección 8): relee el texto
	completo de la carta (no solo el fragmento que capturó ABILITY_PATTERNS)
	para extraer zona, dueño de esa zona, tipo de carta buscado, cantidad
	(fija o 'por cada Aliado que controles'), destino (mano/Destierro) y si
	la carta encontrada se juega directamente pagando su coste."""
	var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
	var ability_lower := ability_text.to_lower()

	var zone := Constants.Zone.CASTILLO
	if "cementerio" in ability_lower:
		zone = Constants.Zone.CEMENTERIO

	# Dueño de la zona a buscar (2026-08-25): 'tu Castillo'/'tu Cementerio'
	# es siempre propio; 'Castillo/Cementerio de tu oponente' (o 'rival') es
	# siempre del rival; 'un Castillo' sin posesivo (p.ej. Rey de Amarillo)
	# es AMBIGUO — el jugador elige a cuál apunta.
	var opponent_id := 1 - controller_id
	var zone_owner := controller_id
	var owner_is_ambiguous := false
	if "oponente" in ability_lower or "rival" in ability_lower:
		zone_owner = opponent_id
	elif "tu castillo" in ability_lower or "tu cementerio" in ability_lower:
		zone_owner = controller_id
	elif "un castillo" in ability_lower or "un cementerio" in ability_lower:
		owner_is_ambiguous = true

	if owner_is_ambiguous and controller_id == 0:
		zone_owner = await _main._targeted_executor._choose_search_zone_owner(controller_id, zone)
	elif owner_is_ambiguous:
		zone_owner = controller_id  # el bot no elige de verdad todavía — busca lo propio

	# Tipos mencionados (no 'elif' — 2026-08-22): "busca un Arma o un Oro"
	# (p.ej. Tyet) menciona DOS tipos válidos a la vez, un elif que corta en
	# el primero que encuentra (antes 'arma' ganaba siempre sobre 'oro')
	# dejaba la búsqueda incompleta.
	var wanted_types: Array = []
	if "aliado" in ability_lower:
		wanted_types.append(Constants.CardType.ALIADO)
	if "talismán" in ability_lower or "talisman" in ability_lower:
		wanted_types.append(Constants.CardType.TALISMAN)
	if "tótem" in ability_lower or "totem" in ability_lower:
		wanted_types.append(Constants.CardType.TOTEM)
	if "arma" in ability_lower:
		wanted_types.append(Constants.CardType.ARMA)
	if "oro" in ability_lower:
		wanted_types.append(Constants.CardType.ORO)

	var filter: Dictionary = {}
	if wanted_types.size() == 1:
		filter["type"] = wanted_types[0]
	elif wanted_types.size() > 1:
		filter["type"] = wanted_types

	# Cantidad: fija ("busca 2 cartas") o dinámica "una carta por cada
	# Aliado que controles (más N)" (2026-08-25, p.ej. Rey de Amarillo:
	# 'una carta por cada Aliado que controles más una').
	var amount := 1
	var per_ally_rx := RegEx.new()
	per_ally_rx.compile("por cada aliado que controles(?:\\s+m[aá]s\\s+(\\w+))?")
	var per_ally_match := per_ally_rx.search(ability_lower)
	if per_ally_match:
		amount = _count_allies_in_play(controller_id)
		var bonus_str := per_ally_match.get_string(1)
		if not bonus_str.is_empty():
			amount += UniversalCardParser._parse_amount(bonus_str)
	else:
		var amount_rx := RegEx.new()
		amount_rx.compile("busca (\\d+)")
		var amount_match := amount_rx.search(ability_lower)
		if amount_match:
			amount = int(amount_match.get_string(1))

	var may_play := (
		"puedes jugarla" in ability_lower
		or "puedes ponerla en juego" in ability_lower
		or "juégala" in ability_lower
		or "pagando su coste" in ability_lower
	)

	# Destino: Destierro directo si el texto lo dice (p.ej. 'y Destiérralas'),
	# Reserva de Oro directa si dice 'ponlo/ponla en tu Reserva' (2026-08-29,
	# p.ej. Don de Amma: 'busca un Oro en tu Castillo y ponlo en tu
	# Reserva' — va derecho a Reserva, no a la mano), si no, el default de
	# siempre (mano / juego con may_play).
	var destination := Constants.Zone.MANO
	if "destiérra" in ability_lower or "destierra" in ability_lower:
		destination = Constants.Zone.DESTIERRO
	elif "en tu reserva" in ability_lower or "en su reserva" in ability_lower:
		destination = Constants.Zone.RESERVA_ORO

	# 'de distinto nombre'/'distintos nombres' (2026-08-25, p.ej. necro-titan:
	# 'busca... dos cartas de distinto nombre') — no puede repetirse nombre
	# entre las elegidas.
	var distinct_names := "distinto nombre" in ability_lower or "distintos nombres" in ability_lower

	# search() no consulta Prevención internamente (confirmado en el resto
	# del proyecto) — sí le corresponde la ventana genérica aquí.
	if await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		return
	await ActionModule.search(zone_owner, zone, filter, amount, true, false, may_play, card, destination, distinct_names)


func _count_allies_in_play(player_id: int) -> int:
	"""Cuenta los Aliados que controla un jugador (Línea de Defensa +
	Ataque) — usado por cantidades dinámicas tipo 'por cada Aliado que
	controles' (2026-08-25)."""
	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return 0
	var fields = [main.player_field, main.player_linea_ataque] if player_id == 0 \
		else [main.opponent_field, main.opponent_linea_ataque]
	var count := 0
	for field in fields:
		if not field:
			continue
		for c in field.get_children():
			if c.get("card_type") == Constants.CardType.ALIADO:
				count += 1
	return count


func _execute_shuffle_for_draw(action: Dictionary, controller_id: int, card: Node = null) -> void:
	"""'Puedes Barajar cartas cuyos costes sumen hasta N y Roba M cartas'
	(patrón SHUFFLE_FOR_DRAW, UniversalCardParser.gd — regex "puedes
	barajar cartas? cuyos? costes? sum(en|an) hasta N ... y robar M
	cartas"). 2026-09-13, corrección a pedido del usuario: el comentario
	original decía "p.ej. Bernardo O'Higgins" — VERIFICADO FALSO contra
	cards.json. El texto real de Bernardo O'Higgins (ids 20312/20478) es
	"Una vez por turno, puedes Barajar un Arma o Aliado Caballero de tu
	mano o que controles para cancelar una habilidad o Desterrar una carta
	de coste 3 o menos" — sin ningún "cuyos costes sumen", ya cubierto por
	BernardoAbilityHandler.gd, un patrón totalmente distinto. Se corrió el
	regex de este patrón contra las ~1900 cartas de cards.json: CERO
	coincidencias — no hay ninguna carta conocida en el caché local que lo
	dispare hoy. Puede ser una carta real no incluida en este caché
	puntual, o un patrón agregado por error en algún momento sin una carta
	real verificada detrás — no se investigó más a fondo, se deja
	documentado en vez de borrar por las dudas de que sí exista.
	DAR: como dice 'puedes', el robo queda condicionado a barajar de
	verdad, no es gratis. Solo el jugador humano por ahora (controller_id
	== 0); el bot simplemente declina. NOTA: solo mira main.player_hand —
	si la carta real (si existe) dijera 'cartas EN JUEGO' en vez de 'de tu
	mano', habría que ampliar los candidatos más allá de la mano."""
	if controller_id != 0:
		return
	var params: Dictionary = action.get("params", {})
	var max_sum: int = params.get("max_cost_sum", 0)
	var draw_amount: int = params.get("draw_amount", 0)
	var main := _main.get_node_or_null("/root/Main")
	if not main or not main.player_hand:
		return
	var hand_cards: Array = main.player_hand.cards.duplicate()
	if hand_cards.is_empty():
		return
	if not main._card_interaction:
		return

	# 2026-09-13, a pedido del usuario: click directo con presupuesto en
	# vivo (dynamic_filter, ver arquitectura.md §10.20/Tempilcahue) en vez
	# del modal viejo que reintentaba toda la selección si te pasabas del
	# presupuesto.
	var budget_filter := func(chosen_so_far: Array, c: Node) -> bool:
		var sum_cost: int = 0
		for x in chosen_so_far:
			sum_cost += int(x.get("card_cost")) if x.get("card_cost") != null else 0
		var c_cost: int = int(c.get("card_cost")) if c.get("card_cost") != null else 0
		return sum_cost + c_cost <= max_sum
	var chosen: Array = await main._card_interaction.await_multi_target(
		"Baraja cartas de tu mano cuyos costes sumen hasta %d (para robar %d)" % [max_sum, draw_amount],
		hand_cards, -1, Callable(), budget_filter)
	if chosen.is_empty():
		return

	for c in chosen:
		if not is_instance_valid(c):
			continue
		var idx = main.player_hand.cards.find(c)
		if idx >= 0:
			main.player_hand.cards.remove_at(idx)
		if c.get_parent() == main.player_hand:
			main.player_hand.remove_child(c)
		await ActionModule.return_to_deck(c, controller_id, false)
	if main.player_hand.has_method("_arrange_cards"):
		main.player_hand._arrange_cards()

	CardManager.shuffle_deck(controller_id)
	# El barajado (costo) ya se pagó arriba — la ventana va aquí, antes del
	# Robo (el efecto en sí), no antes del costo.
	if await TriggerSystem.open_response_window(card, str(card.get("card_name")) if card else "Bernardo O'Higgins", controller_id):
		return
	await ActionModule.draw(controller_id, draw_amount, "etb_trigger", true)


func _execute_play_weapon_discount_draw(action: Dictionary, controller_id: int, card: Node = null) -> void:
	"""'Puedes jugar un Arma desde tu mano o Cementerio reduciendo su coste
	en N Oros, hasta un mínimo de M, y Robar K cartas' (p.ej. Lobo Sagrado)
	— NO es "hasta" un Arma: jugarla es obligatorio para robar, el texto no
	permite jugar 0 Armas y robar igual (confirmado por el usuario,
	2026-08-26 — revertido un intento anterior de hacer el robo
	incondicional). Orden: primero se confirma que hay portador y qué Arma
	jugar; solo con eso resuelto se paga y se retira de su zona de
	origen, para que cancelar a mitad de camino no deje nada a medio mover
	ni cobre Oro de más.

	Variante 'hand_only' (p.ej. Hanta: 'puedes jugar un Arma de tu mano
	reduciendo su coste...' sin Cementerio ni robo) reusa toda esta lógica
	— solo cambia el origen elegible y si al final se roba o no."""
	if controller_id != 0:
		return
	var params: Dictionary = action.get("params", {})
	var discount: int = params.get("discount", 0)
	var floor_val: int = params.get("floor", 1)
	var draw_amount: int = params.get("draw_amount", 0)
	var hand_only: bool = params.get("hand_only", false)

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return

	var hand_weapons: Array = []
	for c in main.player_hand.cards:
		if is_instance_valid(c) and c.get("card_type") == Constants.CardType.ARMA:
			hand_weapons.append(c)
	var cemetery_weapons: Array = []
	if not hand_only:
		for d in CardManager.get_cemetery(controller_id):
			if d.get("tipo") == Constants.CardType.ARMA:
				cemetery_weapons.append(d)
	# 2026-09-25, bug real reportado por el usuario ("con lobo sagrado no me
	# permite jugar armas del cementerio"): confirma qué encontró de verdad
	# esta función antes de construir nada — si el Cementerio real tenía un
	# Arma pero acá aparece vacío, el problema está en cómo quedó guardada
	# esa carta (campo 'tipo'), no en la selección en sí.
	print("[WeaponSearchShuffleExecutor] _execute_play_weapon_discount_draw: mano=%d cementerio=%d (hand_only=%s) — cementerio completo: %s" % [
		hand_weapons.size(), cemetery_weapons.size(), str(hand_only),
		str(CardManager.get_cemetery(controller_id).map(func(d): return "%s(tipo=%s)" % [str(d.get("nombre", d.get("name", "?"))), str(d.get("tipo", "?"))]))
	])
	if hand_weapons.is_empty() and cemetery_weapons.is_empty():
		return

	if not main._card_interaction:
		return
	# Título corto (2026-08-26, a pedido del usuario — "más visual, menos
	# texto"): el botón Cancelar ya cubre "declinar", no hace falta
	# explicarlo en el título.
	var title: String = "Arma con -%d oro (mín %d), roba %d" % [discount, floor_val, draw_amount]
	if draw_amount <= 0:
		title = "Arma con -%d oro (mín %d)" % [discount, floor_val]

	# 2026-09-13, a pedido del usuario: click directo — mano (Nodos ya
	# visibles) + un popup liviano con el Cementerio propio (mismo patrón
	# que Sake, arquitectura.md §10.23) — en vez del modal de lista viejo.
	var cemetery_popup: CanvasLayer = null
	var cemetery_nodes: Array = []
	if not cemetery_weapons.is_empty():
		var CardScene = load("res://scenes/cards/Card.tscn")
		cemetery_popup = CanvasLayer.new()
		cemetery_popup.layer = 40
		main.add_child(cemetery_popup)
		var panel := PanelContainer.new()
		# 2026-09-25, bug real reportado por el usuario ("el popup del
		# Cementerio ni aparece"): set_anchors_preset(BOTTOM_LEFT) +
		# position=Vector2(20,-240) dependía de que el PanelContainer ya
		# tuviera su tamaño final calculado (recién se agrega el contenido
		# DESPUÉS, más abajo) — con rect_size todavía en (0,0) en este
		# instante, la posición resultante podía terminar fuera de pantalla
		# o desalineada. Posición absoluta calculada directo del viewport
		# actual, sin depender del timing de layout de los anchors.
		var viewport_size: Vector2 = main.get_viewport().get_visible_rect().size
		panel.position = Vector2(20, viewport_size.y - 260)
		var pstyle := StyleBoxFlat.new()
		pstyle.bg_color = Color(0.04, 0.03, 0.06, 0.92)
		pstyle.border_color = Color(0.85, 0.72, 0.28, 0.85)
		pstyle.set_border_width_all(2)
		pstyle.set_corner_radius_all(12)
		panel.add_theme_stylebox_override("panel", pstyle)
		cemetery_popup.add_child(panel)
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
		for data in cemetery_weapons:
			var wrapper := Control.new()
			wrapper.custom_minimum_size = Vector2(80.0, 112.0)
			var c_node = CardScene.instantiate()
			c_node.load_from_data(data)
			c_node.set_zone(Constants.Zone.CEMENTERIO)
			c_node.owner_id = controller_id
			c_node.controller_id = controller_id
			c_node.can_interact = true
			c_node.drag_enabled = false
			c_node.custom_minimum_size = Vector2(150.0, 210.0)
			c_node.size = Vector2(150.0, 210.0)
			c_node.scale = Vector2(0.533, 0.533)
			c_node.base_scale = Vector2(0.533, 0.533)
			main._connect_card_signals(c_node)
			wrapper.add_child(c_node)
			hbox.add_child(wrapper)
			cemetery_nodes.append(c_node)

	var weapon_candidates: Array = hand_weapons + cemetery_nodes
	var weapon_filter := func(c: Node) -> bool: return c in weapon_candidates
	# 2026-09-25, bug real reportado por el usuario ("con lobo sagrado no me
	# permite jugar armas del cementerio"): el jugador seguía clickeando el
	# visor de Cementerio de SIEMPRE (no este popup nuevo) y caía en Exhumar
	# en vez de elegir el Arma — ver CardInteractionModule.
	# try_resolve_cemetery_click()/_cemetery_target_nodes. Registrar los
	# Nodos temporales de este popup ahí les da a ambos caminos la misma
	# salida real.
	main._card_interaction._cemetery_target_nodes = cemetery_nodes
	var picked_node: Node = await main._card_interaction.await_target(title, weapon_filter)
	if is_instance_valid(cemetery_popup):
		cemetery_popup.queue_free()
	if not picked_node or not is_instance_valid(picked_node):
		return
	var picked_data: Dictionary = picked_node.card_data

	# Portador ANTES de tocar el origen del Arma (mismo orden que GoldManager.play_card)
	var ally = await main._gold_manager._select_weapon_wielder()
	if not ally or not is_instance_valid(ally):
		return

	var from_hand: bool = picked_node in hand_weapons
	var weapon_node: Node = picked_node
	if not from_hand:
		# picked_node era un Nodo TEMPORAL del popup del Cementerio — se
		# reemplaza por uno real conectado a las señales del juego.
		weapon_node = main._create_card(picked_data, false)
		main._connect_card_signals(weapon_node)

	var applies_to_this_weapon := func(c: Node) -> bool:
		return c == weapon_node
	PaymentManager.agregar_modificador_coste(weapon_node, -discount, applies_to_this_weapon, floor_val <= 0)
	var coste_real: int = PaymentManager.calcular_coste_real(weapon_node)
	var puede_pagar: bool = PaymentManager.puede_jugar_carta(weapon_node, controller_id)
	PaymentManager.remover_modificador_coste(weapon_node)

	if not puede_pagar:
		main._update_debug("No puedes pagar el Arma con descuento (%d Oro)" % coste_real)
		if not from_hand:
			weapon_node.queue_free()
		return

	if await TriggerSystem.open_response_window(card, str(card.get("card_name")) if card else "Lobo Sagrado", controller_id):
		if not from_hand:
			weapon_node.queue_free()
		return

	if from_hand:
		var idx = main.player_hand.cards.find(weapon_node)
		if idx >= 0:
			main.player_hand.cards.remove_at(idx)
		if weapon_node.get_parent() == main.player_hand:
			main.player_hand.remove_child(weapon_node)
	else:
		var cemetery: Array = CardManager.get_cemetery(controller_id)
		var cidx: int = cemetery.find(picked_data)
		if cidx >= 0:
			CardManager.remove_from_cemetery(controller_id, cidx)

	if coste_real > 0:
		var weapon_race: String = str(weapon_node.get("card_raza")) if weapon_node.get("card_raza") != null else ""
		await main._gold_manager.pagar_coste(coste_real, weapon_node.card_type, weapon_race, weapon_node.card_cost)
		PaymentManager.registrar_pago(coste_real)

	await main._gold_manager._equip_weapon(weapon_node, ally)

	if draw_amount > 0:
		await ActionModule.draw(controller_id, draw_amount, "etb_trigger", true)


func _execute_return_weapon_swap_free(controller_id: int, card: Node = null) -> void:
	"""'Puedes subir un Arma que controles a la mano de su dueño para jugar
	un Arma del mismo o menor coste desde tu mano sin pagar su coste'
	(Padre de la Patria, 2026-08-28). Dos elecciones encadenadas: primero
	qué Arma equipada devolver, después qué Arma de la mano (coste ≤ la
	devuelta) jugar gratis con play_card_for_free() — mismo camino final
	que usan los patrones de LookAndPlayResolver."""
	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return

	var equipped_weapons: Array = []
	var own_fields_padre: Array = [main.player_field, main.player_linea_ataque] if controller_id == 0 else [main.opponent_field, main.opponent_linea_ataque]
	for field in own_fields_padre:
		if not field:
			continue
		for ally in field.get_children():
			if not is_instance_valid(ally):
				continue
			var weapons = ally.get("equipped_weapons")
			if weapons is Array:
				for w in weapons:
					if is_instance_valid(w):
						equipped_weapons.append(w)
	if equipped_weapons.is_empty():
		return

	# Hace falta un Arma YA en la mano para que la habilidad tenga algo que
	# jugar gratis — sin esto no vale la pena ni ofrecer el "puedes"
	# (2026-08-28, a pedido del usuario, mismo criterio que Lobo Sagrado).
	var hand_container_padre = main.player_hand if controller_id == 0 else main._opponent_fan
	var hand_weapons: Array = []
	if hand_container_padre:
		for c in hand_container_padre.cards:
			if is_instance_valid(c) and c.get("card_type") == Constants.CardType.ARMA:
				hand_weapons.append(c)
	if hand_weapons.is_empty():
		return

	if not main._card_interaction:
		return
	# 2026-09-13, a pedido del usuario: click directo sobre las Armas
	# equipadas en vez del modal de lista viejo.
	var return_filter := func(c: Node) -> bool: return c in equipped_weapons
	var weapon_to_return: Node = await main._card_interaction.await_target(
		"Sube un Arma que controles a la mano de su dueño", return_filter, true, controller_id)
	if not weapon_to_return or not is_instance_valid(weapon_to_return):
		return

	# get_modified_cost(), no card_cost crudo (2026-09-04) — weapon_to_return
	# está EN JUEGO en este punto (solo se devuelve a la mano en la línea
	# de abajo), así que puede tener el coste reducido de forma continua
	# (p.ej. Samael).
	var returned_cost: int = ContinuousEffectManager.get_modified_cost(weapon_to_return)
	_return_equipped_weapon_to_hand(weapon_to_return, main)

	# 2) Elegir qué Arma de la mano (coste ≤ la devuelta) jugar gratis. Debe
	# ser OTRA Arma, distinta de la que se acaba de devolver (2026-08-30, a
	# pedido del usuario) — weapon_to_return ya quedó insertada en
	# main.player_hand.cards por _return_equipped_weapon_to_hand() (línea de
	# arriba), así que sin esta exclusión aparecía como su propio candidato
	# válido (cualquier carta cumple costo ≤ su propio costo).
	var eligible_hand: Array = []
	if hand_container_padre:
		for c in hand_container_padre.cards:
			if is_instance_valid(c) and c != weapon_to_return and c.get("card_type") == Constants.CardType.ARMA and int(c.card_cost) <= returned_cost:
				eligible_hand.append(c)
	if eligible_hand.is_empty():
		main._update_debug("No tienes otra Arma de coste %d o menos en la mano" % returned_cost)
		return

	# 2026-09-13, a pedido del usuario: click directo en la mano en vez del
	# modal de lista viejo.
	var eligible_filter := func(c: Node) -> bool: return c in eligible_hand
	var picked2_node: Node = await main._card_interaction.await_target(
		"Juega un Arma de coste %d o menos gratis" % returned_cost, eligible_filter, true, controller_id)
	if not picked2_node or not is_instance_valid(picked2_node):
		return
	var picked2: Dictionary = picked2_node.card_data

	# El costo (subir el Arma equipada a la mano) ya se pagó arriba — la
	# ventana va aquí, antes de jugar la nueva gratis (el efecto en sí).
	if await TriggerSystem.open_response_window(card, str(card.get("card_name")) if card else "Padre de la Patria", controller_id):
		return
	await main._gold_manager.play_card_for_free(picked2, controller_id)


func _return_equipped_weapon_to_hand(weapon: Node, main: Node) -> void:
	"""Desequipa 'weapon' de su Aliado portador y la manda a la mano —
	inserción directa (no player_hand.add_card()): _equip_weapon() nunca
	desconectó las señales card_hovered/card_clicked de HandManager al
	sacarla de la mano para equiparla (bypasea remove_card(), que sí las
	desconecta), así que siguen conectadas — add_card() volvería a
	conectarlas y Godot tira un error de 'señal ya conectada'."""
	var ally = weapon.get_parent()
	if ally and ally.get("equipped_weapons") is Array:
		ally.equipped_weapons.erase(weapon)
	if ally:
		ally.remove_child(weapon)
	weapon.can_interact = true
	weapon.set_zone(Constants.Zone.MANO)
	# 2026-09-30, bug real encontrado al convertir más cartas: 'main.player_hand'
	# fijo mandaba el Arma del rival a la mano del Anfitrión. owner_id del
	# Arma decide la mano real de destino.
	var weapon_owner: int = weapon.owner_id if weapon.get("owner_id") != null else 0
	var hand_container = main.player_hand if weapon_owner == 0 else main._opponent_fan
	hand_container.cards.append(weapon)
	hand_container.add_child(weapon)
	hand_container._arrange_cards()
