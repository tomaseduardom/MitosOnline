extends RefCounted
class_name KeywordQuery
## KeywordQuery — Consultas de keywords activas, protección y restricciones
## de combate (atacar/bloquear/ser objetivo) derivadas de los modificadores
## registrados. Opera sobre ContinuousEffectManager via _main.
## Extraído de ContinuousEffectManager.gd (Fase 4 de reestructuración).

var _main: Node


func setup(main: Node) -> void:
	_main = main


# =============================================================================
# KEYWORDS Y HABILIDADES
# =============================================================================
func get_active_keywords(card: Node) -> Array:
	"""Obtiene todas las keywords activas de una carta

	Incluye keywords base + agregadas por modificadores - removidas

	Args:
		card: Nodo de la carta

	Returns: Array de keywords activas
	"""
	var keywords: Array = []

	# Keywords base de la carta
	if card.get("keywords"):
		keywords = card.keywords.duplicate()
	elif card.get("base_keywords"):
		keywords = card.base_keywords.duplicate()

	# Obtener modificadores de keywords
	var applicable = _main._get_applicable_modifiers(card, "")

	for mod in applicable:
		if not _main._is_modifier_active(mod):
			continue

		if mod.type != _main.ModifierType.KEYWORDS:
			continue

		# Agregar keywords
		for kw in mod.keywords_add:
			if kw not in keywords:
				keywords.append(kw)

		# Remover keywords
		for kw in mod.keywords_remove:
			keywords.erase(kw)

	return keywords


func has_keyword(card: Node, keyword) -> bool:
	"""Verifica si una carta tiene una keyword activa

	Args:
		card: Nodo de la carta
		keyword: Keyword a verificar (int enum o String)

	Returns: true si tiene la keyword
	"""
	var active = get_active_keywords(card)

	for kw in active:
		if kw == keyword:
			return true
		# Comparar string con enum
		if kw is String and keyword is int:
			if kw.to_upper() == Constants.Keyword.keys()[keyword]:
				return true
		if kw is int and keyword is String:
			if Constants.Keyword.keys()[kw] == keyword.to_upper():
				return true

	return false


func has_protection(card: Node, protection_type: String = "") -> bool:
	"""Verifica si una carta tiene protección

	Args:
		card: Nodo de la carta
		protection_type: Tipo específico ("DESTROY", "BANISH", "TARGET", etc.)

	Returns: true si tiene protección
	"""
	# Verificar keyword INDESTRUCTIBLE
	if protection_type == "" or protection_type == "DESTROY":
		if has_keyword(card, Constants.Keyword.INDESTRUCTIBLE):
			return true

	# Verificar keyword INDESTERRABLE
	if protection_type == "" or protection_type == "BANISH":
		if has_keyword(card, Constants.Keyword.INDESTERRABLE):
			return true

	# Verificar modificadores de protección
	var applicable = _main._get_applicable_modifiers(card, "")

	for mod in applicable:
		if not _main._is_modifier_active(mod):
			continue

		if mod.type != _main.ModifierType.PROTECTION:
			continue

		# Verificar tipo de protección
		var prot_type = mod.get("protection_type", "ALL")
		if prot_type == "ALL" or prot_type == protection_type:
			return true

	return false


# =============================================================================
# RESTRICCIONES
# =============================================================================
func can_attack(card: Node) -> bool:
	"""Verifica si una carta puede atacar"""
	var applicable = _main._get_applicable_modifiers(card, "")

	for mod in applicable:
		if not _main._is_modifier_active(mod):
			continue

		if mod.type != _main.ModifierType.RESTRICTION:
			continue

		if mod.get("restriction_type") == "CANT_ATTACK":
			return false

	return true


func can_block(card: Node) -> bool:
	"""Verifica si una carta puede bloquear"""
	# Verificar IMBLOQUEABLE (esto afecta si puede SER bloqueada, no si puede bloquear)
	var applicable = _main._get_applicable_modifiers(card, "")

	for mod in applicable:
		if not _main._is_modifier_active(mod):
			continue

		if mod.type != _main.ModifierType.RESTRICTION:
			continue

		if mod.get("restriction_type") == "CANT_BLOCK":
			return false

	return true


func can_be_targeted(card: Node, source: Node = null) -> bool:
	"""Verifica si una carta puede ser objetivo de efectos

	Args:
		card: Carta que sería el objetivo
		source: Carta fuente del efecto (opcional)

	Returns: true si puede ser objetivo
	"""
	var applicable = _main._get_applicable_modifiers(card, "")

	for mod in applicable:
		if not _main._is_modifier_active(mod):
			continue

		if mod.type != _main.ModifierType.PROTECTION:
			continue

		var prot_type = mod.get("protection_type", "")
		if prot_type == "TARGET" or prot_type == "HEXPROOF":
			# Verificar si la fuente es del mismo controlador
			if source and card:
				var card_owner = card.get("controller_id") if card.get("controller_id") != null else card.get("owner_id") if card.get("owner_id") != null else -1
				var source_owner = source.get("controller_id") if source.get("controller_id") != null else source.get("owner_id") if source.get("owner_id") != null else -1
				if card_owner == source_owner:
					continue  # Hexproof no protege de tus propios efectos

			return false

	return true
