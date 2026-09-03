class_name CardInspectionLayer
extends Node

const CardScene = preload("res://scenes/cards/Card.tscn")

# Manejadores de patrones especiales extraídos de este archivo (2026-08-30,
# "módulos gordos" — mismo corte que BernardoAbilityHandler/
# ResponseWindowHandler). preload() en vez del nombre de clase global: son
# scripts NUEVOS de esta sesión, el editor todavía no los escaneó para
# registrar su class_name (ver el mismo comentario sobre
# CardNameSearchDialogScript en TriggerSystem.gd) — referenciarlos por
# nombre tiraría "Could not find type" hasta el próximo reimport manual.
const SearchAbilityHandlerScript = preload("res://scripts/ui/inspection/SearchAbilityHandler.gd")
const PreventionAbilityHandlerScript = preload("res://scripts/ui/inspection/PreventionAbilityHandler.gd")
const HandCementerioAbilityHandlerScript = preload("res://scripts/ui/inspection/HandCementerioAbilityHandler.gd")

# Caja de texto de habilidades en el arte impreso de la carta (medida sobre
# las imágenes reales en cartas_descargadas/): banda inferior desde ~75%
# hasta ~96.5% de la altura, dejando fuera el borde y el pie de crédito.
const ABILITY_TEXT_TOP_RATIO := 0.725
const ABILITY_TEXT_BOTTOM_RATIO := 0.915
const ABILITY_TEXT_SIDE_MARGIN := 14.0

var _main: Node = null

var inspected_card: Node = null
var _ability_buttons_panel: Control = null
var _inspected_source_card: Node = null
var _glowing_cards: Dictionary = {}
var _bernardo: BernardoAbilityHandler
var _response_window: ResponseWindowHandler
var _search_handler: RefCounted
var _prevention_handler: RefCounted
var _hand_cementerio_handler: RefCounted


func setup(main: Node) -> void:
	_main = main
	_bernardo = BernardoAbilityHandler.new()
	_bernardo.setup(self)
	_response_window = ResponseWindowHandler.new()
	_response_window.setup(self)
	_search_handler = SearchAbilityHandlerScript.new()
	_search_handler.setup(self)
	_prevention_handler = PreventionAbilityHandlerScript.new()
	_prevention_handler.setup(self)
	_hand_cementerio_handler = HandCementerioAbilityHandlerScript.new()
	_hand_cementerio_handler.setup(self)
	if not ActionPipeline.step_d_waiting.is_connected(_response_window._on_step_d_waiting):
		ActionPipeline.step_d_waiting.connect(_response_window._on_step_d_waiting)
	if not ActionPipeline.step_d_completed.is_connected(_response_window._on_step_d_completed):
		ActionPipeline.step_d_completed.connect(_response_window._on_step_d_completed)
	if not ActionPipeline.stack_object_resolved.is_connected(_on_ability_glow_resolved):
		ActionPipeline.stack_object_resolved.connect(_on_ability_glow_resolved)

	if not PriorityManager.priority_changed.is_connected(_on_priority_changed_refresh_glows):
		PriorityManager.priority_changed.connect(_on_priority_changed_refresh_glows)

	# Signo Amarillo (2026-08-26): ventana de respuesta para triggers ETB de
	# Oro/fuera del juego — separada de step_d_waiting (esa es para la Pila
	# de habilidades activadas/cartas jugadas; los triggers automáticos
	# tienen su propia señal en TriggerSystem).
	if not TriggerSystem.waiting_for_responses.is_connected(_response_window._on_trigger_waiting_for_responses):
		TriggerSystem.waiting_for_responses.connect(_response_window._on_trigger_waiting_for_responses)
	if not TriggerSystem.response_window_closed.is_connected(_response_window._on_trigger_response_window_closed):
		TriggerSystem.response_window_closed.connect(_response_window._on_trigger_response_window_closed)


func _on_priority_changed_refresh_glows(_player_id: int) -> void:
	refresh_activatable_glows()


# =============================================================================
# INDICADOR PASIVO DE HABILIDAD ACTIVABLE (brillo celeste)
# =============================================================================
func refresh_activatable_glows() -> void:
	"""Prende/apaga el brillo celeste de 'tiene una habilidad activable
	disponible ahora' en cada carta del jugador humano en juego — sin
	necesidad de abrir el panel de inspección. Reutiliza exactamente la
	misma detección y validación que _build_ability_buttons()/_validate_ability()."""
	if not _main:
		return

	if not GameManager.is_game_active or GameManager.active_player_id != 0:
		_clear_all_activatable_glows()
		return

	var in_vigilia = GameManager.current_phase == Constants.Phase.VIGILIA
	var has_priority_window = PriorityManager.priority_window_active and PriorityManager.can_act(0)
	if not in_vigilia and not has_priority_window:
		_clear_all_activatable_glows()
		return

	var candidates: Array = []
	if _main.player_field:
		candidates.append_array(_main.player_field.get_children())
	if _main.player_linea_ataque:
		candidates.append_array(_main.player_linea_ataque.get_children())
	if _main.player_gold:
		candidates.append_array(_main.player_gold.get_children())

	# Armas equipadas (2026-09-02, a pedido del usuario): son hijas del
	# Aliado portador, no de player_field/player_linea_ataque directo, así
	# que nunca aparecían acá — su propia habilidad podía activarse bien
	# (vive en el nodo del Arma, ajeno al estado de silenciado del
	# portador), pero nunca se le prendía el brillo celeste de "tiene una
	# habilidad activable disponible ahora".
	var weapon_candidates: Array = []
	for ally in candidates:
		if not is_instance_valid(ally):
			continue
		var weapons = ally.get("equipped_weapons")
		if weapons is Array:
			for w in weapons:
				if is_instance_valid(w):
					weapon_candidates.append(w)
	candidates.append_array(weapon_candidates)

	for card in candidates:
		if not (card is Card) or not is_instance_valid(card):
			continue
		if card.get("card_data") == null:
			continue
		var habilidad_text: String = card.card_data.get("habilidad", "")
		if habilidad_text.is_empty():
			card.set_activatable(false)
			continue
		var card_id: String = str(card.card_data.get("id", ""))
		var all_parsed := UniversalCardParser.parse_abilities(habilidad_text, card_id)
		var abilities: Array = all_parsed.filter(func(a): return a.get("ability_type", "") == "ACTIVATED")
		var can_activate_any := false
		for ability in abilities:
			# Estas cartas ya están EN JUEGO (candidates viene solo de
			# player_field/player_linea_ataque/player_gold) — mismo filtro que
			# _build_ability_buttons() (2026-08-31): una habilidad 'de tu
			# mano'/'de tu Cementerio' sin 'en juego' no tiene sentido acá,
			# aunque esté en la lista chica de _ability_is_hand_usable().
			if _ability_is_hand_or_cementerio_only(str(ability.get("raw_text", ""))):
				continue
			if _validate_ability(ability, card).get("can", false):
				can_activate_any = true
				break
		card.set_activatable(can_activate_any)


func _clear_all_activatable_glows() -> void:
	if not _main:
		return
	for container in [_main.player_field, _main.player_linea_ataque, _main.player_gold]:
		if not container:
			continue
		for card in container.get_children():
			if card is Card:
				card.set_activatable(false)


func on_card_right_clicked(card: Node) -> void:
	if card.esta_oculta:
		return
	_open_card_inspection(card)


func _open_card_inspection(card: Node) -> void:
	if inspected_card:
		return
	_inspected_source_card = card
	inspected_card = CardScene.instantiate()
	inspected_card.load_from_data(card.card_data)
	inspected_card.can_interact = false
	inspected_card.esta_oculta = card.esta_oculta
	inspected_card.scale = Vector2(0.1, 0.1)
	inspected_card.modulate.a = 0.0
	inspected_card.pivot_offset = inspected_card.custom_minimum_size / 2
	_main.inspection_container.add_child(inspected_card)
	# El clon no tiene la zona/dueño reales de 'card', así que sus propios
	# badges recién creados en _ready() quedan con el valor base — forzamos
	# el recálculo usando el contexto de la carta REAL (2026-08-31, corrige
	# a Manuel Bulnes mostrando 1 de Fuerza menos al inspeccionarlo).
	inspected_card.refresh_strength_badge(card)
	inspected_card.refresh_cost_badge(card)
	_main.inspection_layer.visible = true
	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(inspected_card, "scale", Vector2(3.2, 3.2), 0.3).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tween.tween_property(inspected_card, "modulate:a", 1.0, 0.2)
	tween.chain().tween_callback(_build_ability_buttons.bind(card))
	if not _main.inspection_blur.gui_input.is_connected(_on_inspection_blur_input):
		_main.inspection_blur.gui_input.connect(_on_inspection_blur_input)


func _on_inspection_blur_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		close_card_inspection()


func close_card_inspection() -> void:
	if not inspected_card:
		return
	if _ability_buttons_panel and is_instance_valid(_ability_buttons_panel):
		_ability_buttons_panel.queue_free()
		_ability_buttons_panel = null
	_inspected_source_card = null
	var card_to_remove = inspected_card
	inspected_card = null
	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(card_to_remove, "scale", Vector2(0.1, 0.1), 0.2).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_BACK)
	tween.tween_property(card_to_remove, "modulate:a", 0.0, 0.15)
	await tween.finished
	card_to_remove.queue_free()
	_main.inspection_layer.visible = false


func _ability_is_hand_usable(full_text: String) -> bool:
	"""Lista chica y explícita de habilidades usables DESDE LA MANO (2026-08-30)
	— ver el comentario en _build_ability_buttons() sobre por qué no es un
	permiso genérico por la sola presencia de 'tu mano' en el texto."""
	var lower := full_text.to_lower()
	if "desterrarlo de tu mano o en juego" in lower:
		return true  # Ramón Freire
	if "esta y otra carta de tu mano" in lower and "fondo de tu castillo" in lower:
		return true  # Tyet
	if "desterrarlo de tu mano o cementerio" in lower:
		return true  # Drácula
	if "barajar esta carta desde tu mano" in lower:
		return true  # Sacrificio Solar
	return false


func _ability_is_cementerio_usable(full_text: String) -> bool:
	"""Lista chica y explícita de habilidades usables DESDE EL CEMENTERIO
	(2026-08-30, p.ej. Espada del Juicio: 'Puedes Desterrarla de tu
	Cementerio para que un Aliado gane o pierda 2 de Fuerza permanentemente')
	— mismo criterio que _ability_is_hand_usable(), un permiso chico y
	explícito en vez de genérico por la sola presencia de 'tu Cementerio'."""
	var lower := full_text.to_lower()
	if "desterrarla de tu cementerio" in lower or "desterrarlo de tu cementerio" in lower:
		return true  # Espada del Juicio
	if "desterrarlo de tu mano o cementerio" in lower:
		return true  # Drácula
	return false


func _ability_is_hand_or_cementerio_only(full_text: String) -> bool:
	"""true si esta habilidad está en la lista chica de _ability_is_hand_usable()/
	_ability_is_cementerio_usable() (usable desde la mano y/o el Cementerio,
	ANTES de jugar la carta) pero su propio texto NO incluye también 'en
	juego' — o sea, no tiene sentido una vez la carta ya está en juego
	(2026-08-31, p.ej. la primera habilidad de Tyet: 'esta y otra carta de
	tu mano en el fondo de tu Castillo', solo tiene sentido con Tyet
	literalmente en la mano; o la de cancelar ataque de Drácula: 'de tu
	mano o Cementerio', sin 'en juego'). Ramón Freire SÍ dice 'de tu mano o
	EN JUEGO' explícito, así que esa sigue disponible en ambos casos."""
	if not (_ability_is_hand_usable(full_text) or _ability_is_cementerio_usable(full_text)):
		return false
	return not ("en juego" in full_text.to_lower())


func _build_ability_buttons(source_card: Node) -> void:
	if not is_instance_valid(source_card):
		return
	if not GameManager.is_game_active:
		return
	if GameManager.active_player_id != 0:
		return
	# controller_id, no owner_id (2026-08-29, a pedido del usuario): quién
	# puede activar la habilidad de una carta es quién la CONTROLA, no
	# necesariamente su dueño — importa para poder usar habilidades de una
	# carta ajena que controlás (p.ej. jugada por Miguel desde el Cementerio
	# rival). controller_id sigue a owner_id por defecto, así que para toda
	# carta normal esto se comporta igual que antes.
	var source_controller_id: int = source_card.controller_id if source_card.get("controller_id") != null else -1
	if source_controller_id != 0:
		return

	# Solo cartas EN JUEGO pueden activar habilidades (DAR) — sin esto,
	# zoomear una carta en la mano con una habilidad "Una vez por turno"
	# también mostraba el botón, aunque no tenía forma real de resolverse
	# desde ahí (2026-08-28, reportado por el usuario). Excepción chica y
	# explícita (2026-08-30, no un permiso genérico): algunas habilidades
	# se pueden usar DESDE LA MANO o EL CEMENTERIO, antes de jugar la carta
	# — p.ej. Ramón Freire ("Desterrarlo de tu mano o en juego..."), Tyet
	# ("poner esta y otra carta de tu mano en el fondo de tu Castillo...")
	# o Espada del Juicio ("Desterrarla de tu Cementerio..."). El chequeo
	# real es POR HABILIDAD (más abajo, con el raw_text de CADA una), no
	# acá por carta entera — 2026-08-30, bug real encontrado con Tyet: solo
	# UNA de sus dos habilidades es usable desde la mano (la otra necesita
	# estar en Reserva de Oro), pero como el gate viejo era "toda la carta
	# o nada", estando en la mano ofrecía IGUAL el botón de la que no
	# correspondía — clickearlo fallaba con 'ya no está en tu Reserva'.
	# Acá solo se decide si la ZONA en sí es una de las permitidas; cuál
	# habilidad puntual aplica se filtra en el loop de usable_abilities.
	var source_zone = source_card.get("current_zone")
	if source_zone == null:
		return
	var in_play: bool = source_zone in Constants.ZONES_IN_PLAY
	if not in_play and source_zone != Constants.Zone.MANO and source_zone != Constants.Zone.CEMENTERIO:
		return
	# Silencio de Cementerio (2026-08-30, Sable de Napoleón) — 'pierde su
	# habilidad' bloquea también las habilidades usables DESDE el
	# Cementerio (p.ej. Espada del Juicio). No aplica a Mano/en juego, solo
	# a cartas efectivamente marcadas mientras están en el Cementerio.
	if source_zone == Constants.Zone.CEMENTERIO and source_card.get("card_data") != null \
			and CardManager.is_cemetery_card_silenced(source_card.card_data):
		return

	# Permitir en Vigilia O cuando hay ventana de prioridad activa
	var in_vigilia = GameManager.current_phase == Constants.Phase.VIGILIA
	var has_priority_window = PriorityManager.priority_window_active and PriorityManager.can_act(0)
	if not in_vigilia and not has_priority_window:
		return

	# parse_abilities() es el Compilador Fase 1: detecta TRIGGER y ACTIVATED por Regex.
	# Solo mostramos botones para habilidades ACTIVATED (las que el jugador activa manualmente).
	var card_id: String = str(source_card.card_data.get("id", ""))
	var habilidad_text: String = source_card.card_data.get("habilidad", "")
	var all_parsed := UniversalCardParser.parse_abilities(habilidad_text, card_id)
	var abilities: Array = all_parsed.filter(func(a): return a.get("ability_type", "") == "ACTIVATED")

	if abilities.is_empty():
		return

	# Solo se muestran las habilidades usables ahora mismo — las bloqueadas
	# (sin oro, ya usadas este turno, etc.) se ocultan en vez de listarse en gris.
	var usable_abilities: Array = []
	for ability in abilities:
		var ability_raw_text: String = str(ability.get("raw_text", ""))
		if not in_play:
			var zone_ok: bool = (source_zone == Constants.Zone.MANO and _ability_is_hand_usable(ability_raw_text)) \
				or (source_zone == Constants.Zone.CEMENTERIO and _ability_is_cementerio_usable(ability_raw_text))
			if not zone_ok:
				continue
		elif _ability_is_hand_or_cementerio_only(ability_raw_text):
			# 2026-08-31, corrección a pedido del usuario: el chequeo de zona
			# de arriba solo corría cuando la carta NO estaba en juego — una
			# vez en juego, CUALQUIER habilidad ACTIVATED pasaba sin más,
			# aunque su propio texto dijera 'de tu mano'/'de tu Cementerio'
			# SIN 'o en juego' (p.ej. la primera de Tyet o la de cancelar
			# ataque de Drácula) — esas solo tienen sentido con la carta
			# literalmente en esa zona, no ya jugada.
			continue
		var validation = _validate_ability(ability, source_card)
		if validation.get("can", false):
			usable_abilities.append({"ability": ability, "validation": validation})

	if usable_abilities.is_empty():
		return

	if not is_instance_valid(inspected_card):
		return

	# Ubica cada botón exactamente sobre el fragmento de texto donde está impresa esa
	# habilidad en la carta, calculando la posición exacta dentro del texto completo
	# (incluyendo palabras clave de arriba y pasivas de abajo para no taparlas).
	var card_size: Vector2 = inspected_card.custom_minimum_size
	var zone_top: float = card_size.y * ABILITY_TEXT_TOP_RATIO
	var zone_height: float = card_size.y * (ABILITY_TEXT_BOTTOM_RATIO - ABILITY_TEXT_TOP_RATIO)
	var full_text_length: int = maxi(habilidad_text.strip_edges().length(), 1)
	var h_lower: String = habilidad_text.to_lower()

	var offsets_by_index: Dictionary = {}
	for a in all_parsed:
		var raw_t: String = a.get("raw_text", "")
		var idx: int = a.get("ability_index", -1)
		var start_pos: int = -1
		if not raw_t.is_empty():
			var first_chunk: String = raw_t.split(".")[0].strip_edges().to_lower()
			if first_chunk.length() > 6:
				first_chunk = first_chunk.substr(0, 30)
			start_pos = h_lower.find(first_chunk)
		if start_pos < 0:
			start_pos = 0
		var len_a: int = maxi(raw_t.length(), 1)
		var y0: float = zone_top + zone_height * (float(start_pos) / float(full_text_length))
		var y1: float = zone_top + zone_height * (float(start_pos + len_a) / float(full_text_length))
		y0 = clampf(y0, zone_top, zone_top + zone_height)
		y1 = clampf(y1, zone_top, zone_top + zone_height)
		if y1 - y0 < 18.0:
			y1 = minf(y0 + 18.0, zone_top + zone_height)
		offsets_by_index[idx] = Vector2(y0, y1)

	var panel = Control.new()
	panel.name = "AbilityOverlayButtons"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inspected_card.add_child(panel)
	_ability_buttons_panel = panel

	# source_card_node: se necesita la carta VIVA (no solo sus datos) para que
	# ActionPipeline._resolve_ability() pueda ejecutar el efecto real vía
	# TriggerSystem._execute_parsed_action() (requiere un Node, no un Dictionary).
	var context = {"controller_id": 0, "source_card_node": source_card}
	for entry in usable_abilities:
		var ability = entry.ability
		var validation = entry.validation
		var idx = ability.get("ability_index", -1)
		if not offsets_by_index.has(idx):
			continue
		var y_range: Vector2 = offsets_by_index[idx]

		var btn = _create_ability_overlay_button(ability, validation)
		var btn_y: float = y_range.x + 2.0
		var btn_h: float = maxi(16.0, (y_range.y - y_range.x) - 4.0)
		btn.position = Vector2(ABILITY_TEXT_SIDE_MARGIN, btn_y)
		btn.size = Vector2(card_size.x - ABILITY_TEXT_SIDE_MARGIN * 2.0, btn_h)
		btn.mouse_filter = Control.MOUSE_FILTER_STOP

		var captured           = ability.duplicate()
		var captured_card_data = source_card.card_data.duplicate()
		var card_for_glow      = source_card  # capturado antes del cierre

		# Patrón especial de Bernardo O'Higgins (2026-08-26): coste alternativo
		# (barajar un Arma/Aliado Caballero) + elegir entre dos efectos con
		# objetivo (desterrar ≤3 / cancelar habilidad) — no encaja en el
		# sistema genérico de costes/acciones de ActionPipeline (un solo tipo
		# de coste, sin targeting), así que se resuelve aparte.
		var ability_lower: String = str(captured.get("raw_text", "")).to_lower()
		var is_bernardo_pattern: bool = ("barajar" in ability_lower and "caballero" in ability_lower
			and ("desterrar" in ability_lower or "cancelar" in ability_lower))

		if is_bernardo_pattern:
			btn.pressed.connect(func():
				close_card_inspection()
				await _bernardo._activate_bernardo_shuffle_removal(card_for_glow, captured)
			)
			panel.add_child(btn)
			continue

		# Patrón especial de Padre de la Patria (2026-08-28): "genera un Oro
		# para jugar X" es Oro Virtual RESTRINGIDO (GoldManager.
		# restricted_gold_pools), un concepto que ActionPipeline no conoce —
		# se genera directo acá, sin pasar por el pipeline genérico.
		var is_padre_patria_gold_pattern: bool = ("genera" in ability_lower
			and "para jugar" in ability_lower and "caballero" in ability_lower)
		if is_padre_patria_gold_pattern:
			btn.pressed.connect(func():
				close_card_inspection()
				_search_handler._activate_padre_patria_gold(card_for_glow, captured)
			)
			panel.add_child(btn)
			continue

		# Patrón especial de Legión Paladín (2026-08-28): "Puedes Desterrarlo
		# para prevenir que un Aliado que controles salga del juego" — costo
		# de auto-Destierro + Prevención (DAR - Utilizar Habilidades:
		# EffectController._leave_play_preventions), un concepto que
		# ActionPipeline tampoco conoce. 2026-08-29: la API de esta carta es
		# inestable entre fetches — en un fetch devolvió 'salgan'/'hasta dos
		# Aliados' (plural), en el fetch más reciente (usado ahora, y
		# sincronizado al cache local) volvió a 'salga'/'un Aliado' (singular)
		# — se dejan ambas formas en la detección por si vuelve a cambiar,
		# pero la carga de Prevención que se agrega abajo sigue el texto
		# actual (1, no 2).
		var is_legion_paladin_prevention_pattern: bool = ("desterrarlo" in ability_lower
			and "prevenir" in ability_lower
			and ("salga del juego" in ability_lower or "salgan del juego" in ability_lower))
		if is_legion_paladin_prevention_pattern:
			btn.pressed.connect(func():
				close_card_inspection()
				_prevention_handler._activate_legion_paladin_prevention(card_for_glow)
			)
			panel.add_child(btn)
			continue

		# Patrón especial de Don de Amma (2026-08-29): "Una vez por turno,
		# puedes Desterrar un Oro con habilidad de tu Reserva. Luego, busca
		# un Oro en tu Castillo y ponlo en tu Reserva." — costo de Desterrar
		# UNA carta elegida entre los Oros-con-habilidad propios en Reserva
		# (no necesariamente esta misma), seguido de una búsqueda que no va
		# a la mano — ActionPipeline no tiene ninguno de los dos conceptos.
		var is_don_de_amma_pattern: bool = ("desterrar un oro" in ability_lower
			and "con habilidad" in ability_lower and "busca un oro" in ability_lower)
		if is_don_de_amma_pattern:
			btn.pressed.connect(func():
				close_card_inspection()
				await _search_handler._activate_don_de_amma(card_for_glow, captured)
			)
			panel.add_child(btn)
			continue

		# Patrón especial de Tesoro de los Césares (2026-08-29): "Una vez por
		# turno, puedes Barajar una carta de tu mano para nombrar una carta.
		# Esa carta cuesta un Oro adicional el próximo turno." — costo de
		# Barajar (mano → mazo, no descarte) + nombrar una carta CUALQUIERA
		# del juego (no un objeto en juego, un NOMBRE) con un recargo de
		# coste que recién arranca el turno siguiente — ActionPipeline no
		# tiene ninguno de los tres conceptos (costo Barajar, nombrar, tax
		# diferido). Requiere el fix de parse_abilities() de esta misma
		# sesión que une la segunda oración (sin coste/trigger propio) a la
		# ACTIVADA anterior — sin eso 'cuesta un oro adicional' nunca
		# aparecía en raw_text y este patrón no matcheaba nunca.
		var is_tesoro_cesares_pattern: bool = ("barajar una carta de tu mano" in ability_lower
			and "nombrar una carta" in ability_lower and "cuesta un oro adicional" in ability_lower)
		if is_tesoro_cesares_pattern:
			btn.pressed.connect(func():
				close_card_inspection()
				await _search_handler._activate_tesoro_cesares_name_tax(card_for_glow, captured)
			)
			panel.add_child(btn)
			continue

		# Patrón especial de Miguel (2026-08-29): "Una vez en tu turno, juega
		# una carta de tu mano o de un Cementerio reduciendo su coste en un
		# Oro, hasta un mínimo de 0." — elegir entre mano Y Cementerio a la
		# vez, con descuento de -1/piso 0 aplicado solo a esa carta, no es
		# nada que ActionPipeline sepa hacer solo. Reusa GoldManager.
		# play_card() completo (fases, portador de Armas, Talismanes) con el
		# mismo mecanismo de descuento puntual que 'Muestra X para reducir
		# el coste' (El Rey y el Verdugo, ya en GoldManager.play_card()).
		var is_miguel_pattern: bool = ("juega una carta de tu mano" in ability_lower
			and "cementerio" in ability_lower and "reduciendo su coste" in ability_lower)
		if is_miguel_pattern:
			btn.pressed.connect(func():
				close_card_inspection()
				await _search_handler._activate_miguel_discount_play(card_for_glow, captured)
			)
			panel.add_child(btn)
			continue

		# Patrón especial de Tyet (2026-08-29): "Puedes pagar este Oro para
		# que un Oro pierda su habilidad este turno y muévelo al Oro Pagado."
		# Costo = esta misma carta (CostType.SELF_AS_GOLD, ActionPipeline no
		# lo conoce). Efecto sobre OTRO Oro elegido: silencio temporal
		# (KeywordManager.silence_card(..., "turn"), se autolimpia solo al
		# empezar el próximo turno) + mover a Oro Pagado.
		var is_tyet_pattern: bool = (("pagar este oro" in ability_lower or "puedes pagarlo" in ability_lower)
			and "pierda su habilidad" in ability_lower and "oro pagado" in ability_lower)
		if is_tyet_pattern:
			btn.pressed.connect(func():
				close_card_inspection()
				await _hand_cementerio_handler._activate_tyet_silence_and_pay(card_for_glow, captured)
			)
			panel.add_child(btn)
			continue

		# Segundo patrón de Tyet (2026-08-30): "Puedes poner esta y otra
		# carta de tu mano en el fondo de tu Castillo y Robar dos cartas." —
		# usable DESDE LA MANO (ver _ability_is_hand_usable()). Costo:
		# esta carta + otra elegida de la mano, ambas al fondo del mazo.
		var is_tyet_mill_pattern: bool = ("esta y otra carta de tu mano" in ability_lower
			and "fondo de tu castillo" in ability_lower)
		if is_tyet_mill_pattern:
			btn.pressed.connect(func():
				close_card_inspection()
				await _hand_cementerio_handler._activate_tyet_mill_and_draw(card_for_glow, captured)
			)
			panel.add_child(btn)
			continue

		# Patrón especial de Ramón Freire (2026-08-30): "Si controlas
		# Aliados de coste 2 o más, puedes Desterrarlo de tu mano o en
		# juego para generar un Oro para jugar Armas." — usable DESDE LA
		# MANO o ya en juego, con una condición previa (controlar un Aliado
		# de coste ≥2) que ActionPipeline no sabe verificar.
		var is_ramon_freire_pattern: bool = ("desterrarlo de tu mano o en juego" in ability_lower
			and "generar un oro" in ability_lower)
		if is_ramon_freire_pattern:
			btn.pressed.connect(func():
				close_card_inspection()
				await _hand_cementerio_handler._activate_ramon_freire_banish_for_gold(card_for_glow, captured)
			)
			panel.add_child(btn)
			continue

		# Patrón especial de Espada de O'Higgins (2026-08-30): "En tu Vigilia,
		# una vez por turno, puedes Barajar una carta que no sea Oro o buscar
		# un Oro en tu Castillo y ponerlo en tu mano." — elección A/B entre
		# dos efectos que no comparten nada (Barajar de mano vs buscar en
		# mazo), ActionPipeline solo resuelve un tipo de acción por
		# habilidad, no una elección genérica entre dos.
		var is_espada_ohiggins_vigilia_pattern: bool = ("barajar una carta que no sea oro" in ability_lower
			and "buscar un oro en tu castillo" in ability_lower)
		if is_espada_ohiggins_vigilia_pattern:
			btn.pressed.connect(func():
				close_card_inspection()
				await _search_handler._activate_espada_ohiggins_vigilia_choice(card_for_glow, captured)
			)
			panel.add_child(btn)
			continue

		# Patrón especial de Infernum Vox (2026-08-30): "Una vez por turno,
		# puedes mirar seis cartas del tope de un Castillo y devolverlas en
		# cualquier orden en el tope y/o fondo del Castillo." — puro
		# reordenamiento (no es 'mirar y jugar/quedarte una', es 'mirar y
		# repartir+ordenar TODAS'), un concepto que ActionPipeline no tiene.
		var is_infernum_vox_pattern: bool = ("mirar" in ability_lower
			and "cartas del tope de un castillo" in ability_lower
			and "tope y/o fondo" in ability_lower)
		if is_infernum_vox_pattern:
			btn.pressed.connect(func():
				close_card_inspection()
				await _search_handler._activate_infernum_vox_look_reorder(card_for_glow, captured)
			)
			panel.add_child(btn)
			continue

		# Patrón especial de Paladín Bestiarium — habilidad 1 (2026-08-30):
		# "Una vez por turno, puedes Descartar una carta para jugar un Arma
		# de tu mano reduciendo su coste en un Oro, hasta un mínimo de 0." —
		# el costo (descartar CUALQUIER carta) y el efecto (jugar OTRA carta
		# distinta con descuento) no coinciden, ActionPipeline solo sabe
		# resolver costo+efecto sobre la MISMA carta.
		var is_paladin_bestiarium_discard_pattern: bool = ("descartar una carta para jugar un arma" in ability_lower
			and "reduciendo su coste" in ability_lower)
		if is_paladin_bestiarium_discard_pattern:
			btn.pressed.connect(func():
				close_card_inspection()
				await _prevention_handler._activate_paladin_bestiarium_discard_weapon_discount(card_for_glow, captured)
			)
			panel.add_child(btn)
			continue

		# Patrón especial de Paladín Bestiarium — habilidad 2 (2026-08-30):
		# "Una vez en tu turno, puedes Descartar o subir un Arma que
		# controles a la mano para Anular una carta de coste 1 o menos." —
		# costo con DOS mecanismos alternativos (descartar O devolver a la
		# mano) sobre un Arma EN JUEGO (no la propia carta), más un
		# objetivo con filtro de coste — nada de esto lo resuelve
		# ActionPipeline solo.
		var is_paladin_bestiarium_annul_pattern: bool = ("descartar o subir un arma que controles" in ability_lower
			and "anular una carta de coste" in ability_lower)
		if is_paladin_bestiarium_annul_pattern:
			btn.pressed.connect(func():
				close_card_inspection()
				await _prevention_handler._activate_paladin_bestiarium_weapon_annul(card_for_glow, captured)
			)
			panel.add_child(btn)
			continue

		# Patrón especial de Aho (2026-08-30): "Una vez por turno, Destierra
		# un Aliado o Tótem y cinco cartas del tope de un Castillo." — dos
		# destierros independientes (objetivo elegido + N del tope de un
		# mazo a elección) unidos por 'y', ninguno de los dos conceptos lo
		# resuelve ActionPipeline solo.
		var is_aho_banish_pattern: bool = ("destierra un aliado o" in ability_lower
			and "cartas del tope de un castillo" in ability_lower)
		if is_aho_banish_pattern:
			btn.pressed.connect(func():
				close_card_inspection()
				await _search_handler._activate_aho_banish_ally_and_deck(card_for_glow, captured)
			)
			panel.add_child(btn)
			continue

		# Patrón especial de Chakram (2026-08-30): "Una vez por turno, puedes
		# mirar la mano de tu oponente y elegir una carta de ahí que no sea
		# Oro para que no pueda ser jugada hasta tu próximo turno y Roba una
		# carta." — reveal privado de la mano rival + candado por carta
		# puntual (GoldManager.lock_card_from_playing()), ningún concepto que
		# ActionPipeline resuelva solo.
		var is_chakram_pattern: bool = ("mirar la mano de tu oponente" in ability_lower
			and "no pueda ser jugada" in ability_lower)
		if is_chakram_pattern:
			btn.pressed.connect(func():
				close_card_inspection()
				await _search_handler._activate_chakram_look_and_lock(card_for_glow, captured)
			)
			panel.add_child(btn)
			continue

		# Patrón especial de Estaca (2026-08-30): "Una vez por turno, puedes
		# Robar tres cartas, Barajar una carta oponente que no sea Oro y
		# tantas cartas de tu mano como coste tenga." — la carta oponente no
		# dice zona (EN JUEGO, ver [[project_no_zone_means_in_play]]) y la
		# cantidad a barajar de la propia mano es DINÁMICA (el coste de la
		# carta rival elegida), nada de esto lo resuelve ActionPipeline solo.
		var is_estaca_pattern: bool = ("barajar una carta oponente que no sea oro" in ability_lower
			and "tantas cartas de tu mano como coste tenga" in ability_lower)
		if is_estaca_pattern:
			btn.pressed.connect(func():
				close_card_inspection()
				await _hand_cementerio_handler._activate_estaca_draw_and_shuffle(card_for_glow, captured)
			)
			panel.add_child(btn)
			continue

		# Segundo patrón de Estaca (2026-08-30): "Puedes Desterrarla para
		# prevenir que una carta sea afectada por un efecto oponente." —
		# costo de autodesterrarse (femenino, 'Desterrarla' — ver el fix de
		# UniversalCardParser.pays_self_banish) + elegir qué carta proteger.
		var is_estaca_prevention_pattern: bool = ("desterrarla para prevenir" in ability_lower
			and "efecto oponente" in ability_lower)
		if is_estaca_prevention_pattern:
			btn.pressed.connect(func():
				close_card_inspection()
				await _prevention_handler._activate_estaca_banish_for_prevention(card_for_glow, captured)
			)
			panel.add_child(btn)
			continue

		# Patrón especial de Espada del Juicio (2026-08-30): "Puedes
		# Desterrarla de tu Cementerio para que un Aliado gane o pierda 2
		# de Fuerza permanentemente." — primera habilidad usable DESDE EL
		# CEMENTERIO de esta sesión (ver _ability_is_cementerio_usable()),
		# costo sobre el DATO real del Cementerio (no sobre este nodo de
		# solo vista) + elegir Aliado y signo del bono.
		var is_espada_juicio_pattern: bool = ("desterrarla de tu cementerio" in ability_lower
			and "gane o pierda 2 de fuerza" in ability_lower)
		if is_espada_juicio_pattern:
			btn.pressed.connect(func():
				close_card_inspection()
				await _hand_cementerio_handler._activate_espada_juicio_banish_cemetery_for_buff(card_for_glow, captured)
			)
			panel.add_child(btn)
			continue

		# Patrón especial de Drácula, tercera habilidad (2026-08-30): "Puedes
		# convertirlo en un Oro sin habilidad para prevenir que una habilidad
		# sea cancelada o un Aliado de coste 1 sea Anulado." — coste de
		# autoconvertirse (is_converted=true sobre SÍ MISMO, sin elegir
		# objetivo, a diferencia del Convertir de Capitán O'Brien), efecto de
		# carga consumible sobre la pila (EffectController.
		# try_consume_stack_annul_cancel_prevention(), consumida desde
		# LinkedEffectRegistry._execute_cancel()/_execute_annul()).
		var is_dracula_convert_pattern: bool = ("convertirlo en un oro sin habilidad" in ability_lower
			and "prevenir" in ability_lower)
		if is_dracula_convert_pattern:
			btn.pressed.connect(func():
				close_card_inspection()
				_prevention_handler._activate_dracula_convert_for_prevention(card_for_glow, captured)
			)
			panel.add_child(btn)
			continue

		# Patrón especial de Drácula, cuarta habilidad (2026-08-30): "Puedes
		# Desterrarlo de tu mano o Cementerio para cancelar el ataque de
		# hasta dos Aliados." — usable DESDE LA MANO o el CEMENTERIO (ver
		# _ability_is_hand_usable()/_ability_is_cementerio_usable()), primera
		# habilidad que cancela un ataque ya declarado (nuevo: sacar de
		# GameManager.attackers + revertir el aspecto visual, sin pasar por
		# undeclare_attacker() porque no requiere ser el propio turno del
		# controlador de ese Aliado).
		var is_dracula_cancel_attack_pattern: bool = ("desterrarlo de tu mano o cementerio" in ability_lower
			and "cancelar el ataque" in ability_lower)
		if is_dracula_cancel_attack_pattern:
			btn.pressed.connect(func():
				close_card_inspection()
				await _hand_cementerio_handler._activate_dracula_cancel_attacks(card_for_glow, captured)
			)
			panel.add_child(btn)
			continue

		# Patrón especial de Espíritu Kotaix, segunda habilidad (2026-09-02):
		# "Una vez por turno, Roba dos cartas y Baraja una carta oponente que
		# no sea Oro. Esta habilidad no puede ser cancelada." — mismo patrón
		# que Estaca (Robo incondicional + Baraja de una carta rival en juego
		# excluyendo Oro), sin el barajado adicional de la propia mano.
		var is_kotaix_pattern: bool = "baraja una carta oponente que no sea oro" in ability_lower
		if is_kotaix_pattern:
			btn.pressed.connect(func():
				close_card_inspection()
				await _search_handler._activate_kotaix_draw_and_shuffle_opponent(card_for_glow, captured)
			)
			panel.add_child(btn)
			continue

		# Patrón especial de Sacrificio Solar (2026-09-02): "Puedes pagar un
		# Oro y Barajar esta carta desde tu mano para Desterrar o Barajar
		# una carta de coste 2 o menos y Robar una carta." — usable DESDE LA
		# MANO (ver _ability_is_hand_usable()), costo de Oro + la propia
		# carta (autobarajarse desde la mano, no destierro ni descarte —
		# concepto que ActionPipeline no tiene) y elección Destierra/Baraja
		# sobre el objetivo, algo que tampoco resuelve solo.
		var is_sacrificio_solar_pattern: bool = "barajar esta carta desde tu mano" in ability_lower
		if is_sacrificio_solar_pattern:
			btn.pressed.connect(func():
				close_card_inspection()
				await _hand_cementerio_handler._activate_sacrificio_solar_self_shuffle_banish_or_shuffle(card_for_glow, captured)
			)
			panel.add_child(btn)
			continue

		# Patrón especial de La Ouija (2026-08-31): "Una vez por turno, puedes
		# jugar una carta de tu Cementerio o del tope de tu Castillo." — dos
		# zonas de origen alternativas ('de tu Cementerio' Y 'del tope de tu
		# Castillo', ambas con posesivo — solo las propias) que ActionPipeline
		# no resuelve solo (solo sabe jugar la carta que ya tenés en mano).
		var is_ouija_pattern: bool = ("jugar una carta de tu cementerio" in ability_lower
			and "tope de tu castillo" in ability_lower)
		if is_ouija_pattern:
			btn.pressed.connect(func():
				close_card_inspection()
				await _hand_cementerio_handler._activate_ouija_play_from_cemetery_or_deck_top(card_for_glow, captured)
			)
			panel.add_child(btn)
			continue

		# Un solo click: cerrar inspección → empujar a la Pila → Paso D automático
		btn.pressed.connect(func():
			close_card_inspection()
			await _activate_ability_via_pipeline(card_for_glow, captured_card_data, captured, context)
		)
		panel.add_child(btn)


func _validate_ability(ability: Dictionary, source_card: Node) -> Dictionary:
	"""Valida si una habilidad activada puede ejecutarse ahora.
	Comprueba: prioridad, oro disponible, cartas en mano, carta girada, ActionPipeline."""
	if PriorityManager.priority_window_active and not PriorityManager.can_act(0):
		return {"can": false, "reason": "Sin prioridad ahora"}

	# Silenciada (por instancia o por nombre, ver KeywordManager.is_silenced())
	# = pierde TODAS sus habilidades, activadas incluidas — antes esto solo
	# se chequeaba para triggers (TriggerSystem._check_trigger_conditions()),
	# los botones de habilidad activada seguían mostrándose igual (2026-08-29).
	if KeywordManager.is_silenced(source_card):
		return {"can": false, "reason": "Sin habilidad (silenciada)"}

	# Restricción de fase por texto propio de la carta (2026-08-30, p.ej.
	# Espada de O'Higgins: "En tu Vigilia, una vez por turno, puedes...").
	# _build_ability_buttons() ya permite el botón en Vigilia O en ventana
	# de prioridad (genérico, para cartas sin restricción de fase) — esto
	# cierra el caso más estricto de una carta que solo se puede usar en su
	# propia Vigilia, ni siquiera con prioridad abierta en otra fase.
	var raw_lower: String = str(ability.get("raw_text", "")).to_lower()
	if "en tu vigilia" in raw_lower and GameManager.current_phase != Constants.Phase.VIGILIA:
		return {"can": false, "reason": "Solo en tu Vigilia"}

	var cost_type   = ability.get("cost_type",   UniversalCardParser.CostType.NONE)
	var cost_amount = ability.get("cost_amount", 0)

	match cost_type:
		UniversalCardParser.CostType.GOLD:
			if _main._gold_manager:
				var available = _main._gold_manager.get_oro_disponible()
				if not _main._gold_manager.puede_pagar(cost_amount):
					return {"can": false, "reason": "Oro insuficiente (%d/%d)" % [available, cost_amount]}

		UniversalCardParser.CostType.DISCARD:
			var hand = _main.player_hand
			var count = hand.cards.size() if hand and hand.get("cards") != null else hand.get_child_count() if hand else 0
			if count == 0:
				return {"can": false, "reason": "Mano vacía"}

		UniversalCardParser.CostType.TAP:
			if source_card.get("is_tapped") == true:
				return {"can": false, "reason": "Carta ya girada"}

		UniversalCardParser.CostType.ONCE_PER_TURN:
			# instance_id, NO card_data.id (2026-08-30, corrección: card_data.id
			# es el ID de la carta/impresión, compartido por TODAS las copias en
			# juego — con 2 Aho en juego, usar uno marcaba el cupo también para
			# el otro. Cada copia física necesita su propio cupo).
			var card_id: String = str(source_card.get_instance_id())
			var ability_idx: int = ability.get("ability_index", 0)
			var turn: int = GameManager.current_turn
			if UniversalCardParser.turn_registry.was_used(card_id, ability_idx, turn):
				return {"can": false, "reason": "Ya usada este turno"}

	# Flag once_per_turn desde parse_abilities() (puede venir sin cost_type ONCE_PER_TURN)
	if ability.get("once_per_turn", false) and cost_type != UniversalCardParser.CostType.ONCE_PER_TURN:
		var card_id: String = str(source_card.get_instance_id())
		var ability_idx: int = ability.get("ability_index", 0)
		var turn: int = GameManager.current_turn
		if UniversalCardParser.turn_registry.was_used(card_id, ability_idx, turn):
			return {"can": false, "reason": "Ya usada este turno"}

	# Verificación adicional con ActionPipeline — source_card_node en el
	# context (2026-08-30) para que can_activate_ability() también use el
	# instance_id, no el id compartido entre copias.
	var context = {"controller_id": 0, "source_card_node": source_card}
	var check = ActionPipeline.can_activate_ability(source_card.card_data, ability, context)
	if not check.get("can", true):
		return {"can": false, "reason": check.get("reason", "No disponible")}

	return {"can": true, "reason": ""}


func _create_ability_overlay_button(ability: Dictionary, validation: Dictionary) -> Button:
	"""Botón superpuesto sobre el párrafo de la carta donde está impresa esta
	habilidad. No dibuja texto propio (la carta ya lo muestra); un
	rectángulo de bordes curvos color celeste marca SIEMPRE qué habilidad se
	puede activar y dónde clickear (2026-08-26, a pedido del usuario — antes
	el borde solo aparecía al pasar el mouse, así que no había forma de
	saber de antemano qué parte de la carta era clickeable). Al pasar el
	mouse se resalta más fuerte, y lleva el costo y efecto como tooltip."""
	var cost_type   = ability.get("cost_type",   UniversalCardParser.CostType.NONE)
	var cost_amount = ability.get("cost_amount", 0)
	var effect_text = ability.get("effect_text", ability.get("raw_text", ""))

	var cost_label: String
	match cost_type:
		UniversalCardParser.CostType.GOLD:
			cost_label = "Paga %d Oro" % cost_amount
		UniversalCardParser.CostType.ONCE_PER_TURN:
			cost_label = "Una vez por turno"
		UniversalCardParser.CostType.DISCARD:
			cost_label = "Descarta una carta"
		UniversalCardParser.CostType.TAP:
			cost_label = "Gira esta carta"
		_:
			cost_label = ability.get("cost_text", "")

	var btn = Button.new()
	btn.text = ""
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.tooltip_text = ""  # Sin texto negro explicativo en hover

	# Contorno celeste fino y fijo (1px siempre, sin expandirse al poner el mouse)
	var style_normal = StyleBoxFlat.new()
	style_normal.bg_color = Color(0.2, 0.65, 1.0, 0.04)
	style_normal.set_border_width_all(1)
	style_normal.border_color = Color(0.35, 0.80, 1.0, 0.75)
	style_normal.set_corner_radius_all(6)
	btn.add_theme_stylebox_override("normal", style_normal)
	btn.add_theme_stylebox_override("focus", style_normal)

	var style_hover = StyleBoxFlat.new()
	style_hover.bg_color = Color(0.2, 0.65, 1.0, 0.12)
	style_hover.set_border_width_all(1)
	style_hover.border_color = Color(0.48, 0.86, 1.0, 0.92)
	style_hover.set_corner_radius_all(6)
	btn.add_theme_stylebox_override("hover", style_hover)

	var style_pressed = StyleBoxFlat.new()
	style_pressed.bg_color = Color(0.2, 0.65, 1.0, 0.18)
	style_pressed.set_border_width_all(1)
	style_pressed.border_color = Color(0.55, 0.90, 1.0, 1.0)
	style_pressed.set_corner_radius_all(6)
	btn.add_theme_stylebox_override("pressed", style_pressed)

	return btn


func _activate_ability_via_pipeline(card_node: Node, card_data: Dictionary, ability: Dictionary, context: Dictionary) -> void:
	"""Envía la habilidad a la Pila LIFO y arranca el flujo Paso D.
	ActionPipeline se encarga de: Paso B (pagar), Paso C (triggers), añadir a pila, Paso D (ventana respuesta)."""
	print("[CardInspection] Activando habilidad '%s' vía Pila" % ability.get("cost_text", "?"))
	var result = await ActionPipeline.activate_ability(card_data, ability, context)
	if not result.get("success", false):
		_main._update_debug("Habilidad no pudo activarse: %s" % result.get("reason", "?"))
		return
	# Brillo en la carta fuente mientras la habilidad está en la pila
	if is_instance_valid(card_node):
		_start_card_glow(card_node)


func _activate_ability_with_glow(card_node: Node, card_data: Dictionary, ability: Dictionary, context: Dictionary) -> void:
	# Alias mantenido por compatibilidad — delega al nuevo método
	await _activate_ability_via_pipeline(card_node, card_data, ability, context)


# El caso especial de Bernardo O'Higgins (coste alternativo + elección de
# efecto con objetivo) se movió a BernardoAbilityHandler.gd (2026-08-28,
# "módulos gordos") — ver _bernardo, montado en setup().


func _start_card_glow(card_node: Node) -> void:
	if not is_instance_valid(card_node):
		return
	if card_node in _glowing_cards:
		_glowing_cards[card_node].kill()
	var tween = create_tween().set_loops()
	tween.tween_property(card_node, "modulate", Color(1.5, 1.2, 0.2, 1.0), 0.45)
	tween.tween_property(card_node, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.45)
	_glowing_cards[card_node] = tween


func _stop_card_glow(card_node: Node) -> void:
	if card_node in _glowing_cards:
		_glowing_cards[card_node].kill()
		_glowing_cards.erase(card_node)
	if is_instance_valid(card_node):
		var tw = create_tween()
		tw.tween_property(card_node, "modulate", Color.WHITE, 0.25)


func _on_ability_glow_resolved(stack_obj: Dictionary, _result: Dictionary) -> void:
	if not stack_obj.get("card_data", {}).get("_is_activated_ability", false):
		return
	var source_id = stack_obj.get("card_data", {}).get("id", "")
	if source_id.is_empty():
		return
	for card_node in _glowing_cards.keys():
		if not is_instance_valid(card_node):
			_glowing_cards.erase(card_node)
			continue
		var cd = card_node.get("card_data") if card_node.get("card_data") != null else {}
		if cd.get("id", "") == source_id:
			_stop_card_glow(card_node)
			break


# Ventanas de respuesta (Paso D genérico + Signo Amarillo) y
# _show_puedes_confirm() (sin llamadores, código muerto) se movieron a
# ResponseWindowHandler.gd (2026-08-28, "módulos gordos") — ver
# _response_window, montado en setup().
