extends RefCounted
## GoldManagerTax — Impuestos de coste sobre Talismanes/Tótems/Oro ('jugar
## Talismanes y Tótems cuesta un Oro adicional', Bernardo O'Higgins; 'cuesta
## un Oro adicional si ya jugaste/pusiste uno este turno', Fuente de la
## Juventud) y el descuento de coste por 'muestra X de tu mano/Cementerio/en
## juego' (El Rey y el Verdugo, Shiji). Extraído de GoldManager.gd
## (2026-09-06, "módulos gordos", Fase 3) — confirmado por grep de todo
## scripts/ que ninguna de estas funciones tiene un llamador externo a
## GoldManager.gd. GoldManager.gd sigue exponiendo las cuatro con llamador
## interno propio (_register_talisman_totem_tax/_register_talisman_second_
## play_tax desde _trigger_enter_play(); _get_reveal_cost_reduction_pattern/
## _resolve_reveal_cost_reduction desde play_card()) bajo el mismo nombre,
## como forwarder de una sola línea. _gather_showable_candidates() no tiene
## ningún llamador fuera de _resolve_reveal_cost_reduction() (mismo módulo),
## así que no necesita forwarder.
##
## _main es Main (mismo significado que en el resto de GoldManager.gd) — el
## estado propio de GoldManager que este módulo necesita (oro_colocado_
## conteo, _fix_mojibake()) se alcanza vía _main._gold_manager, el back-
## reference que Main.gd ya mantiene hacia su propia instancia de GoldManager
## (mismo patrón que ya usan CardInteractionModule/DropZone/CardManager/
## LookRevealPatterns para llamar a GoldManager desde afuera).

var _main: Node = null


func setup(main: Node) -> void:
	_main = main


func _register_talisman_totem_tax(card: Node) -> void:
	"""Detecta 'jugar Talismanes y Tótems cuesta un Oro adicional' (p.ej.
	Bernardo O'Higgins) y registra el impuesto en PaymentManager — afecta a
	CUALQUIER Talismán/Tótem que se calcule con calcular_coste_real(), del
	dueño que sea (2026-08-26, a pedido del usuario: aplica a los dos
	jugadores por igual).

	PaymentManager.cost_modifiers se vacía entero en cada turno nuevo
	(_on_turn_started_clear_modifiers, pensado para descuentos de un solo
	uso como el de Lobo Sagrado) — para que este impuesto dure 'mientras la
	carta esté en juego' (varios turnos), se re-registra en cada
	turn_started mientras la carta siga válida y en juego, y se desconecta
	sola apenas deja de estarlo. La limpieza al salir de juego de verdad la
	hace Card._exit_tree() → PaymentManager.remover_modificador_coste()."""
	var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
	if ability_text.is_empty():
		return
	# _fix_mojibake() (2026-08-26): la API de ShadowForge trae "TalismÃ¡n"/
	# "TÃ³tem" con doble codificación rota para varias cartas (Bernardo
	# O'Higgins entre ellas) — sin normalizar, "talismán"/"tótem" nunca
	# matcheaban y este impuesto quedaba inerte para esas cartas.
	var lower: String = _main._gold_manager._fix_mojibake(ability_text).to_lower()
	var mentions_tax := "oro adicional" in lower
	var mentions_talisman_totem := ("talismán" in lower or "talisman" in lower) and ("tótem" in lower or "totem" in lower)
	if not (mentions_tax and mentions_talisman_totem):
		return

	var condition := func(c: Node) -> bool:
		return c.get("card_type") in [Constants.CardType.TALISMAN, Constants.CardType.TOTEM]

	PaymentManager.agregar_modificador_coste(card, 1, condition)
	# Afecta a una CATEGORÍA de cartas (todo Talismán/Tótem), no una sola —
	# refresca toda la mano, no un solo card_node (2026-08-30).
	PaymentManager.refresh_all_hand_cost_badges()

	var reapply: Callable
	reapply = func(_player_id: int, _turn: int) -> void:
		if not is_instance_valid(card) or not card.is_in_play():
			if GameManager.turn_started.is_connected(reapply):
				GameManager.turn_started.disconnect(reapply)
			return
		PaymentManager.agregar_modificador_coste(card, 1, condition)
		PaymentManager.refresh_all_hand_cost_badges()
	GameManager.turn_started.connect(reapply)


func _register_talisman_second_play_tax(card: Node) -> void:
	"""Detecta 'A los jugadores les cuesta un Oro adicional jugar
	Talismanes si han jugado Talismanes este turno y les cuesta un Oro
	adicional poner Oros en juego si han puesto Oros en juego este turno'
	(2026-09-04, p.ej. Fuente de la Juventud). A diferencia de
	_register_talisman_totem_tax() (impuesto FIJO, siempre activo, propio
	de Bernardo O'Higgins), acá el impuesto es CONDICIONAL por jugador:
	solo la SEGUNDA carta de ese tipo en el mismo turno lo paga, la
	primera sigue gratis. 'A los jugadores' = ambos, no solo el rival —
	la condición mira el owner_id de la carta candidata, no quién controla
	esta fuente.

	La mitad de Talismanes tiene un gancho de pago real: _play_talisman()
	registra 'talisman_played:<owner_id>' en turn_registry apenas resuelve
	el primero, ANTES de que un segundo se cotice. La mitad de Oro queda
	registrada como dato correcto pero hoy INERTE: play_card() manda los
	Oro directo a _place_card_as_gold() sin pasar nunca por PaymentManager.
	calcular_coste_real() — no existe en este motor una acción de 'pagar
	para colocar un Oro extra' a la que este impuesto pueda aplicarse (el
	único otro camino para un segundo Oro es un efecto de búsqueda que lo
	coloca directo y gratis, put_gold_directly_in_reserva). Si algún día
	se agrega esa acción, esto ya la cubre sin tocar nada más."""
	var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
	if ability_text.is_empty():
		return
	var lower: String = _main._gold_manager._fix_mojibake(ability_text).to_lower()
	if not ("oro adicional jugar talismanes" in lower and "oro adicional poner oros en juego" in lower):
		return

	var condition := func(c: Node) -> bool:
		var owner: int = c.owner_id if c.get("owner_id") != null else 0
		if c.get("card_type") == Constants.CardType.TALISMAN:
			return UniversalCardParser.turn_registry.was_used("talisman_played:%d" % owner, 0, GameManager.current_turn)
		if c.get("card_type") == Constants.CardType.ORO:
			return _main._gold_manager.oro_colocado_conteo.get(owner, 0) >= 1
		return false

	PaymentManager.agregar_modificador_coste(card, 1, condition)
	PaymentManager.refresh_all_hand_cost_badges()

	var reapply2: Callable
	reapply2 = func(_player_id: int, _turn: int) -> void:
		if not is_instance_valid(card) or not card.is_in_play():
			if GameManager.turn_started.is_connected(reapply2):
				GameManager.turn_started.disconnect(reapply2)
			return
		PaymentManager.agregar_modificador_coste(card, 1, condition)
		PaymentManager.refresh_all_hand_cost_badges()
	GameManager.turn_started.connect(reapply2)


func _get_reveal_cost_reduction_pattern(card: Node) -> Dictionary:
	"""Detecta 'Reduce su coste en un Oro por cada X que muestres de tu
	mano, Cementerio o que controles, hasta un mínimo de N' (2026-08-29,
	p.ej. El Rey y el Verdugo: '...por cada Arma...') — escala con la
	cantidad mostrada. También detecta 'Reduce su coste en un Oro si
	muestras un X (o Y) de tu mano o Cementerio' (2026-09-03, p.ej. Shiji:
	'...si muestras un Arma o Tótem...') — SINGULAR, no escala ('un X', no
	'por cada X'): tope de 1 carta mostrada (ver max_reveal en
	_resolve_reveal_cost_reduction()), el descuento de -1 sale solo de
	limitar la cuenta a 0 o 1, no hace falta un cálculo de descuento
	distinto. 'Arma o Tótem' es una lista de tipos válidos (no un elif que
	corta en el primero, mismo criterio ya usado en _execute_targeted_
	search() de TargetedEffectExecutor.gd para 'busca un Arma o un Oro').
	A diferencia de _register_talisman_totem_tax()/_register_weapon_
	first_play_discount() (modificadores PERSISTENTES de una carta ya en
	juego, afectando a OTRAS), este es un descuento de UN SOLO USO sobre
	la carta que se está jugando AHORA MISMO — se resuelve en play_card(),
	no como un modifier registrado en turn_started.
	Returns: {} si no aplica, si no {types: Array[Constants.CardType],
	allow_zero: bool, single: bool}."""
	var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
	if ability_text.is_empty():
		return {}
	var lower: String = _main._gold_manager._fix_mojibake(ability_text).to_lower()
	if not ("reduce su coste" in lower and ("que muestres" in lower or "si muestras" in lower)):
		return {}
	# Enmascarar 'reduce su coste en [un/N] Oro(s)' ANTES de buscar tipos
	# (2026-09-04, bug reportado: Shiji — 'si muestras un Arma o Tótem' —
	# también ofrecía Oro como tipo mostrable, porque esa frase de arriba
	# menciona 'Oro' como la UNIDAD del descuento, no como un tipo de
	# carta a revelar. La versión anterior de este detector era un elif
	# (un solo tipo posible) y "arma"/"tótem" ganaban SIEMPRE antes de
	# llegar a la rama "oro", así que nunca se notó — el cambio a lista
	# (2026-09-03, para soportar 'Arma o Tótem' a la vez) sí lo expuso.
	var cost_amount_rx := RegEx.new()
	cost_amount_rx.compile("reduce su coste en (?:un|una|\\d+|dos|tres|cuatro|cinco)\\s+oros?")
	var type_scan_text: String = cost_amount_rx.sub(lower, "", true)

	var wanted_types: Array = []
	if "arma" in type_scan_text:
		wanted_types.append(Constants.CardType.ARMA)
	if "aliado" in type_scan_text:
		wanted_types.append(Constants.CardType.ALIADO)
	if "talismán" in type_scan_text or "talisman" in type_scan_text:
		wanted_types.append(Constants.CardType.TALISMAN)
	if "tótem" in type_scan_text or "totem" in type_scan_text:
		wanted_types.append(Constants.CardType.TOTEM)
	if "oro" in type_scan_text:
		wanted_types.append(Constants.CardType.ORO)
	if wanted_types.is_empty():
		return {}
	var allow_zero := "mínimo de 0" in lower or "minimo de 0" in lower
	var single := "si muestras un" in lower or "si muestras una" in lower
	# Zonas de origen realmente mencionadas (2026-09-03, p.ej. Shiji: 'de tu
	# mano o Cementerio', SIN 'que controles' — a diferencia de El Rey y el
	# Verdugo que sí ofrece las tres). No ofrecer una zona que el texto no
	# menciona.
	var zones: Array = []
	if "tu mano" in lower:
		zones.append(0)
	if "cementerio" in lower:
		zones.append(1)
	if "que controles" in lower:
		zones.append(2)
	if zones.is_empty():
		zones = [0, 1, 2]
	return {"types": wanted_types, "allow_zero": allow_zero, "single": single, "zones": zones}


func _gather_showable_candidates(card_types, exclude_card: Node, source: int) -> Array:
	"""Reúne candidatos 'que muestres de tu mano, Cementerio o que
	controles' de UNA sola zona a la vez (source: 0=mano, 1=Cementerio,
	2=en juego) — 'mostrar' (DAR) no mueve ni gasta nada, la carta se queda
	donde está. card_types acepta un int (un solo tipo) o un Array (2026-
	09-03, p.ej. Shiji: 'muestra un Arma o Tótem' — dos tipos válidos).

	Antes juntaba las tres zonas en un solo pool combinado (2026-08-31,
	corregido a pedido del usuario): el 'y/o' de 'tu mano, Cementerio o que
	controles' es DAR para 'elegí UNA de las tres', no 'mostrá cualquier
	combinación de las tres a la vez' — con el pool combinado se podía
	mostrar, p.ej., un Arma de la mano Y otra del Cementerio en el mismo
	'muestra X', algo que el texto real no permite. Ver
	_resolve_reveal_cost_reduction(), que ahora pide la zona ANTES de
	llamar acá."""
	var types_array: Array = card_types if card_types is Array else [card_types]
	var candidates: Array = []
	match source:
		0:
			for c in _main.player_hand.cards:
				if c == exclude_card:
					continue
				if c.get("card_type") in types_array:
					candidates.append(c.card_data)
		1:
			for d in CardManager.get_cemetery(0):
				if d.get("tipo", -1) in types_array:
					candidates.append(d)
		2:
			var field_zones: Array = [_main.player_field, _main.player_linea_ataque, _main.player_linea_apoyo]
			for zone in field_zones:
				if not zone:
					continue
				for ally in zone.get_children():
					if ally.get("card_type") in types_array:
						candidates.append(ally.card_data)
					for weapon in ally.get("equipped_weapons") if ally.get("equipped_weapons") != null else []:
						if is_instance_valid(weapon) and weapon.get("card_type") in types_array:
							candidates.append(weapon.card_data)
	return candidates


const _CARD_TYPE_DISPLAY_NAMES: Dictionary = {
	0: "Oro", 1: "Aliado(s)", 2: "Arma(s)", 3: "Talismán(es)", 4: "Tótem(s)"
}


func _resolve_reveal_cost_reduction(card: Node, pattern: Dictionary) -> int:
	"""Primero elige UNA zona de origen (mano / Cementerio / en juego —
	2026-08-31, corregido: el 'y/o' del texto es 'elegí una', no un pool
	combinado, ver _gather_showable_candidates()), después abre selección
	múltiple (0 a todos los candidatos DE ESA ZONA) — el jugador elige
	CUÁLES mostrar, el conteo de elegidas es la reducción de Oro (DAR: 1
	por carta mostrada). No remueve nada de su zona ('mostrar' no es
	'gastar' ni 'desterrar').
	Returns: cantidad de cartas mostradas (0 si no había candidatos en la
	zona elegida o no se eligió ninguna)."""
	var types: Array = pattern.get("types", [])
	var type_name: String = " o ".join(types.map(func(t): return _CARD_TYPE_DISPLAY_NAMES.get(t, "carta(s)"))) if not types.is_empty() else "carta(s)"

	var zone_choices: Array = pattern.get("zones", [0, 1, 2])
	var zone_labels := {0: "Tu mano", 1: "Tu Cementerio", 2: "Lo que controlas en juego"}
	var source: int
	if zone_choices.size() == 1:
		source = zone_choices[0]
	else:
		var picked_idx: int = await SelectionManager.await_choice(
			_main, "¿Desde dónde mostrar %s para reducir el coste?" % type_name,
			zone_choices.map(func(z): return zone_labels[z]))
		source = zone_choices[picked_idx]

	var candidates: Array = _gather_showable_candidates(types, card, source)
	if candidates.is_empty():
		return 0
	# Tope real de cartas ÚTILES a mostrar (2026-09-02, bug reportado por el
	# usuario: con base_cost=2 y 'hasta un mínimo de 0', mostrar más de 2
	# no reduce nada más — pero el picker seguía ofreciendo hasta
	# candidates.size(), dejando elegir 3 o 4 sin ningún efecto). El piso
	# real que aplica calcular_coste_real() es 0 con allow_zero, 1 si no
	# (mismo criterio documentado ahí) — más allá de coste_base - piso, cada
	# carta adicional mostrada es un no-op. 'single' (2026-09-03, p.ej.
	# Shiji: 'si muestras un Arma o Tótem' — no escala, tope duro de 1) se
	# aplica ADEMÁS del tope por utilidad, el que sea más chico gana.
	var floor_val: int = 0 if pattern.get("allow_zero", false) else 1
	var base_cost: int = int(card.get("card_cost")) if card.get("card_cost") != null else 0
	var useful_cap: int = maxi(base_cost - floor_val, 0)
	var max_selections: int = mini(candidates.size(), useful_cap) if useful_cap > 0 else candidates.size()
	if pattern.get("single", false):
		max_selections = mini(max_selections, 1)
	var result: Dictionary = await SelectionManager.await_multi_pick(
		candidates,
		"Muestra %s de esa zona para reducir el coste (1 Oro c/u)" % type_name,
		max_selections)
	return result.picked.size()
