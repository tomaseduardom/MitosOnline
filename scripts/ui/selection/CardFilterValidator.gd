extends RefCounted
class_name CardFilterValidator
## CardFilterValidator — Validación de cartas contra el filtro de requisitos
## de una selección (DAR Sección 1.D) y mensajes de error asociados.
## Opera sobre SelectionCanvas via _main. Extraído de SelectionCanvas.gd
## (Fase 4 de reestructuración).

var _main: CanvasLayer


func setup(main: CanvasLayer) -> void:
	_main = main


func get_valid_cards(cards: Array, filter: Dictionary) -> Array:
	"""Retorna solo las cartas que cumplen el filtro"""
	if filter.is_empty():
		return cards.duplicate()

	var valid: Array = []
	for card in cards:
		if card_passes_filter(card, filter):
			valid.append(card)

	return valid


func card_passes_filter(card: Node, filter: Dictionary) -> bool:
	"""Verifica si una carta cumple todos los requisitos del filtro

	Filtros soportados:
	- card_type: int (Constants.CardType)
	- card_race: String
	- card_class: String
	- max_cost: int
	- min_cost: int
	- cost: int (exacto)
	- min_attack: int
	- max_attack: int
	- min_defense: int
	- max_defense: int
	- has_keyword: String o Array[String]
	- name_contains: String
	- in_zone: int (Constants.Zone)
	- controller: int (player_id)
	- custom: Callable(card) -> bool
	"""
	if filter.is_empty():
		return true

	# Tipo de carta (ej: solo Aliados)
	if filter.has("card_type"):
		var ct = card.card_type if card.get("card_type") != null else -1
		if ct != filter.card_type:
			return false

	# Raza (ej: solo Humanos)
	if filter.has("card_race"):
		var race = card.card_race if card.get("card_race") != null else ""
		if race.to_lower() != filter.card_race.to_lower():
			return false

	# Clase (ej: solo Guerreros)
	if filter.has("card_class"):
		var cls = card.card_class if card.get("card_class") != null else ""
		if cls.to_lower() != filter.card_class.to_lower():
			return false

	# Coste máximo
	if filter.has("max_cost"):
		var cost = card.card_cost if card.get("card_cost") != null else 0
		if cost > filter.max_cost:
			return false

	# Coste mínimo
	if filter.has("min_cost"):
		var cost = card.card_cost if card.get("card_cost") != null else 0
		if cost < filter.min_cost:
			return false

	# Coste exacto
	if filter.has("cost"):
		var cost = card.card_cost if card.get("card_cost") != null else 0
		if cost != filter.cost:
			return false

	# Ataque mínimo
	if filter.has("min_attack"):
		var atk = card.card_attack if card.get("card_attack") != null else 0
		if atk < filter.min_attack:
			return false

	# Ataque máximo
	if filter.has("max_attack"):
		var atk = card.card_attack if card.get("card_attack") != null else 0
		if atk > filter.max_attack:
			return false

	# Defensa mínima
	if filter.has("min_defense"):
		var def = card.card_defense if card.get("card_defense") != null else 0
		if def < filter.min_defense:
			return false

	# Defensa máxima
	if filter.has("max_defense"):
		var def = card.card_defense if card.get("card_defense") != null else 0
		if def > filter.max_defense:
			return false

	# Tiene keyword específica
	if filter.has("has_keyword"):
		var required_keywords = filter.has_keyword
		if required_keywords is String:
			required_keywords = [required_keywords]

		var has_all = true
		for kw in required_keywords:
			if card.has_method("has_keyword"):
				if not card.has_keyword(kw):
					has_all = false
					break
			elif card.get("keywords"):
				if kw not in card.keywords:
					has_all = false
					break
			else:
				has_all = false
				break

		if not has_all:
			return false

	# Nombre contiene texto
	if filter.has("name_contains"):
		var card_name = card.card_name if card.get("card_name") else ""
		if filter.name_contains.to_lower() not in card_name.to_lower():
			return false

	# Está en zona específica
	if filter.has("in_zone"):
		var zone = card.current_zone if card.get("current_zone") != null else -1
		if zone != filter.in_zone:
			return false

	# Controlada por jugador específico
	if filter.has("controller"):
		var ctrl = card.controller_id if card.get("controller_id") != null else -1
		if ctrl != filter.controller:
			return false

	# Filtro personalizado (Callable)
	if filter.has("custom"):
		var custom_fn: Callable = filter.custom
		if custom_fn.is_valid():
			if not custom_fn.call(card):
				return false

	return true


func matches_required_type(card: Node) -> bool:
	"""Verifica si la carta coincide con el tipo requerido por el filtro

	DAR Sección 1.D: Solo cartas del tipo correcto pueden ser seleccionadas
	"""
	if not _main.selection_filter.has("card_type"):
		return true  # Sin filtro de tipo, todas coinciden

	var required_type = _main.selection_filter.card_type
	var card_type = card.card_type if card.get("card_type") != null else -1

	return card_type == required_type


func all_selected_pass_filter() -> bool:
	"""Verifica que todas las cartas seleccionadas cumplan el filtro"""
	if _main.selection_filter.is_empty():
		return true

	for card in _main.selected_cards:
		if not card_passes_filter(card, _main.selection_filter):
			return false

	return true


func show_validation_error(card: Node) -> void:
	"""Muestra mensaje de error cuando una carta no cumple el filtro"""
	var card_name = card.card_name if card.get("card_name") else "Esta carta"
	_main.validation_error = generate_filter_error_message(card)

	print("[SelectionCanvas] Validación fallida: %s" % _main.validation_error)

	# Mostrar en UI si hay label de instrucciones
	if _main.instruction_label:
		_main.instruction_label.text = _main.validation_error
		_main.instruction_label.modulate = Color(1, 0.5, 0.5, 1)  # Rojo suave

		# Restaurar después de un tiempo
		await _main.get_tree().create_timer(2.0).timeout
		if _main.instruction_label:
			_main.instruction_label.modulate = Color(1, 1, 1, 1)
			_main._setup_ui_for_mode(_main.current_mode, _main.amount_to_select)


func generate_filter_error_message(card: Node) -> String:
	"""Genera mensaje descriptivo de por qué la carta no cumple el filtro"""
	var reasons: Array = []
	var selection_filter = _main.selection_filter

	if selection_filter.has("card_type"):
		var required_type = Constants.CARD_TYPE_NAMES.get(selection_filter.card_type, "tipo requerido")
		var actual_type = Constants.CARD_TYPE_NAMES.get(card.card_type, "desconocido") if card.get("card_type") != null else "desconocido"
		if card.get("card_type") != selection_filter.card_type:
			reasons.append("Debe ser %s (es %s)" % [required_type, actual_type])

	if selection_filter.has("card_race"):
		var actual_race = card.card_race if card.get("card_race") else "ninguna"
		if actual_race.to_lower() != selection_filter.card_race.to_lower():
			reasons.append("Debe ser raza %s" % selection_filter.card_race)

	if selection_filter.has("max_cost"):
		var cost = card.card_cost if card.get("card_cost") != null else 0
		if cost > selection_filter.max_cost:
			reasons.append("Coste máximo %d (tiene %d)" % [selection_filter.max_cost, cost])

	if selection_filter.has("min_attack"):
		var atk = card.card_attack if card.get("card_attack") != null else 0
		if atk < selection_filter.min_attack:
			reasons.append("Ataque mínimo %d" % selection_filter.min_attack)

	if reasons.is_empty():
		return "Esta carta no cumple los requisitos"

	return "No válida: " + ", ".join(reasons)


func update_validation_display() -> void:
	"""Actualiza la visualización de validación en las cartas"""
	if not _main.cards_container:
		return

	for child in _main.cards_container.get_children():
		var card = child.get_meta("card", null)
		if not card:
			continue

		var is_valid = card_passes_filter(card, _main.selection_filter)

		# Actualizar apariencia según validez
		if child is Button:
			if not is_valid and not _main.selection_filter.is_empty():
				# Carta inválida - atenuar
				child.modulate = Color(0.5, 0.5, 0.5, 0.7)
				child.disabled = true
				child.mouse_default_cursor_shape = Control.CURSOR_FORBIDDEN
			else:
				# Carta válida
				child.modulate = Color(1, 1, 1, 1)
				child.disabled = false
				child.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func get_filter_description() -> String:
	"""Genera descripción legible del filtro actual"""
	var selection_filter = _main.selection_filter
	if selection_filter.is_empty():
		return "Cualquier carta"

	var parts: Array = []

	if selection_filter.has("card_type"):
		parts.append(Constants.CARD_TYPE_NAMES.get(selection_filter.card_type, ""))

	if selection_filter.has("card_race"):
		parts.append("raza " + selection_filter.card_race)

	if selection_filter.has("max_cost"):
		parts.append("coste ≤%d" % selection_filter.max_cost)

	if selection_filter.has("min_attack"):
		parts.append("ataque ≥%d" % selection_filter.min_attack)

	if selection_filter.has("has_keyword"):
		var kws = selection_filter.has_keyword
		if kws is String:
			parts.append("con " + kws)
		else:
			parts.append("con " + ", ".join(kws))

	if parts.is_empty():
		return "Carta específica"

	return " ".join(parts)
