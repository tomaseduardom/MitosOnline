extends Node
## DeckSelector — Interfaz diegética de selección de mazos antes de la partida.
## Altar rúnico ancestral con las 9 razas oficiales en alta definición:
## - Caballero, Bestia, Dragón, Imp, Héroe, Guerrero, Faerie, Sacerdote, Sombra.
## - Carrusel sobre la meseta del altar entre los monolitos rúnicos.
## - Pedestales de piedra interactivos que se funden 100% con la ilustración original.
## - Sin cajas verdes ni marcos intrusivos. Solo interacción orgánica y pura.

signal decks_selected(player_data: Dictionary, opponent_data: Dictionary, player_is_external: bool, opponent_is_external: bool)
signal selection_cancelled

const CARD_SIZE := Vector2(196, 266)
const GOLD := Color(0.83, 0.69, 0.22, 1.0)
const GOLD_HOVER := Color(0.88, 0.76, 0.35, 1.0)
const GOLD_SELECTION := Color(0.86, 0.72, 0.30, 0.90)
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

# Texturas de Encuadernación y Botones Diegéticos
const TEX_LEATHER := preload("res://assets/ui/deck_selector/card_base_leather.png")
const TEX_BTN_CONFIRM := preload("res://assets/ui/deck_selector/pedestal_confirm_exact.png")
const TEX_BTN_RANDOM := preload("res://assets/ui/deck_selector/pedestal_random_exact.png")
const TEX_BTN_PLAQUE_BLANK := preload("res://assets/ui/deck_selector/pedestal_plaque_blank.png")
const TEX_SHIMMER_CURVED := preload("res://assets/ui/deck_selector/shimmer_curved_beam.png")


# =============================================================================
# CLASES AUXILIARES DE RENDERIZADO VISUAL
# =============================================================================

## Dibuja remaches / tachas metálicas doradas en las 4 esquinas de la encuadernación de cuero
class StudsDrawer extends Control:
	var card_size: Vector2 = Vector2(196, 266)
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _draw() -> void:
		var w = size.x if size.x > 0 else card_size.x
		var h = size.y if size.y > 0 else card_size.y
		var studs = [
			Vector2(11, 12),
			Vector2(w - 11, 12),
			Vector2(11, h - 12),
			Vector2(w - 11, h - 12)
		]
		for pt in studs:
			# Anillo exterior de bronce oscuro
			draw_circle(pt, 4.5, Color(0.24, 0.16, 0.08, 0.95))
			# Núcleo de oro antiguo
			draw_circle(pt, 3.2, Color(0.88, 0.72, 0.28, 1.0))
			# Reflejo especular blanco
			draw_circle(pt - Vector2(1.0, 1.0), 1.2, Color(1.0, 0.98, 0.90, 0.95))


## Dibuja gemas rúnicas turquesas con halo radial brillante y pulsación viva
class GemGlowDrawer extends Control:
	var pulse_alpha: float = 0.6:
		set(v):
			pulse_alpha = v
			queue_redraw()
	var gem_color: Color = Color(0.05, 0.95, 0.85)
	var gem_positions: Array = []
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _draw() -> void:
		for pt in gem_positions:
			# Resplandor difuso exterior
			draw_circle(pt, 13.0, Color(gem_color.r, gem_color.g, gem_color.b, 0.22 * pulse_alpha))
			# Halo medio brillante
			draw_circle(pt, 7.5, Color(gem_color.r, gem_color.g, gem_color.b, 0.50 * pulse_alpha))
			# Núcleo intenso
			draw_circle(pt, 3.8, Color(0.75, 1.0, 0.95, 0.90 * pulse_alpha))
			# Punto especular
			draw_circle(pt - Vector2(1.0, 1.0), 1.3, Color(1.0, 1.0, 1.0, min(1.0, pulse_alpha)))


## Reflejo de luz curvado y orgánico (sin esquinas puntiagudas) para el barrido Shimmer
class ShimmerBeam extends TextureRect:
	func _init() -> void:
		texture = preload("res://assets/ui/deck_selector/shimmer_curved_beam.png")
		expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		mouse_filter = Control.MOUSE_FILTER_IGNORE


var _canvas_layer: CanvasLayer = null
var _overlay: Control = null
var _btn_available_decks: Control = null
var _btn_available_decks_clicker: Button = null
var _scroll_container: ScrollContainer = null
var _player_row: HBoxContainer = null
var _btn_confirm: Control = null
var _btn_confirm_clicker: Button = null
# 2026-09-23, bug real reportado por el usuario ("no se pudo cargar este
# mazo (revisa tu conexión)"): _on_confirm_pressed() no tenía ninguna
# guarda contra re-entrada — el botón seguía clickeable mientras
# _resolve_deck_entries() esperaba una respuesta lenta de ShadowForge, y el
# log real mostró 3 llamadas simultáneas a _resolve_deck_entries() para el
# mismo mazo (3 clicks de impaciencia sin feedback visible), saturando el
# backend gratuito de PythonAnywhere (probablemente un solo worker) hasta
# que las 3 quedaban sin respuesta. Ver arquitectura.md §13.15.
var _confirming: bool = false
var _confirm_flash: ColorRect = null
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

# 2026-09-22, bug real reportado por el usuario: "se queda cargando y nunca
# termina" — la cadena real de fetches (mazos privados -> mazos públicos ->
# _populate_options()) tiene 3 pasos encadenados, cada uno con su propio
# timeout de red, pero ningún límite GLOBAL sobre la cadena completa. Si
# cualquier eslabón se cuelga (señal que nunca llega, conexión que nunca
# resuelve), el "Invocando grimorios ancestrales..." queda ahí para siempre
# y no hay ningún camino que lleve a mostrar presets o el aviso de "no se
# encontraron mazos". _mazos_load_resolved corta esto: se marca en TODO
# camino terminal real (_populate_options()/_populate_with_error()) y un
# vigía de 25s (más que cualquier timeout HTTP individual, todos en 15-20s)
# fuerza el fallback local si para entonces nada resolvió solo.
var _mazos_load_resolved: bool = false


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
	_canvas_layer = CanvasLayer.new()
	_canvas_layer.name = "DeckSelectorCanvasLayer"
	_canvas_layer.layer = 25
	parent.add_child(_canvas_layer)

	_overlay = Control.new()
	_overlay.name = "AltarDeckSelectorOverlay"
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas_layer.add_child(_overlay)

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
	# Los libros reposan directamente sobre la repisa de piedra con amplio margen para elevación
	var carousel_wrapper = Control.new()
	carousel_wrapper.name = "AltarCarouselWrapper"
	carousel_wrapper.set_anchor(SIDE_LEFT, 0.5)
	carousel_wrapper.set_anchor(SIDE_RIGHT, 0.5)
	carousel_wrapper.set_anchor(SIDE_TOP, 0.5)
	carousel_wrapper.set_anchor(SIDE_BOTTOM, 0.5)
	carousel_wrapper.set_offset(SIDE_LEFT, -570)
	carousel_wrapper.set_offset(SIDE_RIGHT, 570)
	carousel_wrapper.set_offset(SIDE_TOP, -255)
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

	# Margen de seguridad para que los libros no se corten al elevarse, escalar o brillar
	var scroll_margin = MarginContainer.new()
	scroll_margin.name = "ScrollMargin"
	scroll_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll_margin.add_theme_constant_override("margin_left", 40)
	scroll_margin.add_theme_constant_override("margin_right", 40)
	scroll_margin.add_theme_constant_override("margin_top", 28)
	scroll_margin.add_theme_constant_override("margin_bottom", 16)
	_scroll_container.add_child(scroll_margin)

	_player_row = HBoxContainer.new()
	_player_row.name = "GrimoriosRow"
	_player_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_player_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_player_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_player_row.custom_minimum_size = Vector2(0, 290)
	_player_row.add_theme_constant_override("separation", 20)
	scroll_margin.add_child(_player_row)

	# Placeholder de carga místico con runas giratorias
	_loading_box = _build_loading_placeholder()
	_player_row.add_child(_loading_box)

	# 3. Botones Rúnicos Circulares de Navegación Lateral (◄ y ►)
	_btn_prev = _build_circular_nav_button("◄", Vector2(-630, -50))
	_btn_prev.pressed.connect(_scroll_left)
	_overlay.add_child(_btn_prev)

	_btn_next = _build_circular_nav_button("►", Vector2(582, -50))
	_btn_next.pressed.connect(_scroll_right)
	_overlay.add_child(_btn_next)

	# 4. Cartel Central de Mazo Activo (sobre el grabado de piedra "ELIGE TU MAZO")
	_build_center_banner()

	# 5. Pedestal de Mazos Disponibles (esquina inferior izquierda)
	_build_available_decks_pedestal()

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
	"""Muestra el nombre del mazo activo elegantemente centrado sobre el altar,
	justo debajo de los grimorios y sin tapar la inscripción ELIGE TU MAZO tallada en la roca"""
	var banner_box = VBoxContainer.new()
	banner_box.name = "ActiveDeckBanner"
	banner_box.set_anchor(SIDE_LEFT, 0.5)
	banner_box.set_anchor(SIDE_RIGHT, 0.5)
	banner_box.set_anchor(SIDE_TOP, 0.5)
	banner_box.set_anchor(SIDE_BOTTOM, 0.5)
	banner_box.set_offset(SIDE_LEFT, -320)
	banner_box.set_offset(SIDE_RIGHT, 320)
	banner_box.set_offset(SIDE_TOP, 90)
	banner_box.set_offset(SIDE_BOTTOM, 142)
	banner_box.alignment = BoxContainer.ALIGNMENT_CENTER
	banner_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(banner_box)

	var plate = PanelContainer.new()
	plate.name = "BannerPlate"
	var plate_style = StyleBoxFlat.new()
	plate_style.bg_color = Color(0.06, 0.08, 0.10, 0.72)
	plate_style.border_color = Color(0.83, 0.69, 0.22, 0.35)
	plate_style.set_border_width_all(1)
	plate_style.set_corner_radius_all(6)
	plate_style.set_expand_margin_all(5)
	plate.add_theme_stylebox_override("panel", plate_style)
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner_box.add_child(plate)

	var text_vbox = VBoxContainer.new()
	text_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	text_vbox.add_theme_constant_override("separation", 2)
	plate.add_child(text_vbox)

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
	text_vbox.add_child(_deck_banner)

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
	text_vbox.add_child(_deck_sub_banner)


func _build_available_decks_pedestal() -> void:
	"""Crea el botón-pedestal diegético de 'Mazos Disponibles' en la meseta izquierda del altar.
	Cubre completamente el fondo original con una placa de piedra gótica en alto contraste,
	sincronizada simétricamente con el botón de Mazos Aleatorios."""

	# Pedestal Plaque Control (sincronizado con Mazos Aleatorios en tamaño y nivel vertical)
	_btn_available_decks = Control.new()
	_btn_available_decks.name = "PedestalMazosDisponibles"
	_btn_available_decks.set_anchor(SIDE_LEFT, 0.5)
	_btn_available_decks.set_anchor(SIDE_RIGHT, 0.5)
	_btn_available_decks.set_anchor(SIDE_TOP, 0.5)
	_btn_available_decks.set_anchor(SIDE_BOTTOM, 0.5)
	_btn_available_decks.set_offset(SIDE_LEFT, -550)
	_btn_available_decks.set_offset(SIDE_RIGHT, -230)
	_btn_available_decks.set_offset(SIDE_TOP, 224)
	_btn_available_decks.set_offset(SIDE_BOTTOM, 331)
	_btn_available_decks.pivot_offset = Vector2(160.0, 53.5)
	_btn_available_decks.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(_btn_available_decks)

	# Contenedor para animación táctil
	var plaque_fx = Control.new()
	plaque_fx.name = "PlaqueFX"
	plaque_fx.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	plaque_fx.pivot_offset = Vector2(160.0, 53.5)
	plaque_fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_btn_available_decks.add_child(plaque_fx)

	# Textura HD de piedra tallada idéntica a Mazos Aleatorios
	var plaque_tex = TextureRect.new()
	plaque_tex.name = "ButtonTexture"
	plaque_tex.texture = TEX_BTN_PLAQUE_BLANK
	plaque_tex.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	plaque_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	plaque_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	plaque_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plaque_fx.add_child(plaque_tex)

	# Capa de efectos Shimmer confinado a la placa
	var stone_fx = Control.new()
	stone_fx.name = "StonePlaqueFX"
	stone_fx.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stone_fx.clip_contents = true
	stone_fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plaque_fx.add_child(stone_fx)

	var shimmer_beam = ShimmerBeam.new()
	shimmer_beam.name = "ShimmerBeam"
	shimmer_beam.size = Vector2(36, 110)
	shimmer_beam.position = Vector2(-70, 0)
	stone_fx.add_child(shimmer_beam)

	# Etiqueta con tipografía grande, nítida y en alto contraste
	_parchment_label = Label.new()
	_parchment_label.name = "LabelDisponibles"
	_parchment_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_parchment_label.text = "CARGANDO MAZOS..."
	_parchment_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_parchment_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_parchment_label.add_theme_font_override("font", FONT_TITLE)
	_parchment_label.add_theme_font_size_override("font_size", 18)
	_parchment_label.add_theme_color_override("font_color", Color(0.95, 0.90, 0.75, 1.0))
	_parchment_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.98))
	_parchment_label.add_theme_constant_override("shadow_offset_x", 1)
	_parchment_label.add_theme_constant_override("shadow_offset_y", 2)
	_parchment_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plaque_fx.add_child(_parchment_label)

	# Clicker interactivo para sensación táctil y abrir explorador de mazos
	_btn_available_decks_clicker = Button.new()
	_btn_available_decks_clicker.name = "Clicker"
	_btn_available_decks_clicker.flat = true
	_btn_available_decks_clicker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_btn_available_decks_clicker.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_btn_available_decks_clicker.pressed.connect(_on_available_decks_pressed)
	_btn_available_decks.add_child(_btn_available_decks_clicker)

	_btn_available_decks_clicker.mouse_entered.connect(func():
		var tw = plaque_fx.create_tween()
		tw.set_parallel(true)
		tw.tween_property(plaque_fx, "scale", Vector2(1.008, 1.008), 0.12).set_ease(Tween.EASE_OUT)
		tw.tween_property(plaque_fx, "position:y", -1.0, 0.12).set_ease(Tween.EASE_OUT)
		_trigger_shimmer(shimmer_beam, 360.0)
	)
	_btn_available_decks_clicker.mouse_exited.connect(func():
		var tw = plaque_fx.create_tween()
		tw.set_parallel(true)
		tw.tween_property(plaque_fx, "scale", Vector2(1.0, 1.0), 0.12).set_ease(Tween.EASE_OUT)
		tw.tween_property(plaque_fx, "position:y", 0.0, 0.12).set_ease(Tween.EASE_OUT)
	)
	_btn_available_decks_clicker.button_down.connect(func():
		var tw = plaque_fx.create_tween()
		tw.set_parallel(true)
		tw.tween_property(plaque_fx, "scale", Vector2(0.992, 0.992), 0.06).set_ease(Tween.EASE_OUT)
		tw.tween_property(plaque_fx, "position:y", 1.0, 0.06).set_ease(Tween.EASE_OUT)
	)
	_btn_available_decks_clicker.button_up.connect(func():
		var tw = plaque_fx.create_tween()
		tw.set_parallel(true)
		tw.tween_property(plaque_fx, "scale", Vector2(1.008, 1.008), 0.1).set_ease(Tween.EASE_OUT)
		tw.tween_property(plaque_fx, "position:y", -1.0, 0.1).set_ease(Tween.EASE_OUT)
	)


func _on_available_decks_pressed() -> void:
	_open_public_deck_browser()


func _build_clean_action_buttons() -> void:
	"""Crea botones interactivos en el pedestal que calzan al milímetro sobre los botones
	del fondo original, tapándolos por completo con versiones 3D táctiles y vivas."""
	
	# =========================================================================
	# 1. PEDESTAL CENTRAL: COMENZAR PARTIDA (Calce 100% exacto sobre el altar)
	# =========================================================================
	_btn_confirm = Control.new()
	_btn_confirm.name = "PedestalComenzarPartida"
	_btn_confirm.set_anchor(SIDE_LEFT, 0.5)
	_btn_confirm.set_anchor(SIDE_RIGHT, 0.5)
	_btn_confirm.set_anchor(SIDE_TOP, 0.5)
	_btn_confirm.set_anchor(SIDE_BOTTOM, 0.5)
	_btn_confirm.set_offset(SIDE_LEFT, -189)
	_btn_confirm.set_offset(SIDE_RIGHT, 221)
	_btn_confirm.set_offset(SIDE_TOP, 235)
	_btn_confirm.set_offset(SIDE_BOTTOM, 407)
	_btn_confirm.pivot_offset = Vector2(205.0, 86.0)
	_btn_confirm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(_btn_confirm)

	# Contenedor para animación táctil (escala y elevación 3D limpia)
	var confirm_fx = Control.new()
	confirm_fx.name = "ConfirmFX"
	confirm_fx.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	confirm_fx.pivot_offset = Vector2(205.0, 86.0)
	confirm_fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_btn_confirm.add_child(confirm_fx)

	# Textura HD exacta que cubre ("tapa") el botón del fondo original a la perfección
	var confirm_tex = TextureRect.new()
	confirm_tex.name = "ButtonTexture"
	confirm_tex.texture = TEX_BTN_CONFIRM
	confirm_tex.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	confirm_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	confirm_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	confirm_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	confirm_fx.add_child(confirm_tex)

	# Capa de Gemas Turquesas Rúnicas Vivas (ubicadas al píxel sobre las 4 gemas del pedestal)
	var confirm_gems = GemGlowDrawer.new()
	confirm_gems.name = "RunicGems"
	confirm_gems.gem_color = Color(0.05, 0.95, 0.85)
	confirm_gems.gem_positions = [
		Vector2(25.5, 85.5),   # Gema ala izquierda
		Vector2(384.0, 85.5),  # Gema ala derecha
		Vector2(205.5, 27.0),  # Gema diamante superior
		Vector2(205.0, 142.5)  # Gema diamante inferior
	]
	confirm_fx.add_child(confirm_gems)
	_start_gem_pulse(confirm_gems)

	# Pastilla Esmeralda Diegética para brillo interior y Shimmer (sin paneles verdes artificiales)
	var pill_fx = Control.new()
	pill_fx.name = "EmeraldPillFX"
	pill_fx.set_anchor(SIDE_LEFT, 0.5)
	pill_fx.set_anchor(SIDE_RIGHT, 0.5)
	pill_fx.set_anchor(SIDE_TOP, 0.5)
	pill_fx.set_anchor(SIDE_BOTTOM, 0.5)
	pill_fx.set_offset(SIDE_LEFT, -155)
	pill_fx.set_offset(SIDE_RIGHT, 155)
	pill_fx.set_offset(SIDE_TOP, -36)
	pill_fx.set_offset(SIDE_BOTTOM, 36)
	pill_fx.pivot_offset = Vector2(155.0, 36.0)
	pill_fx.clip_contents = true
	pill_fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	confirm_fx.add_child(pill_fx)

	# Haz de luz Shimmer diagonal confinado a la pastilla esmeralda
	var confirm_shimmer_beam = ShimmerBeam.new()
	confirm_shimmer_beam.name = "ShimmerBeam"
	confirm_shimmer_beam.size = Vector2(36, 72)
	confirm_shimmer_beam.position = Vector2(-70, 0)
	pill_fx.add_child(confirm_shimmer_beam)

	# Destello de confirmación al presionar el botón
	_confirm_flash = ColorRect.new()
	_confirm_flash.name = "EmeraldFlash"
	_confirm_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_confirm_flash.color = Color(1.0, 0.95, 0.8, 0.0)
	_confirm_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill_fx.add_child(_confirm_flash)

	# Botón invisible de interacción táctil
	_btn_confirm_clicker = Button.new()
	_btn_confirm_clicker.name = "Clicker"
	_btn_confirm_clicker.flat = true
	_btn_confirm_clicker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_btn_confirm_clicker.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_btn_confirm_clicker.pressed.connect(_on_confirm_pressed)
	_btn_confirm.add_child(_btn_confirm_clicker)

	_btn_confirm_clicker.mouse_entered.connect(func():
		if _selected_player_idx >= 0:
			var tw = confirm_fx.create_tween()
			tw.set_parallel(true)
			tw.tween_property(confirm_fx, "scale", Vector2(1.008, 1.008), 0.12).set_ease(Tween.EASE_OUT)
			tw.tween_property(confirm_fx, "position:y", -1.0, 0.12).set_ease(Tween.EASE_OUT)
			tw.tween_property(confirm_gems, "pulse_alpha", 0.85, 0.12)
			_trigger_shimmer(confirm_shimmer_beam, 380.0)
	)
	_btn_confirm_clicker.mouse_exited.connect(func():
		var tw = confirm_fx.create_tween()
		tw.set_parallel(true)
		tw.tween_property(confirm_fx, "scale", Vector2(1.0, 1.0), 0.12).set_ease(Tween.EASE_OUT)
		tw.tween_property(confirm_fx, "position:y", 0.0, 0.12).set_ease(Tween.EASE_OUT)
		tw.tween_property(confirm_gems, "pulse_alpha", 0.45, 0.12)
	)
	_btn_confirm_clicker.button_down.connect(func():
		if _selected_player_idx >= 0:
			var tw = confirm_fx.create_tween()
			tw.set_parallel(true)
			tw.tween_property(confirm_fx, "scale", Vector2(0.992, 0.992), 0.06).set_ease(Tween.EASE_OUT)
			tw.tween_property(confirm_fx, "position:y", 1.0, 0.06).set_ease(Tween.EASE_OUT)
	)
	_btn_confirm_clicker.button_up.connect(func():
		var tw = confirm_fx.create_tween()
		tw.set_parallel(true)
		tw.tween_property(confirm_fx, "scale", Vector2(1.008, 1.008), 0.1).set_ease(Tween.EASE_OUT)
		tw.tween_property(confirm_fx, "position:y", -1.0, 0.1).set_ease(Tween.EASE_OUT)
	)

	# =========================================================================
	# 2. PEDESTAL DERECHO: MAZOS ALEATORIOS (Calce 100% exacto sobre la lápida)
	# =========================================================================
	_btn_random = Control.new()
	_btn_random.name = "PedestalMazosAleatorios"
	_btn_random.set_anchor(SIDE_LEFT, 0.5)
	_btn_random.set_anchor(SIDE_RIGHT, 0.5)
	_btn_random.set_anchor(SIDE_TOP, 0.5)
	_btn_random.set_anchor(SIDE_BOTTOM, 0.5)
	_btn_random.set_offset(SIDE_LEFT, 328)
	_btn_random.set_offset(SIDE_RIGHT, 648)
	_btn_random.set_offset(SIDE_TOP, 224)
	_btn_random.set_offset(SIDE_BOTTOM, 331)
	_btn_random.pivot_offset = Vector2(160.0, 53.5)
	_btn_random.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(_btn_random)

	# Contenedor para animación táctil
	var random_fx = Control.new()
	random_fx.name = "RandomFX"
	random_fx.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	random_fx.pivot_offset = Vector2(160.0, 53.5)
	random_fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_btn_random.add_child(random_fx)

	# Textura HD exacta que cubre ("tapa") la lápida del fondo original al píxel
	var random_tex = TextureRect.new()
	random_tex.name = "ButtonTexture"
	random_tex.texture = TEX_BTN_RANDOM
	random_tex.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	random_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	random_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	random_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	random_fx.add_child(random_tex)

	# Capa de efectos sobre la placa de piedra (sin brillos ni paneles azules artificiales)
	var stone_fx = Control.new()
	stone_fx.name = "StonePlaqueFX"
	stone_fx.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stone_fx.clip_contents = true
	stone_fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	random_fx.add_child(stone_fx)

	# Haz Shimmer confinado a la placa de piedra
	var random_shimmer_beam = ShimmerBeam.new()
	random_shimmer_beam.name = "ShimmerBeam"
	random_shimmer_beam.size = Vector2(36, 110)
	random_shimmer_beam.position = Vector2(-70, 0)
	stone_fx.add_child(random_shimmer_beam)

	_btn_random_clicker = Button.new()
	_btn_random_clicker.name = "Clicker"
	_btn_random_clicker.flat = true
	_btn_random_clicker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_btn_random_clicker.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_btn_random_clicker.pressed.connect(_on_random_pressed)
	_btn_random.add_child(_btn_random_clicker)

	_btn_random_clicker.mouse_entered.connect(func():
		var tw = random_fx.create_tween()
		tw.set_parallel(true)
		tw.tween_property(random_fx, "scale", Vector2(1.008, 1.008), 0.12).set_ease(Tween.EASE_OUT)
		tw.tween_property(random_fx, "position:y", -1.0, 0.12).set_ease(Tween.EASE_OUT)
		_trigger_shimmer(random_shimmer_beam, 360.0)
	)
	_btn_random_clicker.mouse_exited.connect(func():
		var tw = random_fx.create_tween()
		tw.set_parallel(true)
		tw.tween_property(random_fx, "scale", Vector2(1.0, 1.0), 0.12).set_ease(Tween.EASE_OUT)
		tw.tween_property(random_fx, "position:y", 0.0, 0.12).set_ease(Tween.EASE_OUT)
	)
	_btn_random_clicker.button_down.connect(func():
		var tw = random_fx.create_tween()
		tw.set_parallel(true)
		tw.tween_property(random_fx, "scale", Vector2(0.992, 0.992), 0.06).set_ease(Tween.EASE_OUT)
		tw.tween_property(random_fx, "position:y", 1.0, 0.06).set_ease(Tween.EASE_OUT)
	)
	_btn_random_clicker.button_up.connect(func():
		var tw = random_fx.create_tween()
		tw.set_parallel(true)
		tw.tween_property(random_fx, "scale", Vector2(1.008, 1.008), 0.1).set_ease(Tween.EASE_OUT)
		tw.tween_property(random_fx, "position:y", -1.0, 0.1).set_ease(Tween.EASE_OUT)
	)

	# =========================================================================
	# 4. BOTÓN "MAZOS PÚBLICOS" (2026-09-22, a pedido del usuario: buscar y
	# jugar mazos públicos de otros jugadores de ShadowForge). Botón plano
	# simple, sin pedestal a medida como los de arriba (no hay textura para
	# esto) — abre un popup de búsqueda encima del altar.
	# =========================================================================
	var public_decks_btn = Button.new()
	public_decks_btn.name = "PublicDecksButton"
	public_decks_btn.text = "Mazos públicos de ShadowForge"
	public_decks_btn.set_anchor(SIDE_LEFT, 1.0)
	public_decks_btn.set_anchor(SIDE_RIGHT, 1.0)
	public_decks_btn.set_anchor(SIDE_TOP, 0.0)
	public_decks_btn.set_anchor(SIDE_BOTTOM, 0.0)
	public_decks_btn.set_offset(SIDE_LEFT, -260)
	public_decks_btn.set_offset(SIDE_RIGHT, -16)
	public_decks_btn.set_offset(SIDE_TOP, 16)
	public_decks_btn.set_offset(SIDE_BOTTOM, 52)
	public_decks_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	public_decks_btn.add_theme_font_override("font", FONT_MEDIEVAL)
	public_decks_btn.add_theme_font_size_override("font_size", 14)
	public_decks_btn.pressed.connect(_open_public_deck_browser)
	_overlay.add_child(public_decks_btn)


func _start_gem_pulse(drawer: GemGlowDrawer) -> void:
	if not is_instance_valid(drawer): return
	var tw = drawer.create_tween().set_loops()
	tw.tween_property(drawer, "pulse_alpha", 1.0, 1.3).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)
	tw.tween_property(drawer, "pulse_alpha", 0.45, 1.3).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)


func _trigger_shimmer(beam: ShimmerBeam, target_x: float) -> void:
	if not is_instance_valid(beam): return
	beam.position.x = -70.0
	var tw = beam.create_tween()
	tw.tween_property(beam, "position:x", target_x, 0.55).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)


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
	_mazos_load_resolved = false
	if is_inside_tree():
		# 65s: por encima del timeout HTTP real de 60s (ver ExternalApiClient
		# ._authed_request()) para no forzar el fallback local mientras una
		# respuesta todavía podría llegar a tiempo.
		get_tree().create_timer(65.0).timeout.connect(_on_mazos_load_watchdog_timeout)

	var api_client = _get_autoload("ExternalApiClient")
	if api_client:
		if not api_client.decks_received.is_connected(_on_external_decks_received):
			api_client.decks_received.connect(_on_external_decks_received, CONNECT_ONE_SHOT)
		if not api_client.decks_failed.is_connected(_on_external_decks_failed):
			api_client.decks_failed.connect(_on_external_decks_failed, CONNECT_ONE_SHOT)
		api_client.fetch_my_decks()
	else:
		_load_local_fallback()


func _on_mazos_load_watchdog_timeout() -> void:
	"""Se ejecuta 65s después de empezar a cargar, sin importar qué haya
	pasado con la cadena real de fetches. Si para entonces ya se resolvió
	solo (camino normal), no hace nada. Si no, fuerza el fallback local en
	vez de dejar el 'Invocando grimorios ancestrales...' para siempre."""
	if _mazos_load_resolved:
		return
	push_warning("[DeckSelector] La carga de mazos no resolvió en 65s — forzando mazos locales")
	_load_local_fallback()


func _on_external_decks_received(decks: Array) -> void:
	if _mazos_load_resolved:
		return
	_mazos = []
	for d in decks:
		d["_is_external"] = true
		d["_shadowforge_kind"] = "my"
		_mazos.append(d)
	_mazos.append_array(_get_preset_decks())
	if _mazos.is_empty():
		push_warning("[DeckSelector] Sin mazos propios ni presets — probando mazos locales")
		_load_local_fallback()
		return
	_fetch_and_merge_public_decks()


func _on_external_decks_failed(reason: String) -> void:
	if _mazos_load_resolved:
		return
	push_warning("[DeckSelector] No se pudieron cargar tus mazos (%s) — probando mazos locales" % reason)
	_load_local_fallback()


# =============================================================================
# FUSIÓN DE MAZOS PRIVADOS + PÚBLICOS (2026-09-22, a pedido del usuario:
# "la idea es que el botón mis mazos te muestre los mazos privados y
# públicos") — antes los públicos solo aparecían detrás del popup de
# búsqueda aparte (_open_public_deck_browser más abajo, que sigue
# disponible para buscar algo puntual más allá de esta primera página).
# =============================================================================
func _fetch_and_merge_public_decks() -> void:
	"""Trae una primera página de mazos públicos (orden 'popular') y la
	fusiona en _mazos junto a los privados/preset ya armados, antes de
	poblar el carrusel. Si falla (sin conexión, API caída), no bloquea la
	pantalla — se sigue igual con lo que ya hay."""
	var api_client = _get_autoload("ExternalApiClient")
	if not api_client:
		_populate_options()
		return
	if not api_client.public_decks_received.is_connected(_on_initial_public_decks_received):
		api_client.public_decks_received.connect(_on_initial_public_decks_received, CONNECT_ONE_SHOT)
	if not api_client.public_decks_failed.is_connected(_on_initial_public_decks_failed):
		api_client.public_decks_failed.connect(_on_initial_public_decks_failed, CONNECT_ONE_SHOT)
	api_client.fetch_public_decks("", 1, "", "", "popular")


func _on_initial_public_decks_received(results: Array, _count: int) -> void:
	if _mazos_load_resolved:
		return
	# Solo datos resumidos aquí (sin "entries") — se resuelven de verdad solo
	# al confirmar (_on_confirm_pressed() -> _resolve_deck_entries()), no
	# tiene sentido bajar las cartas de mazos que el jugador quizás nunca
	# elija.
	for r in results:
		if not r is Dictionary:
			continue
		var owner := str(r.get("owner_username", "?"))
		var mazo := {
			"slug": "public-%d" % int(r.get("id", 0)),
			"nombre": "%s — por %s" % [str(r.get("name", "Mazo sin nombre")), owner],
			"arquetipo": str(r.get("race", "")),
			"raza": str(r.get("race", "")),
			"formato": str(r.get("format", "")),
			"entries": [],
			"id": int(r.get("id", 0)),
			"image_url": str(r.get("image_url", "")),
			"_is_external": true,
			"_shadowforge_kind": "public",
		}
		_mazos.append(mazo)
	_populate_options()


func _on_initial_public_decks_failed(_reason: String) -> void:
	if _mazos_load_resolved:
		return
	_populate_options()


func _get_preset_decks() -> Array:
	"""2026-09-23, bug real reportado por el usuario ("no encontró los
	mazos" en 2 PCs distintas): esto usaba get_local_decks() — lee
	user://decks/, una carpeta POR MÁQUINA que empieza VACÍA en cualquier
	instalación nueva del .exe. En la máquina de desarrollo "funcionaba" de
	casualidad porque ahí se acumularon 183 mazos de prueba durante toda la
	sesión; en una PC recién instalada da 0, dejando el carrusel sin ningún
	preset. Los presets reales van embebidos en el propio .exe
	(res://data/decks/*.json, ver arquitectura.md §12.1/§12) y se leen con
	get_bundled_decks() — SIEMPRE disponible, sin depender de nada por
	máquina. Se combinan ambas fuentes (bundled primero, garantizado; local
	como extra si la máquina tiene algo guardado) en vez de usar una sola,
	deduplicando por slug."""
	var result: Array = []
	var seen_slugs: Dictionary = {}
	var loader = _get_autoload("DeckLoader")
	if not loader:
		return result

	if loader.has_method("get_bundled_decks"):
		for m in loader.get_bundled_decks():
			var slug := str(m.get("slug", ""))
			if slug.begins_with("preset-") and not seen_slugs.has(slug):
				m["_is_external"] = false
				result.append(m)
				seen_slugs[slug] = true

	if loader.has_method("get_local_decks"):
		for m in loader.get_local_decks():
			var slug := str(m.get("slug", ""))
			if slug.begins_with("preset-") and not seen_slugs.has(slug):
				m["_is_external"] = false
				result.append(m)
				seen_slugs[slug] = true

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
	_mazos_load_resolved = true
	_selected_player_idx = -1
	_player_cards.clear()

	for child in _player_row.get_children():
		_player_row.remove_child(child)
		child.queue_free()

	# 2026-09-22, a pedido del usuario ("que estén separados los mazos
	# públicos y privados, primero los míos, en otra columna los
	# públicos"): el orden real de _mazos YA es privados+preset primero,
	# públicos al final (ver _on_external_decks_received() ->
	# _fetch_and_merge_public_decks()) — aquí solo se agrega el separador
	# visual entre los dos grupos, detectando la transición por
	# "_shadowforge_kind" (todo lo que NO sea "public" cuenta como "mío":
	# mazos privados de ShadowForge y presets locales por igual). El
	# separador es un Control aparte, nunca se agrega a _player_cards, así
	# que los índices de selección (_selected_player_idx / _mazos) no se
	# desalinean con los mazos reales.
	var divider_shown := false
	var any_mine := false
	for i in range(_mazos.size()):
		var mazo: Dictionary = _mazos[i]
		var is_public: bool = str(mazo.get("_shadowforge_kind", "")) == "public"
		if not is_public:
			any_mine = true
		if is_public and any_mine and not divider_shown:
			_player_row.add_child(_build_section_divider("MAZOS PÚBLICOS\nDE SHADOWFORGE"))
			divider_shown = true
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
		_parchment_label.text = "%d MAZOS DISPONIBLES" % _mazos.size()

	print("[DeckSelector] %d grimorios dispuestos sobre el altar." % _mazos.size())


func _populate_with_error() -> void:
	_mazos_load_resolved = true
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
		_parchment_label.text = "SIN MAZOS DISPONIBLES"


func _build_section_divider(label_text: String) -> Control:
	"""Separador visual entre el grupo de mazos 'míos' (privados de
	ShadowForge + presets locales) y el grupo de mazos públicos, dentro del
	mismo carrusel horizontal (2026-09-22, a pedido del usuario). Un Control
	angosto, no un mazo — nunca se agrega a _player_cards ni participa de la
	selección."""
	var holder := Control.new()
	holder.name = "SectionDivider"
	holder.custom_minimum_size = Vector2(46, CARD_SIZE.y)
	holder.size_flags_vertical = Control.SIZE_SHRINK_END
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var line := ColorRect.new()
	line.color = Color(GOLD.r, GOLD.g, GOLD.b, 0.45)
	line.set_anchor(SIDE_LEFT, 0.5)
	line.set_anchor(SIDE_RIGHT, 0.5)
	line.set_anchor(SIDE_TOP, 0.0)
	line.set_anchor(SIDE_BOTTOM, 1.0)
	line.offset_left = -1
	line.offset_right = 1
	line.offset_top = 6
	line.offset_bottom = -6
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(line)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.set_anchor(SIDE_LEFT, 0.5)
	lbl.set_anchor(SIDE_RIGHT, 0.5)
	lbl.set_anchor(SIDE_TOP, 0.5)
	lbl.set_anchor(SIDE_BOTTOM, 0.5)
	lbl.offset_left = -CARD_SIZE.y / 2.0
	lbl.offset_right = CARD_SIZE.y / 2.0
	lbl.offset_top = -18
	lbl.offset_bottom = 18
	lbl.rotation_degrees = -90
	lbl.add_theme_font_override("font", FONT_TITLE)
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", GOLD)
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	holder.add_child(lbl)

	return holder


func _build_deck_card(mazo: Dictionary, idx: int) -> Control:
	var card = Control.new()
	card.name = "Grimoire_%d" % idx
	card.custom_minimum_size = CARD_SIZE
	card.size_flags_vertical = Control.SIZE_SHRINK_END

	# Sombra de contacto profunda en la roca (permanece sobre la piedra cuando el tomo se eleva)
	var ground_shadow = Panel.new()
	ground_shadow.name = "GroundShadow"
	ground_shadow.set_anchor(SIDE_LEFT, 0.0)
	ground_shadow.set_anchor(SIDE_RIGHT, 1.0)
	ground_shadow.set_anchor(SIDE_TOP, 1.0)
	ground_shadow.set_anchor(SIDE_BOTTOM, 1.0)
	ground_shadow.offset_left = 6
	ground_shadow.offset_right = -6
	ground_shadow.offset_top = -18
	ground_shadow.offset_bottom = 14
	ground_shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shadow_flat = StyleBoxFlat.new()
	shadow_flat.bg_color = Color(0, 0, 0, 0.75)
	shadow_flat.set_corner_radius_all(12)
	shadow_flat.shadow_color = Color(0, 0, 0, 0.90)
	shadow_flat.shadow_size = 14
	ground_shadow.add_theme_stylebox_override("panel", shadow_flat)
	card.add_child(ground_shadow)

	# visual_box aloja el libro físico encuadernado y permite la elevación mágica independiente
	var visual_box = Control.new()
	visual_box.name = "VisualBox"
	visual_box.custom_minimum_size = CARD_SIZE
	visual_box.size = CARD_SIZE
	visual_box.pivot_offset = CARD_SIZE / 2.0
	visual_box.modulate = Color(1.10, 1.07, 1.02)
	card.add_child(visual_box)

	# 1. Base del Tomo: Encuadernación de Cuero Repujado con esquinas redondeadas
	var tome_base = PanelContainer.new()
	tome_base.name = "TomeLeatherBase"
	tome_base.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tome_base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tome_style = StyleBoxFlat.new()
	tome_style.bg_color = Color(0.20, 0.14, 0.08, 1.0)
	tome_style.border_width_left = 3
	tome_style.border_width_top = 3
	tome_style.border_width_right = 3
	tome_style.border_width_bottom = 3
	tome_style.border_color = Color(0.58, 0.40, 0.22, 0.95)
	tome_style.set_corner_radius_all(12)
	tome_style.shadow_color = Color(0, 0, 0, 0.55)
	tome_style.shadow_size = 6
	tome_base.add_theme_stylebox_override("panel", tome_style)
	visual_box.add_child(tome_base)

	# Textura de piel/cuero del tomo
	var leather_tex = TextureRect.new()
	leather_tex.name = "LeatherTexture"
	leather_tex.texture = TEX_LEATHER
	leather_tex.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	leather_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	leather_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	leather_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tome_base.add_child(leather_tex)

	# 2. Inlay / Grabado Interior (Ventana biselada que aloja la ilustración de la raza)
	var inlay_holder = Control.new()
	inlay_holder.name = "InlayHolder"
	inlay_holder.set_anchor(SIDE_LEFT, 0.0)
	inlay_holder.set_anchor(SIDE_RIGHT, 1.0)
	inlay_holder.set_anchor(SIDE_TOP, 0.0)
	inlay_holder.set_anchor(SIDE_BOTTOM, 1.0)
	inlay_holder.offset_left = 13
	inlay_holder.offset_right = -13
	inlay_holder.offset_top = 15
	inlay_holder.offset_bottom = -15
	inlay_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	visual_box.add_child(inlay_holder)

	var inlay_frame = PanelContainer.new()
	inlay_frame.name = "InlayFrame"
	inlay_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	inlay_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var inlay_style = StyleBoxFlat.new()
	inlay_style.bg_color = Color(0.16, 0.11, 0.07, 0.9)
	inlay_style.border_width_left = 2
	inlay_style.border_width_top = 2
	inlay_style.border_width_right = 2
	inlay_style.border_width_bottom = 2
	inlay_style.border_color = Color(0.32, 0.22, 0.12, 0.95)
	inlay_style.set_corner_radius_all(7)
	inlay_style.shadow_color = Color(0, 0, 0, 0.6)
	inlay_style.shadow_size = 4
	inlay_frame.add_theme_stylebox_override("panel", inlay_style)
	inlay_holder.add_child(inlay_frame)

	var raw_nombre = str(mazo.get("nombre", mazo.get("name", "Mazo")))
	var nombre_clean = _sanitize_utf8(raw_nombre)
	var race_name := _extract_race_or_archetype(mazo)
	var card_texture: Texture2D = _get_card_texture(race_name, nombre_clean, idx)

	var tex_rect = TextureRect.new()
	tex_rect.name = "DeckCoverInlay"
	tex_rect.texture = card_texture
	tex_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inlay_frame.add_child(tex_rect)

	# 2026-09-22, a pedido del usuario ("que los mazos muestren la imagen
	# como de portada"): para mazos de ShadowForge con "image_url" real
	# (privados y públicos, ver arquitectura.md §13), se reemplaza la
	# ilustración genérica de raza por la portada real del mazo en cuanto
	# termina de bajar — mismo mecanismo ya usado en DeckManager.gd
	# (_load_cover_image), sin duplicar: la genérica queda de placeholder
	# mientras carga, no hay hueco en blanco.
	var cover_url := str(mazo.get("image_url", ""))
	if not cover_url.is_empty():
		_load_deck_cover_image(tex_rect, cover_url)

	# 3. Remaches / Tachas Metálicas en las 4 esquinas del tomo
	var studs = StudsDrawer.new()
	studs.name = "CornerStuds"
	studs.card_size = CARD_SIZE
	studs.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visual_box.add_child(studs)

	# 4. Marco de Selección Dorado Cálido
	var glow_panel = PanelContainer.new()
	glow_panel.name = "SelectionGlow"
	glow_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glow_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var glow_style = StyleBoxFlat.new()
	glow_style.bg_color = Color(0, 0, 0, 0)
	glow_style.border_color = Color(0, 0, 0, 0)
	glow_style.set_border_width_all(0)
	glow_style.set_corner_radius_all(12)
	glow_style.shadow_color = Color(0, 0, 0, 0)
	glow_style.shadow_size = 0
	glow_panel.add_theme_stylebox_override("panel", glow_style)
	visual_box.add_child(glow_panel)

	# 5. Botón invisible de interacción táctil
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
			var tw = visual_box.create_tween()
			tw.set_parallel(true)
			tw.tween_property(visual_box, "modulate", Color(1.26, 1.22, 1.15), 0.12).set_ease(Tween.EASE_OUT)
			tw.tween_property(visual_box, "scale", Vector2(1.012, 1.012), 0.12).set_ease(Tween.EASE_OUT)
			tw.tween_property(visual_box, "position:y", -2.5, 0.12).set_ease(Tween.EASE_OUT)
	)
	button.mouse_exited.connect(func():
		if _selected_player_idx != idx:
			var tw = visual_box.create_tween()
			tw.set_parallel(true)
			tw.tween_property(visual_box, "modulate", Color(1.10, 1.07, 1.02), 0.12).set_ease(Tween.EASE_OUT)
			tw.tween_property(visual_box, "scale", Vector2(1.0, 1.0), 0.12).set_ease(Tween.EASE_OUT)
			tw.tween_property(visual_box, "position:y", 0.0, 0.12).set_ease(Tween.EASE_OUT)
	)

	return card


const MAX_CONCURRENT_COVER_DOWNLOADS := 3
var _cover_image_queue: Array = []  # Array de {"tex_rect": TextureRect, "url": String}
var _cover_images_in_flight: int = 0
var _cover_image_active_requests: Array = []  # HTTPRequest en vuelo, para poder cancelarlos


func _load_deck_cover_image(tex_rect: TextureRect, url: String) -> void:
	"""Baja la portada real de un mazo de ShadowForge y reemplaza la
	ilustración genérica de raza en cuanto termina. 2026-09-23, bug real
	reportado por el usuario ("no se pudo cargar este mazo (revisa tu
	conexión)" al confirmar): con el carrusel mostrando hasta ~20 mazos
	públicos de golpe, esto disparaba hasta 20 HTTPRequest simultáneos hacia
	Cloudinary — sospecha fuerte (no confirmada con certeza, pero es la
	única diferencia real entre las pruebas sintéticas, que SIEMPRE
	funcionaron, y la partida real, que SIEMPRE se cuelga 20s exactos) de
	que eso satura algún límite de conexiones concurrentes y deja sin
	respuesta al pedido de /decks/my/{id}/ que se dispara después, al
	confirmar un mazo. Se pone en cola con un tope de
	MAX_CONCURRENT_COVER_DOWNLOADS en vez de lanzar todas de una — las
	portadas fuera de pantalla de todos modos no se ven todavía."""
	_cover_image_queue.append({"tex_rect": tex_rect, "url": url})
	_process_cover_image_queue()


func _process_cover_image_queue() -> void:
	while _cover_images_in_flight < MAX_CONCURRENT_COVER_DOWNLOADS and not _cover_image_queue.is_empty():
		var item: Dictionary = _cover_image_queue.pop_front()
		var tex_rect: TextureRect = item.get("tex_rect")
		var url: String = item.get("url", "")
		if not is_instance_valid(tex_rect):
			continue  # el carrusel se repobló antes de que le tocara el turno
		_cover_images_in_flight += 1
		var http := HTTPRequest.new()
		add_child(http)
		_cover_image_active_requests.append(http)
		http.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
			_cover_image_active_requests.erase(http)
			http.queue_free()
			_cover_images_in_flight -= 1
			_process_cover_image_queue()
			if not is_instance_valid(tex_rect):
				return
			if result != HTTPRequest.RESULT_SUCCESS or code != 200:
				return
			var image := Image.new()
			var err := image.load_webp_from_buffer(body)
			if err != OK:
				err = image.load_png_from_buffer(body)
			if err != OK:
				err = image.load_jpg_from_buffer(body)
			if err != OK:
				return
			tex_rect.texture = ImageTexture.create_from_image(image)
		)
		var request_err := http.request(url)
		if request_err != OK:
			_cover_image_active_requests.erase(http)
			http.queue_free()
			_cover_images_in_flight -= 1
			_process_cover_image_queue()


func _cancel_all_cover_image_downloads() -> void:
	"""Cancela de verdad los HTTPRequest de portadas que ya estén en vuelo
	(no solo los que siguen en cola) — 2026-09-23, se llama al confirmar un
	mazo para liberar cualquier capacidad de red antes del pedido crítico
	de /decks/my/{id}/. cancel_request() deja el nodo reusable, pero como no
	se va a reusar, se libera directo."""
	_cover_image_queue.clear()
	for http in _cover_image_active_requests.duplicate():
		if is_instance_valid(http):
			http.cancel_request()
			http.queue_free()
	_cover_image_active_requests.clear()
	_cover_images_in_flight = 0


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
	s = s.replace("Ã±", "ñ").replace("Ã", "Á").replace("Ã‰", "É").replace("Ã", "Í").replace("Ã“", "Ó").replace("Ãš", "Ú").replace("Ã‘", "Ñ")
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
	var target_scroll = max(0, _scroll_container.scroll_horizontal - int(CARD_SIZE.x + 20))
	var tw = create_tween()
	tw.tween_property(_scroll_container, "scroll_horizontal", target_scroll, 0.22).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)


func _scroll_right() -> void:
	if not _scroll_container: return
	var target_scroll = _scroll_container.scroll_horizontal + int(CARD_SIZE.x + 20)
	var tw = create_tween()
	tw.tween_property(_scroll_container, "scroll_horizontal", target_scroll, 0.22).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)


func _unhandled_input(event: InputEvent) -> void:
	if not _overlay or not is_instance_valid(_overlay): return
	if not event.is_pressed() or event.is_echo(): return

	if event.is_action_pressed("ui_left") or (event is InputEventKey and event.keycode == KEY_LEFT):
		_navigate_deck(-1)
	elif event.is_action_pressed("ui_right") or (event is InputEventKey and event.keycode == KEY_RIGHT):
		_navigate_deck(1)
	elif event.is_action_pressed("ui_accept") or (event is InputEventKey and (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER or event.keycode == KEY_SPACE)):
		if _btn_random_clicker and is_instance_valid(_btn_random_clicker) and _btn_random_clicker.is_hovered():
			_on_random_pressed()
			return
		if _selected_player_idx < 0 and _mazos.size() > 0:
			_selected_player_idx = 0
		_on_confirm_pressed()
	elif event.is_action_pressed("ui_cancel") or (event is InputEventKey and event.keycode == KEY_ESCAPE):
		# 2026-09-30, a pedido del usuario: antes no había forma de salir de
		# esta pantalla sin elegir un mazo. Si el popup de búsqueda de mazos
		# públicos está abierto, Escape lo cierra a ÉL primero (un nivel por
		# vez) — recién si no hay nada más abierto cancela la selección
		# completa y vuelve al menú principal.
		if _public_browser_overlay and is_instance_valid(_public_browser_overlay):
			_public_browser_overlay.queue_free()
			_public_browser_overlay = null
			_disconnect_public_browser_signals()
			return
		if _confirming:
			return  # ya se está confirmando/cargando — no cancelar a mitad de camino
		_close()
		emit_signal("selection_cancelled")


func _navigate_deck(direction: int) -> void:
	if _mazos.is_empty(): return
	var next_idx = _selected_player_idx + direction
	if _selected_player_idx < 0:
		next_idx = 0
	next_idx = clamp(next_idx, 0, _mazos.size() - 1)
	if next_idx != _selected_player_idx:
		_on_card_pressed(next_idx)


func _on_card_pressed(idx: int) -> void:
	_selected_player_idx = idx
	_refresh_selection(_player_cards, idx)
	_update_confirm_button()

	# Centrar suavemente el grimorio seleccionado en el viewport del altar
	if _scroll_container and idx >= 0 and idx < _player_cards.size():
		var card_node = _player_cards[idx]
		var card_center_x = card_node.position.x + 40.0 + card_node.size.x / 2.0
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
			# Tomo seleccionado: iluminación cálida integrada al altar y sutil aura dorada
			glow_style.border_color = Color(0.85, 0.72, 0.35, 0.60)
			glow_style.set_border_width_all(2)
			glow_style.shadow_color = Color(0.92, 0.78, 0.38, 0.40)
			glow_style.shadow_size = 10
			card.z_index = 10
			tw.tween_property(visual_box, "modulate", Color(1.45, 1.36, 1.22), 0.16).set_ease(Tween.EASE_OUT)
			tw.tween_property(visual_box, "scale", Vector2(1.025, 1.025), 0.16).set_ease(Tween.EASE_OUT)
			tw.tween_property(visual_box, "position:y", -6.0, 0.16).set_ease(Tween.EASE_OUT)
		else:
			# Tomo en reposo sobre la roca del altar
			glow_style.border_color = Color(0, 0, 0, 0)
			glow_style.set_border_width_all(0)
			glow_style.shadow_color = Color(0, 0, 0, 0)
			glow_style.shadow_size = 0
			card.z_index = 0
			tw.tween_property(visual_box, "modulate", Color(1.10, 1.07, 1.02), 0.16).set_ease(Tween.EASE_OUT)
			tw.tween_property(visual_box, "scale", Vector2(1.0, 1.0), 0.16).set_ease(Tween.EASE_OUT)
			tw.tween_property(visual_box, "position:y", 0.0, 0.16).set_ease(Tween.EASE_OUT)

	# Actualizar el cartel central de mazo seleccionado
	if selected_idx >= 0 and selected_idx < _mazos.size():
		var mazo: Dictionary = _mazos[selected_idx]
		var nombre_clean = _sanitize_utf8(str(mazo.get("nombre", mazo.get("name", "Mazo"))))
		var is_preset: bool = str(mazo.get("slug", "")).begins_with("preset-")
		var formato = _sanitize_utf8(str(mazo.get("formato", mazo.get("format", "Crónicas")))).capitalize()
		var cant_cartas: int = mazo.get("cartas", mazo.get("cards", [])).size()

		if _deck_banner:
			_deck_banner.text = nombre_clean
		if _deck_sub_banner:
			if cant_cartas > 0:
				_deck_sub_banner.text = "Formato: %s  •  %d cartas" % [formato, cant_cartas]
			else:
				_deck_sub_banner.text = "Formato: %s" % formato


func _on_confirm_pressed() -> void:
	if _mazos.is_empty() or _selected_player_idx < 0 or _selected_player_idx >= _mazos.size():
		return
	# Guarda de re-entrada (ver comentario en la declaración de _confirming
	# más arriba) — sin esto, clickear varias veces mientras ya está
	# cargando mandaba pedidos duplicados al mismo mazo, saturando la API.
	if _confirming:
		return
	_confirming = true
	if _btn_confirm_clicker:
		_btn_confirm_clicker.disabled = true

	# 2026-09-23: cortar (de verdad, no solo la cola) las descargas de
	# portada pendientes al confirmar — lo que no bajó todavía ya no hace
	# falta (se sale de esta pantalla), y libera de inmediato cualquier
	# capacidad de red para el pedido importante que sigue (bajar las
	# cartas reales del mazo elegido).
	_cancel_all_cover_image_downloads()

	# Destello esmeralda de confirmación
	if _confirm_flash and is_instance_valid(_confirm_flash):
		var tw = _confirm_flash.create_tween()
		tw.tween_property(_confirm_flash, "color:a", 0.65, 0.08)
		tw.tween_property(_confirm_flash, "color:a", 0.0, 0.14)
		await tw.finished

	var player_deck: Dictionary = _mazos[_selected_player_idx]
	var opponent_deck: Dictionary = _mazos[randi() % _mazos.size()] if not _mazos.is_empty() else {}

	# 2026-09-22, a pedido del usuario (fusión de mazos privados/públicos en
	# el carrusel principal, ver _fetch_and_merge_public_decks() arriba): los
	# mazos de ShadowForge que vienen de la lista resumida (privados o
	# públicos) no traen "entries" todavía — se resuelve solo aquí, cuando
	# de verdad se confirma uno, para no bajar las cartas de mazos que el
	# jugador ni siquiera eligió.
	if _needs_entries_fetch(player_deck):
		if _deck_sub_banner:
			_deck_sub_banner.text = "Cargando cartas del mazo..."
		var resolved_player := await _resolve_deck_entries(player_deck)
		if resolved_player.is_empty():
			if _deck_sub_banner:
				_deck_sub_banner.text = "No se pudo cargar este mazo (revisa tu conexión) — inténtalo de nuevo"
			else:
				push_warning("[DeckSelector] No se pudo cargar '%s' — sin conexión con ShadowForge" % str(player_deck.get("nombre", "")))
			_confirming = false
			if _btn_confirm_clicker:
				_btn_confirm_clicker.disabled = false
			return
		player_deck = resolved_player
		_mazos[_selected_player_idx] = resolved_player

	if _needs_entries_fetch(opponent_deck):
		var resolved_opponent := await _resolve_deck_entries(opponent_deck)
		if resolved_opponent.is_empty():
			# El mazo aleatorio del oponente no cargó — en vez de arrancar la
			# partida con un mazo vacío en silencio, se usa el primer mazo
			# que YA tenga entries (preset/local) como respaldo.
			opponent_deck = {}
			for m: Dictionary in _mazos:
				if not _needs_entries_fetch(m):
					opponent_deck = m
					break
		else:
			opponent_deck = resolved_opponent

	if opponent_deck.is_empty():
		# Ninguna de las dos resoluciones anteriores dejó un mazo rival con
		# entries (ni el aleatorio ni el respaldo) — abortar en vez de
		# arrancar la partida con decks_selected emitiendo un mazo vacío en
		# silencio (reintroducía el bug de "mazo vacío" ya arreglado para
		# _on_random_pressed()).
		if _deck_sub_banner:
			_deck_sub_banner.text = "No se pudo cargar un mazo rival (revisa tu conexión) — inténtalo de nuevo"
		else:
			push_warning("[DeckSelector] No se pudo resolver ningún mazo rival con entries — abortando confirmación")
		_confirming = false
		if _btn_confirm_clicker:
			_btn_confirm_clicker.disabled = false
		return

	_close()
	emit_signal("decks_selected", player_deck, opponent_deck,
		player_deck.get("_is_external", false), opponent_deck.get("_is_external", false))


func _needs_entries_fetch(mazo: Dictionary) -> bool:
	"""Un mazo de ShadowForge (privado o público) recién agregado a _mazos
	desde la lista resumida (_on_external_decks_received()/
	_on_initial_public_decks_received()) todavía no tiene 'entries' reales —
	los mazos preset/locales y los públicos elegidos desde el popup de
	búsqueda (_import_public_deck()) SÍ las traen desde que se agregan, así
	que no necesitan este fetch extra."""
	if not mazo.get("_is_external", false):
		return false
	var entries = mazo.get("entries", [])
	return not (entries is Array and not entries.is_empty())


func _resolve_deck_entries(mazo: Dictionary) -> Dictionary:
	"""Baja las 'entries' reales de un mazo de ShadowForge (privado o
	público) que todavía no las tiene — ver _needs_entries_fetch(). Devuelve
	el Dictionary completo con 'entries' pobladas, o {} si falló (HTTP,
	desconexión, o ninguna señal llegó dentro del timeout de salvaguarda).

	2026-09-23, CAUSA RAÍZ REAL encontrada tras reproducir el cuelgue en
	este mismo equipo (headless y con ventana, ver arquitectura.md §13.17):
	la petición HTTP SIEMPRE se completaba casi al instante — el problema
	nunca fue de red ni de backend. Los lambdas de GDScript capturan las
	variables locales POR VALOR, no por referencia: "done = true" dentro
	de on_ok/on_fail modificaba una copia propia del lambda, nunca la
	variable "done" de esta función, así que el bucle de espera de abajo
	jamás se enteraba de que la señal ya había llegado y agotaba siempre
	los 60s completos. Arreglado guardando el estado en un Dictionary
	("_state"): un Dictionary SÍ se captura por referencia (la copia por
	valor es una copia del puntero al mismo Dictionary), así que mutar sus
	claves adentro del lambda es visible afuera."""
	var deck_id := int(mazo.get("id", -1))
	if Constants.VERBOSE_DIAG_LOGS:
		print("[DeckSelector] _resolve_deck_entries: nombre='%s' id=%d kind='%s'" % [
			str(mazo.get("nombre", mazo.get("name", "?"))), deck_id, str(mazo.get("_shadowforge_kind", "?"))
		])
	if deck_id < 0:
		return {}
	var api_client = _get_autoload("ExternalApiClient")
	if not api_client:
		return {}
	var kind := str(mazo.get("_shadowforge_kind", "public"))

	var _state := {"done": false, "result": {}}
	var on_ok := func(deck_data: Dictionary):
		var r: Dictionary = mazo.duplicate(true)
		r["entries"] = deck_data.get("entries", [])
		_state["result"] = r
		_state["done"] = true
	var on_fail := func(_reason: String):
		_state["done"] = true

	if kind == "my":
		api_client.my_deck_detail_received.connect(on_ok, CONNECT_ONE_SHOT)
		api_client.my_deck_detail_failed.connect(on_fail, CONNECT_ONE_SHOT)
		api_client.fetch_my_deck_entries(deck_id)
	else:
		api_client.public_deck_detail_received.connect(on_ok, CONNECT_ONE_SHOT)
		api_client.public_deck_detail_failed.connect(on_fail, CONNECT_ONE_SHOT)
		api_client.fetch_public_deck_entries(deck_id)

	# Salvaguarda: si por algún motivo ninguna señal llega, no colgar la
	# pantalla para siempre. 60s calza con el timeout real de HTTPRequest en
	# ExternalApiClient.
	var waited := 0.0
	while not _state["done"] and waited < 60.0:
		await get_tree().process_frame
		waited += get_process_delta_time()

	if Constants.VERBOSE_DIAG_LOGS:
		print("[DeckSelector] _resolve_deck_entries: done=%s waited=%.1fs" % [str(_state["done"]), waited])

	if not _state["done"]:
		if api_client.my_deck_detail_received.is_connected(on_ok):
			api_client.my_deck_detail_received.disconnect(on_ok)
		if api_client.my_deck_detail_failed.is_connected(on_fail):
			api_client.my_deck_detail_failed.disconnect(on_fail)
		if api_client.public_deck_detail_received.is_connected(on_ok):
			api_client.public_deck_detail_received.disconnect(on_ok)
		if api_client.public_deck_detail_failed.is_connected(on_fail):
			api_client.public_deck_detail_failed.disconnect(on_fail)
		return {}

	return _state["result"]


func _on_random_pressed() -> void:
	# 2026-09-20, bug real reportado por el usuario: en una sala online,
	# "Mazos aleatorios" emitía {}/{} incondicionalmente — GameBootstrap.
	# _on_decks_selected() trata datos vacíos como "usar el flujo de prueba
	# local" y se salta ENTERO el intercambio de mazos por red (nunca llega a
	# preguntar NetworkClient.room_code), así que la partida arrancaba sola
	# sin esperar al otro jugador. En sala online no tiene sentido "aleatorio
	# para los dos lados" de todos modos — el mazo del jugador remoto tiene
	# que ser el suyo real, elegido por él, no uno inventado aquí. Se
	# interpreta como "elige un mazo al azar para mi lado" y se resuelve
	# igual que un click de Confirmar, así pasa por el mismo camino de
	# intercambio por red.
	if NetworkClient.room_code != "" and not _mazos.is_empty():
		_selected_player_idx = randi() % _mazos.size()
		_on_confirm_pressed()
		return
	_close()
	emit_signal("decks_selected", {}, {}, false, false)


func _close() -> void:
	if _canvas_layer and is_instance_valid(_canvas_layer):
		_canvas_layer.queue_free()
		_canvas_layer = null
	elif _overlay and is_instance_valid(_overlay):
		_overlay.queue_free()
		_overlay = null


# =============================================================================
# MAZOS PÚBLICOS DE SHADOWFORGE (2026-09-22, a pedido del usuario)
# =============================================================================
# Popup simple (no un browser gráfico elaborado — alcanza con lista +
# búsqueda + paginación) sobre el altar existente. Al elegir un mazo, se
# arma un Dictionary con la MISMA forma que ya consume _populate_options()/
# _build_deck_card() (nombre, arquetipo/raza, formato, entries, _is_external)
# y se agrega a _mazos — reusa 100% el carrusel, la selección y
# _on_confirm_pressed() ya existentes, no duplica ningún camino de carga.
var _public_browser_overlay: Control = null
var _public_search_edit: LineEdit = null
var _public_results_box: VBoxContainer = null
var _public_status_label: Label = null
var _public_page_label: Label = null
var _public_page: int = 1
var _public_total: int = 0
var _public_signals_connected: bool = false


func _open_public_deck_browser() -> void:
	if _public_browser_overlay and is_instance_valid(_public_browser_overlay):
		_public_browser_overlay.queue_free()

	if not _public_signals_connected:
		_public_signals_connected = true
		ExternalApiClient.public_decks_received.connect(_on_public_decks_received)
		ExternalApiClient.public_decks_failed.connect(_on_public_decks_failed)
		ExternalApiClient.public_deck_detail_received.connect(_on_public_deck_detail_received)
		ExternalApiClient.public_deck_detail_failed.connect(_on_public_deck_detail_failed)


func _disconnect_public_browser_signals() -> void:
	# El popup de búsqueda deja estas conexiones permanentes mientras está
	# abierto; si quedan conectadas después de cerrarlo, colisionan con los
	# listeners CONNECT_ONE_SHOT que usan _fetch_and_merge_public_decks() y
	# _resolve_deck_entries() sobre las MISMAS señales (ver hallazgo de
	# revisión: ambos handlers podían dispararse con una sola respuesta).
	if not _public_signals_connected:
		return
	_public_signals_connected = false
	if ExternalApiClient.public_decks_received.is_connected(_on_public_decks_received):
		ExternalApiClient.public_decks_received.disconnect(_on_public_decks_received)
	if ExternalApiClient.public_decks_failed.is_connected(_on_public_decks_failed):
		ExternalApiClient.public_decks_failed.disconnect(_on_public_decks_failed)
	if ExternalApiClient.public_deck_detail_received.is_connected(_on_public_deck_detail_received):
		ExternalApiClient.public_deck_detail_received.disconnect(_on_public_deck_detail_received)
	if ExternalApiClient.public_deck_detail_failed.is_connected(_on_public_deck_detail_failed):
		ExternalApiClient.public_deck_detail_failed.disconnect(_on_public_deck_detail_failed)

	_public_browser_overlay = Control.new()
	_public_browser_overlay.name = "PublicDeckBrowser"
	_public_browser_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_public_browser_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.add_child(_public_browser_overlay)

	var dim = ColorRect.new()
	dim.color = Color(0, 0, 0, 0.72)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_public_browser_overlay.add_child(dim)

	var panel = PanelContainer.new()
	panel.set_anchor(SIDE_LEFT, 0.5)
	panel.set_anchor(SIDE_RIGHT, 0.5)
	panel.set_anchor(SIDE_TOP, 0.5)
	panel.set_anchor(SIDE_BOTTOM, 0.5)
	panel.set_offset(SIDE_LEFT, -320)
	panel.set_offset(SIDE_RIGHT, 320)
	panel.set_offset(SIDE_TOP, -260)
	panel.set_offset(SIDE_BOTTOM, 260)
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.08, 0.07, 0.10, 0.97)
	panel_style.border_width_left = 2
	panel_style.border_width_top = 2
	panel_style.border_width_right = 2
	panel_style.border_width_bottom = 2
	panel_style.border_color = GOLD
	panel_style.set_corner_radius_all(10)
	panel_style.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", panel_style)
	_public_browser_overlay.add_child(panel)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var title = Label.new()
	title.text = "Mazos públicos de ShadowForge"
	title.add_theme_font_override("font", FONT_TITLE)
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", GOLD)
	vbox.add_child(title)

	var search_row = HBoxContainer.new()
	search_row.add_theme_constant_override("separation", 8)
	vbox.add_child(search_row)

	_public_search_edit = LineEdit.new()
	_public_search_edit.placeholder_text = "Buscar por nombre..."
	_public_search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_public_search_edit.text_submitted.connect(func(_t): _search_public_decks(1))
	search_row.add_child(_public_search_edit)

	var search_btn = Button.new()
	search_btn.text = "Buscar"
	search_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	search_btn.pressed.connect(func(): _search_public_decks(1))
	search_row.add_child(search_btn)

	_public_status_label = Label.new()
	_public_status_label.text = "Buscando mazos públicos..."
	_public_status_label.add_theme_color_override("font_color", RUNIC_CYAN)
	_public_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(_public_status_label)

	var scroll = ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 300)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	_public_results_box = VBoxContainer.new()
	_public_results_box.add_theme_constant_override("separation", 4)
	_public_results_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_public_results_box)

	var page_row = HBoxContainer.new()
	page_row.alignment = BoxContainer.ALIGNMENT_CENTER
	page_row.add_theme_constant_override("separation", 14)
	vbox.add_child(page_row)

	var prev_btn = Button.new()
	prev_btn.text = "◄ Anterior"
	prev_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	prev_btn.pressed.connect(func():
		if _public_page > 1:
			_search_public_decks(_public_page - 1)
	)
	page_row.add_child(prev_btn)

	_public_page_label = Label.new()
	_public_page_label.text = "Página 1"
	page_row.add_child(_public_page_label)

	var next_btn = Button.new()
	next_btn.text = "Siguiente ►"
	next_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	next_btn.pressed.connect(func(): _search_public_decks(_public_page + 1))
	page_row.add_child(next_btn)

	var close_btn = Button.new()
	close_btn.text = "Cerrar"
	close_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	close_btn.pressed.connect(func():
		if _public_browser_overlay and is_instance_valid(_public_browser_overlay):
			_public_browser_overlay.queue_free()
			_public_browser_overlay = null
		_disconnect_public_browser_signals()
	)
	vbox.add_child(close_btn)

	_search_public_decks(1)


func _search_public_decks(page: int) -> void:
	_public_page = page
	if _public_status_label:
		_public_status_label.text = "Buscando..."
	if _public_results_box:
		for child in _public_results_box.get_children():
			child.queue_free()
	var search := _public_search_edit.text.strip_edges() if _public_search_edit else ""
	ExternalApiClient.fetch_public_decks(search, page)


func _on_public_decks_received(results: Array, count: int) -> void:
	if not _public_browser_overlay or not is_instance_valid(_public_browser_overlay):
		return  # el popup se cerró mientras la petición estaba en vuelo
	_public_total = count
	if _public_page_label:
		var total_pages: int = max(1, ceili(float(count) / 20.0))
		_public_page_label.text = "Página %d de %d" % [_public_page, total_pages]
	if _public_status_label:
		_public_status_label.text = "%d mazos públicos encontrados." % count if count > 0 else "Sin resultados."
	if not _public_results_box:
		return
	for child in _public_results_box.get_children():
		child.queue_free()
	for deck in results:
		if not deck is Dictionary:
			continue
		_public_results_box.add_child(_build_public_deck_row(deck))


func _build_public_deck_row(deck: Dictionary) -> Control:
	var row_btn = Button.new()
	row_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var nombre := str(deck.get("name", "Mazo sin nombre"))
	var raza := str(deck.get("race", ""))
	var owner := str(deck.get("owner_username", "?"))
	var card_count := int(deck.get("card_count", 0))
	row_btn.text = "%s — %s — por %s (%d cartas)" % [nombre, raza.capitalize(), owner, card_count]
	row_btn.pressed.connect(func(): _import_public_deck(deck))
	return row_btn


func _on_public_decks_failed(reason: String) -> void:
	if _public_status_label and is_instance_valid(_public_status_label):
		_public_status_label.text = "No se pudieron buscar mazos públicos: %s" % reason


func _import_public_deck(deck: Dictionary) -> void:
	var deck_id := int(deck.get("id", -1))
	if deck_id < 0:
		return
	if _public_status_label and is_instance_valid(_public_status_label):
		_public_status_label.text = "Cargando '%s'..." % str(deck.get("name", ""))
	ExternalApiClient.fetch_public_deck_entries(deck_id)


func _on_public_deck_detail_received(deck_data: Dictionary) -> void:
	# deck_data ya trae "entries" (ver ExternalApiClient.fetch_public_deck_
	# entries()) — misma forma exacta que DeckLoader._process_external_deck_
	# data()/_process_deck_data() ya saben leer, así que solo hace falta
	# completar los campos que _build_deck_card()/_populate_options() leen
	# para mostrarlo en el carrusel (nombre, raza, formato).
	var mazo := {
		"slug": "public-%d" % int(deck_data.get("id", 0)),
		"nombre": str(deck_data.get("name", "Mazo público")),
		"arquetipo": str(deck_data.get("race", "")),
		"raza": str(deck_data.get("race", "")),
		"formato": str(deck_data.get("format", "")),
		"entries": deck_data.get("entries", []),
		"id": int(deck_data.get("id", 0)),
		"image_url": str(deck_data.get("image_url", "")),
		"_is_external": true,
		"_shadowforge_kind": "public",
	}
	_mazos.append(mazo)
	if _public_browser_overlay and is_instance_valid(_public_browser_overlay):
		_public_browser_overlay.queue_free()
		_public_browser_overlay = null
	_disconnect_public_browser_signals()
	_populate_options()
	_selected_player_idx = _mazos.size() - 1
	_refresh_selection(_player_cards, _selected_player_idx)
	_update_confirm_button()


func _on_public_deck_detail_failed(reason: String) -> void:
	if _public_status_label and is_instance_valid(_public_status_label):
		_public_status_label.text = "No se pudo cargar ese mazo: %s" % reason
