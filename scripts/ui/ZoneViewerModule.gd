class_name ZoneViewerModule
extends Node

const CardScene = preload("res://scenes/cards/Card.tscn")

var _main: Node = null


func setup(main: Node) -> void:
	_main = main
	setup_public_zone_viewers()


func setup_public_zone_viewers() -> void:
	var zones = [
		[_main._panel_player_cem,  "Cementerio (Jugador)",  0, "cemetery"],
		[_main._panel_player_dst,  "Destierro (Jugador)",   0, "exile"],
		[_main._panel_opp_cem,     "Cementerio (Oponente)", 1, "cemetery"],
		[_main._panel_opp_dst,     "Destierro (Oponente)",  1, "exile"],
	]
	for z in zones:
		var panel: Panel = z[0]
		var label: String = z[1]
		var pid: int = z[2]
		var ztype: String = z[3]
		panel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		panel.gui_input.connect(func(ev):
			if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT and ev.pressed:
				_show_zone_popup(label, pid, ztype)
		)
		# TextureRect para mostrar la carta del tope (detrás de los labels existentes)
		var tr = TextureRect.new()
		tr.name = "TopCardPreview"
		tr.set_anchors_preset(Control.PRESET_FULL_RECT)
		tr.set_offsets_preset(Control.PRESET_FULL_RECT)
		tr.expand_mode = TextureRect.EXPAND_FIT_HEIGHT_PROPORTIONAL
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tr.visible = false
		panel.add_child(tr)
		panel.move_child(tr, 0)  # Detrás de los otros hijos (count, label)

	# Conectar señales del CardManager para actualizar el tope en tiempo real
	var cm = get_node_or_null("/root/CardManager")
	if cm:
		cm.cemetery_count_changed.connect(_on_zone_cemetery_changed)
		cm.exile_count_changed.connect(_on_zone_exile_changed)

	# Cuando CardDatabase termina de descargar una imagen, refrescar las zonas
	var cdb = get_node_or_null("/root/CardDatabase")
	if cdb:
		cdb.card_image_loaded.connect(_on_zone_card_image_loaded)


func _show_zone_popup(title: String, player_id: int, zone_type: String) -> void:
	var card_manager = get_node_or_null("/root/CardManager")
	var cards_data: Array = []
	if card_manager:
		cards_data = card_manager.get_cemetery(player_id) if zone_type == "cemetery" else card_manager.get_exile(player_id)
	else:
		cards_data = _main.player_cemetery if player_id == 0 else _main.opponent_cemetery

	# Limpiar popup anterior
	var existing = _main.get_node_or_null("ZoneViewerPopup")
	if existing:
		existing.queue_free()

	var vp = get_viewport().get_visible_rect().size

	var popup_canvas = CanvasLayer.new()
	popup_canvas.name = "ZoneViewerPopup"
	popup_canvas.layer = 55
	_main.add_child(popup_canvas)

	# Fondo oscuro — click fuera cierra
	var bg = ColorRect.new()
	bg.size = vp
	bg.color = Color(0, 0, 0, 0.65)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	bg.gui_input.connect(func(ev):
		if ev is InputEventMouseButton and ev.pressed:
			popup_canvas.queue_free()
	)
	popup_canvas.add_child(bg)

	# Panel principal
	var popup_w = min(vp.x * 0.80, 800.0)
	var popup_h = min(vp.y * 0.80, 560.0)
	var panel = Panel.new()
	panel.size = Vector2(popup_w, popup_h)
	panel.position = (vp - panel.size) / 2.0
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var pstyle = StyleBoxFlat.new()
	pstyle.bg_color = Color(0.08, 0.06, 0.14, 0.98)
	pstyle.set_corner_radius_all(10)
	pstyle.set_border_width_all(2)
	pstyle.border_color = Color(0.50, 0.38, 0.70)
	panel.add_theme_stylebox_override("panel", pstyle)
	popup_canvas.add_child(panel)

	# Layout interior
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.set_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 14)
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	# Encabezado
	var header = HBoxContainer.new()
	vbox.add_child(header)

	var title_lbl = Label.new()
	title_lbl.text = title.to_upper()
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.add_theme_font_size_override("font_size", 20)
	title_lbl.add_theme_color_override("font_color", Color(0.92, 0.80, 1.0))
	header.add_child(title_lbl)

	var count_lbl = Label.new()
	count_lbl.text = "(%d)" % cards_data.size()
	count_lbl.add_theme_font_size_override("font_size", 14)
	count_lbl.add_theme_color_override("font_color", Color(0.65, 0.65, 0.75))
	header.add_child(count_lbl)

	var close_btn = Button.new()
	close_btn.text = "  ✕  "
	close_btn.flat = true
	close_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	close_btn.add_theme_font_size_override("font_size", 18)
	close_btn.add_theme_color_override("font_color", Color(0.8, 0.6, 0.6))
	close_btn.pressed.connect(func(): popup_canvas.queue_free())
	header.add_child(close_btn)

	var sep = HSeparator.new()
	vbox.add_child(sep)

	if cards_data.is_empty():
		var empty_lbl = Label.new()
		empty_lbl.text = "Esta zona está vacía."
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
		empty_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		empty_lbl.add_theme_font_size_override("font_size", 16)
		empty_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
		vbox.add_child(empty_lbl)
		return

	# Grilla de 4 columnas
	var scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	var grid = GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)

	for card_data in cards_data:
		var card = CardScene.instantiate()
		card.load_from_data(card_data)
		card.can_interact = false
		card.drag_enabled = false
		card.scale = Vector2(0.82, 0.82)
		card.custom_minimum_size = Vector2(140.0, 196.0)
		card.gui_input.connect(func(ev):
			if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_RIGHT and ev.pressed:
				_main._on_card_right_clicked(card)
		)
		grid.add_child(card)


func _on_zone_cemetery_changed(player_id: int, _count: int) -> void:
	var panel = _main._panel_player_cem if player_id == 0 else _main._panel_opp_cem
	var cm = get_node_or_null("/root/CardManager")
	_refresh_zone_top_card(panel, cm.get_cemetery(player_id) if cm else [])


func _on_zone_exile_changed(player_id: int, _count: int) -> void:
	var panel = _main._panel_player_dst if player_id == 0 else _main._panel_opp_dst
	var cm = get_node_or_null("/root/CardManager")
	_refresh_zone_top_card(panel, cm.get_exile(player_id) if cm else [])


func _on_zone_card_image_loaded(_card_id: String, _texture: Texture2D) -> void:
	var cm = get_node_or_null("/root/CardManager")
	if not cm:
		return
	_refresh_zone_top_card(_main._panel_player_cem, cm.get_cemetery(0))
	_refresh_zone_top_card(_main._panel_player_dst, cm.get_exile(0))
	_refresh_zone_top_card(_main._panel_opp_cem,    cm.get_cemetery(1))
	_refresh_zone_top_card(_main._panel_opp_dst,    cm.get_exile(1))


func _refresh_zone_top_card(panel: Panel, cards_data: Array) -> void:
	var tr: TextureRect = panel.get_node_or_null("TopCardPreview")
	if not tr:
		return

	if cards_data.is_empty():
		tr.texture = null
		tr.visible = false
		return

	tr.visible = true
	var top_card = cards_data.back()
	var card_id = str(top_card.get("id", ""))

	var cdb = get_node_or_null("/root/CardDatabase")
	if cdb and not card_id.is_empty():
		var tex = cdb.image_cache.get(card_id)
		if tex:
			tr.texture = tex
			return

	# Fallback: mostrar dorso mientras la imagen no está lista
	var gs = get_node_or_null("/root/GameSettings")
	if gs:
		tr.texture = gs.get_card_back_texture(0)
