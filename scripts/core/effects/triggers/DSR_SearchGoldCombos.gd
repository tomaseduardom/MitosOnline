extends RefCounted
## DSR_SearchGoldCombos — Slice de DrawShuffleResolver.gd: patrones que
## combinan buscar/subir una carta (del Castillo, la mano o el Cementerio) o
## generar Oro Virtual restringido, con un Robo u otro efecto secundario
## (Legión Paladín, Levisterio, La Ouija, Shiji). Uno de 4 hermanos separados
## de DrawShuffleResolver.gd (2026-09-06, "módulos gordos") — ver también
## DSR_ShuffleDrawCombos.gd, DSR_CemeteryBanishDraw.gd y
## DSR_DiscardChoicePatterns.gd. Opera sobre TriggerSystem via
## _executor._main (mismo Node que TargetedEffectExecutor._main — ver ese
## archivo). DrawShuffleResolver.gd queda como FACADE — cada función de este
## archivo es llamada por un reenvío de una sola línea desde ahí, con el
## mismo nombre y firma de siempre, así que TriggerResolution.gd (único
## llamador) no necesitó cambiar una sola línea por este split.

var _executor: TargetedEffectExecutor


func setup(executor: TargetedEffectExecutor) -> void:
	_executor = executor


func try_execute_free_play_weapon_or_totem_cost1_hand_cemetery_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'Cuando entra en juego, juega un Arma o Tótem de coste 1 de tu mano
	o Cementerio sin pagar su coste' (Shiji, myl_id 18196, edición
	Escuadrón Mecha / reprint promo custom_mig_12). Pool combinado mano +
	Cementerio (mismo patrón de try_execute_golpe_solar_pattern más
	arriba), filtrado a Arma/Tótem de coste EXACTO 1. A diferencia de
	Golpe Solar (que paga con descuento), aquí es gratis de verdad — reusa
	GoldManager.play_card_for_free(), que ya rutea Arma (con selección de
	portador) y Tótem (a campo) sin pasar por PaymentManager. El llamador
	(esta función) saca la carta de su zona de origen ANTES de llamar,
	como pide el contrato documentado de play_card_for_free()."""
	var lower := ability_text.to_lower()
	var mentions_arma_totem_cost1 := "arma o tótem de coste 1" in lower or "arma o totem de coste 1" in lower
	if not mentions_arma_totem_cost1 or not ("sin pagar su coste" in lower):
		return false

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return true
	var hand_container_shiji = main.player_hand if controller_id == 0 else main._opponent_fan
	if not hand_container_shiji:
		return true

	var hand_candidates: Array = []
	for c in hand_container_shiji.cards:
		if is_instance_valid(c) and c.get("card_type") in [Constants.CardType.ARMA, Constants.CardType.TOTEM] \
				and c.get("card_cost") != null and int(c.card_cost) == 1:
			hand_candidates.append(c)
	var cemetery_data: Array = []
	for d in CardManager.get_cemetery(controller_id):
		if d.get("tipo") in [Constants.CardType.ARMA, Constants.CardType.TOTEM] and int(d.get("coste", -1)) == 1:
			cemetery_data.append(d)

	if hand_candidates.is_empty() and cemetery_data.is_empty():
		main._update_debug("No tienes ningún Arma o Tótem de coste 1 en tu mano o Cementerio")
		return true
	if not main._card_interaction:
		return true

	# 2026-09-14, a pedido del usuario: click directo — mano (Nodos ya
	# visibles) + un popup liviano con el Cementerio propio (mismo patrón
	# que Golpe Solar, ver DSR_DiscardChoicePatterns.gd), en vez del modal
	# de lista viejo combinando ambas zonas.
	var cemetery_popup: CanvasLayer = null
	var cemetery_nodes: Array = []
	if not cemetery_data.is_empty():
		var CardScene = load("res://scenes/cards/Card.tscn")
		cemetery_popup = CanvasLayer.new()
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
		for d in cemetery_data:
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
			cemetery_nodes.append(c_node)

	var candidates: Array = hand_candidates + cemetery_nodes
	var filter := func(c: Node) -> bool: return c in candidates
	var picked_node: Node = await main._card_interaction.await_target(
		"Juega un Arma o Tótem de coste 1 sin pagar su coste", filter, true, controller_id)
	if is_instance_valid(cemetery_popup):
		cemetery_popup.queue_free()

	if not picked_node or not is_instance_valid(picked_node):
		return true
	var picked: Dictionary = picked_node.card_data
	if await TriggerSystem.open_response_window(card, str(card.card_name) if card else "Shiji", controller_id):
		return true

	var from_hand_node: Node = picked_node if picked_node in hand_candidates else null
	if from_hand_node:
		hand_container_shiji.remove_card(from_hand_node, true)
		from_hand_node.queue_free()
	else:
		var cidx: int = CardManager.get_cemetery(controller_id).find(picked)
		if cidx >= 0:
			CardManager.remove_from_cemetery(controller_id, cidx)

	await main._gold_manager.play_card_for_free(picked, controller_id)
	return true


# =============================================================================
# PATRÓN "CUANDO ENTRA EN JUEGO, ROBA N, GENERA UN ORO PARA JUGAR X DE COSTE
# Y O MÁS Y SUBE HASTA M CARTA(S) DE TU CEMENTERIO A TU MANO" (Legión Paladín)
# =============================================================================
func try_execute_draw_gold_search_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""Detecta 'Roba N carta(s), genera un Oro para jugar Aliados o Armas de
	coste X o más y sube hasta M carta(s) de tu Cementerio a tu mano' (Legión
	Paladín — 2026-08-29: texto reconfirmado en vivo contra la API, que
	resultó ser INESTABLE entre fetches para esta carta específica; esta es
	la versión que la API acaba de devolver, la misma que ya se había
	usado en una implementación anterior de este mismo desarrollo. Ver
	[[feedback_api_is_source_of_truth]] — se sincronizó también el cache
	local (user://card_cache/cards.json, id 20857) a este texto). Tres
	efectos encadenados SIN 'puedes' (no son opcionales, y el trigger es
	SOLO 'cuando entra en juego' — no incluye salir del juego). Se detecta
	por texto y se ejecutan los tres en orden.
	Returns: true si el patrón aplicaba."""
	var lower := ability_text.to_lower()
	if not ("genera un oro para jugar" in lower and "sube hasta" in lower and "cementerio" in lower):
		return false

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main:
		return true

	var draw_rx := RegEx.new()
	draw_rx.compile("(?i)roba[s]?\\s+(\\w+)\\s+cartas?")
	var m_draw := draw_rx.search(ability_text)
	var draw_amount: int = UniversalCardParser._parse_amount(m_draw.get_string(1)) if m_draw else 0

	var cost_rx := RegEx.new()
	cost_rx.compile("(?i)coste\\s+(\\w+)\\s+o\\s+m[aá]s")
	var m_cost := cost_rx.search(ability_text)
	var min_cost: int = UniversalCardParser._parse_amount(m_cost.get_string(1)) if m_cost else 0

	var search_rx := RegEx.new()
	search_rx.compile("(?i)sube\\s+hasta\\s+(\\w+)\\s+cartas?\\s+de\\s+tu\\s+cementerio\\s+a\\s+tu\\s+mano")
	var m_search := search_rx.search(ability_text)
	var search_amount: int = UniversalCardParser._parse_amount(m_search.get_string(1)) if m_search else 0

	# Ventana única para las 3 partes juntas (ninguna pasa por un choke point
	# ya protegido por Prevención) — sin objetivos que declarar antes (robar/
	# generar Oro son automáticos, y a quién sube del Cementerio se elige
	# solo dentro de _resolve_search_cemetery_to_hand()).
	if await TriggerSystem.open_response_window(card, str(card.card_name) if card else "Legión Paladín", controller_id):
		return true

	if draw_amount > 0:
		await ActionModule.draw(controller_id, draw_amount, "etb_trigger", true)

	# 2026-10-06 (ver arquitectura.md §33): generar_oro_virtual_restringido()
	# y _resolve_search_cemetery_to_hand() ya son por jugador — el guard
	# 'controller_id == 0' de 2026-09-11 (bug real: el Oro restringido del
	# rival aparecía del lado del Anfitrión) ya no hace falta.
	if min_cost > 0 and main._gold_manager:
		var predicate := func(card_type: int, _card_race: String, card_cost: int) -> bool:
			return card_type in [Constants.CardType.ALIADO, Constants.CardType.ARMA] and card_cost >= min_cost
		main._gold_manager.generar_oro_virtual_restringido(1, predicate, "Aliados o Armas de coste %d o más" % min_cost, controller_id)

	if search_amount > 0:
		await _executor._resolve_search_cemetery_to_hand(controller_id, search_amount)

	return true


func try_execute_draw_reveal_talisman_gold_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""Detecta 'Roba una carta y puedes mostrar tu mano. Si no tienes más de
	un Talismán, genera un Oro para jugar Armas y Roba una carta adicional'
	(Levisterio, 2026-08-31). El 'mostrar tu mano' es cómo el jugador
	demuestra que cumple la condición del Talismán — no hay sistema de
	revelado-verificable de mano en este motor (SelectionCanvas.
	reveal_hand_cards() existe pero está huérfana/sin instanciar, ver
	arquitectura.md), así que se resuelve leyendo la mano directamente y
	dejando constancia en el log en vez de abrir una UI de revelado nueva
	para un único caso. El bonus condicional solo se evalúa para
	controller_id == 0 (mismo alcance ya usado por search_amount en
	try_execute_draw_gold_search_pattern) — no hay mano de IA modelada
	carta por carta para poder contar sus Talismanes.
	Returns: true si el patrón aplicaba."""
	var lower := ability_text.to_lower()
	if not ("puedes mostrar tu mano" in lower and "genera un oro para jugar armas" in lower and "roba una carta adicional" in lower):
		return false

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main:
		return true
	if await TriggerSystem.open_response_window(card, str(card.card_name) if card else "Levisterio", controller_id):
		return true

	await ActionModule.draw(controller_id, 1, "etb_trigger", true)

	# 2026-10-06 (ver arquitectura.md §33): generar_oro_virtual_restringido()
	# ya es por jugador — el guard 'controller_id == 0' de arriba ya no hace
	# falta; la mano a contar es la del jugador real que activó la carta.
	var hand_container_levisterio = main.player_hand if controller_id == 0 else main._opponent_fan
	if hand_container_levisterio:
		var talisman_count: int = 0
		for c in hand_container_levisterio.cards:
			if is_instance_valid(c) and c.card_type == Constants.CardType.TALISMAN:
				talisman_count += 1
		main._update_debug("Levisterio: mano mostrada (%d Talismán%s)" % [talisman_count, "" if talisman_count == 1 else "es"])
		if talisman_count <= 1 and main._gold_manager:
			var predicate := func(card_type: int, _card_race: String, _card_cost: int) -> bool:
				return card_type == Constants.CardType.ARMA
			main._gold_manager.generar_oro_virtual_restringido(1, predicate, "Armas", controller_id)
			await ActionModule.draw(controller_id, 1, "etb_trigger", true)

	return true


func try_execute_deck_top_or_bottom_to_hand_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""Detecta 'pon la primera o la última carta de tu Castillo en tu mano'
	(La Ouija, 2026-08-31 — carta promocional de 'IMP - Chile Oscuro 2', sin
	myl_id real, no está en la API externa; ver nota de fuente en
	_activate_ouija_play_from_cemetery_or_deck_top(), HandCementerioAbilityHandler.gd).
	Sin 'puedes': mandatorio, pero con una elección real entre las dos
	cartas (no 'la que sea al azar'). 'primera' = tope (índice 0, ver
	convención real documentada en CardManager.add_to_deck_top()), 'última'
	= fondo.
	Returns: true si el patrón aplicaba."""
	var lower := ability_text.to_lower()
	if not ("primera o la última carta de tu castillo" in lower and "en tu mano" in lower):
		return false
	if controller_id != 0:
		return false  # el bot no usa esta habilidad todavía

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main or main.player_deck.is_empty():
		return true

	# El revelado del tope (segunda mitad del texto de La Ouija: 'Juega
	# mostrando la primera carta de tu Castillo') arranca DESDE EL PRIMER
	# SEGUNDO que entra en juego (2026-08-31, corrección a pedido del
	# usuario: antes esto solo se aplicaba a la habilidad de una vez por
	# turno) — refrescar AQUÍ, antes de ofrecer la elección tope/fondo, para
	# que el jugador ya sepa cuál es la del tope al decidir (la de fondo
	# sigue a ciegas). La carta ya es hija de player_gold con zona
	# RESERVA_ORO en este punto (_trigger_enter_play() se llama después de
	# _place_card_as_gold() la deja en su lugar), así que la detección por
	# texto en refresh_castillo_top_reveal() ya la encuentra.
	if main._zone_viewer:
		main._zone_viewer.refresh_castillo_top_reveal()

	var choose_top: bool = true
	if main.player_deck.size() > 1:
		var top_card: Dictionary = main.player_deck.front()
		var bottom_card: Dictionary = main.player_deck.back()
		choose_top = await SelectionManager.await_card_pair_choice(
			main, "La Ouija",
			top_card, bottom_card,
			"Tope",
			"Fondo",
			true, false
		)

	if await TriggerSystem.open_response_window(card, str(card.card_name) if card else "La Ouija", controller_id):
		return true
	var card_data: Dictionary = main.player_deck.pop_front() if choose_top else main.player_deck.pop_back()
	var card_node: Node = main._create_card(card_data, false)
	main.player_hand.add_card(card_node)
	main._connect_card_signals(card_node)
	if main._zone_manager:
		main._zone_manager._update_castillo_counts()

	return true
