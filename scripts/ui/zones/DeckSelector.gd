extends Node
## DeckSelector — Interfaz diegética de selección de mazos antes de la partida.
## Altar rúnico ancestral con las 9 razas oficiales en alta definición:
## - Caballero, Bestia, Dragón, Imp, Héroe, Guerrero, Faerie, Sacerdote, Sombra.
## - Carrusel sobre la meseta del altar entre los monolitos rúnicos.
## - Pedestales de piedra interactivos que se funden 100% con la ilustración original.
## - Sin cajas verdes ni marcos intrusivos. Solo interacción orgánica y pura.

signal decks_selected(player_data: Dictionary, opponent_data: Dictionary, player_is_external: bool, opponent_is_external: bool)
signal selection_cancelled

const CARD_SIZE := Vector2(210, 280)
const GOLD := Color(0.83, 0.69, 0.22, 1.0)
const GOLD_HOVER := Color(1.0, 0.88, 0.45, 1.0)
const GOLD_SELECTION := Color(1.0, 0.86, 0.38, 1.0)
const RUNIC_CYAN := Color(0.40, 0.92, 0.90, 1.0)

const FONT_MEDIEVAL := preload("res://assets/fonts/Marcellus-Regular.ttf")
const FONT_TITLE := preload("res://assets/fonts/Cinzel-Bold.ttf")

# Texturas HD de las 9 Razas oficiales
const TEX_CABALLERO := preload("res://assets/ui/deck_selector/card_caballero.png")
const TEX_BESTIA := preload("res://assets/ui/deck_selector/card_bestia.png")
const TEX_DRAGON := preload("res://assets/ui/deck_selector/card_dragon.png")
const TEX_IMP := preload("res://assets/ui/deck_selector/card_imp.png")
const TEX_HEROE := preload("res://assets/ui/deck_selector/card_heroe.png")
const TEX_GUERRERO := preload("res://assets/ui/deck_selector/card_guerrero.png")
const TEX_FAERIE := preload("res://assets/ui/deck_selector/card_faerie.png")
const TEX_SACERDOTE := preload("res://assets/ui/deck_selector/card_sacerdote.png")
const TEX_SOMBRA := preload("res://assets/ui/deck_selector/card_sombra.png")

# Fondo diegético y spinner de carga
const BACKGROUND_TEXTURE := preload("res://assets/ui/deck_selector/altar_deck_selector.jpg")
const SpinnerDrawerScript := preload("res://scripts/ui/zones/SpinnerDrawer.gd")

var _overlay: Control = null
var _scroll_container: ScrollContainer = null
var _player_row: HBoxContainer = null
var _btn_confirm: Control = null
var _btn_confirm_clicker: Button = null
var _btn_random: Control = null
var _btn_random_clicker: Button = null
var _btn_prev: Button = null
var _btn_next: Button = null

# Cartel dinámico de mazo activo en el centro del altar
var _deck_banner: Label = null
var _deck_sub_banner: Label = null

# Pergamino inferior izquierdo
var _parchment_label: Label = null

var _mazos: Array = []
var _selected_player_idx: int = -1
var _player_cards: Array = []
var _loading_box: Control = null


func show_selector(parent: Node) -> void:
	"""Muestra el altar diegético de selección. Emite decks_selected al confirmar."""
	_build_ui(parent)
	_fetch_mazos()


func _get_autoload(node_name: String) -> Node:
	if is_inside_tree():
		return get_node_or_null("/root/" + node_name)
	var tree = Engine.get_main_loop() as SceneTree
	if tree and tree.root:
		return tree.root.get_node_or_null(node_name)
	return null


# =============================================================================
# CONSTRUCCIÓN DE UI DIEGÉTICA
# =============================================================================
func _build_ui(parent: Node) -> void:
	_overlay = Control.new()
	_overlay.name = "AltarDeckSelectorOverlay"
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(_overlay)

	# 1. Escenario de Fondo: Altar rúnico ancestral en alta definición
	var bg_texture = TextureRect.new()
	bg_texture.name = "AltarBackground"
	bg_texture.texture = BACKGROUND_TEXTURE
	bg_texture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(bg_texture)

	# 2. Contenedor del Carrusel sobre la meseta de piedra del altar
	# Los libros reposan directamente sobre la repisa de piedra
	var carousel_wrapper = Control.new()
	carousel_wrapper.name = "AltarCarouselWrapper"
	carousel_wrapper.set_anchor(SIDE_LEFT, 0.5)
	carousel_wrapper.set_anchor(SIDE_RIGHT, 0.5)
	carousel_wrapper.set_anchor(SIDE_TOP, 0.5)
	carousel_wrapper.set_anchor(SIDE_BOTTOM, 0.5)
	carousel_wrapper.set_offset(SIDE_LEFT, -570)
	carousel_wrapper.set_offset(SIDE_RIGHT, 570)
	carousel_wrapper.set_offset(SIDE_TOP, -245)
	carousel_wrapper.set_offset(SIDE_BOTTOM, 85)
	carousel_wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(carousel_wrapper)

	_scroll_container = ScrollContainer.new()
	_scroll_container.name = "AltarScroll"
	_scroll_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# Ocultar la barra gris para máxima inmersión
	var h_bar = _scroll_container.get_h_scroll_bar()
	if h_bar:
		h_bar.modulate = Color(1, 1, 1, 0)
	_scroll_container.gui_input.connect(_on_scroll_gui_input)
	carousel_wrapper.add_child(_scroll_container)

	_player_row = HBoxContainer.new()
	_player_row.name = "GrimoriosRow"
	_player_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_player_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_player_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_player_row.custom_minimum_size = Vector2(0, 330)
	_player_row.add_theme_constant_override("separation", 24)
	_scroll_container.add_child(_player_row)

	# Placeholder de carga místico con runas giratorias
	_loading_box = _build_loading_placeholder()
	_player_row.add_child(_loading_box)

	# 3. Botones Rúnicos Circulares de Navegación Lateral (◄ y ►)
	_btn_prev = _build_circular_nav_button("◄", Vector2(-625, -50))
	_btn_prev.pressed.connect(_scroll_left)
	_overlay.add_child(_btn_prev)

	_btn_next = _build_circular_nav_button("►", Vector2(575, -50))
	_btn_next.pressed.connect(_scroll_right)
	_overlay.add_child(_btn_next)

	# 4. Cartel Central de Mazo Activo (sobre el grabado de piedra "ELIGE TU MAZO")
	_build_center_banner()

	# 5. Pergamino Dinámico (esquina inferior izquierda)
	_build_parchment_label()

	# 6. Botones de Pedestal Orgánicos (100% limpios, sin cajas de colores)
	_build_clean_action_buttons()


func _build_circular_nav_button(glyph: String, pos_offset: Vector2) -> Button:
	var btn = Button.new()
	btn.text = glyph
	btn.custom_minimum_size = Vector2(48, 48)
	btn.set_anchor(SIDE_LEFT, 0.5)
	btn.set_anchor(SIDE_RIGHT, 0.5)
	btn.set_anchor(SIDE_TOP, 0.5)
	btn.set_anchor(SIDE_BOTTOM, 0.5)
	btn.set_offset(SIDE_LEFT, pos_offset.x)
	btn.set_offset(SIDE_RIGHT, pos_offset.x + 48)
	btn.set_offset(SIDE_TOP, pos_offset.y)
	btn.set_offset(SIDE_BOTTOM, pos_offset.y + 48)
	btn.pivot_offset = Vector2(24, 24)

	# Estilo de piedra rúnica circular
	var style_norm = StyleBoxFlat.new()
	style_norm.bg_color = Color(0.08, 0.10, 0.12, 0.85)
	style_norm.border_color = Color(0.83, 0.69, 0.22, 0.6)
	style_norm.set_border_width_all(2)
	style_norm.set_corner_radius_all(24)
	style_norm.shadow_color = Color(0, 0, 0, 0.6)
	style_norm.shadow_size = 6
	btn.add_theme_stylebox_override("normal", style_norm)

	var style_hov = StyleBoxFlat.new()
	style_hov.bg_color = Color(0.12, 0.16, 0.20, 0.95)
	style_hov.border_color = GOLD_HOVER
	style_hov.set_border_width_all(2)
	style_hov.set_corner_radius_all(24)
	style_hov.shadow_color = Color(0.83, 0.69, 0.22, 0.4)
	style_hov.shadow_size = 10
	btn.add_theme_stylebox_override("hover", style_hov)

	var style_press = StyleBoxFlat.new()
	style_press.bg_color = Color(0.05, 0.07, 0.09, 0.95)
	style_press.border_color = GOLD_SELECTION
	style_press.set_border_width_all(2)
	style_press.set_corner_radius_all(24)
	btn.add_theme_stylebox_override("pressed", style_press)

	btn.add_theme_font_override("font", FONT_TITLE)
	btn.add_theme_font_size_override("font_size", 20)
	btn.add_theme_color_override("font_color", Color(0.95, 0.90, 0.80, 1.0))
	btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0, 1.0))
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.visible = false

	btn.mouse_entered.connect(func():
		var tw = btn.create_tween()
		tw.tween_property(btn, "scale", Vector2(1.12, 1.12), 0.12)
	)
	btn.mouse_exited.connect(func():
		var tw = btn.create_tween()
		tw.tween_property(btn, "scale", Vector2(1.0, 1.0), 0.12)
	)
	btn.button_down.connect(func():
		btn.scale = Vector2(0.95, 0.95)
	)
	btn.button_up.connect(func():
		btn.scale = Vector2(1.0, 1.0)
	)
	return btn


func _build_center_banner() -> void:
	"""Muestra el nombre del mazo activo elegantemente centrado sobre el altar"""
	var banner_box = VBoxContainer.new()
	banner_box.name = "ActiveDeckBanner"
	banner_box.set_anchor(SIDE_LEFT, 0.5)
	banner_box.set_anchor(SIDE_RIGHT, 0.5)
	banner_box.set_anchor(SIDE_TOP, 0.5)
	banner_box.set_anchor(SIDE_BOTTOM, 0.5)
	banner_box.set_offset(SIDE_LEFT, -380)
	banner_box.set_offset(SIDE_RIGHT, 380)
	banner_box.set_offset(SIDE_TOP, 140)
	banner_box.set_offset(SIDE_BOTTOM, 195)
	banner_box.alignment = BoxContainer.ALIGNMENT_CENTER
	banner_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(banner_box)

	_deck_banner = Label.new()
	_deck_banner.text = "ELIGE TU GRIMORIO"
	_deck_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_deck_banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_deck_banner.add_theme_font_override("font", FONT_TITLE)
	_deck_banner.add_theme_font_size_override("font_size", 16)
	_deck_banner.add_theme_color_override("font_color", Color(1.0, 0.88, 0.48, 1.0))
	_deck_banner.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.98))
	_deck_banner.add_theme_constant_override("shadow_offset_x", 1)
	_deck_banner.add_theme_constant_override("shadow_offset_y", 2)
	banner_box.add_child(_deck_banner)

	_deck_sub_banner = Label.new()
	_deck_sub_banner.text = "Toca un libro para seleccionarlo"
	_deck_sub_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_deck_sub_banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_deck_sub_banner.add_theme_font_override("font", FONT_MEDIEVAL)
	_deck_sub_banner.add_theme_font_size_override("font_size", 12)
	_deck_sub_banner.add_theme_color_override("font_color", Color(0.85, 0.78, 0.65, 0.9))
	_deck_sub_banner.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	_deck_sub_banner.add_theme_constant_override("shadow_offset_x", 1)
	_deck_sub_banner.add_theme_constant_override("shadow_offset_y", 1)
	banner_box.add_child(_deck_sub_banner)


func _build_parchment_label() -> void:
	"""Integra un texto limpio en tinta sobre el pergamino ilustrado a la izquierda"""
	var parch_holder = Control.new()
	parch_holder.name = "ParchmentDynamic"
	parch_holder.set_anchor(SIDE_LEFT, 0.5)
	parch_holder.set_anchor(SIDE_RIGHT, 0.5)
	parch_holder.set_anchor(SIDE_TOP, 0.5)
	parch_holder.set_anchor(SIDE_BOTTOM, 0.5)
	parch_holder.set_offset(SIDE_LEFT, -520)
	parch_holder.set_offset(SIDE_RIGHT, -310)
	parch_holder.set_offset(SIDE_TOP, 205)
	parch_holder.set_offset(SIDE_BOTTOM, 305)
	parch_holder.pivot_offset = Vector2(105, 50)
	parch_holder.rotation_degrees = -14.0
	parch_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(parch_holder)

	_parchment_label = Label.new()
	_parchment_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_parchment_label.text = "Cargando..."
	_parchment_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_parchment_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_parchment_label.add_theme_font_override("font", FONT_MEDIEVAL)
	_parchment_label.add_theme_font_size_override("font_size", 13)
	_parchment_label.add_theme_color_override("font_color", Color(0.22, 0.16, 0.10, 0.95))
	_parchment_label.add_theme_color_override("font_shadow_color", Color(0.95, 0.90, 0.82, 0.5))
	_parchment_label.add_theme_constant_override("shadow_offset_x", 1)
	_parchment_label.add_theme_constant_override("shadow_offset_y", 1)
	_parchment_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parch_holder.add_child(_parchment_label)


func _build_clean_action_buttons() -> void:
	"""Crea botones interactivos transparentes que se alinean exactamente con el arte original.
	Sin cajas verdes ni bordes artificiales."""
	
	# 1. PEDESTAL CENTRAL: COMENZAR PARTIDA
	_btn_confirm = Control.new()
	_btn_confirm.name = "PedestalComenzarPartida"
	_btn_confirm.set_anchor(SIDE_LEFT, 0.5)
	_btn_confirm.set_anchor(SIDE_RIGHT, 0.5)
	_btn_confirm.set_anchor(SIDE_TOP, 0.5)
	_btn_confirm.set_anchor(SIDE_BOTTOM, 0.5)
	_btn_confirm.set_offset(SIDE_LEFT, -195)
	_btn_confirm.set_offset(SIDE_RIGHT, 180)
	_btn_confirm.set_offset(SIDE_TOP, 245)
	_btn_confirm.set_offset(SIDE_BOTTOM, 345)
	_btn_confirm.pivot_offset = Vector2(187.5, 50.0)
	_overlay.add_child(_btn_confirm)

	_btn_confirm_clicker = Button.new()
	_btn_confirm_clicker.name = "Clicker"
	_btn_confirm_clicker.flat = true
	_btn_confirm_clicker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_btn_confirm_clicker.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_btn_confirm_clicker.pressed.connect(_on_confirm_pressed)
	_btn_confirm.add_child(_btn_confirm_clicker)

	_btn_confirm_clicker.mouse_entered.connect(func():
		if _selected_player_idx >= 0:
			var tw = _btn_confirm.create_tween()
			tw.set_parallel(true)
			tw.tween_property(_btn_confirm, "scale", Vector2(1.03, 1.03), 0.12).set_ease(Tween.EASE_OUT)
			tw.tween_property(_btn_confirm, "modulate", Color(1.2, 1.2, 1.1, 1.0), 0.12)
	)
	_btn_confirm_clicker.mouse_exited.connect(func():
		var tw = _btn_confirm.create_tween()
		tw.set_parallel(true)
		tw.tween_property(_btn_confirm, "scale", Vector2(1.0, 1.0), 0.12).set_ease(Tween.EASE_OUT)
		tw.tween_property(_btn_confirm, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.12)
	)
	_btn_confirm_clicker.button_down.connect(func():
		if _selected_player_idx >= 0:
			_btn_confirm.scale = Vector2(0.97, 0.97)
	)
	_btn_confirm_clicker.button_up.connect(func():
		_btn_confirm.scale = Vector2(1.0, 1.0)
	)

	# 2. PEDESTAL DERECHO: MAZOS ALEATORIOS
	_btn_random = Control.new()
	_btn_random.name = "PedestalMazosAleatorios"
	_btn_random.set_anchor(SIDE_LEFT, 0.5)
	_btn_random.set_anchor(SIDE_RIGHT, 0.5)
	_btn_random.set_anchor(SIDE_TOP, 0.5)
	_btn_random.set_anchor(SIDE_BOTTOM, 0.5)
	_btn_random.set_offset(SIDE_LEFT, 350)
	_btn_random.set_offset(SIDE_RIGHT, 660)
	_btn_random.set_offset(SIDE_TOP, 225)
	_btn_random.set_offset(SIDE_BOTTOM, 325)
	_btn_random.pivot_offset = Vector2(155.0, 50.0)
	_overlay.add_child(_btn_random)

	_btn_random_clicker = Button.new()
	_btn_random_clicker.name = "Clicker"
	_btn_random_clicker.flat = true
	_btn_random_clicker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_btn_random_clicker.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_btn_random_clicker.pressed.connect(_on_random_pressed)
	_btn_random.add_child(_btn_random_clicker)

	_btn_random_clicker.mouse_entered.connect(func():
		var tw = _btn_random.create_tween()
		tw.set_parallel(true)
		tw.tween_property(_btn_random, "scale", Vector2(1.03, 1.03), 0.12).set_ease(Tween.EASE_OUT)
		tw.tween_property(_btn_random, "modulate", Color(1.15, 1.25, 1.25, 1.0), 0.12)
	)
	_btn_random_clicker.mouse_exited.connect(func():
		var tw = _btn_random.create_tween()
		tw.set_parallel(true)
		tw.tween_property(_btn_random, "scale", Vector2(1.0, 1.0), 0.12).set_ease(Tween.EASE_OUT)
		tw.tween_property(_btn_random, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.12)
	)
	_btn_random_clicker.button_down.connect(func():
		_btn_random.scale = Vector2(0.97, 0.97)
	)
	_btn_random_clicker.button_up.connect(func():
		_btn_random.scale = Vector2(1.0, 1.0)
	)


func _build_loading_placeholder() -> Control:
	var box = CenterContainer.new()
	box.custom_minimum_size = Vector2(800, CARD_SIZE.y)
	box.size_flags_vertical = Control.SIZE_SHRINK_END

	var vbox = VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 14)
	box.add_child(vbox)

	var spin_holder = Control.new()
	spin_holder.custom_minimum_size = Vector2(64, 64)
	vbox.add_child(spin_holder)

	var spinner = Node2D.new()
	spinner.set_script(SpinnerDrawerScript)
	spinner.position = Vector2(32, 32)
	spin_holder.add_child(spinner)

	var tw = spinner.create_tween().set_loops()
	tw.tween_property(spinner, "rotation", TAU, 1.8).from(0.0)

	var lbl = Label.new()
	lbl.text = "Invocando grimorios ancestrales..."
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_override("font", FONT_TITLE)
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.add_theme_color_override("font_color", RUNIC_CYAN)
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 2)
	vbox.add_child(lbl)

	var tw_txt = lbl.create_tween().set_loops()
	tw_txt.tween_property(lbl, "modulate:a", 0.4, 0.8).set_trans(Tween.TRANS_SINE)
	tw_txt.tween_property(lbl, "modulate:a", 1.0, 0.8).set_trans(Tween.TRANS_SINE)

	return box


# =============================================================================
# CARGA DE MAZOS
# =============================================================================
func _fetch_mazos() -> void:
	var api_client = _get_autoload("ExternalApiClient")
	if api_client:
		if not api_client.decks_received.is_connected(_on_external_decks_received):
			api_client.decks_received.connect(_on_external_decks_received, CONNECT_ONE_SHOT)
		if not api_client.decks_failed.is_connected(_on_external_decks_failed):
			api_client.decks_failed.connect(_on_external_decks_failed, CONNECT_ONE_SHOT)
		api_client.fetch_my_decks()
	else:
		_load_local_fallback()


func _on_external_decks_received(decks: Array) -> void:
	_mazos = []
	for d in decks:
		d["_is_external"] = true
		_mazos.append(d)
	_mazos.append_array(_get_preset_decks())
	if _mazos.is_empty():
		push_warning("[DeckSelector] Sin mazos propios ni presets — probando mazos locales")
		_load_local_fallback()
		return
	_populate_options()


func _on_external_decks_failed(reason: String) -> void:
	push_warning("[DeckSelector] No se pudieron cargar tus mazos (%s) — probando mazos locales" % reason)
	_load_local_fallback()


func _get_preset_decks() -> Array:
	var result: Array = []
	var loader = _get_autoload("DeckLoader")
	if loader and loader.has_method("get_local_decks"):
		for m in loader.get_local_decks():
			if str(m.get("slug", "")).begins_with("preset-"):
				m["_is_external"] = false
				result.append(m)
	return result


func _load_local_fallback() -> void:
	var loader = _get_autoload("DeckLoader")
	if loader:
		_mazos = loader.get_bundled_decks()
		if _mazos.is_empty():
			_mazos = loader.get_local_decks()
	else:
		_mazos = []

	for m in _mazos:
		m["_is_external"] = false

	if _mazos.is_empty():
		push_warning("[DeckSelector] Sin mazos disponibles. Usa 'Mazos aleatorios'.")
		_populate_with_error()
	else:
		print("[DeckSelector] Usando %d mazos offline" % _mazos.size())
		_populate_options()


# =============================================================================
# CONSTRUCCIÓN DE CADA GRIMORIO EN EL CARRUSEL
# =============================================================================
func _populate_options() -> void:
	_selected_player_idx = -1
	_player_cards.clear()

	for child in _player_row.get_children():
		_player_row.remove_child(child)
		child.queue_free()

	for i in range(_mazos.size()):
		var mazo: Dictionary = _mazos[i]
		var p_card := _build_deck_card(mazo, i)
		_player_row.add_child(p_card)
		_player_cards.append(p_card)

	# Mostrar flechas circulares si hay más de 5 mazos
	var has_overflow = _mazos.size() > 5
	if _btn_prev: _btn_prev.visible = has_overflow
	if _btn_next: _btn_next.visible = has_overflow

	# Auto-seleccionar el primer mazo por defecto
	if _mazos.size() > 0:
		_selected_player_idx = 0
		_refresh_selection(_player_cards, _selected_player_idx)
		_update_confirm_button()

	if _parchment_label:
		_parchment_label.text = "%d mazos\ndisponibles..." % _mazos.size()

	print("[DeckSelector] %d grimorios dispuestos sobre el altar." % _mazos.size())


func _populate_with_error() -> void:
	for child in _player_row.get_children():
		_player_row.remove_child(child)
		child.queue_free()
	var err = Label.new()
	err.text = "No se encontraron grimorios disponibles"
	err.add_theme_font_override("font", FONT_TITLE)
	err.add_theme_font_size_override("font_size", 16)
	err.add_theme_color_override("font_color", Color(0.9, 0.6, 0.4, 1.0))
	_player_row.add_child(err)
	if _parchment_label:
		_parchment_label.text = "Sin mazos\ndisponibles"


func _build_deck_card(mazo: Dictionary, idx: int) -> Control:
	var card = Control.new()
	card.name = "Grimoire_%d" % idx
	card.custom_minimum_size = CARD_SIZE
	card.size_flags_vertical = Control.SIZE_SHRINK_END

	# Sombra de contacto en la roca que permanece al elevarse el libro
	var ground_shadow = Panel.new()
	ground_shadow.name = "GroundShadow"
	ground_shadow.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	ground_shadow.custom_minimum_size = Vector2(0, 16)
	ground_shadow.position.y = CARD_SIZE.y - 8
	var shadow_flat = StyleBoxFlat.new()
	shadow_flat.bg_color = Color(0, 0, 0, 0.5)
	shadow_flat.set_corner_radius_all(10)
	shadow_flat.shadow_color = Color(0, 0, 0, 0.6)
	shadow_flat.shadow_size = 8
	ground_shadow.add_theme_stylebox_override("panel", shadow_flat)
	card.add_child(ground_shadow)

	# visual_box aloja el libro físico y permite la elevación mágica independiente
	var visual_box = Control.new()
	visual_box.name = "VisualBox"
	visual_box.custom_minimum_size = CARD_SIZE
	visual_box.size = CARD_SIZE
	visual_box.pivot_offset = CARD_SIZE / 2.0
	card.add_child(visual_box)

	# 1. Borde de Selección Dorado Elegante (como en el juego original)
	var glow_panel = PanelContainer.new()
	glow_panel.name = "SelectionGlow"
	glow_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glow_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var glow_style = StyleBoxFlat.new()
	glow_style.bg_color = Color(0, 0, 0, 0)
	glow_style.border_color = Color(0, 0, 0, 0)
	glow_style.set_border_width_all(0)
	glow_style.set_corner_radius_all(8)
	glow_style.shadow_color = Color(0, 0, 0, 0)
	glow_style.shadow_size = 0
	glow_panel.add_theme_stylebox_override("panel", glow_style)
	visual_box.add_child(glow_panel)

	# 2. Portada del Grimorio
	var content_clip = Control.new()
	content_clip.name = "ContentClip"
	content_clip.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content_clip.clip_contents = true
	visual_box.add_child(content_clip)

	var raw_nombre = str(mazo.get("nombre", mazo.get("name", "Mazo")))
	var nombre_clean = _sanitize_utf8(raw_nombre)
	var race_name := _extract_race_or_archetype(mazo)
	var card_texture: Texture2D = _get_card_texture(race_name, nombre_clean, idx)

	var tex_rect = TextureRect.new()
	tex_rect.name = "LeatherCover"
	tex_rect.texture = card_texture
	tex_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	content_clip.add_child(tex_rect)

	# 3. Botón invisible de interacción
	var button = Button.new()
	button.flat = true
	button.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.pressed.connect(_on_card_pressed.bind(idx))
	visual_box.add_child(button)

	card.set_meta("visual_box", visual_box)
	card.set_meta("glow_style", glow_style)

	button.mouse_entered.connect(func():
		if _selected_player_idx != idx:
			glow_style.border_color = Color(GOLD.r, GOLD.g, GOLD.b, 0.6)
			glow_style.set_border_width_all(2)
			glow_style.shadow_color = Color(0.83, 0.69, 0.22, 0.25)
			glow_style.shadow_size = 4
			var tw = visual_box.create_tween()
			tw.set_parallel(true)
			tw.tween_property(visual_box, "scale", Vector2(1.025, 1.025), 0.12).set_ease(Tween.EASE_OUT)
			tw.tween_property(visual_box, "position:y", -5.0, 0.12).set_ease(Tween.EASE_OUT)
	)
	button.mouse_exited.connect(func():
		if _selected_player_idx != idx:
			glow_style.border_color = Color(0, 0, 0, 0)
			glow_style.set_border_width_all(0)
			glow_style.shadow_color = Color(0, 0, 0, 0)
			glow_style.shadow_size = 0
			var tw = visual_box.create_tween()
			tw.set_parallel(true)
			tw.tween_property(visual_box, "scale", Vector2(1.0, 1.0), 0.12).set_ease(Tween.EASE_OUT)
			tw.tween_property(visual_box, "position:y", 0.0, 0.12).set_ease(Tween.EASE_OUT)
	)

	return card


func _get_card_texture(race: String, deck_name: String, idx: int) -> Texture2D:
	var r := (race + " " + deck_name).to_lower()
	if "caballero" in r or "paladin" in r or "paladín" in r:
		return TEX_CABALLERO
	elif "bestia" in r or "lobo" in r:
		return TEX_BESTIA
	elif "dragon" in r or "dragón" in r:
		return TEX_DRAGON
	elif "imp" in r or "demonio" in r:
		return TEX_IMP
	elif "heroe" in r or "héroe" in r or "defensor" in r:
		return TEX_HEROE
	elif "guerrero" in r or "barbaro" in r or "bárbaro" in r:
		return TEX_GUERRERO
	elif "faerie" in r or "hada" in r or "mago" in r:
		return TEX_FAERIE
	elif "sacerdote" in r or "santo" in r or "luz" in r:
		return TEX_SACERDOTE
	elif "sombra" in r or "undead" in r or "no-muerto" in r:
		return TEX_SOMBRA

	var all_textures := [
		TEX_CABALLERO, TEX_BESTIA, TEX_DRAGON, TEX_IMP,
		TEX_HEROE, TEX_GUERRERO, TEX_FAERIE, TEX_SACERDOTE, TEX_SOMBRA
	]
	return all_textures[idx % all_textures.size()]


func _extract_race_or_archetype(mazo: Dictionary) -> String:
	var val: String = str(mazo.get("raza", mazo.get("race", mazo.get("arquetipo", mazo.get("archetype", "")))))
	val = _sanitize_utf8(val)
	if val.is_empty():
		var nombre_lower := _sanitize_utf8(str(mazo.get("nombre", mazo.get("name", "")))).to_lower()
		for r in ["caballero", "bestia", "dragon", "dragón", "sombra", "faerie", "sacerdote", "eterno", "heroe", "héroe", "guerrero", "imp"]:
			if r in nombre_lower:
				return r
	return val


func _sanitize_utf8(text: String) -> String:
	var s = text
	s = s.replace("Ã¡", "á").replace("Ã©", "é").replace("Ã­", "í").replace("Ã³", "ó").replace("Ãº", "ú")
	s = s.replace("Ã±", "ñ").replace("Ã ", "Á").replace("Ã‰", "É").replace("Ã ", "Í").replace("Ã“", "Ó").replace("Ãš", "Ú").replace("Ã‘", "Ñ")
	s = s.replace("DragÃ³n", "Dragón").replace("DragÃ¡", "Dragá")
	return s


# =============================================================================
# NAVEGACIÓN Y CONTROL DEL CARRUSEL
# =============================================================================
func _on_scroll_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.is_pressed():
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_scroll_left()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_scroll_right()


func _scroll_left() -> void:
	if not _scroll_container: return
	var target_scroll = max(0, _scroll_container.scroll_horizontal - int(CARD_SIZE.x + 24))
	var tw = create_tween()
	tw.tween_property(_scroll_container, "scroll_horizontal", target_scroll, 0.22).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)


func _scroll_right() -> void:
	if not _scroll_container: return
	var target_scroll = _scroll_container.scroll_horizontal + int(CARD_SIZE.x + 24)
	var tw = create_tween()
	tw.tween_property(_scroll_container, "scroll_horizontal", target_scroll, 0.22).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)


func _on_card_pressed(idx: int) -> void:
	_selected_player_idx = idx
	_refresh_selection(_player_cards, idx)
	_update_confirm_button()

	# Centrar suavemente el grimorio seleccionado en el viewport del altar
	if _scroll_container and idx >= 0 and idx < _player_cards.size():
		var card_node = _player_cards[idx]
		var card_center_x = card_node.position.x + card_node.size.x / 2.0
		var visible_width = _scroll_container.size.x
		var desired_scroll = max(0, int(card_center_x - visible_width / 2.0))
		var tw = create_tween()
		tw.tween_property(_scroll_container, "scroll_horizontal", desired_scroll, 0.25).set_ease(Tween.EASE_OUT)


func _update_confirm_button() -> void:
	var can_confirm := (_selected_player_idx >= 0 and _selected_player_idx < _mazos.size())
	if _btn_confirm:
		_btn_confirm.modulate = Color(1.0, 1.0, 1.0, 1.0) if can_confirm else Color(0.65, 0.65, 0.65, 0.8)


func _refresh_selection(cards: Array, selected_idx: int) -> void:
	for i in range(cards.size()):
		var card: Control = cards[i]
		var visual_box: Control = card.get_meta("visual_box")
		var glow_style: StyleBoxFlat = card.get_meta("glow_style")
		var is_sel: bool = (i == selected_idx)

		var tw = visual_box.create_tween()
		tw.set_parallel(true)

		if is_sel:
			# Elevación Mágica: marco dorado cálido idéntico al juego original
			glow_style.border_color = GOLD_SELECTION
			glow_style.set_border_width_all(3)
			glow_style.shadow_color = Color(1.0, 0.82, 0.28, 0.4)
			glow_style.shadow_size = 8
			card.z_index = 10
			tw.tween_property(visual_box, "scale", Vector2(1.05, 1.05), 0.18).set_ease(Tween.EASE_OUT)
			tw.tween_property(visual_box, "position:y", -14.0, 0.18).set_ease(Tween.EASE_OUT)
		else:
			# Grimorio en reposo sobre la roca
			glow_style.border_color = Color(0, 0, 0, 0)
			glow_style.set_border_width_all(0)
			glow_style.shadow_color = Color(0, 0, 0, 0)
			glow_style.shadow_size = 0
			card.z_index = 0
			tw.tween_property(visual_box, "scale", Vector2(1.0, 1.0), 0.18).set_ease(Tween.EASE_OUT)
			tw.tween_property(visual_box, "position:y", 0.0, 0.18).set_ease(Tween.EASE_OUT)

	# Actualizar el cartel central de mazo seleccionado
	if selected_idx >= 0 and selected_idx < _mazos.size():
		var mazo: Dictionary = _mazos[selected_idx]
		var nombre_clean = _sanitize_utf8(str(mazo.get("nombre", mazo.get("name", "Mazo"))))
		var is_preset: bool = str(mazo.get("slug", "")).begins_with("preset-")
		var formato = _sanitize_utf8(str(mazo.get("formato", mazo.get("format", "Crónicas")))).capitalize()
		var cant_cartas: int = mazo.get("cartas", mazo.get("cards", [])).size()

		if _deck_banner:
			_deck_banner.text = ("⭐ " if is_preset else "") + nombre_clean
		if _deck_sub_banner:
			if cant_cartas > 0:
				_deck_sub_banner.text = "Formato: %s  •  %d cartas" % [formato, cant_cartas]
			else:
				_deck_sub_banner.text = "Formato: %s" % formato


func _on_confirm_pressed() -> void:
	if _mazos.is_empty() or _selected_player_idx < 0 or _selected_player_idx >= _mazos.size():
		return

	var player_deck: Dictionary = _mazos[_selected_player_idx]
	var opponent_deck: Dictionary = _mazos[randi() % _mazos.size()] if not _mazos.is_empty() else {}

	_close()
	emit_signal("decks_selected", player_deck, opponent_deck,
		player_deck.get("_is_external", false), opponent_deck.get("_is_external", false))


func _on_random_pressed() -> void:
	_close()
	emit_signal("decks_selected", {}, {}, false, false)


func _close() -> void:
	if _overlay and is_instance_valid(_overlay):
		_overlay.queue_free()
		_overlay = null
