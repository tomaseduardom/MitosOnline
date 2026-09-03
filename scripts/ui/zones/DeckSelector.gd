extends Node
## DeckSelector — Popup de selección de mazos antes de la partida.
## Selección unilateral ("ELIGE TU MAZO") con las 9 razas oficiales en alta definición:
## - Caballero, Bestia, Dragón, Imp, Héroe, Guerrero, Faerie, Sacerdote, Sombra.
## - Texturas de cuero repujado completas y sin parches.
## - Botones ornamentales "COMENZAR PARTIDA" y "Mazos aleatorios" con bordes completos.
## - El mazo rival se sortea automáticamente al iniciar.

signal decks_selected(player_data: Dictionary, opponent_data: Dictionary, player_is_external: bool, opponent_is_external: bool)
signal selection_cancelled

const CARD_SIZE := Vector2(245, 316)
const GOLD := Color(0.83, 0.69, 0.22, 1.0)
const GOLD_HOVER := Color(1.0, 0.88, 0.45, 1.0)

const FONT_MEDIEVAL := preload("res://assets/fonts/Marcellus-Regular.ttf")
const FONT_TITLE := preload("res://assets/fonts/Cinzel-Bold.ttf")
const GOLD_SELECTION := Color(1.0, 0.86, 0.38, 1.0)

# Texturas HD de las 9 Razas oficiales
const TEX_CABALLERO := preload("res://assets/ui/deck_selector/card_caballero.png")
const TEX_BESTIA := preload("res://assets/ui/deck_selector/card_bestia.png")
const TEX_DRAGON := preload("res://assets/ui/deck_selector/card_dragon.png")
const TEX_IMP := preload("res://assets/ui/deck_selector/card_imp.png")
const TEX_HEROE := preload("res://assets/ui/deck_selector/card_heroe.png")
const TEX_GUERRERO := preload("res://assets/ui/deck_selector/card_guerrero.png")
const TEX_FAERIE := preload("res://assets/ui/deck_selector/card_faerie.png")
const TEX_SACERDOTE := preload("res://assets/ui/deck_selector/card_sacerdote.png")
const TEX_SOMBRA := preload("res://assets/ui/deck_selector/card_sombra.png")

# Botones completos y fondo
const TEX_BTN_EMERALD := preload("res://assets/ui/deck_selector/btn_comenzar_partida.png")
const TEX_BTN_RANDOM := preload("res://assets/ui/deck_selector/btn_mazos_aleatorios.png")
const BACKGROUND_TEXTURE := preload("res://fondo_inicio.png")
const SpinnerDrawerScript := preload("res://scripts/ui/zones/SpinnerDrawer.gd")

var _overlay: Control = null
var _player_row: HBoxContainer = null
var _btn_confirm: TextureButton = null
var _btn_random: TextureButton = null
var _status_label: Label = null

var _mazos: Array = []
var _selected_player_idx: int = -1
var _player_cards: Array = []


func show_selector(parent: Node) -> void:
	"""Muestra el popup de selección. Emite decks_selected cuando el jugador confirma."""
	_build_ui(parent)
	_fetch_mazos()


# =============================================================================
# CONSTRUCCIÓN DE UI
# =============================================================================
func _build_ui(parent: Node) -> void:
	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(_overlay)

	# 1. Fondo ambiental temático
	var bg_texture = TextureRect.new()
	bg_texture.texture = BACKGROUND_TEXTURE
	bg_texture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_overlay.add_child(bg_texture)

	var bg_dark = ColorRect.new()
	bg_dark.color = Color(0.03, 0.02, 0.04, 0.82)
	bg_dark.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg_dark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(bg_dark)

	# 2. Panel central estilo ventana de fantasía con marco dorado
	var panel = PanelContainer.new()
	panel.set_anchor(SIDE_LEFT, 0.5)
	panel.set_anchor(SIDE_TOP, 0.5)
	panel.set_anchor(SIDE_RIGHT, 0.5)
	panel.set_anchor(SIDE_BOTTOM, 0.5)
	panel.set_offset(SIDE_LEFT, -680)
	panel.set_offset(SIDE_TOP, -320)
	panel.set_offset(SIDE_RIGHT, 680)
	panel.set_offset(SIDE_BOTTOM, 320)

	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.06, 0.05, 0.08, 0.97)
	panel_style.border_color = GOLD
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(14)
	panel_style.content_margin_left = 36
	panel_style.content_margin_right = 36
	panel_style.content_margin_top = 22
	panel_style.content_margin_bottom = 22
	panel_style.shadow_color = Color(0, 0, 0, 0.9)
	panel_style.shadow_size = 25
	panel.add_theme_stylebox_override("panel", panel_style)
	_overlay.add_child(panel)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	# 3. Título superior ("ELIGE TU MAZO")
	var title = Label.new()
	title.text = "ELIGE TU MAZO"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_override("font", FONT_TITLE)
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(1.0, 0.90, 0.60, 1.0))
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	title.add_theme_constant_override("shadow_offset_x", 2)
	title.add_theme_constant_override("shadow_offset_y", 2)
	vbox.add_child(title)

	# 4. Fila única horizontal de mazos con scroll
	var p_scroll = ScrollContainer.new()
	p_scroll.custom_minimum_size = Vector2(0, CARD_SIZE.y + 12)
	p_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	p_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(p_scroll)

	_player_row = HBoxContainer.new()
	_player_row.add_theme_constant_override("separation", 18)
	_player_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	p_scroll.add_child(_player_row)
	_player_row.add_child(_build_loading_placeholder())

	# 5. Texto de estado / instrucciones
	_status_label = Label.new()
	_status_label.text = "Cargando mazos..."
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_override("font", FONT_MEDIEVAL)
	_status_label.add_theme_color_override("font_color", Color(0.85, 0.78, 0.70, 1.0))
	_status_label.add_theme_font_size_override("font_size", 14)
	vbox.add_child(_status_label)

	# 6. Botones de acción inferiores con proporciones completas
	var btn_row = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 24)

	# Botón "COMENZAR PARTIDA" (TextureButton esmeralda HD con bordes completos)
	_btn_confirm = TextureButton.new()
	_btn_confirm.texture_normal = TEX_BTN_EMERALD
	_btn_confirm.custom_minimum_size = Vector2(300, 74)
	_btn_confirm.ignore_texture_size = true
	_btn_confirm.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	_btn_confirm.disabled = true
	_btn_confirm.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_btn_confirm.pressed.connect(_on_confirm_pressed)
	_btn_confirm.mouse_entered.connect(func(): if not _btn_confirm.disabled: _btn_confirm.modulate = Color(1.15, 1.15, 1.15, 1.0))
	_btn_confirm.mouse_exited.connect(func(): if not _btn_confirm.disabled: _btn_confirm.modulate = Color(1.0, 1.0, 1.0, 1.0))
	btn_row.add_child(_btn_confirm)

	# Botón "Mazos aleatorios" (TextureButton piedra/metal HD con bordes completos)
	_btn_random = TextureButton.new()
	_btn_random.texture_normal = TEX_BTN_RANDOM
	_btn_random.custom_minimum_size = Vector2(208, 74)
	_btn_random.ignore_texture_size = true
	_btn_random.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	_btn_random.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_btn_random.pressed.connect(_on_random_pressed)
	_btn_random.mouse_entered.connect(func(): _btn_random.modulate = Color(1.15, 1.15, 1.15, 1.0))
	_btn_random.mouse_exited.connect(func(): _btn_random.modulate = Color(1.0, 1.0, 1.0, 1.0))
	btn_row.add_child(_btn_random)

	vbox.add_child(btn_row)


func _build_loading_placeholder() -> Control:
	var box = CenterContainer.new()
	box.custom_minimum_size = Vector2(800, CARD_SIZE.y)

	var vbox = VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 16)
	box.add_child(vbox)

	# Spinner místico dorado
	var spin_holder = Control.new()
	spin_holder.custom_minimum_size = Vector2(60, 60)
	vbox.add_child(spin_holder)

	var spinner = Node2D.new()
	spinner.set_script(SpinnerDrawerScript)
	spinner.position = Vector2(30, 30)
	spin_holder.add_child(spinner)

	var tw = spinner.create_tween().set_loops()
	tw.tween_property(spinner, "rotation", TAU, 1.8).from(0.0)

	var lbl = Label.new()
	lbl.text = "Invocando grimorios y mazos..."
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.add_theme_color_override("font_color", GOLD_HOVER)
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	vbox.add_child(lbl)

	var tw_txt = lbl.create_tween().set_loops()
	tw_txt.tween_property(lbl, "modulate:a", 0.45, 0.8).set_trans(Tween.TRANS_SINE)
	tw_txt.tween_property(lbl, "modulate:a", 1.0, 0.8).set_trans(Tween.TRANS_SINE)

	return box



# =============================================================================
# CARGA DE MAZOS
# =============================================================================
func _fetch_mazos() -> void:
	if not ExternalApiClient.decks_received.is_connected(_on_external_decks_received):
		ExternalApiClient.decks_received.connect(_on_external_decks_received, CONNECT_ONE_SHOT)
	if not ExternalApiClient.decks_failed.is_connected(_on_external_decks_failed):
		ExternalApiClient.decks_failed.connect(_on_external_decks_failed, CONNECT_ONE_SHOT)
	ExternalApiClient.fetch_my_decks()


func _on_external_decks_received(decks: Array) -> void:
	_mazos = []
	for d in decks:
		d["_is_external"] = true
		_mazos.append(d)
	_mazos.append_array(_get_preset_decks())
	if _mazos.is_empty():
		push_warning("[DeckSelector] Sin mazos propios ni presets — probando mazos locales")
		_load_local_fallback()
		return
	_populate_options()


func _on_external_decks_failed(reason: String) -> void:
	push_warning("[DeckSelector] No se pudieron cargar tus mazos (%s) — probando mazos locales" % reason)
	_load_local_fallback()


func _get_preset_decks() -> Array:
	var result: Array = []
	for m in DeckLoader.get_local_decks():
		if str(m.get("slug", "")).begins_with("preset-"):
			m["_is_external"] = false
			result.append(m)
	return result


func _load_local_fallback() -> void:
	_mazos = DeckLoader.get_bundled_decks()
	if _mazos.is_empty():
		_mazos = DeckLoader.get_local_decks()
	for m in _mazos:
		m["_is_external"] = false

	if _mazos.is_empty():
		push_warning("[DeckSelector] Sin mazos disponibles. Usa 'Mazos aleatorios'.")
		_populate_with_error()
	else:
		print("[DeckSelector] Usando %d mazos offline" % _mazos.size())
		if _status_label:
			_status_label.text = "Mazos offline — guardados localmente en el equipo."
		_populate_options()


# =============================================================================
# TARJETAS DE MAZO
# =============================================================================
func _populate_options() -> void:
	_selected_player_idx = -1
	_player_cards.clear()

	for child in _player_row.get_children():
		child.queue_free()

	for i in range(_mazos.size()):
		var mazo: Dictionary = _mazos[i]
		var p_card := _build_deck_card(mazo, i)
		_player_row.add_child(p_card)
		_player_cards.append(p_card)

	# Auto-seleccionar el primer mazo por defecto
	if _mazos.size() > 0:
		_selected_player_idx = 0
		_refresh_selection(_player_cards, _selected_player_idx)
		_update_confirm_button()

	if _status_label:
		_status_label.text = "%d mazo(s) disponibles — toca uno para seleccionarlo." % _mazos.size()

	print("[DeckSelector] %d mazos cargados." % _mazos.size())


func _populate_with_error() -> void:
	for child in _player_row.get_children():
		child.queue_free()
	var err = Label.new()
	err.text = "No se encontraron mazos disponibles"
	_player_row.add_child(err)
	if _status_label:
		_status_label.text = "No se pudieron cargar mazos — usa 'Mazos aleatorios'."


func _build_deck_card(mazo: Dictionary, idx: int) -> Control:
	var card = Control.new()
	card.custom_minimum_size = CARD_SIZE

	var clip = Control.new()
	clip.set_anchors_preset(Control.PRESET_FULL_RECT)
	clip.clip_contents = true
	card.add_child(clip)

	var raw_nombre = str(mazo.get("nombre", mazo.get("name", "Mazo")))
	var nombre_clean = _sanitize_utf8(raw_nombre)
	var race_name := _extract_race_or_archetype(mazo)
	var card_texture: Texture2D = _get_card_texture(race_name, nombre_clean, idx)

	# 1. Textura base HD completa de cuero repujado
	var tex_rect = TextureRect.new()
	tex_rect.texture = card_texture
	tex_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	clip.add_child(tex_rect)

	# 2. Borde de Selección interactivo (Dorado brillante)
	var border_panel = PanelContainer.new()
	border_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var border_style = StyleBoxFlat.new()
	border_style.bg_color = Color(0, 0, 0, 0)
	border_style.border_color = Color(0, 0, 0, 0)
	border_style.set_border_width_all(3)
	border_style.set_corner_radius_all(10)
	border_panel.add_theme_stylebox_override("panel", border_style)
	clip.add_child(border_panel)
	card.set_meta("border_style", border_style)

	# 3. Textos dinámicos del mazo en el pie
	var bottom_margin = MarginContainer.new()
	bottom_margin.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bottom_margin.add_theme_constant_override("margin_left", 14)
	bottom_margin.add_theme_constant_override("margin_right", 14)
	bottom_margin.add_theme_constant_override("margin_bottom", 12)
	clip.add_child(bottom_margin)

	var bottom_vbox = VBoxContainer.new()
	bottom_vbox.add_theme_constant_override("separation", 2)
	bottom_margin.add_child(bottom_vbox)

	var is_preset: bool = str(mazo.get("slug", "")).begins_with("preset-")
	var name_lbl = Label.new()
	name_lbl.text = ("⭐ " if is_preset else "") + nombre_clean
	name_lbl.add_theme_font_override("font", FONT_MEDIEVAL)
	name_lbl.add_theme_font_size_override("font_size", 16)
	name_lbl.add_theme_color_override("font_color", Color(0.98, 0.95, 0.90, 1.0))
	name_lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	name_lbl.add_theme_constant_override("shadow_offset_x", 1)
	name_lbl.add_theme_constant_override("shadow_offset_y", 1)
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.max_lines_visible = 2
	bottom_vbox.add_child(name_lbl)

	var sub_text = "(público)" if is_preset else str(mazo.get("formato", mazo.get("format", "personal"))).to_lower()
	var sub_lbl = Label.new()
	sub_lbl.text = _sanitize_utf8(sub_text)
	sub_lbl.add_theme_font_override("font", FONT_MEDIEVAL)
	sub_lbl.add_theme_font_size_override("font_size", 13)
	sub_lbl.add_theme_color_override("font_color", Color(0.78, 0.72, 0.65, 1.0))
	bottom_vbox.add_child(sub_lbl)

	# 4. Botón interactivo sobre la tarjeta
	var button = Button.new()
	button.flat = true
	button.set_anchors_preset(Control.PRESET_FULL_RECT)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.pressed.connect(_on_card_pressed.bind(idx))
	card.add_child(button)

	button.mouse_entered.connect(func():
		if _selected_player_idx != idx:
			border_style.border_color = GOLD
	)
	button.mouse_exited.connect(func():
		if _selected_player_idx != idx:
			border_style.border_color = Color(0, 0, 0, 0)
	)

	return card


func _get_card_texture(race: String, deck_name: String, idx: int) -> Texture2D:
	var r := (race + " " + deck_name).to_lower()
	if "caballero" in r or "paladin" in r or "paladín" in r:
		return TEX_CABALLERO
	elif "bestia" in r or "lobo" in r:
		return TEX_BESTIA
	elif "dragon" in r or "dragón" in r:
		return TEX_DRAGON
	elif "imp" in r or "demonio" in r:
		return TEX_IMP
	elif "heroe" in r or "héroe" in r or "defensor" in r:
		return TEX_HEROE
	elif "guerrero" in r or "barbaro" in r or "bárbaro" in r:
		return TEX_GUERRERO
	elif "faerie" in r or "hada" in r or "mago" in r:
		return TEX_FAERIE
	elif "sacerdote" in r or "santo" in r or "luz" in r:
		return TEX_SACERDOTE
	elif "sombra" in r or "undead" in r or "no-muerto" in r:
		return TEX_SOMBRA

	# Variedad dinámica para mazos sin raza específica
	var all_textures := [
		TEX_CABALLERO, TEX_BESTIA, TEX_DRAGON, TEX_IMP,
		TEX_HEROE, TEX_GUERRERO, TEX_FAERIE, TEX_SACERDOTE, TEX_SOMBRA
	]
	return all_textures[idx % all_textures.size()]


func _extract_race_or_archetype(mazo: Dictionary) -> String:
	var val: String = str(mazo.get("raza", mazo.get("race", mazo.get("arquetipo", mazo.get("archetype", "")))))
	val = _sanitize_utf8(val)
	if val.is_empty():
		var nombre_lower := _sanitize_utf8(str(mazo.get("nombre", mazo.get("name", "")))).to_lower()
		for r in ["caballero", "bestia", "dragon", "dragón", "sombra", "faerie", "sacerdote", "eterno", "heroe", "héroe", "guerrero", "imp"]:
			if r in nombre_lower:
				return r
	return val


func _sanitize_utf8(text: String) -> String:
	var s = text
	s = s.replace("Ã¡", "á").replace("Ã©", "é").replace("Ã­", "í").replace("Ã³", "ó").replace("Ãº", "ú")
	s = s.replace("Ã±", "ñ").replace("Ã ", "Á").replace("Ã‰", "É").replace("Ã ", "Í").replace("Ã“", "Ó").replace("Ãš", "Ú").replace("Ã‘", "Ñ")
	s = s.replace("DragÃ³n", "Dragón").replace("DragÃ¡", "Dragá")
	return s


# =============================================================================
# CALLBACKS Y CONTROL DE SELECCIÓN
# =============================================================================
func _on_card_pressed(idx: int) -> void:
	_selected_player_idx = idx
	_refresh_selection(_player_cards, idx)
	_update_confirm_button()


func _update_confirm_button() -> void:
	var can_confirm := (_selected_player_idx >= 0 and _selected_player_idx < _mazos.size())
	_btn_confirm.disabled = not can_confirm
	_btn_confirm.modulate = Color(1, 1, 1, 1) if can_confirm else Color(0.6, 0.6, 0.6, 0.7)


func _refresh_selection(cards: Array, selected_idx: int) -> void:
	for i in range(cards.size()):
		var style: StyleBoxFlat = cards[i].get_meta("border_style")
		if i == selected_idx:
			style.border_color = GOLD_SELECTION
			style.set_border_width_all(3)
		else:
			style.border_color = Color(0, 0, 0, 0)
			style.set_border_width_all(2)


func _on_confirm_pressed() -> void:
	if _mazos.is_empty() or _selected_player_idx < 0 or _selected_player_idx >= _mazos.size():
		return

	_btn_confirm.disabled = true
	var player_deck: Dictionary = _mazos[_selected_player_idx]

	# El mazo del oponente se sortea automáticamente de los disponibles
	var opponent_deck: Dictionary = _mazos[randi() % _mazos.size()] if not _mazos.is_empty() else {}

	_close()
	emit_signal("decks_selected", player_deck, opponent_deck,
		player_deck.get("_is_external", false), opponent_deck.get("_is_external", false))


func _on_random_pressed() -> void:
	_close()
	emit_signal("decks_selected", {}, {}, false, false)


func _close() -> void:
	if _overlay and is_instance_valid(_overlay):
		_overlay.queue_free()
		_overlay = null
