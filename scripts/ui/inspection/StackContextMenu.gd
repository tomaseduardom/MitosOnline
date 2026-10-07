extends RefCounted
class_name StackContextMenu
## StackContextMenu — Menú contextual (click derecho) y ventana de preview de
## carta de un item del StackVisualizer (Sección 8: Anular/Cancelar).
## Opera sobre el StackVisualizer via _main. Extraído de StackVisualizer.gd
## (Fase 4 de reestructuración).

var _main: Control

## Popup de contexto para interacción
var _context_popup: PopupMenu = null
var _selected_stack_id: int = -1
var _card_preview_window: Window = null

## IDs del menú contextual
enum ContextMenuID {
	VIEW_CARD = 0,
	CHECK_VALID_TARGET = 1,
	SELECT_AS_ANNUL_TARGET = 2,
	SELECT_AS_CANCEL_TARGET = 3
}


func setup(main: Control) -> void:
	_main = main


func on_item_gui_input(event: InputEvent, stack_id: int) -> void:
	"""Maneja input en un item - Click izquierdo y derecho"""
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				# Click izquierdo: Seleccionar/resaltar
				_main.emit_signal("stack_item_clicked", stack_id)
				_main._highlight_selected_item(stack_id)

			MOUSE_BUTTON_RIGHT:
				# Click derecho: Menú contextual (Sección 8)
				_selected_stack_id = stack_id
				_show_context_menu(stack_id, event.global_position)


func _show_context_menu(stack_id: int, position: Vector2) -> void:
	"""Muestra menú contextual para un item de la pila"""
	# Crear popup si no existe
	if _context_popup == null:
		_context_popup = PopupMenu.new()
		_context_popup.name = "StackContextMenu"
		_main.add_child(_context_popup)
		_context_popup.id_pressed.connect(_on_context_menu_selected)

	_context_popup.clear()

	# Obtener datos del objeto
	var stack_obj = _main._get_stack_object_by_id(stack_id)
	if stack_obj.is_empty():
		return

	var obj_name = stack_obj.get("name", "???")
	var can_be_annulled = _main._can_be_annulled(stack_obj)
	var can_be_cancelled = _main._can_be_cancelled(stack_obj)

	# Opciones del menú
	_context_popup.add_item("Ver carta: %s" % obj_name, ContextMenuID.VIEW_CARD)
	_context_popup.add_separator()
	_context_popup.add_item("Verificar como objetivo", ContextMenuID.CHECK_VALID_TARGET)

	# Opciones de Anular/Cancelar (Sección 8)
	_context_popup.add_separator()

	if can_be_annulled:
		_context_popup.add_item("Seleccionar para ANULAR", ContextMenuID.SELECT_AS_ANNUL_TARGET)
	else:
		_context_popup.add_item("No puede ser anulado", ContextMenuID.SELECT_AS_ANNUL_TARGET)
		_context_popup.set_item_disabled(_context_popup.item_count - 1, true)

	if can_be_cancelled:
		_context_popup.add_item("Seleccionar para CANCELAR", ContextMenuID.SELECT_AS_CANCEL_TARGET)
	else:
		_context_popup.add_item("No puede ser cancelado", ContextMenuID.SELECT_AS_CANCEL_TARGET)
		_context_popup.set_item_disabled(_context_popup.item_count - 1, true)

	# Mostrar popup
	_context_popup.position = Vector2i(position)
	_context_popup.popup()


func _on_context_menu_selected(id: int) -> void:
	"""Maneja selección del menú contextual"""
	var stack_obj = _main._get_stack_object_by_id(_selected_stack_id)

	match id:
		ContextMenuID.VIEW_CARD:
			_show_card_preview(stack_obj)

		ContextMenuID.CHECK_VALID_TARGET:
			_check_valid_target(stack_obj)

		ContextMenuID.SELECT_AS_ANNUL_TARGET:
			_main.emit_signal("annul_target_selected", _selected_stack_id)
			_show_target_selection_feedback(_selected_stack_id, "annul")

		ContextMenuID.SELECT_AS_CANCEL_TARGET:
			_main.emit_signal("cancel_target_selected", _selected_stack_id)
			_show_target_selection_feedback(_selected_stack_id, "cancel")


func _show_card_preview(stack_obj: Dictionary) -> void:
	"""Muestra ventana de preview de la carta completa"""
	_main.emit_signal("card_preview_requested", stack_obj)

	# Crear ventana de preview si no existe
	if _card_preview_window == null:
		_card_preview_window = Window.new()
		_card_preview_window.name = "CardPreviewWindow"
		_card_preview_window.title = "Vista de Carta"
		_card_preview_window.size = Vector2i(350, 500)
		_card_preview_window.unresizable = false
		_card_preview_window.close_requested.connect(_close_card_preview)
		_main.add_child(_card_preview_window)

		# Contenido de la ventana
		var preview_content = _create_card_preview_content()
		_card_preview_window.add_child(preview_content)

	# Actualizar contenido
	_update_card_preview_content(stack_obj)

	# Mostrar ventana
	_card_preview_window.popup_centered()


func _create_card_preview_content() -> Control:
	"""Crea el contenido de la ventana de preview"""
	var panel = PanelContainer.new()
	panel.name = "PreviewPanel"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 15)
	margin.add_theme_constant_override("margin_right", 15)
	margin.add_theme_constant_override("margin_top", 15)
	margin.add_theme_constant_override("margin_bottom", 15)
	panel.add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.name = "ContentVBox"
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	# Nombre de carta
	var name_label = Label.new()
	name_label.name = "CardName"
	name_label.add_theme_font_size_override("font_size", 18)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(name_label)

	# Tipo
	var type_label = Label.new()
	type_label.name = "CardType"
	type_label.add_theme_font_size_override("font_size", 12)
	type_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	type_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(type_label)

	# Separador
	var sep = HSeparator.new()
	vbox.add_child(sep)

	# Coste y Fuerza
	var stats_hbox = HBoxContainer.new()
	stats_hbox.name = "StatsBox"
	stats_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(stats_hbox)

	var cost_label = Label.new()
	cost_label.name = "CostLabel"
	cost_label.add_theme_font_size_override("font_size", 14)
	stats_hbox.add_child(cost_label)

	var spacer = Control.new()
	spacer.custom_minimum_size.x = 30
	stats_hbox.add_child(spacer)

	var strength_label = Label.new()
	strength_label.name = "StrengthLabel"
	strength_label.add_theme_font_size_override("font_size", 14)
	stats_hbox.add_child(strength_label)

	# Habilidad
	var ability_label = RichTextLabel.new()
	ability_label.name = "AbilityText"
	ability_label.bbcode_enabled = true
	ability_label.fit_content = true
	ability_label.custom_minimum_size.y = 150
	vbox.add_child(ability_label)

	# Info de pila
	var sep2 = HSeparator.new()
	vbox.add_child(sep2)

	var stack_info = Label.new()
	stack_info.name = "StackInfo"
	stack_info.add_theme_font_size_override("font_size", 11)
	stack_info.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
	stack_info.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(stack_info)

	# Botón cerrar
	var close_btn = Button.new()
	close_btn.name = "CloseButton"
	close_btn.text = "Cerrar"
	close_btn.pressed.connect(_close_card_preview)
	vbox.add_child(close_btn)

	return panel


func _update_card_preview_content(stack_obj: Dictionary) -> void:
	"""Actualiza el contenido del preview con los datos del objeto"""
	if _card_preview_window == null:
		return

	var card_data = stack_obj.get("card_data", {})
	var content = _card_preview_window.get_node_or_null("PreviewPanel/MarginContainer/ContentVBox")
	if content == null:
		return

	# Nombre
	var name_label = content.get_node_or_null("CardName")
	if name_label:
		name_label.text = stack_obj.get("name", "???")

	# Tipo
	var type_label = content.get_node_or_null("CardType")
	if type_label:
		type_label.text = stack_obj.get("type_name", "Desconocido")

	# Coste
	var cost_label = content.get_node_or_null("StatsBox/CostLabel")
	if cost_label:
		var cost = card_data.get("coste", 0)
		cost_label.text = "Coste: %d" % cost

	# Fuerza
	var strength_label = content.get_node_or_null("StatsBox/StrengthLabel")
	if strength_label:
		var strength = card_data.get("fuerza", 0)
		if card_data.get("tipo", -1) == Constants.CardType.ALIADO:
			strength_label.text = "Fuerza: %d" % strength
		else:
			strength_label.text = ""

	# Habilidad
	var ability_text = content.get_node_or_null("AbilityText")
	if ability_text:
		var ability = card_data.get("habilidad", card_data.get("ability", "Sin habilidad"))
		ability_text.text = ability

	# Info de pila
	var stack_info = content.get_node_or_null("StackInfo")
	if stack_info:
		var info_parts: Array = []
		info_parts.append("ID en pila: #%d" % stack_obj.get("id", 0))
		info_parts.append("Estado: %s" % stack_obj.get("step_name", "???"))

		var targets = stack_obj.get("targets", [])
		if not targets.is_empty():
			info_parts.append("Objetivos: %d" % targets.size())

		if _main._can_be_annulled(stack_obj):
			info_parts.append("Puede ser ANULADO")
		if _main._can_be_cancelled(stack_obj):
			info_parts.append("Puede ser CANCELADO")

		stack_info.text = "\n".join(info_parts)


func _close_card_preview() -> void:
	"""Cierra la ventana de preview"""
	if _card_preview_window:
		_card_preview_window.hide()


func _check_valid_target(stack_obj: Dictionary) -> void:
	"""Verifica y muestra si el objeto es un objetivo válido"""
	var is_valid_annul = _main._can_be_annulled(stack_obj)
	var is_valid_cancel = _main._can_be_cancelled(stack_obj)

	var message = "%s:\n" % stack_obj.get("name", "???")

	if is_valid_annul:
		message += "VÁLIDO para Anular\n"
	else:
		message += "NO puede ser Anulado\n"

	if is_valid_cancel:
		message += "VÁLIDO para Cancelar"
	else:
		message += "NO puede ser Cancelado"

	# Mostrar feedback visual
	_show_validation_popup(message, stack_obj.get("id", -1))

	_main.emit_signal("target_validation_requested", stack_obj.get("id", -1), {})


func _show_validation_popup(message: String, stack_id: int) -> void:
	"""Muestra popup temporal con resultado de validación"""
	var popup = AcceptDialog.new()
	popup.dialog_text = message
	popup.title = "Validación de Objetivo"
	popup.confirmed.connect(popup.queue_free)
	popup.canceled.connect(popup.queue_free)
	_main.add_child(popup)
	popup.popup_centered()


func _show_target_selection_feedback(stack_id: int, action_type: String) -> void:
	"""Muestra feedback visual cuando se selecciona un objetivo"""
	if not _main._stack_items.has(stack_id):
		return

	var item = _main._stack_items[stack_id]
	if not is_instance_valid(item):
		return

	# Flash según tipo de acción
	var flash_color = Color.RED if action_type == "annul" else Color.ORANGE
	_main._animations.flash_item(item, flash_color)

	# Añadir indicador visual temporal
	var indicator = item.find_child("WaitIndicator", true, false)
	if indicator:
		indicator.visible = true
		if action_type == "annul":
			indicator.text = "[OBJETIVO DE ANULACIÓN]"
			indicator.add_theme_color_override("font_color", Color.RED)
		else:
			indicator.text = "[OBJETIVO DE CANCELACIÓN]"
			indicator.add_theme_color_override("font_color", Color.ORANGE)
