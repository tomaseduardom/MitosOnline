extends Control
## Main - Escena principal del juego. Punto de entrada que instancia módulos y conecta señales.

@export var test_mode: bool = false

# =============================================================================
# ESCENAS PRECARGADAS
# =============================================================================
const CardScene = preload("res://scenes/cards/Card.tscn")
const DropZoneScript = preload("res://scripts/ui/DropZone.gd")
const OpponentFanScript = preload("res://scripts/ui/OpponentFan.gd")
const GameStateScript = preload("res://scripts/core/config/GameState.gd")

# Preloads de módulos (fuerzan registro de class_name antes del parse de Main)
const _ZoneManagerScript      = preload("res://scripts/core/game/ZoneManager.gd")
const _PhaseFlowScript        = preload("res://scripts/core/game/PhaseFlowController.gd")
const _GameHUDScript          = preload("res://scripts/ui/GameHUDModule.gd")
const _GameBootstrapScript    = preload("res://scripts/core/game/GameBootstrap.gd")
const _CardInteractionScript  = preload("res://scripts/ui/CardInteractionModule.gd")
const _SceneSetupScript       = preload("res://scripts/ui/SceneSetupModule.gd")

# =============================================================================
# REFERENCIAS A NODOS
# =============================================================================
var _game_state: Node = null

@onready var turn_label: Label               = $TopBar/TurnLabel
@onready var phase_label: Label              = $TopBar/PhaseLabel
@onready var player_info: Label              = $TopBar/PlayerInfo
@onready var debug_label: Label              = $UI/DebugPanel/DebugLabel
@onready var game_board: Control             = $GameBoard
@onready var player_hand: Control            = $GameBoard/PlayerArea/PlayerHand
@onready var player_field: HBoxContainer     = $GameBoard/PlayerArea/PlayerField
@onready var player_gold: HBoxContainer      = $GameBoard/PlayerArea/PlayerReservaOro
@onready var player_oro_pagado: HBoxContainer= $GameBoard/PlayerArea/PlayerOroPagado
@onready var opponent_field: HBoxContainer   = $GameBoard/OpponentArea/OpponentField
var _opponent_fan: Node = null

@onready var player_castillo_count: Label    = $GameBoard/PlayerArea/PlayerCastillo/Count
@onready var player_cementerio_count: Label  = $GameBoard/PlayerArea/PlayerCementerio/Count
@onready var player_destierro_count: Label   = $GameBoard/PlayerArea/PlayerDestierro/Count
@onready var opponent_castillo_count: Label  = $GameBoard/OpponentArea/OpponentCastillo/Count
@onready var opponent_cementerio_count: Label= $GameBoard/OpponentArea/OpponentCementerio/Count
@onready var opponent_destierro_count: Label = $GameBoard/OpponentArea/OpponentDestierro/Count

@onready var _panel_player_cem: Panel = $GameBoard/PlayerArea/PlayerCementerio
@onready var _panel_player_dst: Panel = $GameBoard/PlayerArea/PlayerDestierro
@onready var _panel_opp_cem: Panel    = $GameBoard/OpponentArea/OpponentCementerio
@onready var _panel_opp_dst: Panel    = $GameBoard/OpponentArea/OpponentDestierro

@onready var player_oro_reserva_label: Label   = $GameBoard/PlayerArea/GoldAreaLabel
@onready var player_oro_pagado_label: Label    = $GameBoard/PlayerArea/OroPagadoLabel
@onready var opponent_oro_reserva_label: Label = $GameBoard/OpponentArea/OpponentReservaOroLabel
@onready var opponent_oro_pagado_label: Label  = $GameBoard/OpponentArea/OpponentOroPagadoLabel
@onready var timer_label: Label                = $TurnTimer/VBox/TimerLabel

@onready var mulligan_overlay: Panel      = $UI/MulliganOverlay
@onready var mulligan_hand: MulliganHand  = $UI/MulliganOverlay/MulliganHand
@onready var mulligan_cards_label: Label  = $UI/MulliganOverlay/MulliganCardsLabel
@onready var keep_hand_button: Button     = $UI/MulliganOverlay/MulliganButtons/KeepHandButton
@onready var mulligan_button: Button      = $UI/MulliganOverlay/MulliganButtons/MulliganButton

@onready var inspection_layer: CanvasLayer      = $CardInspectionLayer
@onready var inspection_blur: ColorRect         = $CardInspectionLayer/BlurBackground
@onready var inspection_container: CenterContainer = $CardInspectionLayer/CardContainer

# =============================================================================
# MÓDULOS (hijos Node creados en _ready)
# =============================================================================
var _gold_manager: GoldManager             = null
var _mulligan_ctrl: MulliganController     = null
var _card_inspector: CardInspectionLayer   = null
var _zone_viewer: ZoneViewerModule         = null
var _selection: SelectionModule            = null
var _zone_manager: ZoneManager             = null
var _phase_flow: PhaseFlowController       = null
var _game_hud: GameHUDModule               = null
var _bootstrap: GameBootstrap              = null
var _card_interaction: CardInteractionModule = null
var _scene_setup: SceneSetupModule         = null

# =============================================================================
# ESTADO
# =============================================================================
var _dice_winner: int = 0
var gold_cards: Array = []
var player_deck: Array = []
var opponent_deck: Array = []
var player_cemetery: Array = []
var opponent_cemetery: Array = []
const INITIAL_HAND_SIZE: int = 8  # DAR 4.3

# =============================================================================
# INICIALIZACIÓN
# =============================================================================
func _ready() -> void:
	print("[Main] Escena principal cargada")
	_game_state = get_node_or_null("/root/GameState")
	if not _game_state:
		push_warning("[Main] GameState no disponible como autoload")

	GameManager.turn_ended.connect(_on_turn_ended)
	GameManager.game_started.connect(_on_game_started)
	GameManager.game_ended.connect(_on_game_ended)

	# ── Módulos ──────────────────────────────────────────────────────────────
	_scene_setup = SceneSetupModule.new(); _scene_setup.name = "SceneSetupModule"
	add_child(_scene_setup); _scene_setup.setup(self)

	_game_hud = GameHUDModule.new(); _game_hud.name = "GameHUDModule"
	add_child(_game_hud); _game_hud.setup(self)

	_zone_manager = ZoneManager.new(); _zone_manager.name = "ZoneManager"
	add_child(_zone_manager); _zone_manager.setup(self)

	_phase_flow = PhaseFlowController.new(); _phase_flow.name = "PhaseFlowController"
	add_child(_phase_flow); _phase_flow.setup(self)

	_gold_manager = GoldManager.new(); _gold_manager.name = "GoldManager"
	add_child(_gold_manager); _gold_manager.setup(self)

	_card_interaction = CardInteractionModule.new(); _card_interaction.name = "CardInteractionModule"
	add_child(_card_interaction); _card_interaction.setup(self)

	_mulligan_ctrl = MulliganController.new(); _mulligan_ctrl.name = "MulliganController"
	add_child(_mulligan_ctrl); _mulligan_ctrl.setup(self)

	_card_inspector = CardInspectionLayer.new(); _card_inspector.name = "CardInspectorModule"
	add_child(_card_inspector); _card_inspector.setup(self)

	_zone_viewer = ZoneViewerModule.new(); _zone_viewer.name = "ZoneViewerModule"
	add_child(_zone_viewer); _zone_viewer.setup(self)

	_selection = SelectionModule.new(); _selection.name = "SelectionModule"
	add_child(_selection); _selection.setup(self)

	_bootstrap = GameBootstrap.new(); _bootstrap.name = "GameBootstrap"
	add_child(_bootstrap); _bootstrap.setup(self)

	VisualManager.setup(self, $Background)

	UIManager.setup({
		"turn_label": turn_label, "phase_label": phase_label,
		"player_info": player_info, "debug_label": debug_label,
		"timer_label": timer_label,
		"player_castillo_count": player_castillo_count,
		"player_cementerio_count": player_cementerio_count,
		"player_destierro_count": player_destierro_count,
		"opponent_castillo_count": opponent_castillo_count,
		"opponent_cementerio_count": opponent_cementerio_count,
		"opponent_destierro_count": opponent_destierro_count,
		"player_oro_reserva_label": player_oro_reserva_label,
		"player_oro_pagado_label": player_oro_pagado_label,
		"opponent_oro_reserva_label": opponent_oro_reserva_label,
		"opponent_oro_pagado_label": opponent_oro_pagado_label,
	})

	_bootstrap.start()


# =============================================================================
# CARTA — fábrica y señales
# =============================================================================
func _create_card(data: Dictionary, is_hidden: bool = false) -> Node:
	var card = CardScene.instantiate()
	card.load_from_data(data, is_hidden)
	return card


func _connect_card_signals(card: Node) -> void:
	card.card_clicked.connect(_card_interaction._on_card_clicked)
	card.card_double_clicked.connect(_card_interaction._on_card_double_clicked)
	card.card_right_clicked.connect(_on_card_right_clicked)
	card.card_hovered.connect(_card_interaction._on_card_hovered)
	card.card_unhovered.connect(_card_interaction._on_card_unhovered)
	card.card_dropped.connect(_card_interaction._on_card_dropped)


# =============================================================================
# DELEGADOS — SceneSetupModule
# =============================================================================
func _toggle_pause_menu() -> void:
	if _scene_setup: _scene_setup.toggle_pause_menu()


# =============================================================================
# DELEGADOS — GameBootstrap
# =============================================================================
func _setup_oro_inicial() -> void:
	if _bootstrap: _bootstrap._setup_oro_inicial()

func _prepare_game() -> void:
	if _bootstrap: _bootstrap._prepare_game()

func _start_mulligan_phase() -> void:
	if _mulligan_ctrl: await _mulligan_ctrl.start_mulligan_phase()


# =============================================================================
# DELEGADOS — CardInteractionModule
# =============================================================================
func _on_place_gold_pressed() -> void:
	if _card_interaction: _card_interaction._on_place_gold_pressed()

func _declare_attacker(card: Node) -> void:
	if _card_interaction: await _card_interaction._declare_attacker(card)

func _on_card_right_clicked(card: Node) -> void:
	if _card_inspector: _card_inspector.on_card_right_clicked(card)

func _close_card_inspection() -> void:
	if _card_inspector: _card_inspector.close_card_inspection()


# =============================================================================
# DELEGADOS — GoldManager
# =============================================================================
func play_card(card: Node) -> bool:
	return await _gold_manager.play_card(card)

func pagar_coste(cantidad: int) -> bool:
	return await _gold_manager.pagar_coste(cantidad)

func puede_pagar(cantidad: int) -> bool:
	return _gold_manager.puede_pagar(cantidad)

func get_oro_disponible() -> int:
	return _gold_manager.get_oro_disponible()

func get_oro_pagado() -> int:
	return _gold_manager.get_oro_pagado()

func get_oro_total() -> int:
	return _gold_manager.get_oro_total()

func generar_oros_virtuales(cantidad: int) -> void:
	_gold_manager.generar_oros_virtuales(cantidad)

func limpiar_oros_virtuales() -> void:
	_gold_manager.limpiar_oros_virtuales()

func _update_gold_display() -> void:
	if _gold_manager: _gold_manager._update_gold_display()

func _reset_gold() -> void:
	await _gold_manager._reset_gold()


# =============================================================================
# DELEGADOS — ZoneManager
# =============================================================================
func draw_card(player_id: int = 0) -> bool:
	if _zone_manager: return await _zone_manager.draw_card(player_id)
	return false

func draw_initial_hand(player_id: int, count: int = 7) -> void:
	if _zone_manager: await _zone_manager.draw_initial_hand(player_id, count)

func _update_castillo_counts() -> void:
	if _zone_manager: _zone_manager._update_castillo_counts()

func shuffle_deck(player_id: int = 0) -> void:
	if _zone_manager: _zone_manager.shuffle_deck(player_id)

func move_card(from_zone: Constants.Zone, to_zone: Constants.Zone, amount: int = 1) -> void:
	if _zone_manager: _zone_manager.move_card(from_zone, to_zone, amount)


# =============================================================================
# DELEGADOS — GameHUDModule
# =============================================================================
func _show_phase_title(text: String) -> void:
	if _game_hud: _game_hud.show_phase_title(text)

func _update_paso_button_state() -> void:
	if _game_hud: _game_hud.update_paso_button_state()

func _start_paso_glow() -> void:
	if _game_hud: _game_hud.start_paso_glow()

func _stop_paso_glow() -> void:
	if _game_hud: _game_hud.stop_paso_glow()


# =============================================================================
# DELEGADOS — PhaseFlowController
# =============================================================================
func _on_paso_pressed() -> void:
	if _phase_flow: _phase_flow._on_paso_pressed()

func _on_priority_both_passed_main() -> void:
	pass  # PhaseFlowController conecta directamente

func _on_stack_resolved() -> void:
	pass  # PhaseFlowController conecta directamente

func _do_fase_final() -> void:
	if _phase_flow: await _phase_flow._do_fase_final()

func _on_phase_state_machine(new_phase: Constants.Phase) -> void:
	if _phase_flow: _phase_flow._on_phase_state_machine(new_phase)


# =============================================================================
# DELEGADOS — SelectionModule
# =============================================================================
func open_exhume_selection(player_id: int = 0) -> void:
	_selection.open_exhume_selection(player_id)

func open_search_deck(player_id: int = 0, filter: Callable = Callable(), on_selected: Callable = Callable()) -> void:
	_selection.open_search_deck(player_id, filter, on_selected)

func reveal_damage_cards(cards: Array) -> void:
	_selection.reveal_damage_cards(cards)


# =============================================================================
# CALLBACKS DEL GAMEMANAGER
# =============================================================================
func _on_game_started() -> void:
	_update_debug("Partida iniciada!")

func _on_game_ended(winner: int) -> void:
	_update_debug("Jugador %d gana!" % (winner + 1))
	UIManager.set_phase_text("VICTORIA!")

func _on_phase_changed(_new_phase: Constants.Phase) -> void:
	pass  # PhaseFlowController gestiona directamente

func _on_turn_ended(_player_id: int) -> void:
	pass

func _update_buttons_for_phase(_phase: Constants.Phase) -> void:
	pass

func get_deck_size(player_id: int) -> int:
	var cm = get_node_or_null("/root/CardManager")
	if cm: return cm.get_deck_count(player_id)
	return player_deck.size() if player_id == 0 else opponent_deck.size()

func _sync_oro_ui() -> void:
	if not _game_state: return
	UIManager.update_oro_reserva(0, _game_state.get_oro_reserva(0))
	UIManager.update_oro_pagado(0, _game_state.get_oro_pagado(0))
	UIManager.update_oro_reserva(1, _game_state.get_oro_reserva(1))
	UIManager.update_oro_pagado(1, _game_state.get_oro_pagado(1))


# =============================================================================
# DEBUG E INPUT
# =============================================================================
func _update_debug(text: String) -> void:
	UIManager.show_debug(text)
	print("[Main] %s" % text)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		call_deferred("_check_deselect")

	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_F1:
				_update_debug("Fase: %s" % Constants.PHASE_NAMES[GameManager.current_phase])
			KEY_F2:
				_update_debug("Turno: %d, Jugador: %d" % [GameManager.current_turn, GameManager.active_player_id + 1])
			KEY_F3:
				_update_debug("Cartas en DB: %d" % CardDatabase.cards.size())
			KEY_F4:
				_update_debug("Oro disponible: %d" % gold_cards.size())
			KEY_F5:
				draw_card(0)
			KEY_F6:
				_update_debug("Castillo: %d cartas | Mano: %d" % [player_deck.size(), player_hand.get_child_count()])
			KEY_F7:
				open_exhume_selection(0)
			KEY_F8:
				var preview = player_deck.slice(0, mini(3, player_deck.size()))
				SelectionManager.open_reveal(preview, "Vista previa del Mazo")
			KEY_F9:
				CardDatabase.run_smoke_test()
			KEY_ESCAPE:
				if _card_inspector and _card_inspector.inspected_card:
					_card_inspector.close_card_inspection()
				elif _card_interaction and _card_interaction.is_selecting_target:
					_card_interaction.cancel_target_selection()
				elif _card_interaction and _card_interaction.is_placing_gold:
					_card_interaction.is_placing_gold = false
					_update_debug("Modo Oro cancelado")
				else:
					_toggle_pause_menu()


func _check_deselect() -> void:
	if _card_interaction: _card_interaction.check_deselect()
