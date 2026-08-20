extends Node
## DeckSelector — Popup de selección de mazos antes de la partida.
## Se crea programáticamente desde Main.gd, no requiere escena .tscn.
## Fuente: ExternalApiClient (tus mazos vía /external/my-decks/, requiere
## login — ver ExternalApiClient.gd). El viejo /api/game/mazos ya no existe;
## si el login o el fetch fallan, cae a mazos bundled/locales como siempre.

signal decks_selected(player_data: Dictionary, opponent_data: Dictionary, is_external: bool)
signal selection_cancelled

var _overlay: ColorRect = null
var _player_option: OptionButton = null
var _opponent_option: OptionButton = null
var _mazos: Array = []  # [{slug, nombre, arquetipo, formato}] o mazos externos crudos
var _external: bool = false  # true si _mazos viene de ExternalApiClient (forma distinta)


func show_selector(parent: Node) -> void:
	"""Muestra el popup de selección. Emite decks_selected cuando el jugador confirma."""
	_build_ui(parent)
	_fetch_mazos()


# =============================================================================
# CONSTRUCCIÓN DE UI
# =============================================================================
func _build_ui(parent: Node) -> void:
	# Fondo semitransparente
	_overlay = ColorRect.new()
	_overlay.color = Color(0, 0, 0, 0.85)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	parent.add_child(_overlay)

	# Panel central
	var panel = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(480, 300)
	panel.set_anchor(SIDE_LEFT, 0.5)
	panel.set_anchor(SIDE_TOP, 0.5)
	panel.set_anchor(SIDE_RIGHT, 0.5)
	panel.set_anchor(SIDE_BOTTOM, 0.5)
	panel.set_offset(SIDE_LEFT, -240)
	panel.set_offset(SIDE_TOP, -150)
	panel.set_offset(SIDE_RIGHT, 240)
	panel.set_offset(SIDE_BOTTOM, 150)
	_overlay.add_child(panel)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 16)
	panel.add_child(vbox)

	# Título
	var title = Label.new()
	title.text = "Selecciona los mazos"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)

	# Selector jugador
	var row1 = HBoxContainer.new()
	var lbl1 = Label.new()
	lbl1.text = "Tu mazo:"
	lbl1.custom_minimum_size = Vector2(110, 0)
	_player_option = OptionButton.new()
	_player_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_player_option.add_item("Cargando...")
	_player_option.disabled = true
	row1.add_child(lbl1)
	row1.add_child(_player_option)
	vbox.add_child(row1)

	# Selector oponente
	var row2 = HBoxContainer.new()
	var lbl2 = Label.new()
	lbl2.text = "Mazo oponente:"
	lbl2.custom_minimum_size = Vector2(110, 0)
	_opponent_option = OptionButton.new()
	_opponent_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_opponent_option.add_item("Cargando...")
	_opponent_option.disabled = true
	row2.add_child(lbl2)
	row2.add_child(_opponent_option)
	vbox.add_child(row2)

	# Nota informativa
	var note = Label.new()
	note.text = "Solo se muestran mazos públicos."
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	note.add_theme_font_size_override("font_size", 12)
	vbox.add_child(note)

	# Botones
	var btn_row = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 12)

	var btn_confirm = Button.new()
	btn_confirm.text = "Comenzar partida"
	btn_confirm.disabled = true
	btn_confirm.pressed.connect(_on_confirm_pressed.bind(btn_confirm))
	btn_row.add_child(btn_confirm)

	var btn_random = Button.new()
	btn_random.text = "Mazos aleatorios"
	btn_random.pressed.connect(_on_random_pressed)
	btn_row.add_child(btn_random)

	vbox.add_child(btn_row)

	# Guardar referencia al botón confirmar para habilitarlo al cargar
	_overlay.set_meta("btn_confirm", btn_confirm)


# =============================================================================
# CARGA DE MAZOS
# =============================================================================
func _fetch_mazos() -> void:
	var client = get_node_or_null("/root/ExternalApiClient")
	if not client:
		push_warning("[DeckSelector] ExternalApiClient no disponible — probando mazos locales")
		_load_local_fallback()
		return
	if not client.decks_received.is_connected(_on_external_decks_received):
		client.decks_received.connect(_on_external_decks_received, CONNECT_ONE_SHOT)
	if not client.decks_failed.is_connected(_on_external_decks_failed):
		client.decks_failed.connect(_on_external_decks_failed, CONNECT_ONE_SHOT)
	client.fetch_my_decks()


func _on_external_decks_received(decks: Array) -> void:
	if decks.is_empty():
		push_warning("[DeckSelector] La API externa no devolvió mazos — probando mazos locales")
		_load_local_fallback()
		return
	_mazos = decks
	_external = true
	_populate_options()


func _on_external_decks_failed(reason: String) -> void:
	push_warning("[DeckSelector] No se pudieron cargar tus mazos (%s) — probando mazos locales" % reason)
	_load_local_fallback()


func _load_local_fallback() -> void:
	"""Carga mazos sin API: bundled (res://) → user://decks/"""
	_external = false
	var deck_loader = get_node_or_null("/root/DeckLoader")
	if deck_loader:
		# 1. Mazos bundleados — incluidos en el proyecto exportado
		_mazos = deck_loader.get_bundled_decks()
		# 2. Mazos guardados por el usuario en sesiones anteriores
		if _mazos.is_empty():
			_mazos = deck_loader.get_local_decks()
	if _mazos.is_empty():
		push_warning("[DeckSelector] Sin mazos disponibles. Usa 'Mazos aleatorios'.")
		_populate_with_error()
	else:
		print("[DeckSelector] Usando %d mazos offline" % _mazos.size())
		var btn = _overlay.get_meta("btn_confirm", null) as Button
		if btn:
			btn.text = "Comenzar (offline)"
		_populate_options()


func _populate_options() -> void:
	_player_option.clear()
	_opponent_option.clear()

	for m in _mazos:
		# Los mazos externos pueden usar nombres de campo en inglés — ver
		# ExternalApiClient.gd (forma de /my-decks/ sin confirmar del todo).
		var nombre = str(m.get("nombre", m.get("name", "Mazo")))
		var arquetipo = str(m.get("arquetipo", m.get("format", m.get("archetype", ""))))
		var label = "%s (%s)" % [nombre, arquetipo] if arquetipo != "" else nombre
		_player_option.add_item(label)
		_opponent_option.add_item(label)

	_player_option.disabled = false
	_opponent_option.disabled = false

	# Habilitar botón confirmar
	var btn = _overlay.get_meta("btn_confirm", null) as Button
	if btn:
		btn.disabled = false

	print("[DeckSelector] %d mazos cargados (externos: %s)." % [_mazos.size(), str(_external)])


func _populate_with_error() -> void:
	_player_option.clear()
	_opponent_option.clear()
	_player_option.add_item("Error al cargar")
	_opponent_option.add_item("Error al cargar")
	push_warning("[DeckSelector] No se pudieron cargar mazos. Usa 'Mazos aleatorios'.")


# =============================================================================
# CALLBACKS
# =============================================================================
func _on_confirm_pressed(btn_confirm: Button) -> void:
	if _mazos.is_empty():
		return
	var p_idx = _player_option.selected
	var o_idx = _opponent_option.selected
	if p_idx < 0 or p_idx >= _mazos.size() or o_idx < 0 or o_idx >= _mazos.size():
		return

	btn_confirm.disabled = true
	_close()
	emit_signal("decks_selected", _mazos[p_idx], _mazos[o_idx], _external)


func _on_random_pressed() -> void:
	_close()
	emit_signal("decks_selected", {}, {}, false)  # Dict vacío = mazo aleatorio


func _close() -> void:
	if _overlay and is_instance_valid(_overlay):
		_overlay.queue_free()
		_overlay = null
