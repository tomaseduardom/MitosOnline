extends Node
class_name ZoneManager
## ZoneManager — Gestiona el Castillo (mazo), robo de cartas y movimientos entre zonas.
## Se instancia como hijo de Main en _ready().

const CardScene = preload("res://scenes/cards/Card.tscn")
## Tamaño inicial estándar del Castillo (DAR 4.1)
const CASTILLO_INITIAL_SIZE: int = 42

var _main: Node = null


func setup(main: Node) -> void:
	_main = main


# =============================================================================
# SISTEMA DE MAZO (CASTILLO)
# =============================================================================
func draw_card(player_id: int = 0) -> bool:
	"""Roba una carta del Castillo y la pone en la mano."""
	if player_id == 0:
		if _main.player_deck.is_empty():
			_main._update_debug("Tu Castillo esta vacio!")
			GameManager.check_victory()
			return false
		var card_data = _main.player_deck.pop_front()
		var card = _main._create_card(card_data)
		_main.player_hand.add_card(card)
		_main._connect_card_signals(card)
		card.modulate.a = 0
		var tween = create_tween()
		tween.tween_property(card, "modulate:a", 1.0, 0.3)
		_update_castillo_counts()
		_main._update_debug("Robas: %s" % card_data.nombre)
		return true
	else:
		if _main.opponent_deck.is_empty():
			GameManager.check_victory()
			return false
		var card_data = _main.opponent_deck.pop_front()
		var card = _main._create_card(card_data, true)
		_main._opponent_fan.add_card(card)
		_update_castillo_counts()
		return true


func draw_initial_hand(player_id: int, count: int = 7) -> void:
	"""Roba la mano inicial."""
	for i in range(count):
		await draw_card(player_id)


func _update_castillo_counts() -> void:
	"""Actualiza los contadores de cartas en los Castillos."""
	UIManager.sync_castillo_counts(_main.player_deck.size(), _main.opponent_deck.size())
	# Único punto de verdad para "el Castillo cambió" (robo normal, Destierra
	# N del tope de Aho, la habilidad de La Ouija, etc.) — refrescar acá el
	# revelado del tope (2026-08-31) evita tener que llamarlo a mano en cada
	# sitio que toca player_deck directo. Ver ZoneViewerModule.
	# refresh_castillo_top_reveal().
	if _main._zone_viewer:
		_main._zone_viewer.refresh_castillo_top_reveal()
	# Chequeo de victoria por Castillo vacío (DAR 2.1) — mismo motivo: antes
	# solo se chequeaba al INTENTAR robar con el mazo ya vacío (2026-08-31,
	# reportado por el usuario: desterrar el Castillo rival a 0 con Aho no
	# declaraba ganada la partida). Ver GameManager.check_victory() — ya
	# tiene su propio guard is_game_active, no hace falta repetirlo acá.
	GameManager.check_victory()


func shuffle_deck(player_id: int = 0) -> void:
	"""Baraja el mazo de un jugador."""
	if player_id == 0:
		_main.player_deck.shuffle()
	else:
		_main.opponent_deck.shuffle()


func move_card(from_zone: Constants.Zone, to_zone: Constants.Zone, amount: int = 1) -> void:
	"""Mueve 'amount' cartas de from_zone a to_zone (jugador 0).
	   Actualiza contadores de Castillo, Cementerio y Destierro en tiempo real."""
	for _i in range(amount):
		match [from_zone, to_zone]:

			[Constants.Zone.CASTILLO, Constants.Zone.CEMENTERIO]:
				if _main.player_deck.is_empty():
					_main._update_debug("Castillo vacío"); return
				var data = _main.player_deck.pop_front()
				data["esta_oculta"] = false
				CardManager.add_to_cemetery(0, data)
				_update_castillo_counts()

			[Constants.Zone.CASTILLO, Constants.Zone.DESTIERRO]:
				if _main.player_deck.is_empty():
					_main._update_debug("Castillo vacío"); return
				var data = _main.player_deck.pop_front()
				data["esta_oculta"] = false
				CardManager.get_exile(0).append(data)
				CardManager._emit_exile_changed(0)
				_update_castillo_counts()

			[Constants.Zone.MANO, Constants.Zone.CEMENTERIO]:
				var hand_cards = _main.player_hand.cards if _main.player_hand.get("cards") != null else _main.player_hand.get_children()
				if hand_cards.is_empty():
					_main._update_debug("Mano vacía"); return
				var card = hand_cards[randi() % hand_cards.size()]
				var data = card.card_data.duplicate() if card.get("card_data") else {}
				data["esta_oculta"] = false
				CardManager.add_to_cemetery(0, data)
				_main.player_hand.remove_card(card)

			_:
				push_warning("[ZoneManager] move_card: combinación de zonas no implementada")


# =============================================================================
# BOTONES DE PRUEBA (test_mode)
# =============================================================================
func setup_test_buttons() -> void:
	"""Crea un panel lateral con botones de prueba para las zonas."""
	var canvas = CanvasLayer.new()
	canvas.layer = 40
	_main.add_child(canvas)

	var vp = _main.get_viewport().get_visible_rect().size

	var panel = PanelContainer.new()
	panel.position = Vector2(vp.x - 140.0, vp.y / 2.0 - 130.0)
	panel.size = Vector2(130.0, 260.0)

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.1, 0.88)
	style.set_corner_radius_all(8)
	style.set_border_width_all(1)
	style.border_color = Color(0.4, 0.4, 0.6, 0.7)
	panel.add_theme_stylebox_override("panel", style)
	canvas.add_child(panel)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	var title = Label.new()
	title.text = "TEST ZONES"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 11)
	title.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
	vbox.add_child(title)

	var separator = HSeparator.new()
	vbox.add_child(separator)

	for btn_data in [
		["Botar 1", "_test_botar_uno"],
		["Desterrar Tope", "_test_desterrar_tope"],
		["Descartar Azar", "_test_descartar_azar"],
		["Mostrar Tope 3", "_test_mostrar_tope_tres"]
	]:
		var btn = Button.new()
		btn.text = btn_data[0]
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		btn.add_theme_font_size_override("font_size", 12)
		var bstyle = StyleBoxFlat.new()
		bstyle.bg_color = Color(0.15, 0.15, 0.25, 1.0)
		bstyle.set_corner_radius_all(5)
		btn.add_theme_stylebox_override("normal", bstyle)
		var hstyle = StyleBoxFlat.new()
		hstyle.bg_color = Color(0.25, 0.25, 0.45, 1.0)
		hstyle.set_corner_radius_all(5)
		btn.add_theme_stylebox_override("hover", hstyle)
		btn.pressed.connect(Callable(self, btn_data[1]))
		vbox.add_child(btn)


func _test_botar_uno() -> void:
	move_card(Constants.Zone.CASTILLO, Constants.Zone.CEMENTERIO, 1)
	_main._update_debug("Botada 1 carta al cementerio (Castillo: %d)" % _main.player_deck.size())


func _test_desterrar_tope() -> void:
	move_card(Constants.Zone.CASTILLO, Constants.Zone.DESTIERRO, 1)
	_main._update_debug("Tope desterrado (Castillo: %d)" % _main.player_deck.size())


func _test_descartar_azar() -> void:
	move_card(Constants.Zone.MANO, Constants.Zone.CEMENTERIO, 1)
	_main._update_debug("Carta al azar descartada al cementerio")


func _test_mostrar_tope_tres() -> void:
	"""Muestra las 3 cartas del tope del Castillo en un popup."""
	var top_count = mini(3, _main.player_deck.size())
	if top_count == 0:
		_main._update_debug("Castillo vacío"); return

	var existing = _main.get_node_or_null("TopTresPopup")
	if existing:
		existing.queue_free()

	var vp = _main.get_viewport().get_visible_rect().size
	var popup_canvas = CanvasLayer.new()
	popup_canvas.name = "TopTresPopup"
	popup_canvas.layer = 55
	_main.add_child(popup_canvas)

	var bg = ColorRect.new()
	bg.size = vp
	bg.color = Color(0, 0, 0, 0.55)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	bg.gui_input.connect(func(ev):
		if ev is InputEventMouseButton and ev.pressed:
			popup_canvas.queue_free()
	)
	popup_canvas.add_child(bg)

	var panel = PanelContainer.new()
	var card_w = 160.0
	var padding = 20.0
	var panel_w = top_count * card_w + (top_count - 1) * 12.0 + padding * 2.0
	panel.size = Vector2(panel_w, 320.0)
	panel.position = (vp - panel.size) / 2.0
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var pstyle = StyleBoxFlat.new()
	pstyle.bg_color = Color(0.08, 0.06, 0.12, 0.97)
	pstyle.set_corner_radius_all(10)
	pstyle.set_border_width_all(2)
	pstyle.border_color = Color(0.5, 0.4, 0.7)
	panel.add_theme_stylebox_override("panel", pstyle)
	popup_canvas.add_child(panel)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var lbl = Label.new()
	lbl.text = "Tope del Castillo (%d)" % top_count
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.9, 0.85, 1.0))
	vbox.add_child(lbl)

	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(hbox)

	for i in range(top_count):
		var card_data = _main.player_deck[i]
		var card = CardScene.instantiate()
		card.load_from_data(card_data)
		card.can_interact = false
		card.drag_enabled = false
		card.scale = Vector2(0.9, 0.9)
		card.custom_minimum_size = Vector2(card_w, 210.0)
		hbox.add_child(card)

	var close_btn = Button.new()
	close_btn.text = "Cerrar"
	close_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	close_btn.pressed.connect(func(): popup_canvas.queue_free())
	vbox.add_child(close_btn)


# =============================================================================
# SLOTS FIJOS DE LÍNEA DE DEFENSA/APOYO (2026-08-31, a pedido del usuario)
# =============================================================================
## Antes Línea de Defensa/Apoyo eran HBoxContainer puro (alignment=CENTER):
## agregar o sacar UN hijo reordenaba TODOS sus hermanos de una — reportado
## como 'cuando 1 ataque, el otro toma su puesto' (el Aliado que se quedaba
## en Defensa se corría solo al vacante el que salió a atacar). No se cambia
## el TIPO de contenedor en la escena — sigue siendo un HBoxContainer real, y
## container.get_children() sigue siendo la fuente de verdad de 'quién está
## en esta zona' para el resto del proyecto (docenas de lugares dependen de
## eso) — solo se desacopla cada carta de su layout automático
## (top_level=true, mismo truco que CardInteraction._start_drag()) y se le
## asigna una posición fija dentro de una grilla de slots imaginaria que el
## Container ya no puede tocar.
const _FIELD_SLOT_WIDTH: float = 162.0  # 150 (ancho de carta) + 12 (separación del HBoxContainer)
var _field_slot_occupants: Dictionary = {}  # {container: Array[Node]}


func _get_base_field_container(container: Control) -> Control:
	if not _main:
		return container
	if container == _main.player_field or container == _main.player_linea_ataque:
		return _main.player_field
	if container == _main.opponent_field or container == _main.opponent_linea_ataque:
		return _main.opponent_field
	return container


func _get_associated_attack_container(container: Control) -> Control:
	if not _main:
		return null
	if container == _main.player_field:
		return _main.player_linea_ataque
	if container == _main.opponent_field:
		return _main.opponent_linea_ataque
	return null


func pin_card_to_field_slot(card: Node, container: Control) -> Vector2:
	"""Asigna a 'card' un slot fijo dentro de 'container' (Línea de Defensa o
	de Apoyo), la desacopla del layout del HBoxContainer para siempre
	(top_level=true) y deja su global_position en ese slot.
	Elige el slot libre más cercano al centro y preserva los slots de cartas que
	están atacando en la Línea de Ataque para que ninguna otra carta se mueva en X a su puesto."""
	if not is_instance_valid(card) or not container:
		return card.global_position if is_instance_valid(card) else Vector2.ZERO

	var max_slots: int = maxi(1, int(container.size.x / _FIELD_SLOT_WIDTH))
	var base_container: Control = _get_base_field_container(container)
	var occupants: Array = _field_slot_occupants.get(base_container, [])
	occupants.resize(max_slots)

	# Si la carta ya tenía un slot asignado en este campo y sigue siendo válido, conservarlo
	var existing_slot: int = card.get_meta("field_slot_index", -1)
	var slot_index: int = -1
	if existing_slot >= 0 and existing_slot < max_slots and (occupants[existing_slot] == card or occupants[existing_slot] == null):
		slot_index = existing_slot
	else:
		var atk_container = _get_associated_attack_container(base_container)
		for i in range(max_slots):
			var occ = occupants[i]
			if occ != null:
				var is_valid_occ = is_instance_valid(occ) and (occ.get_parent() == base_container or (atk_container and occ.get_parent() == atk_container))
				if not is_valid_occ:
					occupants[i] = null

		var center: float = (max_slots - 1) / 2.0
		var order: Array = range(max_slots)
		order.sort_custom(func(a, b): return absf(a - center) < absf(b - center))

		for i in order:
			if occupants[i] == null or occupants[i] == card:
				slot_index = i
				break

	if slot_index == -1:
		slot_index = 0

	occupants[slot_index] = card
	_field_slot_occupants[base_container] = occupants
	card.set_meta("field_slot_index", slot_index)

	var center_val: float = (max_slots - 1) / 2.0
	var card_size: Vector2 = card.size * card.scale
	var local_center_x: float = container.size.x / 2.0 + (slot_index - center_val) * _FIELD_SLOT_WIDTH
	var local_pos: Vector2 = Vector2(
		local_center_x - card_size.x / 2.0,
		(container.size.y - card_size.y) / 2.0
	)
	card.top_level = true
	var target_pos: Vector2 = container.global_position + local_pos
	card.set_meta("field_slot_x", target_pos.x)
	card.set_meta("field_slot_pos", target_pos)
	card.global_position = target_pos

	var is_opp: bool = (card.owner_id == 1 or card.controller_id == 1)
	if is_opp:
		card.pivot_offset = card_size / 2.0
		card.rotation_degrees = 180.0
	return target_pos


func compact_field_slots(container: Control, animate: bool = true) -> void:
	"""Reordena y compacta de izquierda a derecha (centrado continuo) todos los aliados/tótems
	que quedan en juego cuando una carta abandona el campo, rellenando los espacios vacíos."""
	if not container or not _main:
		return
	var base_container: Control = _get_base_field_container(container)
	var atk_container: Control = _get_associated_attack_container(base_container)

	var active_cards: Array = []
	for child in base_container.get_children():
		if is_instance_valid(child) and not child.is_queued_for_deletion():
			active_cards.append(child)
	if atk_container:
		for child in atk_container.get_children():
			if is_instance_valid(child) and not child.is_queued_for_deletion():
				active_cards.append(child)

	if active_cards.is_empty():
		_field_slot_occupants[base_container] = []
		return

	# Ordenar de izquierda a derecha según su posición X actual
	active_cards.sort_custom(func(a, b):
		var pos_a: float = a.get_meta("field_slot_x", a.global_position.x)
		var pos_b: float = b.get_meta("field_slot_x", b.global_position.x)
		return pos_a < pos_b
	)

	var max_slots: int = maxi(1, int(base_container.size.x / _FIELD_SLOT_WIDTH))
	var center_val: float = (max_slots - 1) / 2.0
	var count: int = active_cards.size()
	var start_slot: float = center_val - (float(count - 1) / 2.0)

	var new_occupants: Array = []
	new_occupants.resize(max_slots)

	for i in range(count):
		var card: Node = active_cards[i]
		var slot_pos_idx: float = start_slot + float(i)
		var card_size: Vector2 = card.size * card.scale
		var local_center_x: float = base_container.size.x / 2.0 + (slot_pos_idx - center_val) * _FIELD_SLOT_WIDTH
		var target_x: float = base_container.global_position.x + local_center_x - card_size.x / 2.0

		var int_slot: int = int(round(slot_pos_idx))
		if int_slot >= 0 and int_slot < max_slots:
			new_occupants[int_slot] = card
		card.set_meta("field_slot_index", int_slot)
		card.set_meta("field_slot_x", target_x)
		var current_pos: Vector2 = card.global_position
		card.set_meta("field_slot_pos", Vector2(target_x, current_pos.y))

		var is_opp: bool = (card.owner_id == 1 or card.controller_id == 1)
		if is_opp:
			card.pivot_offset = card_size / 2.0
			card.rotation_degrees = 180.0

		if animate and absf(current_pos.x - target_x) > 1.0:
			var tw = card.create_tween()
			tw.tween_property(card, "global_position:x", target_x, 0.28).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
		elif not animate:
			card.global_position.x = target_x

	_field_slot_occupants[base_container] = new_occupants


func compact_all_fields(animate: bool = true) -> void:
	"""Compacta y reordena todas las zonas del campo (Líneas de Defensa y Apoyo de ambos jugadores)"""
	if not _main:
		return
	if _main.player_field:
		compact_field_slots(_main.player_field, animate)
	if _main.player_linea_apoyo:
		compact_field_slots(_main.player_linea_apoyo, animate)
	if _main.opponent_field:
		compact_field_slots(_main.opponent_field, animate)
	if _main.opponent_linea_apoyo:
		compact_field_slots(_main.opponent_linea_apoyo, animate)
