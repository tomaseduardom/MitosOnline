extends Node
class_name GoldManager
## GoldManager — Sistema de pago de costes y gestión de Oro (DAR Secciones 6 y 8).
## Se instancia como hijo de Main en _ready(). Accede a nodos de Main via _main.

var _main: Node = null
var oros_virtuales: int = 0

func setup(main: Node) -> void:
	_main = main


func _place_card_as_gold(card: Node) -> void:
	if card.get_parent() != _main.player_hand:
		_main._update_debug("Solo puedes colocar cartas de la mano como Oro")
		return
	if card.card_type != Constants.CardType.ORO:
		_main._update_debug("Solo puedes colocar cartas de tipo Oro")
		return
	if not TurnManager.can_place_oro(GameManager.current_phase):
		_main._update_debug("No puedes colocar Oro ahora")
		if _main._card_interaction: _main._card_interaction.is_placing_gold = false
		return
	var pm_check3 = get_node_or_null("/root/PriorityManager")
	if pm_check3 and pm_check3.priority_window_active:
		_main._update_debug("Resuelve la respuesta pendiente (¿Paso?) antes de colocar otro Oro")
		if _main._card_interaction: _main._card_interaction.is_placing_gold = false
		return
	var start_pos = card.global_position
	var idx = _main.player_hand.cards.find(card)
	if idx >= 0:
		_main.player_hand.cards.remove_at(idx)
	_main.player_hand.remove_child(card)
	_main.player_hand._arrange_cards()
	card.can_interact = false
	_main.player_gold.add_child(card)
	# Ver GoldManager._play_card_to_field() — misma corrección: sin esto,
	# 'end_pos' más abajo terminaba siendo la última posición del arrastre.
	card.top_level = false
	card.set_zone(Constants.Zone.RESERVA_ORO)
	await get_tree().process_frame
	var end_pos = card.global_position
	card.global_position = start_pos
	card.scale = Vector2.ONE
	var tween = create_tween()
	tween.tween_property(card, "global_position", end_pos, 0.3).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	await tween.finished
	card.base_scale = Vector2.ONE
	card.can_interact = true
	TurnManager.oro_placed_this_turn = true
	TurnManager.any_card_played_this_turn = true
	_main.gold_cards.append(card)
	if _main._game_state:
		_main._game_state.agregar_oro_reserva(0, 1)
	var oro_actual = _main._game_state.get_oro_reserva(0) if _main._game_state else _main.gold_cards.size()
	_main._update_debug("%s colocado como Oro (Reserva: %d)" % [card.card_name, oro_actual])
	if _main._card_interaction: _main._card_interaction.is_placing_gold = false
	_update_gold_display()
	_main._update_buttons_for_phase(GameManager.current_phase)
	# Los Oros también pueden tener habilidades "Al entrar" (p.ej. Signo
	# Amarillo: "mira 4 cartas del tope") — este camino nunca las disparaba,
	# a diferencia de _play_card_to_field()/_play_talisman() que sí lo hacen.
	await _trigger_enter_play(card, Constants.Zone.RESERVA_ORO)


func play_card(card: Node) -> bool:
	if GameManager.current_phase != Constants.Phase.VIGILIA:
		_main._update_debug("Solo puedes jugar cartas en Vigilia")
		card.return_to_hand()
		return false
	if GameManager.active_player_id != 0:
		_main._update_debug("No es tu turno")
		card.return_to_hand()
		return false
	# Si hay una ventana de prioridad abierta (respuesta a un trigger que se
	# acaba de disparar, p.ej. 'cuando entre en juego' de la carta anterior),
	# no dejar jugar otra carta todavía — el trigger pendiente quedaba
	# pospuesto y se resolvía recién cuando pasaba OTRA acción, en el
	# momento equivocado. Hay que resolver esa ventana primero (¿Paso?).
	var pm_check2 = get_node_or_null("/root/PriorityManager")
	if pm_check2 and pm_check2.priority_window_active:
		_main._update_debug("Resuelve la respuesta pendiente (¿Paso?) antes de jugar otra carta")
		card.return_to_hand()
		return false
	if card.card_type == Constants.CardType.ORO:
		await _place_card_as_gold(card)
		return true
	if card.card_type == Constants.CardType.ARMA and not _player_has_ally_in_play():
		_main._update_debug("No puedes jugar un Arma sin Aliados en juego")
		await _return_card_rejected(card)
		return false
	var coste_real = PaymentManager.calcular_coste_real(card)
	if not PaymentManager.puede_jugar_carta(card, 0):
		var disponible = get_oro_disponible()
		_main._update_debug("Oro insuficiente: necesitas %d, tienes %d (gastado este turno: %d)" % [
			coste_real, disponible, PaymentManager.oro_gastado_este_turno])
		await _return_card_rejected(card)
		return false
	if coste_real > 0:
		await pagar_coste(coste_real)
		PaymentManager.registrar_pago(coste_real)
	if card.card_type == Constants.CardType.TALISMAN:
		await _play_talisman(card)
	else:
		await _play_card_to_field(card)
	return true


func _player_has_ally_in_play() -> bool:
	"""Verifica si el jugador tiene al menos un Aliado en juego (requisito
	para poder jugar un Arma — sin portador no tiene sentido)."""
	if not _main.player_field:
		return false
	for card in _main.player_field.get_children():
		if card.get("card_type") == Constants.CardType.ALIADO:
			return true
	return false


func _return_card_rejected(card: Node) -> void:
	if not card or not is_instance_valid(card):
		return
	# Si la carta nunca fue arrastrada (doble click), original_position es Vector2.ZERO — corregirlo
	# antes de llamar return_to_hand(), que usa esa propiedad para animar el regreso.
	if card.get("original_position") != null and card.original_position == Vector2.ZERO:
		card.original_position = card.global_position
	# Flash rojo — sin tweenear global_position para no pelear con el layout del contenedor
	var tween = create_tween()
	tween.tween_property(card, "modulate", Color(1.5, 0.3, 0.3, 1.0), 0.08)
	await tween.finished
	var tween2 = create_tween()
	tween2.tween_property(card, "modulate", Color.WHITE, 0.2)
	await tween2.finished
	card.return_to_hand()


func _play_card_to_field(card: Node) -> void:
	TurnManager.on_card_played(card)
	_main._update_debug("Jugando: %s" % card.card_name)
	var start_pos = card.global_position
	var idx = _main.player_hand.cards.find(card)
	if idx >= 0:
		_main.player_hand.cards.remove_at(idx)
	_main.player_hand.remove_child(card)
	_main.player_hand._arrange_cards()
	card.can_interact = false
	_main.player_field.add_child(card)
	# Si la carta llegó por arrastre (drag), top_level seguía en true (modo
	# 'posición global libre' que usa Card._update_drag()). Sin resetearlo,
	# el contenedor no puede posicionarla de verdad, y el 'end_pos' leído
	# más abajo terminaba siendo la última posición del arrastre en vez de
	# la casilla real del campo — la carta se animaba hacia un lugar sin
	# relación con el campo, dando la sensación de que desaparecía.
	card.top_level = false
	card.set_zone(Constants.Zone.LINEA_DEFENSA)
	for sibling in _main.player_field.get_children():
		if sibling == card:
			continue
		print("[DEBUG-FIELD] al entrar '%s': vecino '%s' visible=%s modulate.a=%s rot=%s pos=%s" % [
			card.card_name, sibling.get("card_name"), sibling.visible, sibling.modulate.a,
			sibling.rotation_degrees, sibling.position
		])
	await get_tree().process_frame
	var end_pos = card.global_position
	card.global_position = start_pos
	card.scale = Vector2.ONE
	var tween = create_tween()
	tween.tween_property(card, "global_position", end_pos, 0.3).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	await tween.finished
	card.base_scale = Vector2.ONE
	card.can_interact = true
	VisualManager.play_card_effect(card.card_cost)
	if card.has_method("play_enter_animation"):
		card.play_enter_animation()
	_update_gold_display()
	_main._update_buttons_for_phase(GameManager.current_phase)
	await _trigger_enter_play(card)


func _trigger_enter_play(card: Node, zone: int = Constants.Zone.LINEA_DEFENSA) -> void:
	"""Dispara la entrada al juego (DAR 7.4) para habilidades 'Al entrar'.

	Este método mueve la carta directamente (ver player_field.add_child arriba)
	en vez de pasar por EffectController.play_card_to_zone(), porque esa función
	depende de un GameBoard legacy que no está activo en la escena actual (su
	@onready apunta a nodos de un layout de tablero anterior — BattleField/
	PlayerLineaDefensa/etc. — que ya no existe en Main.tscn).

	CardEffectSystem sigue escuchando la señal (fire-and-forget) solo para
	recalcular efectos continuos — su propia ejecución de texto está
	desactivada a propósito para no duplicar el efecto. Pero el trigger en
	sí (TriggerSystem → UniversalCardParser → ActionModule) se llama DIRECTO
	con 'await' en vez de por señal: conectado por señal, quien juega la
	carta no esperaba a que el trigger terminara de resolverse, así que el
	juego seguía de fase mientras el trigger todavía se procesaba en
	segundo plano — se vio con Drácula y Signo Amarillo resolviendo recién
	en la fase de Bloqueo, varios pasos después de jugarse."""
	var card_factory = get_node_or_null("/root/CardFactory")
	if card_factory and card_factory.has_method("on_card_enters_play"):
		card_factory.on_card_enters_play(card)
	if card.has_method("on_entered_play"):
		card.on_entered_play()
	var effect_ctrl = get_node_or_null("/root/EffectController")
	if effect_ctrl:
		effect_ctrl.emit_signal("on_card_entered_play", 0, card, zone)
	await TriggerSystem._collect_triggers_for_event("on_enter_play", {
		"player_id": 0, "card": card, "zone": zone
	})


func _play_talisman(card: Node) -> void:
	"""Los Talismanes se resuelven al jugarse y no se quedan en el campo
	como un Aliado (DAR Sección 8): disparan su habilidad y van al
	Cementerio — o al Destierro si su propio texto dice 'destiérralo'."""
	TurnManager.on_card_played(card)
	_main._update_debug("Jugando talismán: %s" % card.card_name)

	var idx = _main.player_hand.cards.find(card)
	if idx >= 0:
		_main.player_hand.cards.remove_at(idx)
	_main.player_hand.remove_child(card)
	_main.player_hand._arrange_cards()
	card.can_interact = false
	_main.player_field.add_child(card)
	# Ver GoldManager._play_card_to_field() — misma corrección.
	card.top_level = false
	card.set_zone(Constants.Zone.LINEA_APOYO)
	await get_tree().create_timer(0.3).timeout

	await _trigger_enter_play(card, Constants.Zone.LINEA_APOYO)
	await get_tree().create_timer(0.4).timeout  # Dar tiempo a que la habilidad resuelva

	var habilidad: String = card.card_ability.to_lower() if card.get("card_ability") else ""
	var self_exile := "destierr" in habilidad  # cubre "destiérralo", "destierra esta carta", etc.

	var effect_ctrl = get_node_or_null("/root/EffectController")
	if effect_ctrl:
		if self_exile:
			await effect_ctrl.exile_card(0, card)
		else:
			await effect_ctrl.destroy_card(0, card)

	_update_gold_display()
	_main._update_buttons_for_phase(GameManager.current_phase)


func _update_gold_display() -> void:
	var available = 0
	for card in _main.gold_cards:
		if card.modulate == Color(1, 1, 1, 1):
			available += 1
	# Display visual is the gold reserve itself
	# El oro disponible cambió — recalcular qué habilidades activadas se
	# pueden pagar ahora (brillo celeste, ver CardInspectionLayer).
	if _main._card_inspector:
		_main._card_inspector.refresh_activatable_glows()


func _reset_gold() -> void:
	var oros_pagados = _main.player_oro_pagado.get_children().duplicate()
	for card in oros_pagados:
		await _mover_oro_a_reserva(card)
	if _main._game_state:
		_main._game_state.reagrupar_oro(0)
	_update_gold_display()


func puede_pagar(cantidad: int) -> bool:
	var oro_fisico = _main._game_state.get_oro_reserva(0) if _main._game_state else _main.player_gold.get_child_count()
	var disponible = oros_virtuales + oro_fisico
	return disponible >= cantidad


func pagar_coste(cantidad: int) -> bool:
	if not puede_pagar(cantidad):
		var disponible = oros_virtuales + _main.player_gold.get_child_count()
		_main._update_debug("Oro insuficiente: necesitas %d, tienes %d (V:%d + F:%d)" % [
			cantidad, disponible, oros_virtuales, _main.player_gold.get_child_count()])
		return false
	if cantidad <= 0:
		return true
	var restante = cantidad
	if oros_virtuales > 0:
		var virtuales_usados = mini(oros_virtuales, restante)
		oros_virtuales -= virtuales_usados
		restante -= virtuales_usados
		_main._update_debug("Consumido %d Oro Virtual (quedan %d)" % [virtuales_usados, oros_virtuales])
	if restante > 0:
		_main._update_debug("Pagando %d Oro físico..." % restante)
		var oros_reserva = _main.player_gold.get_children()
		for i in range(restante):
			if i >= oros_reserva.size():
				break
			await _mover_oro_a_pagado(oros_reserva[i])
		if _main._game_state:
			_main._game_state.pagar_oro(0, restante)
	TurnManager.any_card_played_this_turn = true
	var oro_restante = _main._game_state.get_oro_reserva(0) if _main._game_state else _main.player_gold.get_child_count()
	_main._update_debug("Pagado %d Oro total (Reserva: %d, Virtual: %d)" % [cantidad, oro_restante, oros_virtuales])
	_update_gold_display()
	return true


func generar_oros_virtuales(cantidad: int) -> void:
	oros_virtuales += cantidad
	_main._update_debug("Generado %d Oro Virtual (total: %d)" % [cantidad, oros_virtuales])
	_update_gold_display()


func limpiar_oros_virtuales() -> void:
	if oros_virtuales > 0:
		_main._update_debug("Oros Virtuales expirados: %d" % oros_virtuales)
		oros_virtuales = 0
		_update_gold_display()


func _mover_oro_a_pagado(card: Node) -> void:
	var start_pos = card.global_position
	_main.player_gold.remove_child(card)
	card.can_interact = false
	_main.player_oro_pagado.add_child(card)
	await get_tree().process_frame
	var end_pos = card.global_position
	card.global_position = start_pos
	var tween = create_tween()
	tween.tween_property(card, "global_position", end_pos, 0.25).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.parallel().tween_property(card, "modulate", Color(0.6, 0.6, 0.6, 1.0), 0.25)
	await tween.finished
	card.can_interact = true


func _mover_oro_a_reserva(card: Node) -> void:
	var start_pos = card.global_position
	_main.player_oro_pagado.remove_child(card)
	card.can_interact = false
	_main.player_gold.add_child(card)
	await get_tree().process_frame
	var end_pos = card.global_position
	card.global_position = start_pos
	var tween = create_tween()
	tween.tween_property(card, "global_position", end_pos, 0.25).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.parallel().tween_property(card, "modulate", Color(1, 1, 1, 1), 0.25)
	await tween.finished
	card.can_interact = true


func get_oro_disponible() -> int:
	if _main._game_state:
		return _main._game_state.get_oro_reserva(0)
	return _main.player_gold.get_child_count()


func get_oro_pagado() -> int:
	if _main._game_state:
		return _main._game_state.get_oro_pagado(0)
	return _main.player_oro_pagado.get_child_count()


func get_oro_total() -> int:
	if _main._game_state:
		return _main._game_state.get_oro_total(0)
	return get_oro_disponible() + get_oro_pagado()
