extends RefCounted
class_name SelectionReorder
## SelectionReorder — Drag & drop y botones de reordenamiento (modo LOOK/
## REORDER) de SelectionCanvas. Opera sobre SelectionCanvas via _main.
## Extraído de SelectionCanvas.gd (Fase 4 de reestructuración).

var _main: CanvasLayer

var dragging_card: Control = null
var drag_start_index: int = -1
var drag_offset: Vector2 = Vector2.ZERO
var selected_for_reorder: int = -1  # Índice de carta seleccionada para mover


func setup(main: CanvasLayer) -> void:
	_main = main


func on_card_gui_input(event: InputEvent, display: Control, card: Node) -> void:
	"""Maneja input para drag & drop en modo reordenar"""
	if not _main.is_reorder_mode:
		return

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				# Iniciar drag
				dragging_card = display
				drag_start_index = _main.card_order.find(card)
				drag_offset = display.global_position - event.global_position
				display.z_index = 100

				# Marcar visualmente
				_highlight_card_for_reorder(drag_start_index)

			else:
				# Soltar
				if dragging_card:
					_finalize_drag()

	elif event is InputEventMouseMotion and dragging_card:
		# Mover visualmente mientras arrastra
		dragging_card.global_position = event.global_position + drag_offset

		# Calcular nueva posición basada en posición del mouse
		var container_pos = _main.cards_container.get_local_mouse_position()
		var card_width = 130  # Ancho aproximado de carta + separación
		var new_index = int(container_pos.x / card_width)
		new_index = clampi(new_index, 0, _main.card_order.size() - 1)

		# Mostrar indicador de posición
		_show_drop_indicator(new_index)

		if new_index != drag_start_index:
			# Reordenar en el array
			var card_to_move = _main.card_order[drag_start_index]
			_main.card_order.remove_at(drag_start_index)
			_main.card_order.insert(new_index, card_to_move)
			drag_start_index = new_index


func _finalize_drag() -> void:
	"""Finaliza el drag y actualiza posiciones"""
	if dragging_card:
		dragging_card.z_index = 0
		dragging_card = null

	drag_start_index = -1
	_hide_drop_indicator()
	reorder_card_displays()
	update_position_labels()


func _highlight_card_for_reorder(index: int) -> void:
	"""Resalta una carta seleccionada para reordenar"""
	selected_for_reorder = index

	if not _main.cards_container:
		return

	for i in range(_main.cards_container.get_child_count()):
		var child = _main.cards_container.get_child(i)
		if child is Button:
			if i == index:
				child.modulate = Color(1.2, 1.2, 0.8, 1)  # Amarillo suave
			else:
				child.modulate = Color(1, 1, 1, 1)


func _show_drop_indicator(index: int) -> void:
	"""Muestra indicador visual de dónde se soltará la carta"""
	# TODO: Implementar indicador visual (línea o espacio)
	pass


func _hide_drop_indicator() -> void:
	"""Oculta el indicador de drop"""
	pass


func reorder_card_displays() -> void:
	"""Reordena los displays de cartas según card_order"""
	if not _main.cards_container:
		return

	for i in range(_main.card_order.size()):
		var card = _main.card_order[i]
		for child in _main.cards_container.get_children():
			if child.get_meta("card", null) == card:
				_main.cards_container.move_child(child, i)
				# Resetear posición (por si fue arrastrada)
				child.position = Vector2.ZERO
				break


func update_position_labels() -> void:
	"""Actualiza etiquetas de posición (1=tope, N=fondo)"""
	if not _main.cards_container:
		return

	for i in range(_main.cards_container.get_child_count()):
		var child = _main.cards_container.get_child(i)
		var pos_label = child.get_node_or_null("PositionLabel")
		if pos_label:
			if i == 0:
				pos_label.text = "TOPE"
			elif i == _main.card_order.size() - 1:
				pos_label.text = "FONDO"
			else:
				pos_label.text = str(i + 1)


# --- Botones de reordenamiento (alternativa a drag & drop) ---
func move_card_up(card: Node) -> void:
	"""Mueve una carta hacia arriba (hacia el tope)"""
	var index = _main.card_order.find(card)
	if index > 0:
		_main.card_order.remove_at(index)
		_main.card_order.insert(index - 1, card)
		reorder_card_displays()
		update_position_labels()
		print("[SelectionCanvas] Carta movida al índice %d" % (index - 1))


func move_card_down(card: Node) -> void:
	"""Mueve una carta hacia abajo (hacia el fondo)"""
	var index = _main.card_order.find(card)
	if index < _main.card_order.size() - 1:
		_main.card_order.remove_at(index)
		_main.card_order.insert(index + 1, card)
		reorder_card_displays()
		update_position_labels()
		print("[SelectionCanvas] Carta movida al índice %d" % (index + 1))


func move_card_to_top(card: Node) -> void:
	"""Mueve una carta al tope del mazo"""
	var index = _main.card_order.find(card)
	if index > 0:
		_main.card_order.remove_at(index)
		_main.card_order.insert(0, card)
		reorder_card_displays()
		update_position_labels()
		print("[SelectionCanvas] Carta movida al TOPE")


func move_card_to_bottom(card: Node) -> void:
	"""Mueve una carta al fondo del mazo"""
	var index = _main.card_order.find(card)
	if index < _main.card_order.size() - 1:
		_main.card_order.remove_at(index)
		_main.card_order.append(card)
		reorder_card_displays()
		update_position_labels()
		print("[SelectionCanvas] Carta movida al FONDO")
