# Arquitectura — El Grimorio / MitosOnline

> Unifica dos fuentes: la auditoría técnica `docs/audit-2026-08-13.html` (snapshot del
> 2026-08-13/15, cuando el proyecto todavía vivía en `game/` dentro del repo Nuxt) y las
> notas de arquitectura verificadas en sesiones de trabajo posteriores, la más reciente
> el 2026-08-28. **Donde las dos fuentes contradicen, manda la más nueva** — el proyecto
> se movió mucho en esas dos semanas. Cada sección dice su fecha de verificación.

---

## 📑 Tabla de Contenidos

1. [Cómo está organizado hoy](#1-cómo-está-organizado-hoy-verificado-2026-08-28)
2. [El patrón de bug más repetido: `_main.<propiedad>` inexistente](#2-el-patrón-de-bug-más-repetido-de-esta-sesión-_mainpropiedad-inexistente)
3. [Sistemas de efectos de cartas](#3-sistemas-de-efectos-de-cartas-construidosextendidos-2026-08-28)
4. [Pantallas de mazos y Selector `boceto2.jpg`](#4-pantallas-de-mazos-y-selector-boceto2jpg)
5. [Estándares de UI, Paleta Visual y Razas/Arquetipos](#5-estándares-de-ui-paleta-visual-y-razasarquetipos)
6. [Infraestructura y Scripts de Test](#6-infraestructura-y-scripts-de-test)
7. [Workspace y estado del repositorio](#7-workspace--por-qué-la-raíz-del-repo-nuxt-tiene-todo-borrado)
8. [Auditoría histórica (2026-08-13/15) — resumen](#8-auditoría-histórica-2026-08-1315--resumen)
9. [Convenciones confirmadas al agregar cartas/efectos nuevos](#9-convenciones-confirmadas-al-agregar-cartasefectos-nuevos)

---

## 1. Cómo está organizado hoy (verificado 2026-08-28)

### Autoloads (orden real en `project.godot`)

```
GameSettings → Constants → GameState → CardDatabase → ExternalApiClient → VisualManager →
UIManager → GameManager → TurnManager → PriorityManager → BattleManager →
EffectController → TriggerSystem → CardEffectSystem → ActionModule → AnimationQueue →
CardFactory → ActionExecutor → CombatLog → UniversalCardParser →
ContinuousEffectManager → KeywordManager → DeckLoader → CardManager →
PaymentManager → ActionPipeline → DamageManager → SelectionManager
```

El orden de carga en `project.godot` es el único orden garantizado entre autoloads —
no asumir que uno ya está listo dentro del `_ready()` de otro si no está antes en esta
lista.

### Responsabilidades confirmadas

- **GameManager** — fuente de verdad de estado global (`is_game_active`,
  `active_player_id`, `current_phase`, `current_turn`). Cambios de fase externos van por
  `advance_to_phase()` (público) — nunca `_change_phase()` desde afuera.
- **TurnManager** — driver DAR-compliant: prioridad, oros, límite de mano. Se conecta en
  `Main._init_turn_manager()` solo para el Turno 1.
- **PriorityManager** — árbitro único del Paso D. Señal `both_players_passed` →
  `PhaseFlowController._on_priority_both_passed_main()`.
- **BattleManager** — daño de combate. Señales `damage_to_castle`, `player_defeated`,
  `combat_finished`. Se autoactiva al recibir `ASIGNACION_DANIO` vía `TurnManager`.
- **UIManager** — único escritor de `Label.text` en la UI de juego. `UIManager.setup({...})`
  se llama una vez en `Main._ready()`.
- **PaymentManager** — modificadores de coste (`cost_modifiers`,
  `calcular_coste_real(card)`). Se limpia solo al empezar cada turno vía
  `TurnManager.turn_started`.
- **GameState** — Oro Reserva/Pagado real por jugador (`agregar_oro_reserva`,
  `pagar_oro`, `get_oro_reserva`). Autoload — se accede `GameState.x`, nunca
  `_main._game_state` (ver §2).
- **GoldManager** (módulo de `Main`, no autoload) — único sistema real de "jugar carta"
  y pago de coste del jugador humano. Ver §3 para el sistema de Oro Virtual.
- **EffectController** (autoload) — dueño de `destroy_card()`/`exile_card()`, el único
  cuello de botella real de "una carta sale del juego" en todo el proyecto (todo camino
  de remoción — combate, `ActionModule.destroy()`, Anular — termina llamando acá,
  verificado 2026-08-28). Es también donde vive el sistema de Prevención (§3).
- **Main.gd** — orquestador puro de "cuándo". No escribe `.text` en Labels, no tiene
  lógica de daño, no tiene modificadores de coste — todo eso vive en los managers de
  arriba.

### Módulos de escena (hijos de `Main.gd`, instanciados en `_ready()`, NO autoloads)

`GameBootstrap`, `PhaseFlowController`, `ZoneManager`, `GoldManager`,
`CardInteractionModule`, `MulliganController`, `SceneSetupModule`, `GameHUDModule`,
`CardInspectionLayer` (+ `BernardoAbilityHandler`, `ResponseWindowHandler`),
`ZoneViewerModule`, `SelectionModule`.

### Flujo de inicio de partida

1. `GameBootstrap._load_cards()` → bundled (`res://data/cards.json`) → caché
   (`user://`) → API externa (rara vez llega acá, bundled/caché cubren ~5600 cartas).
2. `_show_deck_selector()` → `DeckSelector.gd` (overlay de selección de mazos, ver §4).
3. `_show_dice_roll()` → animación de dados.
4. `_prepare_game()` → mazos + setup de jugadores.
5. `_start_mulligan_phase()` → overlay de mulligan.
6. `_end_mulligan_phase()`:
   - `GameManager.start_game(dice_winner)` — solo fija estado, no arranca el turno.
   - `_init_turn_manager(dice_winner)` — conecta `TurnManager`, dispara
     `TurnManager.start_turn()`.
7. Turno 1: `TurnManager` detecta `is_first_turn=true`, salta AGRUPACIÓN, emite
   `phase_changed(VIGILIA)`.

### Máquina de fases (post-refactor)

- `PhaseFlowController._on_phase_state_machine()` es el único punto de entrada real,
  alimentado por señales de `GameManager` **y** de `TurnManager` (guard
  `_last_state_machine_phase` evita doble disparo si ambos emiten la misma fase).
- Turno 2+: `_do_fase_final()` → `GameManager.end_turn()` → `GameManager._start_turn()`
  → `_change_phase(AGRUPACIÓN)`. `TurnManager` queda "en pausa" con la ventana de
  prioridad del turno anterior todavía abierta.
- **Botón "Atacar"** (2026-08-28, reemplaza un diseño anterior donde declarar un
  atacante durante Vigilia terminaba la fase implícitamente): ahora hay una transición
  explícita Vigilia→Ataque vía este botón (`GameManager.proceed_to_battle()`) — declarar
  atacantes (con o sin Furia) solo es posible una vez que la fase YA es Ataque.
  `GameManager.skip_battle()` se eliminó (dead code) porque `confirm_attackers()` con la
  lista vacía ya manda directo a Fase Final.

---

## 2. El patrón de bug más repetido de esta sesión: `_main.<propiedad>` inexistente

**Verificado 2026-08-28 — patrón general, no un bug puntual.**

Muchos módulos "hijos" reciben `.setup(X)` de un padre `X` que **no es** el `Main.gd`
real (`res://scripts/core/game/Main.gd`), guardan `X` en una variable típicamente
llamada `_main`, y el código de adentro accede `_main.<algo>` asumiendo que `_main` ES
el Main real. Cuando `<algo>` no existe en la clase padre real, Godot tira en runtime:

```
Invalid access to property or key '<algo>' on a base object of type '<ClasePadre>'.
```

El fix casi siempre es reemplazar `_main.<algo>` por el **autoload global directo**
(`GameState`, `TriggerSystem`, `PriorityManager`, `GameManager`, `ActionModule`,
`CombatLog`, `ActionExecutor`, ...) en vez de intentar llegar a él a través de una
cadena de referencias que nunca existió.

### Instancias confirmadas y arregladas (2026-08-28)

| Archivo | `_main` real es... | Propiedad rota | Reemplazo |
|---|---|---|---|
| `GoldManager.gd`, `GameBootstrap.gd`, `SelectionModule.gd`, `LookAndPlayResolver.gd` | (variaba) | `_main._game_state` | autoload `GameState` |
| `StackStepResolver.gd` (hijo de `ActionPipeline.setup(self)`) | `ActionPipeline` | `_main._trigger_system` | autoload `TriggerSystem` |
| `StackStepResolver.gd` | `ActionPipeline` | `_main._priority_manager` | autoload `PriorityManager` |
| `StackStepResolver.gd` | `ActionPipeline` | `_main._game_manager` | autoload `GameManager` |
| `StackStepResolver.gd` | `ActionPipeline` | `_main._action_module` | autoload `ActionModule` |
| `StackStepResolver.gd` | `ActionPipeline` | `_main._combat_log` | autoload `CombatLog` |
| `PaymentValidation.gd` | `PaymentManager` | `_main._action_pipeline` | autoload `ActionPipeline` |
| `PaymentValidation.gd` | `PaymentManager` | `_main._game_manager` | autoload `GameManager` |
| `PaymentUI.gd` | `PaymentManager` | `_main._game_manager` | autoload `GameManager` |
| `ExhumarSystem.gd` | `PaymentManager` | `_main._action_executor` | autoload `ActionExecutor` |

### Pendiente / código huérfano relacionado (sin arreglar a propósito)

`TargetSelector.gd`, `LinkedEffectRegistry.gd` y `RegretSystem.gd` tienen el mismo bug
(`_main._action_pipeline`), pero **este clúster completo parece código muerto**:
`TargetSelector.gd` no se instancia con `.new()` en ningún lado, no está en ninguna
escena, y no es autoload. `StackVisualizer.tscn` tampoco está referenciado en
`Main.tscn`. Si se retoma este sistema, va a explotar con el mismo error — aplicar
esta misma tabla de reemplazos ahí primero.

También huérfano, cluster separado: **`SelectionCanvas.gd`** (`scripts/ui/selection/`)
+ `OpponentUI.gd` + su propio `SelectionReveal.gd`/`SelectionReorder.gd`/
`CardFilterValidator.gd`. Nunca se instancia (`SelectionCanvas.new()` no aparece en
ningún lado) — el sistema de selección real y activo es el autoload **`SelectionManager`**
(`scripts/core/effects/targeting/SelectionManager.gd`), que es completamente distinto
pese a nombres parecidos. No confundir los dos al buscar dónde vive la UI de "elegir
carta".

### Cómo evitarlo al agregar código nuevo

Antes de instanciar un submódulo o llamar `.setup(x)`, confirmar qué es realmente `x`
(¿el `Main.gd` real, o otro manager?) y que los accesos `_main.<propiedad>` de adentro
calcen con esa clase — no copiar/pegar un patrón `_main.<algo>` de otro módulo sin
verificar que esa propiedad exista ahí.

---

## 3. Sistemas de efectos de cartas (construidos/extendidos 2026-08-28)

### Oro Virtual — genérico y restringido (`GoldManager.gd`)

- `oros_virtuales: int` — genérico, paga cualquier costo (p.ej. Lobo Sagrado: "genera
  un Oro por el turno"). Expira al pasar de turno.
- `restricted_gold_pools: Array` — cada entrada `{amount, tokens, predicate, label}`;
  `predicate: func(card_type, card_race, card_cost) -> bool` decide si esa unidad
  aplica a la carta que se está pagando (p.ej. Padre de la Patria: "para jugar Armas o
  Aliados Caballero"; Legión Paladín: "Aliados o Armas de coste 2 o más"). Varias
  fuentes con predicados distintos coexisten sin mezclarse.
- Orden de pago en `pagar_coste()`: restringido que aplica → genérico → físico (el
  restringido se gasta primero porque si no se usa se pierde igual al pasar de turno).
- Tokens visuales en Reserva de Oro (`_spawn_gold_token`) — dorado para genérico, celeste
  para restringido, escala `Constants.GOLD_CARD_SCALE`.
- `PaymentManager.puede_jugar_carta()` delega en `GoldManager.puede_pagar()` (fix
  2026-08-28: antes leía `main.get("oros_virtuales")`, que siempre daba null/0 — el Oro
  Virtual nunca contaba para decidir si se podía *intentar* jugar una carta, aunque el
  cobro real después sí lo usaba bien).

### Prevención — DAR "Utilizar Habilidades: Prevenir" (`EffectController.gd`)

No existe el término "Escudo" en el DAR — es el mismo verbo que se usa para prevenir
daño (`DamageManager.add_damage_prevention`), aplicado acá a "salir del juego"
(`_leave_play_preventions: Dictionary`, cargas por jugador). Intercepta en
`destroy_card()`/`exile_card()`, el único choke point real. `add_leave_play_prevention()`
/ `_try_consume_leave_play_prevention()` (solo protege Aliados). `exile_card(...,
bypass_prevention: bool)` existe para que pagar tu propio costo de auto-Destierro nunca
quede bloqueado por tu propia Prevención activa.

### Convertir — DAR Sección 8 (`Card.gd` + `TargetedEffectExecutor.gd`)

`Card.is_converted` (ya existía, usado por Signo Amarillo) da el giro visual de 180° y
"vacía" la caja de texto — pero por sí solo es solo visual. Para que la carta *de
verdad* deje de disparar habilidades hace falta además
`KeywordManager.silence_card(target, source, "permanent")` (mismo mecanismo que usa
Bernardo O'Higgins). `_execute_targeted_convert()` combina ambos.

### Patrones de texto compuestos (ETB sin pasar por `extract_action()` de una sola acción)

- `LookAndPlayResolver.gd` — familia "mira/muestra N cartas del tope... elige qué
  hacer" (Signo Amarillo, Tangata Manu, Presente, Perder la Razón).
- `TargetedEffectExecutor.try_execute_draw_gold_search_pattern()` — "Roba N, genera un
  Oro restringido, sube hasta M del Cementerio a la mano" (Legión Paladín) — tres
  efectos encadenados SIN "puedes" (no opcionales), por eso no calzan en el sistema de
  una-sola-acción.
- Ambos se prueban en `TriggerResolution._resolve_look_and_play_patterns()` ANTES del
  `extract_action()` genérico, recibiendo el texto completo de la carta (no aislado a
  una oración).

### Sistema "Puedes" — confirmación eliminada para habilidades activadas (2026-08-28)

`ActionPipeline.activate_ability()` ya no pide un diálogo "¿Deseas activar esta
habilidad?" aparte — clickear el botón de la habilidad ya es la confirmación. Las
señales `puedes_confirm_requested`/`puedes_responded` y el diálogo modal en
`UIManager.gd` se eliminaron por completo (no quedaron deshabilitados, se sacaron). Los
TRIGGERS ("puedes" en "Cuando entra/ataca/...") nunca dependieron de esto — ofrecen su
propio "declinar" vía `can_cancel` en el `SelectionManager` que abren.

---

## 4. Pantallas de mazos y Selector `boceto2.jpg`

| | `DeckManager.gd` (+ `.tscn`) | `DeckSelector.gd` (sin `.tscn`, construida en código) |
|---|---|---|
| Dónde | Menú principal, pantalla "MIS MAZOS" | Overlay sobre el tablero, justo antes del sorteo de dados |
| Fuente de datos | `http://localhost:3000/api/mazos/publicos` (backend Nuxt local — **no corre**, código fuente borrado del disco) | `ExternalApiClient` (`/external/my-decks/`) + presets locales (`user://decks/preset-*.json`) + fallback bundled/`user://decks/` |
| Estado visual y flujo | Tarjetas grandes de mazo con portada, gradiente y stats | **Diseño `boceto2.jpg`**: Doble selección ("TU MAZO" y "MAZO RIVAL"), estética tomo de cuero repujado, badges de raza/arquetipo, botón esmeralda "COMENZAR PARTIDA" y secundario "Mazos aleatorios" |

### Fuentes de datos de mazos — mapa completo (verificado 2026-08-28)

- **`http://localhost:3000/...`** — API del backend Nuxt local. Repo del código fuente
  (`Divaxz/Grimorio_NUXT`) borrado del disco a propósito (ver §7) — este servidor no corre hoy.
- **API externa MyL** (`https://iterva.pythonanywhere.com/api`) — confirmada funcionando
  2026-08-28. Endpoints reales: `POST /external/token/`, `GET /external/my-decks/`
  (devuelve `{user, deck_count, decks[]}`), `GET /external/cards/<edicion>/`. `GET /external/all-decks/` **no existe** (404).
- **`res://data/decks/*.json`** (bundled) — vacío hoy.
- **`user://decks/*.json`** (mazos locales guardados) — presets oficiales uno-por-raza (`preset-*.json`) y mazos de usuario. Si los IDs numéricos no calzan con el catálogo cargado, `DeckLoader` cae a `load_random_deck()` de respaldo.
- **`DeckLoader.load_random_deck()`** — fallback robusto que sortea cartas válidas de `CardDatabase.get_all_cards()` si falla la resolución de un mazo.

---

## 5. Estándares de UI, Paleta Visual y Razas/Arquetipos

### Configuración de Pantalla (Godot 4)
- **Resolución base:** 1920 × 1080 (`viewport_width=1920`, `viewport_height=1080`).
- **Modo de estiramiento:** `canvas_items` con `aspect="expand"`.
- **Filtro de texturas:** Linear Mipmap (`default_texture_filter=2`), `msaa_2d=2`.

### Paleta de Colores Compartida
- **Dorado Base (`GOLD`):** `Color(0.83, 0.69, 0.22, 1.0)` (`#d4b038`) — bordes de paneles, detalles heráldicos.
- **Dorado Brillante (`GOLD_BRIGHT`):** `Color(1.0, 0.9, 0.5, 1.0)` (`#ffe680`) — hover y estados seleccionados.
- **Fondo Modal Oscuro:** `Color(0.06, 0.05, 0.09, 0.95)` (`#0f0d17`) — paneles contenedores translúcidos.
- **Botón Confirmar (Esmeralda):** `Color(0.12, 0.38, 0.20, 1.0)` (`#1f6133`) con borde dorado/esmeralda brillante.
- **Botón Secundario (Piedra/Pizarra):** `Color(0.18, 0.18, 0.22, 1.0)` (`#2e2e38`).

### Mapeo Canónico de Razas e Íconos
| Raza / Arquetipo | Color de Acento | Ícono / Badge |
|---|---|---|
| **Caballero** | `Color(0.85, 0.65, 0.25)` | 🛡️ `CABALLERO` |
| **Bestia** | `Color(0.65, 0.40, 0.20)` | 🐺 `BESTIA` |
| **Dragón** | `Color(0.80, 0.25, 0.20)` | 🐉 `DRAGÓN` |
| **Sombra / Undead** | `Color(0.45, 0.25, 0.65)` | 💀 `SOMBRA` |
| **Faerie / Mago** | `Color(0.25, 0.55, 0.85)` | 🔮 `FAERIE` / `MAGO` |
| **Sacerdote / Santo**| `Color(0.90, 0.85, 0.45)` | ✝️ `SACERDOTE` |
| **Eterno / Titán** | `Color(0.35, 0.65, 0.55)` | 🏛️ `ETERNO` |
| **Héroe / Defensor**| `Color(0.70, 0.50, 0.30)` | ⚔️ `HÉROE` |
| **Imp / Demonio** | `Color(0.75, 0.20, 0.30)` | 😈 `IMP` |

---

## 6. Infraestructura y Scripts de Test

Ubicados en `res://scripts/test/` y escena `res://scenes/test/TestScene.tscn`:

- **`TestScene.gd`** — Orquestador de pruebas aisladas sin necesidad de iniciar una partida completa.
- **`TestCardLoader.gd`** — Carga cartas específicas por ID o nombre directamente al campo/mano para verificar lógica.
- **`TestCardResolvers.gd`** — Dispara triggers y resuelve acciones simuladas.
- **`TestUIBuilder.gd`** — Monta interfaces y componentes HUD en entorno controlado de prueba.

---

## 7. Workspace — por qué la raíz del repo Nuxt tiene todo borrado

El working directory (`Elgrimorio/`) sigue siendo git-clon de `Divaxz/Grimorio_NUXT`
(app Nuxt), pero casi todos sus archivos (`app/`, `server/`, etc., ~557 archivos) se
borraron del disco **a propósito** — `git status` los muestra como deleted, pero nada
se commiteó ni se hizo `git restore`, así queda a propósito.

El proyecto activo real es `Elgrimorio/MitosOnline/` — un juego Godot 4.6 con **su
propio repo separado** (`github.com/tomaseduardom/MitosOnline`), sin relación con el
repo Nuxt (no es submódulo). `MitosOnline/mitos-online/` es una subcarpeta casi vacía
con un `project.godot` suelto — dejada sin revisar a propósito.

**No proponer** `git restore`/`checkout` para el repo Nuxt, ni comitear esas
eliminaciones, ni tocar `MitosOnline/mitos-online/` sin preguntar — las tres cosas
fueron diferidas explícitamente por el usuario.

---

## 8. Auditoría histórica (2026-08-13/15) — resumen

`docs/audit-2026-08-13.html` es una auditoría estática completa (60 scripts, ~30.000
líneas, sin ejecutar el proyecto en el editor) hecha cuando el juego todavía vivía en
`game/` dentro del repo Nuxt.

Diagnóstico central de esa auditoría:
1. **Turno 1 se jugaba distinto al resto** — *Resuelto* vía `PhaseFlowController._resolve_fase_final()` unificado.
2. **Jugar una carta no pasaba por el motor de habilidades** — *Resuelto parcial.*
3. **Tres sistemas de prioridad/pila compitiendo** — *Resuelto parcial* (`BattleManager` ahora lee `GameManager.attackers`).
4. **Robar/buscar/botar/descartar implementados 4 veces** — *Resuelto parcial* (`CardManager` como fallback real de `EffectController`).
5. **Atacar sin Furia** — *Resuelto.*

---

## 9. Convenciones confirmadas al agregar cartas/efectos nuevos

- Buscar primero si ya existe un patrón parecido (`_execute_targeted_*` en
  `TargetedEffectExecutor.gd`, `try_execute_*` en `LookAndPlayResolver.gd`) antes de
  inventar uno nuevo.
- Detección de texto por *substring*, no por nombre de carta — para que cubra
  reimpresiones con el mismo texto.
- Preferir el autoload/manager correcto en vez de una cadena `_main.algo` no verificada
  (ver §2).
- Cross-check de texto de carta: caché local (`card_cache/cards.json`) primero; si hay
  dudas, la API externa como segunda fuente.
