extends RefCounted
## SearchOwnZonePatterns — 2 de 7 mitades de LookAndPlayResolver.gd, dividido
## por tamaño el 2026-09-06 ("módulos gordos"). Cubre patrones de "busca en tu
## Castillo/Cementerio (o el de cualquiera, sin apuntar al oponente)" que
## relocalizan o convierten cartas sin banish/destierro dirigido: Kuchiku Kan,
## La Torre, Dulce Canasta, Azi Sruvara, duelo espacial, alto prime, Belta,
## Aurora de Chile, Danza de Dragones, asedio naval. Llamada solo desde
## LookAndPlayResolver.gd (facade) — ver ese archivo para la lista completa de
## las 7 mitades hermanas.

var _main: Node


func setup(main: Node) -> void:
	_main = main


func try_execute_search_ally_castillo_or_cementerio_then_buff_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando entra en juego, busca un Aliado en tu Castillo o Cementerio,
	ponlo en tu mano y tus Aliados ganan 1 de Fuerza permanentemente'
	(Kuchiku Kan, custom_mig_15, edición 'Ángeles y Demonios: Vigilantes -
	Mazo Guerreros'). 'Castillo o Cementerio' es 'y/o' entre zonas
	(project_y_o_means_choose_one_zone) — el jugador elige UNA, no se
	combinan en un solo pool de búsqueda. El buff de Fuerza es un pump
	puntual sobre los Aliados que controlas EN ESE MOMENTO (dice
	'permanentemente', no 'los Aliados que controles' en presente
	continuo — mismo criterio ya usado en Espada del Juicio): se registra
	un modificador PERMANENT por cada Aliado en juego al resolver, con
	source=el Aliado mismo (sobrevive aunque Kuchiku Kan salga de juego,
	ya que el buff no dice 'mientras esta carta esté en juego').
	Returns: true si el patrón aplicaba (se haya encontrado algo o no)."""
	var lower := ability_text.to_lower()
	if not ("castillo o cementerio" in lower and "gana" in lower and "permanentemente" in lower):
		return false

	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return true

	var search_castillo: bool = await SelectionManager.await_two_choice(
		main, "¿Dónde buscar un Aliado?", "Tu Castillo", "Tu Cementerio", controller_id)
	var zone := Constants.Zone.CASTILLO if search_castillo else Constants.Zone.CEMENTERIO

	if await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		return true
	await ActionModule.search(controller_id, zone, {"type": Constants.CardType.ALIADO}, 1, true, false, false, card, Constants.Zone.MANO)

	var strength_rx := RegEx.new()
	strength_rx.compile("aliados ganan (\\d+|una|dos|tres) de fuerza")
	var m := strength_rx.search(lower)
	var buff_amount: int = UniversalCardParser._parse_amount(m.get_string(1)) if m else 1

	var fields = [main.player_field, main.player_linea_ataque] if controller_id == 0 \
		else [main.opponent_field, main.opponent_linea_ataque]
	for field in fields:
		if not field:
			continue
		for ally in field.get_children():
			if not is_instance_valid(ally) or ally.get("card_type") != Constants.CardType.ALIADO:
				continue
			ContinuousEffectManager.register_modifier({
				"source": ally,
				"target": ally,
				"type": ContinuousEffectManager.ModifierType.STRENGTH,
				"stat": "strength",
				"value": buff_amount,
				"operation": "add",
				"duration": ContinuousEffectManager.ModifierDuration.PERMANENT,
				"layer": ContinuousEffectManager.ModifierLayer.LAYER_7B_CHAR_MODIFY,
				"description": "Buff de Kuchiku Kan",
			})

	return true




func try_execute_search_ally_cost_max_free_play_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando entra en juego, busca en tu Castillo o Cementerio un Aliado
	de coste N o menos y juégalo sin pagar su coste' (La Torre, custom_
	mig_19, edición Ángeles y Demonios: Vigilantes - Mazo Guerreros).
	'Castillo o Cementerio' es 'y/o' entre zonas (project_y_o_means_
	choose_one_zone) — el jugador elige UNA. Gratis de verdad (Gold
	Manager.play_card_for_free()), no un descuento — a diferencia de
	Kuchiku El Cazador (SearchAbilityHandler._activate_kuchiku_cazador_
	search_and_play_discount, ACTIVADA con descuento), esta es DISPARADA
	(ETB) y sin costo alguno."""
	var lower := ability_text.to_lower()
	var cost_rx := RegEx.new()
	cost_rx.compile("busca en tu castillo o cementerio un aliado de coste (\\d+) o menos y ju[eé]galo sin pagar su coste")
	var m := cost_rx.search(lower)
	if not m:
		return false

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return true
	var hand_container = main.player_hand if controller_id == 0 else main._opponent_fan
	if not hand_container:
		return true

	var max_cost: int = int(m.get_string(1))
	var search_castillo: bool = await SelectionManager.await_two_choice(
		main, "¿Dónde buscar un Aliado?", "Tu Castillo", "Tu Cementerio", controller_id)
	var zone := Constants.Zone.CASTILLO if search_castillo else Constants.Zone.CEMENTERIO

	if await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		return true
	var hand_before: Array = hand_container.cards.duplicate()
	var result: Dictionary = await ActionModule.search(
		controller_id, zone, {"type": Constants.CardType.ALIADO, "cost_max": max_cost}, 1, true, false, false, card, Constants.Zone.MANO)
	if result.get("selected", []).is_empty():
		main._update_debug("No se encontró ningún Aliado ahí")
		return true

	var found_node: Node = null
	for c in hand_container.cards:
		if c not in hand_before:
			found_node = c
			break
	if not is_instance_valid(found_node):
		return true

	var found_data: Dictionary = found_node.card_data
	hand_container.remove_card(found_node, true)
	found_node.queue_free()
	await main._gold_manager.play_card_for_free(found_data, controller_id)
	return true




func try_execute_search_oro_castillo_or_cementerio_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Busca un Oro en tu Castillo o Cementerio y ponlo en tu mano'
	(2026-09-04, p.ej. Dulce Canasta) — 'Castillo o Cementerio' es 'y/o'
	entre zonas ([[project_y_o_means_choose_one_zone]]), el jugador elige
	UNA."""
	var lower := ability_text.to_lower()
	if not ("busca un oro en tu castillo o cementerio" in lower and "ponlo en tu mano" in lower):
		return false

	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return true
	var search_castillo: bool = await SelectionManager.await_two_choice(
		main, "¿Dónde buscar un Oro?", "Tu Castillo", "Tu Cementerio", controller_id)
	var zone := Constants.Zone.CASTILLO if search_castillo else Constants.Zone.CEMENTERIO
	if await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		return true
	await ActionModule.search(controller_id, zone, {"type": Constants.CardType.ORO}, 1, true, false, false, card, Constants.Zone.MANO)
	return true




func try_execute_raise_up_to_one_ally_or_gold_from_cemetery_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'Prevén un efecto y puedes subir hasta un Aliado u Oro de tu
	Cementerio a tu mano' (Danza de Dragones, 2026-09-06) — solo la parte
	de subir a la mano; 'Prevén un efecto' y la condición de juego
	'controlas y/o muestras al menos cinco Oros' NO implementadas."""
	var lower := ability_text.to_lower()
	if not ("prevén un efecto y puedes subir hasta un aliado u oro de tu cementerio a tu mano" in lower):
		return false

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._zone_viewer:
		return true
	var hand_container_danza = main.player_hand if controller_id == 0 else main._opponent_fan
	if not hand_container_danza:
		return true
	var own_cemetery: Array = CardManager.get_cemetery(controller_id)
	var eligible: Array = own_cemetery.filter(func(d): return d.get("tipo", -1) in [Constants.CardType.ALIADO, Constants.CardType.ORO])
	if eligible.is_empty():
		return true
	# 2026-09-14, a pedido del usuario: click directo sobre el Cementerio
	# propio (open_cemetery_target_picker) en vez del modal de lista viejo.
	var eligible_filter := func(c: Node) -> bool:
		return c.owner_id == controller_id and c.card_data.get("tipo", -1) in [Constants.CardType.ALIADO, Constants.CardType.ORO]
	var picked_list: Array = await main._zone_viewer.open_cemetery_target_picker(
		"Sube hasta un Aliado u Oro de tu Cementerio a tu mano", eligible_filter, 1, "cemetery", false, false, controller_id)
	var picked_data: Dictionary = picked_list[0].data if not picked_list.is_empty() else {}
	if picked_data.is_empty():
		return true
	if await TriggerSystem.open_response_window(card, "Danza de Dragones", controller_id):
		return true
	var idx: int = own_cemetery.find(picked_data)
	if idx < 0:
		return true
	CardManager.remove_from_cemetery(controller_id, idx)
	var card_node = main._create_card(picked_data, false)
	hand_container_danza.add_card(card_node)
	main._connect_card_signals(card_node)
	return true




func try_execute_raise_same_type_gold_and_search_banish_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Sube una o dos cartas de un mismo tipo que no sea Talismán de tu
	Cementerio a tu mano. Genera un Oro para jugar cartas del mismo tipo y
	busca en un Castillo una carta y Destiérrala' (asedio naval,
	2026-09-06) — el jugador elige el TIPO implícitamente al elegir las
	cartas (deben compartir tipo); el Oro restringido queda atado a ese
	mismo tipo."""
	var lower := ability_text.to_lower()
	if not ("sube una o dos cartas de un mismo tipo que no sea talismán de tu cementerio a tu mano" in lower):
		return false
	if controller_id != 0:
		# 2026-10-05: a diferencia del resto de este archivo, esta NO se
		# desbloquea — usa lock_group_key (candado "mismo tipo que la
		# primera elegida") en await_multi_target(), que el puente de red
		# NO enforcea del lado del Remoto a propósito (ver §17). Dejarla
		# pasar permitiría subir cartas de tipos distintos sin que el
		# candado se respete de verdad.
		return true  # el Remoto no puede usar esta habilidad todavía

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return true
	var own_cemetery: Array = CardManager.get_cemetery(controller_id)
	var eligible: Array = own_cemetery.filter(func(d): return d.get("tipo", -1) != Constants.CardType.TALISMAN)
	var chosen_type: int = -1
	var raised: Array = []
	# 2026-09-14, a pedido del usuario: click directo sobre el Cementerio
	# propio, con el candado de "mismo tipo que la primera" resuelto vía
	# lock_group_key de await_multi_target() (mismo mecanismo que Hanta el
	# Samurai usa para 'un solo Cementerio'), en vez del modal de lista viejo.
	if not eligible.is_empty() and main._card_interaction:
		var CardScene = load("res://scenes/cards/Card.tscn")
		var cemetery_popup := CanvasLayer.new()
		cemetery_popup.layer = 40
		main.add_child(cemetery_popup)
		var panel := PanelContainer.new()
		panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
		panel.position = Vector2(20, -240)
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
		var candidates: Array = []
		for d in eligible:
			var wrapper := Control.new()
			wrapper.custom_minimum_size = Vector2(80.0, 112.0)
			var c_node = CardScene.instantiate()
			c_node.load_from_data(d)
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
			candidates.append(c_node)

		var lock_key := func(c: Node) -> Variant: return c.card_data.get("tipo", -1)
		var chosen_nodes: Array = await main._card_interaction.await_multi_target(
			"Sube hasta dos cartas del MISMO tipo de tu Cementerio a tu mano", candidates, 2, lock_key)
		if is_instance_valid(cemetery_popup):
			cemetery_popup.queue_free()
		for node in chosen_nodes:
			if is_instance_valid(node):
				var picked_data: Dictionary = node.card_data
				if chosen_type == -1:
					chosen_type = picked_data.get("tipo", -1)
				raised.append(picked_data)

	# Ventana única para todo el efecto (subir a mano + Oro Virtual +
	# buscar/desterrar), sin importar si se encontró algo que subir o no.
	if await TriggerSystem.open_response_window(card, "asedio naval", controller_id):
		return true

	for picked_data in raised:
		var idx: int = own_cemetery.find(picked_data)
		if idx >= 0:
			CardManager.remove_from_cemetery(controller_id, idx)
			var card_node = main._create_card(picked_data, false)
			main.player_hand.add_card(card_node)
			main._connect_card_signals(card_node)

	if chosen_type != -1:
		var predicate := func(card_type: int, _card_race: String, _card_cost: int) -> bool:
			return card_type == chosen_type
		main._gold_manager.generar_oro_virtual_restringido(1, predicate, "cartas del mismo tipo")

	var zone_owner: int = await _main._targeted_executor._choose_search_zone_owner(controller_id, Constants.Zone.CASTILLO)
	await ActionModule.search(zone_owner, Constants.Zone.CASTILLO, {}, 1, true, false, false, card, Constants.Zone.DESTIERRO)
	return true




func try_execute_search_azi_ally_to_hand_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'Cuando entra en juego, busca en tu Castillo un Aliado Azi, ponlo en
	tu mano y convierte una carta de coste 1 o menos en un Oro con la
	habilidad "Cancelar la habilidad de tus Aliados de coste 4 o más
	cuesta un Oro adicional" y muévelo a tu Oro Pagado' (Azi Sruvara,
	2026-09-06/2026-09-30) — ambas mitades implementadas ahora:

	1) Búsqueda del Aliado Azi (por nombre, ya que "Azi" es un prefijo
	compartido entre estos Aliados, no una Raza impresa). 2026-09-30, bug
	real reportado por el usuario: esto manipula CardManager.get_deck()
	directo (sin pasar por ActionModule.search()) y barajaba los datos sin
	disparar NUNCA la animación de barajado — se sentía como "aparece una
	carta sola, automática", sin la retroalimentación visual que cualquier
	otra búsqueda en el Castillo sí muestra (ver ActionSearch.search(),
	'Barajar si buscó en el Castillo'). Agregado el mismo AnimationQueue.CUSTOM.

	2) Conversión de una carta de coste 1 o menos EN JUEGO (propia — el
	texto no dice "oponente") en un Oro con la habilidad de texto nueva, a
	Oro Pagado — mismo mecanismo de conversión real que GoldManager.
	convert_ally_to_gold_in_pagado() (Jormundgander): re-tipar los datos
	('tipo' = ORO) y crear el nodo desde cero, no silenciar uno existente
	(la carta original SALE del juego, no se queda silenciada ahí).
	IMPORTANTE — límite conocido, mismo motivo que antes de esta sesión: el
	TEXTO de la habilidad nueva queda bien asignado en la carta resultante,
	pero no hay ningún chequeo funcional en el motor que de verdad cobre
	ese Oro adicional al cancelar una habilidad (requeriría un hook nuevo
	en el camino de "cancelar" que usa Drácula,
	LinkedEffectRegistry._execute_cancel() — no auditado en esta sesión)."""
	var lower := ability_text.to_lower()
	if not ("busca en tu castillo un aliado azi, ponlo en tu mano" in lower):
		return false

	var deck: Array = CardManager.get_deck(controller_id)
	var found_idx: int = -1
	for i in range(deck.size()):
		if deck[i].get("tipo", -1) == Constants.CardType.ALIADO and str(deck[i].get("nombre", "")).to_lower().begins_with("azi"):
			found_idx = i
			break
	if found_idx == -1:
		return true
	if await TriggerSystem.open_response_window(card, "Azi Sruvara", controller_id):
		return true
	var found_data: Dictionary = deck[found_idx]
	deck.remove_at(found_idx)
	CardManager.shuffle_deck(controller_id)
	AnimationQueue.add_command(AnimationQueue.CommandType.CUSTOM, {
		"callable": Callable(AnimationQueue, "animate_shuffle").bind(controller_id),
		"description": "Barajar mazo (Azi Sruvara)"
	})

	var main := _main.get_node_or_null("/root/Main")
	if main:
		var azi_hand_container = main.player_hand if controller_id == 0 else main._opponent_fan
		if azi_hand_container:
			var card_node = main._create_card(found_data, false)
			azi_hand_container.add_card(card_node)
			main._connect_card_signals(card_node)
	if main and main.get("_zone_manager"):
		main._zone_manager._update_castillo_counts()

	if main and main._gold_manager:
		var own_in_play: Array = []
		var own_fields_azi: Array = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo, main.player_gold] if controller_id == 0 else [main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo, main.opponent_gold]
		for field in own_fields_azi:
			if not field:
				continue
			for c in field.get_children():
				if is_instance_valid(c) and c.get("card_cost") != null and int(c.card_cost) <= 1:
					own_in_play.append(c)
		var to_convert: Node = null
		if own_in_play.size() == 1:
			to_convert = own_in_play[0]
		elif own_in_play.size() > 1 and main._card_interaction:
			var convert_filter := func(c: Node) -> bool: return c in own_in_play
			to_convert = await main._card_interaction.await_target(
				"Azi Sruvara: elige una carta de coste 1 o menos para convertir en un Oro (ESC para no hacerlo)",
				convert_filter, true, controller_id)
		if to_convert and is_instance_valid(to_convert):
			var new_gold_data: Dictionary = to_convert.card_data.duplicate()
			new_gold_data["tipo"] = Constants.CardType.ORO
			new_gold_data["habilidad"] = "Cancelar la habilidad de tus Aliados de coste 4 o más cuesta un Oro adicional."
			var parent = to_convert.get_parent()
			if parent:
				parent.remove_child(to_convert)
			to_convert.queue_free()
			await main._gold_manager.put_gold_directly_in_pagado(controller_id, new_gold_data)
	return true




func try_execute_search_castillo_or_cemetery_to_pagado_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Busca una carta en un Castillo o Cementerio y ponlo en tu Oro
	Pagado como un Oro sin habilidad. Este efecto no puede ser prevenido'
	(duelo espacial, 2026-09-04) — 'un Castillo o Cementerio' es elegir
	UNA zona ([[project_y_o_means_choose_one_zone]]), luego de quién. 'No
	puede ser prevenido' ya se cumple: search() no pasa por el sistema de
	prevención (solo destroy()/banish() lo consultan)."""
	var lower := ability_text.to_lower()
	if not ("busca una carta en un castillo o cementerio y ponlo en tu oro pagado" in lower):
		return false

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return true
	var search_castillo: bool = await SelectionManager.await_two_choice(
		main, str(card.get("card_name")), "Buscar en un Castillo", "Buscar en un Cementerio", controller_id)
	var zone := Constants.Zone.CASTILLO if search_castillo else Constants.Zone.CEMENTERIO
	var zone_owner: int = await _main._targeted_executor._choose_search_zone_owner(controller_id, zone)
	if await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		return true

	# Destino SIEMPRE es "tu Oro Pagado" (el controlador de esta habilidad),
	# sin importar de qué Castillo/Cementerio salió la carta — a diferencia
	# de DESTIERRO/CEMENTERIO en ActionModule.search(), que van al dueño DE
	# LA ZONA buscada. Por eso se busca a la mano primero y se reubica aquí.
	var hand_container_duelo = main.player_hand if controller_id == 0 else main._opponent_fan
	if not hand_container_duelo:
		return true
	var hand_before: Array = hand_container_duelo.cards.duplicate()
	var result: Dictionary = await ActionModule.search(zone_owner, zone, {}, 1, true, false, false, card, Constants.Zone.MANO)
	if result.get("selected", []).is_empty():
		return true
	var found_node: Node = null
	for c in hand_container_duelo.cards:
		if c not in hand_before:
			found_node = c
			break
	if not is_instance_valid(found_node):
		return true
	var found_data: Dictionary = found_node.card_data.duplicate()
	hand_container_duelo.remove_card(found_node, true)
	await main._gold_manager.put_gold_directly_in_pagado(controller_id, found_data)
	return true




func try_execute_search_each_castillo_two_to_cemetery_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando entra o sale del juego, busca en cada Castillo dos cartas y
	ponlas en el Cementerio' (alto prime, 2026-09-04) — 'cada Castillo' =
	AMBOS jugadores, cada uno a su propio Cementerio (destino CEMENTERIO
	nuevo en ActionModule.search())."""
	var lower := ability_text.to_lower()
	if not ("busca en cada castillo dos cartas y ponlas en el cementerio" in lower):
		return false

	if await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		return true
	for player_id in [0, 1]:
		await ActionModule.search(player_id, Constants.Zone.CASTILLO, {}, 2, true, false, false, card, Constants.Zone.CEMENTERIO)
	return true




func try_execute_optional_search_totem_castillo_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Puedes buscar un Tótem en tu Castillo y ponerlo en tu mano'
	(2026-09-04, p.ej. Belta)."""
	var lower := ability_text.to_lower()
	if not ("puedes buscar un tótem en tu castillo y ponerlo en tu mano" in lower):
		return false

	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return true
	var confirm: bool = await SelectionManager.await_two_choice(
		main, "Belta", "Buscar un Tótem en tu Castillo", "No hacer nada", controller_id)
	if confirm and not await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		await ActionModule.search(controller_id, Constants.Zone.CASTILLO, {"type": Constants.CardType.TOTEM}, 1, true, false, false, card, Constants.Zone.MANO)
	return true




func try_execute_search_two_oros_split_destination_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando salga del juego, busca en tu Castillo dos Oros que no sean
	Aurora de Chile, pon uno en tu Oro Pagado y otro en tu mano' (Aurora de
	Chile, 2026-09-04) — dos búsquedas secuenciales de a 1 (cada una remueve
	la carta encontrada del Castillo, así que la segunda nunca puede repetir
	la misma copia), con name_not para excluirse a sí misma."""
	var lower := ability_text.to_lower()
	if not ("busca en tu castillo dos oros que no sean" in lower and "oro pagado" in lower):
		return false

	var self_name: String = str(card.get("card_name")) if card.get("card_name") != null else "Aurora de Chile"
	var filter := {"type": Constants.CardType.ORO, "name_not": self_name}
	if await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		return true
	await ActionModule.search(controller_id, Constants.Zone.CASTILLO, filter, 1, true, false, false, card, Constants.Zone.ORO_PAGADO)
	await ActionModule.search(controller_id, Constants.Zone.CASTILLO, filter, 1, true, false, false, card, Constants.Zone.MANO)
	return true




# =============================================================================
# FAMILIA "SELLO" (Ángeles y Demonios: Vigilantes) — 2026-09-20, auditoría de
# cartas sin implementar del usuario. Ciclo completo de 7 Sellos + "Los Siete
# Sellos" (un Oro, ver GoldManager._check_los_siete_sellos_trigger()) —
# primera tanda (Primer/Segundo/Tercer Sello) a pedido explícito del usuario
# ("Familia de los Sellos primero"), segunda tanda (Cuarto/Quinto/Sexto/
# Séptimo Sello) a pedido explícito de seguir ("sigue con el resto de la
# familia de sellos").
# =============================================================================
func _search_sello_to_hand(card: Node, controller_id: int) -> void:
	"""Búsqueda compartida por los 3 Sellos: 'Busca un Sello en tu Castillo y
	ponlo en tu mano.' 'Sello' no es una Raza impresa (campo raza vacío en
	los datos) — se identifica por nombre, igual que Azi Sruvara identifica
	'Aliado Azi' arriba (try_execute_search_azi_ally_to_hand_pattern):
	name_contains='sello' + type=TALISMAN (el type descarta 'Los Siete
	Sellos', que es Oro, sin necesidad de una lista de exclusión aparte)."""
	await ActionModule.search(controller_id, Constants.Zone.CASTILLO,
		{"type": Constants.CardType.TALISMAN, "name_contains": "sello"},
		1, true, false, false, card, Constants.Zone.MANO)


func try_execute_primer_sello_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Busca un Sello en tu Castillo y ponlo en tu mano. Tu oponente Bota
	una carta más una por cada Sello en tu Cementerio. Si está en tu
	Cementerio, una vez por turno, cuando juegues una carta Sello, tu
	oponente Bota una carta.' (Primer Sello). Primera cláusula: búsqueda
	compartida (_search_sello_to_hand). Segunda: Bota (mill) al oponente 1 +
	cartas 'Sello' que YA estén en tu Cementerio — se cuenta ANTES de que
	esta copia se resuelva y vaya a su propio Cementerio, así que nunca se
	cuenta a sí misma. Tercera: habilidad DESDE EL CEMENTERIO — sin
	precedente en el proyecto (arquitectura.md no documenta ningún otro
	caso); implementada en GoldManager._check_primer_sello_cemetery_trigger(),
	enganchada en el único punto real por el que pasa TODA carta jugada
	(GoldManager.play_card(), arquitectura.md §1) en vez de inventar un
	signal nuevo.
	SIN ventana de respuesta propia a propósito: un Talismán ya abre la
	suya en TriggerSystem.resolve_talisman() ANTES de despachar a este
	patrón — abrir otra aquí sería preguntar dos veces (ver el propio
	docstring de resolve_talisman(), mismo criterio que Golpe Solar/
	Tempilcahue/Acabar la Esperanza)."""
	var lower := ability_text.to_lower()
	if not ("busca un sello en tu castillo y ponlo en tu mano" in lower
			and "bota una carta más una por cada sello en tu cementerio" in lower):
		return false

	await _search_sello_to_hand(card, controller_id)

	var own_cemetery: Array = CardManager.get_cemetery(controller_id)
	var sello_count: int = own_cemetery.filter(func(d): return d.get("tipo", -1) == Constants.CardType.TALISMAN and "sello" in String(d.get("nombre", "")).to_lower()).size()
	await ActionModule.mill(1 - controller_id, 1 + sello_count, false, "Primer Sello", true)
	return true


func try_execute_segundo_sello_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Busca un Sello en tu Castillo y ponlo en tu mano. Hasta dos Aliados
	ganan 2 de Fuerza, su daño de combate y el daño directo de tus Sello es
	enviado al Destierro este turno. Si está en tu Cementerio, tus Sello no
	pueden ser Anulados.' (Segundo Sello). 'Su daño de combate... es enviado
	al Destierro' se lee como referido a los Aliados recién buffeados en la
	misma oración (no a cartas Sello, que nunca hacen daño de combate en
	esta familia) — mismo mecanismo YA EXISTENTE de atenea en wonderland
	(PreventionAbilityHandler_AE._activate_atenea_grant_double_damage_exile,
	Card.doubles_damage_to_exile), pero SIN doblar: se activa
	Card.damage_goes_to_exile (infraestructura muerta reactivada, ver
	Card.gd) en vez de doubles_damage_to_exile. Limitación conocida (mismo
	alcance que el propio BattleManager._check_damage_to_exile_effect() ya
	tenía de antes): solo cubre daño AL CASTILLO, no destrucción carta-contra-
	carta en combate ni daño directo fuera de combate — no se intentó
	extender ese alcance en esta sesión. 'No pueden ser Anulados' desde el
	Cementerio: ver LinkedEffectRegistry._execute_annul().
	SIN ventana de respuesta propia a propósito (mismo motivo que Primer
	Sello arriba — ya la abre resolve_talisman())."""
	var lower := ability_text.to_lower()
	if not ("busca un sello en tu castillo y ponlo en tu mano" in lower
			and "ganan 2 de fuerza" in lower and "enviado al destierro este turno" in lower):
		return false

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._card_interaction:
		return true

	await _search_sello_to_hand(card, controller_id)

	var own_fields = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo] if controller_id == 0 \
		else [main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]
	var candidates: Array = []
	for field in own_fields:
		if not field:
			continue
		for ally in field.get_children():
			if is_instance_valid(ally) and ally.get("card_type") == Constants.CardType.ALIADO:
				candidates.append(ally)
	if not candidates.is_empty():
		var chosen: Array = await main._card_interaction.await_multi_target(
			"Hasta dos Aliados ganan 2 de Fuerza y su daño de combate va al Destierro este turno", candidates, 2, Callable(), Callable(), true, null, controller_id)
		for ally in chosen:
			if not is_instance_valid(ally):
				continue
			ContinuousEffectManager.register_modifier({
				"source": card,
				"target": ally,
				"type": ContinuousEffectManager.ModifierType.STRENGTH,
				"stat": "strength",
				"value": 2,
				"operation": "add",
				"duration": ContinuousEffectManager.ModifierDuration.UNTIL_END_TURN,
				"layer": ContinuousEffectManager.ModifierLayer.LAYER_7B_CHAR_MODIFY,
				"description": "Segundo Sello",
			})
			ally.damage_goes_to_exile = true
			# 2026-09-20, bug real encontrado en revisión de código (al revisar
			# libro de thoth, que copió este mismo mecanismo): "este turno"
			# debe expirar en la MISMA frontera que el modificador de Fuerza de
			# arriba (UNTIL_END_TURN, que limpia en _on_turn_ended() sin
			# filtrar por jugador — ver ContinuousEffectManager.gd). El filtro
			# `started_player_id != owner_id` de abajo esperaba a que volviera
			# a ser TU turno para limpiar, dejando el efecto vivo durante todo
			# el turno del oponente de más (un turno extra de lo que dice el
			# texto). Se limpia en el PRÓXIMO turn_started sin importar de
			# quién sea, igual que cualquier otro efecto "este turno".
			var clear_it: Callable
			clear_it = func(_started_player_id: int, _turn: int) -> void:
				if is_instance_valid(ally):
					ally.damage_goes_to_exile = false
				if GameManager.turn_started.is_connected(clear_it):
					GameManager.turn_started.disconnect(clear_it)
			GameManager.turn_started.connect(clear_it)
	return true


func try_execute_tercer_sello_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Busca un Sello en tu Castillo y ponlo en tu mano. Hasta tu próximo
	turno, los Aliados que estén o entren en juego pierden 3 de Fuerza y si
	tienen Fuerza 0 no pueden disparar sus habilidades. Baraja los Aliados
	oponentes de Fuerza 0.' (Tercer Sello). Debuff GLOBAL (ambos jugadores,
	en juego Y futuros que entren) vía target dinámico 'ALL' + filter
	{type:ALIADO} de ModifierRegistry — el mismo mecanismo de auras 'Tus
	Aliados'/'Aliados oponentes' (ModifierRegistry._card_matches_global_
	target()), generalizado aquí a AMBOS lados sin filtrar por dueño. Se
	registra con target='ALL' en vez de una lista fija de Nodos, así que
	cualquier Aliado que ENTRE en juego después también queda afectado
	automáticamente (se resuelve dinámicamente en cada consulta, ver
	ContinuousEffectManager._resolve_targets()/get_modified_strength()) —
	sin esto habría que reaplicar el modificador a mano en cada ETB rival,
	que es justo lo que el texto pide evitar ('...que entren en juego').
	Duración TIMED, duration_value=2: se descuenta en CADA fin de turno de
	CUALQUIER jugador (ContinuousEffectManager._on_turn_ended() no filtra
	por quién terminó) — jugada en mi propio turno, sobrevive mi fin de
	turno (2→1) y expira al fin del turno rival (1→0), justo antes de que
	empiece MI próximo turno: 'hasta tu próximo turno' exacto.
	'Si tienen Fuerza 0 no pueden disparar sus habilidades' — sin precedente
	en el proyecto (habilidad condicional ligada a un valor de Fuerza
	calculado, no a una fuente en juego); ver KeywordManager.
	register_zero_strength_ability_lock()/is_silenced(), con el mismo
	criterio de 2 turnos para que se apague junto con el debuff de Fuerza.
	'Baraja los Aliados oponentes de Fuerza 0' — limpieza puntual, una sola
	vez, DESPUÉS de aplicar el debuff (para que capture Aliados que llegan a
	0 justo por este mismo efecto), respetando Prevención (mismo tag
	'leave_play' que ActionReturnDiscard.return_to_deck()).
	SIN ventana de respuesta propia a propósito (mismo motivo que Primer/
	Segundo Sello arriba — ya la abre resolve_talisman())."""
	var lower := ability_text.to_lower()
	if not ("busca un sello en tu castillo y ponlo en tu mano" in lower
			and "pierden 3 de fuerza" in lower and "baraja los aliados oponentes de fuerza 0" in lower):
		return false

	await _search_sello_to_hand(card, controller_id)

	ContinuousEffectManager.register_modifier({
		"source": card,
		"target": "ALL",
		"filter": {"type": Constants.CardType.ALIADO},
		"type": ContinuousEffectManager.ModifierType.STRENGTH,
		"stat": "strength",
		"value": -3,
		"operation": "add",
		"duration": ContinuousEffectManager.ModifierDuration.TIMED,
		"duration_value": 2,
		"layer": ContinuousEffectManager.ModifierLayer.LAYER_7B_CHAR_MODIFY,
		"description": "Tercer Sello",
	})
	KeywordManager.register_zero_strength_ability_lock(2)

	var main := _main.get_node_or_null("/root/Main")
	if main:
		var opponent_id: int = 1 - controller_id
		var opponent_fields = [main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo] if controller_id == 0 \
			else [main.player_field, main.player_linea_ataque, main.player_linea_apoyo]
		var zero_strength_allies: Array = []
		for field in opponent_fields:
			if not field:
				continue
			for ally in field.get_children():
				if is_instance_valid(ally) and ally.get("card_type") == Constants.CardType.ALIADO and ContinuousEffectManager.get_modified_strength(ally) <= 0:
					zero_strength_allies.append(ally)
		for ally in zero_strength_allies:
			if not is_instance_valid(ally):
				continue
			# ActionModule.return_to_deck() ya hace el chequeo de Prevención
			# (offer_prevention con tag "leave_play"), desequipa cualquier
			# Arma del portador, desconecta señales y emite
			# on_card_returned_to_deck (necesario para sync remoto) — la
			# versión manual anterior (remove_child + queue_free +
			# add_to_deck_top directo) se saltaba todo eso.
			if await ActionModule.return_to_deck(ally, opponent_id, true, card):
				CardManager.shuffle_deck(opponent_id)
		if not zero_strength_allies.is_empty() and main.get("_zone_manager"):
			main._zone_manager._update_castillo_counts()
	return true


func _shuffle_up_to_from_cemeteries(max_amount: int, title: String, chooser_id: int = 0) -> void:
	"""Variante 'solo Barajar' de GoldManager._resolve_armeria_barajar_
	desterrar() — Quinto Sello dice 'Baraja hasta cinco cartas de los
	Cementerios', sin la elección Barajar/Desterrar por carta que sí tiene
	Armería del Guerrero (no se reutiliza esa función directo porque fuerza
	esa elección; mismo picker de selección compartido,
	ZoneViewerModule.open_cemetery_target_picker(), pool combinado de ambos
	Cementerios, sin lock)."""
	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._zone_viewer:
		return
	var no_filter := func(_c: Node) -> bool: return true
	var picked: Array = await main._zone_viewer.open_cemetery_target_picker(
		"%s — elige hasta %d carta(s) de los Cementerios para Barajar" % [title, max_amount], no_filter, max_amount, "cemetery", false, false, chooser_id)
	for entry in picked:
		var owner_of_picked: int = entry.owner_id
		var picked_data: Dictionary = entry.data
		var idx: int = CardManager.get_cemetery(owner_of_picked).find(picked_data)
		if idx < 0:
			continue
		CardManager.remove_from_cemetery(owner_of_picked, idx)
		CardManager.get_deck(owner_of_picked).append(picked_data)
		CardManager.shuffle_deck(owner_of_picked)
		AnimationQueue.add_command(AnimationQueue.CommandType.CUSTOM, {
			"callable": Callable(AnimationQueue, "animate_shuffle").bind(owner_of_picked),
			"description": "Barajar mazo (%s)" % title
		})


func try_execute_cuarto_sello_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Puedes jugarlo al comienzo de cualquier Fase. Busca un Sello en tu
	Castillo y ponlo en tu mano. Destruye hasta una carta de coste 4 o menos.
	Puedes pagar un Oro y Descartarlo para que un Aliado pierda su habilidad
	y 4 de Fuerza por el turno. Roba dos cartas.' (Cuarto Sello, 2026-09-20).
	Primera cláusula ('Puedes jugarlo al comienzo de cualquier Fase') no
	necesita código: no existe en el proyecto ninguna restricción de
	horario/fase para jugar un Talismán (grep confirmado, sin resultados) —
	el motor ya deja jugar cualquier Talismán en cualquier momento en que el
	jugador tenga la palabra, así que esta cláusula ya se cumple sola.
	Segunda: búsqueda compartida. Tercera: Destruye hasta una carta (0 o 1)
	de coste ≤4, cualquier tipo/jugador en juego — mismo filtro de zona +
	ContinuousEffectManager.get_modified_cost() que BanishOpponentPatterns.
	try_execute_raise_opponent_cemetery_or_destroy_cost1_draw_pattern().
	Cuarta: costo adicional OPCIONAL ('Puedes') — pagar 1 Oro y Descartarlo
	(no existe en el proyecto un camino genérico para 'descartar un Oro de
	Reserva', ver GoldManager._discard_oro_from_reserva(), nuevo) para que
	UN Aliado (sin calificador 'tuyo'/'oponente' en el texto — se interpreta
	como cualquier Aliado en juego de cualquier lado, igual que el objetivo
	de Convertir de _select_convert_target()) pierda su habilidad (Keyword
	Manager.silence_card(..., 'turn')) y 4 de Fuerza este turno. 'Roba dos
	cartas' se interpretó como parte del mismo costo opcional (misma oración,
	sin 'de todas formas' que la desligue) — no se resuelve si no se paga.
	SIN ventana de respuesta propia a propósito (mismo motivo que el resto de
	la familia — ya la abre resolve_talisman())."""
	var lower := ability_text.to_lower()
	if not ("busca un sello en tu castillo y ponlo en tu mano" in lower
			and "destruye hasta una carta de coste 4 o menos" in lower):
		return false

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._card_interaction:
		return true

	await _search_sello_to_hand(card, controller_id)

	var destroy_filter := func(c: Node) -> bool:
		if c.get("current_zone") not in [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE,
				Constants.Zone.LINEA_APOYO, Constants.Zone.RESERVA_ORO]:
			return false
		return ContinuousEffectManager.get_modified_cost(c) <= 4
	var destroy_target: Node = await main._card_interaction.await_target(
		"Destruye hasta una carta de coste 4 o menos (ESC para no hacerlo)", destroy_filter, true, controller_id)
	if destroy_target and is_instance_valid(destroy_target):
		await ActionModule.destroy([destroy_target], card, true, true)

	# 2026-10-05, bug real encontrado al convertir más cartas: main.gold_cards
	# es un Array GLOBAL con el Oro físico de AMBOS jugadores — sin filtrar
	# por owner_id, "own_oros" en realidad devolvía cualquier Oro en Reserva
	# de cualquiera de los dos (bug preexistente, no solo de red).
	var own_oros: Array = main.gold_cards.filter(func(g): return is_instance_valid(g) and g.get("current_zone") == Constants.Zone.RESERVA_ORO and g.get("owner_id") == controller_id)
	if not own_oros.is_empty():
		var pay: bool = await SelectionManager.await_two_choice(
			main, str(card.get("card_name")),
			"Pagar un Oro y Descartarlo: un Aliado pierde su habilidad y 4 de Fuerza este turno. Roba dos cartas.",
			"No pagar", controller_id)
		if pay:
			var oro_to_discard: Node = own_oros[0]
			if own_oros.size() > 1:
				var oro_filter := func(c: Node) -> bool: return c in own_oros
				var picked_oro: Node = await main._card_interaction.await_target("Elige qué Oro Descartar", oro_filter, true, controller_id)
				if picked_oro and is_instance_valid(picked_oro):
					oro_to_discard = picked_oro
			await main._gold_manager._discard_oro_from_reserva(oro_to_discard, controller_id)

			var ally_candidates: Array = []
			for field in [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
					main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]:
				if not field:
					continue
				for ally in field.get_children():
					if is_instance_valid(ally) and ally.get("card_type") == Constants.CardType.ALIADO:
						ally_candidates.append(ally)
			if not ally_candidates.is_empty():
				var ally_filter := func(c: Node) -> bool: return c in ally_candidates
				var chosen_ally: Node = await main._card_interaction.await_target(
					"Elige un Aliado que pierda su habilidad y 4 de Fuerza este turno", ally_filter, true, controller_id)
				if chosen_ally and is_instance_valid(chosen_ally):
					await KeywordManager.silence_card(chosen_ally, card, "turn")
					ContinuousEffectManager.register_modifier({
						"source": card,
						"target": chosen_ally,
						"type": ContinuousEffectManager.ModifierType.STRENGTH,
						"stat": "strength",
						"value": -4,
						"operation": "add",
						"duration": ContinuousEffectManager.ModifierDuration.UNTIL_END_TURN,
						"layer": ContinuousEffectManager.ModifierLayer.LAYER_7B_CHAR_MODIFY,
						"description": "Cuarto Sello",
					})
			await ActionModule.draw(controller_id, 2, "etb_trigger", true)
	return true


func try_execute_quinto_sello_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Busca un Sello en tu Castillo y ponlo en tu mano. Baraja hasta cinco
	cartas de los Cementerios y juega un Aliado de tu Cementerio reduciendo
	su coste en un Oro, hasta un mínimo de 0 o un Sello pagando su coste. Si
	está en tu Cementerio, no se pueden jugar más de cinco cartas por turno.'
	(Quinto Sello, 2026-09-20). Segunda cláusula: _shuffle_up_to_from_
	cemeteries() (nueva, variante 'solo Barajar' de _resolve_armeria_
	barajar_desterrar()) + elección A/B — jugar un Aliado del Cementerio a
	-1 Oro (mínimo 0, allow_zero=true, mismo mecanismo que aku aku en
	PlayFromCemeteryPatterns.gd pero con mínimo 0 en vez de 1) O jugar un
	Sello del Cementerio pagando su coste completo (mismo camino de
	búsqueda-a-mano + play_card() de GoldManager, sin descuento). Tercera
	cláusula: habilidad DESDE EL CEMENTERIO, tope GLOBAL de cartas jugadas
	por turno — ver TurnManager.cards_played_count_this_turn y GoldManager.
	_quinto_sello_cap_violation() (gatea play_card(), NO play_card_from_
	exile()/play_card_from_cemetery()/play_card_for_free() — limitación
	conocida, ver arquitectura.md §12.5).
	SIN ventana de respuesta propia a propósito (mismo motivo que el resto
	de la familia — ya la abre resolve_talisman())."""
	var lower := ability_text.to_lower()
	if not ("busca un sello en tu castillo y ponlo en tu mano" in lower
			and "baraja hasta cinco cartas de los cementerios" in lower):
		return false

	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return true
	var hand_container_quinto = main.player_hand if controller_id == 0 else main._opponent_fan
	if not hand_container_quinto:
		return true

	await _search_sello_to_hand(card, controller_id)
	await _shuffle_up_to_from_cemeteries(5, "Quinto Sello", controller_id)

	var own_cemetery: Array = CardManager.get_cemetery(controller_id)
	var has_ally: bool = own_cemetery.any(func(d): return d.get("tipo", -1) == Constants.CardType.ALIADO)
	var has_sello: bool = own_cemetery.any(func(d): return d.get("tipo", -1) == Constants.CardType.TALISMAN and "sello" in String(d.get("nombre", "")).to_lower())
	if not has_ally and not has_sello:
		return true

	var play_ally: bool = has_ally
	if has_ally and has_sello:
		play_ally = await SelectionManager.await_two_choice(
			main, str(card.get("card_name")),
			"Jugar un Aliado de tu Cementerio (-1 Oro, mínimo 0)", "Jugar un Sello de tu Cementerio (paga su coste)", controller_id)

	if play_ally:
		var hand_before: Array = hand_container_quinto.cards.duplicate()
		var result: Dictionary = await ActionModule.search(
			controller_id, Constants.Zone.CEMENTERIO, {"type": Constants.CardType.ALIADO}, 1, true, false, false, card, Constants.Zone.MANO)
		if result.get("selected", []).is_empty():
			return true
		var card_node: Node = null
		for c in hand_container_quinto.cards:
			if c not in hand_before:
				card_node = c
				break
		if not is_instance_valid(card_node):
			return true
		var applies_to_this_card := func(c: Node) -> bool: return c == card_node
		PaymentManager.agregar_modificador_coste(card_node, -1, applies_to_this_card, true)
		if card_node.has_method("refresh_cost_badge"):
			card_node.refresh_cost_badge()
		await main._gold_manager.play_card(card_node)
	else:
		var hand_before2: Array = hand_container_quinto.cards.duplicate()
		var result2: Dictionary = await ActionModule.search(
			controller_id, Constants.Zone.CEMENTERIO,
			{"type": Constants.CardType.TALISMAN, "name_contains": "sello"}, 1, true, false, false, card, Constants.Zone.MANO)
		if result2.get("selected", []).is_empty():
			return true
		var sello_node: Node = null
		for c in hand_container_quinto.cards:
			if c not in hand_before2:
				sello_node = c
				break
		if is_instance_valid(sello_node):
			await main._gold_manager.play_card(sello_node)
	return true


func try_execute_sexto_sello_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'No puede ser Anulado. Busca un Sello en tu Castillo y ponlo en tu
	mano. Destruye o Destierra todas las cartas que no sean Oro. Cada
	jugador Bota seis cartas y por cada Sello que se haya Botado de esta
	forma, tu oponente Bota una carta adicional.' (Sexto Sello, 2026-09-20).
	'No puede ser Anulado': protección estática incondicional agregada en
	LinkedEffectRegistry._execute_annul() (nueva, mismo criterio que 'no
	pueden ser canceladas' de Drácula en _execute_cancel()) — cubre esta
	carta automáticamente, sin código aparte aquí. Elección A/B única para
	TODAS las cartas (no por carta) — Destruir o Desterrar, ambos jugadores,
	cualquier carta que no sea Oro en juego. Mill 6 a cada jugador (source
	'Sexto Sello'); el bono 'una carta adicional por cada Sello Botado de
	esta forma' cuenta los Sello entre las 12 cartas molidas en total (ambos
	jugadores) — interpretación: 'de esta forma' se lee como 'por este
	efecto', no solo del Cementerio del controlador, ya que el texto no dice
	'tuyos'."""
	var lower := ability_text.to_lower()
	if not ("busca un sello en tu castillo y ponlo en tu mano" in lower
			and "destruye o destierra todas las cartas que no sean oro" in lower):
		return false

	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return true

	await _search_sello_to_hand(card, controller_id)

	var choose_destroy: bool = await SelectionManager.await_two_choice(
		main, str(card.get("card_name")),
		"Destruir todas las cartas que no sean Oro", "Desterrar todas las cartas que no sean Oro", controller_id)

	var all_targets: Array = []
	for field in [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
			main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]:
		if not field:
			continue
		for c in field.get_children():
			if is_instance_valid(c) and c.get("card_type") != Constants.CardType.ORO:
				all_targets.append(c)
	if not all_targets.is_empty():
		if choose_destroy:
			await ActionModule.destroy(all_targets, card, true, true)
		else:
			await ActionModule.banish(all_targets, card, true, true)

	var opponent_id: int = 1 - controller_id
	var result_own: Dictionary = await ActionModule.mill(controller_id, 6, false, "Sexto Sello", true)
	var result_opp: Dictionary = await ActionModule.mill(opponent_id, 6, false, "Sexto Sello", true)
	# ActionModule.mill() delega en EffectController.mill_cards() cuando no
	# hay GameBoard legacy (el caso normal, siempre), que a su vez devuelve
	# Dictionary de datos crudos (clave "nombre") en vez de nodos Card
	# reales (clave "card_name") — result.cards venía vacío antes de este
	# fix, así que este conteo nunca disparaba el bono.
	var sello_milled: int = 0
	for c in result_own.get("cards", []) + result_opp.get("cards", []):
		var name_str: String
		if c is Dictionary:
			name_str = str(c.get("nombre", c.get("card_name", "")))
		elif is_instance_valid(c):
			name_str = str(c.get("card_name"))
		else:
			continue
		if "sello" in name_str.to_lower():
			sello_milled += 1
	if sello_milled > 0:
		await ActionModule.mill(opponent_id, sello_milled, false, "Sexto Sello (bono)", true)
	return true


func _apply_septimo_sello_convert(target: Node, source_card: Node) -> void:
	"""Convertir + Fuerza 0 (Séptimo Sello, 2026-09-20) — 'Convertir'
	estándar del proyecto (is_converted + KeywordManager.silence_card, ver
	TargetedEffectExecutor._execute_targeted_convert()) NO fuerza Fuerza a 0
	('conserva tipo/coste/Fuerza' según su propio docstring); esta carta
	exige explícitamente 'de Fuerza 0' además, así que se agrega un
	modificador STRENGTH separado con operation='set' (soportado por
	ModifierRegistry._apply_operation(), no usado hasta ahora en el
	proyecto) en vez de 'add'. Duración UNTIL_LEAVES (no PERMANENT — PERMANENT
	dura 'mientras la FUENTE esté en juego', pero Séptimo Sello es un
	Talismán que se va al Cementerio apenas resuelve; UNTIL_LEAVES ata la
	duración al OBJETIVO, que es lo que corresponde a un Convertir de
	verdad: dura hasta que la carta convertida sale de juego)."""
	if not is_instance_valid(target):
		return
	if TriggerSystem._targeted_executor._target_text_denies(target, ["no puede ser convertida", "no puede ser convertido"]):
		return
	target.is_converted = true
	await KeywordManager.silence_card(target, source_card, "permanent")
	ContinuousEffectManager.register_modifier({
		"source": source_card,
		"target": target,
		"type": ContinuousEffectManager.ModifierType.STRENGTH,
		"stat": "strength",
		"value": 0,
		"operation": "set",
		"duration": ContinuousEffectManager.ModifierDuration.UNTIL_LEAVES,
		"layer": ContinuousEffectManager.ModifierLayer.LAYER_7B_CHAR_MODIFY,
		"description": "Séptimo Sello",
	})


func try_execute_septimo_sello_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'No puede ser Anulado. Convierte un Oro y hasta una carta oponente de
	cada coste en cartas del mismo tipo, de Fuerza 0 y sin habilidad. Una
	carta que controles gana Indestructible e Indesterrable. Roba dos
	cartas o tu oponente Bota una carta por cada Sello en tu Cementerio,
	hasta siete.' (Séptimo Sello, 2026-09-20) — el único de los 7 SIN
	cláusula 'busca un Sello'. 'No puede ser Anulado' — mismo motivo que
	Sexto Sello (protección estática genérica, sin código aparte aquí).
	'Hasta una carta oponente de CADA coste' — recorre los costes DISTINTOS
	presentes entre las cartas oponentes en juego (no solo Aliados — el
	texto no dice 'Aliado', cualquier tipo) y convierte hasta una por cada
	valor de coste, eligiendo cuál si hay más de una al mismo coste — sin
	precedente exacto en el proyecto (_select_convert_target() es de UN
	objetivo, coste ≤N; aquí es potencialmente MUCHOS objetivos, uno por
	cada coste exacto distinto)."""
	var lower := ability_text.to_lower()
	if not ("convierte un oro y hasta una carta oponente de cada coste en cartas del mismo tipo" in lower):
		return false

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._card_interaction:
		return true

	# 2026-10-05, mismo bug que Cuarto Sello: gold_cards es global, hay que
	# filtrar por owner_id para que "own_oros" sea de verdad el Oro propio.
	var own_oros: Array = main.gold_cards.filter(func(g): return is_instance_valid(g) and g.get("current_zone") == Constants.Zone.RESERVA_ORO and g.get("owner_id") == controller_id)
	if not own_oros.is_empty():
		var oro_target: Node = own_oros[0]
		if own_oros.size() > 1:
			var oro_filter := func(c: Node) -> bool: return c in own_oros
			var picked_oro: Node = await main._card_interaction.await_target("Elige un Oro para Convertir", oro_filter, true, controller_id)
			if picked_oro and is_instance_valid(picked_oro):
				oro_target = picked_oro
		await _apply_septimo_sello_convert(oro_target, card)

	var opponent_id: int = 1 - controller_id
	var opponent_fields = [main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo] if controller_id == 0 \
		else [main.player_field, main.player_linea_ataque, main.player_linea_apoyo]
	var opponent_cards: Array = []
	for field in opponent_fields:
		if not field:
			continue
		for c in field.get_children():
			if is_instance_valid(c):
				opponent_cards.append(c)
	var distinct_costs: Array = []
	for c in opponent_cards:
		var cst: int = ContinuousEffectManager.get_modified_cost(c)
		if cst not in distinct_costs:
			distinct_costs.append(cst)
	distinct_costs.sort()
	for cst in distinct_costs:
		var bracket: Array = opponent_cards.filter(func(c: Node) -> bool: return ContinuousEffectManager.get_modified_cost(c) == cst)
		var chosen: Node = bracket[0]
		if bracket.size() > 1:
			var bracket_filter := func(c: Node) -> bool: return c in bracket
			var picked_c: Node = await main._card_interaction.await_target(
				"Elige una carta oponente de coste %d para Convertir" % cst, bracket_filter, true, controller_id)
			if picked_c and is_instance_valid(picked_c):
				chosen = picked_c
		await _apply_septimo_sello_convert(chosen, card)

	var own_fields = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo, main.player_gold] if controller_id == 0 \
		else [main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo, main.opponent_gold]
	var own_cards: Array = []
	for field in own_fields:
		if not field:
			continue
		for c in field.get_children():
			if is_instance_valid(c):
				own_cards.append(c)
	if not own_cards.is_empty():
		var own_filter := func(c: Node) -> bool: return c in own_cards
		var grant_target: Node = await main._card_interaction.await_target(
			"Elige una carta que gane Indestructible e Indesterrable", own_filter, true, controller_id)
		if grant_target and is_instance_valid(grant_target):
			KeywordManager.grant_keyword(grant_target, Constants.Keyword.INDESTRUCTIBLE, card, "permanent")
			KeywordManager.grant_keyword(grant_target, Constants.Keyword.INDESTERRABLE, card, "permanent")

	var own_cemetery: Array = CardManager.get_cemetery(controller_id)
	var sello_count: int = mini(7, own_cemetery.filter(func(d): return d.get("tipo", -1) == Constants.CardType.TALISMAN and "sello" in String(d.get("nombre", "")).to_lower()).size())
	var choose_draw: bool = await SelectionManager.await_two_choice(
		main, str(card.get("card_name")), "Robar dos cartas",
		"Tu oponente Bota una carta por cada Sello en tu Cementerio (hasta 7)", controller_id)
	if choose_draw:
		await ActionModule.draw(controller_id, 2, "etb_trigger", true)
	elif sello_count > 0:
		await ActionModule.mill(opponent_id, sello_count, false, "Séptimo Sello", true)
	return true


