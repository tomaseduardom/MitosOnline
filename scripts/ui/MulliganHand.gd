extends Control
class_name MulliganHand
## Mano de Mulligan con disposición en abanico y animaciones elegantes

signal card_hovered(card: Node)
signal card_unhovered(card: Node)
signal card_clicked(card: Node)

# =============================================================================
# CONFIGURACIÓN DEL ABANICO
# =============================================================================
@export var max_rotation: float = 15.0  # Rotación máxima de las cartas externas (grados)
@export var card_spacing: float = 120.0  # Espacio horizontal entre cartas
@export var vertical_curve: float = 30.0  # Curvatura vertical del arco (píxeles)

# =============================================================================
# CONFIGURACIÓN DE ANIMACIONES
# =============================================================================
@export var entry_duration: float = 0.4  # Duración de animación de entrada
@export var entry_delay_per_card: float = 0.08  # Delay entre cada carta
@export var hover_lift: float = 30.0  # Elevación al hover
@export var hover_scale: float = 1.12  # Escala al hover
@export var hover_duration: float = 0.15  # Duración del hover

# =============================================================================
# ESTADO
# =============================================================================
var cards: Array[Node] = []
var hovered_card: Node = null
var _card_targets: Dictionary = {}  # card -> {pos, rot, scale}
var _tweens: Dictionary = {}
var _deck_position: Vector2 = Vector2.ZERO  # Posición del mazo para animación

# =============================================================================
# INICIALIZACIÓN
# =============================================================================
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Posición del mazo (esquina superior derecha, fuera de pantalla)
	_deck_position = Vector2(size.x + 200, -100)


func set_deck_position(pos: Vector2) -> void:
	"""Define la posición desde donde vienen las cartas"""
	_deck_position = pos


# =============================================================================
# GESTIÓN DE CARTAS
# =============================================================================
func add_card(card: Node, animate: bool = true) -> void:
	"""Añade una carta al abanico con animación"""
	cards.append(card)
	add_child(card)

	# Conectar señales de hover
	if card.has_signal("card_hovered"):
		card.card_hovered.connect(_on_card_hovered)
	if card.has_signal("card_unhovered"):
		card.card_unhovered.connect(_on_card_unhovered)
	if card.has_signal("card_clicked"):
		card.card_clicked.connect(_on_card_clicked)

	# Habilitar interacción para hover, pero no drag (el mulligan no usa drag)
	card.can_interact = true
	card.drag_enabled = false

	# Calcular posiciones del abanico
	_calculate_fan_positions()

	if animate:
		var idx = cards.size() - 1
		if card.get("_image_ready") == true:
			_animate_card_entry(card, idx)
		else:
			if _card_targets.has(card):
				var t = _card_targets[card]
				card.position = t.position
				card.rotation_degrees = t.rotation
				card.scale = t.scale
				card.z_index = t.z_index
			card.modulate.a = 0.0
			if card.has_signal("image_ready"):
				card.image_ready.connect(_on_card_image_ready.bind(card, idx), CONNECT_ONE_SHOT)
	else:
		_apply_card_position(card, false)


func add_cards_with_animation(card_list: Array, create_card_func: Callable) -> void:
	"""Añade múltiples cartas con animación secuencial desde el mazo"""
	# Esperar hasta que el contenedor tenga un tamaño válido (máx 10 intentos)
	var attempts = 0
	while (size.x <= 0 or size.y <= 0) and attempts < 10:
		await get_tree().process_frame
		attempts += 1

	# Si aún no hay tamaño válido, usar tamaño de ventana como fallback
	var container_size = size
	if container_size.x <= 0 or container_size.y <= 0:
		var viewport = get_viewport()
		if viewport:
			container_size = viewport.get_visible_rect().size
			container_size.y = container_size.y * 0.4  # Usar 40% de altura
		else:
			container_size = Vector2(1920, 400)  # Fallback absoluto
		push_warning("[MulliganHand] Usando tamaño fallback: %s" % container_size)

	for i in range(card_list.size()):
		var card_data = card_list[i]
		var card = create_card_func.call(card_data)

		cards.append(card)
		add_child(card)

		# Conectar señales
		if card.has_signal("card_hovered"):
			card.card_hovered.connect(_on_card_hovered)
		if card.has_signal("card_unhovered"):
			card.card_unhovered.connect(_on_card_unhovered)
		if card.has_signal("card_clicked"):
			card.card_clicked.connect(_on_card_clicked)

		card.can_interact = true
		card.drag_enabled = false

	# Calcular posiciones finales (pasando el tamaño calculado)
	_calculate_fan_positions(container_size)

	# Animar entrada secuencial: solo si la imagen ya está lista, sino diferir
	for i in range(cards.size()):
		var card = cards[i]
		if card.get("_image_ready") == true:
			_animate_card_entry(card, i)
		else:
			if _card_targets.has(card):
				var t = _card_targets[card]
				card.position = t.position
				card.rotation_degrees = t.rotation
				card.scale = t.scale
				card.z_index = t.z_index
			card.modulate.a = 0.0
			if card.has_signal("image_ready"):
				card.image_ready.connect(_on_card_image_ready.bind(card, i), CONNECT_ONE_SHOT)


func remove_card(card: Node) -> void:
	"""Remueve una carta del abanico"""
	var idx = cards.find(card)
	if idx >= 0:
		cards.remove_at(idx)
		if card.card_hovered.is_connected(_on_card_hovered):
			card.card_hovered.disconnect(_on_card_hovered)
		if card.card_unhovered.is_connected(_on_card_unhovered):
			card.card_unhovered.disconnect(_on_card_unhovered)
		if card.card_clicked.is_connected(_on_card_clicked):
			card.card_clicked.disconnect(_on_card_clicked)
		card.queue_free()
		_calculate_fan_positions()
		_arrange_cards(true)


func clear_cards() -> void:
	"""Limpia todas las cartas con animación de salida"""
	for card in cards:
		_animate_card_exit(card)
	cards.clear()
	_card_targets.clear()


func clear_cards_instant() -> void:
	"""Limpia todas las cartas inmediatamente"""
	for card in cards:
		card.queue_free()
	cards.clear()
	_card_targets.clear()


func get_card_count() -> int:
	return cards.size()


func get_cards() -> Array[Node]:
	return cards


# =============================================================================
# CÁLCULO DEL ABANICO
# =============================================================================
func _calculate_fan_positions(override_size: Vector2 = Vector2.ZERO) -> void:
	"""Calcula las posiciones en abanico para todas las cartas"""
	_card_targets.clear()

	if cards.is_empty():
		return

	var card_count = cards.size()
	var card_size = Vector2(150, 210) * 0.9  # Tamaño de carta escalada

	# Usar tamaño override si se proporciona, sino el tamaño del contenedor
	var container_size = override_size if override_size.x > 0 else size
	if container_size.x <= 0 or container_size.y <= 0:
		container_size = Vector2(1920, 400)  # Fallback

	# Centro del contenedor
	var center_x = container_size.x / 2.0
	var center_y = container_size.y / 2.0

	# Ancho total que ocuparán las cartas
	var total_width = (card_count - 1) * card_spacing
	var start_x = center_x - total_width / 2.0

	for i in range(card_count):
		var card = cards[i]

		# Posición X centrada
		var pos_x = start_x + i * card_spacing - card_size.x / 2.0

		# Factor de -1 a 1 según posición (centro = 0)
		var t = 0.0
		if card_count > 1:
			t = (float(i) / (card_count - 1)) * 2.0 - 1.0  # -1 a 1

		# Posición Y con curva (centro más arriba)
		var curve_offset = (1.0 - t * t) * vertical_curve  # Parábola invertida
		var pos_y = center_y - card_size.y / 2.0 - curve_offset

		# Rotación basada en posición (izquierda rota negativo, derecha positivo)
		var rotation = t * max_rotation

		_card_targets[card] = {
			"position": Vector2(pos_x, pos_y),
			"rotation": rotation,
			"scale": Vector2(0.9, 0.9),
			"z_index": i
		}


func _apply_card_position(card: Node, animated: bool = true) -> void:
	"""Aplica la posición calculada a una carta"""
	if not _card_targets.has(card):
		return

	var target = _card_targets[card]
	card.z_index = target.z_index

	if animated:
		_kill_tween(card)
		var tween = create_tween()
		tween.set_parallel(true)
		tween.tween_property(card, "position", target.position, hover_duration)
		tween.tween_property(card, "rotation_degrees", target.rotation, hover_duration)
		tween.tween_property(card, "scale", target.scale, hover_duration)
		_tweens[card] = tween
	else:
		card.position = target.position
		card.rotation_degrees = target.rotation
		card.scale = target.scale


func _arrange_cards(animated: bool = true) -> void:
	"""Reorganiza todas las cartas en el abanico"""
	for card in cards:
		if card != hovered_card:
			_apply_card_position(card, animated)


# =============================================================================
# ANIMACIONES DE ENTRADA/SALIDA
# =============================================================================
func _animate_card_entry(card: Node, index: int) -> void:
	"""Anima la entrada de una carta desde el mazo"""
	if not _card_targets.has(card):
		return

	var target = _card_targets[card]

	# Posición inicial (desde el mazo)
	card.position = _deck_position
	card.rotation_degrees = 15.0
	card.scale = Vector2(0.5, 0.5)
	card.modulate.a = 0.0
	card.z_index = 100 + index  # Encima durante animación

	# Delay basado en índice
	var delay = index * entry_delay_per_card

	_kill_tween(card)
	var tween = create_tween()

	# Delay inicial
	if delay > 0:
		tween.tween_interval(delay)

	# Animación de entrada
	tween.tween_property(card, "modulate:a", 1.0, entry_duration * 0.3)
	tween.parallel().tween_property(card, "position", target.position, entry_duration).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tween.parallel().tween_property(card, "rotation_degrees", target.rotation, entry_duration).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(card, "scale", target.scale, entry_duration).set_ease(Tween.EASE_OUT)

	# Restaurar z_index al final
	tween.tween_callback(func(): card.z_index = target.z_index)

	_tweens[card] = tween


func _animate_card_exit(card: Node) -> void:
	"""Anima la salida de una carta hacia el mazo"""
	_kill_tween(card)
	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(card, "position", _deck_position, entry_duration * 0.8).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_BACK)
	tween.tween_property(card, "rotation_degrees", -15.0, entry_duration * 0.8)
	tween.tween_property(card, "scale", Vector2(0.3, 0.3), entry_duration * 0.8)
	tween.tween_property(card, "modulate:a", 0.0, entry_duration * 0.5)
	tween.chain().tween_callback(card.queue_free)


# =============================================================================
# HOVER
# =============================================================================
func _on_card_hovered(card: Node) -> void:
	"""Cuando se hace hover sobre una carta"""
	hovered_card = card
	var idx = cards.find(card)
	if idx < 0:
		return

	# Elevar z-index
	card.z_index = 100

	# Obtener posición base
	if not _card_targets.has(card):
		return

	var target = _card_targets[card]
	var hover_pos = target.position + Vector2(0, -hover_lift)

	_kill_tween(card)
	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(card, "position", hover_pos, hover_duration).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "scale", target.scale * hover_scale, hover_duration).set_ease(Tween.EASE_OUT)
	# Reducir rotación al hacer hover para mejor visibilidad
	tween.tween_property(card, "rotation_degrees", target.rotation * 0.3, hover_duration).set_ease(Tween.EASE_OUT)
	_tweens[card] = tween

	emit_signal("card_hovered", card)


func _on_card_unhovered(card: Node) -> void:
	"""Cuando se deja de hacer hover"""
	if hovered_card == card:
		hovered_card = null
		_apply_card_position(card, true)

	emit_signal("card_unhovered", card)


func _on_card_clicked(card: Node) -> void:
	"""Cuando se hace click en una carta"""
	emit_signal("card_clicked", card)


# =============================================================================
# UTILIDADES
# =============================================================================
func _on_card_image_ready(card: Node, index: int) -> void:
	"""Anima la entrada de una carta cuando su imagen está lista."""
	if card in cards:
		_animate_card_entry(card, index)


func _kill_tween(card: Node) -> void:
	"""Detiene el tween activo de una carta"""
	if _tweens.has(card):
		var tween = _tweens[card]
		if tween and tween.is_valid():
			tween.kill()
		_tweens.erase(card)


func set_cards_interactive(interactive: bool) -> void:
	"""Activa/desactiva la interacción de todas las cartas"""
	for card in cards:
		card.can_interact = interactive
