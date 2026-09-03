class_name ZoneViewerModule
extends Node

const CardScene = preload("res://scenes/cards/Card.tscn")
const TEX_CEMETERY_BG := preload("res://assets/backgrounds/cementerio_bg.jpg")
const TEX_EXILE_BG    := preload("res://assets/backgrounds/destierro_bg.jpg")
const SHADER_VIGNETTE := preload("res://assets/shaders/zone_modal_vignette.gdshader")

var _main: Node = null


func setup(main: Node) -> void:
	_main = main
	setup_public_zone_viewers()


func setup_public_zone_viewers() -> void:
	var zones = [
		[_main._panel_player_cem,  "Cementerio",  0, "cemetery"],
		[_main._panel_player_dst,  "Destierro",   0, "exile"],
		[_main._panel_opp_cem,     "Cementerio",  1, "cemetery"],
		[_main._panel_opp_dst,     "Destierro",   1, "exile"],
	]
	for z in zones:
		var panel: Panel = z[0]
		var label: String = z[1]
		var pid: int = z[2]
		var ztype: String = z[3]
		panel.clip_contents = true
		panel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		panel.gui_input.connect(func(ev):
			if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT and ev.pressed:
				_show_zone_popup(label, pid, ztype)
		)
		# TextureRect para mostrar la carta del tope ajustada al contenedor completo
		var tr = TextureRect.new()
		tr.name = "TopCardPreview"
		tr.set_anchors_preset(Control.PRESET_FULL_RECT)
		tr.set_offsets_preset(Control.PRESET_FULL_RECT)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_SCALE
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tr.visible = false
		panel.add_child(tr)
		panel.move_child(tr, 0)  # Detrás de los otros hijos (count, label)

	# Conectar señales del CardManager para actualizar el tope en tiempo real
	CardManager.cemetery_count_changed.connect(_on_zone_cemetery_changed)
	CardManager.exile_count_changed.connect(_on_zone_exile_changed)

	# Cuando CardDatabase termina de descargar una imagen, refrescar las zonas
	CardDatabase.card_image_loaded.connect(_on_zone_card_image_loaded)

	# Revelado del tope del Castillo (La Ouija, 2026-08-31) — a diferencia de
	# Cementerio/Destierro (siempre públicos), el Castillo es zona OCULTA por
	# defecto: el TopCardPreview de PlayerCastillo solo se muestra mientras
	# haya una carta propia en Reserva con 'Juega mostrando la primera carta
	# de tu Castillo' (ver refresh_castillo_top_reveal()), y se apaga solo si
	# esa carta sale de juego. No hay popup de todo el mazo (a diferencia de
	# Cementerio/Destierro) — el efecto solo revela el TOPE, nunca el resto.
	var castillo_tr = TextureRect.new()
	castillo_tr.name = "TopCardPreview"
	castillo_tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	castillo_tr.set_offsets_preset(Control.PRESET_FULL_RECT)
	castillo_tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	castillo_tr.stretch_mode = TextureRect.STRETCH_SCALE
	castillo_tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	castillo_tr.visible = false
	_main._panel_player_castillo.add_child(castillo_tr)

	CardManager.card_destroyed.connect(func(_pid, _c): refresh_castillo_top_reveal())
	CardManager.card_exiled.connect(func(_pid, _c): refresh_castillo_top_reveal())
	if not PriorityManager.priority_changed.is_connected(_on_priority_changed_refresh_castillo_top):
		PriorityManager.priority_changed.connect(_on_priority_changed_refresh_castillo_top)


func _show_zone_popup(title: String, player_id: int, zone_type: String) -> void:
	var cards_data: Array = CardManager.get_cemetery(player_id) if zone_type == "cemetery" else CardManager.get_exile(player_id)

	# Limpiar popup anterior
	var existing = _main.get_node_or_null("ZoneViewerPopup")
	if existing:
		existing.queue_free()

	var vp = get_viewport().get_visible_rect().size

	var popup_canvas = CanvasLayer.new()
	popup_canvas.name = "ZoneViewerPopup"
	popup_canvas.layer = 55
	_main.add_child(popup_canvas)

	# Fondo oscuro exterior traslúcido — click fuera cierra
	var bg = ColorRect.new()
	bg.size = vp
	bg.color = Color(0, 0, 0, 0.65)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	bg.gui_input.connect(func(ev):
		if ev is InputEventMouseButton and ev.pressed:
			popup_canvas.queue_free()
	)
	popup_canvas.add_child(bg)

	var n_cards := cards_data.size()
	var is_cemetery := zone_type == "cemetery"

	# Paleta y textura ilustrada temática generada
	var bg_tex = TEX_CEMETERY_BG if is_cemetery else TEX_EXILE_BG
	var title_color = Color(0.94, 0.92, 0.88, 1.0)
	var tint_color = Color(0.01, 0.04, 0.04, 0.35) if is_cemetery else Color(0.04, 0.01, 0.05, 0.35)

	# Dimensiones dinámicas adaptadas a la proporción real de cartas 1:1.4
	var popup_w: float
	var popup_h: float
	if n_cards == 0:
		popup_w = 460.0
		popup_h = 220.0
	elif n_cards <= 4:
		var card_w := 140.0
		var sep := 18.0
		var content_w := float(n_cards) * card_w + float(n_cards - 1) * sep + 60.0
		popup_w = clampf(content_w, 460.0, vp.x * 0.88)
		popup_h = 310.0
	else:
		popup_w = minf(vp.x * 0.88, 860.0)
		popup_h = minf(vp.y * 0.84, 560.0)

	var panel = Panel.new()
	panel.size = Vector2(popup_w, popup_h)
	panel.position = (vp - panel.size) / 2.0
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.clip_contents = false

	# Estilo con sombra ambiental profunda y esquinas redondeadas
	var pstyle = StyleBoxFlat.new()
	pstyle.bg_color = Color(0.02, 0.02, 0.04, 0.96)
	pstyle.set_corner_radius_all(22)
	pstyle.shadow_color = Color(0, 0, 0, 0.85)
	pstyle.shadow_size = 35
	panel.add_theme_stylebox_override("panel", pstyle)
	popup_canvas.add_child(panel)

	# 1. Textura de fondo con shader de viñeta suave y esquinas redondeadas antialiased
	var bg_rect = TextureRect.new()
	bg_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg_rect.texture = bg_tex
	bg_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var smat = ShaderMaterial.new()
	smat.shader = SHADER_VIGNETTE
	smat.set_shader_parameter("panel_size", Vector2(popup_w, popup_h))
	smat.set_shader_parameter("corner_radius", 22.0)
	smat.set_shader_parameter("vignette_amount", 0.72)
	smat.set_shader_parameter("tint_color", tint_color)
	smat.set_shader_parameter("edge_shadow_color", Color(0.01, 0.01, 0.02, 0.95))
	bg_rect.material = smat
	panel.add_child(bg_rect)

	# Layout interior
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.set_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 16)
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	# Encabezado limpio y suave
	var header_bar = PanelContainer.new()
	var hb_style = StyleBoxFlat.new()
	hb_style.bg_color = Color(0.02, 0.02, 0.03, 0.60)
	hb_style.set_corner_radius_all(10)
	header_bar.add_theme_stylebox_override("panel", hb_style)
	vbox.add_child(header_bar)

	var header = HBoxContainer.new()
	header.alignment = BoxContainer.ALIGNMENT_CENTER
	header_bar.add_child(header)

	var title_lbl = Label.new()
	title_lbl.text = "CEMENTERIO" if is_cemetery else "DESTIERRO"
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.add_theme_font_size_override("font_size", 17)
	title_lbl.add_theme_color_override("font_color", title_color)
	title_lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	title_lbl.add_theme_constant_override("shadow_offset_x", 1)
	title_lbl.add_theme_constant_override("shadow_offset_y", 1)
	header.add_child(title_lbl)

	# Pastilla de contador suave
	var gem_panel = PanelContainer.new()
	var g_style = StyleBoxFlat.new()
	g_style.bg_color = Color(0.08, 0.08, 0.12, 0.70)
	g_style.set_corner_radius_all(8)
	gem_panel.add_theme_stylebox_override("panel", g_style)
	header.add_child(gem_panel)

	var count_lbl = Label.new()
	count_lbl.text = " %d %s " % [n_cards, "Carta" if n_cards == 1 else "Cartas"]
	count_lbl.add_theme_font_size_override("font_size", 12)
	count_lbl.add_theme_color_override("font_color", Color(0.88, 0.88, 0.88, 1.0))
	gem_panel.add_child(count_lbl)

	var close_btn = Button.new()
	close_btn.text = "  ✕  "
	close_btn.flat = true
	close_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	close_btn.add_theme_font_size_override("font_size", 16)
	close_btn.add_theme_color_override("font_color", Color(0.9, 0.7, 0.7))
	close_btn.pressed.connect(func(): popup_canvas.queue_free())
	header.add_child(close_btn)

	if cards_data.is_empty():
		var empty_lbl = Label.new()
		empty_lbl.text = "Esta zona está vacía."
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
		empty_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		empty_lbl.add_theme_font_size_override("font_size", 15)
		empty_lbl.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
		vbox.add_child(empty_lbl)
		return

	var is_own_cemetery := player_id == 0 and zone_type == "cemetery"

	if n_cards <= 4:
		var center_box = HBoxContainer.new()
		center_box.alignment = BoxContainer.ALIGNMENT_CENTER
		center_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
		center_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		center_box.add_theme_constant_override("separation", 18)
		vbox.add_child(center_box)

		for card_data in cards_data:
			_create_popup_card(card_data, player_id, zone_type, is_own_cemetery, popup_canvas, center_box, Vector2(0.933, 0.933))
	else:
		var scroll = ScrollContainer.new()
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		vbox.add_child(scroll)

		var grid = GridContainer.new()
		grid.columns = 4
		grid.add_theme_constant_override("h_separation", 16)
		grid.add_theme_constant_override("v_separation", 16)
		grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(grid)

		for card_data in cards_data:
			_create_popup_card(card_data, player_id, zone_type, is_own_cemetery, popup_canvas, grid, Vector2(0.84, 0.84))


func _create_popup_card(card_data: Dictionary, player_id: int, zone_type: String, is_own_cemetery: bool, popup_canvas: CanvasLayer, container: Control, base_scale_val: Vector2) -> void:
	# Wrapper con dimensiones fijas para evitar deformación por contenedores de Godot
	var wrapper = Control.new()
	var target_w := 150.0 * base_scale_val.x
	var target_h := 210.0 * base_scale_val.y
	wrapper.custom_minimum_size = Vector2(target_w, target_h)
	wrapper.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	wrapper.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	var card = CardScene.instantiate()
	card.load_from_data(card_data)
	card.set_zone(Constants.Zone.CEMENTERIO if zone_type == "cemetery" else Constants.Zone.DESTIERRO)
	card.owner_id = player_id
	card.can_interact = false
	card.drag_enabled = false
	card.custom_minimum_size = Vector2(150.0, 210.0)
	card.size = Vector2(150.0, 210.0)
	card.scale = base_scale_val
	card.base_scale = base_scale_val
	card.position = Vector2.ZERO
	card.pivot_offset = Vector2(75.0, 105.0)

	card.gui_input.connect(func(ev):
		if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_RIGHT and ev.pressed:
			_main._card_inspector.on_card_right_clicked(card)
	)

	if is_own_cemetery and PaymentManager.card_has_exhumar(card_data):
		card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		card.gui_input.connect(func(ev):
			if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT and ev.pressed:
				_on_exhumar_card_clicked(card_data, popup_canvas)
		)

	wrapper.add_child(card)
	container.add_child(wrapper)


func _on_exhumar_card_clicked(card_data: Dictionary, popup_canvas: CanvasLayer) -> void:
	"""Click en una carta con Exhumar dentro del popup del Cementerio propio
	(2026-08-23): valida Oro disponible, cierra el popup y la juega vía
	GoldManager.play_card_from_cemetery() — mismo camino real que jugar
	desde la mano, no el ActionPipeline/ExhumarSystem huérfanos."""
	if not _main._gold_manager:
		return
	var cost: int = PaymentManager.get_exhumar_cost(card_data)
	var card_name: String = card_data.get("nombre", "???")
	if _main._gold_manager.get_oro_disponible() < cost:
		_main._update_debug("Oro insuficiente para Exhumar %s (necesitas %d)" % [card_name, cost])
		return
	if popup_canvas and is_instance_valid(popup_canvas):
		popup_canvas.queue_free()
	await _main._gold_manager.play_card_from_cemetery(card_data)


func _on_zone_cemetery_changed(player_id: int, _count: int) -> void:
	var panel = _main._panel_player_cem if player_id == 0 else _main._panel_opp_cem
	_refresh_zone_top_card(panel, CardManager.get_cemetery(player_id))


func _on_zone_exile_changed(player_id: int, _count: int) -> void:
	var panel = _main._panel_player_dst if player_id == 0 else _main._panel_opp_dst
	_refresh_zone_top_card(panel, CardManager.get_exile(player_id))


func _on_zone_card_image_loaded(_card_id: String, _texture: Texture2D) -> void:
	_refresh_zone_top_card(_main._panel_player_cem, CardManager.get_cemetery(0))
	_refresh_zone_top_card(_main._panel_player_dst, CardManager.get_exile(0))
	_refresh_zone_top_card(_main._panel_opp_cem,    CardManager.get_cemetery(1))
	_refresh_zone_top_card(_main._panel_opp_dst,    CardManager.get_exile(1))
	refresh_castillo_top_reveal()


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

	if not card_id.is_empty():
		var tex = CardDatabase.image_cache.get(card_id)
		if tex:
			tr.texture = tex
			return

	# Fallback: mostrar dorso mientras la imagen no está lista
	tr.texture = GameSettings.get_card_back_texture(0)


func _on_priority_changed_refresh_castillo_top(_player_id: int) -> void:
	refresh_castillo_top_reveal()


func refresh_castillo_top_reveal() -> void:
	"""Muestra la carta del tope del Castillo propio (índice 0, ver
	convención real documentada en CardManager.add_to_deck_top()) en vez del
	dorso, mientras haya una carta propia en Reserva de Oro con 'Juega
	mostrando la primera carta de tu Castillo' (La Ouija, 2026-08-31 —
	detección por texto, mismo patrón que _max_weapons_per_ally() en
	GoldManager.gd). Llamar tras cualquier cambio al Castillo (robo, la
	propia habilidad de La Ouija) y cuando una carta puede haber salido de
	Reserva. Solo jugador 0 — el resto de estos efectos puntuales tampoco
	corren para el rival todavía."""
	if not _main or not _main._panel_player_castillo:
		return
	var tr: TextureRect = _main._panel_player_castillo.get_node_or_null("TopCardPreview")
	var dorso = _main._panel_player_castillo.get_node_or_null("DorsoImage")
	if not tr:
		return

	var revealed: bool = false
	if _main.player_gold:
		for c in _main.player_gold.get_children():
			if not is_instance_valid(c):
				continue
			var ability_text: String = c.get("card_ability") if c.get("card_ability") != null else ""
			if ability_text.is_empty():
				continue
			if "juega mostrando la primera carta de tu castillo" in ability_text.to_lower():
				revealed = true
				break

	if not revealed or _main.player_deck.is_empty():
		tr.visible = false
		if dorso:
			dorso.visible = true
		return

	var top_card: Dictionary = _main.player_deck[0]
	var card_id := str(top_card.get("id", ""))
	var tex = CardDatabase.image_cache.get(card_id) if not card_id.is_empty() else null
	if not tex:
		tr.visible = false
		if dorso:
			dorso.visible = true
		return

	tr.texture = tex
	tr.visible = true
	if dorso:
		dorso.visible = false
