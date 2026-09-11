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

# Validación de habilidades ACTIVADAS + ciclo de vida del botón superpuesto,
# y los 4 grupos (por posición en el archivo original) del if-chain de
# patrones especiales de _build_ability_buttons() — extraídos de este mismo
# archivo (2026-09-06, "módulos gordos", Fase 2 — ver
# iterative-booping-abelson.md). Mismo motivo de preload() que arriba.
const AbilityButtonSupportScript = preload("res://scripts/ui/inspection/AbilityButtonSupport.gd")
const AbilityButtonPatternsAScript = preload("res://scripts/ui/inspection/AbilityButtonPatternsA.gd")
const AbilityButtonPatternsBScript = preload("res://scripts/ui/inspection/AbilityButtonPatternsB.gd")
const AbilityButtonPatternsCScript = preload("res://scripts/ui/inspection/AbilityButtonPatternsC.gd")
const AbilityButtonPatternsDScript = preload("res://scripts/ui/inspection/AbilityButtonPatternsD.gd")

# Caja de texto de habilidades en el arte impreso de la carta (medida sobre
# las imágenes reales en cartas_descargadas/): marco inferior desde ~76.5%
# hasta ~94.0% de la altura, dejando fuera el borde y el pie de crédito.
const ABILITY_TEXT_TOP_RATIO := 0.765
const ABILITY_TEXT_BOTTOM_RATIO := 0.940
const ABILITY_TEXT_SIDE_MARGIN := 14.0
const ABILITY_TEXT_RIGHT_MARGIN := 42.0  ## Margen derecho para no tapar el sello de la edición

var _main: Node = null

var inspected_card: Node = null
var _ability_buttons_panel: Control = null
var _inspected_source_card: Node = null
var _bernardo: BernardoAbilityHandler
var _response_window: ResponseWindowHandler
var _search_handler: RefCounted
var _prevention_handler: RefCounted
var _hand_cementerio_handler: RefCounted
var _button_support: RefCounted
var _pattern_group_a: RefCounted
var _pattern_group_b: RefCounted
var _pattern_group_c: RefCounted
var _pattern_group_d: RefCounted


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
	_button_support = AbilityButtonSupportScript.new()
	_button_support.setup(self)
	_pattern_group_a = AbilityButtonPatternsAScript.new()
	_pattern_group_a.setup(self)
	_pattern_group_b = AbilityButtonPatternsBScript.new()
	_pattern_group_b.setup(self)
	_pattern_group_c = AbilityButtonPatternsCScript.new()
	_pattern_group_c.setup(self)
	_pattern_group_d = AbilityButtonPatternsDScript.new()
	_pattern_group_d.setup(self)
	if not ActionPipeline.step_d_waiting.is_connected(_response_window._on_step_d_waiting):
		ActionPipeline.step_d_waiting.connect(_response_window._on_step_d_waiting)
	if not ActionPipeline.step_d_completed.is_connected(_response_window._on_step_d_completed):
		ActionPipeline.step_d_completed.connect(_response_window._on_step_d_completed)
	if not ActionPipeline.stack_object_resolved.is_connected(_button_support._on_ability_glow_resolved):
		ActionPipeline.stack_object_resolved.connect(_button_support._on_ability_glow_resolved)

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
			if _button_support._validate_ability(ability, card).get("can", false):
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
	if not inspected_card.gui_input.is_connected(_on_inspection_blur_input):
		inspected_card.gui_input.connect(_on_inspection_blur_input)


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
	if "ponerlo en el fondo de tu castillo para reducir a cero el próximo daño" in lower:
		return true  # Piruquina
	if "puedes barajarla de tu mano para buscar un oro en tu castillo" in lower:
		return true  # skofnung
	if "puedes pagar un oro para desterrar este y otro aliado sacerdote de tu mano" in lower:
		return true  # sandraudiga
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
	if "para subir esta carta de tu cementerio a tu mano" in lower:
		return true  # vision heroica
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
	EN JUEGO' explícito, así que esa sigue disponible en ambos casos.

	REVERTIDO (2026-09-09, a pedido explícito del usuario): entre el
	2026-08-31 y el 2026-09-06 hubo un vaivén con la segunda habilidad de
	Tyet ('esta y otra carta de tu mano en el fondo de tu Castillo') — se
	restringió a solo-mano, después se abrió también a Reserva de Oro
	razonando que 'esta' no implica zona. El usuario confirmó ahora que la
	restricción original (solo-mano) es la correcta — Tyet YA EN JUEGO no
	puede usar esta habilidad. Se sacó la excepción; vuelve a caer en la
	regla general de abajo (está en _ability_is_hand_usable(), su texto no
	dice 'en juego', así que da true = solo mano)."""
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
	# carta ajena que controlas (p.ej. jugada por Miguel desde el Cementerio
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
		var validation = _button_support._validate_ability(ability, source_card)
		if validation.get("can", false):
			usable_abilities.append({"ability": ability, "validation": validation})

	if usable_abilities.is_empty():
		return

	if not is_instance_valid(inspected_card):
		return

	# Ubica cada botón exactamente sobre las líneas donde está impresa esa habilidad
	# en la carta, calculando las líneas visuales ocupadas por cada párrafo/palabra clave.
	var card_size: Vector2 = inspected_card.custom_minimum_size
	var zone_top: float = card_size.y * ABILITY_TEXT_TOP_RATIO
	var zone_height: float = card_size.y * (ABILITY_TEXT_BOTTOM_RATIO - ABILITY_TEXT_TOP_RATIO)
	
	# Normalizar texto en líneas/párrafos
	var lines_raw: PackedStringArray = habilidad_text.strip_edges().split("\n")
	var visual_paragraphs: Array[Dictionary] = []
	var total_visual_lines: float = 0.0
	
	for p in lines_raw:
		var p_str = p.strip_edges()
		if p_str.is_empty():
			continue
		# Caracteres aproximados por línea en la caja de texto (~42 caracteres por línea real)
		var p_lines: float = maxf(1.0, roundf(float(p_str.length()) / 42.0 + 0.2))
		visual_paragraphs.append({
			"text": p_str,
			"lower": p_str.to_lower(),
			"lines": p_lines,
			"line_start": total_visual_lines
		})
		total_visual_lines += p_lines
	
	if total_visual_lines <= 0.0:
		total_visual_lines = 1.0
	
	var line_height_px: float = zone_height / total_visual_lines
	var offsets_by_index: Dictionary = {}
	
	for a in all_parsed:
		var raw_t: String = a.get("raw_text", "")
		var idx: int = a.get("ability_index", -1)
		var raw_lower: String = raw_t.to_lower().strip_edges()
		var first_chunk: String = raw_lower.split(".")[0].strip_edges()
		if first_chunk.length() > 6:
			first_chunk = first_chunk.substr(0, 24)
			
		var match_p: Dictionary = {}
		for p in visual_paragraphs:
			if first_chunk in p["lower"] or p["lower"] in raw_lower:
				match_p = p
				break
		
		var a_line_start: float = 0.0
		var a_lines_count: float = 1.0
		if not match_p.is_empty():
			a_line_start = match_p["line_start"]
			a_lines_count = match_p["lines"]
		else:
			# Fallback proporcional
			var h_lower: String = habilidad_text.to_lower()
			var spos: int = h_lower.find(first_chunk) if not first_chunk.is_empty() else 0
			if spos < 0:
				spos = 0
			var full_len: float = float(maxi(habilidad_text.length(), 1))
			a_line_start = (float(spos) / full_len) * total_visual_lines
			a_lines_count = maxf(1.0, (float(maxi(raw_t.length(), 1)) / full_len) * total_visual_lines)
			
		var y0: float = zone_top + a_line_start * line_height_px
		var y1: float = y0 + a_lines_count * line_height_px
		y0 = clampf(y0, zone_top, zone_top + zone_height - 10.0)
		y1 = clampf(y1, y0 + 12.0, zone_top + zone_height)
		offsets_by_index[idx] = Vector2(y0, y1)

	var panel = Control.new()
	panel.name = "AbilityOverlayButtons"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inspected_card.add_child(panel)
	_ability_buttons_panel = panel

	# Animación sutil de respiración mágica (modulate:a entre 0.82 y 1.0)
	var pulse_tw = panel.create_tween().set_loops()
	pulse_tw.tween_property(panel, "modulate:a", 0.82, 0.9).set_ease(Tween.EASE_IN_OUT)
	pulse_tw.tween_property(panel, "modulate:a", 1.0, 0.9).set_ease(Tween.EASE_IN_OUT)

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

		var btn = _button_support._create_ability_overlay_button(ability, validation)
		var btn_w: float = card_size.x - ABILITY_TEXT_SIDE_MARGIN - ABILITY_TEXT_RIGHT_MARGIN
		var btn_y: float = y_range.x + 1.0
		var btn_h: float = maxf(12.0, (y_range.y - y_range.x) - 2.0)
		btn.position = Vector2(ABILITY_TEXT_SIDE_MARGIN, btn_y)
		btn.size = Vector2(btn_w, btn_h)
		btn.mouse_filter = Control.MOUSE_FILTER_STOP

		var captured           = ability.duplicate()
		var captured_card_data = source_card.card_data.duplicate()
		var card_for_glow      = source_card  # capturado antes del cierre

		var ability_lower: String = str(captured.get("raw_text", "")).to_lower()
		# Patrones especiales de habilidades activadas — extraídos a 4 archivos
		# hermanos por posición en el archivo original (2026-09-06, "módulos
		# gordos", Fase 2 — ver iterative-booping-abelson.md): cada grupo
		# revisa el mismo tramo de condiciones que tenía acá, en el MISMO
		# ORDEN relativo (A, luego B, luego C, luego D), así que el primer
		# match sigue ganando exactamente igual que antes de la extracción.
		# Ver AbilityButtonPatternsA.gd/_B.gd/_C.gd/_D.gd.
		if _pattern_group_a.try_build(ability_lower, btn, panel, card_for_glow, captured):
			continue
		if _pattern_group_b.try_build(ability_lower, btn, panel, card_for_glow, captured):
			continue
		if _pattern_group_c.try_build(ability_lower, btn, panel, card_for_glow, captured):
			continue
		if _pattern_group_d.try_build(ability_lower, btn, panel, card_for_glow, captured):
			continue

		# Un solo click: cerrar inspección → empujar a la Pila → Paso D automático
		btn.pressed.connect(func():
			close_card_inspection()
			await _button_support._activate_ability_via_pipeline(card_for_glow, captured_card_data, captured, context)
		)
		panel.add_child(btn)

# Validación de habilidades ACTIVADAS + ciclo de vida del botón superpuesto
# (creación visual, activación vía ActionPipeline, brillo de "habilidad en
# la pila") se movieron a AbilityButtonSupport.gd (2026-09-06, "módulos
# gordos", Fase 2) — ver _button_support, montado en setup().

# El caso especial de Bernardo O'Higgins (coste alternativo + elección de
# efecto con objetivo) se movió a BernardoAbilityHandler.gd (2026-08-28,
# "módulos gordos") — ver _bernardo, montado en setup().

# Ventanas de respuesta (Paso D genérico + Signo Amarillo) y
# _show_puedes_confirm() (sin llamadores, código muerto) se movieron a
# ResponseWindowHandler.gd (2026-08-28, "módulos gordos") — ver
# _response_window, montado en setup().
