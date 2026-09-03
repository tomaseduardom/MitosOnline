extends RefCounted
class_name XCostSelector
## XCostSelector — Detección y UI de selección de coste variable X (DAR).
## Opera sobre PaymentManager via _main (estado de pago, oro disponible,
## log, continuación del flujo de pago). Extraído de PaymentManager.gd
## (Fase 4 de reestructuración).

var _main: Node

var _x_value: int = 0                  # Valor seleccionado para X
var _x_max_value: int = 0              # Máximo permitido (Oros disponibles)
var _x_base_cost: int = 0              # Coste base además de X
var _has_x_cost: bool = false          # Si la carta actual tiene coste X
var _x_callback: Callable = Callable() # Callback tras seleccionar X

var _x_value_popup: Window = null  # Fallback programático
var _x_value_selector: Control = null  # Escena XValueSelector.tscn

## Escena del selector de X
const X_VALUE_SELECTOR_SCENE = preload("res://scenes/ui/XValueSelector.tscn")


func setup(main: Node) -> void:
	_main = main


func _setup_x_selector() -> void:
	"""Instancia la escena XValueSelector"""
	if X_VALUE_SELECTOR_SCENE:
		_x_value_selector = X_VALUE_SELECTOR_SCENE.instantiate()
		_x_value_selector.name = "XValueSelector"
		_main.add_child(_x_value_selector)

		# Conectar señales
		_x_value_selector.x_confirmed.connect(_on_x_selector_confirmed)
		_x_value_selector.x_cancelled.connect(_on_x_selector_cancelled)
		_x_value_selector.x_changed.connect(_on_x_selector_changed)

		print("[PaymentManager] XValueSelector instanciado desde escena")


# =============================================================================
# COSTE VARIABLE X - Detector e Interfaz
# =============================================================================
func has_variable_x_cost(card_data: Dictionary) -> bool:
	"""Detecta si una carta tiene coste variable X

	Busca en:
	- coste: "X", "X+1", "2+X", etc.
	- coste_x: true
	- has_x_cost: true en traits
	- Texto de habilidad que mencione "paga X"
	"""
	# Verificar coste directo
	var cost = card_data.get("coste", card_data.get("cost", 0))
	if cost is String:
		var cost_str = cost.to_upper()
		if "X" in cost_str:
			return true

	# Verificar flag explícito
	if card_data.get("coste_x", false):
		return true
	if card_data.get("has_x_cost", false):
		return true

	# Verificar traits
	var traits = card_data.get("traits", {})
	if traits.get("has_x_cost", false):
		return true
	if traits.get("coste_variable", false):
		return true

	# Verificar texto de habilidad
	var ability = str(card_data.get("habilidad", card_data.get("ability", ""))).to_lower()
	if "paga x" in ability or "pagar x" in ability or "coste x" in ability:
		return true

	return false


func parse_x_cost(card_data: Dictionary) -> Dictionary:
	"""Parsea el coste X de una carta

	Returns:
		{
			has_x: bool,
			base_cost: int,      # Coste fijo adicional (ej: "2+X" = 2)
			x_multiplier: int,   # Multiplicador de X (ej: "2X" = 2)
			formula: String      # Fórmula original
		}
	"""
	var result = {
		"has_x": false,
		"base_cost": 0,
		"x_multiplier": 1,
		"formula": ""
	}

	var cost = card_data.get("coste", card_data.get("cost", 0))

	# Si es número directo, no hay X
	if cost is int or cost is float:
		return result

	if cost is String:
		var cost_str = cost.to_upper().strip_edges()
		result.formula = cost_str

		if "X" in cost_str:
			result.has_x = true

			# Parsear fórmulas comunes
			# "X" puro
			if cost_str == "X":
				result.base_cost = 0
				result.x_multiplier = 1

			# "X+N" o "N+X"
			elif "+" in cost_str:
				var parts = cost_str.split("+")
				for part in parts:
					part = part.strip_edges()
					if part == "X":
						result.x_multiplier = 1
					elif part.is_valid_int():
						result.base_cost = int(part)
					elif part.ends_with("X"):
						# "2X" = 2 * X
						var mult = part.replace("X", "").strip_edges()
						if mult.is_valid_int():
							result.x_multiplier = int(mult)

			# "2X" (sin +)
			elif cost_str.ends_with("X") and cost_str.length() > 1:
				var mult = cost_str.replace("X", "").strip_edges()
				if mult.is_valid_int():
					result.x_multiplier = int(mult)

	return result


func request_x_value_input(card_data: Dictionary, player_id: int, callback: Callable = Callable()) -> void:
	"""Solicita al jugador que seleccione el valor de X

	Args:
		card_data: Datos de la carta con coste X
		player_id: Jugador que paga
		callback: Función a llamar con el valor seleccionado
	"""
	_main._current_card = card_data
	_main._current_player_id = player_id
	_main._state = PaymentManager.PaymentState.AWAITING_X_INPUT
	_x_callback = callback

	# Calcular límites
	var x_info = parse_x_cost(card_data)
	var available_gold = _main._validation._get_player_available_gold(player_id)

	_x_base_cost = x_info.base_cost
	_has_x_cost = true

	# Máximo X = (Oro disponible - coste base) / multiplicador
	if x_info.x_multiplier > 0:
		_x_max_value = (available_gold - x_info.base_cost) / x_info.x_multiplier
	else:
		_x_max_value = available_gold - x_info.base_cost

	_x_max_value = maxi(0, _x_max_value)
	_x_value = 0

	print("[PaymentManager] ═══ COSTE VARIABLE X ═══")
	print("[PaymentManager] Carta: %s" % card_data.get("nombre", card_data.get("name", "???")))
	print("[PaymentManager] Fórmula: %s | Base: %d | Máx X: %d" % [
		x_info.formula, x_info.base_cost, _x_max_value
	])

	_main.emit_signal("x_value_requested", card_data, _x_max_value)

	# ─────────────────────────────────────────────────────────────────────────
	# USAR ESCENA XValueSelector.tscn SI ESTÁ DISPONIBLE
	# ─────────────────────────────────────────────────────────────────────────
	if _x_value_selector and is_instance_valid(_x_value_selector):
		_x_value_selector.show_selector(card_data, player_id, available_gold, x_info)
	else:
		# Fallback: popup programático
		_create_x_value_popup(card_data, x_info)


func _create_x_value_popup(card_data: Dictionary, x_info: Dictionary) -> void:
	"""Crea popup para seleccionar valor de X"""
	if _x_value_popup and is_instance_valid(_x_value_popup):
		_x_value_popup.queue_free()

	_x_value_popup = Window.new()
	_x_value_popup.name = "XValuePopup"
	_x_value_popup.title = "Seleccionar Valor de X"
	_x_value_popup.size = Vector2i(320, 280)
	_x_value_popup.unresizable = true
	_x_value_popup.close_requested.connect(_on_x_value_cancelled)
	_main.add_child(_x_value_popup)

	var panel = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_x_value_popup.add_child(panel)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	panel.add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 15)
	margin.add_child(vbox)

	# Título de la carta
	var title = Label.new()
	title.text = card_data.get("nombre", card_data.get("name", "???"))
	title.add_theme_font_size_override("font_size", 16)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# Fórmula del coste
	var formula_label = Label.new()
	formula_label.text = "Coste: %s" % x_info.formula
	formula_label.add_theme_font_size_override("font_size", 14)
	formula_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	formula_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	vbox.add_child(formula_label)

	# Oro disponible
	var gold_label = Label.new()
	gold_label.text = "💰 Oro disponible: %d" % _main._validation._get_player_available_gold(_main._current_player_id)
	gold_label.add_theme_font_size_override("font_size", 12)
	gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(gold_label)

	# Separador
	vbox.add_child(HSeparator.new())

	# Contenedor del contador
	var counter_hbox = HBoxContainer.new()
	counter_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	counter_hbox.add_theme_constant_override("separation", 15)
	vbox.add_child(counter_hbox)

	# Botón -
	var minus_btn = Button.new()
	minus_btn.text = "-"
	minus_btn.custom_minimum_size = Vector2(40, 40)
	minus_btn.pressed.connect(_on_x_decrement)
	counter_hbox.add_child(minus_btn)

	# Display del valor
	var value_label = Label.new()
	value_label.name = "XValueLabel"
	value_label.text = "X = 0"
	value_label.add_theme_font_size_override("font_size", 24)
	value_label.custom_minimum_size.x = 80
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	counter_hbox.add_child(value_label)

	# Botón +
	var plus_btn = Button.new()
	plus_btn.text = "+"
	plus_btn.custom_minimum_size = Vector2(40, 40)
	plus_btn.pressed.connect(_on_x_increment)
	counter_hbox.add_child(plus_btn)

	# Coste total calculado
	var total_label = Label.new()
	total_label.name = "TotalCostLabel"
	total_label.text = "Coste total: %d Oro" % x_info.base_cost
	total_label.add_theme_font_size_override("font_size", 14)
	total_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	total_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
	vbox.add_child(total_label)

	# Slider para selección rápida (si el máximo es > 5)
	if _x_max_value > 5:
		var slider = HSlider.new()
		slider.name = "XSlider"
		slider.min_value = 0
		slider.max_value = _x_max_value
		slider.value = 0
		slider.step = 1
		slider.value_changed.connect(_on_x_slider_changed)
		vbox.add_child(slider)

	# Separador
	vbox.add_child(HSeparator.new())

	# Botones de acción
	var btn_hbox = HBoxContainer.new()
	btn_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_hbox.add_theme_constant_override("separation", 20)
	vbox.add_child(btn_hbox)

	var confirm_btn = Button.new()
	confirm_btn.text = "✓ Confirmar"
	confirm_btn.pressed.connect(_on_x_value_confirmed)
	btn_hbox.add_child(confirm_btn)

	var cancel_btn = Button.new()
	cancel_btn.text = "✗ Cancelar"
	cancel_btn.pressed.connect(_on_x_value_cancelled)
	btn_hbox.add_child(cancel_btn)

	_x_value_popup.popup_centered()


func _on_x_increment() -> void:
	"""Incrementa el valor de X"""
	if _x_value < _x_max_value:
		_x_value += 1
		_update_x_display()


func _on_x_decrement() -> void:
	"""Decrementa el valor de X"""
	if _x_value > 0:
		_x_value -= 1
		_update_x_display()


func _on_x_slider_changed(value: float) -> void:
	"""Callback cuando cambia el slider"""
	_x_value = int(value)
	_update_x_display()


func _update_x_display() -> void:
	"""Actualiza la UI con el valor actual de X"""
	if not _x_value_popup or not is_instance_valid(_x_value_popup):
		return

	var x_info = parse_x_cost(_main._current_card)
	var total_cost = x_info.base_cost + (_x_value * x_info.x_multiplier)

	# Actualizar label de valor
	var value_label = _x_value_popup.find_child("XValueLabel", true, false)
	if value_label:
		value_label.text = "X = %d" % _x_value

	# Actualizar coste total
	var total_label = _x_value_popup.find_child("TotalCostLabel", true, false)
	if total_label:
		total_label.text = "Coste total: %d Oro" % total_cost

	# Actualizar slider si existe
	var slider = _x_value_popup.find_child("XSlider", true, false)
	if slider and slider.value != _x_value:
		slider.value = _x_value


func _on_x_value_confirmed() -> void:
	"""Callback cuando se confirma el valor de X"""
	var x_info = parse_x_cost(_main._current_card)
	var total_cost = x_info.base_cost + (_x_value * x_info.x_multiplier)
	var card_name = _main._current_card.get("nombre", _main._current_card.get("name", "???"))
	var player_name = _main._get_player_name(_main._current_player_id)

	print("[PaymentManager] ✓ X = %d confirmado (Coste total: %d)" % [_x_value, total_cost])

	# Guardar valor de X en la carta para uso posterior
	_main._current_card["x_value"] = _x_value
	_main._current_card["x_total_cost"] = total_cost

	# ─────────────────────────────────────────────────────────────────────────
	# LOG: Registrar valor de X seleccionado
	# ─────────────────────────────────────────────────────────────────────────
	_main._log_action("cost", "%s elige X = %d para [%s] (Coste: %d)" % [
		player_name, _x_value, card_name, total_cost
	], {
		"player_id": _main._current_player_id,
		"card_name": card_name,
		"x_value": _x_value,
		"total_cost": total_cost,
		"formula": x_info.formula
	})

	_main.emit_signal("x_value_selected", _main._current_card, _x_value)

	_close_x_value_popup()

	# Ejecutar callback si existe
	if _x_callback.is_valid():
		_x_callback.call(_x_value, total_cost)

	# Continuar con el pago normal
	_main._state = PaymentManager.PaymentState.AWAITING_PAYMENT
	var payment_option = {
		"method": PaymentManager.PaymentMethod.VARIABLE_X,
		"cost": total_cost,
		"x_value": _x_value
	}
	_main._payment_ui._process_payment(payment_option)


func _on_x_value_cancelled() -> void:
	"""Callback cuando se cancela la selección de X"""
	print("[PaymentManager] Selección de X cancelada")
	_main.emit_signal("x_value_cancelled", _main._current_card)
	_close_x_value_popup()
	_main._state = PaymentManager.PaymentState.CANCELLED
	_main.emit_signal("payment_cancelled", _main._current_card, "Selección de X cancelada")


func _close_x_value_popup() -> void:
	"""Cierra el popup de selección de X"""
	if _x_value_popup and is_instance_valid(_x_value_popup):
		_x_value_popup.queue_free()
		_x_value_popup = null

	_has_x_cost = false


# =============================================================================
# CALLBACKS DE XValueSelector.tscn (Escena)
# =============================================================================
func _on_x_selector_confirmed(x_value: int, total_cost: int) -> void:
	"""Callback cuando XValueSelector confirma el valor"""
	var card_name = _main._current_card.get("nombre", _main._current_card.get("name", "???"))
	var player_name = _main._get_player_name(_main._current_player_id)

	_x_value = x_value
	print("[PaymentManager] ✓ XValueSelector: X = %d (Total: %d)" % [x_value, total_cost])

	# ─────────────────────────────────────────────────────────────────────────
	# INYECCIÓN DE DATOS: instance_x en card_data para la Pila
	# ─────────────────────────────────────────────────────────────────────────
	_main._current_card["instance_x"] = x_value
	_main._current_card["x_value"] = x_value
	_main._current_card["x_total_cost"] = total_cost

	# Log
	_main._log_action("cost", "%s elige X = %d para [%s] (Coste: %d)" % [
		player_name, x_value, card_name, total_cost
	], {
		"player_id": _main._current_player_id,
		"card_name": card_name,
		"instance_x": x_value,
		"total_cost": total_cost
	})

	_main.emit_signal("x_value_selected", _main._current_card, x_value)

	# Ejecutar callback si existe
	if _x_callback.is_valid():
		_x_callback.call(x_value, total_cost)

	# Continuar con el pago
	_main._state = PaymentManager.PaymentState.AWAITING_PAYMENT
	var payment_option = {
		"method": PaymentManager.PaymentMethod.VARIABLE_X,
		"cost": total_cost,
		"x_value": x_value,
		"instance_x": x_value
	}
	_main._payment_ui._process_payment(payment_option)


func _on_x_selector_cancelled() -> void:
	"""Callback cuando XValueSelector cancela"""
	print("[PaymentManager] XValueSelector cancelado")
	_main.emit_signal("x_value_cancelled", _main._current_card)
	_main._state = PaymentManager.PaymentState.CANCELLED
	_has_x_cost = false
	_main.emit_signal("payment_cancelled", _main._current_card, "Selección de X cancelada")


func _on_x_selector_changed(x_value: int) -> void:
	"""Callback cuando cambia el valor en XValueSelector (preview)"""
	_x_value = x_value
	# Opcional: emitir señal para preview en UI


func get_x_value() -> int:
	"""Retorna el valor actual de X"""
	return _x_value


func get_x_total_cost() -> int:
	"""Retorna el coste total con X incluido"""
	var x_info = parse_x_cost(_main._current_card)
	return x_info.base_cost + (_x_value * x_info.x_multiplier)
