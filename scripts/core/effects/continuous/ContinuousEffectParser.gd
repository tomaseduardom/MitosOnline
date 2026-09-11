extends RefCounted
class_name ContinuousEffectParser
## ContinuousEffectParser — Lee el texto de habilidad impreso de una carta que
## entra en juego y registra los modificadores continuos correspondientes
## (auras "Tus Aliados...", inmunidades de silencio, autoimpuestos de coste,
## etc). Opera sobre ContinuousEffectManager via _main. Extraído de
## ContinuousEffectManager.gd (Fase 4 de reestructuración).

var _main: Node


func setup(main: Node) -> void:
	_main = main


func _register_card_continuous_effects(card: Node) -> void:
	"""Registra los efectos continuos de una carta al entrar en juego

	Lee la habilidad de la carta y registra modificadores apropiados.
	"""
	if card == null:
		return

	# 2026-08-25: antes leía card.get_meta("card_data", {}) — metadata de
	# Godot que NUNCA se asigna en el juego real (solo en TestScene.gd, una
	# escena de prueba vieja). Siempre volvía {}, así que ability_text
	# siempre estaba vacío y este detector nunca encontraba nada, para
	# ninguna carta — confirmado con Patria Vieja, que no aplicaba su aura
	# a pesar de tener el patrón ya soportado.
	var ability_text: String = card.card_ability if card.get("card_ability") != null else ""
	if ability_text.is_empty():
		var card_data = card.get("card_data") if card.get("card_data") != null else {}
		if card_data is Dictionary:
			ability_text = card_data.get("ability", card_data.get("habilidad", ""))

	# Detectar efectos continuos en el texto
	_parse_and_register_continuous_effects(card, ability_text)


func _parse_and_register_continuous_effects(card: Node, ability_text: String) -> void:
	"""Parsea el texto de habilidad y registra efectos continuos"""
	if ability_text.is_empty():
		return

	var text = ability_text.to_lower()

	# 'Hace doble daño de combate al Destierro' EN PRIMERA PERSONA/pasiva
	# propia (2026-09-04, p.ej. manuel rodriguez: 'Furia. Hace doble daño
	# de combate al Destierro.') — flag propio de la carta, consultado por
	# BattleManager durante ASIGNACION_DANIO. Excluye la variante delegada
	# a un Aliado ELEGIDO por una activada ('Una vez por turno, un Aliado
	# hace doble daño...', p.ej. atenea en wonderland) — esa NO es
	# autoaplicación, se resuelve aparte como target puntual temporal (ver
	# CardInspectionLayer/PreventionAbilityHandler), todavía sin
	# implementar para ese caso.
	if "hace doble daño de combate al destierro" in text and "un aliado hace doble daño" not in text \
			and card.get("doubles_damage_to_exile") != null:
		card.doubles_damage_to_exile = true

	# Detectar buffs a aliados: "Tus aliados obtienen +X/+X"
	var ally_buff_regex = RegEx.new()
	ally_buff_regex.compile("(?:tus |los )?(aliados|criaturas).+obtienen?\\s*\\+(\\d+)")
	var ally_match = ally_buff_regex.search(text)

	if ally_match:
		var buff_value = int(ally_match.get_string(2))
		_main.register_modifier({
			"source": card,
			"target": "ALLIES",
			"type": _main.ModifierType.STRENGTH,
			"stat": "strength",
			"value": buff_value,
			"operation": "add",
			"duration": _main.ModifierDuration.PERMANENT,
			"layer": _main.ModifierLayer.LAYER_7B_CHAR_MODIFY,
			"description": "Buff a aliados +%d" % buff_value
		})

	# Detectar buffs a aliados con calificador de coste, forma "ganan N de
	# Fuerza" (2026-08-24, p.ej. Patria Vieja: "Tus Aliados de coste 1 o más
	# ganan 1 de Fuerza") — distinto del patrón de arriba, que solo cubre
	# "obtienen +N" sin calificador de coste.
	# "(?:que controlas)?" agregado (2026-08-30, p.ej. Sable de Napoleón:
	# "Los Aliados que controlas ganan 1 de Fuerza") — antes exigía "aliados"
	# seguido DIRECTO de "ganan" (salvo el calificador de coste), así que
	# "que controlas" en el medio rompía el match y esta variante quedaba
	# sin ningún patrón que la reconociera.
	# "Tus Aliados Titán ganan 1 de Fuerza" (2026-09-06, p.ej. Cuerno de
	# Titán) — calificador de RAZA en vez de coste, patrón separado a
	# propósito para no reordenar los grupos de captura de
	# qualified_buff_regex (varios llamadores de abajo dependen de que el
	# grupo 1 sea el coste mínimo).
	var race_qualified_buff_regex = RegEx.new()
	race_qualified_buff_regex.compile("(?:tus |los )?aliados (titán|titan|ignis) ganan?\\s*(\\d+)\\s*de fuerza")
	var race_qualified_match = race_qualified_buff_regex.search(text)
	if race_qualified_match:
		var race_word := race_qualified_match.get_string(1).to_lower().replace("titan", "titán")
		var race_value := int(race_qualified_match.get_string(2))
		_main.register_modifier({
			"source": card,
			"target": "ALLIES",
			"type": _main.ModifierType.STRENGTH,
			"stat": "strength",
			"value": race_value,
			"operation": "add",
			"duration": _main.ModifierDuration.PERMANENT,
			"layer": _main.ModifierLayer.LAYER_7B_CHAR_MODIFY,
			"filter": {"raza": race_word},
			"description": "Buff a Aliados %s +%d" % [race_word.capitalize(), race_value]
		})

	var qualified_buff_regex = RegEx.new()
	qualified_buff_regex.compile("(?:tus |los )?aliados(?:\\s+de coste\\s+(\\d+)\\s+o\\s+m[aá]s)?(?:\\s+que controlas)?\\s+ganan?\\s*(\\d+)\\s*de fuerza")
	var qualified_match = qualified_buff_regex.search(text)

	if qualified_match:
		var min_cost_str := qualified_match.get_string(1)
		var qualified_value := int(qualified_match.get_string(2))
		var qualified_filter: Dictionary = {}
		if not min_cost_str.is_empty():
			qualified_filter["min_cost"] = int(min_cost_str)

		# "Si controlas N o más Aliados de la misma Raza" (2026-09-03, p.ej.
		# Trono del Dragón: 'Si controlas tres o más Aliados de la misma
		# Raza, tus Aliados ganan 1 de Fuerza...') — qualified_buff_regex
		# de arriba NO ve este prefijo condicional: matchea sobre la
		# SEGUNDA mención de 'Aliados' (la del propio buff, 'tus Aliados
		# ganan'), ignorando la condición racial que la antecede. Sin este
		# chequeo, el buff se registraría PERMANENT incondicional. Acá se
		# detecta aparte y, si está presente, el modificador pasa a
		# CONDITIONAL con un Callable que recuenta por Raza en cada
		# consulta (_is_modifier_active() lo reevalúa siempre, nunca
		# cachea el resultado) — a diferencia de PERMANENT, CONDITIONAL no
		# chequea solo que la fuente siga en juego, así que el propio
		# Callable lo verifica también.
		var same_race_rx := RegEx.new()
		same_race_rx.compile("si controlas\\s+(\\w+)\\s+o\\s+m[aá]s\\s+aliados\\s+de\\s+la\\s+misma\\s+raza")
		var race_cond_match := same_race_rx.search(text)
		var buff_duration: int = _main.ModifierDuration.PERMANENT
		var buff_condition: Callable = Callable()
		if race_cond_match:
			var race_threshold: int = UniversalCardParser._parse_amount(race_cond_match.get_string(1))
			var race_controller_id: int = _main._get_card_owner(card)
			buff_condition = func() -> bool:
				return is_instance_valid(card) and _main._is_card_in_play(card) \
					and _main._controls_n_allies_of_same_race(race_controller_id, race_threshold)
			buff_duration = _main.ModifierDuration.CONDITIONAL

		_main.register_modifier({
			"source": card,
			"target": "ALLIES",
			"type": _main.ModifierType.STRENGTH,
			"stat": "strength",
			"value": qualified_value,
			"operation": "add",
			"duration": buff_duration,
			"condition": buff_condition,
			"layer": _main.ModifierLayer.LAYER_7B_CHAR_MODIFY,
			"filter": qualified_filter,
			"description": "Buff a aliados +%d%s" % [
				qualified_value,
				(" (coste %d o más)" % qualified_filter.min_cost) if qualified_filter.has("min_cost") else ""
			]
		})

		# Cláusula adicional: "...y no pueden ser afectados por habilidades
		# de cartas fuera del juego mientras atacan" (2026-09-03, Trono del
		# Dragón) — el recorte 'mientras atacan' es POR ALIADO puntual (no
		# tiene sentido en el condition Callable de arriba, que no recibe
		# la carta objetivo), así que solo se registra la mitad 'racial' acá
		# (protection_type OFF_BOARD_WHILE_ATTACKING) y el chequeo real de
		# 'está atacando ahora' vive en el punto de consulta
		# (TargetedEffectExecutor._select_ally_target(), igual que la
		# inmunidad a Talismanes de Kotaix más abajo).
		if race_cond_match and "no pueden ser afectados por habilidades de cartas fuera del juego" in text:
			_main.register_modifier({
				"source": card,
				"target": "ALLIES",
				"type": _main.ModifierType.PROTECTION,
				"stat": "",
				"value": 0,
				"operation": "add",
				"duration": buff_duration,
				"condition": buff_condition,
				"layer": _main.ModifierLayer.LAYER_6_ABILITIES,
				"filter": qualified_filter,
				"protection_type": "OFF_BOARD_WHILE_ATTACKING",
				"description": "Inmune a cartas fuera del juego mientras ataca (Trono del Dragón)"
			})

		# Cláusula adicional: "...y no son Destruidos cuando bloquean"
		# (p.ej. Patria Vieja) — protección acotada SOLO a destrucción por
		# perder un combate bloqueando (BattleManager la consulta con
		# protection_type "BLOCK_DESTROY"), no protección general.
		if "no son destruid" in text and "bloquean" in text:
			_main.register_modifier({
				"source": card,
				"target": "ALLIES",
				"type": _main.ModifierType.PROTECTION,
				"stat": "",
				"value": 0,
				"operation": "add",
				"duration": _main.ModifierDuration.PERMANENT,
				"layer": _main.ModifierLayer.LAYER_6_ABILITIES,
				"filter": qualified_filter,
				"protection_type": "BLOCK_DESTROY",
				"description": "No son destruidos cuando bloquean"
			})

		# Cláusula adicional: "...y no pueden perder su habilidad" SIN
		# calificador de Arma (2026-09-04, p.ej. Abu Simbel: "Tus Aliados
		# ganan 1 de Fuerza y no pueden perder su habilidad") — a diferencia
		# de "Aliados que porten Arma no pueden perder su habilidad" (Manuel
		# Bulnes, ya cubierto por register_weapon_wielder_silence_immunity()
		# en otra parte de este mismo archivo), esta protege a TODOS los
		# Aliados del controlador, consultada desde KeywordManager.silence_
		# card() vía register_all_allies_silence_immunity().
		if "no pueden perder su habilidad" in text and "porten arma" not in text:
			KeywordManager.register_all_allies_silence_immunity(card)

		# Cláusula adicional: "...Furia..." en la misma oración (2026-09-02,
		# p.ej. Espíritu Kotaix: "Tus Aliados ganan 2 de Fuerza, Furia y no
		# pueden ser afectados por Talismanes") — mismo criterio que la
		# cláusula de BLOCK_DESTROY de arriba, pero para el patrón de
		# keyword_regex más abajo (que exige 'tienen', no matchea 'ganan...
		# Furia' en lista separada por comas).
		if "furia" in text:
			_main.register_modifier({
				"source": card,
				"target": "ALLIES",
				"type": _main.ModifierType.KEYWORDS,
				"stat": "",
				"value": 0,
				"operation": "add",
				"duration": _main.ModifierDuration.PERMANENT,
				"layer": _main.ModifierLayer.LAYER_6_ABILITIES,
				"filter": qualified_filter,
				"keywords_add": [Constants.Keyword.FURIA],
				"description": "Otorga Furia a aliados"
			})

		# Cláusula adicional: "...no pueden ser afectados por Talismanes"
		# (2026-09-02, Espíritu Kotaix) — protección otorgada a OTRAS cartas
		# (a diferencia de Constants.gd/TargetedEffectExecutor._target_text_denies(),
		# que solo detecta cuando una carta se protege a SÍ MISMA con su
		# propio texto impreso). ContinuousEffectManager.has_protection(card,
		# "TALISMAN") es la consulta; TargetedEffectExecutor._select_ally_target()
		# la respeta cuando source_card es un Talismán.
		if "no pueden ser afectados por talismanes" in text or "no puede ser afectado por talismanes" in text:
			_main.register_modifier({
				"source": card,
				"target": "ALLIES",
				"type": _main.ModifierType.PROTECTION,
				"stat": "",
				"value": 0,
				"operation": "add",
				"duration": _main.ModifierDuration.PERMANENT,
				"layer": _main.ModifierLayer.LAYER_6_ABILITIES,
				"filter": qualified_filter,
				"protection_type": "TALISMAN",
				"description": "Inmune a Talismanes"
			})

	# Cláusula independiente (fuera del bloque qualified_match, no exige
	# "ganan N de Fuerza" en la misma oración): "En tu turno, tus Aliados no
	# pueden ser afectados por Talismanes oponentes" (2026-09-04, Aurora de
	# Chile) — protección de Talismanes acotada SOLO al turno del propio
	# controlador, vía duration CONDITIONAL (a diferencia de la protección
	# permanente de Espíritu Kotaix de más arriba).
	if "en tu turno" in text and ("no pueden ser afectados por talismanes" in text or "no puede ser afectado por talismanes" in text):
		var turn_scoped_owner: int = _main._get_card_owner(card)
		var turn_scoped_condition: Callable = func() -> bool:
			return is_instance_valid(card) and _main._is_card_in_play(card) \
				and GameManager.active_player_id == turn_scoped_owner
		_main.register_modifier({
			"source": card,
			"target": "ALLIES",
			"type": _main.ModifierType.PROTECTION,
			"stat": "",
			"value": 0,
			"operation": "add",
			"duration": _main.ModifierDuration.CONDITIONAL,
			"condition": turn_scoped_condition,
			"layer": _main.ModifierLayer.LAYER_6_ABILITIES,
			"protection_type": "TALISMAN",
			"description": "Inmune a Talismanes oponentes en tu turno (Aurora de Chile)"
		})

	# Cláusula independiente: "...No puede perder su habilidad" EN SINGULAR
	# referido a sí misma (2026-09-04, p.ej. lagrima del dragon: "Oro
	# Inicial. Indesterrable. No puede perder su habilidad.") — distinto de
	# "no pueden perder su habilidad" en plural de más arriba (protege a
	# Aliados de TERCEROS); acá "puede" en singular protege a la PROPIA
	# carta. "no puede" nunca matchea dentro de "no pueden" (falta el
	# espacio tras "puede"), así que no hay colisión entre ambas cláusulas.
	if "no puede perder su habilidad" in text:
		KeywordManager.register_self_silence_immunity(card)

	# "Tus Armas no pueden perder su habilidad" (2026-09-04, p.ej.
	# skofnung) — variante de la cláusula de Abu Simbel pero para Armas en
	# vez de Aliados.
	if "tus armas" in text and "no pueden perder su habilidad" in text:
		KeywordManager.register_all_weapons_silence_immunity(card)

	# "Los Oros oponentes pierden su habilidad" (2026-09-06, p.ej. Daikaiju
	# Furioso) — inverso de las inmunidades de arriba: FUERZA el silencio en
	# vez de proteger contra él.
	if "oros oponentes pierden su habilidad" in text:
		KeywordManager.register_opponent_type_silence(card, Constants.CardType.ORO)

	# "No puedes recibir daño" (2026-09-06, p.ej. Cetro Demoniaco) —
	# prevención TOTAL y continua para el controlador de 'card' mientras
	# siga en juego (DamageManager.add_damage_prevention con source=card,
	# one_shot=false; el chequeo de 'source' en juego en
	# _apply_damage_prevention() la limpia sola cuando 'card' sale).
	# 'tu oponente no puede Desterrar cartas de tu Castillo' (segunda mitad
	# de la misma oración) NO implementada: no hay un choke point único
	# donde interceptar todos los "Destierra del tope del Castillo" del
	# proyecto (cada patrón manipula CardManager.get_deck() directo).
	if "no puedes recibir daño" in text:
		var damage_immunity_controller: int = _main._get_card_owner(card)
		DamageManager.add_damage_prevention(damage_immunity_controller, -1, -1, false, card)

	# Cláusula independiente: "Si está en tu Reserva, las cartas que
	# controles no pueden perder su habilidad por habilidades y efectos
	# oponentes" (2026-09-04, p.ej. Terminal P-12) — protección amplia
	# (TODAS las cartas del controlador, no solo Aliados) pero condicionada
	# a que 'card' esté específicamente en Reserva de Oro, no en juego en
	# general (a diferencia de las otras variantes de silence-immunity de
	# más arriba, todas PERMANENT mientras la fuente esté en juego).
	if ("si está en tu reserva" in text or "si esta en tu reserva" in text) \
			and "no pueden perder su habilidad" in text:
		KeywordManager.register_reserva_conditional_full_silence_immunity(card)

	# Cláusula independiente: "Tus Aliados Ignis o Titán ganan Fuerza igual
	# a su coste y Furia" (2026-09-04, shedo titan) — valor DINÁMICO por
	# carta (no un número fijo, por eso no matchea qualified_buff_regex),
	# vía Callable en 'value' (_calculate_modifier_value() ya lo soporta).
	if "ganan fuerza igual a su coste" in text:
		var race_match_rx := RegEx.new()
		race_match_rx.compile("tus aliados ([a-záéíóúñ]+(?: o [a-záéíóúñ]+)?) ganan fuerza igual a su coste")
		var race_m := race_match_rx.search(text)
		var races: Array = []
		if race_m:
			for r in race_m.get_string(1).split(" o "):
				races.append(r.strip_edges().capitalize())
		var race_filter: Dictionary = {"raza": races} if not races.is_empty() else {}
		_main.register_modifier({
			"source": card,
			"target": "ALLIES",
			"type": _main.ModifierType.STRENGTH,
			"stat": "strength",
			"value": func(c: Node, _current: int, _mod: Dictionary) -> int:
				return ContinuousEffectManager.get_modified_cost(c),
			"operation": "add",
			"duration": _main.ModifierDuration.PERMANENT,
			"layer": _main.ModifierLayer.LAYER_7B_CHAR_MODIFY,
			"filter": race_filter,
			"description": "Fuerza +coste (shedo titan)"
		})
		if "furia" in text:
			_main.register_modifier({
				"source": card,
				"target": "ALLIES",
				"type": _main.ModifierType.KEYWORDS,
				"stat": "",
				"value": 0,
				"operation": "add",
				"duration": _main.ModifierDuration.PERMANENT,
				"layer": _main.ModifierLayer.LAYER_6_ABILITIES,
				"filter": race_filter,
				"keywords_add": [Constants.Keyword.FURIA],
				"description": "Otorga Furia (shedo titan)"
			})

	# Detectar debuffs a enemigos: "Los enemigos obtienen -X"
	var enemy_debuff_regex = RegEx.new()
	enemy_debuff_regex.compile("(?:los )?(enemigos|oponente).+obtienen?\\s*-(\\d+)")
	var enemy_match = enemy_debuff_regex.search(text)

	if enemy_match:
		var debuff_value = int(enemy_match.get_string(2))
		_main.register_modifier({
			"source": card,
			"target": "ENEMIES",
			"type": _main.ModifierType.STRENGTH,
			"stat": "strength",
			"value": -debuff_value,
			"operation": "add",
			"duration": _main.ModifierDuration.PERMANENT,
			"layer": _main.ModifierLayer.LAYER_7B_CHAR_MODIFY,
			"description": "Debuff a enemigos -%d" % debuff_value
		})

	# "Los Aliados oponentes pierden N de Fuerza" (2026-09-06, p.ej. amazona
	# desafiante) — misma idea que enemy_debuff_regex de arriba ("obtienen
	# -N"), pero con la fórmula "pierden N de Fuerza" en vez de "obtienen -N".
	var ally_lose_strength_regex = RegEx.new()
	ally_lose_strength_regex.compile("aliados (?:oponentes?|del oponente|rivales?) pierden?\\s*(\\d+)\\s*de fuerza")
	var ally_lose_match = ally_lose_strength_regex.search(text)
	if ally_lose_match:
		var lose_value := int(ally_lose_match.get_string(1))
		_main.register_modifier({
			"source": card,
			"target": "ENEMIES",
			"type": _main.ModifierType.STRENGTH,
			"stat": "strength",
			"value": -lose_value,
			"operation": "add",
			"duration": _main.ModifierDuration.PERMANENT,
			"layer": _main.ModifierLayer.LAYER_7B_CHAR_MODIFY,
			"description": "Debuff a Aliados oponentes -%d" % lose_value
		})

	# "Las cartas oponentes en juego reducen su coste en N Oro(s)" (2026-
	# 09-04, p.ej. Samael) — debuff de COSTE (no Fuerza) mientras la
	# fuente siga en juego, a diferencia de un descuento de UN SOLO USO al
	# jugarse (GoldManager._get_reveal_cost_reduction_pattern() y
	# similares): este es un modificador PERMANENT sobre el stat "cost",
	# que get_modified_cost() ya soporta (_get_modified_stat(), floor 0).
	# Importante para cualquier filtro 'de coste N o menos' sobre una carta
	# YA EN JUEGO (Destruir/Anular/Convertir/etc., ver TargetedEffectExecutor)
	# — esos deben leer get_modified_cost(c), no card_cost crudo, para ver
	# este debuff.
	# "Tus cartas en juego aumentan su coste en un Oro" (2026-09-06, p.ej.
	# Asmodeus) / "Tus Aliados en juego aumentan su coste en un Oro"
	# (Belcebú, calificado a solo Aliados) — espejo del debuff de coste
	# rival de abajo, pero como autoimpuesto (ALLIES en vez de ENEMIES,
	# "aumentan" en vez de "reducen"). Aplica a cartas futuras tuyas
	# también (stat "cost" vía get_modified_cost(), no solo a lo ya en juego).
	var self_cost_tax_regex = RegEx.new()
	self_cost_tax_regex.compile("tus (cartas|aliados) en juego aumentan su coste en (\\d+|un|una|dos|tres)\\s*oros?")
	var self_cost_tax_match = self_cost_tax_regex.search(text)
	if self_cost_tax_match:
		var tax_scope: String = self_cost_tax_match.get_string(1)
		var tax_value := UniversalCardParser._parse_amount(self_cost_tax_match.get_string(2))
		var tax_filter: Dictionary = {}
		if tax_scope == "aliados":
			tax_filter["type"] = Constants.CardType.ALIADO
		_main.register_modifier({
			"source": card,
			"target": "ALLIES",
			"type": _main.ModifierType.STRENGTH,
			"stat": "cost",
			"value": tax_value,
			"operation": "add",
			"duration": _main.ModifierDuration.PERMANENT,
			"layer": _main.ModifierLayer.LAYER_7B_CHAR_MODIFY,
			"filter": tax_filter,
			"description": "Autoimpuesto de coste +%d" % tax_value
		})

	var cost_debuff_regex = RegEx.new()
	cost_debuff_regex.compile("cartas (?:oponentes?|del oponente|rivales?) en juego reducen su coste en (\\d+|un|una|dos|tres)\\s*oros?")
	var cost_debuff_match = cost_debuff_regex.search(text)
	if cost_debuff_match:
		var cost_debuff_value := UniversalCardParser._parse_amount(cost_debuff_match.get_string(1))
		_main.register_modifier({
			"source": card,
			"target": "ENEMIES",
			"type": _main.ModifierType.STRENGTH,
			"stat": "cost",
			"value": -cost_debuff_value,
			"operation": "add",
			"duration": _main.ModifierDuration.PERMANENT,
			"layer": _main.ModifierLayer.LAYER_7B_CHAR_MODIFY,
			"description": "Reduce el coste de las cartas rivales en %d" % cost_debuff_value
		})

	# Detectar keywords otorgadas: "Tus aliados tienen Furia"
	var keyword_regex = RegEx.new()
	keyword_regex.compile("(?:tus |los )?(aliados|criaturas).+tienen\\s+(\\w+)")
	var keyword_match = keyword_regex.search(text)

	if keyword_match:
		var keyword_name = keyword_match.get_string(2)
		var keyword_enum = _main._string_to_keyword(keyword_name)

		if keyword_enum != -1:
			_main.register_modifier({
				"source": card,
				"target": "ALLIES",
				"type": _main.ModifierType.KEYWORDS,
				"stat": "",
				"value": 0,
				"operation": "add",
				"duration": _main.ModifierDuration.PERMANENT,
				"layer": _main.ModifierLayer.LAYER_6_ABILITIES,
				"keywords_add": [keyword_enum],
				"description": "Otorga %s a aliados" % keyword_name
			})

	# "Gana N de Fuerza por cada Arma que controles" (2026-08-30, p.ej.
	# Manuel Bulnes) — buff a SÍ MISMA (no 'tus Aliados'), con valor
	# DINÁMICO que se recalcula solo (value como Callable, ya soportado por
	# _calculate_modifier_value()). Cuenta Armas equipadas en cualquier
	# Aliado del mismo controlador — las Armas son hijas de su portador,
	# no children directos del campo, así que no alcanza con
	# _get_all_cards_in_play() + filtro de tipo.
	var self_scaling_weapon_regex = RegEx.new()
	self_scaling_weapon_regex.compile("gana\\s+(\\d+)\\s+de\\s+fuerza\\s+por\\s+cada\\s+arma\\s+que\\s+controles")
	var self_scaling_match = self_scaling_weapon_regex.search(text)
	if self_scaling_match:
		var per_unit_value := int(self_scaling_match.get_string(1))
		var value_callable := func(c: Node, _current: int, _mod: Dictionary) -> int:
			var card_owner: int = _main._get_card_owner(c)
			var weapon_count := 0
			for other in _main._get_all_cards_in_play():
				if _main._get_card_owner(other) != card_owner:
					continue
				var w = other.get("equipped_weapons")
				if w is Array:
					weapon_count += w.size()
			return per_unit_value * weapon_count
		_main.register_modifier({
			"source": card,
			"target": "SELF",
			"type": _main.ModifierType.STRENGTH,
			"stat": "strength",
			"value": value_callable,
			"operation": "add",
			"duration": _main.ModifierDuration.PERMANENT,
			"layer": _main.ModifierLayer.LAYER_7B_CHAR_MODIFY,
			"description": "Gana %d de Fuerza por cada Arma que controle" % per_unit_value
		})

	# "Gana N de Fuerza por cada otro Aliado que controles" (2026-09-04,
	# p.ej. La Torre) — mismo mecanismo que el de Arma de Manuel Bulnes de
	# arriba, pero contando Aliados (excluyendo a la carta misma, 'otro')
	# en las tres zonas de campo del mismo controlador.
	var self_scaling_ally_regex = RegEx.new()
	self_scaling_ally_regex.compile("gana\\s+(\\d+)\\s+de\\s+fuerza\\s+por\\s+cada\\s+otro\\s+aliado\\s+que\\s+controles")
	var self_scaling_ally_match = self_scaling_ally_regex.search(text)
	if self_scaling_ally_match:
		var per_unit_value2 := int(self_scaling_ally_match.get_string(1))
		var value_callable2 := func(c: Node, _current: int, _mod: Dictionary) -> int:
			var card_owner: int = _main._get_card_owner(c)
			var ally_count := 0
			for other in _main._get_all_cards_in_play():
				if other == c:
					continue
				if _main._get_card_owner(other) != card_owner:
					continue
				if other.get("card_type") == Constants.CardType.ALIADO:
					ally_count += 1
			return per_unit_value2 * ally_count
		_main.register_modifier({
			"source": card,
			"target": "SELF",
			"type": _main.ModifierType.STRENGTH,
			"stat": "strength",
			"value": value_callable2,
			"operation": "add",
			"duration": _main.ModifierDuration.PERMANENT,
			"layer": _main.ModifierLayer.LAYER_7B_CHAR_MODIFY,
			"description": "Gana %d de Fuerza por cada otro Aliado que controle" % per_unit_value2
		})

	# "Tus Aliados que porten Arma no pueden perder su habilidad" (2026-08-30,
	# Manuel Bulnes) — protección contra KeywordManager.silence_card(),
	# consultada directo desde ahí (choke point único).
	if "aliados que porten arma" in text and "no pueden perder su habilidad" in text:
		KeywordManager.register_weapon_wielder_silence_immunity(card)
