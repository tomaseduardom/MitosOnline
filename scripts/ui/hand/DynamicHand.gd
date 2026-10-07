extends Control
class_name DynamicHand
## Mano con cartas en abanico profesional (arco rúnico).
## - Distribución matemática en arco cosenoidal/parabólico con rotación progresiva.
## - Hover profesional: la carta se eleva, se endereza a 0° y gana prioridad z_index.
## - Teclas Q / H: el jugador oculta o despliega su mano con animación fluida.

signal card_clicked(card: Node)
signal card_double_clicked(card: Node)

@export_group("Layout")
@export var card_overlap: float = -35.0         ## Solapamiento base entre cartas en mano
@export var animation_duration: float = 0.22
@export var max_fan_angle: float = 9.5          ## Ángulo máximo de apertura del abanico en grados
@export var max_arc_height: float = 22.0        ## Elevación vertical máxima del centro del arco
@export var hover_lift: float = 2.0             ## Elevación mínima en píxeles al hacer hover (micro-lift sutil)

var cards: Array[Node] = []
var _tweens: Dictionary = {}
var _is_hidden: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not child_exiting_tree.is_connected(_on_child_exiting_tree):
		child_exiting_tree.connect(_on_child_exiting_tree)


func _on_child_exiting_tree(node: Node) -> void:
	var idx = cards.find(node)
	if idx >= 0:
		cards.remove_at(idx)
		if _tweens.has(node):
			if is_instance_valid(_tweens[node]):
				_tweens[node].kill()
			_tweens.erase(node)
		_arrange_cards(true)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_Q or event.keycode == KEY_H:
			toggle_hidden()
			get_viewport().set_input_as_handled()


func toggle_hidden() -> void:
	"""Alterna entre ocultar la mano para ver el campo y mostrarla para jugar cartas."""
	_is_hidden = not _is_hidden
	_arrange_cards(true)


func show_hand() -> void:
	if _is_hidden:
		_is_hidden = false
		_arrange_cards(true)


func hide_hand() -> void:
	if not _is_hidden:
		_is_hidden = true
		_arrange_cards(true)


func add_card(card: Node) -> void:
	"""Añade una carta a la mano configurando pivote para abanico y señales de hover."""
	if card in cards:
		return
	cards.append(card)
	if card.get_parent() != self:
		add_child(card)

	# Pivote en centro-inferior de la carta (150x210) para giro de abanico natural
	var card_width = 150.0
	var card_height = 210.0
	card.pivot_offset = Vector2(card_width / 2.0, card_height)

	if not card.card_clicked.is_connected(_forward_card_clicked):
		card.card_clicked.connect(_forward_card_clicked)
	if not card.card_double_clicked.is_connected(_forward_card_double_clicked):
		card.card_double_clicked.connect(_forward_card_double_clicked)
	if card.has_signal("card_hovered") and not card.card_hovered.is_connected(_on_card_hovered):
		card.card_hovered.connect(_on_card_hovered)
	if card.has_signal("card_unhovered") and not card.card_unhovered.is_connected(_on_card_unhovered):
		card.card_unhovered.connect(_on_card_unhovered)

	_arrange_cards(true)


func _forward_card_clicked(c: Node) -> void:
	card_clicked.emit(c)


func _forward_card_double_clicked(c: Node) -> void:
	card_double_clicked.emit(c)


func remove_card(card: Node, destroy: bool = true) -> void:
	"""Remueve una carta de la mano y reordena el abanico."""
	var idx = cards.find(card)
	if idx >= 0:
		cards.remove_at(idx)
	if _tweens.has(card):
		if is_instance_valid(_tweens[card]):
			_tweens[card].kill()
		_tweens.erase(card)

	if card.has_signal("card_hovered") and card.card_hovered.is_connected(_on_card_hovered):
		card.card_hovered.disconnect(_on_card_hovered)
	if card.has_signal("card_unhovered") and card.card_unhovered.is_connected(_on_card_unhovered):
		card.card_unhovered.disconnect(_on_card_unhovered)

	if destroy:
		card.queue_free()
	elif card.get_parent() == self:
		remove_child(card)
	_arrange_cards(true)


func get_card_count() -> int:
	return cards.size()


func clear_hand() -> void:
	"""Limpia todas las cartas de la mano."""
	for card in cards:
		if is_instance_valid(card):
			card.queue_free()
	cards.clear()
	_tweens.clear()


func get_card_target_rotation(card: Node) -> float:
	"""Calcula la inclinación angular en grados para una carta según su posición en el abanico."""
	var idx = cards.find(card)
	if idx < 0:
		return 0.0
	var n = cards.size()
	if n <= 1 or _is_hidden:
		return 0.0

	var center_idx = (n - 1) / 2.0
	var d = float(idx) - center_idx
	var t = d / maxf(center_idx, 1.0)
	var dynamic_max_tilt = clampf((n - 1) * 2.2, 0.0, max_fan_angle)
	return t * dynamic_max_tilt


func get_card_target_position(card: Node) -> Vector2:
	"""Calcula la posición local (X, Y en arco) de destino para una carta en la mano."""
	var idx = cards.find(card)
	if idx < 0:
		idx = cards.size() - 1
	if idx < 0:
		idx = 0

	var card_width = 150.0
	var n = maxi(1, cards.size())
	var effective_overlap = card_overlap
	if n > 1:
		var available_w = size.x if size.x > 100.0 else 1160.0
		var natural_total = card_width + (n - 1) * (card_width + card_overlap)
		if natural_total > available_w:
			var max_step = (available_w - card_width) / float(n - 1)
			effective_overlap = max_step - card_width

	var step_x = card_width + effective_overlap
	var total_width = card_width + (n - 1) * step_x if n > 1 else card_width
	var start_x = (size.x - total_width) / 2.0
	var center_y = size.y / 2.0
	var target_x = start_x + idx * step_x

	var base_y = _get_vertical_target_y(center_y)
	var target_y = base_y
	if not _is_hidden and n > 1:
		var center_idx = (n - 1) / 2.0
		var d = float(idx) - center_idx
		var t = d / maxf(center_idx, 1.0)
		var dynamic_arc = clampf((n - 1) * 3.5, 0.0, max_arc_height)
		var curve_lift = (1.0 - (t * t)) * dynamic_arc
		target_y = base_y - curve_lift

	return Vector2(target_x, target_y)


func _get_vertical_target_y(center_y: float) -> float:
	"""Calcula la posición Y base según si la mano está desplegada u oculta."""
	if not _is_hidden:
		return center_y - 75.0
	else:
		return center_y + 155.0  # Oculta bajo la pantalla


func _arrange_cards(animated: bool = true) -> void:
	"""Organiza las cartas en un abanico simétrico con elevación en arco y rotación armónica."""
	var valid_cards: Array[Node] = []
	for c in cards:
		if is_instance_valid(c) and c.get_parent() == self:
			valid_cards.append(c)
	if valid_cards.size() != cards.size():
		cards = valid_cards

	if cards.is_empty():
		return

	var card_width = 150.0
	var card_height = 210.0
	var n = cards.size()

	var effective_overlap = card_overlap
	if n > 1:
		var available_w = size.x if size.x > 100.0 else 1160.0
		var natural_total = card_width + (n - 1) * (card_width + card_overlap)
		if natural_total > available_w:
			var max_step = (available_w - card_width) / float(n - 1)
			effective_overlap = max_step - card_width

	var step_x = card_width + effective_overlap

	for i in range(cards.size()):
		var card = cards[i]
		card.pivot_offset = Vector2(card_width / 2.0, card_height)

		var target_pos: Vector2 = get_card_target_position(card)
		var target_rot: float = get_card_target_rotation(card)

		card.set_meta("hand_base_z_index", i)
		card.set("target_rotation", target_rot)
		card.set("original_position", target_pos)

		var is_card_hovered: bool = (card.get("is_hovered") == true)
		if is_card_hovered:
			target_pos.y -= hover_lift
			target_rot = 0.0
			card.z_index = 100
			card.set("original_z_index", i)
		else:
			card.z_index = i
			card.set("original_z_index", i)

		# Recorte de click para cartas tapadas por la siguiente a la derecha
		if card.has_method("set_click_clip_right"):
			if not is_card_hovered and i < n - 1 and step_x < card_width:
				card.set_click_clip_right(step_x)
			else:
				card.set_click_clip_right(-1.0)

		if animated and _tweens.has(card):
			if is_instance_valid(_tweens[card]):
				_tweens[card].kill()
			_tweens.erase(card)

		if animated:
			var tween = create_tween()
			tween.set_parallel(true)
			tween.tween_property(card, "position", target_pos, animation_duration).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
			tween.tween_property(card, "rotation_degrees", target_rot, animation_duration).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
			if not is_card_hovered:
				tween.tween_property(card, "scale", Vector2.ONE, animation_duration).set_ease(Tween.EASE_OUT)
			_tweens[card] = tween
		else:
			card.position = target_pos
			card.rotation_degrees = target_rot
			if not is_card_hovered:
				card.scale = Vector2.ONE


func _on_card_hovered(card: Node) -> void:
	"""Al hacer hover: eleva suavemente la carta, la endereza a 0° y le da prioridad de dibujo."""
	if not is_instance_valid(card) or card.get_parent() != self:
		return
	if _is_hidden or card.get("is_dragging") == true:
		return

	if _tweens.has(card) and is_instance_valid(_tweens[card]):
		_tweens[card].kill()
		_tweens.erase(card)

	var base_target: Vector2 = get_card_target_position(card)
	var hover_pos := Vector2(base_target.x, base_target.y - hover_lift)

	card.z_index = 100
	if card.has_method("set_click_clip_right"):
		card.set_click_clip_right(-1.0)

	var tw = create_tween()
	tw.set_parallel(true)
	tw.tween_property(card, "position", hover_pos, 0.16).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(card, "rotation_degrees", 0.0, 0.16).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_tweens[card] = tw


func _on_card_unhovered(card: Node) -> void:
	"""Al salir el mouse: regresa suavemente a su posición y rotación en el abanico."""
	if not is_instance_valid(card) or card.get_parent() != self:
		return
	if card.get("is_dragging") == true:
		return

	if _tweens.has(card) and is_instance_valid(_tweens[card]):
		_tweens[card].kill()
		_tweens.erase(card)

	var target_pos: Vector2 = get_card_target_position(card)
	var target_rot: float = get_card_target_rotation(card)
	var base_z: int = card.get_meta("hand_base_z_index", cards.find(card))

	var tw = create_tween()
	tw.set_parallel(true)
	tw.tween_property(card, "position", target_pos, 0.18).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(card, "rotation_degrees", target_rot, 0.18).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.chain().tween_callback(func():
		if is_instance_valid(card) and not card.get("is_hovered"):
			card.z_index = base_z
			if card.has_method("set_click_clip_right"):
				card.set_click_clip_right(get_card_clip_right(card))
	)
	_tweens[card] = tw


func get_card_clip_right(card: Node) -> float:
	"""Devuelve el ancho expuesto para recorte de clic en cartas solapadas."""
	var idx = cards.find(card)
	if idx < 0 or idx >= cards.size() - 1:
		return -1.0
	var card_width = 150.0
	var n = cards.size()
	var effective_overlap = card_overlap
	if n > 1:
		var available_w = size.x if size.x > 100.0 else 1160.0
		var natural_total = card_width + (n - 1) * (card_width + card_overlap)
		if natural_total > available_w:
			var max_step = (available_w - card_width) / float(n - 1)
			effective_overlap = max_step - card_width
	var step_x = card_width + effective_overlap
	return step_x if step_x < card_width else -1.0
