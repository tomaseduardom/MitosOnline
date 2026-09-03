extends Control
## BackSelector - Pantalla para seleccionar el dorso de las cartas

# =============================================================================
# CONSTANTES
# =============================================================================
const BACKS_PATH = "res://assets/card_backs/"
const CONFIG_PATH = "user://settings.cfg"

# Lista de dorsos disponibles
const AVAILABLE_BACKS = [
	{"id": "dorso_1", "file": "dorso_1.png", "name": "Clásico"},
	{"id": "dorso_2", "file": "dorso_2.png", "name": "Místico"},
	{"id": "dorso_3", "file": "dorso_3.png", "name": "Legendario"},
]

# =============================================================================
# REFERENCIAS UI
# =============================================================================
@onready var back_button: Button = $TopBar/BackButton
@onready var title_label: Label = $TopBar/TitleLabel
@onready var backs_container: HBoxContainer = $CenterContainer/BacksContainer
@onready var preview_texture: TextureRect = $PreviewPanel/PreviewTexture

# =============================================================================
# VARIABLES
# =============================================================================
var current_selected_id: String = "dorso_1"
var preview_back_id: String = ""
var back_cards: Dictionary = {}  # id -> Control


func _ready() -> void:
	# Conectar botones
	back_button.pressed.connect(_on_back_pressed)

	# Cargar configuración guardada
	_load_config()

	# Crear las tarjetas de dorsos
	_create_back_cards()

	# Mostrar preview del dorso actual
	_show_preview(current_selected_id)


func _load_config() -> void:
	"""Carga la configuración guardada desde GameSettings"""
	current_selected_id = GameSettings.get_card_back_id(0)  # Player 0
	print("[BackSelector] Current back: ", current_selected_id)


func _save_config() -> void:
	"""Guarda la configuración via GameSettings"""
	# GameSettings se encarga de guardar
	print("[BackSelector] Config saved via GameSettings")


func _create_back_cards() -> void:
	"""Crea las tarjetas visuales para cada dorso"""
	for back_data in AVAILABLE_BACKS:
		var card = _create_back_card(back_data)
		backs_container.add_child(card)
		back_cards[back_data["id"]] = card

	# Marcar el seleccionado actualmente
	_update_selection_visuals()


func _create_back_card(back_data: Dictionary) -> Control:
	"""Crea una tarjeta visual para un dorso"""
	var card = Control.new()
	card.custom_minimum_size = Vector2(200, 340)

	# Panel con borde
	var panel = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.08, 0.15, 0.9)
	style.border_color = Color(0.5, 0.5, 0.5, 1.0)
	style.set_border_width_all(3)
	style.set_corner_radius_all(12)
	panel.add_theme_stylebox_override("panel", style)
	panel.set_meta("style", style)
	card.add_child(panel)

	# Contenedor vertical
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 12)
	card.add_child(vbox)

	# Margin
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 12)
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(margin)

	var inner_vbox = VBoxContainer.new()
	inner_vbox.add_theme_constant_override("separation", 12)
	margin.add_child(inner_vbox)

	# Imagen del dorso
	var texture_rect = TextureRect.new()
	texture_rect.custom_minimum_size = Vector2(168, 235)
	texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var texture = load(BACKS_PATH + back_data["file"])
	if texture:
		texture_rect.texture = texture
	inner_vbox.add_child(texture_rect)

	# Nombre del dorso
	var name_label = Label.new()
	name_label.text = back_data["name"]
	name_label.add_theme_font_size_override("font_size", 18)
	name_label.add_theme_color_override("font_color", Color(1, 0.95, 0.8, 1))
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	inner_vbox.add_child(name_label)

	# Botón invisible para click
	var button = Button.new()
	button.flat = true
	button.set_anchors_preset(Control.PRESET_FULL_RECT)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.pressed.connect(_on_back_card_clicked.bind(back_data["id"]))
	card.add_child(button)

	# Hover effects
	button.mouse_entered.connect(func():
		if back_data["id"] != current_selected_id:
			style.border_color = Color(0.8, 0.7, 0.4, 1.0)
	)
	button.mouse_exited.connect(func():
		if back_data["id"] != current_selected_id:
			style.border_color = Color(0.5, 0.5, 0.5, 1.0)
	)

	return card


func _on_back_card_clicked(back_id: String) -> void:
	"""Cuando se hace click en un dorso, lo selecciona directamente"""
	_select_back(back_id)


func _show_preview(back_id: String) -> void:
	"""Muestra el preview de un dorso"""
	preview_back_id = back_id

	# Encontrar datos del dorso
	for back_data in AVAILABLE_BACKS:
		if back_data["id"] == back_id:
			# Actualizar preview
			var texture = load(BACKS_PATH + back_data["file"])
			if texture:
				preview_texture.texture = texture
			break


func _select_back(back_id: String) -> void:
	"""Selecciona un dorso directamente"""
	if back_id == current_selected_id:
		print("[BackSelector] Ya está seleccionado: ", back_id)
		return

	print("[BackSelector] Cambiando de ", current_selected_id, " a ", back_id)
	current_selected_id = back_id
	_save_config()
	_update_selection_visuals()
	_show_preview(back_id)

	# Notificar al juego del cambio (player_id = 0 para jugador local)
	GameSettings.set_card_back(current_selected_id, 0)
	print("[BackSelector] GameSettings actualizado correctamente")

	print("[BackSelector] Selected: ", current_selected_id)


func _update_selection_visuals() -> void:
	"""Actualiza los bordes para mostrar cuál está seleccionado"""
	for back_id in back_cards:
		var card = back_cards[back_id]
		var panel = card.get_child(0) as PanelContainer
		var style = panel.get_meta("style") as StyleBoxFlat
		if back_id == current_selected_id:
			style.border_color = Color(0.83, 0.69, 0.22, 1.0)  # Gold
		else:
			style.border_color = Color(0.5, 0.5, 0.5, 1.0)


func _on_back_pressed() -> void:
	"""Volver al menú principal"""
	get_tree().change_scene_to_file("res://scenes/menu/MainMenu.tscn")
