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
	var script = load("res://scripts/ui/zones/DeckSelector.gd")
	if not script:
		push_warning("[Bootstrap] DeckSelector.gd no encontrado — saltando al sorteo")
		_show_dice_roll()
		return
	var selector = script.new()
	_main.add_child(selector)
	selector.decks_selected.connect(_on_decks_selected)
	selector.show_selector(_main)


func _on_decks_selected(player_data: Dictionary, opponent_data: Dictionary, player_is_external: bool = false, opponent_is_external: bool = false) -> void:
	# get_node_or_null("/root/...") en vez del identificador global directo
	# (2026-08-30): MatchLoadingOverlay SÍ está registrado como autoload en
	# project.godot, pero el compilador de GDScript no lo reconocía como
	# identificador válido ("Compile Error: Identifier not found") — mismo
	# síntoma que CardNameSearchDialog antes (un class_name/autoload nuevo
	# que el editor todavía no había terminado de indexar). La búsqueda por
	# ruta es una resolución en tiempo de ejecución, no depende de que el
	# compilador ya conozca el identificador.
	var _loading_overlay := get_node_or_null("/root/MatchLoadingOverlay")
	if _loading_overlay:
		_loading_overlay.show_loading(_main, "PREPARANDO PARTIDA", "Barajando los grimorios...")

	if player_data.is_empty() or opponent_data.is_empty():
		_show_dice_roll()
		return
	if not DeckLoader.all_decks_ready.is_connected(_show_dice_roll):
		DeckLoader.all_decks_ready.connect(_show_dice_roll, CONNECT_ONE_SHOT)
	# Nadie escuchaba deck_load_failed en este flujo (2026-08-18): si un mazo
	# no tenía ninguna carta encontrable en CardDatabase (p.ej. porque el
	# catálogo cargado es más chico que el mazo guardado), DeckLoader emitía
	# el fallo a la nada y el juego se quedaba esperando para siempre una
	# all_decks_ready que nunca iba a llegar — sin ningún error visible.
	if not DeckLoader.deck_load_failed.is_connected(_on_deck_load_failed):
		DeckLoader.deck_load_failed.connect(_on_deck_load_failed)
	# Jugador y oponente pueden venir de orígenes distintos ahora (2026-08-24):
	# tu propio mazo (externo) para uno, un preset por raza (local) para el
	# otro — cada lado se enruta según SU propio origen, no uno compartido.
	if player_is_external:
		DeckLoader.load_deck_from_external_data(0, player_data)
	else:
		DeckLoader.load_deck_from_data(0, player_data)
	if opponent_is_external:
		DeckLoader.load_deck_from_external_data(1, opponent_data)
	else:
		DeckLoader.load_deck_from_data(1, opponent_data)


func _on_deck_load_failed(player_id: int, error: String) -> void:
	"""Si un mazo falla, no dejar el juego colgado esperando all_decks_ready
	para siempre — avisar y usar un mazo aleatorio de respaldo para ese
	jugador, que sí calza con las cartas realmente disponibles."""
	_main._update_debug("Mazo del jugador %d falló (%s) — usando mazo aleatorio" % [player_id + 1, error])
	push_warning("[Bootstrap] Mazo de jugador %d falló: %s — cargando mazo aleatorio de respaldo" % [player_id, error])
	DeckLoader.load_random_deck(player_id)


# =============================================================================
# INICIO DE PARTIDA
# =============================================================================
func _prepare_game() -> void:
	"""Prepara mazos, jugadores y GameManager (sin mulligan)."""
	print("[Bootstrap] Preparando partida...")
	if DeckLoader.is_deck_loaded(0):
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
	_main._zone_manager.shuffle_deck(0)
	_main._zone_manager.shuffle_deck(1)
	CardDatabase.preload_deck_images(_main.player_deck + _main.opponent_deck)


func _start_test_game() -> void:
	_prepare_game()
	await _main._mulligan_ctrl.start_mulligan_phase()


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
			card.scale = Constants.GOLD_CARD_SCALE
			card.base_scale = Constants.GOLD_CARD_SCALE
			_main._connect_card_signals(card)
			_main.player_gold.add_child(card)
			# set_zone() faltaba acá (2026-08-29, bug real reportado: el Oro
			# Inicial quedaba con current_zone en su valor por defecto, MANO
			# — nunca se actualizaba a RESERVA_ORO porque este camino de
			# colocación es distinto al de _place_card_as_gold(), que sí lo
			# hace. Cualquier efecto que revise 'está en juego/en Reserva'
			# vía current_zone —p.ej. Convertir de Capitán O'Brien— rechazaba
			# el Oro Inicial como objetivo aunque estuviera ahí a la vista).
			card.set_zone(Constants.Zone.RESERVA_ORO)
			_main.gold_cards.append(card)
			GameState.agregar_oro_reserva(0, 1)
			_main._gold_manager._update_gold_display()
		else:
			# El Oro Inicial del oponente ahora también se muestra como carta
			# real (2026-08-25, a pedido del usuario) — antes solo sumaba al
			# contador, sin ningún nodo visible en OpponentReservaOro. El Oro
			# es información pública (DAR): va boca arriba, no oculta como una
			# carta de mano (2026-08-26 — se creaba con is_hidden=true por error).
			var card = _main._create_card(oro_data, false)
			card.owner_id = 1
			# can_interact = true (2026-08-28, a pedido del usuario: "necesito
			# poder interactuar con él como con mis cartas") — antes estaba en
			# false, así que ni el hover corría sobre esta carta (con
			# can_interact=false, CardInteraction.process() la ignora entera).
			card.can_interact = true
			card.scale = Constants.GOLD_CARD_SCALE
			card.base_scale = Constants.GOLD_CARD_SCALE
			card.pivot_offset = Vector2(75.0, 105.0)
			card.rotation_degrees = 180.0
			_main._connect_card_signals(card)
			_main.opponent_gold.add_child(card)
			card.set_zone(Constants.Zone.RESERVA_ORO)  # ver comentario arriba, mismo bug en el lado rival
			GameState.agregar_oro_reserva(1, 1)
	_main._zone_manager._update_castillo_counts()


func _sync_decks_from_loader() -> void:
	_main.player_deck.clear()
	_main.opponent_deck.clear()
	for card_data in DeckLoader.get_deck_data(0):
		_main.player_deck.append(card_data)
	for card_data in DeckLoader.get_deck_data(1):
		_main.opponent_deck.append(card_data)
	DeckLoader.clear_deck_data(0)
	DeckLoader.clear_deck_data(1)
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


func _debug_spawn_opponent_test_allies(count: int = 3, card_name: String = "bernardo ohiggins") -> void:
	"""DEBUG TEMPORAL (2026-09-02, a pedido del usuario, "solo por ahora"):
	al terminar el mulligan, pone 'count' copias de la misma carta conocida
	(Bernardo O'Higgins por defecto — 2026-09-02, a pedido del usuario:
	'que sean 3 Bernardo OHiggins o algo así', para tener un objetivo fijo
	y repetible en vez de lo que sea que toque al azar del mazo cargado)
	directo en la Línea de Defensa del rival, para poder probar efectos que
	apuntan a 'una carta oponente' en juego (p.ej. Estaca — Barajar una
	carta oponente que no sea Oro) sin tener que jugar una partida completa
	contra el bot primero. Busca la carta por nombre en CardDatabase (no en
	el mazo cargado — así siempre están disponibles, tenga o no el mazo del
	rival esa carta) y duplica sus datos ('duplicate(true)', para que las 3
	copias no compartan el mismo Dictionary). Si no la encuentra, cae al
	comportamiento viejo (primeros Aliados que encuentre en opponent_deck).
	Sin ETB (no pasa por _trigger_enter_play() a propósito — son solo
	cuerpos en juego, no 'jugados' de verdad) PERO CON efectos continuos
	(auras tipo 'Tus Aliados ganan Fuerza' — 2026-09-02, corrección: se
	registran directo vía ContinuousEffectManager._register_card_
	continuous_effects(), sin abrir ninguna ventana de trigger/respuesta,
	porque una aura pasiva no depende de haber sido 'jugada'). Buscar este
	comentario para sacarlo cuando ya no haga falta — llamado desde
	MulliganController._end_mulligan_phase()."""
	if not _main.opponent_field:
		return

	var base_data: Dictionary = CardDatabase.get_card_by_name(card_name) if CardDatabase else {}
	var placed := 0

	if not base_data.is_empty():
		for i in range(count):
			var data: Dictionary = base_data.duplicate(true)
			var card = _main._create_card(data, false)  # is_hidden=false: en juego es info pública
			card.owner_id = 1
			card.controller_id = 1
			card.pivot_offset = Vector2(75.0, 105.0)
			card.rotation_degrees = 180.0
			_main._connect_card_signals(card)
			_main.opponent_field.add_child(card)
			card.top_level = false
			card.set_zone(Constants.Zone.LINEA_DEFENSA)
			card.scale = Vector2.ONE
			card.base_scale = Vector2.ONE
			card.can_interact = true
			CardFactory.on_card_enters_play(card)
			ContinuousEffectManager._register_card_continuous_effects(card)
			placed += 1
	elif not _main.opponent_deck.is_empty():
		# Fallback (no se encontró 'card_name' en CardDatabase): primeros
		# Aliados del propio mazo del rival, como antes de este cambio.
		var i := 0
		while i < _main.opponent_deck.size() and placed < count:
			var data: Dictionary = _main.opponent_deck[i]
			if data.get("tipo", -1) != Constants.CardType.ALIADO:
				i += 1
				continue
			_main.opponent_deck.remove_at(i)
			var card = _main._create_card(data, false)  # is_hidden=false: en juego es info pública
			card.owner_id = 1
			card.controller_id = 1
			card.pivot_offset = Vector2(75.0, 105.0)
			card.rotation_degrees = 180.0
			_main._connect_card_signals(card)
			_main.opponent_field.add_child(card)
			card.top_level = false
			card.set_zone(Constants.Zone.LINEA_DEFENSA)
			card.scale = Vector2.ONE
			card.base_scale = Vector2.ONE
			card.can_interact = true
			CardFactory.on_card_enters_play(card)
			ContinuousEffectManager._register_card_continuous_effects(card)
			placed += 1

	if placed > 0:
		_main._zone_manager._update_castillo_counts()
		_main._update_debug("[DEBUG] %d Aliado(s) rival(es) puestos en juego para pruebas" % placed)


# =============================================================================
# DUELO DE DADOS D20 EN 3D
# =============================================================================
func _show_dice_roll() -> void:
	"""Lanza el Duelo de Dados D20 en 3D en tiempo real — al terminar llama _start_mulligan_phase()."""
	print("[Bootstrap] _show_dice_roll: iniciando duelo D20 en 3D")
	var loading_overlay := get_node_or_null("/root/MatchLoadingOverlay")
	if loading_overlay:
		loading_overlay.hide_loading()
	UIManager.set_phase_text("Sorteo D20")

	var dice_duel = DiceDuel3D.new()
	_main.add_child(dice_duel)

	dice_duel.duel_completed.connect(func(winner_id: int):
		_main._dice_winner = winner_id
		print("[Bootstrap] Duelo D20 3D finalizado. Ganador: Jugador %d. Iniciando juego..." % (winner_id + 1))
		_prepare_game()
		await _main._mulligan_ctrl.start_mulligan_phase()
	)
