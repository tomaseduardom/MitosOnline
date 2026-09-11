extends Control
class_name DynamicHand
## Mano ESTÁTICA con cartas solapadas y atajo de teclado (H / TAB) para Ocultar/Mostrar la mano y despejar el campo de batalla.

signal card_clicked(card: Node)
signal card_double_clicked(card: Node)

@export var card_overlap: float = -35.0         ## Solapamiento base entre cartas en mano
@export var animation_duration: float = 0.22

var cards: Array[Node] = []
var _tweens: Dictionary = {}
var _is_hidden: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_H or event.keycode == KEY_TAB:
			toggle_hidden()
			get_viewport().set_input_as_handled()


func toggle_hidden() -> void:
	"""Alterna entre ocultar la mano para ver el campo y mostrarla para jugar cartas."""
	_is_hidden = not _is_hidden
	_arrange_cards(true)


func show_hand() -> void:
	if _is_hidden:
		toggle_hidden()


func hide_hand() -> void:
	if not _is_hidden:
		toggle_hidden()


func add_card(card: Node) -> void:
	"""Añade una carta a la mano"""
	cards.append(card)
	add_child(card)

	card.card_clicked.connect(func(c): card_clicked.emit(c))
	card.card_double_clicked.connect(func(c): card_double_clicked.emit(c))

	_arrange_cards()


func remove_card(card: Node, destroy: bool = true) -> void:
	"""Remueve una carta de la mano."""
	var idx = cards.find(card)
	if idx >= 0:
		cards.remove_at(idx)
		if destroy:
			card.queue_free()
		else:
			remove_child(card)
		_arrange_cards()


func get_card_count() -> int:
	return cards.size()


func clear_hand() -> void:
	"""Limpia todas las cartas"""
	for card in cards:
		card.queue_free()
	cards.clear()


func _arrange_cards(animated: bool = true) -> void:
	"""Organiza las cartas con solapamiento ergonómico y centrado."""
	if cards.is_empty():
		return

	var card_width = 150.0  # Ancho base de carta
	var n = cards.size()

	# Solapamiento dinámico: si hay muchas cartas se comprime para encajar en size.x
	var effective_overlap = card_overlap
	if n > 1:
		var available_w = size.x if size.x > 100.0 else 1160.0
		var natural_total = card_width + (n - 1) * (card_width + card_overlap)
		if natural_total > available_w:
			var max_step = (available_w - card_width) / float(n - 1)
			effective_overlap = max_step - card_width

	var total_width = card_width + (n - 1) * (card_width + effective_overlap) if n > 1 else card_width
	var start_x = (size.x - total_width) / 2.0
	var center_y = size.y / 2.0

	for i in range(cards.size()):
		var card = cards[i]
		var target_x = start_x + i * (card_width + effective_overlap)

		# Posición vertical según si la mano está desplegada u oculta:
		# Visible: center_y - 75.0 (posición normal de juego)
		# Oculta: center_y + 155.0 (se retrae bajo la pantalla despejando la Línea de Defensa)
		var target_y = (center_y + 155.0) if _is_hidden else (center_y - 75.0)
		var target_pos = Vector2(target_x, target_y)

		# Z-index basado en posición
		card.z_index = i

		if animated and _tweens.has(card):
			_tweens[card].kill()

		if animated:
			var tween = create_tween()
			tween.set_parallel(true)
			tween.tween_property(card, "position", target_pos, animation_duration).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
			tween.tween_property(card, "scale", Vector2.ONE, animation_duration).set_ease(Tween.EASE_OUT)
			_tweens[card] = tween
		else:
			card.position = target_pos
			card.scale = Vector2.ONE


func get_card_target_position(card: Node) -> Vector2:
	"""Calcula la posición local de destino de una carta en la mano."""
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

	var total_width = card_width + (n - 1) * (card_width + effective_overlap) if n > 1 else card_width
	var start_x = (size.x - total_width) / 2.0
	var center_y = size.y / 2.0
	var target_x = start_x + idx * (card_width + effective_overlap)
	var target_y = (center_y + 155.0) if _is_hidden else (center_y - 75.0)
	return Vector2(target_x, target_y)
