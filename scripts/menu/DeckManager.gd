extends Control
## DeckManager - Pantalla de gestión de mazos

# =============================================================================
# SEÑALES
# =============================================================================
signal deck_selected(deck_data: Dictionary)

# =============================================================================
# CONSTANTES
# =============================================================================
const API_BASE_URL = "http://localhost:3000"
const CDN_BASE_URL = "https://grimorio-cards.b-cdn.net"
const DECKS_PER_PAGE = 12

# =============================================================================
# REFERENCIAS UI
# =============================================================================
@onready var back_button: Button = $TopBar/BackButton
@onready var title_label: Label = $TopBar/TitleLabel
@onready var decks_container: GridContainer = $ScrollContainer/DecksContainer
@onready var loading_label: Label = $LoadingLabel
@onready var error_label: Label = $ErrorLabel
@onready var scroll_container: ScrollContainer = $ScrollContainer

# =============================================================================
# VARIABLES
# =============================================================================
var http_request: HTTPRequest
var decks_data: Array = []
var is_loading: bool = false


func _ready() -> void:
	# Crear HTTPRequest node
	http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(_on_request_completed)

	# Conectar botón atrás
	back_button.pressed.connect(_on_back_pressed)

	# Iniciar carga de mazos
	_fetch_decks()


func _fetch_decks() -> void:
	"""Obtiene los mazos desde la API"""
	if is_loading:
		return

	is_loading = true
	_show_loading(true)

	var url = "%s/api/mazos/publicos?limit=%d&sort=populares" % [API_BASE_URL, DECKS_PER_PAGE]
	print("[DeckManager] Fetching decks from: ", url)

	var error = http_request.request(url)
	if error != OK:
		print("[DeckManager] HTTP Request failed: ", error)
		_show_error("Error de conexión")
		is_loading = false


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	"""Callback cuando la request HTTP completa"""
	is_loading = false
	_show_loading(false)

	if result != HTTPRequest.RESULT_SUCCESS:
		print("[DeckManager] Request failed with result: ", result)
		_show_error("Error de conexión al servidor")
		return

	if response_code != 200:
		print("[DeckManager] Server returned: ", response_code)
		_show_error("Error del servidor (%d)" % response_code)
		return

	# Parsear JSON
	var json = JSON.new()
	var parse_result = json.parse(body.get_string_from_utf8())
	if parse_result != OK:
		print("[DeckManager] JSON parse error")
		_show_error("Error al procesar datos")
		return

	var data = json.get_data()
	if data.has("mazos"):
		decks_data = data["mazos"]
		print("[DeckManager] Loaded %d decks" % decks_data.size())
		_populate_decks()
	else:
		_show_error("Formato de datos inválido")


func _populate_decks() -> void:
	"""Crea los items visuales para cada mazo"""
	# Limpiar contenedor
	for child in decks_container.get_children():
		child.queue_free()

	if decks_data.is_empty():
		_show_error("No hay mazos disponibles")
		return

	error_label.visible = false

	# Crear card para cada mazo
	for deck in decks_data:
		var deck_card = _create_deck_card(deck)
		decks_container.add_child(deck_card)


func _create_deck_card(deck: Dictionary) -> Control:
	"""Crea un panel visual para un mazo - estilo web"""
	var card = Control.new()
	card.custom_minimum_size = Vector2(280, 320)

	# Container principal con clip
	var clip_container = Control.new()
	clip_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	clip_container.clip_contents = true
	card.add_child(clip_container)

	# Fondo oscuro base (se ve si no hay imagen)
	var bg_rect = ColorRect.new()
	bg_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg_rect.color = Color(0.08, 0.06, 0.12, 1.0)
	clip_container.add_child(bg_rect)

	# Imagen de fondo (portada)
	var portada_url = deck.get("portada_url", null)
	if portada_url != null and typeof(portada_url) == TYPE_STRING and not portada_url.is_empty():
		_load_cover_image(clip_container, portada_url)

	# Gradiente oscuro (overlay)
	var gradient_overlay = ColorRect.new()
	gradient_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	gradient_overlay.color = Color(0, 0, 0, 0.6)
	clip_container.add_child(gradient_overlay)

	# Panel solo para borde dorado (transparente)
	var panel = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0, 0, 0, 0)  # Transparente
	panel_style.border_color = Color(0.83, 0.69, 0.22, 1.0)  # Gold #d4af37
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(12)
	panel.add_theme_stylebox_override("panel", panel_style)
	clip_container.add_child(panel)

	# Contenido principal
	var content = VBoxContainer.new()
	content.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.add_theme_constant_override("separation", 0)
	clip_container.add_child(content)

	# Margin para el contenido
	var margin_top = MarginContainer.new()
	margin_top.add_theme_constant_override("margin_left", 16)
	margin_top.add_theme_constant_override("margin_right", 16)
	margin_top.add_theme_constant_override("margin_top", 16)
	margin_top.add_theme_constant_override("margin_bottom", 8)
	content.add_child(margin_top)

	# === HEADER: Arquetipo ===
	var archetype_hbox = HBoxContainer.new()
	archetype_hbox.add_theme_constant_override("separation", 8)
	margin_top.add_child(archetype_hbox)

	var arquetipo = deck.get("arquetipo", "Sin Arquetipo")
	var archetype_icon = _get_archetype_icon(arquetipo)

	var icon_label = Label.new()
	icon_label.text = archetype_icon
	icon_label.add_theme_font_size_override("font_size", 14)
	icon_label.add_theme_color_override("font_color", Color(0.83, 0.69, 0.22, 1.0))
	archetype_hbox.add_child(icon_label)

	var archetype_label = Label.new()
	archetype_label.text = arquetipo.to_upper()
	archetype_label.add_theme_font_size_override("font_size", 12)
	archetype_label.add_theme_color_override("font_color", Color(0.83, 0.69, 0.22, 1.0))
	archetype_hbox.add_child(archetype_label)

	# Spacer central
	var spacer = Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(spacer)

	# === CENTRO: Título y Autor ===
	var center_margin = MarginContainer.new()
	center_margin.add_theme_constant_override("margin_left", 16)
	center_margin.add_theme_constant_override("margin_right", 16)
	content.add_child(center_margin)

	var center_vbox = VBoxContainer.new()
	center_vbox.add_theme_constant_override("separation", 4)
	center_margin.add_child(center_vbox)

	# Título del mazo
	var title_label = Label.new()
	title_label.text = deck.get("nombre", "Sin nombre")
	title_label.add_theme_font_size_override("font_size", 24)
	title_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	title_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	title_label.add_theme_constant_override("shadow_offset_x", 2)
	title_label.add_theme_constant_override("shadow_offset_y", 2)
	title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	center_vbox.add_child(title_label)

	# Autor
	var author_label = Label.new()
	var autor = deck.get("autor_nombre", "Anónimo")
	author_label.text = "por %s" % autor
	author_label.add_theme_font_size_override("font_size", 14)
	author_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8, 1))
	center_vbox.add_child(author_label)

	# Spacer inferior
	var spacer2 = Control.new()
	spacer2.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(spacer2)

	# === FOOTER: Stats ===
	var footer_margin = MarginContainer.new()
	footer_margin.add_theme_constant_override("margin_left", 16)
	footer_margin.add_theme_constant_override("margin_right", 16)
	footer_margin.add_theme_constant_override("margin_bottom", 16)
	footer_margin.add_theme_constant_override("margin_top", 8)
	content.add_child(footer_margin)

	var footer_vbox = VBoxContainer.new()
	footer_vbox.add_theme_constant_override("separation", 12)
	footer_margin.add_child(footer_vbox)

	# Línea separadora
	var separator = HSeparator.new()
	separator.modulate = Color(1, 1, 1, 0.2)
	footer_vbox.add_child(separator)

	# Curva de coste (2026-08-28, a pedido del usuario — mostrar el mazo más
	# visual): mini histograma de cuántas cartas hay por coste, para juzgar
	# de un vistazo si el mazo es agresivo (curva baja) o de control (alta).
	var curve_costs := _compute_cost_curve(deck)
	if not curve_costs.is_empty():
		footer_vbox.add_child(_build_mana_curve_row(curve_costs))

	# Stats row
	var stats_hbox = HBoxContainer.new()
	stats_hbox.add_theme_constant_override("separation", 24)
	footer_vbox.add_child(stats_hbox)

	# Vistas
	var views_hbox = HBoxContainer.new()
	views_hbox.add_theme_constant_override("separation", 6)
	stats_hbox.add_child(views_hbox)

	var views_icon = Label.new()
	views_icon.text = "👁"
	views_icon.add_theme_font_size_override("font_size", 14)
	views_icon.add_theme_color_override("font_color", Color(0.83, 0.69, 0.22, 1.0))
	views_hbox.add_child(views_icon)

	var views_count = Label.new()
	views_count.text = str(deck.get("vistas", 0))
	views_count.add_theme_font_size_override("font_size", 14)
	views_count.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	views_hbox.add_child(views_count)

	# Likes
	var likes_hbox = HBoxContainer.new()
	likes_hbox.add_theme_constant_override("separation", 6)
	stats_hbox.add_child(likes_hbox)

	var likes_icon = Label.new()
	likes_icon.text = "❤"
	likes_icon.add_theme_font_size_override("font_size", 14)
	likes_icon.add_theme_color_override("font_color", Color(0.83, 0.69, 0.22, 1.0))
	likes_hbox.add_child(likes_icon)

	var likes_count = Label.new()
	likes_count.text = str(deck.get("likes", 0))
	likes_count.add_theme_font_size_override("font_size", 14)
	likes_count.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	likes_hbox.add_child(likes_count)

	# Botón de selección (invisible, cubre todo el panel)
	var button = Button.new()
	button.flat = true
	button.set_anchors_preset(Control.PRESET_FULL_RECT)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.pressed.connect(_on_deck_selected.bind(deck))
	card.add_child(button)

	# Hover effect
	button.mouse_entered.connect(func():
		panel_style.border_color = Color(1.0, 0.9, 0.5, 1.0)
		var tween = card.create_tween()
		tween.tween_property(card, "position:y", card.position.y - 8, 0.15)
	)
	button.mouse_exited.connect(func():
		panel_style.border_color = Color(0.83, 0.69, 0.22, 1.0)
		var tween = card.create_tween()
		tween.tween_property(card, "position:y", card.position.y + 8, 0.15)
	)

	return card


func _ensure_card_database_ready() -> bool:
	"""Carga CardDatabase desde disco (bundled o caché local) SIN red — esta
	pantalla es un menú, no queremos que armar la curva de coste dependa de
	golpear una API (y menos la local en localhost:3000, que hoy no corre).
	Devuelve false si no hay ningún catálogo disponible; en ese caso la
	curva simplemente no se muestra."""
	if CardDatabase.is_loaded and not CardDatabase.cards.is_empty():
		return true
	if CardDatabase.load_cards_from_bundled():
		return true
	if CardDatabase.load_cards_from_cache():
		return true
	return false


func _compute_cost_curve(deck: Dictionary) -> Array:
	"""Cuenta cuántas cartas del mazo hay por coste (0,1,2,3,4,5,'6+'),
	excluyendo Oros (no forman parte de la curva de mazo). Resuelve el mismo
	abanico de formas que ya prueba DeckLoader.gd para un mazo (datos_json.
	main como {id: cantidad}, o 'entries'/'cards' como Array de
	{myl_id/card_id/id, quantity}) — mismo motivo: no se pudo confirmar la
	forma exacta de /api/mazos/publicos sin el backend corriendo. Devuelve
	[] si no se pudo resolver nada (mazo vacío o CardDatabase sin catálogo),
	así el llamador sabe que no hay nada que dibujar."""
	if not _ensure_card_database_ready():
		return []

	var datos_json = deck.get("datos_json", deck.get("data", {}))
	if datos_json is String:
		datos_json = JSON.parse_string(datos_json)
	if not datos_json is Dictionary:
		datos_json = {}

	var main_deck: Dictionary = datos_json.get("main", datos_json.get("main_deck", datos_json.get("maindeck", {})))
	if not main_deck is Dictionary:
		main_deck = {}

	if main_deck.is_empty() and deck.get("entries") is Array:
		for entry in deck.entries:
			if not entry is Dictionary:
				continue
			var cid = str(entry.get("myl_id", entry.get("card_id", entry.get("id", ""))))
			if cid.is_empty():
				continue
			var qty = int(entry.get("quantity", entry.get("qty", 1)))
			main_deck[cid] = main_deck.get(cid, 0) + qty

	if main_deck.is_empty() and datos_json.get("cards") is Array:
		for entry in datos_json.cards:
			if not entry is Dictionary or entry.get("is_side", false):
				continue
			var cid = str(entry.get("myl_id", entry.get("card_id", entry.get("id", ""))))
			if cid.is_empty():
				continue
			var qty = int(entry.get("quantity", entry.get("qty", 1)))
			main_deck[cid] = main_deck.get(cid, 0) + qty

	if main_deck.is_empty():
		return []

	# Buckets 0..5 y "6+"
	var buckets: Array = [0, 0, 0, 0, 0, 0, 0]
	var any_resolved := false
	for cid in main_deck:
		var card_data: Dictionary = CardDatabase.get_card(str(cid))
		if card_data.is_empty():
			continue
		if card_data.get("tipo", -1) == Constants.CardType.ORO:
			continue
		any_resolved = true
		var coste: int = int(card_data.get("coste", 0))
		var idx: int = clampi(coste, 0, 6)
		buckets[idx] += int(main_deck[cid])

	return buckets if any_resolved else []


func _build_mana_curve_row(costs: Array) -> Control:
	"""Mini histograma de barras — una sola serie (cantidad de cartas), un
	solo tono (el dorado ya usado en todo el resto de la carta) porque la
	magnitud ya la codifica la altura de la barra; no hace falta que el
	color también varíe. Sin ejes ni tooltip: es un sparkline de un vistazo,
	no un gráfico para analizar en detalle."""
	const BAR_MAX_HEIGHT := 32.0
	const BAR_WIDTH := 14.0
	const GOLD := Color(0.83, 0.69, 0.22, 1.0)

	var row = HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 6)

	var max_count: int = 1
	for c in costs:
		max_count = maxi(max_count, int(c))

	var cost_labels := ["0", "1", "2", "3", "4", "5", "6+"]
	for i in range(costs.size()):
		var col = VBoxContainer.new()
		col.add_theme_constant_override("separation", 2)
		col.alignment = BoxContainer.ALIGNMENT_END
		col.custom_minimum_size = Vector2(BAR_WIDTH, BAR_MAX_HEIGHT + 16)

		var count: int = int(costs[i])
		var bar_height: float = 3.0 if count == 0 else max(3.0, BAR_MAX_HEIGHT * (float(count) / float(max_count)))

		var spacer = Control.new()
		spacer.custom_minimum_size = Vector2(BAR_WIDTH, BAR_MAX_HEIGHT - bar_height)
		col.add_child(spacer)

		var bar = ColorRect.new()
		bar.custom_minimum_size = Vector2(BAR_WIDTH, bar_height)
		bar.color = GOLD if count > 0 else Color(1, 1, 1, 0.12)
		bar.tooltip_text = "%d carta(s) de coste %s" % [count, cost_labels[i]]
		col.add_child(bar)

		var lbl = Label.new()
		lbl.text = cost_labels[i]
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.add_theme_font_size_override("font_size", 9)
		lbl.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75, 0.8))
		col.add_child(lbl)

		row.add_child(col)

	return row


func _get_archetype_icon(arquetipo: String) -> String:
	"""Retorna el icono correspondiente al arquetipo"""
	match arquetipo.to_lower():
		"agresivo": return "🔥"
		"control": return "🛡"
		"combo": return "⚙"
		"midrange": return "⚖"
		_: return "📖"


func _load_cover_image(container: Control, url: String) -> void:
	"""Carga la imagen de portada del mazo"""
	var texture_rect = TextureRect.new()
	texture_rect.name = "CoverImage"
	texture_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	container.add_child(texture_rect)
	container.move_child(texture_rect, 1)  # Después del bg, antes del overlay

	# Construir URL completa
	var full_url = _build_image_url(url)
	print("[DeckManager] Loading cover: ", full_url)

	# Crear HTTP request para la imagen
	var http = HTTPRequest.new()
	add_child(http)  # Agregar al DeckManager, no al container
	http.request_completed.connect(func(result, code, _headers, body):
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			var image = Image.new()
			var err = image.load_webp_from_buffer(body)
			if err != OK:
				err = image.load_png_from_buffer(body)
			if err != OK:
				err = image.load_jpg_from_buffer(body)
			if err == OK:
				var texture = ImageTexture.create_from_image(image)
				if is_instance_valid(texture_rect):
					texture_rect.texture = texture
					print("[DeckManager] Image loaded successfully!")
			else:
				print("[DeckManager] Failed to decode image")
		else:
			print("[DeckManager] HTTP error: result=", result, " code=", code)
		http.queue_free()
	)
	var err = http.request(full_url)
	if err != OK:
		print("[DeckManager] Request failed to start: ", err)


func _build_image_url(url: String) -> String:
	"""Construye la URL completa de la imagen desde el CDN"""
	if url.is_empty():
		return ""

	# Si ya es URL completa, devolverla
	if url.begins_with("http://") or url.begins_with("https://"):
		return url

	# Si es path relativo, agregar CDN base
	if url.begins_with("/"):
		return CDN_BASE_URL + url

	# Si no tiene /, agregarlo
	return CDN_BASE_URL + "/" + url


func _on_deck_selected(deck: Dictionary) -> void:
	"""Cuando el usuario selecciona un mazo"""
	var deck_name = deck.get("nombre", "")
	var deck_slug = deck.get("slug", "")
	print("[DeckManager] Selected deck: %s (slug: %s)" % [deck_name, deck_slug])

	# Emitir señal para otros sistemas
	deck_selected.emit(deck)

	# Verificar que tenemos un slug válido
	if deck_slug.is_empty():
		_show_error("El mazo seleccionado no tiene un identificador válido")
		return

	# Cargar el mazo usando DeckLoader
	# Conectar señales para feedback
	if not DeckLoader.deck_loaded.is_connected(_on_deck_loaded):
		DeckLoader.deck_loaded.connect(_on_deck_loaded)
	if not DeckLoader.deck_load_failed.is_connected(_on_deck_load_failed):
		DeckLoader.deck_load_failed.connect(_on_deck_load_failed)
	if not DeckLoader.all_decks_ready.is_connected(_on_all_decks_ready):
		DeckLoader.all_decks_ready.connect(_on_all_decks_ready)

	# Iniciar carga del mazo para el jugador local (ID 0)
	_show_loading(true)
	DeckLoader.load_deck_for_player(0, deck_slug)


func _on_deck_loaded(player_id: int, card_count: int) -> void:
	"""Callback cuando el mazo se carga exitosamente"""
	if not is_inside_tree():
		return
	_show_loading(false)
	print("[DeckManager] Mazo cargado: %d cartas para jugador %d" % [card_count, player_id])

	# TODO: Para partidas PvP, esperar a que el oponente también cargue su mazo
	# Por ahora, generar un mazo aleatorio para el oponente y comenzar
	if not DeckLoader.is_deck_loaded(1):
		# Generar mazo aleatorio para oponente (para testing)
		DeckLoader.load_random_deck(1, 50)
		return  # Esperar al callback de all_decks_ready

	# Ir a la escena del juego
	_go_to_game()


func _on_deck_load_failed(player_id: int, error: String) -> void:
	"""Callback cuando falla la carga del mazo"""
	if not is_inside_tree():
		return
	_show_loading(false)
	_show_error("Error cargando mazo: %s" % error)


func _on_all_decks_ready() -> void:
	"""Callback cuando ambos mazos están listos"""
	print("[DeckManager] Ambos mazos listos, iniciando partida...")
	_go_to_game()


func _go_to_game() -> void:
	"""Navega a la escena del juego de forma segura"""
	# Usar Engine.get_main_loop() como fallback si get_tree() falla
	var tree = get_tree()
	if tree == null:
		tree = Engine.get_main_loop() as SceneTree
	if tree:
		tree.change_scene_to_file("res://scenes/game/Main.tscn")
	else:
		push_error("[DeckManager] No se pudo obtener el SceneTree")


func _show_loading(show: bool) -> void:
	"""Muestra/oculta el indicador de carga"""
	loading_label.visible = show
	scroll_container.visible = not show
	error_label.visible = false


func _show_error(message: String) -> void:
	"""Muestra un mensaje de error"""
	error_label.text = message
	error_label.visible = true
	loading_label.visible = false


func _on_back_pressed() -> void:
	"""Volver al menú principal"""
	print("[DeckManager] Returning to main menu...")
	get_tree().change_scene_to_file("res://scenes/menu/MainMenu.tscn")
