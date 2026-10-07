extends Node
## PaymentManager - Gestión de Costes y Pagos (DAR Sección 6.B)
##
## Maneja:
## - Cálculo de costes (base + modificadores)
## - Costes alternativos (Exhumar, sacrificio, etc.)
## - Scanner de Cementerio para cartas con Exhumar
## - Interfaz de selección de pago

# =============================================================================
# SEÑALES
# =============================================================================
signal payment_requested(card_data: Dictionary, cost_info: Dictionary)
signal payment_completed(card_data: Dictionary, method: String, amount_paid: int)
signal payment_cancelled(card_data: Dictionary, reason: String)
signal payment_failed(card_data: Dictionary, reason: String)

## Exhumar
signal exhumar_cards_available(player_id: int, cards: Array)
signal exhumar_card_selected(card_data: Dictionary, player_id: int)
signal exhumar_payment_confirmed(card_data: Dictionary, player_id: int)

## Coste Variable X
signal x_value_requested(card_data: Dictionary, max_value: int)
signal x_value_selected(card_data: Dictionary, x_value: int)
signal x_value_cancelled(card_data: Dictionary)

## UI
signal payment_ui_opened(options: Array)
signal payment_ui_closed

# =============================================================================
# ENUMS
# =============================================================================
enum PaymentMethod {
	NORMAL,           # Pago normal con Oros
	EXHUMAR,          # Desde Cementerio
	SACRIFICE,        # Sacrificar carta
	DISCARD,          # Descartar cartas
	LIFE,             # Pagar vida/daño a Castillo
	FREE,             # Sin coste
	ALTERNATIVE,      # Coste alternativo definido en carta
	VARIABLE_X        # Coste variable (X)
}

enum PaymentState {
	IDLE,
	AWAITING_SELECTION,    # Esperando que jugador elija método
	AWAITING_X_INPUT,      # Esperando valor de X
	AWAITING_PAYMENT,      # Esperando que pague
	PROCESSING,            # Procesando pago
	COMPLETED,
	CANCELLED
}

# =============================================================================
# ESTADO
# =============================================================================
var _state: PaymentState = PaymentState.IDLE
var _current_card: Dictionary = {}
var _current_player_id: int = -1
var _current_cost_info: Dictionary = {}
var _selected_method: PaymentMethod = PaymentMethod.NORMAL

## Módulos extraídos (Fase 4 de reestructuración)
var _cost_modifiers_mod: CostModifiers
var _exhumar: ExhumarSystem
var _x_cost: XCostSelector
var _validation: PaymentValidation
var _payment_ui: PaymentUI

# =============================================================================
# UI REFERENCES
# =============================================================================
var _payment_popup: Window = null

# =============================================================================
# MODIFICADORES DE COSTE (DAR Sección 6.B)
# =============================================================================
## Modificadores al COSTE IMPRESO [{source, modifier, condition, allow_zero}].
## modifier negativo = "reduce su coste en N" (piso 1 salvo allow_zero=true);
## modifier positivo = "aumenta su coste en N" (sin techo).
var cost_modifiers: Array = []
## "Jugar por X Oros menos" [{source, reduction, condition}] — descuento
## sobre lo que se PAGA, no toca el coste impreso. Sin piso, puede llegar a 0.
var oros_menos_modifiers: Array = []
## "Cuesta X Oro(s) adicional(es)" para pagar [{source, increase, condition}]
## — inverso de oros_menos: sube lo pagado sin tocar el coste impreso.
var oros_mas_modifiers: Array = []

## "Esa carta cuesta un Oro adicional el PRÓXIMO turno" — por NOMBRE de
## carta, no por instancia (2026-08-29, p.ej. Tesoro de los Césares: "puedes
## Barajar una carta de tu mano para nombrar una carta. Esa carta cuesta un
## Oro adicional el próximo turno"). Registro APARTE de oros_mas_modifiers a
## propósito: ese Array se limpia entero en CADA turn_started (pensado para
## 'por el turno actual'), pero aquí el efecto todavía NO debe estar activo
## en el momento de registrarse — arranca solo cuando empiece el turno
## siguiente, y dura exactamente ese turno. {nombre_lower: número_de_turno}.
var _named_surcharge_next_turn: Dictionary = {}

# =============================================================================
# TRACKING DE ORO GASTADO EN EL TURNO
# =============================================================================
## Acumulado de oro pagado en el turno actual (se resetea en cada nuevo turno)
var oro_gastado_este_turno: int = 0


func _ready() -> void:
	_cost_modifiers_mod = CostModifiers.new()
	_cost_modifiers_mod.setup(self)
	_exhumar = ExhumarSystem.new()
	_exhumar.setup(self)
	_x_cost = XCostSelector.new()
	_x_cost.setup(self)
	_validation = PaymentValidation.new()
	_validation.setup(self)
	_payment_ui = PaymentUI.new()
	_payment_ui.setup(self)

	call_deferred("_connect_signals")
	_x_cost.call_deferred("_setup_x_selector")
	print("[PaymentManager] Inicializado")


func _on_turn_started_clear_modifiers(_player_id: int, _turn_num: int) -> void:
	cost_modifiers.clear()
	oros_menos_modifiers.clear()
	oros_mas_modifiers.clear()
	oro_gastado_este_turno = 0
	# Los recargos diferidos por nombre (Tesoro de los Césares) no se
	# limpian aquí — _get_named_surcharge_next_turn() se auto-expira sola
	# comparando contra GameManager.current_turn. Pero si uno de esos
	# recargos recién arranca o recién expira justo este turno, la insignia
	# de coste de la carta en mano (si la tienes) no se enteraría hasta el
	# próximo refresh puntual — se refresca toda la mano aquí para no
	# depender de que algo más la dispare.
	refresh_all_hand_cost_badges()


func refresh_all_hand_cost_badges() -> void:
	"""Refresca la insignia de coste (Card.refresh_cost_badge()) de todas
	las cartas en tu mano — llamar después de cualquier cambio que pueda
	afectar el coste de una carta ajena a ella misma (2026-08-30): un
	modificador nuevo, uno que se limpia, o un recargo diferido que
	arranca/expira al cambiar de turno."""
	var main := get_node_or_null("/root/Main")
	if not main or not main.player_hand:
		return
	for c in main.player_hand.cards:
		if is_instance_valid(c) and c.has_method("refresh_cost_badge"):
			c.refresh_cost_badge()


func puede_jugar_carta(card: Node, player_id: int = 0) -> bool:
	"""Valida si el jugador puede pagar la carta considerando lo ya gastado este turno.
	Cartas de coste 0 siempre se permiten si hay prioridad.
	Returns: true si puede jugarla, false si no tiene oro suficiente."""
	var coste = calcular_coste_real(card)

	# Coste 0 → siempre jugable (Talismanes sin coste, etc.)
	if coste <= 0:
		return true

	var main = get_node_or_null("/root/Main")
	if not main:
		return false

	# Oro físico disponible en reserva ahora mismo
	var oro_reserva: int = GameState.get_oro_reserva(player_id)

	# Oro Virtual (genérico + restringido) — 2026-10-06: GoldManager.
	# oros_virtuales/restricted_gold_pools ya son por jugador (ver
	# arquitectura.md §33), así que esto deja de limitarse al jugador 0.
	# 2026-08-28, corrige bug real: aquí se leía 'main.get("oros_virtuales")',
	# pero esa propiedad vive en main._gold_manager.oros_virtuales, no en
	# Main — siempre daba null/0, así que el Oro Virtual de Lobo Sagrado
	# NUNCA contaba para decidir si se podía siquiera INTENTAR jugar una
	# carta, aunque GoldManager.pagar_coste() sí lo hubiera cobrado bien
	# después.
	var oros_virtuales: int = 0
	var oro_restringido: int = 0
	if main._gold_manager:
		oros_virtuales = main._gold_manager.oros_virtuales.get(player_id, 0)
		var card_type: int = card.get("card_type") if card.get("card_type") != null else -1
		var card_race: String = str(card.get("card_raza")) if card.get("card_raza") != null else ""
		var card_cost: int = card.get("card_cost") if card.get("card_cost") != null else -1
		oro_restringido = main._gold_manager._restricted_gold_available_for(card_type, card_race, card_cost, player_id)

	var disponible = oro_reserva + oros_virtuales + oro_restringido
	return coste <= disponible


func registrar_pago(amount: int) -> void:
	"""Registra un pago completado en el tracker del turno."""
	if amount > 0:
		oro_gastado_este_turno += amount


func calcular_coste_real(card: Node) -> int:
	"""Calcula el coste real de una carta aplicando DAR 6.B. Dos familias de
	efecto, independientes entre sí:

	A. COSTE IMPRESO (cost_modifiers) — cambia el número base de la carta.
	   'Reduce su coste en N' tiene piso 1 salvo que el efecto indique
	   explícitamente 'hasta un mínimo de 0' (allow_zero=true al agregarlo).
	   'Aumenta su coste en N' no tiene techo.
	B. SOLO PARA PAGAR (oros_menos_modifiers / oros_mas_modifiers) — cambian
	   lo que se paga sin tocar el coste impreso de la carta. 'Jugar por X
	   Oros menos' y 'cuesta X Oro(s) adicional(es)' no tienen piso propio
	   (el piso final de 0 es solo para que el pago nunca sea negativo).
	"""
	if not is_instance_valid(card):
		return 0

	var coste_base: int = 0
	if card.get("card_cost") != null:
		coste_base = int(card.get("card_cost"))

	var coste_mod = coste_base
	var floor_impreso = 1
	for mod in cost_modifiers:
		if _modifier_applies(mod, card):
			coste_mod += mod.modifier
			if mod.modifier < 0 and mod.get("allow_zero", false):
				floor_impreso = 0
	if coste_base > 0:
		coste_mod = maxi(coste_mod, floor_impreso)

	var oros_menos_total = 0
	for red in oros_menos_modifiers:
		if _modifier_applies(red, card):
			oros_menos_total += red.reduction

	var oros_mas_total = 0
	for inc in oros_mas_modifiers:
		if _modifier_applies(inc, card):
			oros_mas_total += inc.increase

	var card_name_for_surcharge: String = str(card.get("card_name")) if card.get("card_name") != null else ""
	if not card_name_for_surcharge.is_empty():
		oros_mas_total += _get_named_surcharge_next_turn(card_name_for_surcharge)

	oros_menos_total += _self_scaling_oro_discount(card)
	oros_menos_total += _conditional_boolean_discount(card)

	return maxi(coste_mod - oros_menos_total + oros_mas_total, 0)


func _self_scaling_oro_discount(card: Node) -> int:
	"""'...cuesta un Oro menos por cada Oro que controles' (2026-08-30,
	Aaru) — descuento intrínseco de ESTA carta que escala con el propio
	estado del tablero de su controlador (Reserva + Oro Pagado), no un
	modificador registrado por un efecto externo como el resto de
	oros_menos_modifiers. Se detecta por texto y se recalcula fresco cada
	vez (no se cachea: el conteo de Oro puede cambiar entre llamadas del
	mismo turno)."""
	if card.get("card_data") == null:
		return 0
	var habilidad: String = str(card.card_data.get("habilidad", "")).to_lower()
	# "Reduce su coste en un Oro por cada Oro que controles" (2026-09-04,
	# Piruquina) — mismo concepto que Aaru, otra forma de imprimirlo. Nota:
	# el texto de Piruquina dice 'hasta un mínimo de 1', pero el piso real
	# de esta función es 0 (ver calcular_coste_real(), maxi(..., 0) es
	# compartido con oros_menos_modifiers) — desviación menor conocida, sin
	# caso de prueba a mano que la haga notoria todavía.
	if not ("cuesta un oro menos por cada oro que controles" in habilidad
			or "reduce su coste en un oro por cada oro que controles" in habilidad):
		return 0
	var controller_id: int = card.get("controller_id") if card.get("controller_id") != null else 0
	return GameState.get_oro_total(controller_id)


func _conditional_boolean_discount(card: Node) -> int:
	"""Descuentos intrínsecos de 1 Oro condicionados a un booleano del
	tablero (2026-09-06) — a diferencia de _self_scaling_oro_discount()
	(escala con una cantidad), aquí el descuento es 0 o 1 según se cumpla o
	no una condición puntual. Lista chica y explícita, mismo criterio que
	el resto de detectores por texto de este archivo. 'jugaste este turno'
	(Cetro Demoniaco) NO se evalúa — no existe todavía un registro
	genérico de 'jugué un Arma este turno', solo se chequea la mitad
	'controlas' de la condición."""
	if card.get("card_data") == null:
		return 0
	var habilidad: String = str(card.card_data.get("habilidad", "")).to_lower()
	var controller_id: int = card.get("controller_id") if card.get("controller_id") != null else 0
	var main := get_node_or_null("/root/Main")
	if not main:
		return 0

	# "Reduce su coste en un Oro si controlas o jugaste este turno Armas o
	# a Lucifer" (Cetro Demoniaco) — solo la mitad 'controlas Armas o a
	# Lucifer'.
	if "reduce su coste en un oro si controlas o jugaste este turno armas o a lucifer" in habilidad:
		var fields_a: Array = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo, main.player_gold] \
			if controller_id == 0 else [main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo, main.opponent_gold]
		for field in fields_a:
			if not field:
				continue
			for c in field.get_children():
				if not is_instance_valid(c):
					continue
				if c.get("card_type") == Constants.CardType.ARMA:
					return 1
				if str(c.get("card_name")).to_lower() == "lucifer":
					return 1
		return 0

	# "Reduce su coste en un Oro si controlas Armas" (sable corto, 2026-09-20,
	# arquitectura.md "539 cartas sin cobertura") — las Armas son hijas de su
	# portador, no children directos del campo (mismo motivo documentado en
	# ContinuousEffectParser.gd para el bono de Manuel Bulnes), así que se
	# revisa 'equipped_weapons' de cada Aliado en vez de recorrer field.
	# get_children() buscando tipo ARMA directo (eso nunca encontraría nada).
	if "reduce su coste en un oro si controlas armas" in habilidad:
		var fields_sc: Array = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo] \
			if controller_id == 0 else [main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]
		for field in fields_sc:
			if not field:
				continue
			for c in field.get_children():
				if is_instance_valid(c):
					var w = c.get("equipped_weapons")
					if w is Array and not w.is_empty():
						return 1
		return 0

	# "Si controlas Dragones reduce su coste en un Oro" (Azi Raoiota).
	if "si controlas dragones reduce su coste en un oro" in habilidad:
		var fields_b: Array = [main.player_field, main.player_linea_ataque] if controller_id == 0 \
			else [main.opponent_field, main.opponent_linea_ataque]
		for field in fields_b:
			if not field:
				continue
			for c in field.get_children():
				if is_instance_valid(c) and c.get("card_type") == Constants.CardType.ALIADO \
						and "drag" in str(c.get("card_raza")).to_lower():
					return 1
		return 0

	# "Si no controlas Aliados de coste 1 o menos, reduce su coste en un
	# Oro" (Jabberwocky). 2026-09-30, bug real reportado por el usuario
	# ("Stack overflow... en PaymentManager"): usaba calcular_coste_real(c)
	# para revisar el coste de cada Aliado — si Jabberwocky mismo ya está
	# en el campo (o cualquier otro Aliado cuyo propio coste dependa de
	# este mismo chequeo), esa llamada vuelve a entrar a esta función y
	# nunca termina. Se revisa el coste BASE (card_cost, sin modificadores)
	# en vez del efectivo — mismo criterio que los chequeos hermanos de
	# arriba (Armas/Dragones), que tampoco llaman calcular_coste_real().
	if "si no controlas aliados de coste 1 o menos, reduce su coste en un oro" in habilidad:
		var fields_c: Array = [main.player_field, main.player_linea_ataque] if controller_id == 0 \
			else [main.opponent_field, main.opponent_linea_ataque]
		for field in fields_c:
			if not field:
				continue
			for c in field.get_children():
				if is_instance_valid(c) and c.get("card_type") == Constants.CardType.ALIADO \
						and c.get("card_cost") != null and int(c.card_cost) <= 1:
					return 0
		return 1

	return 0


func add_named_surcharge_next_turn(card_name: String, target_turn: int) -> void:
	"""Registra que 'card_name' cuesta 1 Oro adicional durante target_turn
	(2026-08-29, Tesoro de los Césares — quien lo registra ya calculó
	target_turn como GameManager.current_turn + 1 al activar la habilidad)."""
	if card_name.is_empty():
		return
	_named_surcharge_next_turn[card_name.to_lower()] = target_turn


func _get_named_surcharge_next_turn(card_name: String) -> int:
	"""Devuelve 1 si 'card_name' tiene un recargo vigente para el turno
	ACTUAL, 0 si todavía no llega ese turno o ya pasó (y en ese caso limpia
	la entrada vencida, auto-expira sin necesidad de un hook de turn_started
	aparte)."""
	var key := card_name.to_lower()
	if not _named_surcharge_next_turn.has(key):
		return 0
	var target_turn: int = _named_surcharge_next_turn[key]
	if not GameManager or GameManager.current_turn > target_turn:
		_named_surcharge_next_turn.erase(key)
		return 0
	if GameManager.current_turn < target_turn:
		return 0
	return 1


func _modifier_applies(mod: Dictionary, card: Node) -> bool:
	if not mod.has("condition") or mod.condition == null:
		return true
	if mod.condition is Callable and mod.condition.is_valid():
		return mod.condition.call(card)
	return false  # Tipo de condición desconocido — no aplicar


# =============================================================================
# MODIFICADORES DE COSTE (implementación en CostModifiers.gd)
# =============================================================================
func agregar_modificador_coste(source: Node, modifier: int, condition: Callable = Callable(), allow_zero: bool = false) -> void:
	_cost_modifiers_mod.agregar_modificador_coste(source, modifier, condition, allow_zero)


func remover_modificador_coste(source: Node) -> void:
	_cost_modifiers_mod.remover_modificador_coste(source)


func agregar_oros_menos(source: Node, reduction: int, condition: Callable = Callable()) -> void:
	_cost_modifiers_mod.agregar_oros_menos(source, reduction, condition)


func remover_oros_menos(source: Node) -> void:
	_cost_modifiers_mod.remover_oros_menos(source)


func agregar_oros_mas(source: Node, increase: int, condition: Callable = Callable()) -> void:
	_cost_modifiers_mod.agregar_oros_mas(source, increase, condition)


func remover_oros_mas(source: Node) -> void:
	_cost_modifiers_mod.remover_oros_mas(source)


func puede_pagar_carta(card: Node) -> bool:
	"""Verifica si el jugador (player 0) puede pagar el coste real de una carta"""
	var main = get_node_or_null("/root/Main")
	if main and main.get("_gold_manager"):
		return main._gold_manager.puede_pagar(calcular_coste_real(card))
	return false


## NOTA: Esta función es una coroutine. Siempre llamar con: await pagar_carta(card)
func pagar_carta(card: Node) -> bool:
	"""Paga el coste real de una carta delegando el pago físico a GoldManager
	Returns: true si se pudo pagar
	"""
	var coste_real = calcular_coste_real(card)
	var main = get_node_or_null("/root/Main")
	if not main or not main.get("_gold_manager"):
		return false
	if coste_real <= 0:
		return true
	return await main._gold_manager.pagar_coste(coste_real)


func _connect_signals() -> void:
	# (2026-08-28, "módulos gordos" punto 1): esto apuntaba a GameManager
	# buscando señales 'card_moved_to_zone'/'zone_changed' que NUNCA
	# existieron ahí (ni existen hoy) — el cache de Exhumar jamás se
	# invalidaba tras el primer escaneo, así que las opciones de Exhumar
	# quedaban congeladas con el estado del cementerio del primer chequeo.
	# La señal real es CardManager.zone_changed. Mismo problema con
	# 'priority_given' (no existe en PriorityManager; la real es
	# priority_changed).
	if not CardManager.zone_changed.is_connected(_exhumar._on_card_moved_to_zone):
		CardManager.zone_changed.connect(_exhumar._on_card_moved_to_zone)

	if not PriorityManager.priority_changed.is_connected(_exhumar._on_priority_given):
		PriorityManager.priority_changed.connect(_exhumar._on_priority_given)

	# Limpiar modificadores al inicio de cada turno.
	# GameManager es el único conductor de turnos (ver consolidación 2026-08-19).
	if GameManager and GameManager.has_signal("turn_started"):
		if not GameManager.turn_started.is_connected(_on_turn_started_clear_modifiers):
			GameManager.turn_started.connect(_on_turn_started_clear_modifiers)


# =============================================================================
# EXHUMAR (implementación en ExhumarSystem.gd)
# =============================================================================
func scan_cemetery_for_exhumar(player_id: int) -> Array[Dictionary]:
	return _exhumar.scan_cemetery_for_exhumar(player_id)


func get_all_exhumar_cards() -> Dictionary:
	return _exhumar.get_all_exhumar_cards()


func mark_playable_exhumar_cards(player_id: int) -> void:
	_exhumar.mark_playable_exhumar_cards(player_id)


func show_exhumar_options(player_id: int) -> void:
	_exhumar.show_exhumar_options(player_id)


func has_exhumar_available(player_id: int) -> bool:
	return _exhumar.has_exhumar_available(player_id)


func invalidate_cache() -> void:
	_exhumar.invalidate_cache()


func card_has_exhumar(card_data: Dictionary) -> bool:
	"""Expone el chequeo privado de ExhumarSystem — usado por ZoneViewerModule
	para marcar como clickeables las cartas del Cementerio que se pueden
	jugar via Exhumar (2026-08-23). Respeta el silencio de Cementerio
	(2026-08-30, Sable de Napoleón) — 'pierde su habilidad' incluye Exhumar."""
	if CardManager.is_cemetery_card_silenced(card_data):
		return false
	return _exhumar._card_has_exhumar(card_data)


func get_exhumar_cost(card_data: Dictionary) -> int:
	"""Coste de jugar esta carta via Exhumar (normalmente el coste base,
	salvo que la carta tenga un coste de Exhumar alternativo definido)."""
	return _exhumar._calculate_exhumar_cost(card_data, card_data.get("coste", 0))


func card_playable_from_exile(card_data: Dictionary) -> bool:
	"""'Puedes jugar(lo/la) desde/de tu Destierro' (2026-09-04, a pedido del
	usuario — p.ej. uriel, batallon de ovejas, cruzar el bosque) — usado
	por ZoneViewerModule para marcar como clickeables las cartas del
	Destierro propio jugables vía GoldManager.play_card_from_exile().
	Lista chica y explícita (mismo criterio que card_has_exhumar()/
	_ability_is_hand_usable()), no un permiso genérico por presencia de
	'Destierro' en el texto (esa palabra aparece en muchísimas habilidades
	sin relación con jugar desde ahí)."""
	var text: String = str(card_data.get("habilidad", "")).to_lower()
	if "puedes jugarlo de tu destierro pagando su coste" in text:
		return true  # uriel
	if "puedes jugarlo de tu destierro reduciendo su coste en un oro" in text:
		# rafael: condicionado a controlar Sacerdotes
		if "si controlas sacerdotes" in text:
			var main = get_node_or_null("/root/Main")
			if not main:
				return false
			for field in [main.player_field, main.player_linea_ataque, main.player_linea_apoyo]:
				if not field:
					continue
				for c in field.get_children():
					if c.get("card_type") == Constants.CardType.ALIADO and str(c.get("card_raza")).to_lower() == "sacerdote":
						return true
			return false
		return true
	if "puedes jugarlo desde tu destierro" in text:
		# batallon de ovejas: condicionado a mano de 4 o menos
		if "cuatro cartas o menos en tu mano" in text:
			var main = get_node_or_null("/root/Main")
			if main and main.player_hand:
				return main.player_hand.cards.size() <= 4
			return false
		return true
	if "puedes jugar esta carta desde tu destierro" in text:
		return true  # cruzar el bosque
	return false


func get_exile_play_discount(card_data: Dictionary) -> int:
	"""Descuento fijo al jugar desde el Destierro (2026-09-04, p.ej.
	rafael: 'reduciendo su coste en un Oro') — 0 si no aplica (la mayoría,
	p.ej. uriel/batallon de ovejas pagan el coste completo)."""
	var text: String = str(card_data.get("habilidad", "")).to_lower()
	if "puedes jugarlo de tu destierro reduciendo su coste en un oro" in text:
		return 1
	return 0


# =============================================================================
# VALIDACIÓN DE CARTAS ÚNICAS Y CONSULTAS DE ORO — ver PaymentValidation.gd
# (2026-08-28, "módulos gordos": _card_is_unique/_validate_unique_card/
# _check_unique_in_play/_check_unique_in_stack/_get_cards_in_zone/
# _get_player_cemetery/_get_player_available_gold se movieron ahí, acceso vía
# _validation. Se quedaron aquí porque son consultas sin estado — nada que ver
# con _current_card/_payment_popup/etc., que sí están entrelazados con
# ExhumarSystem.gd/XCostSelector.gd como blackboard compartido.)


# =============================================================================
# INTERFAZ DE PAGO (popup + procesamiento) — ver PaymentUI.gd (2026-08-28,
# "módulos gordos"): show_payment_options/_detect_payment_options/
# _create_payment_popup/_process_payment/_pay_with_*/etc. se movieron ahí,
# acceso vía _payment_ui. El estado (_current_card/_payment_popup/_state/
# etc.) se quedó aquí — ver nota arriba.
# =============================================================================


# =============================================================================
# COSTE VARIABLE X (implementación en XCostSelector.gd)
# =============================================================================
func has_variable_x_cost(card_data: Dictionary) -> bool:
	return _x_cost.has_variable_x_cost(card_data)


func parse_x_cost(card_data: Dictionary) -> Dictionary:
	return _x_cost.parse_x_cost(card_data)


func request_x_value_input(card_data: Dictionary, player_id: int, callback: Callable = Callable()) -> void:
	_x_cost.request_x_value_input(card_data, player_id, callback)


func get_x_value() -> int:
	return _x_cost.get_x_value()


func get_x_total_cost() -> int:
	return _x_cost.get_x_total_cost()


# =============================================================================
# HELPER FUNCTIONS - Log y Player Name
# =============================================================================
func _log_action(action_type: String, message: String, data: Dictionary = {}) -> void:
	"""Registra una acción en el CombatLog"""
	CombatLog.add_entry(action_type, message, data)


func _get_player_name(player_id: int) -> String:
	"""Obtiene el nombre del jugador para logs
	(2026-08-28: GameManager no expone get_player_name() ni una propiedad
	'_players' — esto siempre cayó al fallback genérico. GameManager.players
	es un Array[Node] sin campo de nombre legible hoy, así que se deja el
	fallback como único comportamiento real en vez de simular una lectura
	que nunca funcionó.)"""
	return "Jugador %d" % (player_id + 1)



# =============================================================================
# API PÚBLICA
# =============================================================================
func get_state() -> PaymentState:
	"""Retorna el estado actual del PaymentManager"""
	return _state


func is_awaiting_payment() -> bool:
	"""Retorna si está esperando un pago"""
	return _state in [PaymentState.AWAITING_SELECTION, PaymentState.AWAITING_PAYMENT]


func get_current_card() -> Dictionary:
	"""Retorna la carta actual en proceso de pago"""
	return _current_card


func cancel_current_payment() -> void:
	"""Cancela el pago actual"""
	_payment_ui._on_payment_cancelled()
