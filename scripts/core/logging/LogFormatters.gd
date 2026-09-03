extends RefCounted
class_name LogFormatters
## LogFormatters — Utilidades de formato BBCode y extracción de nombres de
## carta/zona/fase para el CombatLog. Opera sobre CombatLog via _main (para
## la const COLORS). Extraído de CombatLog.gd (Fase 4 de reestructuración).

var _main: Node


func setup(main: Node) -> void:
	_main = main


func format_card(card_name: String) -> String:
	"""Formatea nombre de carta con color dorado y negrita"""
	if card_name.is_empty() or card_name == "???":
		return "[color=#888888]carta desconocida[/color]"
	return "[b][color=#FFD700]%s[/color][/b]" % card_name


func format_card_with_origin(card_name: String, via_exhumar: bool = false) -> String:
	"""Formatea nombre de carta con prefijo de origen si aplica"""
	var display_name = card_name
	if via_exhumar:
		display_name = "[EXHUMAR] " + card_name

	return format_card(display_name)


func format_effect(text: String, effect_type: String = "") -> String:
	"""Formatea tipo de efecto con su color correspondiente"""
	var color = _main.COLORS.get(effect_type.to_lower(), "#FFFFFF")
	return "[color=%s]%s[/color]" % [color, text]


func format_player(player_id: int) -> String:
	"""Formatea nombre de jugador con color"""
	var color = _main.COLORS.player1 if player_id == 0 else _main.COLORS.player2
	var name = "Jugador 1" if player_id == 0 else "Jugador 2"
	return "[color=%s]%s[/color]" % [color, name]


func format_zone(zone_name: String) -> String:
	"""Formatea nombre de zona con color"""
	var zone_lower = zone_name.to_lower()
	var color = _main.COLORS.get(zone_lower, "#AAAAAA")

	var display_name = zone_name
	match zone_lower:
		"deck", "castillo": display_name = "Castillo"
		"hand", "mano": display_name = "Mano"
		"field", "campo": display_name = "Campo"
		"graveyard", "cemetery", "cementerio": display_name = "Cementerio"
		"exile", "destierro": display_name = "Destierro"

	return "[color=%s]%s[/color]" % [color, display_name]


func format_status(status: String, override_type: String = "") -> String:
	"""Formatea estado con color y símbolo"""
	var type_key = override_type if not override_type.is_empty() else status
	var color = _main.COLORS.get(type_key, "#FFFFFF")

	var symbol = ""
	match status.to_lower():
		"success": symbol = "✓"
		"failure": symbol = "✗"
		"warning": symbol = "⚠"
		"pasó": symbol = "⏭"

	var text = symbol + " " + status if not symbol.is_empty() else status
	return "[color=%s]%s[/color]" % [color, text]


func format_phase(phase_name: String) -> String:
	"""Formatea nombre de fase"""
	return "[color=%s][b]%s[/b][/color]" % [_main.COLORS.phase, phase_name.to_upper()]


func format_number(value: int, context: String = "") -> String:
	"""Formatea número con color según contexto"""
	var color = _main.COLORS.get(context, "#FFFFFF")
	return "[color=%s][b]%d[/b][/color]" % [color, value]


func format_timestamp() -> String:
	"""Formatea timestamp actual"""
	var time = Time.get_time_string_from_system()
	return "[color=#666666][%s][/color]" % time.substr(0, 5)


func get_card_name(card) -> String:
	"""Obtiene el nombre de una carta (Node o Dictionary)"""
	if card == null:
		return "???"

	if card is Dictionary:
		return card.get("name", card.get("nombre", "???"))

	if card is Node:
		if card.get("card_name"):
			return card.card_name
		if card.has_method("get_card_name"):
			return card.get_card_name()

	return "???"


func get_card_names(cards: Array) -> Array[String]:
	"""Obtiene nombres de múltiples cartas"""
	var names: Array[String] = []
	for card in cards:
		names.append(get_card_name(card))
	return names


func format_card_list(names: Array) -> String:
	"""Formatea lista de cartas"""
	if names.is_empty():
		return "[color=#888888]ninguna[/color]"

	var formatted: Array[String] = []
	for name in names:
		formatted.append(format_card(name))

	return ", ".join(formatted)


func zone_to_string(zone: int) -> String:
	"""Convierte enum de zona a string"""
	match zone:
		Constants.Zone.CASTILLO: return "castillo"
		Constants.Zone.MANO: return "mano"
		Constants.Zone.CEMENTERIO: return "cementerio"
		Constants.Zone.DESTIERRO: return "destierro"
		Constants.Zone.LINEA_ATAQUE: return "línea de ataque"
		Constants.Zone.LINEA_DEFENSA: return "línea de defensa"
		Constants.Zone.LINEA_APOYO: return "línea de apoyo"
		Constants.Zone.RESERVA_ORO: return "reserva de oro"
		Constants.Zone.ORO_PAGADO: return "oro pagado"
		_: return "zona desconocida"


func phase_to_string(phase: int) -> String:
	"""Convierte enum de fase a string usando Constants.PHASE_NAMES"""
	# Intentar usar Constants.PHASE_NAMES
	if Constants and Constants.get("PHASE_NAMES"):
		return Constants.PHASE_NAMES.get(phase, "Fase %d" % phase)

	# Fallback usando Constants.Phase enum
	match phase:
		Constants.Phase.AGRUPACION: return "Agrupación"
		Constants.Phase.VIGILIA: return "Vigilia"
		Constants.Phase.ATAQUE: return "Ataque"
		Constants.Phase.BLOQUEO: return "Bloqueo"
		Constants.Phase.GUERRA_TALISMANES: return "Guerra de Talismanes"
		Constants.Phase.ASIGNACION_DANIO: return "Asignación de Daño"
		Constants.Phase.FINAL: return "Final"
		_: return "Fase %d" % phase


func strip_bbcode(text: String) -> String:
	"""Remueve tags BBCode para texto plano"""
	var regex = RegEx.new()
	regex.compile("\\[.*?\\]")
	return regex.sub(text, "", true)
