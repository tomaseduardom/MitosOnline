extends Control
class_name CompactZone
## Zona compacta para Mazo, Cementerio o Destierro

signal zone_clicked()

@export var zone_name: String = "Zona"
@export var zone_color: Color = Color(0.15, 0.15, 0.2, 0.9)
@export var border_color: Color = Color(0.3, 0.3, 0.4, 1.0)
@export var show_card_back: bool = true
@export var player_id: int = 0  ## ID del jugador dueño de esta zona

# Dorso dinámico desde get_node("/root/GameSettings")

var count: int = 0:
	set(value):
		count = value
		if count_label:
			count_label.text = str(count)
		if card_icon:
			card_icon.visible = count > 0

var panel: Panel
var card_icon: TextureRect
var count_label: Label
var name_label: Label

func _ready() -> void:
	custom_minimum_size = Vector2(70, 100)
	mouse_filter = Control.MOUSE_FILTER_STOP

	# Panel base
	panel = Panel.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style = StyleBoxFlat.new()
	style.bg_color = zone_color
	style.border_color = border_color
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	# Icono de carta (dorso con imagen)
	if show_card_back:
		card_icon = TextureRect.new()
		card_icon.custom_minimum_size = Vector2(40, 56)
		card_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		card_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		card_icon.texture = get_node("/root/GameSettings").get_card_back_texture(player_id)
		card_icon.set_anchors_preset(Control.PRESET_CENTER_TOP)
		card_icon.position = Vector2(-20, 8)
		card_icon.visible = count > 0
		add_child(card_icon)

	# Label de cantidad
	count_label = Label.new()
	count_label.text = str(count)
	count_label.set_anchors_preset(Control.PRESET_CENTER)
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count_label.add_theme_font_size_override("font_size", 18)
	count_label.add_theme_color_override("font_color", Color.WHITE)
	count_label.position = Vector2(-15, show_card_back if -5 else -10)
	add_child(count_label)

	# Label de nombre
	name_label = Label.new()
	name_label.text = zone_name
	name_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 9)
	name_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7, 1.0))
	name_label.position = Vector2(-30, -18)
	name_label.custom_minimum_size = Vector2(60, 14)
	add_child(name_label)

	# Conectar click
	gui_input.connect(_on_gui_input)

	# Escuchar cambios de dorso
	get_node("/root/GameSettings").card_back_changed.connect(_on_card_back_changed)


func _on_card_back_changed(_back_id: String) -> void:
	"""Actualiza el dorso cuando cambia en get_node("/root/GameSettings")"""
	if card_icon:
		card_icon.texture = get_node("/root/GameSettings").get_card_back_texture(player_id)


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		zone_clicked.emit()
