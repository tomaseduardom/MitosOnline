extends RefCounted
class_name PaymentValidation
## PaymentValidation — Consultas de solo-lectura para el pago: validación de
## cartas Únicas (DAR Sección 4.1) y disponibilidad de Oro/Cementerio del
## jugador. Ninguna de estas funciones toca el estado de pago en curso
## (_current_card/_payment_popup/etc. se quedan en PaymentManager — están
## entrelazados con ExhumarSystem.gd/XCostSelector.gd como estado compartido,
## sacarlos de ahí sería mucho más riesgo para poco beneficio). Opera sobre
## PaymentManager via _main.
## Extraído de PaymentManager.gd (2026-08-28, "módulos gordos" — mismo corte
## que ya separó ExhumarSystem/CostModifiers/XCostSelector).

var _main: Node


func setup(main: Node) -> void:
	_main = main


# =============================================================================
# VALIDACIÓN DE CARTAS ÚNICAS (DAR Sección 4.1)
# =============================================================================
func _card_is_unique(card_data: Dictionary) -> bool:
	"""Verifica si una carta tiene el trait 'Única'"""
	# Verificar trait directo
	var traits = card_data.get("traits", {})
	if traits.get("is_unique", false):
		return true

	# Verificar keywords
	var keywords = card_data.get("keywords", [])
	for kw in keywords:
		if kw is String and kw.to_upper() == "UNICA":
			return true
		if kw is String and kw.to_upper() == "ÚNICA":
			return true
		if kw is int and kw == Constants.Keyword.UNICA:
			return true

	# Verificar texto de habilidad
	var ability = str(card_data.get("habilidad", card_data.get("ability", "")))
	if "única" in ability.to_lower():
		return true

	return false


func _validate_unique_card(card_data: Dictionary, player_id: int) -> Dictionary:
	"""Valida si una carta Única puede ser jugada

	Bloquea el pago si ya existe una copia en:
	- Campo de Juego (Línea de Defensa, Ataque, Apoyo)
	- Pila de resolución

	Returns:
		{can_play: bool, reason: String}
	"""
	var card_name = card_data.get("nombre", card_data.get("name", ""))

	# Verificar en Campo de Juego
	var in_play = _check_unique_in_play(card_name, player_id)
	if in_play.found:
		return {
			"can_play": false,
			"reason": "ÚNICA: Ya hay una copia en %s" % in_play.zone_name
		}

	# Verificar en Pila de Resolución
	var in_stack = _check_unique_in_stack(card_name)
	if in_stack.found:
		return {
			"can_play": false,
			"reason": "ÚNICA: Ya hay una copia en la Pila de Efectos"
		}

	return {"can_play": true, "reason": ""}


func _check_unique_in_play(card_name: String, player_id: int) -> Dictionary:
	"""Busca si existe una copia de la carta en el campo de juego. El campo
	real es un único contenedor por jugador (no hay zonas separadas de
	Defensa/Ataque/Apoyo), así que se revisa una sola vez."""
	var result = {"found": false, "zone_name": "", "card": null}

	for card in _get_cards_in_zone(player_id, -1):
		var existing_name = card.get("card_name") if card.get("card_name") != null else ""
		if existing_name.to_lower() == card_name.to_lower():
			result.found = true
			result.zone_name = "el campo de juego"
			result.card = card
			return result

	return result


func _check_unique_in_stack(card_name: String) -> Dictionary:
	"""Busca si existe una copia de la carta en la pila de resolución"""
	var result = {"found": false, "stack_id": -1}

	if not ActionPipeline.has_method("get_stack"):
		return result

	var stack = ActionPipeline.get_stack()
	for stack_obj in stack:
		var obj_name = stack_obj.get("name", "")
		var card_data = stack_obj.get("card_data", {})
		var card_nombre = card_data.get("nombre", card_data.get("name", ""))

		if obj_name.to_lower() == card_name.to_lower() or card_nombre.to_lower() == card_name.to_lower():
			result.found = true
			result.stack_id = stack_obj.get("id", -1)
			return result

	return result


func _get_cards_in_zone(player_id: int, _zone: int) -> Array:
	"""Obtiene las cartas en juego (campo) de un jugador. Antes buscaba
	métodos que no existen en GameManager (get_zone_cards/get_cards_in_zone)
	y como fallback un '_game_board' que tampoco existe — siempre devolvía
	[], así que la validación de la palabra clave Única jamás encontraba
	una copia ya en juego. Se ignora el parámetro de zona: agrega las 3
	líneas reales (Defensa/Ataque/Apoyo, consolidación 2026-08-20) — Única
	puede aplicar a cualquier tipo de carta en juego."""
	var main = _main.get_node_or_null("/root/Main")
	if not main:
		return []
	var fields = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo] if player_id == 0 \
		else [main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]
	var cards: Array = []
	for field in fields:
		if field:
			cards.append_array(field.get_children())
	return cards


func _get_player_cemetery(player_id: int) -> Array:
	"""Obtiene las cartas en el cementerio del jugador"""
	if GameManager.has_method("get_zone_cards"):
		return GameManager.get_zone_cards(player_id, Constants.Zone.CEMENTERIO)

	if GameManager.has_method("get_cemetery"):
		return GameManager.get_cemetery(player_id)

	# Fallback: buscar en estructura de zonas
	var zones = GameManager.get("_zones")
	if zones and zones.has(player_id):
		var player_zones = zones[player_id]
		if player_zones.has(Constants.Zone.CEMENTERIO):
			return player_zones[Constants.Zone.CEMENTERIO]

	return []


func _get_player_available_gold(player_id: int) -> int:
	"""Obtiene el Oro disponible del jugador"""
	if GameManager.has_method("get_available_gold"):
		return GameManager.get_available_gold(player_id)

	if GameManager.has_method("get_player_gold"):
		return GameManager.get_player_gold(player_id)

	# Fallback
	var gold_reserve = GameManager.get("_gold_reserves")
	if gold_reserve and gold_reserve.has(player_id):
		return gold_reserve[player_id]

	return 0
