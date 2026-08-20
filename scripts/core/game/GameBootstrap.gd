extends Node
class_name GameBootstrap
## GameBootstrap — Carga de cartas, selección de mazos, dados y preparación de partida.
## Se instancia como hijo de Main en _ready().

var _main: Node = null


func setup(main: Node) -> void:
	_main = main


func start() -> void:
	"""Punto de entrada: carga cartas y arranca el flujo de inicio."""
	_load_cards()


# =============================================================================
# CARGA DE CARTAS
# =============================================================================
func _load_cards() -> void:
	"""Carga las cartas: bundled (res://) → cache (user://) → API externa.
	La API vieja (load_cards_from_api, localhost:3000) ya no está disponible —
	ver ExternalApiClient.gd. Bundled/cache normalmente cubren esto (5607
	cartas ya incluidas), así que este último paso rara vez se ejecuta."""
	if CardDatabase.load_cards_from_bundled():
		_main._update_debug("Cartas bundled: %d. Iniciando juego..." % CardDatabase.cards.size())
		_show_deck_selector()
		return
	if CardDatabase.load_cards_from_cache():
		_main._update_debug("Cartas desde cache: %d. Iniciando juego..." % CardDatabase.cards.size())
		_show_deck_selector()
		return
	if not CardDatabase.cards_loaded.is_connected(_on_cards_loaded):
		CardDatabase.cards_loaded.connect(_on_cards_loaded)
	if not CardDatabase.cards_load_failed.is_connected(_on_cards_load_failed):
		CardDatabase.cards_load_failed.connect(_on_cards_load_failed)
	_main._update_debug("Cargando cartas desde la API externa...")
	CardDatabase.load_cards_from_external_api()


func _on_cards_loaded(count: int) -> void:
	_main._update_debug("Cartas cargadas: %d" % count)
	CardDatabase.save_cards_to_cache()
	CardDatabase.export_for_bundling()
	_show_deck_selector()


func _on_cards_load_failed(error: String) -> void:
	_main._update_debug("Error cargando cartas: %s. Usando cartas de prueba." % error)
	_show_deck_selector()


# =============================================================================
# SELECCIÓN DE MAZOS
# =============================================================================
func _show_deck_selector() -> void:
	"""Muestra el popup de selección de mazos antes del sorteo de dados."""
	var script = load("res://scripts/ui/DeckSelector.gd")
	if not script:
		push_warning("[Bootstrap] DeckSelector.gd no encontrado — saltando al sorteo")
		_show_dice_roll()
		return
	var selector = script.new()
	_main.add_child(selector)
	selector.decks_selected.connect(_on_decks_selected)
	selector.show_selector(_main)


func _on_decks_selected(player_data: Dictionary, opponent_data: Dictionary, is_external: bool = false) -> void:
	if player_data.is_empty() or opponent_data.is_empty():
		_show_dice_roll()
		return
	var deck_loader = get_node_or_null("/root/DeckLoader")
	if not deck_loader:
		push_warning("[Bootstrap] DeckLoader no disponible — usando mazos aleatorios")
		_show_dice_roll()
		return
	if not deck_loader.all_decks_ready.is_connected(_show_dice_roll):
		deck_loader.all_decks_ready.connect(_show_dice_roll, CONNECT_ONE_SHOT)
	# Nadie escuchaba deck_load_failed en este flujo (2026-08-18): si un mazo
	# no tenía ninguna carta encontrable en CardDatabase (p.ej. porque el
	# catálogo cargado es más chico que el mazo guardado), DeckLoader emitía
	# el fallo a la nada y el juego se quedaba esperando para siempre una
	# all_decks_ready que nunca iba a llegar — sin ningún error visible.
	if not deck_loader.deck_load_failed.is_connected(_on_deck_load_failed):
		deck_loader.deck_load_failed.connect(_on_deck_load_failed)
	if is_external:
		deck_loader.load_deck_from_external_data(0, player_data)
		deck_loader.load_deck_from_external_data(1, opponent_data)
	else:
		deck_loader.load_deck_from_data(0, player_data)
		deck_loader.load_deck_from_data(1, opponent_data)


func _on_deck_load_failed(player_id: int, error: String) -> void:
	"""Si un mazo falla, no dejar el juego colgado esperando all_decks_ready
	para siempre — avisar y usar un mazo aleatorio de respaldo para ese
	jugador, que sí calza con las cartas realmente disponibles."""
	_main._update_debug("Mazo del jugador %d falló (%s) — usando mazo aleatorio" % [player_id + 1, error])
	push_warning("[Bootstrap] Mazo de jugador %d falló: %s — cargando mazo aleatorio de respaldo" % [player_id, error])
	var deck_loader = get_node_or_null("/root/DeckLoader")
	if deck_loader:
		deck_loader.load_random_deck(player_id)


# =============================================================================
# INICIO DE PARTIDA
# =============================================================================
func _prepare_game() -> void:
	"""Prepara mazos, jugadores y GameManager (sin mulligan)."""
	print("[Bootstrap] Preparando partida...")
	var deck_loader = get_node_or_null("/root/DeckLoader")
	if deck_loader and deck_loader.has_method("is_deck_loaded") and deck_loader.is_deck_loaded(0):
		print("[Bootstrap] Usando mazo del DeckLoader")
		_sync_decks_from_loader()
	if _main.player_deck.size() < 10:
		print("[Bootstrap] Mazo insuficiente (%d cartas), usando mazo de prueba" % _main.player_deck.size())
		_build_test_decks()
	print("[Bootstrap] Mazos listos — jugador: %d, oponente: %d cartas" % [_main.player_deck.size(), _main.opponent_deck.size()])
	if not _main.get_node_or_null("Player1"):
		var p1 = Node.new(); p1.name = "Player1"; _main.add_child(p1)
	if not _main.get_node_or_null("Player2"):
		var p2 = Node.new(); p2.name = "Player2"; _main.add_child(p2)
	GameManager.setup_game(_main.get_node("Player1"), _main.get_node("Player2"))
	_main.shuffle_deck(0)
	_main.shuffle_deck(1)
	var cdb = get_node_or_null("/root/CardDatabase")
	if cdb and cdb.has_method("preload_deck_images"):
		cdb.preload_deck_images(_main.player_deck + _main.opponent_deck)


func _start_test_game() -> void:
	_prepare_game()
	await _main._start_mulligan_phase()


func _setup_oro_inicial() -> void:
	"""Extrae el Oro Inicial de ambos mazos y lo coloca en Reserva antes del mulligan."""
	for player_id in [0, 1]:
		var deck: Array = _main.player_deck if player_id == 0 else _main.opponent_deck
		var found_idx: int = -1
		for i in range(deck.size()):
			var texto: String = (deck[i].get("habilidad", "") + " " + deck[i].get("nombre", "")).to_lower()
			if "oro inicial" in texto:
				found_idx = i
				break
		var oro_data: Dictionary
		if found_idx != -1:
			oro_data = deck[found_idx]
			deck.remove_at(found_idx)
			print("[Bootstrap] Oro Inicial extraído (J%d): %s — mazo: %d cartas" % [player_id, oro_data.get("nombre", "?"), deck.size()])
		else:
			oro_data = {
				"id": "oro_inicial_fallback_%d" % player_id,
				"nombre": "Oro Inicial",
				"tipo": Constants.CardType.ORO,
				"coste": 0,
				"fuerza": 0,
				"habilidad": "",
				"raza": "",
				"imagen": "/dorso_default.webp",
				"keywords": []
			}
			print("[Bootstrap] Sin Oro Inicial en mazo J%d — carta sintética generada" % player_id)
		if player_id == 0:
			var card = _main._create_card(oro_data)
			card.can_interact = true
			_main._connect_card_signals(card)
			_main.player_gold.add_child(card)
			_main.gold_cards.append(card)
			if _main._game_state:
				_main._game_state.agregar_oro_reserva(0, 1)
			_main._update_gold_display()
		else:
			if _main._game_state:
				_main._game_state.agregar_oro_reserva(1, 1)
	_main._update_castillo_counts()


func _sync_decks_from_loader() -> void:
	_main.player_deck.clear()
	_main.opponent_deck.clear()
	var deck_loader = get_node_or_null("/root/DeckLoader")
	if not deck_loader:
		push_error("[Bootstrap] DeckLoader no disponible para sincronizar")
		return
	for card_data in deck_loader.get_deck_data(0):
		_main.player_deck.append(card_data)
	for card_data in deck_loader.get_deck_data(1):
		_main.opponent_deck.append(card_data)
	deck_loader.clear_deck_data(0)
	deck_loader.clear_deck_data(1)
	print("[Bootstrap] Mazos sincronizados: Jugador=%d, Oponente=%d" % [_main.player_deck.size(), _main.opponent_deck.size()])


func _build_decks() -> void:
	_main.player_deck.clear()
	_main.opponent_deck.clear()
	if CardDatabase.is_loaded and CardDatabase.cards.size() > 0:
		_build_decks_from_database()
	else:
		_build_test_decks()


func _build_decks_from_database() -> void:
	var oros = CardDatabase.get_cards_by_type(Constants.CardType.ORO)
	var aliados = CardDatabase.get_cards_by_type(Constants.CardType.ALIADO)
	var armas = CardDatabase.get_cards_by_type(Constants.CardType.ARMA)
	var talismanes = CardDatabase.get_cards_by_type(Constants.CardType.TALISMAN)
	var oro_count = mini(20, oros.size())
	for i in range(oro_count):
		_main.player_deck.append(oros[i % oros.size()])
	var cards_needed = 50 - oro_count
	var other_cards = aliados + armas + talismanes
	for i in range(cards_needed):
		if other_cards.size() > 0:
			_main.player_deck.append(other_cards[i % other_cards.size()])
	_main.opponent_deck = _main.player_deck.duplicate()
	print("[Bootstrap] Mazos construidos: %d cartas" % _main.player_deck.size())


func _build_test_decks() -> void:
	print("[Bootstrap] Usando cartas de prueba")
	for i in range(15):
		_main.player_deck.append({
			"id": "oro_%d" % i, "nombre": "Oro",
			"tipo": Constants.CardType.ORO, "coste": 0, "fuerza": 0,
			"habilidad": "", "raza": "", "keywords": []
		})
	var test_allies = [
		{"nombre": "Guerrero Vikingo", "coste": 3, "fuerza": 4, "raza": "Vikingo", "habilidad": "Furia."},
		{"nombre": "Arquero Elfico", "coste": 2, "fuerza": 2, "raza": "Elfo", "habilidad": "Al entrar, haz 1 de daño."},
		{"nombre": "Jinete del Norte", "coste": 4, "fuerza": 5, "raza": "Vikingo", "habilidad": ""},
		{"nombre": "Mago Oscuro", "coste": 3, "fuerza": 2, "raza": "Hechicero", "habilidad": "Al entrar, roba una carta."},
		{"nombre": "Golem de Piedra", "coste": 5, "fuerza": 7, "raza": "Constructo", "habilidad": "Indestructible."},
		{"nombre": "Espadachin Real", "coste": 2, "fuerza": 3, "raza": "Humano", "habilidad": ""},
		{"nombre": "Dragon Menor", "coste": 6, "fuerza": 6, "raza": "Dragon", "habilidad": "Imbloqueable."},
		{"nombre": "Sacerdotisa", "coste": 3, "fuerza": 2, "raza": "Clerigo", "habilidad": "Al entrar, gana 2 vida."},
	]
	for i in range(25):
		var base = test_allies[i % test_allies.size()].duplicate()
		base["id"] = "ally_%d" % i
		base["tipo"] = Constants.CardType.ALIADO
		base["keywords"] = []
		_main.player_deck.append(base)
	for i in range(5):
		_main.player_deck.append({
			"id": "arma_%d" % i, "nombre": "Espada Ancestral",
			"tipo": Constants.CardType.ARMA, "coste": 2, "fuerza": 0,
			"habilidad": "El portador gana +2 Fuerza.", "raza": "", "keywords": []
		})
	for i in range(5):
		_main.player_deck.append({
			"id": "talisman_%d" % i, "nombre": "Bola de Fuego",
			"tipo": Constants.CardType.TALISMAN, "coste": 3, "fuerza": 0,
			"habilidad": "Destruye un Aliado con Fuerza 3 o menos.", "raza": "", "keywords": []
		})
	_main.opponent_deck = _main.player_deck.duplicate(true)
	print("[Bootstrap] Mazos de prueba: %d cartas" % _main.player_deck.size())


# =============================================================================
# DUELO DE DADOS
# =============================================================================
func _show_dice_roll() -> void:
	"""Animación de dados — al terminar llama _start_mulligan_phase()."""
	print("[Bootstrap] _show_dice_roll: iniciando")
	UIManager.set_phase_text("Sorteo")

	const DICE_FACES: Array = ["⚀", "⚁", "⚂", "⚃", "⚄", "⚅"]
	var vp_size = _main.get_viewport().get_visible_rect().size

	var overlay = CanvasLayer.new()
	overlay.layer = 60
	_main.add_child(overlay)

	var wrapper = Control.new()
	wrapper.size = vp_size
	wrapper.pivot_offset = vp_size / 2.0
	overlay.add_child(wrapper)

	var bg = ColorRect.new()
	bg.size = vp_size
	bg.color = Color(0.0, 0.0, 0.0, 0.88)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	wrapper.add_child(bg)

	var panel = Panel.new()
	panel.size = Vector2(460, 340)
	panel.position = (vp_size - panel.size) / 2.0
	var ps = StyleBoxFlat.new()
	ps.bg_color = Color(0.07, 0.06, 0.11, 0.97)
	ps.border_color = Color(0.75, 0.55, 0.2, 1.0)
	ps.set_border_width_all(3)
	ps.set_corner_radius_all(14)
	ps.shadow_color = Color(0.75, 0.55, 0.2, 0.45)
	ps.shadow_size = 18
	panel.add_theme_stylebox_override("panel", ps)
	wrapper.add_child(panel)

	var vbox = VBoxContainer.new()
	vbox.position = Vector2(18, 18)
	vbox.size = panel.size - Vector2(36, 36)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 18)
	panel.add_child(vbox)

	var title = Label.new()
	title.text = "⚔  DUELO DE DADOS  ⚔"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35, 1.0))
	vbox.add_child(title)

	var subtitle = Label.new()
	subtitle.text = "¿Quién comienza la partida?"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 13)
	subtitle.add_theme_color_override("font_color", Color(0.65, 0.6, 0.55, 1.0))
	vbox.add_child(subtitle)

	var row = HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 55)
	vbox.add_child(row)

	var _make_die_col = func(label_text: String, color: Color) -> Array:
		var col = VBoxContainer.new()
		col.alignment = BoxContainer.ALIGNMENT_CENTER
		col.add_theme_constant_override("separation", 6)
		row.add_child(col)
		var lbl = Label.new()
		lbl.text = label_text
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.add_theme_font_size_override("font_size", 12)
		lbl.add_theme_color_override("font_color", color)
		col.add_child(lbl)
		var die = Label.new()
		die.text = "⚀"
		die.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		die.add_theme_font_size_override("font_size", 60)
		col.add_child(die)
		var res = Label.new()
		res.text = " "
		res.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		res.add_theme_font_size_override("font_size", 18)
		col.add_child(res)
		return [die, res, lbl]

	var p1_parts = _make_die_col.call("JUGADOR 1", Color(0.5, 0.72, 1.0, 1.0))
	var die1: Label = p1_parts[0]; var res1: Label = p1_parts[1]; var lbl1: Label = p1_parts[2]

	var vs = Label.new()
	vs.text = "VS"
	vs.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	vs.add_theme_font_size_override("font_size", 18)
	vs.add_theme_color_override("font_color", Color(0.55, 0.5, 0.45, 1.0))
	row.add_child(vs)

	var p2_parts = _make_die_col.call("JUGADOR 2", Color(1.0, 0.5, 0.5, 1.0))
	var die2: Label = p2_parts[0]; var res2: Label = p2_parts[1]; var lbl2: Label = p2_parts[2]

	var winner_lbl = Label.new()
	winner_lbl.text = ""
	winner_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	winner_lbl.add_theme_font_size_override("font_size", 17)
	winner_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35, 0.0))
	vbox.add_child(winner_lbl)

	var roll_interval = 0.07
	var elapsed = 0.0
	var roll_duration = 1.8
	while elapsed < roll_duration:
		die1.text = DICE_FACES[randi() % 6]
		die2.text = DICE_FACES[randi() % 6]
		await get_tree().create_timer(roll_interval).timeout
		elapsed += roll_interval
		if elapsed > roll_duration * 0.65:
			roll_interval = minf(roll_interval * 1.18, 0.22)

	var fp1 = 6
	var fp2 = randi() % 5 + 1
	die1.text = DICE_FACES[fp1 - 1]
	die2.text = DICE_FACES[fp2 - 1]
	res1.text = str(fp1)
	res2.text = str(fp2)
	_main._dice_winner = 0 if fp1 > fp2 else 1

	if _main._dice_winner == 0:
		lbl1.text = "✓ JUGADOR 1"
		res1.add_theme_color_override("font_color", Color(0.3, 1.0, 0.5, 1.0))
		res2.add_theme_color_override("font_color", Color(0.45, 0.45, 0.45, 1.0))
	else:
		lbl2.text = "✓ JUGADOR 2"
		res2.add_theme_color_override("font_color", Color(0.3, 1.0, 0.5, 1.0))
		res1.add_theme_color_override("font_color", Color(0.45, 0.45, 0.45, 1.0))

	winner_lbl.text = "¡Jugador %d comienza la partida!" % (_main._dice_winner + 1)
	var ft = create_tween()
	ft.tween_property(winner_lbl, "theme_override_colors/font_color", Color(1.0, 0.85, 0.35, 1.0), 0.35)

	await get_tree().create_timer(1.5).timeout
	_prepare_game()

	var exit_tween = create_tween()
	exit_tween.set_parallel(true)
	exit_tween.tween_property(wrapper, "modulate:a", 0.0, 0.5).set_ease(Tween.EASE_IN)
	exit_tween.tween_property(wrapper, "scale", Vector2(0.8, 0.8), 0.5).set_ease(Tween.EASE_IN)
	exit_tween.finished.connect(func():
		overlay.queue_free()
		print("[Bootstrap] Dados cerrados, iniciando mulligan")
		await _main._start_mulligan_phase()
	)
