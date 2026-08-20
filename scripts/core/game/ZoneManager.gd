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


func shuffle_deck(player_id: int = 0) -> void:
	"""Baraja el mazo de un jugador."""
	if player_id == 0:
		_main.player_deck.shuffle()
	else:
		_main.opponent_deck.shuffle()


func move_card(from_zone: Constants.Zone, to_zone: Constants.Zone, amount: int = 1) -> void:
	"""Mueve 'amount' cartas de from_zone a to_zone (jugador 0).
	   Actualiza contadores de Castillo, Cementerio y Destierro en tiempo real."""
	var card_manager = get_node_or_null("/root/CardManager")
	for _i in range(amount):
		match [from_zone, to_zone]:

			[Constants.Zone.CASTILLO, Constants.Zone.CEMENTERIO]:
				if _main.player_deck.is_empty():
					_main._update_debug("Castillo vacío"); return
				var data = _main.player_deck.pop_front()
				data["esta_oculta"] = false
				if card_manager:
					card_manager.add_to_cemetery(0, data)
				else:
					_main.player_cemetery.append(data)
					UIManager.update_cementerio_count(0, _main.player_cemetery.size())
				_update_castillo_counts()

			[Constants.Zone.CASTILLO, Constants.Zone.DESTIERRO]:
				if _main.player_deck.is_empty():
					_main._update_debug("Castillo vacío"); return
				var data = _main.player_deck.pop_front()
				data["esta_oculta"] = false
				if card_manager:
					card_manager.get_exile(0).append(data)
					card_manager._emit_exile_changed(0)
				else:
					UIManager.update_destierro_count(0, UIManager.get_destierro_count(0) + 1)
				_update_castillo_counts()

			[Constants.Zone.MANO, Constants.Zone.CEMENTERIO]:
				var hand_cards = _main.player_hand.cards if _main.player_hand.get("cards") != null else _main.player_hand.get_children()
				if hand_cards.is_empty():
					_main._update_debug("Mano vacía"); return
				var card = hand_cards[randi() % hand_cards.size()]
				var data = card.card_data.duplicate() if card.get("card_data") else {}
				data["esta_oculta"] = false
				if card_manager:
					card_manager.add_to_cemetery(0, data)
				else:
					_main.player_cemetery.append(data)
					UIManager.update_cementerio_count(0, _main.player_cemetery.size())
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
