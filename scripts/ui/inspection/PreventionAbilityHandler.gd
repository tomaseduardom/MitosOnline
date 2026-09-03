extends RefCounted
## PreventionAbilityHandler — Patrones especiales de habilidades ACTIVADAS
## de protección/prevención y descuentos ligados a un Arma (Legión Paladín,
## Estaca — prevención, Drácula — autoconvertirse, Paladín Bestiarium — 2
## habilidades). Detectados en CardInspectionLayer._build_ability_buttons()
## y ruteados acá en vez de al pipeline genérico de habilidades activadas.
## Opera sobre CardInspectionLayer via _inspector (y sobre el Main del juego
## via _inspector._main).
## Extraído de CardInspectionLayer.gd (2026-08-30, "módulos gordos" — mismo
## corte que ya separó BernardoAbilityHandler/ResponseWindowHandler).

var _inspector: CardInspectionLayer


func setup(inspector: CardInspectionLayer) -> void:
	_inspector = inspector


func _activate_legion_paladin_prevention(source_card: Node) -> void:
	"""'Puedes Desterrarlo para prevenir que un Aliado que controles salga
	del juego' (Legión Paladín — texto reconfirmado 2026-08-29 contra un
	fetch en vivo de la API, sincronizado al cache local). Sin objetivo: se
	destierra la propia carta (bypass_prevention=true — pagar el costo
	nunca debe poder bloquearse por una Prevención propia ya activa) y se
	agrega 1 carga de Prevención al jugador."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	await EffectController.exile_card(owner_id, source_card, true)
	EffectController.add_leave_play_prevention(owner_id, 1)


func _activate_estaca_banish_for_prevention(source_card: Node, ability: Dictionary) -> void:
	"""'Puedes Desterrarla para prevenir que una carta sea afectada por un
	efecto oponente' (Estaca, 2026-08-30). Sin posesivo en 'una carta' —
	el jugador elige cuál proteger, en cualquiera de las tres zonas de
	campo de cualquiera de los dos jugadores (mismo criterio ya usado para
	'un Aliado o Tótem' de Aho). Alcance de la protección confirmado por
	el usuario: solo efectos CON OBJETIVO del rival (anular/destruir/
	desterrar/debuff/silenciar), no daño de combate ni auras pasivas — ver
	EffectController.try_consume_opponent_effect_prevention()."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía

	var candidates: Array = []
	for field in [_inspector._main.player_field, _inspector._main.player_linea_ataque, _inspector._main.player_linea_apoyo,
			_inspector._main.opponent_field, _inspector._main.opponent_linea_ataque, _inspector._main.opponent_linea_apoyo]:
		if not field:
			continue
		for c in field.get_children():
			if not is_instance_valid(c):
				continue
			candidates.append(c)
			var weapons = c.get("equipped_weapons")
			if weapons is Array:
				for w in weapons:
					if is_instance_valid(w):
						candidates.append(w)
	if candidates.is_empty():
		return

	var filter := func(c: Node) -> bool:
		return c in candidates
	var target: Node = await _inspector._main._card_interaction.await_target(
		"Elige una carta para proteger de un efecto rival", filter)
	if not target or not is_instance_valid(target):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	# Desvincular del Aliado portador ANTES de desterrarse (2026-08-30,
	# mismo motivo que la rama 'Descartar' de Paladín Bestiarium) —
	# CardManager.exile_card() no sabe de equipped_weapons cuando la carta
	# EN SÍ es un Arma equipada.
	var wielder = source_card.get_parent()
	if wielder and wielder.get("equipped_weapons") is Array:
		wielder.equipped_weapons.erase(source_card)

	await EffectController.exile_card(owner_id, source_card, true)
	EffectController.add_opponent_effect_prevention(target)


func _activate_dracula_convert_for_prevention(source_card: Node, ability: Dictionary) -> void:
	"""'Puedes convertirlo en un Oro sin habilidad para prevenir que una
	habilidad sea cancelada o un Aliado de coste 1 sea Anulado' (Drácula,
	2026-08-30). Sin objetivo que elegir — 'convertirlo' es sobre SÍ MISMO,
	a diferencia del Convertir con objetivo de Capitán O'Brien/Aho/Estaca.
	Otorga una carga reactiva (EffectController.add_stack_annul_cancel_
	prevention) que se consume sola la próxima vez que corresponda, no hay
	nada más que resolver acá."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0:
		return  # el bot no usa esta habilidad todavía

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	source_card.is_converted = true
	# is_converted por sí solo es solo visual (mismo criterio que Capitán
	# O'Brien/Aho/Estaca, ver TargetedEffectExecutor._execute_targeted_
	# convert()) — hace falta silence_card() para que de verdad deje de
	# poder usar sus otras 3 habilidades (2, 3 y 4), tal como dice el texto:
	# "convertirlo en un Oro SIN HABILIDAD".
	KeywordManager.silence_card(source_card, source_card, "permanent")
	EffectController.add_stack_annul_cancel_prevention(owner_id)
	_inspector._main._update_debug("Drácula se convierte — protege tu próxima habilidad cancelada o Aliado de coste 1 anulado")


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
