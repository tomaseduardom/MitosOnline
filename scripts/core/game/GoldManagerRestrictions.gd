extends RefCounted
## GoldManagerRestrictions — Elegibilidad para jugar una carta: Errante ('solo
## una copia en juego'), 'Sólo puedes jugar un <Nombre> por turno', Talismanes
## de respuesta instantánea (Anula/Cancela — 'Red de Plata'/'Sacrificio
## Solar'), portadores de Arma disponibles, y las excepciones de fase (Arma/
## Talismán en Guerra de Talismanes, 'Lobo Sagrado'). Extraído de
## GoldManager.gd (2026-09-06, "módulos gordos", Fase 3) — confirmado por grep
## de todo scripts/ que _get_eligible_weapon_wielders() (CardManager.gd),
## _player_has_ally_in_play() (LookRevealPatterns.gd, DropZone.gd),
## _is_response_only_talisman()/has_phase_exception()/get_phase_rejection_
## reason() (CardInteractionModule.gd, DropZone.gd) tienen llamadores reales
## fuera de GoldManager.gd — GoldManager.gd sigue exponiendo esas cinco bajo
## el mismo nombre como forwarder de una sola línea (junto con
## _errante_violation/_play_limit_violation/_register_play_limit/
## _is_response_only_talisman_data, que solo tienen llamadores internos
## propios en play_card()/play_card_from_exile()/play_card_from_cemetery()).
## El resto (_has_play_limit_phrase, _is_response_only_ability_text,
## _ally_weapon_count, _max_weapons_per_ally,
## _can_play_weapons_in_guerra_talismanes) no tiene ningún llamador fuera de
## este mismo módulo, así que no necesita forwarder.
##
## _main es Main (mismo significado que en el resto de GoldManager.gd) — el
## único estado propio de GoldManager que este módulo necesita
## (_fix_mojibake()) se alcanza vía _main._gold_manager, el back-reference
## que Main.gd ya mantiene hacia su propia instancia de GoldManager (mismo
## patrón que ya usan CardInteractionModule/DropZone/CardManager/
## LookRevealPatterns para llamar a GoldManager desde afuera).

var _main: Node = null


func setup(main: Node) -> void:
	_main = main


func _errante_violation(card: Node) -> bool:
	"""Errante (keyword real de Mitos y Leyendas, corrección 2026-08-20):
	solo puede haber una copia de esta carta en juego a la vez, sin importar
	el controlador. Distinto de Única, que limita copias en el MAZO."""
	if not KeywordManager.has_keyword(card, Constants.Keyword.ERRANTE):
		return false
	var card_name: String = card.card_name if card.get("card_name") != null else ""
	if card_name.is_empty():
		return false
	for field in [_main.player_field, _main.player_linea_ataque, _main.player_linea_apoyo, _main.opponent_field, _main.opponent_linea_ataque, _main.opponent_linea_apoyo]:
		if not field:
			continue
		for existing in field.get_children():
			if existing != card and existing.get("card_name") == card_name:
				return true
	return false


func _play_limit_violation(card: Node) -> bool:
	"""'Sólo puedes jugar un <Nombre> por turno' (2026-08-30, p.ej. Aaru) —
	restricción de JUGAR la carta en sí (distinta de 'una vez por turno'
	sobre una habilidad ACTIVADA), por NOMBRE y compartida entre todas las
	copias: si ya jugaste un <Nombre> este turno, no puedes jugar un segundo
	aunque sea una copia distinta. Se registra en UniversalCardParser.
	turn_registry con un prefijo propio ('play_limit:') para no compartir
	namespace con el registro de habilidades ACTIVADAS (card_id/ability_index
	numéricos)."""
	var habilidad: String = card.get("card_ability") if card.get("card_ability") != null else ""
	var lower := habilidad.to_lower()
	if not _has_play_limit_phrase(lower):
		return false
	var card_name: String = card.card_name if card.get("card_name") != null else ""
	if card_name.is_empty():
		return false
	var name_key: String = "play_limit:%s" % card_name.to_lower()
	return UniversalCardParser.turn_registry.was_used(name_key, 0, GameManager.current_turn)


func _has_play_limit_phrase(lower: String) -> bool:
	"""'Sólo puedes jugar un <Nombre> por turno' (p.ej. Aaru), su variante
	en voz pasiva 'Sólo puede ser puesto en juego un <Nombre> por turno'
	(2026-09-04, p.ej. La Torre), o la negativa 'no puedes poner en juego
	más de un <Nombre> por turno' (2026-09-04, p.ej. rafael) — mismo
	concepto DAR, tres formas de imprimirlo."""
	if "por turno" not in lower:
		return false
	return "solo puedes jugar un" in lower or "sólo puedes jugar un" in lower \
		or "solo puede ser puesto en juego un" in lower or "sólo puede ser puesto en juego un" in lower \
		or "no puedes poner en juego más de un" in lower


func _register_play_limit(card: Node) -> void:
	"""Registra el uso del cupo de 'Sólo puedes jugar un <Nombre> por turno'
	(ver _play_limit_violation()) — llamar solo cuando el juego de la carta
	ya está garantizado (después de todas las validaciones, justo antes de
	colocarla), para no gastar el cupo en un intento que después se cancela
	(sin Oro suficiente, portador cancelado, etc.)."""
	var habilidad: String = card.get("card_ability") if card.get("card_ability") != null else ""
	var lower := habilidad.to_lower()
	if not _has_play_limit_phrase(lower):
		return
	var card_name: String = card.card_name if card.get("card_name") != null else ""
	if card_name.is_empty():
		return
	var name_key: String = "play_limit:%s" % card_name.to_lower()
	UniversalCardParser.turn_registry.register(name_key, 0, GameManager.current_turn)


func _is_response_only_talisman(card: Node) -> bool:
	"""Detecta Talismanes de velocidad instantánea (DAR): 'Anula un Aliado o
	Tótem...' / 'Anula o cancela la habilidad de una carta...' (p.ej. Red de
	Plata, Sheut, Sacrificio Solar) o 'Puedes jugarlo en respuesta a que tu
	oponente...' explícito (p.ej. Transformación). Busca una ORACIÓN que
	EMPIECE con 'anula'/'cancela'/'puedes jugarlo en respuesta a' — no basta
	con 'anula' en cualquier parte del texto, porque frases de protección
	como 'no puede ser Anulada' o 'esta habilidad no puede ser cancelada'
	contienen la misma palabra pero son lo opuesto (protección de la propia
	carta, no su efecto)."""
	var ability_text: String = card.card_ability if card.get("card_ability") != null else ""
	return _is_response_only_ability_text(ability_text)


func _is_response_only_talisman_data(card_data: Dictionary) -> bool:
	"""Espejo de _is_response_only_talisman() para código que todavía opera
	sobre Dictionary en vez del Node Card (2026-09-06, p.ej.
	play_card_from_cemetery() antes de instanciar la carta) — misma
	detección, mismo criterio."""
	return _is_response_only_ability_text(str(card_data.get("habilidad", "")))


func _is_response_only_ability_text(ability_text: String) -> bool:
	if ability_text.is_empty():
		return false
	for raw_sentence in ability_text.split("."):
		var sentence: String = raw_sentence.strip_edges().to_lower()
		if sentence.begins_with("anula") or sentence.begins_with("cancela") \
				or sentence.begins_with("puedes jugarlo en respuesta a"):
			return true
	return false


func _player_has_ally_in_play() -> bool:
	"""Verifica si hay al menos un Aliado en juego (propio o rival, 2026-
	09-03) SIN Arma ya equipada (requisito para poder jugar un Arma — un
	Aliado solo porta una a la vez, y sin portador libre no tiene
	sentido). Antes solo miraba si había
	CUALQUIER Aliado, sin importar si ya portaba Arma — dejaba pasar a
	_select_weapon_wielder() con cero candidatos elegibles de verdad y esa
	selección se quedaba colgada para siempre (2026-08-28, bug reportado por
	el usuario: intentar jugar un Arma sin portador válido lo dejaba sin
	poder jugar más cartas)."""
	return not _get_eligible_weapon_wielders().is_empty()


func _get_eligible_weapon_wielders() -> Array:
	"""Aliados en juego (propios O RIVALES, 2026-09-03 — DAR no restringe a
	quién controlas: un Arma se puede portar en cualquier Aliado en juego,
	salvo que el propio texto de la carta lo diga) que todavía tienen
	espacio para portar un Arma más (normalmente 1, o más con 'Tus Aliados
	pueden portar un Arma adicional' en juego — ver _max_weapons_per_ally(),
	2026-08-31, Levisterio)."""
	var eligible: Array = []
	var max_weapons: int = _max_weapons_per_ally()
	for field in [_main.player_field, _main.player_linea_ataque, _main.opponent_field, _main.opponent_linea_ataque]:
		if not field:
			continue
		for card in field.get_children():
			if not is_instance_valid(card):
				continue
			if card.get("card_type") != Constants.CardType.ALIADO:
				continue
			if _ally_weapon_count(card) >= max_weapons:
				continue
			eligible.append(card)
	return eligible


func _ally_weapon_count(ally: Node) -> int:
	# equipped_weapons es la lista mantenida por _equip_weapon() — mismo
	# campo que ya usan BernardoAbilityHandler/CardManager/ActionModule, más
	# directo que volver a escanear get_children() a mano.
	var weapons = ally.get("equipped_weapons")
	return weapons.size() if weapons is Array else 0


func _max_weapons_per_ally() -> int:
	"""1 Arma por Aliado por defecto (DAR). +1 por cada carta propia en
	juego con 'Tus Aliados pueden portar un Arma adicional' (2026-08-31,
	Levisterio) — mismo patrón de escaneo por texto que
	_can_play_weapons_in_guerra_talismanes(), no es una Keyword fija
	(ver nota en Constants.gd)."""
	var extra: int = 0
	for field in [_main.player_field, _main.player_linea_ataque, _main.player_linea_apoyo]:
		if not field:
			continue
		for card in field.get_children():
			if not is_instance_valid(card):
				continue
			var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
			if ability_text.is_empty():
				continue
			var lower: String = _main._gold_manager._fix_mojibake(ability_text).to_lower()
			if "aliados pueden portar un arma adicional" in lower:
				extra += 1
	return 1 + extra


func _can_play_weapons_in_guerra_talismanes() -> bool:
	"""Detecta 'Puedes jugar Armas en Guerra de Talismanes' (p.ej. Lobo
	Sagrado) en el propio jugador (2026-08-28) — misma técnica de
	escaneo-de-texto que _register_talisman_totem_tax(), pero como chequeo
	de legalidad puntual en vez de un modificador registrado, porque aquí
	solo importa el instante de jugar el Arma, no algo que deba persistir."""
	for field in [_main.player_field, _main.player_linea_ataque, _main.player_linea_apoyo]:
		if not field:
			continue
		for card in field.get_children():
			if not is_instance_valid(card):
				continue
			var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
			if ability_text.is_empty():
				continue
			var lower: String = _main._gold_manager._fix_mojibake(ability_text).to_lower()
			if "jugar armas en guerra de talismanes" in lower:
				return true
	return false


func has_phase_exception(card_type: int) -> bool:
	"""Único punto de verdad para las excepciones de fase (Arma puntual tipo
	Lobo Sagrado + Talismanes en general en Guerra de Talismanes) — antes
	estaba duplicado inline en play_card()/play_card_from_cemetery(), y
	CardInteractionModule._on_card_double_clicked() tenía su PROPIO gateo de
	fase sin conocer esta excepción, así que nunca dejaba ni siquiera
	intentar jugar el Arma/Talismán (2026-08-28, bug reportado por el
	usuario: 'no puedo jugar armas en guerra'). Llamar esto desde cualquier
	punto que decida si una carta se puede jugar fuera de Vigilia."""
	if GameManager.current_phase != Constants.Phase.GUERRA_TALISMANES:
		return false
	if card_type == Constants.CardType.TALISMAN:
		return true
	if card_type == Constants.CardType.ARMA:
		return _can_play_weapons_in_guerra_talismanes()
	return false


func get_phase_rejection_reason(card_type: int) -> String:
	"""Mensaje específico de por qué ESTA carta no se puede jugar ahora mismo
	(2026-08-28, a pedido del usuario: el genérico 'Solo puedes jugar cartas
	en Vigilia' no decía si esa carta en particular sí tenía alguna
	excepción posible — un Talismán en Guerra de Talismanes normalmente SÍ
	se puede, un Aliado no puede nunca fuera de Vigilia). Llamar solo cuando
	ya se decidió rechazar (current_phase != VIGILIA and not
	has_phase_exception(card_type))."""
	var phase := GameManager.current_phase
	if phase == Constants.Phase.GUERRA_TALISMANES:
		match card_type:
			Constants.CardType.ARMA:
				return "Necesitas un efecto en juego (como Lobo Sagrado) para jugar Armas en Guerra de Talismanes"
			Constants.CardType.TALISMAN:
				return "Ese Talismán es de respuesta — solo se juega en respuesta a una carta o habilidad del oponente"
			_:
				return "En Guerra de Talismanes solo se pueden jugar Talismanes (y Armas, si algo lo permite)"
	return "Solo puedes jugar cartas en tu Vigilia o en Guerra de Talismanes (Talismanes/Armas habilitadas)"
