extends RefCounted
class_name BernardoAbilityHandler
## BernardoAbilityHandler — Caso especial de Bernardo O'Higgins: coste
## alternativo (Barajar un Arma/Aliado Caballero) + elección de efecto con
## objetivo (Desterrar coste ≤3 o cancelar habilidad). Detectado en
## CardInspectionLayer._build_ability_buttons() (is_bernardo_pattern) y
## ruteado acá en vez de al pipeline genérico de habilidades activadas.
## Opera sobre CardInspectionLayer via _inspector (y sobre el Main del juego
## via _inspector._main).
## Extraído de CardInspectionLayer.gd (2026-08-28, "módulos gordos").

var _inspector: CardInspectionLayer


func setup(inspector: CardInspectionLayer) -> void:
	_inspector = inspector


func _activate_bernardo_shuffle_removal(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, puedes Barajar un Arma o Aliado Caballero de tu
	mano o que controles para Desterrar una carta de coste 3 o menos o
	cancelar una habilidad. No se pueden Barajar Aliados con Arma.' Texto
	confirmado por el usuario (2026-08-26) — la versión cacheada de la API
	trae la misma idea con las cláusulas reordenadas."""
	if not is_instance_valid(source_card):
		return

	var _main := _inspector._main
	var candidates: Array = []
	if _main.player_hand:
		for c in _main.player_hand.cards:
			if _bernardo_can_shuffle(c):
				candidates.append(c)
	for field in [_main.player_field, _main.player_linea_ataque]:
		if not field:
			continue
		for c in field.get_children():
			if c != source_card and _bernardo_can_shuffle(c):
				candidates.append(c)
			var weapons = c.get("equipped_weapons")
			if weapons is Array:
				for w in weapons:
					if _bernardo_can_shuffle(w):
						candidates.append(w)

	if candidates.is_empty():
		_main._update_debug("No tienes un Arma ni un Aliado Caballero para Barajar")
		return

	var candidate_data: Array = candidates.map(func(c): return c.card_data)
	var picked: Dictionary = await SelectionManager.await_single_pick(
		candidate_data, "Baraja un Arma o Caballero (coste de la habilidad)", true, 0)
	if picked.is_empty():
		return  # canceló — no se pagó nada, no se marca "una vez por turno"

	var cost_card: Node = null
	for c in candidates:
		if is_instance_valid(c) and c.card_data == picked:
			cost_card = c
			break
	if not cost_card:
		return

	var cost_owner: int = cost_card.owner_id if cost_card.get("owner_id") != null else 0
	_bernardo_shuffle_into_deck(cost_card, cost_owner)

	# "Una vez por turno" recién se marca ahora que el coste ya se pagó de
	# verdad — mismo criterio que ActionPipeline.activate_ability() (Paso B).
	# register_ability_use() usa el instance_id de source_card (2026-08-30),
	# no card_data.id — cada copia física necesita su propio cupo.
	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	var choice_state := {"resolved": false, "choice": ""}
	_show_bernardo_effect_choice(func(c: String):
		choice_state.choice = c
		choice_state.resolved = true
	)
	while not choice_state.resolved:
		await _inspector.get_tree().process_frame

	if choice_state.choice == "desterrar":
		await _bernardo_banish_target(source_card)
	elif choice_state.choice == "cancelar":
		await _bernardo_cancel_ability_target(source_card)


func _bernardo_can_shuffle(c: Node) -> bool:
	if not is_instance_valid(c):
		return false
	if c.get("card_type") == Constants.CardType.ARMA:
		return true
	if c.get("card_type") == Constants.CardType.ALIADO:
		var raza: String = str(c.get("card_raza") if c.get("card_raza") != null else "").to_lower()
		if not ("caballero" in raza):
			return false
		var weapons = c.get("equipped_weapons")
		if weapons is Array and not weapons.is_empty():
			return false  # No se pueden Barajar Aliados con Arma
		return true
	return false


func _bernardo_shuffle_into_deck(card: Node, owner_id: int) -> void:
	var cm := CardManager
	var _main := _inspector._main
	var data: Dictionary = card.card_data.duplicate()
	data["esta_oculta"] = true
	var parent = card.get_parent()
	if parent == _main.player_hand:
		var idx = _main.player_hand.cards.find(card)
		if idx >= 0:
			_main.player_hand.cards.remove_at(idx)
		_main.player_hand.remove_child(card)
		_main.player_hand._arrange_cards()
	elif parent:
		parent.remove_child(card)
	card.queue_free()
	cm.add_to_deck_top(owner_id, data)
	cm.shuffle_deck(owner_id)
	if _main._zone_manager:
		_main._zone_manager._update_castillo_counts()


func _show_bernardo_effect_choice(on_choice: Callable) -> void:
	var overlay = ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.55)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_inspector._main.inspection_layer.add_child(overlay)
	var panel = PanelContainer.new()
	panel.set_anchor(SIDE_LEFT,   0.5)
	panel.set_anchor(SIDE_TOP,    0.5)
	panel.set_anchor(SIDE_RIGHT,  0.5)
	panel.set_anchor(SIDE_BOTTOM, 0.5)
	panel.set_offset(SIDE_LEFT,  -210)
	panel.set_offset(SIDE_TOP,   -85)
	panel.set_offset(SIDE_RIGHT,  210)
	panel.set_offset(SIDE_BOTTOM, 85)
	overlay.add_child(panel)
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)
	var lbl = Label.new()
	lbl.text = "Elige el efecto"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 13)
	vbox.add_child(lbl)
	var btn_banish = Button.new()
	btn_banish.text = "Desterrar una carta de coste 3 o menos"
	btn_banish.pressed.connect(func():
		overlay.queue_free()
		on_choice.call("desterrar")
	)
	vbox.add_child(btn_banish)
	var btn_cancel = Button.new()
	btn_cancel.text = "Cancelar la habilidad de una carta"
	btn_cancel.pressed.connect(func():
		overlay.queue_free()
		on_choice.call("cancelar")
	)
	vbox.add_child(btn_cancel)


func _bernardo_banish_target(source_card: Node) -> void:
	if not _inspector._main._card_interaction:
		return
	var filter := func(c: Node) -> bool:
		if not (c.get("card_type") in [Constants.CardType.ALIADO, Constants.CardType.ARMA, Constants.CardType.TOTEM]):
			return false
		return int(c.get("card_cost")) <= 3
	var chosen: Node = await _inspector._main._card_interaction.await_target(
		"Elige una carta de coste 3 o menos para Desterrar", filter)
	if chosen and is_instance_valid(chosen):
		await ActionModule.banish([chosen], source_card, true)


func _bernardo_cancel_ability_target(source_card: Node) -> void:
	if not _inspector._main._card_interaction:
		return
	var filter := func(c: Node) -> bool:
		return c.get("card_type") == Constants.CardType.ALIADO
	var chosen: Node = await _inspector._main._card_interaction.await_target(
		"Elige un Aliado que pierda su habilidad", filter)
	if chosen and is_instance_valid(chosen):
		KeywordManager.silence_card(chosen, source_card, "permanent")
