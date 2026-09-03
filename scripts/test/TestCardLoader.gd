extends RefCounted
class_name TestCardLoader
## TestCardLoader — Utilidades sin estado para cargar/filtrar cartas en el escenario de pruebas.
## Extraído de TestScene.gd (Fase 4 de reestructuración).

static func load_card_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("[TestCardLoader] Archivo no encontrado: %s" % path)
		return {}

	var file = FileAccess.open(path, FileAccess.READ)
	var json_text = file.get_as_text()
	file.close()

	var json = JSON.new()
	var error = json.parse(json_text)

	if error != OK:
		push_warning("[TestCardLoader] JSON inválido: %s" % json.get_error_message())
		return {}

	return json.data


static func find_json_files(path: String) -> Array:
	var files: Array = []
	var dir = DirAccess.open(path)

	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if file_name.ends_with(".json"):
				files.append(path.path_join(file_name))
			file_name = dir.get_next()
		dir.list_dir_end()

	return files


static func card_matches_filter(card: Dictionary, filter: Dictionary) -> bool:
	"""Verifica si una carta coincide con un filtro"""
	if filter.is_empty():
		return true

	# Filtro exclude_type
	if filter.has("exclude_type"):
		var card_type = card.get("type", card.get("tipo", ""))
		var exclude = filter.exclude_type

		# Normalizar card_type a String para comparación
		var card_type_str: String = ""
		if card_type is int:
			match card_type:
				Constants.CardType.TALISMAN: card_type_str = "Talisman"
				Constants.CardType.ALIADO: card_type_str = "Aliado"
				Constants.CardType.ARMA: card_type_str = "Arma"
				Constants.CardType.TOTEM: card_type_str = "Totem"
				Constants.CardType.ORO: card_type_str = "Oro"
		else:
			card_type_str = str(card_type)

		# Comparar como strings (case insensitive)
		if card_type_str.to_lower() == str(exclude).to_lower():
			return false

	return true


static func map_type(type_val) -> int:
	if type_val is int:
		return type_val
	match str(type_val).to_lower():
		"talisman", "talismán": return Constants.CardType.TALISMAN
		"aliado", "ally": return Constants.CardType.ALIADO
		"arma", "weapon": return Constants.CardType.ARMA
		"totem", "tótem": return Constants.CardType.TOTEM
		"oro", "gold": return Constants.CardType.ORO
	return Constants.CardType.ALIADO
