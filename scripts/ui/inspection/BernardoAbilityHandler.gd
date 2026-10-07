extends RefCounted
class_name BernardoAbilityHandler
## BernardoAbilityHandler — Caso especial de Bernardo O'Higgins: coste
## alternativo (Barajar un Arma/Aliado Caballero) + elección de efecto con
## objetivo (Desterrar coste ≤3 o cancelar habilidad). Detectado en
## CardInspectionLayer._build_ability_buttons() (is_bernardo_pattern) y
## ruteado aquí en vez de al pipeline genérico de habilidades activadas.
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

	if not _main._card_interaction:
		return
	# 2026-09-13, a pedido del usuario: click directo sobre la mano/campo en
	# vez del modal de lista viejo.
	var cost_filter := func(c: Node) -> bool: return c in candidates
	var cost_card: Node = await _main._card_interaction.await_target(
		"Baraja un Arma o Caballero (coste de la habilidad)", cost_filter)
	if not cost_card or not is_instance_valid(cost_card):
		return  # canceló — no se pagó nada, no se marca "una vez por turno"
	# source_card se usa después de este await (2026-09-13, bug real:
	# "Invalid type... (previously freed)" al llamar _bernardo_banish_
	# target). Mismo motivo ya documentado en HandCementerioAbilityHandler.
	# gd: el await de arriba es tiempo real de espera del jugador — si
	# Bernardo salió de juego mientras tanto (destruido/desterrado por
	# cualquier vía), queda una referencia colgante.
	if not is_instance_valid(source_card) or not is_instance_valid(cost_card):
		return

	var cost_owner: int = cost_card.owner_id if cost_card.get("owner_id") != null else 0
	_bernardo_shuffle_into_deck(cost_card, cost_owner)

	# "Una vez por turno" se marca solo ahora que el coste ya se pagó de
	# verdad — mismo criterio que ActionPipeline.activate_ability() (Paso B).
	# register_ability_use() usa el instance_id de source_card (2026-08-30),
	# no card_data.id — cada copia física necesita su propio cupo.
	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	# 2026-09-19, a pedido explícito del usuario: ya NO se pregunta "Desterrar
	# o Cancelar" con un diálogo — la rama se elige SOLA según el momento en
	# que se usa Bernardo. En tu propio turno o en Guerra de Talismanes
	# (proactivo, sin responder a nada puntual) siempre Desterrar; respondiendo
	# a que el rival jugó una carta o usó una habilidad (ventana de respuesta
	# real, §10.53) siempre Cancelar. Ver AbilityButtonSupport._is_responding_
	# to_opponent_action(). _show_bernardo_effect_choice() queda huérfana (no
	# borrada, ver su docstring) por si hace falta volver a una elección
	# manual.
	if not is_instance_valid(source_card):
		return

	if _inspector._button_support._is_responding_to_opponent_action():
		await _bernardo_cancel_ability_target(source_card)
	else:
		await _bernardo_banish_target(source_card)


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
	# 2026-09-19, SIN LLAMADOR HOY A PROPÓSITO — reemplazada por elección
	# automática según contexto en _activate_bernardo_shuffle_removal() (ver
	# AbilityButtonSupport._is_responding_to_opponent_action(), a pedido del
	# usuario). No se borró: si algún día se quisiera volver a una elección
	# manual (p.ej. el usuario decide que no le gusta la automática), queda
	# lista para reconectar.
	#
	# 2026-09-13, bug real reportado por el usuario: este diálogo es hijo de
	# inspection_layer, la misma capa que close_card_inspection() (llamada
	# al activar el botón de Bernardo, antes de este punto) apaga con un
	# retraso de ~0.2s (tween de cierre) — sin avisarle a esa capa que hay
	# contenido nuevo, el apagón diferido lo dejaba presente pero invisible
	# hasta el próximo click derecho. Ver mark_inspection_layer_in_use().
	_inspector.mark_inspection_layer_in_use()
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
	# mouse_filter = IGNORE ANTES de queue_free() (2026-09-06, a raíz de un
	# reporte del usuario de clicks que "no detectaban" el siguiente paso de
	# selección de objetivo justo después de elegir aquí): queue_free() no
	# saca al nodo del árbol hasta el final del frame — este ColorRect a
	# pantalla completa seguía activo (con su mouse_filter STOP por
	# defecto) durante ese frame y podía tragarse el primer click que el
	# jugador daba sobre la carta objetivo real, si llegaba a caer justo
	# ahí. Poniéndolo en IGNORE de inmediato, cualquier click de ese mismo
	# frame pasa de largo hacia las cartas de abajo sin esperar a que el
	# nodo se libere de verdad.
	var btn_banish = Button.new()
	btn_banish.text = "Desterrar una carta de coste 3 o menos"
	btn_banish.pressed.connect(func():
		overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		overlay.queue_free()
		on_choice.call("desterrar")
	)
	vbox.add_child(btn_banish)
	var btn_cancel = Button.new()
	btn_cancel.text = "Cancelar la habilidad de una carta"
	btn_cancel.pressed.connect(func():
		overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		overlay.queue_free()
		on_choice.call("cancelar")
	)
	vbox.add_child(btn_cancel)


func _bernardo_banish_target(source_card: Node) -> void:
	if not _inspector._main._card_interaction:
		return
	var filter := func(c: Node) -> bool:
		# Bernardo SÍ puede ser objetivo válido de su propio Destierro
		# (2026-09-06, corregido: el usuario confirmó que puede desterrarse
		# a sí mismo/a otra copia con nombre Bernardo con esta habilidad —
		# nada en el texto lo prohíbe, revertido un intento anterior de
		# excluirlo).
		if not (c.get("card_type") in [Constants.CardType.ALIADO, Constants.CardType.ARMA, Constants.CardType.TOTEM]):
			return false
		return int(c.get("card_cost")) <= 3
	var chosen: Node = await _inspector._main._card_interaction.await_target(
		"Elige una carta de coste 3 o menos para Desterrar", filter)
	if chosen and is_instance_valid(chosen) and is_instance_valid(source_card):
		await ActionModule.banish([chosen], source_card, true)


func _bernardo_cancel_ability_target(source_card: Node) -> void:
	if not _inspector._main._card_interaction:
		return
	var filter := func(c: Node) -> bool:
		return c.get("card_type") == Constants.CardType.ALIADO
	var chosen: Node = await _inspector._main._card_interaction.await_target(
		"Elige un Aliado que pierda su habilidad", filter)
	if chosen and is_instance_valid(chosen) and is_instance_valid(source_card):
		await KeywordManager.silence_card(chosen, source_card, "permanent")
