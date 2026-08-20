extends CanvasLayer
## OpponentUI - Muestra información revelada al oponente
## Recibe señales de SelectionCanvas para mostrar cartas públicas

class_name OpponentUI

# =============================================================================
# SIGNALS
# =============================================================================
signal card_reveal_started(context: String)
signal card_reveal_ended
signal reveal_acknowledged  # Cuando el oponente hace click para continuar

# =============================================================================
# ESTADO
# =============================================================================
var revealed_cards: Array = []
var current_context: String = ""
var is_showing: bool = false
var auto_hide_timer: float = 0.0

# UI References
@onready var reveal_panel: Panel = $RevealPanel
@onready var title_label: Label = $RevealPanel/TitleLabel
@onready var cards_container: HBoxContainer = $RevealPanel/CardsContainer
@onready var info_label: Label = $RevealPanel/InfoLabel
@onready var acknowledge_button: Button = $RevealPanel/AcknowledgeButton


func _ready() -> void:
	# Añadir al grupo para que SelectionCanvas pueda encontrarlo
	add_to_group("opponent_ui")

	# Ocultar al inicio
	visible = false
	is_showing = false

	# Conectar botón
	if acknowledge_button:
		acknowledge_button.pressed.connect(_on_acknowledge_pressed)

	# Conectar a SelectionCanvas si existe
	_connect_to_selection_canvas()


func _connect_to_selection_canvas() -> void:
	"""Conecta a las señales de SelectionCanvas"""
	var selection = get_node_or_null("/root/SelectionCanvas")

	if selection:
		if selection.has_signal("cards_revealed_to_opponent"):
			selection.cards_revealed_to_opponent.connect(_on_cards_revealed)
		if selection.has_signal("card_shown_to_opponent"):
			selection.card_shown_to_opponent.connect(_on_card_shown)
		if selection.has_signal("reveal_ended"):
			selection.reveal_ended.connect(_on_reveal_ended)

		print("[OpponentUI] Conectado a SelectionCanvas")
	else:
		# Reintentar después
		call_deferred("_connect_to_selection_canvas")


# =============================================================================
# HANDLERS DE SEÑALES
# =============================================================================
func _on_cards_revealed(player_id: int, cards: Array, context: String) -> void:
	"""Handler cuando se revelan múltiples cartas"""
	revealed_cards = cards.duplicate()
	current_context = context

	_show_reveal_panel(context, cards.size())
	emit_signal("card_reveal_started", context)


func _on_card_shown(player_id: int, card: Node) -> void:
	"""Handler cuando se muestra una carta individual"""
	_add_card_to_display(card)


func _on_reveal_ended(player_id: int) -> void:
	"""Handler cuando termina la revelación"""
	# Iniciar timer de auto-hide o esperar acknowledge
	auto_hide_timer = 3.0


func _process(delta: float) -> void:
	"""Procesa auto-hide"""
	if is_showing and auto_hide_timer > 0:
		auto_hide_timer -= delta
		if auto_hide_timer <= 0:
			hide_revealed_cards()


# =============================================================================
# FUNCIONES DE UI
# =============================================================================
func _show_reveal_panel(context: String, card_count: int) -> void:
	"""Muestra el panel de revelación"""
	if not reveal_panel:
		_create_default_ui()

	visible = true
	is_showing = true

	# Configurar título según contexto
	var title = _get_title_for_context(context)
	if title_label:
		title_label.text = title

	# Configurar info
	if info_label:
		info_label.text = "El oponente revela %d carta(s)" % card_count

	# Limpiar contenedor
	if cards_container:
		for child in cards_container.get_children():
			child.queue_free()

	print("[OpponentUI] Mostrando panel de revelación: %s" % context)


func _get_title_for_context(context: String) -> String:
	"""Genera título según el contexto de revelación"""
	match context:
		"mostrar_efecto":
			return "¡Cartas Reveladas!"
		"buscar_resultado":
			return "Resultado de Búsqueda"
		"mano_revelada":
			return "Mano del Oponente"
		"tope_castillo":
			return "Tope del Castillo"
		"descarte":
			return "Cartas Descartadas"
		_:
			return "Cartas Reveladas"


func _add_card_to_display(card: Node) -> void:
	"""Añade una carta al display de revelación"""
	if not cards_container:
		return

	var card_display = _create_card_display(card)
	cards_container.add_child(card_display)

	# Animación de entrada
	card_display.modulate.a = 0
	var tween = create_tween()
	tween.tween_property(card_display, "modulate:a", 1.0, 0.3)


func _create_card_display(card: Node) -> Control:
	"""Crea visualización de carta para el oponente"""
	var display = Panel.new()
	display.custom_minimum_size = Vector2(100, 140)

	# Estilo
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.15, 0.2, 0.95)
	style.border_color = Color(0.8, 0.6, 0.2, 1)  # Borde dorado
	style.border_width_bottom = 2
	style.border_width_top = 2
	style.border_width_left = 2
	style.border_width_right = 2
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	display.add_theme_stylebox_override("panel", style)

	# Contenedor vertical
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 4)
	display.add_child(vbox)

	# Nombre
	var name_label = Label.new()
	name_label.text = card.card_name if card.get("card_name") else "Carta"
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 11)
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(name_label)

	# Imagen si existe
	if card.get("card_texture"):
		var tex_rect = TextureRect.new()
		tex_rect.texture = card.card_texture
		tex_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex_rect.custom_minimum_size = Vector2(80, 100)
		vbox.add_child(tex_rect)

	# Tipo
	if card.get("card_type") != null:
		var type_label = Label.new()
		type_label.text = Constants.CARD_TYPE_NAMES.get(card.card_type, "")
		type_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		type_label.add_theme_font_size_override("font_size", 9)
		type_label.modulate = Color(0.7, 0.7, 0.7, 1)
		vbox.add_child(type_label)

	return display


func show_revealed_card(card: Node, context: String, index: int, total: int) -> void:
	"""Función pública llamada por SelectionCanvas para mostrar carta"""
	if not is_showing:
		_show_reveal_panel(context, total)

	_add_card_to_display(card)

	# Actualizar progreso
	if info_label:
		info_label.text = "Revelando carta %d de %d" % [index + 1, total]


func hide_revealed_cards() -> void:
	"""Oculta el panel de revelación"""
	if not is_showing:
		return

	# Animación de salida (usando reveal_panel ya que CanvasLayer no tiene modulate)
	if reveal_panel:
		var tween = create_tween()
		tween.tween_property(reveal_panel, "modulate:a", 0.0, 0.3)
		tween.tween_callback(_finish_hide)
	else:
		_finish_hide()


func _finish_hide() -> void:
	"""Finaliza el ocultamiento"""
	visible = false
	is_showing = false
	if reveal_panel:
		reveal_panel.modulate.a = 1.0
	revealed_cards.clear()
	current_context = ""
	emit_signal("card_reveal_ended")


func show_opponent_hand(cards: Array) -> void:
	"""Muestra la mano del oponente (para efectos de revelar mano)"""
	_show_reveal_panel("mano_revelada", cards.size())

	for card in cards:
		_add_card_to_display(card)

	# No auto-hide para mano - requiere acknowledge
	auto_hide_timer = 0


func show_deck_reveal(cards: Array, keep_order: bool) -> void:
	"""Muestra cartas reveladas del tope del mazo"""
	_show_reveal_panel("tope_castillo", cards.size())

	if keep_order and info_label:
		info_label.text += " (en orden de arriba a abajo)"


func _on_acknowledge_pressed() -> void:
	"""Cuando el oponente hace click para continuar"""
	emit_signal("reveal_acknowledged")
	hide_revealed_cards()


# =============================================================================
# CREAR UI POR DEFECTO (si no existe en escena)
# =============================================================================
func _create_default_ui() -> void:
	"""Crea UI básica si no existe"""
	# Panel principal
	reveal_panel = Panel.new()
	reveal_panel.name = "RevealPanel"
	reveal_panel.set_anchors_preset(Control.PRESET_CENTER)
	reveal_panel.offset_left = -350
	reveal_panel.offset_top = -150
	reveal_panel.offset_right = 350
	reveal_panel.offset_bottom = 150
	add_child(reveal_panel)

	# Estilo del panel
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.1, 0.1, 0.15, 0.95)
	panel_style.border_color = Color(0.6, 0.4, 0.1, 1)
	panel_style.border_width_bottom = 3
	panel_style.border_width_top = 3
	panel_style.border_width_left = 3
	panel_style.border_width_right = 3
	panel_style.corner_radius_top_left = 10
	panel_style.corner_radius_top_right = 10
	panel_style.corner_radius_bottom_left = 10
	panel_style.corner_radius_bottom_right = 10
	reveal_panel.add_theme_stylebox_override("panel", panel_style)

	# Título
	title_label = Label.new()
	title_label.name = "TitleLabel"
	title_label.text = "Cartas Reveladas"
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.position = Vector2(20, 10)
	title_label.size = Vector2(660, 30)
	title_label.add_theme_font_size_override("font_size", 20)
	reveal_panel.add_child(title_label)

	# Contenedor de cartas
	cards_container = HBoxContainer.new()
	cards_container.name = "CardsContainer"
	cards_container.position = Vector2(20, 50)
	cards_container.size = Vector2(660, 160)
	cards_container.alignment = BoxContainer.ALIGNMENT_CENTER
	cards_container.add_theme_constant_override("separation", 10)
	reveal_panel.add_child(cards_container)

	# Info
	info_label = Label.new()
	info_label.name = "InfoLabel"
	info_label.text = ""
	info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info_label.position = Vector2(20, 220)
	info_label.size = Vector2(660, 25)
	info_label.add_theme_font_size_override("font_size", 12)
	reveal_panel.add_child(info_label)

	# Botón acknowledge
	acknowledge_button = Button.new()
	acknowledge_button.name = "AcknowledgeButton"
	acknowledge_button.text = "Continuar"
	acknowledge_button.position = Vector2(280, 255)
	acknowledge_button.size = Vector2(140, 35)
	acknowledge_button.pressed.connect(_on_acknowledge_pressed)
	reveal_panel.add_child(acknowledge_button)

	print("[OpponentUI] UI por defecto creada")
