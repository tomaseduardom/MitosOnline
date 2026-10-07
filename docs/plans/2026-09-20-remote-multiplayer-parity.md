# Paridad de cartas para el jugador remoto — Plan de implementación

> **Para Claude:** al ejecutar este plan, usar la skill `executing-plans` tarea por tarea.

**Goal:** que un jugador remoto (Fase B ya construida — Oro, Aliados, atacar, mulligan,
una habilidad activada simple) pueda jugar Armas/Talismanes/Tótems, participar en
elecciones de `SelectionManager`, y ver un reflejo mínimo de la mano/mazo del Anfitrión —
para que una partida online real no se rompa apenas alguien juegue una carta fuera del
subconjunto actual.

**Arquitectura:** mismo patrón ya establecido por `RemotePlayerController extends
EasyBotController` (2026-09-11): cada punto de decisión nuevo manda un `{"op":"prompt",
"kind":...}` por `NetworkClient` y espera un `{"op":"intent","kind":...}` de vuelta — el
motor de reglas (GoldManager/TriggerSystem/EffectController) no cambia, solo QUIÉN
alimenta la decisión. Las funciones nuevas del lado Anfitrión van en
`RemotePlayerController.gd` (NO en `EasyBotController.gd` — no se le agrega alcance al
bot, que sigue sin jugar Armas/Talismanes hoy; alcance separado, fuera de este plan). Del
lado Remoto, `RemoteMirrorController.gd` gana los diálogos/manejo de los `kind` nuevos.

**Tech Stack:** GDScript (Godot 4.6), el relay/protocolo JSON ya desplegado (ver
`arquitectura.md` §11) — nada nuevo de infraestructura, solo mensajes nuevos sobre el
mismo canal.

**Cómo verificar cada tarea (no hay tests automatizados en este proyecto — todo se
verifica jugando):** 2 instancias de Godot en la misma máquina, una como Anfitrión
(`OnlineConnect.gd` → Crear sala) y otra como Remoto (Unirse con el código) — ambas contra
el relay ya en producción (`wss://mitos-relay-server-production.up.railway.app`, ya es el
default). Instrucciones puntuales de qué probar en cada tarea, abajo.

**Alcance real — leer antes de arrancar:** la Fase 3 (`SelectionManager` en red) es GRANDE
— +100 sitios reales del motor de efectos la usan (`await_single_pick`/`await_multi_pick`/
`await_two_choice`/`open_selection`, ver `arquitectura.md` §10.16). Este plan construye el
mecanismo genérico + UN caso convertido como demostración — el resto queda para
conversión incremental posterior, carta por carta, mismo criterio que ya usó este proyecto
para el barrido de pickers modales → click directo (§10.14 y siguientes). No se intenta
"terminar" la Fase 3 entera acá — sería una sesión aparte, quizás varias.

---

## Fase 1 — Armas, Tótems y Talismanes para el jugador remoto

### Task 1.1: Generalizar el filtro de candidatos jugables de la mano

**Contexto:** `RemotePlayerController.take_vigilia_actions()` hoy solo ofrece Oro y
Aliados (`_affordable_allies_in_hand()`, heredada de `EasyBotController.gd:152`, filtra
`card_type != ALIADO`). Hace falta la misma lógica de "afordable" (costo real, sin
violaciones de Errante/límite de copias/etc.) para Arma/Talismán/Tótem, sin tocar la
función del bot.

**Files:**
- Modify: `scripts/core/ai/RemotePlayerController.gd`

**Paso 1 — agregar el helper generalizado, al lado de `_card_public_data()`:**

```gdscript
func _affordable_cards_in_hand(allowed_types: Array) -> Array:
	"""Como EasyBotController._affordable_allies_in_hand(), pero para
	cualquier tipo de carta (no solo Aliado) — el bot no juega Armas/
	Talismanes/Tótems todavía (fuera de alcance de ESE archivo), pero el
	Remoto sí necesita poder ofrecérselos a la persona real. No se tocó
	_affordable_allies_in_hand() para no darle alcance nuevo al bot sin que
	se haya pedido."""
	var result: Array = []
	if not _main._opponent_fan:
		return result
	var reserva: int = GameState.get_oro_reserva(1)
	var gm = _main._gold_manager
	for c in _main._opponent_fan.get_cards():
		if not is_instance_valid(c) or not (c.get("card_type") in allowed_types):
			continue
		if gm and (gm._no_more_cards_violation(c) or gm._card_play_locked(c) \
				or gm._errante_violation(c) or gm._play_limit_violation(c)):
			continue
		var coste: int = PaymentManager.calcular_coste_real(c)
		if coste <= reserva:
			result.append(c)
	return result
```

**Verificación:** no hay forma de probar esto aislado — se verifica junto con la Tarea 1.4
(cuando el prompt de Vigilia ya ofrezca estos candidatos).

---

### Task 1.2: `_play_totem_remote()` — Tótem para el jugador remoto

**Contexto:** un Tótem entra en juego igual que un Aliado pero a
`Constants.Zone.LINEA_APOYO` / `_main.opponent_linea_apoyo` (ver
`GoldManager._play_card_to_field()`, líneas 1308-1311). Mismo criterio que
`EasyBotController._play_ally()` (ya arreglada hoy, arquitectura.md §10.53): abrir
`TriggerSystem.open_response_window()` ANTES de que dispare su "Cuando entra en juego",
con `controller_id=1` explícito (nunca reusar `GoldManager._trigger_enter_play()` para el
jugador 1 — esa función emite `on_card_entered_play` con `player_id` fijo en `0`, ver nota
en `arquitectura.md` §11 y este mismo plan más abajo).

**Files:**
- Modify: `scripts/core/ai/RemotePlayerController.gd`

**Paso 1 — agregar, después de `_play_ally`-equivalente (ver Task 1.3, comparten forma):**

```gdscript
func _play_totem_remote(card: Node) -> void:
	if not is_instance_valid(card):
		return
	var coste: int = PaymentManager.calcular_coste_real(card)
	_main._update_debug("Oponente juega Tótem: %s" % card.card_name)

	_main._opponent_fan.remove_card(card, false)
	card.esta_oculta = false
	_pay_oro_for_bot(coste)
	TurnManager.on_card_played(card)

	card.can_interact = false
	_main.opponent_linea_apoyo.add_child(card)
	card.top_level = false
	card.set_zone(Constants.Zone.LINEA_APOYO)
	card.scale = Vector2(0.8, 0.8)
	card.base_scale = Vector2(0.8, 0.8)
	if _main._zone_manager:
		_main._zone_manager.pin_card_to_field_slot(card, _main.opponent_linea_apoyo)

	VisualManager.play_card_effect(card.card_cost)
	if card.has_method("play_enter_animation"):
		card.play_enter_animation()
	await get_tree().process_frame
	card.can_interact = true

	if await TriggerSystem.open_response_window(card, str(card.card_name) if card.get("card_name") else "", 1):
		await EffectController.destroy_card(1, card, false)
		if _main._gold_manager:
			_main._gold_manager._update_gold_display()
		return

	CardFactory.on_card_enters_play(card)
	if card.has_method("on_entered_play"):
		card.on_entered_play()
	if _main._gold_manager:
		_main._gold_manager._register_talisman_totem_tax(card)
		_main._gold_manager._register_talisman_second_play_tax(card)
	EffectController.emit_signal("on_card_entered_play", 1, card, Constants.Zone.LINEA_APOYO)
	await TriggerSystem._collect_triggers_for_event("on_enter_play", {
		"player_id": 1, "card": card, "zone": Constants.Zone.LINEA_APOYO
	})
	await EffectController.offer_counter_annul(card)
```

**Verificación:** junto con Task 1.4 — jugar un Tótem barato (p.ej. coste 1-2) como
Remoto y confirmar que aparece en la Línea de Apoyo del Anfitrión (del lado "oponente"),
a escala 0.8, y que su "Cuando entra en juego" (si tiene) dispara.

---

### Task 1.3: `_play_weapon_remote()` — Arma para el jugador remoto (con selección de portador por red)

**Contexto:** jugar un Arma necesita ADEMÁS elegir portador (`GoldManager.
_select_weapon_wielder()`, hoy hardcodeada a `_main._card_interaction` — inservible para
el Remoto). Hace falta un prompt de red nuevo, `"kind": "choose_wielder"`, ANTES de armar
el Arma. Reusa `GoldManager._get_eligible_weapon_wielders()` (ya existe, no toca a quién
controla el candidato — cualquier Aliado en juego sin Arma, propio o rival, es candidato
válido por DAR).

**Files:**
- Modify: `scripts/core/ai/RemotePlayerController.gd`

**Paso 1 — agregar la función de selección de portador:**

```gdscript
func _choose_wielder_remote(weapon: Node) -> Node:
	"""Pide al Remoto que elija portador para un Arma que está jugando —
	espejo de GoldManager._select_weapon_wielder(), pero preguntando por
	red en vez de abrir CardInteractionModule local."""
	if not _main._gold_manager or not _main._gold_manager.has_method("_get_eligible_weapon_wielders"):
		return null
	var eligible: Array = _main._gold_manager._get_eligible_weapon_wielders()
	if eligible.is_empty():
		return null
	var payload: Array = []
	for w in eligible:
		payload.append(_card_public_data(w))
	NetworkClient.send_message({"op": "prompt", "kind": "choose_wielder", "weapon": _card_public_data(weapon), "candidates": payload})
	var intent: Dictionary = await _await_intent(["choose_wielder"])
	var chosen := _find_card_by_id(str(intent.get("card_id", "")))
	if chosen and chosen in eligible:
		return chosen
	return null
```

**Paso 2 — agregar la función de jugar el Arma, reusando `GoldManager._equip_weapon()`
para la parte mecánica (portador YA elegido, esa función no asume jugador 0 — revisar
si asume owner_id del Arma o hardcodea contenedores; si asume, ver Nota abajo):**

```gdscript
func _play_weapon_remote(card: Node) -> void:
	if not is_instance_valid(card):
		return
	if not _main._gold_manager or not _main._gold_manager._player_has_ally_in_play():
		NetworkClient.send_message({"op": "prompt", "kind": "error", "message": "Sin Aliados en juego para portar el Arma"})
		return
	var coste: int = PaymentManager.calcular_coste_real(card)
	var wielder := await _choose_wielder_remote(card)
	if not wielder or not is_instance_valid(wielder):
		return

	_main._opponent_fan.remove_card(card, false)
	card.esta_oculta = false
	_pay_oro_for_bot(coste)
	TurnManager.on_card_played(card)
	card.owner_id = 1
	card.controller_id = 1

	if _main._gold_manager.has_method("_equip_weapon"):
		await _main._gold_manager._equip_weapon(card, wielder)
```

**Nota — REVISAR ANTES de escribir este paso de verdad:** `GoldManager._equip_weapon()`
(línea ~921) fue escrita pensando en el humano local — auditar si hace algo hardcodeado a
`_main.player_*`/jugador 0 aparte del bug de `to_local()` ya arreglado hoy (§10.55 en
arquitectura.md). Si lo tiene, extraer una versión paralela
`EasyBotController._equip_weapon_bot(weapon, ally)` en vez de reusarla — mismo criterio
que ya se usó para `_play_ally()` vs. `GoldManager._play_card_to_field()`. Este plan
ASUME que se puede reusar tal cual; confirmarlo es el primer paso real de esta tarea, no
una nota al margen.

**Verificación:** jugar un Arma como Remoto con al menos 1 Aliado propio y 1 rival en
juego — confirmar que el prompt de portador llega, que elegir cualquiera de los dos
funciona, y que el Arma queda anclada como hija del Aliado elegido (mismo criterio visual
que ya usa el humano local).

---

### Task 1.4: `_play_talisman_remote()` y ampliar `take_vigilia_actions()` con los 3 tipos nuevos

**Files:**
- Modify: `scripts/core/ai/RemotePlayerController.gd`

**Paso 1 — Talismán (resuelve y va directo al Cementerio/Destierro/mazo, no se queda en
juego — mismo criterio que `GoldManager._play_talisman()`, adaptado a contenedores del
jugador 1):**

```gdscript
func _play_talisman_remote(card: Node) -> void:
	if not is_instance_valid(card):
		return
	var coste: int = PaymentManager.calcular_coste_real(card)
	_main._update_debug("Oponente juega talismán: %s" % card.card_name)

	_main._opponent_fan.remove_card(card, false)
	card.esta_oculta = false
	_pay_oro_for_bot(coste)
	TurnManager.on_card_played(card)
	UniversalCardParser.turn_registry.register("talisman_played:1", 0, GameManager.current_turn)

	card.can_interact = false
	_main.opponent_linea_apoyo.add_child(card)
	card.top_level = false
	card.set_zone(Constants.Zone.LINEA_APOYO)
	await get_tree().create_timer(0.3).timeout

	await TriggerSystem.resolve_talisman(card)
```

**Paso 2 — reemplazar el bloque de `take_vigilia_actions()` que arma `ally_candidates` y
el `match` de intents, para incluir los 3 tipos nuevos:**

Ubicar en `RemotePlayerController.gd` (función `take_vigilia_actions()`, ya leída en esta
sesión) el bloque:

```gdscript
		var ally_candidates: Array = []
		for c in _affordable_allies_in_hand():
			ally_candidates.append(_card_public_data(c))
```

Reemplazar por:

```gdscript
		var ally_candidates: Array = []
		for c in _affordable_allies_in_hand():
			ally_candidates.append(_card_public_data(c))
		var weapon_candidates: Array = []
		for c in _affordable_cards_in_hand([Constants.CardType.ARMA]):
			weapon_candidates.append(_card_public_data(c))
		var talisman_candidates: Array = []
		for c in _affordable_cards_in_hand([Constants.CardType.TALISMAN]):
			talisman_candidates.append(_card_public_data(c))
		var totem_candidates: Array = []
		for c in _affordable_cards_in_hand([Constants.CardType.TOTEM]):
			totem_candidates.append(_card_public_data(c))
```

Y en el mismo mensaje `NetworkClient.send_message({"op": "prompt", "kind": "vigilia", ...})`
un poco más abajo, agregar las 3 listas nuevas al Dictionary (`"weapon_candidates":
weapon_candidates`, etc.).

Finalmente, en el `match intent.get("kind", ""):` de esa misma función, el caso
`"play_card"` hoy solo verifica `card.get("card_type") == Constants.CardType.ALIADO`.
Reemplazar por un `match` sobre el tipo de la carta elegida:

```gdscript
			"play_card":
				var card := _find_card_by_id(str(intent.get("card_id", "")))
				if card and is_instance_valid(card):
					match card.get("card_type"):
						Constants.CardType.ALIADO:
							await _play_ally(card)
						Constants.CardType.ARMA:
							await _play_weapon_remote(card)
						Constants.CardType.TALISMAN:
							await _play_talisman_remote(card)
						Constants.CardType.TOTEM:
							await _play_totem_remote(card)
```

**Paso 3 — `RemoteMirrorController.gd`: agregar los `kind` nuevos al lado que recibe los
prompts** (ubicar el `match data.get("op", "")... "prompt": match data.get("kind", "")`
existente — ya maneja `"vigilia"` con diálogo de texto; extenderlo para listar también
armas/talismanes/tótems entre las opciones clicleables, y agregar el caso nuevo
`"choose_wielder"` con su propio diálogo simple de lista). Mismo estilo ya usado ahí
(texto plano, sin arte) — no es el momento de pulir esa UI, solo que funcione.

**Verificación (de punta a punta, las 4 tareas juntas):** con las 2 instancias corriendo,
en el turno del Remoto: jugar un Aliado (regresión — debe seguir andando), un Arma
(con selección de portador), un Talismán, y un Tótem, en ese orden, en la misma partida
de prueba. Confirmar que cada uno aparece del lado correcto en la pantalla del Anfitrión
y que el Oro se descuenta bien.

---

## Fase 2 — Mano/Castillo del Anfitrión: dorsos genéricos para el Remoto

**Contexto:** `GameStateBroadcaster.gd` deja Mano/Castillo fuera a propósito (niebla de
guerra) pero hoy no manda NADA — el Remoto no ve ni un dorso de carta moverse. La mejora
mínima: mandar un evento genérico "algo se movió en tu mano/mazo rival" SIN datos de la
carta, para que el Remoto vea al menos un conteo/dorso, no silencio total.

### Task 2.1: `GameStateBroadcaster` — evento genérico de mano/mazo

**Files:**
- Modify: `scripts/core/network/GameStateBroadcaster.gd`

**Paso 1 — en `setup()`, conectar también las señales de robo/juego desde mano (buscar
qué señal real emite `ZoneManager.draw_card()`/`HandManager` al robar — candidatas:
`CardManager.deck_count_changed`, o agregar un emit nuevo si no existe ninguna genérica
para "el jugador 1 robó/jugó desde su mano"). Mandar:

```gdscript
NetworkClient.send_message({"op": "hand_count_changed", "count": <mano actual del jugador 1>})
NetworkClient.send_message({"op": "deck_count_changed", "count": <mazo actual del jugador 1>})
```

**Paso 2 — `RemoteMirrorController.gd`: manejar esos 2 `op` nuevos** — actualizar un
contador de texto simple ("Mano rival: N", "Castillo rival: N") en la UI del Remoto. No
hace falta representar cartas individuales (dorsos por Nodo) en esta pasada — un contador
ya cierra la brecha de "silencio total" sin construir UI nueva compleja.

**Verificación:** Anfitrión roba una carta en su turno → el contador de "Castillo rival"
en la pantalla del Remoto baja en 1, y viceversa (mano del Anfitrión sube).

---

## Fase 3 — `SelectionManager` en red (mecanismo genérico + 1 caso convertido)

**Contexto:** esta es la pieza grande. `SelectionManager.gd` no tiene NINGUNA noción de
`NetworkClient` — construido enteramente para el humano local. Con +100 sitios reales
llamándolo, no se convierte todo en una sola tarea — se construye el puente genérico y se
convierte UN caso real como demostración/plantilla para las conversiones futuras.

### Task 3.1: Puente genérico — `SelectionManager` detecta "el dueño es el Remoto" y redirige

**Files:**
- Modify: `scripts/core/effects/targeting/SelectionManager.gd`

**Paso 1 — al principio de cada función pública relevante (`open_selection()`,
`await_single_pick()`, `await_multi_pick()`, `await_two_choice()` — auditar cuáles
reciben ya un `owner_id`/`controller_id` explícito como parámetro; las que no lo reciben
necesitan ese parámetro agregado primero, cambio que toca a TODOS sus llamadores — evaluar
si conviene hacerlo función por función en vez de las 4 de una), agregar el chequeo:

```gdscript
if owner_id == 1 and NetworkClient.room_code != "" and NetworkClient.is_host:
	return await _delegate_to_remote(<mismos argumentos>)
```

**Paso 2 — `_delegate_to_remote()` nueva, mismo protocolo `prompt`/`intent` que
`RemotePlayerController.gd` ya usa (reusar `_card_public_data`-equivalente — mover ese
helper a un lugar compartido, p.ej. `Constants.gd` o un nuevo `NetworkCardData.gd`, para
no duplicarlo entre `RemotePlayerController.gd` y `SelectionManager.gd`).**

**Decisión de diseño pendiente, a confirmar con el usuario antes de escribir código real
acá:** ¿qué firma de retorno debe tener `_delegate_to_remote()` para que sirva a las 4
funciones distintas (una carta, N cartas, A/B, con/sin cancelar)? Probablemente necesite
una función por forma de retorno, no una sola genérica — auditar las 4 firmas reales
antes de escribir esto.

### Task 3.2: Convertir UN caso real como demostración

**Elegir una carta/patrón SIMPLE que el jugador remoto pueda controlar hoy** (p.ej. algo
que dispare durante Vigilia con un Aliado que el Remoto ya puede jugar — auditar el
catálogo real para encontrar el candidato más chico) y convertirla usando el puente de la
Task 3.1, de punta a punta, como plantilla documentada para las conversiones futuras.

**Verificación:** jugar esa carta puntual como Remoto y confirmar que el prompt llega, la
persona elige, y el efecto se resuelve igual que si lo hubiera hecho un humano local.

**Después de esta tarea:** dejar anotado en `arquitectura.md` (mismo estilo §10.14-10.16)
el criterio para convertir el resto, y que quedan ~100 sitios sin convertir — no
completar la Fase 3 entera en esta sesión.
