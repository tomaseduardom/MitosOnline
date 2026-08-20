extends Control
## XValueSelector - UI para selección de valor X (DAR Sección 6.B)
##
## Permite al jugador elegir el valor de X para costes variables.
## Se integra con PaymentManager y ActionPipeline.

# =============================================================================
# SEÑALES
# =============================================================================
signal x_confirmed(x_value: int, total_cost: int)
signal x_cancelled()
signal x_changed(x_value: int)

# =============================================================================
# CONFIGURACIÓN
# =============================================================================
@export var min_value: int = 0
@export var default_value: int = 0
@export var animate_changes: bool = true

# =============================================================================
# ESTADO
# =============================================================================
var _x_value: int = 0
var _max_value: int = 0
var _base_cost: int = 0
var _x_multiplier: int = 1
var _formula: String = "X"
var _card_data: Dictionary = {}
var _player_id: int = -1

# =============================================================================
# REFERENCIAS UI (se asignan desde la escena)
# =============================================================================
@onready var card_name_label: Label = $Panel/MarginContainer/VBoxContainer/CardNameLabel
@onready var formula_label: Label = $Panel/MarginContainer/VBoxContainer/FormulaLabel
@onready var gold_label: Label = $Panel/MarginContainer/VBoxContainer/GoldLabel
@onready var x_value_label: Label = $Panel/MarginContainer/VBoxContainer/CounterContainer/XValueLabel
@onready var total_cost_label: Label = $Panel/MarginContainer/VBoxContainer/TotalCostLabel
@onready var minus_button: Button = $Panel/MarginContainer/VBoxContainer/CounterContainer/MinusButton
@onready var plus_button: Button = $Panel/MarginContainer/VBoxContainer/CounterContainer/PlusButton
@onready var x_slider: HSlider = $Panel/MarginContainer/VBoxContainer/XSlider
@onready var confirm_button: Button = $Panel/MarginContainer/VBoxContainer/ButtonContainer/ConfirmButton
@onready var cancel_button: Button = $Panel/MarginContainer/VBoxContainer/ButtonContainer/CancelButton
@onready var panel: PanelContainer = $Panel

# =============================================================================
# LIFECYCLE
# =============================================================================
func _ready() -> void:
	_connect_signals()
	_setup_initial_state()
	visible = false


func _connect_signals() -> void:
	if minus_button:
		minus_button.pressed.connect(_on_minus_pressed)
	if plus_button:
		plus_button.pressed.connect(_on_plus_pressed)
	if x_slider:
		x_slider.value_changed.connect(_on_slider_changed)
	if confirm_button:
		confirm_button.pressed.connect(_on_confirm_pressed)
	if cancel_button:
		cancel_button.pressed.connect(_on_cancel_pressed)


func _setup_initial_state() -> void:
	_x_value = default_value
	_update_display()


func _input(event: InputEvent) -> void:
	if not visible:
		return

	# Atajos de teclado
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ENTER, KEY_KP_ENTER:
				_on_confirm_pressed()
			KEY_ESCAPE:
				_on_cancel_pressed()
			KEY_UP, KEY_RIGHT:
				increment()
			KEY_DOWN, KEY_LEFT:
				decrement()


# =============================================================================
# API PÚBLICA
# =============================================================================
func show_selector(card_data: Dictionary, player_id: int, available_gold: int, x_info: Dictionary = {}) -> void:
	"""Muestra el selector con los datos de la carta

	Args:
		card_data: Datos de la carta con coste X
		player_id: ID del jugador
		available_gold: Oro disponible del jugador
		x_info: {base_cost, x_multiplier, formula} parseado
	"""
	_card_data = card_data
	_player_id = player_id

	# Parsear info de X
	_base_cost = x_info.get("base_cost", 0)
	_x_multiplier = x_info.get("x_multiplier", 1)
	_formula = x_info.get("formula", "X")

	# Calcular máximo X basado en oro disponible
	if _x_multiplier > 0:
		_max_value = (available_gold - _base_cost) / _x_multiplier
	else:
		_max_value = available_gold - _base_cost

	_max_value = maxi(0, _max_value)
	_x_value = mini(default_value, _max_value)

	# Configurar slider
	if x_slider:
		x_slider.min_value = min_value
		x_slider.max_value = _max_value
		x_slider.value = _x_value
		x_slider.visible = _max_value > 5  # Solo mostrar si hay rango amplio

	# Actualizar labels
	_update_card_info()
	_update_display()

	# Mostrar
	visible = true

	# Focus en el botón confirmar
	if confirm_button:
		confirm_button.grab_focus()

	print("[XValueSelector] Mostrado para '%s' | Máx X: %d | Oro: %d" % [
		card_data.get("nombre", "???"), _max_value, available_gold
	])


func hide_selector() -> void:
	"""Oculta el selector"""
	visible = false
	_card_data = {}


func get_x_value() -> int:
	"""Retorna el valor actual de X"""
	return _x_value


func get_total_cost() -> int:
	"""Retorna el coste total calculado"""
	return _base_cost + (_x_value * _x_multiplier)


func increment() -> void:
	"""Incrementa X en 1"""
	set_x_value(_x_value + 1)


func decrement() -> void:
	"""Decrementa X en 1"""
	set_x_value(_x_value - 1)


func set_x_value(value: int) -> void:
	"""Establece el valor de X con validación"""
	var old_value = _x_value
	_x_value = clampi(value, min_value, _max_value)

	if _x_value != old_value:
		_update_display()
		emit_signal("x_changed", _x_value)

		if animate_changes and x_value_label:
			_animate_value_change()


# =============================================================================
# CALLBACKS UI
# =============================================================================
func _on_minus_pressed() -> void:
	decrement()


func _on_plus_pressed() -> void:
	increment()


func _on_slider_changed(value: float) -> void:
	# Evitar loops si el cambio viene del código
	if int(value) != _x_value:
		set_x_value(int(value))


func _on_confirm_pressed() -> void:
	var total = get_total_cost()

	print("[XValueSelector] ✓ Confirmado X = %d (Total: %d)" % [_x_value, total])

	# Inyectar datos en card_data para la Pila
	_card_data["instance_x"] = _x_value
	_card_data["x_value"] = _x_value
	_card_data["x_total_cost"] = total

	emit_signal("x_confirmed", _x_value, total)
	hide_selector()


func _on_cancel_pressed() -> void:
	print("[XValueSelector] Cancelado")
	emit_signal("x_cancelled")
	hide_selector()


# =============================================================================
# ACTUALIZACIÓN DE UI
# =============================================================================
func _update_card_info() -> void:
	"""Actualiza la información de la carta"""
	if card_name_label:
		card_name_label.text = _card_data.get("nombre", _card_data.get("name", "???"))

	if formula_label:
		formula_label.text = "Coste: %s" % _formula

	if gold_label:
		# El oro se pasa externamente, podemos mostrar el máximo
		gold_label.text = "Máximo X disponible: %d" % _max_value


func _update_display() -> void:
	"""Actualiza los valores mostrados"""
	# Valor de X
	if x_value_label:
		x_value_label.text = "X = %d" % _x_value

	# Coste total
	var total = get_total_cost()
	if total_cost_label:
		total_cost_label.text = "Coste total: %d Oro" % total

	# Estado de botones
	if minus_button:
		minus_button.disabled = _x_value <= min_value

	if plus_button:
		plus_button.disabled = _x_value >= _max_value

	# Sincronizar slider
	if x_slider and x_slider.value != _x_value:
		x_slider.set_value_no_signal(_x_value)

	# Botón confirmar siempre habilitado (X=0 es válido)
	if confirm_button:
		confirm_button.disabled = false


func _animate_value_change() -> void:
	"""Animación sutil al cambiar el valor"""
	if not x_value_label:
		return

	var tween = create_tween()
	tween.tween_property(x_value_label, "scale", Vector2(1.2, 1.2), 0.05)
	tween.tween_property(x_value_label, "scale", Vector2(1.0, 1.0), 0.1)


# =============================================================================
# UTILIDADES
# =============================================================================
func get_card_data_with_x() -> Dictionary:
	"""Retorna card_data con instance_x inyectado"""
	var data = _card_data.duplicate(true)
	data["instance_x"] = _x_value
	data["x_value"] = _x_value
	data["x_total_cost"] = get_total_cost()
	return data
