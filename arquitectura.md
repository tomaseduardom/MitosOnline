# Arquitectura — El Grimorio / MitosOnline

> Unifica dos fuentes: la auditoría técnica `docs/audit-2026-08-13.html` (snapshot del
> 2026-08-13/15, cuando el proyecto todavía vivía en `game/` dentro del repo Nuxt) y las
> notas de arquitectura verificadas en sesiones de trabajo posteriores, la más reciente
> el 2026-08-28. **Donde las dos fuentes contradicen, manda la más nueva** — el proyecto
> se movió mucho en esas dos semanas. Cada sección dice su fecha de verificación.

---

## 🏛️ Pilares (no negociables, para cualquiera que toque este proyecto)

- **No se puede programar en ningún idioma que no sea español neutro.** Código, comentarios,
  textos de UI, mensajes de commit, todo. Nada de voseo argentino ("vos", "podés", "tenés"),
  nada de "acá" (usar "aquí"), nada de "recién" en el sentido rioplatense de "no antes de
  ahora" (esa palabra en sentido normal de "hace poco" sí es neutra y está bien). Instrucción
  explícita y repetida del usuario (2026-09 en adelante) — no es una preferencia de estilo
  opcional, es una regla dura. Si encontrás código o texto que la viola (propio o de una
  sesión anterior), corregilo de paso, no lo dejes pasar.

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
10. [Bitácora de bugs recurrentes](#10-bitácora-de-bugs-recurrentes)

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
  de remoción — combate, `ActionModule.destroy()`, Anular — termina llamando aquí,
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
   (`user://`) → API externa (rara vez llega aquí, bundled/caché cubren ~5600 cartas).
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
| `ActionValidator.gd` (2026-09-11, bug real reportado por el usuario) | `ActionModule` (correcto — aquí no era el padre equivocado, sino un método que en realidad vive en un submódulo HERMANO) | `_main._get_searchable_zone_data()` — esa función está definida en `ActionSearch.gd`, no en `ActionModule.gd` | `_main._action_search._get_searchable_zone_data()` (submódulo real, guardado en `ActionModule._action_search`) |

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
- Tokens visuales en Reserva de Oro (`_spawn_gold_token`) — cartas de ficha temáticas dedicadas con marco rúnico e ilustración según restricción (`res://assets/ui/tokens/`), escala `Constants.GOLD_CARD_SCALE` con animación de disolución y elevación mágica al consumirse o expirar.
- `PaymentManager.puede_jugar_carta()` delega en `GoldManager.puede_pagar()` (fix
  2026-08-28: antes leía `main.get("oros_virtuales")`, que siempre daba null/0 — el Oro
  Virtual nunca contaba para decidir si se podía *intentar* jugar una carta, aunque el
  cobro real después sí lo usaba bien).

### Prevención — DAR "Utilizar Habilidades: Prevenir" (`EffectController.gd`)

No existe el término "Escudo" en el DAR — es el mismo verbo que se usa para prevenir
daño (`DamageManager.add_damage_prevention`), aplicado aquí a "salir del juego"
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

El working directory (`NosTaw/`, renombrado desde `Elgrimorio/` — 2026-09-11) sigue
siendo git-clon de `Divaxz/Grimorio_NUXT` (app Nuxt), pero casi todos sus archivos
(`app/`, `server/`, etc., ~557 archivos) se borraron del disco **a propósito** —
`git status` los muestra como deleted, pero nada se commiteó ni se hizo `git restore`,
así queda a propósito.

El proyecto activo real es `NosTaw/MitosOnline/` — un juego Godot 4.6 con **su
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
- **"Convertir [carta] en una carta del mismo tipo sin habilidad"** (Capitán O'Brien, DAR
  Sección 8, y todo el resto de cartas que reusan ese patrón — Séptimo Sello, Biblioteca de
  Caballería, "Los Olvidados", etc.): SIEMPRE marcar `target.is_converted = true` además de
  `KeywordManager.silence_card(target, source_card, "permanent")` — `is_converted` es lo que
  dispara el giro visual de 180° sobre el centro de la carta y vacía su caja de texto (ver
  §1, línea ~202); `silence_card()` por sí solo solo apaga las habilidades, no cambia nada
  visual. Recordatorio explícito del usuario (2026-09-20) — verificado en esta sesión que
  Séptimo Sello, Biblioteca de Caballería y "Los Olvidados" ya lo hacían bien; aplica igual
  a cualquier implementación FUTURA del mismo patrón (p.ej. Rito de Pontchartrain, Pacto
  Sangriento, y el resto de Talismanes/Oros todavía sin implementar que usan este texto).

---

## 10. Bitácora de bugs recurrentes

> Objetivo de esta sección: cuando una sesión encuentra y arregla una clase de bug (no
> un typo puntual, sino un PATRÓN que se puede repetir en código nuevo), se anota aquí
> con su fix y su "cómo evitarlo" — para no volver a redescubrirlo desde cero en la
> próxima sesión. Ver también §2 (`_main.<propiedad>` inexistente), que sigue el mismo
> formato y fue la primera bitácora de este tipo.

### 10.1 Efectos de trigger que asumen jugador 0 (`controller_id` ignorado)

**Verificado 2026-09-11.**

Muchas funciones `try_execute_*_pattern(ability_text, controller_id, card)` en
`scripts/core/effects/triggers/` reciben `controller_id` porque la carta que dispara el
trigger puede ser de CUALQUIER jugador (el rival también puede jugar Aliados/Talismanes
con estas habilidades) — pero como en la práctica casi todas se probaron jugándolas el
humano, es fácil escribir la función usando directo los contenedores del humano
(`main.player_hand`, `main.player_field`, `main.player_gold`, etc.) sin condicionar por
`controller_id`. Compila y funciona bien mientras solo el humano juegue esas cartas; si
el RIVAL la juega, el efecto (Oro generado, carta buscada, carta robada a mano, etc.)
aparece del lado equivocado — un bug de "le robás el efecto a tu propio rival", no un
crash, así que puede pasar desapercibido varias partidas.

| Archivo | Función | Bug | Fix |
|---|---|---|---|
| `DSR_SearchGoldCombos.gd` | `try_execute_draw_gold_search_pattern()` (Legión Paladín) | Generaba el Oro Virtual restringido con `main._gold_manager.generar_oro_virtual_restringido()` sin chequear `controller_id` — esa función de `GoldManager` no tiene parámetro de jugador, siempre escribe en la Reserva del jugador 0. Si el rival jugaba Legión Paladín, el Oro aparecía en la Reserva del humano. | Guard `controller_id == 0` agregado antes de generar el Oro (mismo criterio que ya usa la función hermana de Levisterio en el mismo archivo, y el propio `search_amount` unas líneas más abajo en la misma función). |

**Cómo evitarlo al escribir un patrón nuevo:**
- Si la función recibe `controller_id`, toda referencia a un contenedor de jugador va
  por el ternario `main.player_X if controller_id == 0 else main.opponent_X` (campos,
  Oro) o `main.player_hand if controller_id == 0 else main._opponent_fan` (mano) —
  nunca escribir directo a `main.player_*` en una función que puede recibir
  `controller_id == 1`.
- Si la habilidad todavía no tiene sentido para el bot (necesita elegir de su propia
  mano, que no está modelada carta por carta), cortar temprano con el guard ya
  establecido: `if controller_id != 0: return true  # el bot no usa esta habilidad
  todavía` — ver casi cualquier función de `GoldConversionPatterns.gd`/
  `BanishOpponentPatterns.gd`. Preferir este guard total antes que un guard parcial que
  deja alguna línea sin condicionar.
- No asumir "total el bot no juega esa carta todavía" como excusa para omitir el guard
  — el catálogo de jugadas del bot puede crecer (`EasyBotController` hoy solo pone Oro y
  juega Aliados; podría sumar más adelante), así que un guard faltante hoy es un bug
  latente esperando a que cambie el alcance de la IA, no un problema teórico.

**Barrido 2026-09-11 (completado):** revisado función por función el resto de
`scripts/core/effects/triggers/*.gd` (BanishOpponentPatterns.gd, DSR_CemeteryBanishDraw.gd,
DSR_DiscardChoicePatterns.gd, DSR_SearchGoldCombos.gd, PlayFromCemeteryPatterns.gd,
MiscUniquePatterns.gd, MiscTargetedPatterns.gd, WeaponSearchShuffleExecutor.gd, y
muestreo del resto). **Ningún bug nuevo confirmado** — el guard `if controller_id != 0:
return ...` inmediatamente después del match de texto está aplicado de forma consistente
en todas las funciones `try_execute_*_pattern` revisadas.

Dos puntos de bajo riesgo, sin explotar hoy pero frágiles si el alcance del bot crece
("verificar alcance", no "confirmado"):
- `MiscTargetedPatterns.gd` — `_resolve_search_cemetery_to_hand()` (líneas ~22-55): saca
  la carta del Cementerio de `controller_id` incondicionalmente pero solo la agrega a la
  mano si `controller_id == 0` — con `controller_id == 1` la carta del bot desaparecería
  sin destino. Hoy inofensivo porque su único llamador (`DSR_SearchGoldCombos.gd:151-152`)
  ya filtra `controller_id == 0` antes de invocarla. Si algún día se llama para el bot,
  el destino correcto es `main._opponent_fan.add_card(...)` — API distinta a
  `HandManager.add_card()` (`OpponentFan.gd` no tiene `.cards`, tiene `.get_cards()`).
- `EffectController.gd` — `_pay_akari_shuffle_cost()` (líneas ~703-743): siempre lee/
  escribe `main.player_hand`/`main.player_field` sin condicionar por el dueño real de
  Akari. Compartida entre `offer_counter_annul()` (ese caller sí garantiza jugador 0,
  líneas 758-760) y una entrada del registro de Prevención en teoría alcanzable vía
  `offer_prevention_for_player(1, ...)` — no confirmado que el bot pueda llegar a ese
  camino hoy. Si se confirma alcanzable, condicionar por `owner_id`/
  `source_card.controller_id` igual que ya hace `offer_prevention_for_player()` (mismo
  archivo, líneas ~814-817, con el ternario correcto de referencia).

### 10.2 Números mágicos de enum que no coinciden con lo que dice el comentario

**Verificado 2026-09-11.** `StackStepResolver.gd:244` abría la ventana de Paso D con
`PriorityManager.start_priority_window(1, opponent_id)  # RESPONSE_WINDOW = 1` — pero el
enum real (`PriorityManager.gd:43-49`) es `NONE=0, GUERRA_TALISMANES=1, RESPONSE_WINDOW=2,
DISCARD_PHASE=3, BLOCK_DECLARATION=4`. El `1` correspondía a `GUERRA_TALISMANES`, no a
`RESPONSE_WINDOW` — el comentario estaba mal desde el principio (o el enum se reordenó
después y el comentario nunca se actualizó). Síntomas: la consola mostraba "Guerra de
Talismanes" para una ventana que no tenía nada que ver con esa fase (bug real reportado
por el usuario), y — más importante — el auto-pase "no hay nada que decidir" del humano
(§10.1 emparentado, `PhaseFlowController._on_priority_changed_glow()`) está a propósito
restringido a `RESPONSE_WINDOW` real para no auto-pasar una Guerra de Talismanes genuina,
así que nunca se activaba para esta ventana. Sin impacto en quién tiene prioridad primero
(aquí siempre se pasa `starting_player` explícito, sin pasar por
`_get_starting_priority_player()`) ni en `valid_actions`/`is_action_valid()` (confirmado
sin ningún llamador real en todo el proyecto — dead code de solo lectura).

**Fix:** reemplazado el número mágico por `PriorityManager.PriorityContext.RESPONSE_WINDOW`.

**Cómo evitarlo:** nunca pasar un literal numérico donde el parámetro espera un valor de
enum, aunque el comentario al lado diga "= N" — ese comentario es exactamente el tipo de
dato que se desincroniza en silencio si el enum cambia de orden más adelante. Usar
siempre `Enum.VALOR` explícito; si aparece un literal numérico en una llamada a
`start_priority_window()` (o cualquier función que tome un `PriorityContext`), es señal
de alerta para verificar contra la declaración real del enum antes de confiar en el
comentario.

### 10.3 Decisión de reglas confirmada: Monitor Araucano (Oro generado cuenta para la MISMA compra)

**2026-09-11, a pedido del usuario.** Texto real (verificado contra `cards.json`,
id `20392`): *"Este Oro genera un Oro adicional cuando sea usado para pagar Armas de
coste 2 o más."* Ambigüedad de timing: ¿el Oro Virtual generado es un recurso aparte
para más adelante en el turno (como TODOS los demás "genera un Oro para jugar X" del
motor — Padre de la Patria, Almirante Akari, Legión Paladín), o cuenta para pagar la
MISMA Arma que lo disparó?

**Decisión del usuario:** la frase "cuando sea usado para pagar" implica que el Oro
generado se aplica a esa misma compra — si Monitor Araucano paga un Arma de coste 2, el
segundo Oro de esa compra lo pone él mismo (no hace falta gastar otro Oro de Reserva).
Esto es una EXCEPCIÓN deliberada al patrón general "generar Oro = recurso aparte para
después" que usan las demás cartas — no aplicar este mismo razonamiento a otras cartas
sin volver a confirmar con el usuario primero.

**Implementación:** `GoldManager.pagar_coste()` pagaba TODO el Oro físico necesario de
una sola vez (`_choose_physical_gold_to_spend(oros_reserva, restante)` con el `restante`
completo, calculado ANTES de que ninguna reacción pudiera dispararse). Se cambió a un
bucle que gasta un Oro físico A LA VEZ, revisando `oros_virtuales` antes de cada unidad
— así el Oro que `_resolve_gold_paid_reaction()` genera a mitad de pago se consume antes
de sacar más Oro físico de la Reserva, en vez de quedar como sobrante sin tocar para esa
compra. `GameState.pagar_oro()` ahora recibe `physical_spent` (cuántas cartas físicas se
movieron de verdad), no el `restante` original pre-bucle, para no descontar de la
Reserva de más.

### 10.4 Bug grave: lambdas de GDScript capturan variables locales POR VALOR

**Verificado 2026-09-12 — bug real reportado por el usuario, "todas las cartas que
juego se demoran 5-6 segundos", confirmado con instrumentación en vivo: cada carta con
habilidad de entrada tardaba consistentemente ~8 segundos, siempre, sin excepción.**

Causa raíz: `ActionPipeline.add_triggered_ability_to_stack_and_await()` (agregada
2026-09-09 para la Pila de Respuesta Universal, con una salvaguarda de timeout agregada
2026-09-11 para otro bug distinto) esperaba así:

```gdscript
var done: bool = false
var on_resolved := func(obj, _result):
    if obj.get("id", -1) == stack_id:
        done = true   # ← esto NO modifica el "done" de afuera
stack_object_resolved.connect(on_resolved)
while not done and waited < 8.0:
    await get_tree().process_frame
    ...
```

**Las funciones lambda de GDScript capturan las variables locales de la función
envolvente POR VALOR, no por referencia.** Asignar `done = true` dentro del closure
reasigna la copia local *del closure*, nunca la variable `done` de la función de
afuera — así que el `while not done` nunca se enteraba de que el objeto ya había
resuelto (confirmado con diagnóstico en vivo: la señal `stack_object_resolved` SÍ
llegaba, con el `id` correcto, milisegundos después de abrir la ventana — el bucle
simplemente nunca se entera) y esperaba siempre el timeout completo de 8 segundos,
en TODA carta que pasara por esta función (prácticamente cualquier Aliado/Arma/Oro/
Tótem con "Cuando entra en juego", vía `TriggerSystem.open_response_window()`).

Los **Diccionarios y Arrays sí se comparten por referencia** al capturarse en un
closure — por eso `outcome.resolved = true` (mutar un campo del Dictionary) ya
funcionaba bien; solo el `bool` suelto estaba roto.

**Fix:** `done` pasa a vivir como campo del mismo Dictionary `outcome` que ya se
comparte correctamente (`outcome.done`), en vez de una variable `bool` aparte.

**Cómo evitarlo:** nunca usar una variable local primitiva (`bool`/`int`/`float`/
`String`) como flag de "terminé" dentro de un closure que un bucle de afuera necesita
leer — GDScript no la comparte. Usar en cambio un campo de un Dictionary/Array ya
existente en ese scope, o si no hay ninguno a mano, envolver el flag en un Array de un
solo elemento (`var done := [false]`, `done[0] = true`) — el patrón estándar para este
gotcha. Sospechar de esto específicamente cada vez que un `while`/`await` con timeout
nunca sale antes de su límite máximo aunque la condición de éxito claramente haya
ocurrido (visible en los logs) — es la firma exacta de este bug.

### 10.5 Filtros de objetivo que comparaban `get_parent()` en vez de `current_zone`

**Verificado 2026-09-12 — bug real reportado por el usuario en al menos dos cartas
distintas (Espada Vikinga, Espada de O'Higgins): "Objetivo no válido" al clickear una
carta del rival que a simple vista cumplía el filtro (coste, tipo, etc.), repetido en
varios intentos seguidos.**

Patrón encontrado en **10 archivos, ~24 ocurrencias**: los filtros de `await_target()`
para elegir un objetivo en el tablero comparaban el nodo Godot padre real de la carta
contra una lista de contenedores (`var parent = c.get_parent(); ... parent in
[main.player_field, main.opponent_field, ...]`), en vez de usar `current_zone` — la
propiedad que el motor ya trackea específicamente para esto (ver
`_select_convert_target()`, que sí lo hacía bien desde el principio). El caso más obvio
donde esto se rompe: un **Arma equipada** es hija de su portador (otra carta), nunca
directamente de `player_field`/`opponent_field` — así que cualquier filtro de este tipo
la rechazaba siempre, sin importar que estuviera legítimamente "en juego" según
`current_zone`. Cartas normales (Aliados sin equipo) podían fallar igual si su jerarquía
de nodos no calzaba 1:1 con la zona por cualquier otra razón de layout.

**Archivos con al menos una ocurrencia arreglada:** `BanishOpponentPatterns.gd` (6),
`MiscUniquePatterns.gd` (2), `TargetedEffectExecutor.gd` (5), `GoldConversionPatterns.gd`
(1), `ShuffleDrawPatterns.gd` (6), `SearchAbilityHandler_JV.gd` (2),
`SearchAbilityHandler_AI.gd` (2), `PreventionAbilityHandler_PV.gd` (4),
`PreventionAbilityHandler_EP.gd` (4), `PreventionAbilityHandler_AE.gd` (4).

**Fix:** todas convertidas a `c.get("current_zone") in [Constants.Zone.LINEA_DEFENSA,
Constants.Zone.LINEA_ATAQUE, Constants.Zone.LINEA_APOYO, ...]` (agregando
`RESERVA_ORO`/`ORO_PAGADO` a la lista solo donde el filtro original también incluía los
contenedores de Oro). Una única excepción legítima quedó sin tocar:
`ShuffleDrawPatterns.gd:259`, que usa `get_parent()` para de verdad reparentar el nodo
(operación real de árbol de escena, no un chequeo de zona lógica).

**Cómo evitarlo al escribir un filtro nuevo:** para "¿esta carta está en tal zona de
juego?", siempre `c.get("current_zone") in [Constants.Zone...]` — nunca comparar contra
el nodo padre real salvo que el propósito explícito sea manipular el árbol de escena
(reparentar, `add_child`/`remove_child`). `current_zone` es la fuente de verdad lógica;
la jerarquía real de nodos es un detalle de implementación visual que puede no
corresponderse 1:1 (Armas equipadas, cartas con `top_level=true`, etc.).

### 10.14 Proyecto en curso: reemplazar modales de "elegir N cartas" por click directo con brillo

**2026-09-13, a pedido del usuario:** quiere eliminar los modales de lista para
habilidades que piden elegir 2-3 cartas (mostrar Armas para Rey y el Verdugo, elegir de
qué Cementerio para Espada de O'Higgins/Hanta el Samurai, etc.) y reemplazarlos por click
directo sobre las cartas reales con brillo celeste de "elegible" — el mismo mecanismo que
ya se sentía natural en otras interacciones de esta sesión (Bloqueo click-a-click,
selección de qué Oro físico gastar). Pidió extender esto "a todas las habilidades que
pidan 2 o 3 opciones" — alcance grande, se está haciendo de forma incremental.

**Infraestructura nueva agregada esta sesión (reutilizable para cualquier carta futura):**

- `CardInteractionModule.await_multi_target(prompt_prefix, candidates, max_count, lock_group_key)`
  — generaliza `await_target()` a 0..N objetivos: brillo celeste en todos los candidatos,
  clicks repetidos (cada uno saca esa carta del pool y apaga su brillo), ESC en cualquier
  punto TERMINA con lo ya elegido (no cancela todo). `lock_group_key` opcional: tras el
  primer pick, restringe el resto a candidatos con el mismo key (p.ej. mismo dueño) —
  para habilidades tipo "de UN Cementerio" (no un pool combinado). Extraído del mismo
  patrón que ya usaba `GoldManager._choose_physical_gold_to_spend()`.
- `ZoneViewerModule.open_cemetery_target_picker(prompt, filter, max_count, zone_type, lock_to_one_side)`
  — popup NUEVO que muestra AMBOS Cementerios (o Destierros) lado a lado con cartas
  reales instanciadas ahí mismo (`_create_selectable_popup_card()`, `can_interact=true`,
  conectadas vía `_main._connect_card_signals()` para que el mecanismo genérico de
  `is_selecting_target` funcione igual que en cualquier otra carta del campo/mano). Estas
  cartas son Nodos TEMPORALES que solo existen mientras el popup está abierto — el
  `card_data` de cada una es la fuente de verdad real, no el Node. Reemplaza el patrón
  viejo "modal preguntando de cuál Cementerio → modal con lista de esa zona".

**Convertidas a este mecanismo:**
- Espada de O'Higgins, "Destierra hasta N cartas de los Cementerios y Roba M cartas"
  (`DSR_CemeteryBanishDraw.gd::try_execute_banish_up_to_n_cemeteries_then_draw_pattern`) —
  pool combinado de ambos Cementerios, sin lock.
- Hanta el Samurai, "Destierra hasta tantas cartas de un Cementerio como Armas controles"
  (`DSR_CemeteryBanishDraw.gd::try_execute_weapon_count_banish_cemetery_pattern`) — mismo
  picker con `lock_to_one_side=true` (el texto real dice "UN Cementerio", singular — tras
  el primer click al Cementerio propio o rival, el otro deja de ser elegible).

**NO convertidas todavía (alcance grande, pendiente):**
- El Rey y el Verdugo / Shiji, "Reduce su coste... por cada X que muestres de tu mano,
  Cementerio o que controles" (`GoldManagerTax.gd::_resolve_reveal_cost_reduction()`) —
  sigue con el modal viejo de "¿desde dónde mostrar?" + lista. Mano/en juego ya podrían
  usar `await_multi_target()` directo (tienen Nodos persistentes); el Cementerio
  necesitaría `open_cemetery_target_picker()` — combinar ambos caminos en una sola
  selección sin preguntar zona es la parte que falta diseñar (hoy `await_multi_target()`
  y `open_cemetery_target_picker()` son dos llamadas separadas, no una unificada).
- Cualquier otra habilidad del proyecto que hoy use `SelectionManager.await_multi_pick()`/
  `await_single_pick()`/`await_two_choice()` para elegir objetivos EN JUEGO/MANO/
  CEMENTERIO (docenas de casos — Campanita, Tamales, Armería del Guerrero, Colmillo de
  Vampiro, Sandraudiga, etc.) — no se auditaron ni convirtieron todas; se hizo la
  infraestructura reutilizable + 2 casos concretos como demostración. Seguir
  incrementalmente cuando el usuario lo pida para una carta puntual, o pedir confirmación
  antes de un barrido masivo (cambia la sensación de MUCHAS cartas a la vez, alto riesgo
  si algo queda mal calibrado).

**Nota de diseño importante:** `SelectionManager.await_multi_pick()`/`await_single_pick()`
NO quedan obsoletos — siguen siendo la herramienta correcta para elegir entre opciones que
NO son cartas en una zona visible (p.ej. elegir un NOMBRE de carta para Tesoro de los
Césares, o una opción de texto libre). El reemplazo aplica específicamente a "elegir 1+
cartas de una zona jugable" — ahí es donde clickear la carta real es más natural que
leerla en una lista. `await_two_choice()` (elegir entre DOS EFECTOS distintos, no dos
cartas — p.ej. "Barajar o Cancelar") tampoco es candidato a reemplazo por sí solo; solo el
`await_single_pick()`/`await_multi_pick()` que sigue a esa elección (para elegir CUÁL
carta dentro del efecto elegido) sí lo es.

### 10.15 Caso La Ouija: elegir entre una carta visible y el tope/fondo de un Castillo (zona oculta)

**2026-09-13, pregunta del usuario:** ¿cómo se resuelve con click directo una habilidad
que ofrece elegir entre una carta de una zona visible (mano/Cementerio) y "el tope/fondo
de un Castillo" — una posición del mazo, no una carta identificable de antemano en la
mayoría de los casos?

**Dos sub-casos con solución distinta:**

1. **La carta del Castillo se REVELA como parte de la elección** (p.ej. La Ouija: "Juega
   mostrando la primera carta de tu Castillo" — se sabe cuál es antes de comprometerse).
   Solución implementada: se arma UN solo popup con las cartas reales de la zona visible
   MÁS una carta temporal extra construida con `deck[0]` (revelada), y se resuelve todo
   con UN `await_multi_target()` sobre el conjunto combinado — sin correr dos mecanismos
   de selección en paralelo. Convertido: `HandCementerioAbilityHandler.
   _activate_ouija_play_from_cemetery_or_deck_top()`.
2. **No hay nada que revelar/mostrar de antemano** (p.ej. Sherlock Holmes: "convierte
   cartas en juego O del tope de UN Castillo" — cualquiera de los dos Castillos, a
   ciegas). Solución YA EXISTENTE antes de esta sesión, ahora extraída a un helper
   reutilizable: `CardInteractionModule.await_target_or_castillo_pick(prompt, filter,
   castillo_title, allow_cancel, castillo_own_only)` — el Panel del Castillo entero
   (propio y/o rival) se vuelve clickeable EN CARRERA contra la selección normal de
   carta (`SelectionManager.start_castillo_pick()` vs.
   `CardInteractionModule.start_target_selection()`, el primer click real gana). Antes
   este mecanismo vivía escrito a mano solo dentro de
   `ConvertAndMiscResolver.try_execute_mill_convert_to_ally_pattern()`; ahora es
   reutilizable para cualquier carta nueva con este patrón. `castillo_own_only=true`
   cubre el caso "de TU Castillo" (con posesivo, ignora clicks al Castillo rival en vez
   de resolver la carrera con un lado inválido).

**Regla general para el próximo caso similar:** ¿se conoce la carta de antemano (se
revela)? → un solo popup/`await_multi_target()` combinado. ¿No se conoce hasta elegir
esa fuente? → `await_target_or_castillo_pick()`.

### 10.16 Alcance real de la auditoría pedida: ~100+ sitios en ~25 archivos

**2026-09-13, a pedido del usuario:** "auditemos todas las cartas... vamos
desarrollándolas" — se hizo un relevamiento real (grep de
`SelectionManager.await_single_pick/await_multi_pick/await_two_choice/await_choice` fuera
de `SelectionManager.gd`/`SelectionDialogs.gd`): **más de 100 sitios en unos 25 archivos**
(`BanishOpponentPatterns.gd`, `ShuffleDrawPatterns.gd`, `SearchAbilityHandler_*.gd`,
`PreventionAbilityHandler_*.gd`, `LookRevealPatterns*.gd`, `SearchOwnZonePatterns.gd`,
`DSR_*.gd`, `GoldManager.gd`, etc.). Convertir TODO esto de una sola vez sería un cambio
masivo y de alto riesgo (calibrar mal un solo caso es fácil de notar solo jugando esa
carta puntual). **Distinción importante antes de tocar cualquiera:** `await_two_choice()`
en sí mismo casi siempre elige entre dos EFECTOS distintos (p.ej. "Barajar o Cancelar"),
no candidato a este reemplazo — solo el `await_single_pick()`/`await_multi_pick()` que
frecuentemente sigue DESPUÉS de esa elección (para decidir CUÁL carta dentro del efecto
ya elegido) sí lo es.

**Cómo se está abordando (a pedido del usuario, incremental):** convertir de a una,
según vayan apareciendo en partidas reales o el usuario las pida puntualmente — no un
barrido masivo sin supervisión. Convertidas hasta ahora: Espada de O'Higgins (§10.14),
Hanta el Samurai (§10.14), La Ouija (§10.15), El Rey y el Verdugo/Shiji (§10.17). Antes de
convertir la siguiente, revisar primero si encaja en alguno de los patrones ya
construidos (`await_multi_target()` para mano/campo, `open_cemetery_target_picker()` para
Cementerio/Destierro con o sin `lock_to_one_side`, `await_target_or_castillo_pick()` para
Castillo-a-ciegas, o el popup combinado ad-hoc de La Ouija para Castillo-revelado) antes
de escribir uno nuevo.

### 10.17 El Rey y el Verdugo / Shiji: 3 zonas combinadas con lock por click, sin preguntar antes

**2026-09-13, elegida por Claude a pedido del usuario ("andá eligiendo").** Texto real:
"Reduce su coste en un Oro por cada Arma que muestres de tu mano, Cementerio o que
controles, hasta un mínimo de 0" (El Rey y el Verdugo) / "...si muestras un Arma o Tótem
de tu mano o Cementerio" (Shiji, sin "que controles" — tope duro de 1, no escala). Era el
caso pendiente de §10.14: mezcla una zona con Nodos ya visibles en pantalla (mano, en
juego) con una que necesita Nodos temporales (Cementerio).

**Solución:** en vez de abrir un popup grande que tape mano/campo, se armó UN combinado:
`GoldManagerTax._gather_showable_candidate_nodes()` reúne los Nodos REALES de mano/en
juego (ya son clickeables donde están, sin popup), y `_open_cemetery_reveal_popup()` abre
un panel CHICO sin oscurecer el resto de la pantalla (esquina inferior izquierda, sin
`ColorRect` de fondo) con Nodos temporales del Cementerio propio. Los candidatos de las
tres fuentes se unen en un solo Array y se resuelven con UN `await_multi_target()`.

**El "elegí UNA zona, no combines" (2026-08-31) se preserva con `lock_group_key`** en vez
de con una pregunta previa: la key es la zona lógica de cada candidato
(`current_zone` — MANO/CEMENTERIO/en juego). El primer click define la zona; el resto de
esa selección queda restringido a la misma, igual que el patrón ya usado para Hanta el
Samurai (mismo Cementerio) pero aquí con 3 zonas en vez de 2 Cementerios.

**No se tocó `_get_reveal_cost_reduction_pattern()`** (la detección de texto/tipos/zonas
sigue igual) — solo cambió CÓMO se recolectan y presentan los candidatos, no qué cuenta
como candidato. Verificado contra `cards.json`: el texto real de ambas cartas (`custom_
mig_12`/`18196` Shiji, `20275` El Rey y el Verdugo) coincide exactamente con lo que el
detector espera.

### 10.18 Campanita: combo `await_two_choice()` (efecto A/B) + selección de carta por rama

**2026-09-13, a pedido del usuario ("seguí con esa combinación").** Campanita: "Puedes
Barajar hasta cuatro cartas de los Cementerios o subir un Aliado o Tótem de tu Cementerio
a tu mano" — primer ejemplo convertido de una habilidad con DOS efectos distintos a
elegir (`await_two_choice()`, SIN tocar — sigue siendo el modal de 2 botones, ver
§10.16), donde CADA rama necesita su propia selección de carta después.

- Rama "Barajar" — pool combinado de ambos Cementerios, sin lock (mismo caso que Espada
  de O'Higgins): `open_cemetery_target_picker(prompt, no_filter, 4)`.
- Rama "Subir" — "de TU Cementerio" (posesivo, solo propio) + filtrado por tipo (Aliado o
  Tótem): `open_cemetery_target_picker(prompt, eligible_filter, 1)` con un filtro que
  rechaza tanto el lado rival como los tipos no elegibles — esas cartas quedan visibles en
  el popup pero sin brillo, no clickeables.

**Patrón para el próximo caso similar con `await_two_choice()` + selección:** la elección
A/B en sí NO se toca (son efectos distintos); solo el picker de cartas que sigue a cada
rama se convierte, y cada rama puede necesitar un `filter`/`max_count`/`lock` distinto —
no hay que compartir configuración entre ramas solo porque vienen de la misma carta.

### 10.19 akuma el terrible + Belta: mismo combo, y "costo todo o nada" con la nueva selección

**2026-09-13, elegidas por Claude ("seguí con esa combinación").**

- **akuma el terrible** — "Una vez por turno, puedes Desterrar hasta dos cartas de los
  Cementerios o Robar una carta": mismo combo que Campanita (§10.18), pero más simple —
  solo la rama "Desterrar" necesita picker (pool combinado, sin lock, igual que Espada de
  O'Higgins). La rama "Robar" no elige cartas.
- **Belta** (`_activate_belta_self_banish_revive`) — "Puedes Desterrar dos cartas de tu
  Cementerio para ponerlo en juego..." — sin `await_two_choice` esta vez (es un costo
  directo, no una elección A/B), pero interesante por otra razón: es un costo TODO O NADA
  de exactamente 2 cartas (`min_selections=2` en el modal viejo). Con el picker nuevo esto
  se resuelve gratis: `open_cemetery_target_picker()` no muta nada por sí solo (solo
  devuelve qué se clickeó), así que si el jugador cancela antes de elegir las 2, el
  chequeo `if picked.size() < 2: return` aborta sin que ninguna carta se haya movido —
  no hace falta que el picker en sí soporte "mínimo obligatorio". Filtro: `c.owner_id ==
  owner_id and c.card_data != source_card.card_data` (Cementerio propio, excluyendo a la
  propia Belta).

**Lección para costos "todo o nada" (exactamente N, no "hasta N"):** no hace falta ninguna
opción especial en el picker — el patrón es siempre "pedir hasta N, y si `picked.size() <
N` después, abortar sin aplicar ningún efecto" — el picker es puramente de UI, la
mutación de estado siempre pasa DESPUÉS y bajo control del caller.

No se encontró un bug de lógica/conectividad nuevo en esta pasada (se revisó el resto de
`PreventionAbilityHandler_AE.gd` alrededor de estas dos funciones sin encontrar nada
adicional que arreglar).

### 10.20 Tempilcahue: presupuesto de coste que se hace cumplir EN VIVO, no al final

**2026-09-13, elegida por Claude.** Segunda rama de Tempilcahue: "Paga dos Oros: Baraja
cartas cuyos costes sumen hasta 4 (en juego, cualquier lado) y Roba dos cartas". El modal
viejo (`WeaponSearchShuffleExecutor._select_cards_by_cost_budget()`, vía `SelectionManager.
open_selection()`) dejaba elegir CUALQUIER cantidad y solo al confirmar validaba la
suma — si te pasabas de 4, se descartaba TODA la selección y había que repetirla desde
cero.

**Se agregó `dynamic_filter` a `CardInteractionModule.await_multi_target()`:**
`Callable(chosen: Array, candidate: Node) -> bool`, re-evaluado en cada click con lo ya
elegido — permite presupuestos/restricciones que se consumen con cada pick, no solo el
`lock_group_key` (que es binario, todo-o-nada por grupo). Para Tempilcahue, el filtro
resta la suma de lo ya elegido y rechaza cualquier candidato que haría superar 4 — el
brillo celeste de las cartas que dejan de calzar se apaga EN VIVO después de cada click,
en vez de descubrir el error solo al confirmar. Estrictamente mejor UX que el original,
no solo un cambio cosmético.

**`WeaponSearchShuffleExecutor._select_cards_by_cost_budget()` NO se tocó/eliminó en ese
momento** — seguía teniendo otros 2 llamadores (`BanishOpponentPatterns.gd:168`,
`WeaponSearchShuffleExecutor.gd:160`) pendientes de conversión futura, mismo patrón
aplicable ahí (`dynamic_filter` con la misma lógica de presupuesto). **Actualización 2026-09-13 (mismo día, siguiente tanda):** ambos llamadores restantes
convertidos — Ngenechén ("Destierra cartas rivales cuyos costes sumen hasta 6",
`BanishOpponentPatterns.gd::try_execute_banish_opponent_cost_sum_six_pattern`) y el
patrón genérico `SHUFFLE_FOR_DRAW` ("Baraja cartas cuyos costes sumen hasta N y Roba M",
`WeaponSearchShuffleExecutor.gd::_execute_shuffle_for_draw`), mismo `dynamic_filter` de
presupuesto que Tempilcahue. Con los 3 llamadores convertidos, `_select_cards_by_cost_
budget()` (y su forwarder de una línea en `TargetedEffectExecutor.gd`) quedaron sin
ningún llamador real — **se eliminaron completos** en vez de dejarlos como código muerto
(confirmado por grep de todo `scripts/` antes de borrar; solo quedaba una mención en un
comentario de `RemotePlayerController.gd`, ajustada para no señalar a la función borrada).

**CORRECCIÓN 2026-09-13, a pedido del usuario ("la habilidad del Bernardo O'Higgins no es
esa, revísalo bien"):** el segundo caso NO es Bernardo O'Higgins — esa atribución venía de
un comentario viejo en el código (`_execute_shuffle_for_draw()`, "p.ej. Bernardo
O'Higgins") que nunca se había verificado contra el texto real, y lo repetí sin chequear.
Verificado ahora contra `cards.json`: el texto real de Bernardo O'Higgins (ids
20312/20478) es "Una vez por turno, puedes Barajar un Arma o Aliado Caballero de tu mano
o que controles para cancelar una habilidad o Desterrar una carta de coste 3 o menos" —
sin ningún "cuyos costes sumen", un patrón totalmente distinto ya cubierto por
`BernardoAbilityHandler.gd` (ver §10.9, §10.15). El comentario falso ya se corrigió en el
código. **Hallazgo adicional:** se corrió el regex real del patrón `SHUFFLE_FOR_DRAW`
("puedes barajar cartas? cuyos? costes? sum(en\|an) hasta N ... y robar M cartas") contra
las ~1900 cartas de `cards.json` — CERO coincidencias. No hay ninguna carta conocida en
el caché local que dispare este patrón hoy; puede ser una carta real ausente de este
caché puntual, o un patrón agregado en algún momento sin una carta real verificada
detrás. No se investigó más a fondo ni se borró (podría ser una carta real que
simplemente no está cacheada todavía) — queda documentado como código de alcance/impacto
desconocido, no confirmado muerto.

### 10.21 Bug real encontrado al revisar: la conversión de Espada de O'Higgins (§10.14) apuntaba a código MUERTO

**2026-09-13, a pedido del usuario ("la habilidad del Bernardo O'Higgins no es esa,
revísalo bien") — al re-verificar esa corrección se encontró un problema más serio en lo
ya hecho en §10.14.** `TriggerResolution.gd` prueba los patrones de habilidad en un orden
fijo, cada uno con un `if ...: return true` — el PRIMERO que matchea gana, los de abajo ni
se llegan a evaluar para esa carta. Los dos patrones en juego:

- `try_execute_banish_from_cemeteries_and_draw_pattern()` (chequeo SUELTO: solo requiere
  que el texto contenga `"de los cementerios"` Y `"destierra"`, en cualquier parte) —
  probado en la línea ~379.
- `try_execute_banish_up_to_n_cemeteries_then_draw_pattern()` (chequeo ESTRICTO, regex
  exacto `"destierra hasta N cartas de los cementerios y roba M cartas"`) — probado
  DESPUÉS, en la línea ~393. Esta es la función que se convirtió en §10.14 pensando que
  era la que resuelve la Fase Final de Espada de O'Higgins.

Cualquier texto que matchee el regex estricto (línea 393) TAMBIÉN contiene trivialmente
`"destierra"` y `"de los cementerios"`, así que SIEMPRE matchea primero el chequeo suelto
(línea 379) y devuelve `true` antes de llegar a la línea 393 — la función estricta era
**inalcanzable para cualquier carta posible**, no un caso raro de una carta particular. La
conversión de §10.14 estaba bien escrita, pero en una función que el juego nunca llega a
ejecutar.

**La función que SÍ se ejecuta de verdad** para Espada de O'Higgins es
`MiscTargetedPatterns._resolve_banish_from_both_cemeteries()` (invocada desde
`try_execute_banish_from_cemeteries_and_draw_pattern()`) — todavía usaba DOS modales de
lista separados (primero Cementerio rival, después el propio, con el tope de la segunda
descontado de la primera) en vez de click directo. **Se convirtió esta función** (la real)
a `open_cemetery_target_picker()` en modo pool combinado — la razón original de las dos
selecciones separadas ("un pool mezclado confundía de cuál Cementerio salía cada carta")
queda resuelta por las columnas separadas y etiquetadas que el picker ya muestra.

**Limpieza:** `try_execute_banish_up_to_n_cemeteries_then_draw_pattern()` (confirmado
100% inalcanzable, no solo "sin carta conocida" como el caso de §10.20) se **eliminó
completa** — implementación en `DSR_CemeteryBanishDraw.gd`, forwarder en
`DrawShuffleResolver.gd`, y la línea de prueba en `TriggerResolution.gd`.

**De paso, misma revisión:** se convirtió también `MiscTargetedPatterns._resolve_search_
cemetery_to_hand()` (Cementerio propio, sube hasta N cartas a la mano — único llamador:
`DSR_SearchGoldCombos.gd`, confirmado activo/alcanzable) al mismo picker, filtro
restringido al lado propio + tipo. Este era uno de los dos ítems marcados "verificar
alcance" en el barrido de `controller_id` de §10.1, de una sesión anterior — quedó resuelto
de paso.

**Lección importante para el resto de la auditoría (§10.16):** antes de dar por buena una
conversión de un `try_execute_*_pattern()`, verificar en `TriggerResolution.gd` que ese
patrón puntual sea efectivamente el que GANA el orden de chequeo para el texto real de la
carta — no asumir que "la función con el nombre/docstring que menciona la carta" es la que
se ejecuta. Un chequeo de texto más suelto que corre ANTES puede estar interceptando
todo el tráfico sin que se note (ambas funciones "funcionan" si se las llama a mano — el
problema es que una de las dos nunca se llama en el juego real).

### 10.22 Frankenstein, gran kraken, cancelar-por-barajado: descarte/barajado de 1 carta de la mano

**2026-09-13, elegidas por Claude.** Tres casos simples y casi idénticos en
`PreventionAbilityHandler_EP.gd` — costo de "Descarta/Baraja 1 carta CUALQUIERA de tu
mano" sin filtro de tipo, para pagar una habilidad distinta en cada carta (Frankenstein:
silenciar una carta por el turno; una carta de cancelar-habilidad-por-barajado; gran
kraken: destruir una carta de coste ≤3). Al ser un solo Nodo de una sola zona ya visible
(mano), no hicieron falta `await_multi_target()` ni ningún picker — directo con
`CardInteractionModule.await_target()`, el mecanismo más simple de todos, con
`filter := func(c): return c.get("current_zone") == Constants.Zone.MANO`.

**Patrón para "descarta/baraja/destierra 1 carta cualquiera de tu mano" en general:**
si no hay filtro de tipo y es un solo objetivo, no hace falta `await_multi_target` —
`await_target()` con el filtro de zona MANO alcanza y es más simple.

### 10.23 Tanda grande (a pedido del usuario: "sigue con varias cartas no me preguntes")

**2026-09-13.** Conversión de todo lo convertible en `PreventionAbilityHandler_EP.gd`
(quedó en 0 modales de lista) y casi todo `PreventionAbilityHandler_PV.gd` (queda 1,
detallado abajo), más un helper COMPARTIDO de alto impacto:

- **Kuchiku Kan** — descarta 1 de tu mano (`await_target`, zona MANO).
- **Lanza Argenta** — su rama "cancelar" ya usaba click directo, no necesitó cambios.
- **nu-galahad el bastión** ("porta hasta tres cartas de UN Cementerio como Armas") —
  mismo patrón de Hanta el Samurai: `open_cemetery_target_picker(..., lock_to_one_side=
  true)` en vez de `_choose_search_zone_owner()` (pregunta previa) + modal de lista.
  `_choose_search_zone_owner()` NO se tocó/eliminó — sigue usándose en más de 10 sitios
  para búsquedas de Castillo (fuera de alcance, ver nota de Perla de Sangre abajo).
- **Paladín Bestiarium, primera habilidad** (Descartar 1 + jugar un Arma con descuento) —
  dos `await_target()` encadenados sobre la mano (elegir el Arma, después elegir qué
  descartar, excluyendo el Arma ya elegida).
- **Paladín Bestiarium, segunda habilidad** ("una vez en tu turno", Anular — el ejemplo
  real de §10.11) — elegir el Arma equipada a Descartar/subir, ahora `await_target()`
  directo sobre las Armas equipadas en juego.
- **Sake** ("un Oro de tu mano o Cementerio") — combina mano (Nodos reales) + un popup
  liviano del Cementerio propio (mismo patrón de El Rey y el Verdugo, §10.17) en una sola
  selección; se agregó `_open_cemetery_reveal_popup_oro()` en
  `PreventionAbilityHandler_PV.gd` (mismo código que `GoldManagerTax._open_cemetery_
  reveal_popup()`, filtrado a tipo Oro — no se generalizó a un helper único compartido
  por ahora, quedó duplicado a propósito para no acoplar dos módulos distintos por una
  función chica).
- **Sumi el terrible** ("carta de coste 1 en tu Cementerio") — `open_cemetery_target_
  picker()` con filtro propio+coste. Verificado que la mutación en el lugar de
  `picked_data["keywords"]` (para dar Exhumar temporal) sigue funcionando: `Card.load_
  from_data()` asigna `card_data = data` SIN duplicar, así que el diccionario que vuelve
  en `entry.data` es el mismo objeto que vive en `CardManager.get_cemetery()`.
- **Torre de Babel** — Barajar 1 de tu mano (`await_target`) + reusa el helper de abajo.
- **`GoldManager._resolve_armeria_barajar_desterrar()` (ALTO IMPACTO)** — convertida a
  `open_cemetery_target_picker()` (pool combinado, sin lock). Esta es una función
  COMPARTIDA reusada por Armería del Guerrero, Belta (primera habilidad), Perla de
  Sangre, Uriel y Torre de Babel — convertirla UNA vez arregló la selección de cartas
  para las 5 cartas de un saque. La elección posterior "¿Barajarla o Desterrarla?" POR
  CARTA sigue siendo un modal de 2 botones (efecto distinto, no selección de carta).
- **Uriel** — after Barajar/Desterrar (arriba), "Destierra 1 carta de tu mano" también
  convertido a `await_target()`.

**NO convertido — fuera de alcance por ahora:** `_activate_perla_de_sangre_search_hand_
or_play()` (elegir un Aliado del propio CASTILLO/mazo por nombre) y cualquier otro
"busca/elige una carta del Castillo" (docenas de sitios vía `_choose_search_zone_owner()`
+ picks de mazo) — el Castillo es una zona sin Nodos visibles persistentes como el
Cementerio; buscar en él requiere una funcionalidad nueva (un "visor de Castillo"
interactivo, análogo a `ZoneViewerModule` pero para el mazo) que todavía no existe. Se
deja pendiente como un bloque de trabajo aparte, no se improvisó una solución a medias.

**Verificación de esta tanda:** se confirmó con grep que `PreventionAbilityHandler_EP.gd`
quedó en 0 sitios de `SelectionManager.await_single_pick/await_multi_pick`;
`PreventionAbilityHandler_PV.gd` en 1 (la búsqueda de Castillo de Perla de Sangre,
fuera de alcance a propósito); `GoldManager.gd` en 1 (un diálogo de confirmación de un
solo candidato para Don de Amma — no es "elegir entre varias cartas", es un patrón de
confirmación distinto, no aplica el reemplazo).

### 10.24 Precisión sobre "buscar en tu Castillo": el mazo NO necesita el mismo tratamiento

**2026-09-13, pregunta del usuario sobre Tempilcahue.** El comentario de §10.23 sobre
"el Castillo necesita un visor nuevo" fue IMPRECISO — dicho sin haber revisado el detalle.
Al investigar `SelectionManager.open_search()` → `SelectionCanvas._create_card_display()`:
la búsqueda en el Castillo YA muestra el arte/imagen real de cada carta candidata en una
grilla, no una lista de texto plana. La diferencia real con Cementerio/Destierro no es
"buena UI vs. mala UI" sino de naturaleza de la zona: Cementerio/Destierro son PÚBLICOS
(DAR) — existen cartas reales que cualquiera podría mirar en cualquier momento, por eso
tiene sentido un visor que las deje clickear como objetos del tablero. El Castillo (mazo)
es información OCULTA — no hay "carta real" en el mundo hasta el instante mismo de
buscar; se revela solo dentro de esa misma grilla de búsqueda. Point final: la mano
RIVAL (p.ej. Chakram, "mira la mano de tu oponente") es del mismo tipo — oculta, sin
objeto real para clickear, el modal de reveal ya es la solución correcta.

**Regla para decidir si una zona es candidata al reemplazo por click directo:**
¿la información ya es pública/visible para el jugador en cualquier momento (mano propia,
campo, Cementerio, Destierro)? → sí, convertir. ¿Es oculta y solo se revela en el momento
de resolver la habilidad (Castillo propio o rival, mano rival)? → no — el modal/grilla de
SelectionManager ya es la UI correcta, no hay "objeto real" al que agregarle click.

### 10.25 Tanda grande #2: `SearchAbilityHandler_AI.gd` y `SearchAbilityHandler_JV.gd` completos

**2026-09-13, a pedido del usuario ("sigamos con más cartas").** Ambos archivos quedaron
en 0 sitios de `SelectionManager.await_single_pick/await_multi_pick` para zonas públicas
(los que quedaron sin tocar son búsquedas de Castillo o "mirar mano rival", fuera de
alcance por §10.24). Convertidas:

- **Cuerno de Titán** — descartar 1 de tu mano (`await_target`).
- **Don de Amma** — elegir qué Oro-con-habilidad desterrar de tu Reserva (`await_target`
  sobre los Nodos de `player_gold`/`opponent_gold`).
- **Espada de O'Higgins** (segunda habilidad, "Baraja una carta en juego que no sea Oro")
  — `await_target()` directo sobre cualquier carta en juego de cualquier lado (antes
  reunía candidatos en un Array y armaba un modal de lista con sus `card_data`).
- **Miguel** ("de tu mano o de un Cementerio") — el caso más elaborado de esta tanda:
  mano (Nodos reales) + un popup liviano de DOS columnas con ambos Cementerios
  (`_open_dual_cemetery_reveal_popup()`, nueva, en `SearchAbilityHandler_JV.gd` — mismo
  patrón que `_open_cemetery_reveal_popup_oro()` de Sake pero con 2 columnas en vez de
  1), con el filtro de asequibilidad aplicado ANTES de construir los Nodos temporales
  (evita instanciar cartas que ni se van a poder ofrecer).
- **quimera voragh** (mill + poner en juego como Aliado) — `open_cemetery_target_picker()`,
  pool combinado de ambos Cementerios.
- **Tenshi Z** y **Tesoro de los Césares** — barajar 1 de tu mano (`await_target`).

**Nota de diseño:** ahora hay DOS implementaciones del "popup liviano sin oscurecer,
Nodos temporales del Cementerio" — la de una columna (Sake, Rey y el Verdugo) y la de dos
columnas (Miguel). Quedaron duplicadas a propósito en sus respectivos archivos en vez de
extraer un helper compartido — son ~40 líneas de construcción de UI cada una, no vale la
pena acoplar `PreventionAbilityHandler_PV.gd`/`GoldManagerTax.gd`/`SearchAbilityHandler_
JV.gd` a un cuarto módulo solo por esto. Si aparece un tercer o cuarto caso, ahí sí
conviene extraerlo a un helper real (candidato natural: `ZoneViewerModule`, que ya tiene
el popup GRANDE de dos columnas — se podría agregar una variante "liviana" ahí).

### 10.26 Tanda grande #3: `LookRevealPatternsB.gd`, `BanishOpponentPatterns.gd`, `ShuffleDrawPatterns.gd`, `PlayFromCemeteryPatterns.gd`

**2026-09-13, a pedido del usuario ("continuemos con más cartas").** Convertidas:

- **Duelo de Dragones** ("Pon un Oro de tu mano en tu Oro Pagado") — `await_target`.
- **cruzar el bosque** (rama "Subir") — Cementerio rival, coste ≤2, `open_cemetery_
  target_picker()`. La rama "Destruir" ya usaba clicks sucesivos, sin cambios.
- **Anula-y-baraja-por-coste** (`try_execute_annul_then_shuffle_cost_pattern`) — costo
  TODO o NADA de N cartas exactas de tu mano (N = coste de lo anulado), `await_multi_
  target()` con `max_count=amount` + chequeo `picked.size() < amount` (mismo patrón que
  Belta, §10.19).
- **amazona desafiante** — dos partes en la misma función: (1) hasta 1 carta EN JUEGO de
  cualquier lado con coste ≤2 (`await_target`), (2) hasta 4 cartas de AMBOS Cementerios
  (`open_cemetery_target_picker`).
- **Príncipe Orión** (rama "Subir Aliado") — Cementerio propio, tipo Aliado,
  `open_cemetery_target_picker()`.
- **Titán Abismal** y **sumi el terrible** (`_activate_play_cemetery_ally_free_or_draw_
  three_pattern`) — Cementerio propio filtrado por tipo/coste/raza, mismo patrón.

**NO convertido — hallazgo para seguir después:** `aku aku` (`try_execute_play_cemetery_
ally_discounted_min1_pattern`) usa `ActionModule.search(controller_id, Constants.Zone.
CEMENTERIO, ...)` — el motor de búsqueda GENÉRICO (el mismo de "busca en tu Castillo",
§10.24), pero apuntando a una zona PÚBLICA (Cementerio), no oculta. Por la misma regla de
§10.24 (¿la info ya es pública? → convertir), este caso SÍ sería candidato al reemplazo —
pero tocar `ActionModule.search()`/`_select_search_results()` afecta un núcleo compartido
por docenas de habilidades de "busca una carta" (Castillo Y Cementerio a la vez), así que
no se tocó en esta sesión sin evaluarlo con más cuidado aparte. **Queda pendiente**:
separar el camino CEMENTERIO de `ActionModule.search()` para que use `open_cemetery_
target_picker()` en vez de `_select_search_results()`, sin tocar el camino CASTILLO.

**Abrazo de Maipú** (`try_execute_shuffle_any_cemetery_or_exile_into_castillo_then_draw_
pattern`) tampoco se tocó — mezcla Cementerio Y Destierro propios en un mismo pool, y
`open_cemetery_target_picker()` solo maneja un `zone_type` a la vez (cemetery O exile, no
ambos combinados). Necesitaría una variante nueva del picker; un solo caso conocido hasta
ahora, no se justificó construirla todavía.

**Verificación:** grep de todo `scripts/` para `SelectionManager.await_single_pick/
await_multi_pick` fuera de sus propios archivos: bajó de ~100+ sitios (inicio de §10.16)
a 45 — los que quedan son mayormente búsquedas de Castillo/mano rival (fuera de alcance,
§10.24) o casos aún no revisados.

### 10.27 "Seleccionar todo" + Cementerio y Destierro combinados (Abrazo de Maipú)

**2026-09-13, a pedido del usuario.** Texto real verificado: "Baraja **cualquier
cantidad** de cartas de tu Cementerio **y** Destierro en tu Castillo y Roba tres cartas."
Dos problemas reales con el estado de §10.26 (que había dejado esta carta sin convertir):
mezcla DOS zonas de datos a la vez (`open_cemetery_target_picker()` solo aceptaba una),
y "cualquier cantidad" sin tope — con un Cementerio+Destierro grande (el usuario dio el
ejemplo de 20 cartas), clickear una por una es tedioso.

**Dos capacidades nuevas agregadas:**

1. **`zone_type: "cemetery_and_exile"`** en `open_cemetery_target_picker()` — junta
   Cementerio y Destierro de cada lado en el MISMO pool/columna, cada Nodo temporal
   marcado con `set_meta("source_zone_type", ...)` para que el resultado devuelva de cuál
   zona salió cada carta elegida (`entry.zone_type`, "cemetery" o "exile") — el caller
   necesita saberlo para llamar a `remove_from_cemetery()` o `get_exile().erase()` según
   corresponda (son APIs distintas, ver `CardManager.gd`).
2. **`CardInteractionModule.request_select_all()`** + soporte en `await_multi_target()` —
   cualquier botón de UI puede llamarlo mientras la selección está esperando un click; en
   el próximo frame se toma TODO lo que quede en `remaining` (respetando `lock_group_key`/
   `dynamic_filter` si están activos) de una sola vez, sin clicks individuales.
   `open_cemetery_target_picker(..., show_select_all=true)` agrega el botón correspondiente
   al popup. **Advertencia dejada en el docstring:** combinar `lock_to_one_side=true` +
   `show_select_all=true` es seguro DESPUÉS del primer click (el lock ya filtra qué
   cuenta como "remaining"), pero si se aprieta "Seleccionar todo" ANTES de elegir nada,
   se ignora el lock por completo (no hay nada todavía que fije el lado) — ningún caso
   actual combina ambas opciones, pero cualquier uso futuro debe tenerlo presente.

**Abrazo de Maipú convertida** con ambas: `open_cemetery_target_picker(prompt, own_only,
-1, "cemetery_and_exile", false, true)` — sin lock (no hace falta, ya viene filtrado a
solo el propio lado), con el botón de seleccionar todo.

**Aku aku, aclaración pedida por el usuario:** su texto real completo es "Furia. Cuando
entra en juego, puedes jugar un Aliado de tu Cementerio reduciendo su coste en un Oro,
hasta un mínimo de 1. Cuando hagas daño de combate, Destierra tantas cartas de los
Cementerios como Fuerza tenga un Aliado." Lo tocado en §10.26 fue únicamente la PRIMERA
cláusula (la que usa `ActionModule.search()`, dejada sin convertir por afectar al motor
compartido — ver esa sección). **Actualización — segunda cláusula ya convertida:**
`try_execute_banish_cemeteries_equal_to_own_strength_pattern()` (`DSR_CemeteryBanishDraw.
gd`) — pool combinado de ambos Cementerios, sin lock (mismo caso que Espada de O'Higgins).
Esta misma función también cubre a kaitai ("Desterrar hasta tantas cartas de los
Cementerios como Fuerza tenga ESTE Aliado", autoreferencial explícito) — se arregla de
paso con el mismo cambio. Con esto, aku aku queda con su primera cláusula pendiente
(motor de búsqueda compartido, fuera de alcance) y su segunda ya convertida.

### 10.28 `HandCementerioAbilityHandler.gd` y confirmaciones de un solo candidato

**2026-09-13, a pedido del usuario ("termina el aku aku y luego sigue las cartas").**
Convertidas en `HandCementerioAbilityHandler.gd`:

- **Tyet/Cuervo Nocturno** (la habilidad de moler-y-robar, ver también §10.11) — elegir
  la OTRA carta de la mano a mandar al fondo, `await_target`.
- **Sandraudiga** — elegir otro Aliado Sacerdote de la mano para desterrar junto con esta
  carta, `await_target`.
- **Drácula** (cancelar el ataque de hasta dos Aliados) — los candidatos salían de
  `GameManager.attackers`, que ya son Nodos reales (los Aliados atacando) — convertido a
  `await_multi_target()` directo sobre esos Nodos, sin pasar por `card_data` en ningún
  momento.
- **Ramón Freire** (post-barajar un Aliado rival, barajar N cartas de tu mano según su
  coste) — costo todo o nada de N cartas exactas (mismo patrón que Belta, §10.19).
  Corregido de paso un riesgo de usar `card_data` DESPUÉS de `remove_card()` (leer el dato
  antes de remover, no después — un Nodo recién removido/liberado no debe consultarse).

**Nueva categoría identificada: confirmaciones de un solo candidato.** Varias
habilidades ("puedes X" sobre ESTA MISMA carta) reutilizan `await_single_pick()` con un
Array de un solo elemento como diálogo sí/no disfrazado (clickear la única opción = sí,
Cancelar = no) — patrón documentado en el propio código como deliberado
(`_offer_reactive_second_gold_to_pagado()`, `try_execute_ally_to_gold_pagado_pattern()`).
Cuando la carta en cuestión es un Nodo YA EN JUEGO conocido de antemano (no data cruda),
esto también se puede simplificar a `await_target()` con un filtro que solo acepta ESA
carta — clickearla en el tablero confirma, ESC declina, sin panel aparte. Convertido un
caso así (`ConvertAndMiscResolver.try_execute_ally_to_gold_pagado_pattern()`, Biblioteca
de Caballería). El de `GoldManager._offer_reactive_second_gold_to_pagado()` (Don de Amma)
NO se tocó — la carta puede venir de la mano O el Cementerio según el caso, y para
Cementerio no hay Nodo persistente sin abrir un popup — no valía la pena para un solo
candidato confirmándose a sí mismo.

### 10.6 Decisión de reglas confirmada: una errata rige para TODAS las impresiones de la carta

**2026-09-13, a pedido del usuario.** Cuervo Nocturno y Tyet comparten la habilidad
"Puedes poner esta y otra carta de tu mano en el fondo de tu Castillo y Robar dos
cartas." Solo las impresiones más nuevas (`custom_mid_35`/`custom_mig_27`/
`custom_tk26_06` de Cuervo Nocturno; `custom_mid_42`/`custom_mig_43` de Tyet) agregan la
oración de cierre "Sólo puedes utilizar esta habilidad de [Nombre] una vez por turno" —
las impresiones viejas (p.ej. `18646`, `20554`, `20864`, `19968`) no la traen impresa.

**Decisión del usuario:** en Mitos y Leyendas, una errata/actualización de habilidad
rige para TODAS las copias de esa carta, sin importar en qué edición/impresión física
esté cada una — no solo para la impresión puntual que trae el texto actualizado. Por lo
tanto el límite de una vez por turno debe aplicarse a CUALQUIER copia de Cuervo Nocturno
o Tyet, tenga o no la oración de cierre impresa.

**Implementación:** `UniversalCardParser.parse_abilities()` ya distinguía esta
habilidad por texto vía `pays_self_to_deck_bottom` (no depende de la edición). Se agregó
`effective_once_per_turn: bool = once_per_turn or pays_self_to_deck_bottom` justo antes
de armar el diccionario de la habilidad, forzando `once_per_turn: true` para CUALQUIER
carta que matchee ese patrón, en vez de depender de que esa impresión puntual traiga la
oración de cierre. La detección de `cost_type` (línea `if once_per_turn: cost_type =
ONCE_PER_TURN` vs `elif pays_self_to_deck_bottom: cost_type = SELF_TO_DECK_BOTTOM`) sigue
usando la variable `once_per_turn` original sin tocar, para no romper qué costo real se
ejecuta — solo el flag final que ve `AbilityButtonSupport`/`turn_registry` cambia.

**Precedente relacionado, no contradictorio:** esto NO reabre el caso de Aho (§ver
comentario en `UniversalCardParser.gd` líneas 294-304) — ahí la corrección fue que el
cupo de "una vez por turno" se registra POR COPIA FÍSICA (`instance_id`), no compartido
entre copias del mismo nombre en juego a la vez. Esta decisión es ortogonal: sigue siendo
por copia física, pero ahora TODAS las copias (viejas y nuevas) tienen el límite activo,
en vez de solo las impresiones que lo imprimen literalmente.

**Si aparece un caso similar a futuro** (otra carta con errata de "una vez por turno" en
una reimpresión más nueva): mismo patrón — forzar el flag en el `if`/pattern de texto que
ya identifica la habilidad por contenido, no depender de que la oración de cierre esté
presente en esa carta puntual.

### 10.7 Click derecho a una carta "llega pero no hace nada" — inspección con guarda de un solo slot

**2026-09-13, bug real reportado por el usuario:** click derecho sobre un Aliado del
rival (Alto Prime) confirmado con el print `[DIAG] gui_input RIGHT-CLICK llegó a: ...`
— el evento SÍ llegaba hasta `Card.on_gui_input()` y emitía `card_right_clicked`, pero
no pasaba nada visible. Esto llevó a sospechar (incorrectamente al principio) de un
bloqueo de input específico del lado del rival — no lo era.

**Causa real:** `CardInspectionLayer._open_card_inspection()` guarda la carta
inspeccionada en una única variable (`inspected_card`, un solo slot). Si ya había una
inspección abierta (p.ej. se acababa de inspeccionar Tyet de la mano un instante antes,
sin cerrarla) y llegaba un click derecho sobre OTRA carta, la función cortaba en
silencio (`if inspected_card: return`) — sin mensaje de error ni ninguna pista de por
qué "no hacía nada". No era un problema de targeting ni de que el rival estuviera
bloqueado; el mismo corte silencioso pasa con dos cartas propias seguidas.

**Fix:** en vez de cortar, `_open_card_inspection()` ahora cierra la inspección anterior
(`close_card_inspection()`, llamada sin `await` — corre en segundo plano, la carta vieja
se desvanece mientras la nueva ya se abre) y sigue con la nueva. Se agregó una guarda en
`close_card_inspection()` para que su `_main.inspection_layer.visible = false` final (que
corre ~0.2s después, tras el tween de cierre) no apague la capa si mientras tanto ya se
abrió una inspección nueva.

**Lección:** un print de diagnóstico que confirma "el evento llegó al nodo correcto" no
descarta el bug — solo acota dónde seguir buscando (aquí, aguas abajo del emisor de la
señal, no en el routing de input en sí). No asumir que un síntoma "en cartas del rival"
tiene necesariamente que ver con ser del rival — pudo ser una guarda de estado global
(un solo slot de inspección) que se dispara igual con cartas propias en la secuencia de
clicks correcta.

### 10.8 El bot activa habilidades especiales por el camino GENÉRICO, ignorando sus manejadores a medida

**2026-09-13, bug real reportado por el usuario:** el Don de Amma del rival se resolvió
al empezar la Vigilia del jugador con `[Parser] Acción detectada: BANISH` y
`[Main] Elige un Aliado para desterrar` — pero la habilidad real de Don de Amma es
"Desterrar un Oro con habilidad de tu Reserva. Luego, busca un Oro...", nada que ver con
un Aliado.

**Causa:** `EasyBotController.take_ability_actions()` escanea TODAS las habilidades
ACTIVADAS del rival cuyo `cost_type` sea NONE/ONCE_PER_TURN/GOLD/TAP y activa una al azar
llamando directo a `ActionPipeline.activate_ability()` — el camino GENÉRICO basado en
`ABILITY_PATTERNS` (texto → acción). Ese escaneo no sabe que Don de Amma (y varias otras
cartas — ver `AbilityButtonPatternsA/B/C/D.gd`) tienen un manejador a medida
(`_activate_don_de_amma()` en `SearchAbilityHandler_AI.gd`) precisamente PORQUE el
genérico no entiende su costo/objetivo real. Para Don de Amma, el texto matchea el
patrón `BANISH` genérico, que `TargetedEffectExecutor._execute_targeted_banish()`
resuelve SIEMPRE contra un Aliado (`_select_ally_target`), sin importar que el objeto
real sea "un Oro con habilidad de tu Reserva". El botón del jugador humano nunca pasa por
aquí — `AbilityButtonPatternsA.try_build()` intercepta el patrón ANTES de llegar al botón
genérico — pero el escaneo del bot no tiene ese mismo filtro.

**Fix aplicado (alcance: Don de Amma):** `take_ability_actions()` ahora detecta el mismo
patrón de texto que `AbilityButtonPatternsA.gd` (`"desterrar un oro" + "con habilidad" +
"busca un oro"`) y, si matchea, llama directo a
`_main._card_inspector._search_handler._activate_don_de_amma(chosen.card, chosen.ability)`
en vez del genérico. `_activate_don_de_amma()` ya soportaba `owner_id == 1` desde que se
escribió (2026-08-29) — sólo faltaba que este escaneo lo invocara.

**Riesgo NO resuelto (alcance limitado a propósito):** el mismo problema puede
reproducirse con CUALQUIER otra carta que tenga un patrón especial en
`AbilityButtonPatternsA/B/C/D.gd` Y además tenga un `cost_type` genérico reconocible
(NONE/ONCE_PER_TURN/GOLD/TAP) — el escaneo del bot la recogería igual y la ejecutaría mal
si el bot llega a controlarla. No se auditaron los ~40+ patrones especiales uno por uno
para confirmar cuáles son bot-seguros; se corrigió solo el caso reportado. Si aparece
otro caso similar (bot ejecutando mal una habilidad con manejador a medida), aplicar el
mismo patrón: detectar el texto especial en `take_ability_actions()` y desviar al
manejador correspondiente en vez de dejar que caiga en `ActionPipeline.activate_ability()`.

### 10.9 `source_card` usado después de un `await` sin revalidar (recurrencia fuera de HandCementerioAbilityHandler.gd)

**2026-09-13, bug real reportado por el usuario:** `Invalid type in function
'_bernardo_banish_target'... The Object-derived class of argument 1 (previously freed)
is not a subclass of the expected argument class.`

**Causa:** exactamente el mismo patrón ya documentado y corregido en
`HandCementerioAbilityHandler.gd` (2026-09-06, ver comentario ahí: "el await de arriba es
tiempo real de espera del jugador — si la carta salió de juego mientras el selector
estaba abierto, quedaba una referencia colgante") pero que NO se había propagado a
`BernardoAbilityHandler.gd`. `_activate_bernardo_shuffle_removal()` sigue usando
`source_card` (Bernardo O'Higgins) después de DOS esperas reales del jugador
(`await_single_pick()` para el costo, y el loop de espera de la elección Desterrar/
Cancelar) sin revalidar `is_instance_valid(source_card)` entre medio — si Bernardo salió
de juego mientras el jugador todavía elegía, la llamada siguiente pasaba una referencia
liberada a una función con parámetro tipado (`Node`), que Godot rechaza en runtime en vez
de solo fallar silenciosamente.

**Fix:** se agregó `is_instance_valid(source_card)` después de cada uno de los dos
`await` reales en `_activate_bernardo_shuffle_removal()`, y también antes de los usos
finales de `source_card` dentro de `_bernardo_banish_target()`/
`_bernardo_cancel_ability_target()` (por si Bernardo sale de juego durante el
`await_target()` de elegir el objetivo).

**Cómo evitarlo al escribir un manejador nuevo:** cualquier función que reciba una carta
Node y tenga un `await` real (espera de input del jugador, no una animación de duración
fija) en el medio, debe revalidar `is_instance_valid()` de esa carta después de CADA
punto de espera antes de volver a leerla o pasarla a otra función tipada. Buscar
`_bernardo_banish_target`/`HandCementerioAbilityHandler.gd` como referencia de ambos
lados del mismo bug (uno ya corregido, uno recién encontrado) si aparece un tercer caso.

### 10.10 Regresión: preguntaba "¿cuál Oro gastar?" incluso sin elección real

**2026-09-13, bug real reportado por el usuario:** al jugar una carta de coste 2 con
exactamente 2 Oros en Reserva (hay que gastarlos los dos, no hay nada que elegir), el
juego preguntaba igual "Elige qué Oro gastar". `_choose_physical_gold_to_spend()` ya
tenía el atajo correcto desde 2026-09-03 ("Sin elección real... no pregunta nada"),
condicionado a `restante >= oros_reserva.size()`.

**Causa:** regresión introducida por el fix de Monitor Araucano (§10.3, 2026-09-11), que
cambió `pagar_coste()` de gastar todo el Oro físico de una vez a un bucle que gasta
UNO a la vez. Ese bucle (línea ~1635) llamaba a `_choose_physical_gold_to_spend(oros_
reserva, 1)` con el `1` FIJO (una unidad por vuelta), en vez del `restante` real de la
transacción completa — así que la condición `restante >= oros_reserva.size()` se
evaluaba como `1 >= 2` (falso) en vez de `2 >= 2` (verdadero), y el atajo de "sin
elección real" dejaba de dispararse salvo que solo quedara 1 Oro en Reserva.

**Fix:** pasar `restante` (el total real que falta pagar en este momento de la
transacción) en vez de `1` fijo. La función solo consume `picked[0]` de todos modos
(sigue gastando un Oro físico por vuelta, preservando el comportamiento de Monitor
Araucano), pero ahora evalúa correctamente si hay o no elección genuina — y esa
evaluación se re-hace en cada vuelta del bucle, así que si a mitad de pago aparece Oro
Virtual nuevo (Monitor Araucano) que reduce lo que falta por debajo del Oro físico
disponible, en ESE punto sí empieza a preguntar (hay elección real desde ahí).

**Lección:** al convertir un pago "de una sola vez" en un bucle incremental, revisar
TODOS los atajos/optimizaciones que dependían del monto total original — quedan rotos en
silencio si el bucle nuevo pasa una unidad fija en su lugar sin que ningún test lo note
(la función seguía "funcionando", solo con más fricción de la necesaria).

### 10.11 Regla de reglas confirmada: CUÁNDO se puede activar una habilidad (Vigilia vs. tu turno vs. Guerra de Talismanes vs. en cualquier momento)

**2026-09-13, a pedido del usuario.** Cuatro categorías de timing, de más a menos
restrictiva:

1. **"En Vigilia" / "en tu Vigilia"** (texto explícito) — SOLO durante la Vigilia propia.
   Ya implementado correctamente (`AbilityButtonSupport._validate_ability()`, chequeo
   `"en tu vigilia" in raw_lower`).
2. **"Una vez EN tu/su turno"** (texto explícito, distinto del caso 3) — SOLO durante tu
   turno, JAMÁS dentro de una ventana de prioridad anidada (Guerra de Talismanes,
   respuesta a un trigger), aunque la propia habilidad pueda Anular/Cancelar. Ejemplo
   real: paladín bestiarium (id `18631`), segunda habilidad — "Una vez en tu turno,
   puedes Descartar o subir un Arma... para Anular una carta de coste 1 o menos." Puede
   Anular, pero el texto explícito la restringe igual — la restricción textual pesa más
   que la convención general de "Anular/Cancelar es de respuesta instantánea" del caso 4.
3. **"Una vez por/al turno" genérico, o solo "puedes"** (sin calificar CUÁNDO) — activable
   en tu turno normal Y durante cualquier ventana de prioridad que se abra en tu turno
   (Guerra de Talismanes incluida). Ejemplo: Aho ("una vez por turno").
4. **Habilidad que puede Anular/Cancelar, sin calificación de turno tipo caso 2** — "una
   vez por turno" Y ADEMÁS en cualquier momento que el rival juegue una carta o use una
   habilidad, incluso durante el turno DEL RIVAL. Ejemplos: Bernardo O'Higgins, Almirante
   Akari.

**Implementado en esta sesión:** caso 2, vía un nuevo flag `once_per_turn_own_turn_only`
en `UniversalCardParser.parse_abilities()` (true solo para "una vez en tu/su turno",
separado de `once_per_turn` genérico que sigue cubriendo las 4 variantes para la
frecuencia). Consultado en `AbilityButtonSupport._validate_ability()` — si el flag es
true y `PriorityManager.priority_window_active`, la habilidad no está disponible
("Solo en tu turno (no en una ventana de prioridad)"). También excluido de
`EasyBotController.try_respond_with_activated_ability()` (esa función SOLO corre dentro
de una ventana de respuesta, así que por definición el caso 2 nunca aplica ahí).

**NO implementado — brecha conocida (caso 4):** hoy, `CardInspectionLayer._build_
ability_buttons()` corta con `if GameManager.active_player_id != 0: return` ANTES de
llegar a evaluar habilidades — es decir, NINGÚN botón de habilidad del jugador humano se
muestra durante el turno del rival, ni siquiera para cartas con Anular/Cancelar como
Bernardo O'Higgins o Akari. Implementar el caso 4 correctamente requiere permitir ese
botón durante `active_player_id == 1` cuando la ventana de prioridad actual permite
actuar al jugador 0 (`PriorityManager.can_act(0)`) Y la habilidad puntual es de tipo
Anular/Cancelar — un cambio más grande que toca el gateo temprano de turno, no solo
`_validate_ability()`. No se implementó en esta sesión por alcance; queda pendiente si el
usuario confirma que quiere jugar contra el bot usando Bernardo/Akari como respuesta
instantánea en el turno rival.

### 10.12 Diálogo de Bernardo (elegir efecto) invisible hasta el próximo click derecho

**2026-09-13, bug real reportado por el usuario:** al activar la habilidad de Bernardo
O'Higgins, tras elegir la carta de costo (Barajar Arma/Caballero), el diálogo "Elige el
efecto" (Desterrar/Cancelar) no aparecía en pantalla — solo se hacía visible después de
hacer click derecho en cualquier otra carta.

**Causa:** `BernardoAbilityHandler._show_bernardo_effect_choice()` agrega su overlay como
hijo de `_main.inspection_layer` — la MISMA capa que `CardInspectionLayer.close_card_
inspection()` apaga (`inspection_layer.visible = false`) con un retraso real (~0.2s,
esperando el tween de cierre de la carta previamente inspeccionada). El botón de
habilidad de Bernardo llama a `close_card_inspection()` al activarse (cerrando el zoom de
Bernardo) y sigue de largo sin esperar ese cierre — para cuando el diálogo de efecto se
agrega (después de que el jugador elige la carta de costo, tiempo real de espera), el
apagón diferido de la capa puede llegar DESPUÉS, ocultando el diálogo recién agregado sin
que nada lo hubiera avisado. El próximo click derecho vuelve a poner `inspection_layer.
visible = true` (vía `_open_card_inspection()`), revelando el diálogo que ya estaba ahí.

**Fix:** contador de generación (`CardInspectionLayer._inspection_layer_generation`) +
`mark_inspection_layer_in_use()` (fuerza `visible = true` de inmediato Y avisa que hay
contenido nuevo). `close_card_inspection()` captura el contador al empezar y solo apaga
la capa al final si nadie más la marcó como "en uso" mientras tanto. `_show_bernardo_
effect_choice()` ahora llama a `mark_inspection_layer_in_use()` al agregar su overlay —
cubre tanto el caso en que el apagón YA pasó (fuerza visible=true de nuevo) como el caso
en que pasa DESPUÉS (el contador no coincide, así que no apaga).

**Cómo evitarlo con overlays nuevos:** cualquier código que agregue contenido visible a
`_main.inspection_layer` debe llamar a `CardInspectionLayer.mark_inspection_layer_in_use()`
al hacerlo, no asumir que la capa ya está visible solo porque algo la mostró antes.

### 10.13 Botón ¿Paso? contextual: "Daño" en Guerra de Talismanes

**2026-09-13, a pedido del usuario:** "la Guerra de Talismanes se termina cuando doy
Paso... el botón debería decir 'Daño', por ejemplo, no solo cuando hice una acción" — el
botón debe reflejar la CONSECUENCIA de presionarlo (pasar en Guerra de Talismanes es lo
que hace avanzar a Asignación de Daño, Constants.Phase 5.3.3→5.3.4), no ser un genérico
"¿Paso?" siempre. `GameHUDModule.update_paso_button_state()` ya tenía este mismo criterio
para Vigilia ("Atacar") — se extendió con `Constants.Phase.GUERRA_TALISMANES → "Daño"`.
Si aparece un pedido similar para otra fase/contexto, mismo patrón: un caso más en ese
mismo if/else, no una tabla de textos aparte.

**Nota de numeración:** las secciones de este §10 no quedaron en orden numérico estricto
(§10.14-§10.28 se insertaron antes que §10.6-§10.13 en el archivo, por dónde apuntaba
cada edición en su momento) — el contenido está completo, solo el orden físico no es
secuencial. No se renumeró para no arriesgar un find-replace masivo sin necesidad; usar
Ctrl+F por el número si se busca una sección puntual.

### 10.29 Cierre de los "17 genuinamente convertibles" — y una capacidad nueva importante

**2026-09-13, a pedido del usuario ("comencemos con los 17 genuinamente convertibles").**
Los 17 sitios identificados en el conteo de la sesión quedaron convertidos. Antes de la
lista, la capacidad nueva:

**`cancellable` en `await_target()`/`await_multi_target()`/`start_target_selection()`
(default `true`, sin cambiar nada de lo ya convertido).** Al convertir `TargetedEffect
Executor._select_hand_cards_for_discard()` (helper COMPARTIDO por 6 llamadores) se notó
un riesgo real: el modal viejo se abría con `can_cancel=false` para descartes MANDATORIOS
("Descarta N cartas", sin "puedes") — pero el sistema de click (`is_selecting_target`)
no tenía forma de bloquear el ESC, así que convertirlo tal cual habría dejado al jugador
esquivar un descarte obligatorio con solo apretar Escape. Se agregó `_selection_
cancellable` a `CardInteractionModule`: `cancel_target_selection()` (el handler de ESC)
ahora no hace nada si la selección en curso se abrió con `cancellable=false`. El botón
"Seleccionar todo" (§10.27) se resuelve aparte, sin pasar por ese guard, para seguir
funcionando incluso en una selección no-cancelable. **Regla para el resto de la
auditoría:** antes de convertir un `await_multi_pick()`/`await_single_pick()` que se abría
con `can_cancel=false` en el modal viejo, pasar `cancellable=false` a la versión nueva —
NO asumir que el default (`true`) es siempre seguro.

**Convertidos (17):**
- `TargetedEffectExecutor._select_hand_cards_for_discard()` — helper compartido (6
  llamadores: `BanishOpponentPatterns.gd`, `DSR_DiscardChoicePatterns.gd`, `SearchAbility
  Handler_AI.gd`, `ShuffleDrawPatterns.gd`, `ActionPipeline.gd`, uso interno). Ahora
  `cancellable=false` (mandatorio, ver arriba).
- `DSR_CemeteryBanishDraw.gd` — Tamales (Barajar), un segundo patrón de Desterrar (mismo
  molde, la carta de ejemplo en el comentario decía "Quantum Megumi" pero es un patrón
  DISTINTO al ya convertido antes, no duplicado/muerto — verificado por regex), y Mariano
  Osorio (Cementerio rival solo).
- `DSR_DiscardChoicePatterns.gd` — Golpe Solar: descarte opcional de mano
  (`await_multi_target`) + elegir un Aliado de tu mano O TU CEMENTERIO con descuento
  (popup combinado de una columna, mismo patrón que Sake).
- `DSR_ShuffleDrawCombos.gd` — Aaru ("cualquier cantidad" de la mano), Manuel Bulnes y
  Trono del Dragón (cantidad exacta, mandatorio → `cancellable=false`).
- `EffectController._pay_akari_shuffle_cost()` — Almirante Akari, mano+campo combinados.
- `BernardoAbilityHandler._activate_bernardo_shuffle_removal()` — el costo (mano+campo).
- `PreventionAbilityHandler_AE.gd` — Crono Diamante (mismo esqueleto que Paladín
  Bestiarium, dos picks en mano) y Espíritu de la Máquina/Macu (Cementerio, eliminada la
  pregunta previa de "¿cuál Cementerio?" con `lock_to_one_side`).
- `WeaponSearchShuffleExecutor.gd` — Lobo Sagrado (mano+Cementerio propio combinados,
  popup de una columna) y Padre de la Patria (dos picks, ambos en juego/mano).

**Verificación:** grep final de `scripts/` — 15 sitios reales quedan (bajando de 35), y
los 15 son exactamente los ya categorizados como fuera de alcance (busca en Castillo,
mirar mano rival, reordenar disparadores simultáneos, confirmaciones de un solo
candidato). No queda ningún sitio "genuinamente convertible" pendiente de esta
categoría — el resto de trabajo futuro requiere ampliar el alcance (p.ej. un visor
interactivo de Castillo) más que simplemente repetir este mismo patrón.

### 10.30 Los 15 restantes: veredicto del usuario por categoría, y el caso de disparadores simultáneos convertido

**2026-09-13, a pedido del usuario, tras revisar la lista de §10.29:**
- Búsquedas en el Castillo (mazo) → el visor/modal actual está BIEN, sin cambios.
- "Mirar la mano" (rival) → el visor/modal actual está BIEN, sin cambios.
- Ordenar disparadores simultáneos (`TriggerSystem._prompt_trigger_order()`) → SÍ
  convertir, pero sin visor: click directo sobre la carta real que va a disparar.

**`TriggerSystem._prompt_trigger_order()` convertida** — cada trigger pendiente ya trae
su propia carta real (`t.get("card")`, Nodo en juego), así que se armó `candidates` con
esos Nodos directo y se resolvió con `await_multi_target(..., cancellable=false)` — el
orden de click es el orden de resolución, igual que antes preservaba el orden del modal
viejo, pero clickeando la carta real en el tablero en vez de una miniatura en un panel
aparte. `cancellable=false` (mismo criterio de §10.29): cancelar a mitad de camino
perdería triggers reales sin resolver, no es un costo opcional que se pueda declinar.

### 10.31 Bug real encontrado por el usuario al probar: `CardNameSearchDialog.gd` no cargaba

**2026-09-13.** Godot tiró error de parseo al cargar la escena: `results_box` no estaba
declarado en `CardNameSearchDialog.gd` (usado por "nombra una carta", p.ej. Tesoro de los
Césares/Alicia en Wonderland). **NO relacionado con nada tocado en esta sesión** — archivo
nunca editado antes de este hallazgo, bug preexistente. La variable real del contenedor de
resultados se llama `results_flow` (declarada arriba en la misma función); `results_box`
nunca existió. Además la lógica en sí estaba mal aunque el nombre hubiera sido correcto:
comprobaba `top_child is BaseButton` y le disparaba `pressed`, pero los hijos de ese
contenedor son Nodos `Card` (conectados a `card_clicked`, no botones) — nunca habría
funcionado como "Enter selecciona el primer resultado". Se reemplazó por una llamada
directa a `on_result_clicked.call(displayed_cards[0])` (la misma función que ya resuelve
un click real sobre un resultado), usando `displayed_cards` (el Array que sí existe y
lleva la cuenta real de los resultados mostrados).

### 10.32 Bug real encontrado por el usuario al probar: `_mulligan_controller` no existe

**2026-09-13.** Error en runtime: "Invalid access to property or key '_mulligan_controller'
on a base object of type 'Control (Main.gd)'." **NO relacionado con nada tocado en esta
sesión.** `Main.gd` declara la variable como `_mulligan_ctrl` (línea 83); `DebugInputModule.
gd` (el atajo de teclado para "Quedarse con la mano" durante el Mulligan) la referenciaba
como `_main._mulligan_controller` — nombre que nunca existió, único uso en todo el
proyecto (confirmado por grep). Corregido a `_mulligan_ctrl` en las 3 líneas que lo usaban.

### 10.33 Bug real encontrado por el usuario al probar: `is_active`/`confirm_button` no existen en SelectionModule

**2026-09-13.** Error en runtime: "Invalid access to property or key 'is_active' on a base
object of type 'Node (SelectionModule)'." **NO relacionado con nada tocado en esta sesión**
(único uso en todo el proyecto, confirmado por grep). En `DebugInputModule.gd`, dentro de
`_handle_enter_press()` (Enter activa el botón contextual correspondiente), el paso 6
("panel de selección de cartas activo — Buscar, Descartar, etc.") consultaba
`_main._selection.is_active` y `_main._selection.confirm_button`. `_main._selection` es
`SelectionModule` (`scripts/ui/selection/SelectionModule.gd`), cuyas únicas variables son
`_main`, `_pending_exhume_player_id`, `_pending_search_player_id` y
`_pending_search_callback` — nunca tuvo `is_active` ni `confirm_button`. El panel real de
selección (SelectionCanvas) vive en el autoload `SelectionManager`
(`scripts/core/effects/targeting/SelectionManager.gd`), con `var is_open: bool` (línea 61)
y `var _confirm_button: Button` (línea 75, privada por convención). Corregido a
`SelectionManager.is_open` / `SelectionManager.get("_confirm_button")` — este último usando
`.get()` para respetar la convención ya vista en el resto del proyecto para acceder a esa
propiedad privada desde afuera del script.

### 10.34 Descarte por límite de mano (fin de turno, DAR 5.D.4) convertido a click directo

**2026-09-13, a pedido del usuario** ("al momento de descartar cartas por exceso... igual
quiero que sea sin modulo/módulo"): `PhaseFlowController._enforce_hand_limit()` llamaba a
`SelectionModule.open_discard_selection()`, que abría el modal viejo de
`SelectionManager.open_selection(..., SelectionMode.DISCARD)` con lista/grilla en vez de
las cartas reales de la mano. Es exactamente el mismo caso que el resto de descartes de
mano ya convertidos esta sesión (§10.16 y siguientes) — la mano propia es información
totalmente visible para su dueño, no hay nada que ocultar, así que corresponde click
directo, no modal.

Se agregó `PhaseFlowController._discard_excess_by_click(amount)`, que reusa el helper ya
existente y compartido `TriggerSystem._select_hand_cards_for_discard()`
(`TargetedEffectExecutor.gd`, el mismo usado por los otros 6 llamadores de descarte de
mano) con `cancellable=false` — el límite de mano es obligatorio, no un costo opcional, así
que ESC no debe permitir descartar de menos. Se eliminó `SelectionModule.
open_discard_selection()` por quedar sin ningún llamador real (confirmado por grep; solo
quedaban menciones en comentarios de `ActionSearch.gd` y `ActionReturnDiscard.gd`,
actualizadas para no apuntar a una función borrada).

Nota: el descarte automático del oponente (`_opponent_auto_discard()`, elige las más caras
sin intervención del jugador) no se toca — nunca usó modal.

### 10.35 Bug real reportado por el usuario: click izquierdo no funcionaba sobre Aliados rivales al elegir objetivo

**2026-09-14.** Jugando a Capitán O'Brien (ETB: "puedes convertir un Oro o una carta de
coste 2 o menos... del mismo tipo sin habilidad", objetivo propio O enemigo por texto), el
click izquierdo sobre el Aliado del rival no hacía absolutamente nada — ni siquiera
aparecía el mensaje de "objetivo no válido". El usuario tuvo que targetear su propio
Capitán O'Brien (coste 1, calza el filtro) para poder seguir jugando, terminando por
convertirse/silenciarse a sí mismo sin querer.

Aparte, el usuario preguntó por qué el log decía "capitan obrien entró al juego con 2
triggers" si "tiene 1". **Esto NO es un bug** — se confirmó contra la caché real de
cartas (`card_cache/cards.json`) que el texto completo es: "Cuando entra en juego, puedes
convertir un Oro o una carta de coste 2 o menos... " + "**En tu Fase Final**, puedes
Barajar y/o Desterrar tantas cartas de los Cementerios como Fuerza tenga este Aliado." Son
dos disparadores reales (`on_enter_play` + `on_turn_end`); el segundo simplemente no se
había disparado todavía en la partida reportada.

**Causa raíz del bug de targeting:** `CardInteraction.on_gui_input()` corta CUALQUIER
click izquierdo por completo si `can_interact` es `false` (línea "Otras interacciones
requieren can_interact") — el evento nunca llega a `CardInteractionModule._on_card_clicked()`,
así que ni el filtro de la habilidad ni el mensaje de error llegan a ejecutarse nunca. Las
cartas PROPIAS quedan `can_interact = true` apenas terminan de entrar en juego (ver
EasyBotController.gd para el lado rival — también debería quedar en true tras la animación
de entrada), pero `await_target()`/`start_target_selection()` (`CardInteractionModule.gd`)
nunca garantizaban ese estado por sí mismos para ningún candidato del rival en el momento
de la selección — a diferencia de los pickers de mano/Cementerio/Destierro, que sí fuerzan
`can_interact = true` explícitamente al construir sus nodos (temporales o reales). Esto no
es exclusivo de Capitán O'Brien: afecta a TODA habilidad "elige una carta en juego, propia
o enemiga" que use `await_target()`/`await_multi_target()` con un filtro de tablero
(Convertir, Destruir/Anular/Desterrar por coste, Buff/Debuff dirigido, elegir portador de
Arma, orden de disparadores simultáneos de `TriggerSystem._prompt_trigger_order()`, etc.).

**Fix:** `CardInteractionModule.gd` — nuevo `_force_board_interactable()`, llamado desde
`start_target_selection()` (por lo tanto cubre tanto `await_target()` como cada pick de
`await_multi_target()`): recorre las 10 zonas de campo estándar de ambos jugadores
(Defensa/Ataque/Apoyo + Reserva/Pagado de Oro) y fuerza `can_interact = true` en toda
carta que no lo tuviera ya, guardando cuáles se tocaron en `_forced_interact_cards`. Su
contraparte `_restore_board_interactable()` las devuelve a su valor real al cerrar la
selección — se llama en los 3 puntos de salida: `_resolve_target_selection()` (pick
válido), `cancel_target_selection()` (ESC) y la rama de "seleccionar todo" de
`await_multi_target()`. No evalúa el filtro de la habilidad al forzar (barrido amplio a
propósito) — el filtro real se sigue aplicando igual al clickear, así que forzar de más
solo habilita el click en cartas que de todos modos van a rechazarse con el mensaje normal
de "objetivo no válido", en vez de quedar completamente mudas como hasta ahora.

### 10.36 Cierre del barrido §10.14: últimos 11 sitios (5 archivos) + `open_reveal_picker()` nuevo

**2026-09-14.** Quedaban 11 usos de `SelectionManager.await_single_pick()`/`await_multi_pick()`/
`open_selection()` sin convertir en 5 archivos, detectados con un grep de barrido
(`await_(single|multi)_pick` + `open_selection` en `scripts/core/effects/triggers/`) tras
retomar la sesión. Migrados los 11, más uno de más que el primer grep no había agarrado
(`SearchOwnZonePatterns.gd`, usaba `open_selection` directo, no el wrapper).

**Pieza nueva: `ZoneViewerModule.open_reveal_picker(prompt, data_list, owner_id, filter,
max_count, cancellable)`.** Los patrones "Mira"/"Muestra N cartas del tope de tu Castillo"
no tenían ningún Nodo real que clickear (a diferencia de mano/Cementerio/campo, que sí lo
tienen) — el dato revelado vive solo como `Dictionary` suelto hasta que el jugador elige.
Mismo mecanismo que `open_cemetery_target_picker()` (§10.14) pero de un solo pool (no hay
"lado rival" para el propio Castillo mirado): arma Nodos `Card` TEMPORALES a partir de
`data_list`, delega en `await_target()`/`await_multi_target()` para el click + brillo, y
devuelve `Array[Dictionary]` (no Nodos — la fuente de verdad sigue siendo el dato, los Nodos
se destruyen con el popup). `max_count == 1` usa `await_target()`; cualquier otro valor usa
`await_multi_target()` (pasar `cancellable=false` para forzar exactamente `max_count`, igual
que el viejo `min=max=N/can_cancel=false`).

**Archivos migrados:**
- `DSR_SearchGoldCombos.gd` (Shiji, 1/1): pool combinado mano+Cementerio — NO usa
  `open_reveal_picker()` (esas cartas no son "reveladas", ya están en una zona real);
  reusa el patrón local de popup-de-Cementerio-propio ya establecido por Golpe Solar
  (`DSR_DiscardChoicePatterns.gd`).
- `LookRevealPatternsA.gd` (6/7): `_resolve_look_pick_hand_only()` (Tesoro de los Césares),
  `_resolve_look_pick_hand_and_mill()` (Signo Amarillo, 2 picks: mano + Cementerio),
  kitsune-sp (mano rival — Nodos reales, sin popup, `await_target()` directo), Tangata Manu
  y Perder la Razón (ambos con `is_eligible`/`is_pickable` de tipo `Callable(Dictionary)`,
  envueltos en `Callable(Node)` para `open_reveal_picker()`). **Queda 1 sin convertir a
  propósito**: `try_execute_look_play_or_hand_pattern` (Presente) inyecta un tercer botón
  custom ("Poner en tu mano") al panel de `SelectionManager` que `open_reveal_picker()` no
  soporta (solo pick-por-click puro) — mismo criterio de complejidad real que Duelo de
  Dragones/Ofrendas al Dragón (§10.9 del diseño de pila de respuesta), documentado inline.
- `LookRevealPatternsB.gd` (3/3): Duelo de Dragones (mano rival, Nodos reales — el resto de
  esa función ya estaba resuelto, ver diseño de pila de respuesta §"Ampliación 2026-09-10"),
  akari (elegir 1 de hasta 3 tipos encontrados), gran kraken (elegir 1 Aliado de coste 1 de
  hasta 3 revelados).
- `SearchOwnZonePatterns.gd` (2/2): Danza de Dragones (Cementerio propio, reusa
  `open_cemetery_target_picker()` con filtro `owner_id == controller_id` — NO
  `open_reveal_picker()`, esa carta sí está en una zona real); asedio naval ("mismo tipo que
  la primera elegida" resuelto con `lock_group_key` de `await_multi_target()`, mismo
  mecanismo que ya usa Hanta el Samurai para "un solo Cementerio" — popup local de
  Cementerio propio, no `open_reveal_picker()`).
- `ShuffleDrawPatterns.gd` (2/2): Caín — buscar hasta 2 en TODO el mazo (no solo el tope) vía
  `open_reveal_picker()` igual que un reveal-del-tope (la función ya sacaba `matching` como
  `Dictionary` sueltos del mazo completo, sin Nodo real; `open_reveal_picker()` no distingue
  "tope" de "mazo completo", solo pinta lo que se le pasa) + elegir cuál de las 2 jugar.

**Regla para decidir `open_reveal_picker()` vs. popup local vs. Nodos reales** (mismo
espíritu que la regla de §10.29 para zonas): si las cartas YA están en una zona real con
Nodo persistente (mano, campo) → Nodos reales, sin popup. Si están en una zona real sin Nodo
visible (Cementerio, Destierro) → `open_cemetery_target_picker()` (dos lados) o el popup
local de un solo lado ya establecido por Golpe Solar (mano+Cementerio combinado, o
Cementerio propio con `lock_group_key`). Si NO hay zona real todavía (reveladas del
Castillo, recién sacadas con `pop_front()`/`slice()`) → `open_reveal_picker()`.

### 10.37 Bug real reportado por el usuario: La Ouija no refrescaba el tope revelado al buscar/botar

**2026-09-14.** El usuario pidió: "cada vez que la primera carta del mazo se vaya ya sea
robando o interactuando con el castillo, se muestre la siguiente primera". La Ouija
(`ZoneViewerModule.refresh_castillo_top_reveal()`, §"Revelado del tope del Castillo" en la
sección 1) ya existía desde 2026-08-31, pero solo se refrescaba de verdad en ALGUNOS caminos
que tocan el mazo, no en todos — auditados los ~8 verbos/caminos reales que remueven o
reordenan el tope (índice 0) del `player_deck`:

- **Robo normal** (`ZoneManager.draw_card()`) — YA llamaba `_update_castillo_counts()`. Sin bug.
- **`ActionModule.draw()`** (65 llamadores) — cae siempre en `EffectController._draw_cards_
  fallback()` (`_validate_board()` devuelve `false` siempre, GameBoard legacy muerto), que
  delega en `ZoneManager.draw_card()` de arriba. Sin bug.
- **`ActionSearch.search()`** (la función real detrás de ~36 llamadores de "busca en tu
  Castillo") — **BUG real**: removía cartas de `zone_data`/barajaba el resto tras buscar, sin
  llamar nunca a `_update_castillo_counts()`. **Arreglado**: se agregó la llamada al final de
  `search()`, guardada a `zone == Constants.Zone.CASTILLO`.
- **`ActionModule.shuffle_deck()`** (wrapper genérico usado por 5 sitios directos, p.ej.
  `PreventionAbilityHandler_PV.gd`, `GoldManager.gd`) — **BUG real**: barajar no cambia el
  TAMAÑO del mazo pero sí qué carta queda en el índice 0, y `CardManager.shuffle_deck()` no
  emite ninguna señal. **Arreglado**: `ActionModule.shuffle_deck()` ahora llama
  `_update_castillo_counts()` directo tras barajar — único punto de verdad para todos sus
  llamadores, actuales y futuros.
- **`CardManager.take_damage()`** (alias `mill_cards()` — daño de combate normal Y el verbo
  "Botar N cartas" vía `EffectController._mill_cards_fallback()`, rama Cementerio) — saca del
  tope real (`pop_front()`, corregido 2026-08-30) pero solo llamaba `_update_deck_visual()` →
  `_emit_deck_changed()` → señal `deck_count_changed` (el NÚMERO del contador, vía
  `UIManager.update_castillo_count()`) — nada escuchaba esa señal para refrescar el revelado
  del tope. **BUG real, el más frecuente de los tres** (daño de combate pasa todo el tiempo).
- **`SearchAbilityHandler_JV.gd._activate_quimera_voragh_mill_and_revive()`** — mismo síntoma
  que `take_damage()` (llama `CardManager._emit_deck_changed()` manual, misma señal sin
  escucha).
- Casos que remueven del FONDO (`pop_back()` — Asmodeus/Belcebú en `SearchAbilityHandler_
  AI.gd`, rama Destierro de `_mill_cards_fallback()`) — no afectan el índice 0, no hacía falta
  tocarlos.

**Arreglo elegido — punto de verdad centralizado en vez de parchear cada sitio**: en vez de
agregar `_update_castillo_counts()` a mano en cada función que ya llama `CardManager.
_emit_deck_changed()` (y a cualquier función futura que use esa misma convención), se conectó
la señal `CardManager.deck_count_changed` directo a `refresh_castillo_top_reveal()` en
`ZoneViewerModule._ready()`-equivalente (mismo bloque donde ya se conectan `cemetery_count_
changed`/`exile_count_changed`) — cubre `take_damage()`/`mill_cards()`/quimera voragh de una
sola vez, sin duplicar la llamada en cada sitio (se probó primero a mano en
`SearchAbilityHandler_JV.gd` y se revirtió al conectar la señal, para no dejar dos caminos
haciendo lo mismo). `ActionSearch.search()` y `ActionModule.shuffle_deck()` SÍ necesitaron su
propio arreglo puntual porque ninguno de los dos emite `deck_count_changed` — tocan el Array
del mazo directo sin pasar por la convención de señales de `CardManager`.

### 10.38 Bug real reportado por el usuario: `_main.<propiedad>` en `TargetedEffectExecutor._select_hand_cards_for_discard()`

**2026-09-14.** Error en consola: "Invalid access to property or key '_card_interaction' on a
base object of type 'Node (TriggerSystem.gd)'", reportado con la pista "problemas en
phaseflowcontroler targeteffectexecutor triggersystem" — coincide exacto con la cadena real:
`PhaseFlowController.gd:501` → `TriggerSystem._select_hand_cards_for_discard()` (forwarder) →
`TargetedEffectExecutor._select_hand_cards_for_discard()`. Mismo patrón de bug de §2: para
`TargetedEffectExecutor`, `_main` ES `TriggerSystem` (`TriggerSystem._ready()`:
`_targeted_executor.setup(self)`), no el Main real — esta función (agregada 2026-09-13 en la
migración de picker modal → click directo) usaba `_main._card_interaction` directo, a
diferencia de las otras ~14 funciones del mismo archivo que sí resuelven primero `var main :=
_main.get_node_or_null("/root/Main")`. **Arreglado**: se agregó esa misma resolución antes de
usar `main._card_interaction`.

### 10.39 Espada de O'Higgins: elección A/B convertida a carrera de click directo

**2026-09-14, a pedido del usuario.** `_activate_espada_ohiggins_shuffle_or_search_gold()`
(`PreventionAbilityHandler_AE.gd`) preguntaba antes "¿Barajar una carta / Buscar un Oro?" con
`SelectionManager.await_two_choice()`. Cambiado a `CardInteractionModule.await_target_or_
castillo_pick()` (mismo mecanismo ya extraído para Sherlock Holmes/La Ouija, §10.14): el
Castillo PROPIO brilla como objetivo clickeable (rama "buscar un Oro") al mismo tiempo que las
cartas en juego que no sean Oro brillan como objetivo (rama "barajar") — el primer click real
decide, sin preguntar antes. `castillo_own_only=true` (el texto dice "tu Castillo", posesivo).
El resto de la lógica de cada rama (filtro de zona vía `current_zone`, ventana de respuesta
solo en la rama de buscar — `return_to_deck()` ya consulta Prevención internamente, no hace
falta duplicarla) se mantuvo igual, solo cambió CÓMO se elige entre las dos.

### 10.40 Bug real reportado por el usuario: `actualizar_aspecto()` llamado antes de que la carta entre al árbol (`SelectionDialogs.await_card_pair_choice()`)

**2026-09-14.** Error: "Invalid call. Nonexistent function '_apply_pending_data' in base
'Nil'", con la pista "triggerresolution selectiondialog cardgd" — cadena real:
`TriggerResolution.gd` → `DrawShuffleResolver.gd` (facade) →
`DSR_SearchGoldCombos.try_execute_deck_top_or_bottom_to_hand_pattern()` (La Ouija: "pon la
primera o la última carta de tu Castillo en tu mano") → `SelectionManager.await_card_pair_
choice()` → `SelectionDialogs.await_card_pair_choice()` → su helper interno `build_slot()`.

**Causa**: `build_slot()` instancia una carta temporal (`CardScene.instantiate()`) para
mostrarla en el popup de "elegí cuál de las dos" y llamaba `card_inst.actualizar_aspecto()`
EXPLÍCITO, ANTES de `card_box.add_child(card_inst)` — en ese momento `Card._ready()` todavía no
corrió (no está en el árbol de escena todavía), así que `_image_loader` (creado solo en
`_ready()`, línea ~411 de `Card.gd`) sigue siendo `null`, y `actualizar_aspecto()` revienta al
intentar `_image_loader._apply_pending_data()`.

**Arreglo**: se sacó el llamado explícito — no hacía falta: `Card.load_from_data()` (llamado
antes, línea 210) ya deja `card_data`/`esta_oculta`/`current_zone` seteados, y `Card._ready()`
YA llama `actualizar_aspecto()` por su cuenta al final (línea 468) usando esos mismos valores,
apenas la carta entra al árbol vía `add_child()` (que en Godot corre `_ready()` sincrónico si
el padre ya está en el árbol — aquí sí lo está, la cadena de contenedores del popup cuelga de
`main`). Mismo patrón ya usado correctamente en el resto del proyecto (`OpponentFan._init_
card()`, `ZoneManager.draw_card()`/`_animate_player_card_draw()`): `add_child()` SIEMPRE antes
de cualquier llamado explícito a `actualizar_aspecto()`. Se auditaron los otros ~6 sitios que
llaman `actualizar_aspecto()` explícito en todo el proyecto — todos ya respetan ese orden, este
era el único que lo invertía.

### 10.41 Bug real reportado por el usuario: Bernardo — pantalla "borrosa" y sin respuesta tras elegir "Desterrar"

**2026-09-14.** Al activar Bernardo O'Higgins y elegir "Desterrar una carta de coste 3 o
menos" en su diálogo de elección de efecto, el juego quedaba con la pantalla borrosa y sin
responder a ningún click.

**Causa**: `BernardoAbilityHandler._show_bernardo_effect_choice()` llama `mark_inspection_
layer_in_use()` (§10.14/CardInspectionLayer.gd) para forzar `_main.inspection_layer.visible =
true` — necesario porque `close_card_inspection()` (llamado ANTES, al presionar el botón de
Bernardo) ya había apagado esa capa con su tween diferido de ~0.2s para cuando este diálogo se
arma (el jugador tarda más que eso eligiendo qué Arma/Aliado barajar como coste). El problema:
nada volvía a apagar `inspection_layer` después — la única función que lo hace
(`close_card_inspection()`) ya se había ejecutado una vez entera y no se vuelve a llamar. La
capa (con su blur de pantalla completa, `mouse_filter` en modo que intercepta clicks vía
`_on_inspection_blur_input()`) seguía tapando la pantalla y tragándose cada click — inclusive
los que el jugador daba sobre una carta real del tablero para elegir el objetivo a Desterrar
(`_bernardo_banish_target()`, que sí abre su propio `await_target()` correctamente, pero nunca
recibía el click porque el blur lo interceptaba antes).

**Arreglado**: nueva función `CardInspectionLayer.release_inspection_layer_if_unused()`
(contraparte de `mark_inspection_layer_in_use()`, mismo criterio de guardia — no apaga la capa
si mientras tanto se abrió una inspección real nueva), llamada en
`_activate_bernardo_shuffle_removal()` justo después de resolver la elección Desterrar/Cancelar
y antes de empezar la selección de objetivo en el tablero.

### 10.42 Bug real reportado por el usuario: ¿Paso? bypaseaba una selección de objetivo pendiente y congelaba fases futuras

**2026-09-14.** Log real del usuario: tras "Elige un Oro o una carta de coste 2 o menos para
Convertir" (`TargetedEffectExecutor._execute_targeted_convert()`, disparado por un patrón
CONVERT_ORO_OR_LOW_COST), el jugador presionó ¿Paso? sin clickear un objetivo. La fase terminó
de pasar prioridad igual, y varias fases después (Bloqueo → Guerra de Talismanes) quedó
"pegada" — `[DIAG] _on_priority_both_passed_main: BLOQUEADO por awaiting_response=true`.

**Causa**: `await main._card_interaction.await_target(prompt, filter)` no tiene (ni debería
tener) timeout — es una decisión humana real, a diferencia de la espera mecánica de
`ActionPipeline.add_triggered_ability_to_stack_and_await()` (§ Pila de Respuesta Universal, que
sí tiene un timeout de 8s porque ESA espera es puramente interna del motor). El problema real es
otro: nada impedía presionar ¿Paso? mientras `CardInteractionModule.is_selecting_target` seguía
en `true` — el jugador podía "saltarse" la selección pendiente sin cancelarla (ESC si la
habilidad lo permite) ni resolverla. El `await_target()` original queda vivo para siempre en
segundo plano, así que `TriggerResolution.resolve_next_trigger()` nunca vuelve de
`_execute_trigger_effect()`, `TriggerSystem.awaiting_response`/`is_resolving` quedan atascados
en `true`, y el guard de `_on_priority_both_passed_main()` (que SÍ hace su trabajo, evitar
doble-resolución) bloquea correctamente pero para siempre — cualquier fase futura que dependa de
"ambos pasaron" queda pegada.

**Arreglo elegido (consultado con el usuario, opción preferida sobre auto-cancelar la
selección)**: se bloquea en la raíz — `PhaseFlowController._on_paso_pressed()` ahora rechaza de
entrada (con mensaje en debug) si `_main._card_interaction.is_selecting_target` es `true`,
antes de tocar `PriorityManager`/cualquier lógica de fase. Cubre tanto el click del botón como
el atajo de teclado Q (`DebugInputModule.gd`, ambos caminos llaman la misma función). El
jugador tiene que resolver el objetivo pendiente o cancelarlo con ESC (si la habilidad es
opcional) antes de poder pasar.
**Nota**: esto solo previene el cuelgue en partidas NUEVAS — una partida ya atascada por este
bug (como la del reporte) necesita reiniciarse, no hay forma de destrabar `awaiting_response`
retroactivamente desde este fix.

### 10.43 Bug real reportado por el usuario: NINGUNA carta del rival era objetivo válido (en toda habilidad)

**2026-09-14.** Reporte del usuario: "hago objetivo a mi carta y funciona, a las del rival no —
lo mismo de siempre, en cualquier habilidad." Diagnóstico con un print temporal en
`CardInteraction.on_gui_input()` confirmó: el click SÍ llegaba a la carta del rival
(`can_interact=true`), pero no pasaba nada — sin mensaje de "objetivo no válido" ni ningún otro
rastro.

**Causa real**: `ZoneManager.draw_card()` — la función real detrás de CADA robo del rival,
incluida la mano inicial completa (`draw_initial_hand()` solo la llama en loop) — conecta
`_main._connect_card_signals(card)` en la rama del jugador 0, pero NUNCA en la rama del
jugador 1 (oponente). `card_clicked`/`card_double_clicked`/etc. quedaban sin NINGÚN listener
conectado desde el instante en que la carta se roba — el mismo Node se reparenta después de la
mano al campo sin ganar la conexión que nunca tuvo. El click emitía la señal igual (por eso
`can_interact` y el resto del pipeline de `on_gui_input()` se veían bien en el diagnóstico), pero
al vacío: nadie escuchaba, así que `CardInteractionModule._on_card_clicked()` nunca se enteraba.
Mismo patrón (rama jugador 1 sin `_connect_card_signals()`) encontrado y arreglado en 2 sitios
más, mucho menos frecuentes: `ActionSearch._put_found_card_into_play()` (buscar y poner en la
mano del rival) y `LookRevealPatternsB.try_execute_look_two_hand_convert_gold_pattern()`
(revelar 2 del tope a la mano del rival).

**Por qué "siempre" y con cualquier habilidad**: es infraestructura central de un solo punto de
entrada — arreglar `ZoneManager.draw_card()` cubre absolutamente TODA carta que el rival haya
robado alguna vez (mano inicial + cada robo normal de cada turno), sin importar qué habilidad
la use como objetivo después.

### 10.44 Bug real reportado por el usuario (mismo repro): el freeze de "Convertir" sobrevivió al fix de ¿Paso?

**2026-09-14, mismo día que §10.42.** El usuario confirmó haber reiniciado Godot después del fix
de `_on_paso_pressed()` y el freeze de "Elige un Oro o una carta de coste 2 o menos para
Convertir" → `awaiting_response` atascado volvió a pasar IDÉNTICO. Causa real: el "Jugador 1 pasa
prioridad" del log no viene del botón ¿Paso? (no hay ningún "[Main] Paso: ..." antes en el log) —
viene de `PhaseFlowController._human_pass_after()`, un auto-pase por TIMER (0.2s) que
`_on_priority_changed_glow()` agenda cada vez que la prioridad te llega en contexto
RESPONSE_WINDOW, pensado para "no hay nada real que decidir aquí". Ese auto-pase solo miraba
`PriorityManager.suppress_human_autopass` (el mismo flag que ya usa `ResponseWindowHandler.
_offer_signo_amarillo_for_step_d()` para su propio diálogo de Signo Amarillo) — pero nada lo
ponía en `true` mientras un `await_target()` de verdad estaba esperando un click, así que el
auto-pase de 0.2s le pasaba por encima igual, justo cuando la ventana Paso D del propio trigger
coincidía en el tiempo con la selección de objetivo de su efecto.

**Arreglo real (más de raíz que el de §10.42)**: `CardInteractionModule.start_target_selection()`
ahora pone `PriorityManager.suppress_human_autopass = true` al abrir CUALQUIER selección de
objetivo, y `_resolve_target_selection()`/`cancel_target_selection()` lo devuelven a `false` al
cerrarla — cubre no solo el auto-pase de `_human_pass_after()` sino cualquier otro camino que ya
respete (o llegue a respetar) ese mismo flag compartido. El fix de §10.42
(`_on_paso_pressed()` rechaza el click manual) queda como defensa en profundidad, no redundante:
cubre el caso de que el jugador SÍ alcance a clickear ¿Paso? antes de que este auto-pase por
timer dispare solo.

### 10.45 `await_target()` no tenía NINGÚN indicador visual de candidatos (a diferencia de `await_multi_target()`)

**2026-09-15.** Tras los fixes de §10.43 (conexión de señales del rival), el usuario reportó otro
intento con Capitán O'Brien donde "no brilló ninguna carta del rival" — pero el log mostraba que
terminó convirtiendo su PROPIA carta (`capitan obrien`, owner=0) sin problema. Investigando:
`await_target()`/`start_target_selection()` (usada por `_select_convert_target()` y decenas de
otras funciones de un-solo-objetivo) **nunca tuvo ningún indicador visual de "esto es un
candidato válido"** — a diferencia de `await_multi_target()`, que sí prende el brillo celeste
(`CardBadges.set_activatable()`) en sus candidatos. Esto es cierto para AMBOS lados, propio y
rival — por eso la propia carta del usuario tampoco brillaba, solo se veía el hover normal.
Conclusión: "no brilló" no era necesariamente evidencia de que el bug de señales volviera; podía
ser simplemente que el rival no tuviera ningún Oro/carta de coste ≤2 en juego en ese momento, sin
forma de distinguirlo a simple vista de un bug real.

**Arreglo**: `CardInteractionModule._glow_valid_targets(filter)`/`_unglow_target_cards()`
(nuevas) — barren las mismas 10 zonas de tablero de `_force_board_interactable()` más
mano/abanico rival, evalúan el filtro REAL (a diferencia de `_force_board_interactable()`, que
fuerza `can_interact` de más a propósito sin mirar el filtro), y prenden/apagan el mismo brillo
celeste que ya usa la selección múltiple. Llamado solo desde `await_target()` (no desde
`start_target_selection()` en sí, para no pisar el manejo de brillo más fino que ya tiene
`await_multi_target()` con `lock_group_key`/`dynamic_filter` puertas adentro). Con esto, de aquí
en más, si una carta rival es un objetivo legal SIEMPRE va a brillar — su ausencia de brillo deja
de ser ambigua.

### 10.46 Brillo de `set_activatable()` con color según motivo (celeste/rojo/dorado)

**2026-09-15, a pedido del usuario.** El brillo de §10.45 (y el de `await_multi_target()`) era
SIEMPRE dorado, sin importar el motivo — mismo color para "tienes una habilidad activable
disponible" (`CardInspectionLayer.refresh_activatable_glows()`), "objetivo válido de una
selección" y "orden de tus triggers ya disparados" (`TriggerSystem._prompt_trigger_order()`).
Ahora distingue:

- **CELESTE** (`CardBadges.GLOW_COLOR_CELESTE`) — objetivo válido PROPIO de una selección en curso.
- **ROJO** (`CardBadges.GLOW_COLOR_RED`) — objetivo válido RIVAL.
- **DORADO** (`CardBadges.GLOW_COLOR_GOLD`, el color de siempre, ahora con nombre) — todo lo que
  NO es "elegir un objetivo propio/rival": habilidad activable disponible, y orden de triggers
  propios ya disparados.

**Implementación**: `CardBadges.set_activatable(value: bool, glow_color: Color = GLOW_COLOR_GOLD)`
ahora recibe el color y lo reaplica al StyleBoxFlat compartido del panel en cada llamado con
`value=true` (incluso si la carta ya estaba brillando por otro motivo — importa para el caso real
de una carta con habilidad activable, dorada, que además pasa a ser objetivo rival de otra
selección concurrente: debe pasar a rojo, no quedarse dorada). `CardInteractionModule.
_glow_color_for_owner(c)` (celeste si `owner_id == 0`, si no rojo) alimenta tanto `_glow_valid_
targets()` (single-target, §10.45) como los 3 sitios de `await_multi_target()` que prenden/
reevalúan brillo. `await_multi_target()` suma un parámetro opcional `glow_color_override` — si se
pasa, fuerza ese color para TODOS los candidatos sin importar dueño (usado por `_prompt_trigger_
order()` para forzar dorado, ya que ahí no se está eligiendo un objetivo propio/rival sino un
orden). `refresh_activatable_glows()` no cambió — sigue sin pasar color, default dorado.

### 10.47 Diadema Celestial: patrón faltante ("no disparó la diadema")

**2026-09-15.** Texto real (sacado de la caché local, `user://card_cache/cards.json`): "Cuando
entra en juego, muestra cartas del tope de tu Castillo hasta mostrar un Aliado y un Talismán y
ponlos en tu mano." — sin patrón propio, no resolvía nada. Nuevo `try_execute_reveal_until_ally_
and_talisman_pattern` en `LookRevealPatternsB.gd`, mismo molde que `try_execute_reveal_until_
ally_and_weapon_pattern` (metalmorfo), Talismán en vez de Arma. Las otras 2 cláusulas de la carta
(Aliados bloqueadores ganan Fuerza/rival pierde Imbloqueable; Destierro al Botarse por daño)
quedan sin cubrir — no se pidieron, no se tocaron.

### 10.48 Capitán O'Brien (segunda pasada): falso-positivo real confirmado + patrón nuevo

**2026-09-15.** Confirmado con la caché local: "En tu Fase Final, puedes Barajar y/o Desterrar
tantas cartas de los Cementerios como Fuerza tenga este Aliado" caía por error en
`try_execute_shuffle_up_to_n_cemeteries_pattern` (Tamales, solo Barajar — `"puedes barajar"` es
substring literal de la frase real). Se tapó el hueco en ambos sentidos
(`try_execute_shuffle_up_to_n_cemeteries_pattern` ahora excluye `"desterrar"`,
`try_execute_banish_up_to_n_cemeteries_pattern` excluye `"barajar"`, simétrico) y se agregó
`try_execute_shuffle_or_banish_cemeteries_equal_to_strength_pattern` (`DSR_CemeteryBanishDraw.
gd`) — cantidad dinámica vía `ContinuousEffectManager.get_modified_strength(card)`, reusa
`GoldManager._resolve_armeria_barajar_desterrar()`.

### 10.49 `Invalid operands 'String' and 'int' in operator '!='` — ModifierRegistry

**2026-09-15.** `_get_base_stat()`'s rama genérica (`_:`, para cualquier stat que no sea
strength/cost/damage) devolvía `card.get(stat)` crudo pese a estar declarada `-> int` — si esa
propiedad de la carta guardaba un String, se colaba sin castear. Ese valor terminaba cacheado en
`_previous_values`/`_calculated_cache` y comparado con `!= -999` en `_get_modified_stat()`,
reventando. Arreglado en los dos puntos: la rama genérica ahora castea (con `push_warning()` si
detecta un String, dejando rastro de qué `stat`/carta lo causó) y la lectura de `previous_value`
también castea defensivamente. **No se confirmó la causa raíz exacta** (qué stat/carta puso el
String ahí primero) — el `push_warning` nuevo es la pista real si vuelve a pasar.

### 10.50 Talismanes de respuesta instantánea bloqueados en el turno rival (pese a estar diseñados para eso)

**2026-09-15, a pedido del usuario: "integrar el sistema de respuestas... que pueda responder
cartas rivales como estaba planeado".** `_is_response_only_talisman()` (Red de Plata, Sacrificio
Solar, etc.) ya tenía exención de fase (`GoldManager.play_card()` línea ~519) y de ventana de
prioridad (línea ~534) para poder jugarse "en cualquier momento en que el jugador tenga la
palabra" (comentario propio de 2026-09-06) — pero el chequeo `GameManager.active_player_id != 0`
("No es tu turno", línea ~523) NUNCA tuvo esa misma excepción, y bloqueaba a CUALQUIER Talismán de
respuesta durante el turno del rival — exactamente el único caso de uso real que tienen. El mismo
chequeo, duplicado, existía TAMBIÉN en `CardInteractionModule._on_card_double_clicked()` (el
gateo de UI que corre ANTES de llegar a `GoldManager.play_card()`), con el mismo hueco. Arreglados
los dos, mismo criterio: `and not is_instant_response`/`is_instant_response_talisman`.
`ActionPipeline.can_activate_ability()` ya estaba bien (fix de 2026-09-10, sin bloqueo por turno)
— confirmado que las habilidades activadas sí se pueden usar en el turno rival hoy.

### 10.51 §10.11 caso 4 implementado: botón de Anular/Cancelar visible en turno rival

**2026-09-19, a pedido del usuario.** Cerrada la brecha conocida documentada en §10.11:
`CardInspectionLayer._build_ability_buttons()` cortaba con `if GameManager.active_player_id
!= 0: return` ANTES de llegar a evaluar ninguna habilidad — ningún botón ACTIVATED se
mostraba en turno rival, ni para Bernardo O'Higgins ni Akari. El backend
(`ActionPipeline.can_activate_ability()`, fix 2026-09-10) y `AbilityButtonSupport.
_validate_ability()` (línea 29: `if PriorityManager.priority_window_active and not
PriorityManager.can_act(0)`) ya soportaban correctamente activar en una ventana de
respuesta del turno rival — el único bloqueo real era este gate de UI, un piso antes.

**Arreglo, en dos partes:**
1. El gate temprano ahora solo corta si es turno rival Y ADEMÁS no hay ventana de
   prioridad real con `PriorityManager.can_act(0)` — si ambas se cumplen, sigue de largo
   (mismo criterio que `has_priority_window` unas líneas más abajo en la misma función,
   ahora redundante pero inofensivo en ese punto).
2. Nueva `AbilityButtonSupport._is_annul_or_cancel_ability(raw_text)` — mismo criterio de
   palabra que `GoldManagerRestrictions._is_response_only_ability_text()` (Talismanes de
   respuesta instantánea), pero `contains` en vez de `begins_with` porque aquí ya se opera
   sobre el `raw_text` de UNA sola habilidad aislada por `parse_abilities()`, no la carta
   completa con varias oraciones sin relación — el costo casi siempre precede a
   "anula"/"cancela" en la misma oración (p.ej. Akari: "Puedes Desterrarlo para Anular
   una carta..."), así que `begins_with` habría dado falsos negativos reales. Excluye
   frases de protección ("no puede ser anulada/cancelada") para no ofrecer el botón en
   una habilidad que blinda a la propia carta. En el loop de `usable_abilities`, en turno
   rival solo pasan las habilidades que matchean esta función; el resto de las ACTIVATED
   (p.ej. "Paga 1 Oro: roba una carta") no tiene sentido como reacción aunque
   técnicamente haya prioridad abierta.

**Caso borde encontrado y cerrado sin tocar el parser compartido:** Tótem Dragón
Ancestral ("**En tu turno**, puedes barajarlo para Anular un Aliado o Cancelar una
habilidad") es Anular/Cancelar por texto pero está restringido a tu propio turno — sin
embargo `UniversalCardParser` solo tagea `once_per_turn_own_turn_only` con la frase
exacta "**una vez** en tu turno" (con "una vez"), no con "en tu turno" a secas, así que
`_validate_ability()` no lo habría filtrado río abajo. Se agregó un chequeo local extra
en el mismo loop (`"en tu turno" in ability_lower`) en vez de ampliar el regex del
parser compartido — cambio más chico y sin riesgo de afectar otras ~148 cartas que ya
dependen de ese mismo parser.

**No tocado a propósito:** "Prevenir" no pasa por este botón — es reactivo, se resuelve
solo vía `EffectController._prevention_registry` al interceptar `destroy_card()`/
`exile_card()` (ver §3), sin gate de turno que arreglar aquí. Tampoco se tocó el chequeo
de "en tu Vigilia" (línea 46 de `AbilityButtonSupport._validate_ability()`, compara
contra `GameManager.current_phase` sin mirar `active_player_id`) — imprecisión
preexistente que en teoría podría colar una habilidad "en tu Vigilia" si el rival está
en SU propia Vigilia con una ventana de prioridad abierta, pero ninguna carta
Anular/Cancelar del catálogo usa esa frase hoy, así que no había caso real que arreglar.

**Sin verificar en partida real todavía** — cambio de lectura de código + revisión
cruzada contra `card_cache/cards.json` para los patrones de texto citados, pendiente de
que el usuario lo pruebe contra el bot.

### 10.52 §10.51 en la práctica era inútil: el auto-pase de Paso D pasaba en 0.2s, no daba tiempo a reaccionar

**2026-09-19, mismo día, a pedido del usuario** ("la idea es que cada vez que el oponente
haga algo, yo tenga 5 segundos donde pueda escoger si quiero responder o no, si no
quiero le doy a Paso"). Al investigar el pedido se encontró que el botón de Anular/
Cancelar recién habilitado en §10.51 quedaba prácticamente inservible: `PhaseFlowController.
_on_priority_changed_glow()` (línea ~232, la usa `_human_pass_after()`) programa un
auto-pase de la prioridad del humano en `RESPONSE_WINDOW` — pero SIEMPRE con un delay fijo
de **0.2 segundos**, sin mirar si había algo real para responder. Un humano no llega a
notar que un botón apareció y hacer click en 0.2s — Prevención (§3, `EffectController.
_ask_prevention_panel()`) siempre tuvo su propia ventana real de 5s con "Pasar", pero
Anular/Cancelar (vía el botón de habilidad) y los Talismanes de respuesta instantánea
(§10.50) dependían de este auto-pase genérico, que nunca distinguió "no hay nada que
decidir" (el caso real que este delay corto fue diseñado para cubrir, 2026-09-11) de
"SÍ hay algo, pero es fijo en 0.2s de todos modos".

**Arreglo — el delay ahora depende de si hay algo real para responder:**
- `CardInspectionLayer.refresh_activatable_glows()` pasó de `void` a `-> bool`: además de
  prender/apagar el brillo celeste como siempre, ahora retorna `true` si quedó al menos
  una carta brillando. Se le aplicó el mismo criterio Anular/Cancelar-only de §10.51 en
  turno rival (antes solo corría en tu propio turno — mismo gate roto que tenía
  `_build_ability_buttons()`, arreglado con el mismo patrón: `is_own_turn` +
  `_button_support._is_annul_or_cancel_ability()` + exclusión de `"en tu turno"`). Esto
  además resuelve un problema de USABILIDAD que §10.51 por sí solo no resolvía: sin este
  brillo, el jugador no tenía forma de saber QUÉ carta podía responder durante la ventana
  del rival sin inspeccionar una por una a ciegas.
- `PhaseFlowController._human_has_instant_response_talisman_in_hand()` (nueva) — barre
  `_main.player_hand.cards` buscando un Talismán de respuesta instantánea
  (`GoldManager._is_response_only_talisman()`, §10.50) que además sea pagable ahora
  (`PaymentManager.calcular_coste_real()` + `puede_pagar()`).
- `_on_priority_changed_glow()`: si `refresh_activatable_glows()` o la función de arriba
  devuelven `true`, el delay pasa a **5.0s** (mismo tiempo que ya usa el panel de
  Prevención, por consistencia); si no, se mantiene el 0.2s original de siempre — sin
  cambios para el caso mayoritario real donde no hay nada que decidir, que fue
  precisamente lo que motivó el delay corto en 2026-09-11.
- Rama `else` (la prioridad se va del humano) agregada: `_clear_all_activatable_glows()`
  además de apagar el brillo del botón ¿Paso?, para no dejar brillando una carta que ya
  no puede responder.

**No tocado a propósito:** Prevención sigue con su propio panel/timer independiente
(`_ask_prevention_panel()`) — no pasa por este auto-pase de Paso D en absoluto, así que
no necesitaba ningún cambio aquí (confirmado en §10.51, este fix es sobre Anular/Cancelar
y Talismanes de respuesta, no sobre Prevenir).

**Riesgo conocido, no verificado todavía:** este es el mismo mecanismo de timer/
`_window_generation` que causó los cuelgues reales de §10.44/§10.45 — el cambio es
solo en EL VALOR del delay (0.2 → 5.0 condicional), no en la lógica de generación/guard
que ya existía, así que en teoría hereda las mismas protecciones. Sin probar en partida
real todavía.

**Actualización — mismo día, revertido "de momento" contra el EasyBot, a pedido del
usuario:** tras probar en partida (log real: ventana de respuesta abre para Jugador 1,
pasa, prioridad va a Jugador 2/bot, ambos pasan, fase termina), pidió explícitamente que
"si estoy jugando contra el bot, de momento que pase de inmediato la prioridad" — no
tiene sentido hacerle esperar 5s reales al humano por una decisión que toma el EasyBot,
que además no tiene ninguna lógica real de "¿debería responder?" más allá de un `randf()
< 0.5` (ver `ResponseWindowHandler._bot_pass_after()`/`EffectController.
offer_prevention_for_player()`, rama `target_owner_id != 0`).

**Se revirtió el delay condicional (5.0/0.2) a un 0.2s fijo de nuevo**, pero SOLO dentro
de la rama que ya excluía `RemotePlayerController` — es decir, esto sigue sin tocar a un
oponente remoto real si algún día se conecta por esta misma rama (ver comentario nuevo
en el código, marca explícitamente dónde reactivar el delay condicional si corresponde).
`refresh_activatable_glows()` se sigue llamando igual (el brillo celeste informativo no
tiene costo ni hace esperar a nadie). `_human_has_instant_response_talisman_in_hand()`
queda SIN LLAMADOR a propósito — no se borró (ver docstring actualizado, mismo criterio
de "código huérfano con dueño futuro identificado" que evita confundirlo con el cluster
de §2) porque es la pieza reservada para cuando la espera real de 5s sí tenga sentido
(oponente remoto de verdad). El botón de Anular/Cancelar de §10.51 y el brillo celeste
siguen apareciendo contra el bot — solo que ya no fuerzan una espera de 5s para que el
humano llegue a usarlos; hoy dependen de que el humano ya tenga el mouse ahí o reaccione
rápido, igual que cualquier otra decisión durante Vigilia.

### 10.53 Ventana de respuesta universal por carta jugada/habilidad activada/disparada — bug real: el bot nunca la abría

**2026-09-19, mismo día, a pedido EXPLÍCITO y repetido del usuario** ("la idea es que el
sistema se abra por carta jugada o habilidad activada o disparada, nada de pensarlo con
cuidado, lo he dicho 20 veces"). Reportó dos bugs concretos primero:

1. **"No puedo jugar presente con el presente"** — arreglado por separado, ver abajo.
2. **"El bot jugó una carta y no me saltó la ventana para poder anular"** — confirmado que
   la carta era vainilla (sin habilidad de entrada). Investigación inicial concluyó
   (incorrectamente, corregido después) que esto podía ser DAR-correcto (Guerra de
   Talismanes como única ventana real para cartas sin disparador). El usuario cortó esa
   hipótesis en seco y pidió la ventana universal sin más discusión.

**Bug real encontrado al investigar (la pieza que faltaba):** `GoldManager._trigger_enter_play()`
(línea ~1358) YA abría `TriggerSystem.open_response_window()` para CUALQUIER Aliado/Arma/
Tótem/Oro que jugara el HUMANO desde 2026-09-10 (Pila de Respuesta Universal) — pero
`EasyBotController.gd` (el camino equivalente del BOT: `_play_ally()`,
`play_free_ally_from_data()`, `put_free_gold_in_pagado_from_data()`) nunca se actualizó
para hacer lo mismo. Mismo patrón que §10.1/§10.43 ("función que asume jugador 0" /
"rama jugador 1 sin la misma conexión que la rama 0") — no es un bug puntual de una
carta, es que el camino del bot entero nunca tuvo esta pieza.

**Arreglo — 3 partes:**

1. **`EasyBotController.gd`, 3 sitios** (`_play_ally()`, `play_free_ally_from_data()`,
   `put_free_gold_in_pagado_from_data()`): agregado `if await TriggerSystem.
   open_response_window(card, ..., 1): await EffectController.destroy_card(1, card, false);
   return` justo antes de `CardFactory.on_card_enters_play()`/registrar el trigger —
   mismo punto y mismo criterio que `GoldManager._trigger_enter_play()` usa para el
   humano (la carta ya está colocada visualmente; si se anula/cancela, su ETB nunca
   dispara y va directo al Cementerio). En el caso del Oro (`put_free_gold_in_pagado_
   from_data()`), `GameState.agregar_oro_pagado()` se movió a DESPUÉS de la ventana para
   no tener que revertirlo si se cancela.

2. **`TriggerResolution.resolve_next_trigger()`**: reemplazado `_wait_for_response_window()`
   (resolvía el trigger casi al instante, sin ventana real, diseño de 2026-08-17 "el bot
   no responde nada todavía, es pura fricción") por `TriggerSystem.open_response_window()`
   directo — el mismo mecanismo que ya usaban ~40 patrones "mira/muestra" a mano, ahora
   aplicado a TODO trigger genéricamente. Esto cubre "disparada" para cualquier carta con
   `"Cuando entra en juego"`/`"cuando ataque"`/etc., jugada por humano o bot, que antes
   resolvía casi sin fricción salvo el caso puntual de Signo Amarillo.

3. **Activadas ya estaban cubiertas** — `ActionPipeline.activate_ability()` siempre pasó
   por `_process_stack()` → `StackStepResolver._execute_step_d()`, que abre Paso D
   incondicionalmente para CUALQUIER objeto de la Pila (confirmado leyendo el código, sin
   cambios necesarios ahí).

**Efecto colateral encontrado y cerrado — diálogo viejo de Signo Amarillo para triggers
quedaba roto (no huérfano silencioso, sino CLICKEABLE PERO NO FUNCIONAL):**
`ResponseWindowHandler._on_trigger_waiting_for_responses()` (escuchaba `TriggerSystem.
waiting_for_responses`) cancelaba vía `TriggerSystem.cancel_current_trigger()` →
`pending_cancel_callback`, un flag que SOLO `_wait_for_response_window()` leía. Con esa
función sin llamador después del punto 2, el flag ya no lo consumía nadie — el diálogo
"¿Convertir X en un Oro sin habilidad para cancelar Y? (Sí/No)" habría seguido apareciendo
pero "Sí, cancelar" no habría cancelado nada de verdad. Se quitó el `emit_signal
("waiting_for_responses", ...)` de `resolve_next_trigger()` (único emisor real, confirmado
por grep) para que ese diálogo deje de dispararse. **Signo Amarillo para triggers se sigue
ofreciendo bien** por el camino nuevo: `ResponseWindowHandler._offer_signo_amarillo_for_
step_d()`, que escucha `ActionPipeline.step_d_waiting` — señal que `open_response_window()`
SÍ emite (confirmado: `_qualifies_for_signo_amarillo()` detecta Oro por `card_data.tipo`,
que Drácula — el caso real del log del usuario — cumple). `_wait_for_response_window()`,
`_signo_amarillo_response_available()`, `_find_signo_amarillo()` y `_on_trigger_waiting_
for_responses()` quedan huérfanas a propósito (docstrings actualizados, no borradas — el
primer diseño de "sin fricción" de 2026-08-17 documentado ahí por si hace falta revisarlo).

**Riesgo conocido, sin verificar en partida todavía:**
- **Doble ventana para los ~40 patrones "mira/muestra"**: esos patrones llaman
  `open_response_window()` ELLOS MISMOS, DENTRO de `_execute_trigger_effect()` — que ahora
  corre DESPUÉS de que `resolve_next_trigger()` ya abrió su propia ventana genérica en el
  punto 2. Para esas ~40 cartas puntuales, el rival podría ver DOS ventanas de respuesta
  seguidas para el mismo trigger (una genérica antes de saber nada del efecto, otra
  específica después de que el patrón ya reveló/decidió). No es incorrecto per DAR (dos
  oportunidades reales, no una fantasma), pero si se siente repetitivo/molesto en partida,
  es candidato a dedupe — no se intentó deduplicar en esta sesión, a propósito, por
  presupuesto de tiempo.
- **Más ventanas = más pausas acumuladas por turno del bot**: cada carta que juega el bot y
  cada trigger que dispara ahora abre su propia ventana real (0.2s fijo contra el bot, ver
  §10.52) — en un turno con varias jugadas seguidas, esto suma latencia perceptible aunque
  cada una individual sea corta. Si se siente lento, ajustar el delay de §10.52 antes que
  revertir esta ventana.
- Mismo mecanismo de timer/`_window_generation`/Paso D que ya causó cuelgues reales
  (§10.44/§10.45) — ahora se ejercita MUCHAS más veces por partida que antes (cada trigger,
  no solo ~40 patrones). Sin confirmar todavía que no reaparezca ningún cuelgue con este
  volumen nuevo de aperturas/cierres.

### 10.54 Presente: no podía jugar otra copia de sí mismo desde su propio revelado

**2026-09-19, mismo día, bug real reportado por el usuario ("no puedo jugar presente con
el presente").** Texto real (`card_cache/cards.json`, id 19936): *"...muestra las primeras
tres cartas de tu Castillo. Puedes jugar una carta de coste 3 o menos de ahí sin pagar su
coste o ponerlas en tu mano."* — sin ninguna cláusula que excluya otra copia de sí misma.
`LookRevealPatternsA.try_execute_look_play_or_hand_pattern()` llamaba al filtro compartido
`_make_look_play_free_filter(source_card, max_cost)` con su default `exclude_self=true`
(pensado originalmente PARA Presente, según el propio comentario de la función,
2026-08-27) — sin base real en el texto de la carta. Mismo criterio que ya usa Perder la
Razón (`exclude_self=false` explícito, con la misma justificación de texto).

**Arreglo:** el llamador de Presente ahora pasa `exclude_self=false` explícito, con
comentario citando el texto real verificado. **No tocado a propósito:** Tangata Manu usa
el mismo default sin haberse verificado todavía contra su propio texto — no cambiar sin
que el usuario lo confirme primero (texto real de Tangata Manu, verificado en esta misma
sesión: "muestra seis cartas del tope de tu Castillo y juega una carta de coste 2 o menos
de ahí sin pagar su coste" — tampoco tiene cláusula de exclusión, así que probablemente
tiene el mismo bug, pero no se tocó sin que el usuario lo pida para esa carta puntual).

### 10.55 Bug real (pre-existente, no relacionado con §10.51-53): desterrar/destruir un Arma equipada dejaba una referencia colgante en el portador

**2026-09-19, mismo día, bug real reportado por el usuario** ("Trying to assign invalid
previously freed instance, al momento de desterrar una carta con bernardo" — stack trace
apuntando a `ZoneManager.gd:535` dentro de `compact_field_slots()`, llamado desde
`compact_all_fields()` en `ZoneManager.gd:565`).

**Causa real (verificada leyendo el código, no relacionada con los cambios de hoy en
Anular/Cancelar/ventanas de respuesta):** `CardManager.destroy_card()`/`exile_card()` ya
tenían `_move_equipped_weapons_with()` para la dirección "el PORTADOR sale del juego → sus
Armas lo siguen al mismo destino" — pero nunca manejaron la dirección contraria: cuando el
**Arma misma** sale del juego directo (portador se queda en juego), nada quitaba esa Arma
de `wielder.equipped_weapons` antes de `card.queue_free()`. El array seguía con una
referencia a un Nodo ya liberado. `ZoneManager.compact_field_slots()` (línea 535: `var w:
Node = card.equipped_weapons[w_idx]`) lee esa lista cada vez que recompacta un campo —
como es una variable **typada** (`Node`), asignarle la referencia liberada es exactamente
lo que Godot rechaza con ese error. No fallaba en el mismo frame porque
`compact_all_fields()` se llama `call_deferred` dos líneas después de `queue_free()` en
`destroy_card()`/`exile_card()` — el crash aparecía solo en la SIGUIENTE recompactación
real de campo, no necesariamente asociado visualmente al momento exacto de desterrar.

Bernardo O'Higgins lo expuso porque su Destierro puede apuntar a "Aliado, Arma o Tótem de
coste 3 o menos" — un Arma equipada es un objetivo legítimo y común, a diferencia de la
mayoría de los otros ~15 llamadores de `ActionModule.banish()`/`destroy()` en el proyecto,
que en la práctica casi siempre apuntan a Aliados.

**Arreglo:** `CardManager._unequip_from_wielder(card)` (nueva) — si `card` es un Arma con
`wielder` válido, la quita de `wielder.equipped_weapons` antes de `queue_free()`. Llamada
al final de `destroy_card()` y `exile_card()`, justo antes de `_disconnect_card_
interaction_signals()`/`queue_free()` (mismo punto que ya limpia conexiones de señales por
el mismo motivo de referencias colgantes, ver comentario de esa función). No se tocó
`EffectController.gd` (Estaca) que ya hacía `wielder.equipped_weapons.erase(card)` a mano
antes de llamar `exile_card()` — `Array.erase()` sobre un elemento ya ausente es un no-op
seguro, así que la limpieza duplicada no rompe nada, solo es redundante ahí.

**Alcance de la verificación:** confirmado por lectura de código que TODO
destroy/exile en el proyecto pasa por estas dos funciones de `CardManager.gd` (`game_board`
es siempre `null`, así que `EffectController.destroy_card()`/`exile_card()` y
`ActionBanish.banish()` caen siempre a la rama `CardManager.*` — no hay un segundo camino
que necesite el mismo arreglo por separado). Sin verificar en partida real todavía.

### 10.56 Bernardo O'Higgins (y Lanza Argenta): elección Desterrar/Cancelar según el momento, no un diálogo A/B

**2026-09-19, mismo día, a pedido explícito del usuario:** "Bernardo tiene una habilidad
activada Y disparada en una pura habilidad — Desterrar una carta de coste 3 o menos O
cancelar la habilidad de una carta. Como dijimos que las que anulan/cancelan son
disparadas, la idea sería separarlas pero no en distintas habilidades sino en TIEMPOS en
los que se usa: si voy en mi turno o en Guerra de Talismanes, siempre Desterrar; si mi
oponente juega cartas o usa habilidades, ahí cancelaría — y así para todas las cartas que
funcionen de esa manera."

**Traducción a la máquina de estados ya existente:** la señal real que distingue "estoy
respondiendo a algo puntual" de "tengo la palabra en general" no es de quién es el turno
(`GameManager.active_player_id`) — es `PriorityManager.current_priority_context`. Una
ventana `RESPONSE_WINDOW` (Paso D) se abre específicamente cuando algo puntual ya está en
la Pila (una carta jugada o una habilidad activada/disparada — con §10.53, ESO ya cubre
"mi oponente jugó una carta o usó una habilidad" para TODO caso). `GUERRA_TALISMANES` (la
fase) y Vigilia sin ventana abierta son "tengo la palabra pero no estoy respondiendo a
nada puntual" — ahí va la rama proactiva. No importa de quién sea el turno: la
distinción es 100% sobre el contexto de prioridad, no sobre `active_player_id`.

**Nueva `AbilityButtonSupport._is_responding_to_opponent_action() -> bool`**:
`PriorityManager.priority_window_active and current_priority_context == RESPONSE_WINDOW`.

**Aplicado a 2 cartas con este molde exacto (Cancelar reactivo + efecto proactivo en el
mismo costo/botón):**
- **Bernardo O'Higgins** (`BernardoAbilityHandler._activate_bernardo_shuffle_removal()`):
  el diálogo "Elige el efecto" (`_show_bernardo_effect_choice()`, con sus 2 botones) se
  reemplazó por la elección automática. `_show_bernardo_effect_choice()` queda huérfana
  (no borrada, docstring actualizado).
- **Lanza Argenta** (`PreventionAbilityHandler_EP._activate_lanza_argenta_destroy_self_
  cancel_or_draw()`, "Puedes Destruir esta Arma para cancelar una habilidad o Robar tres
  cartas"): mismo molde exacto (Cancelar reactivo / Robar proactivo), `SelectionManager.
  await_two_choice()` reemplazado por la misma función de contexto.

**No auditado todavía — candidatas sin confirmar:** grep de `"cancelar una/la habilidad"`
encontró 11 archivos con esa frase; la mayoría son patrones de TRIGGER (disparados,
siempre reactivos por naturaleza, no necesitan esta separación) o cartas donde ambas
ramas ya son reactivas (p.ej. Tótem Dragón Ancestral: "Anular un Aliado o Cancelar una
habilidad", las dos reactivas — no aplica este criterio, y además está restringido a "en
tu turno" por su propio texto). No se auditaron las 11 una por una en esta sesión — pedir
puntual si aparece otra carta con el mismo molde proactivo+reactivo.

**Botón sigue apareciendo en turno rival por separado (§10.51):** ambas cartas contienen
"cancelar" en su `raw_text`, así que ya pasaban `_is_annul_or_cancel_ability()` y su botón
ya se mostraba durante una ventana de respuesta rival — este cambio no tocó ESA parte
(visibilidad del botón), solo QUÉ PASA después de clickearlo.

**Sin verificar en partida real todavía.**

### 10.57 `open_reveal_picker()`: las cartas reveladas no elegibles (Oro, coste sobre el límite) no se veían restringidas

**2026-09-19, mismo día, a pedido del usuario** ("en el efecto de tangata manu restringir
las cartas que no puedo jugar como oros o cartas de coste 3 o más" — Tangata Manu: "muestra
seis cartas... juega una carta de coste 2 o menos").

**Investigación:** la restricción LÓGICA ya existía — `_make_look_play_free_filter()`
(§10.36/10.54) ya excluye Oros y cartas de coste > max_cost de `candidates`, y
`CardInteractionModule._resolve_target_selection()` ya rechaza un click fuera de esa lista
("Objetivo no válido..."). Lo que faltaba era la parte VISUAL: `ZoneViewerModule.
open_reveal_picker()` (el popup que muestra las 6 cartas reveladas, click directo,
2026-09-14) instanciaba las 6 con exactamente el mismo aspecto — nada distinguía a simple
vista cuáles se podían elegir. El jugador solo se enteraba de que una era inválida
clickeándola y leyendo el mensaje de error. El diseño ANTERIOR a la migración a click
directo (`SelectionManager._create_selection_card()`, `can_interact=false` +
`modulate=Color(0.5,0.5,0.5,0.7)` para "no seleccionable") sí tenía este tratamiento — se
perdió en la migración de 2026-09-14 a `open_reveal_picker()` y nunca se repuso.

**Arreglo:** mismo tratamiento visual restaurado en `open_reveal_picker()` — las cartas
que no pasan el filtro quedan con `can_interact=false` (sin hover ni cursor de mano
tampoco) y atenuadas al 50% de brillo/70% de opacidad, mismo valor exacto que usaba
`SelectionManager`. Como `open_reveal_picker()` es compartida por TODOS los patrones
"mira/muestra del Castillo" (Tesoro de los Césares, Caín, akari, gran kraken, Signo
Amarillo, etc. — ver §10.36), el arreglo beneficia a todos ellos, no solo a Tangata Manu.

**No tocado:** `open_cemetery_target_picker()` (la función hermana para Cementerio/
Destierro) usa `await_multi_target()`, que tiene su propio sistema de brillo (§10.45/10.46)
— no se auditó si tiene el mismo hueco visual, no se reportó ningún problema ahí.

### 10.58 Misma familia de bug que §10.??: `is Node` bare (sin `is_instance_valid` primero) en 4 sitios más del sistema de modificadores continuos

**2026-09-19, mismo día.** El usuario reportó "Left operand of 'is' is a previously freed
instance" en `ContinuousVisualSync` — arreglado invirtiendo el orden a
`is_instance_valid(target) and target is Node` (`is` revienta con una referencia liberada
sin importar de qué lado del `and` esté; lo que importa es que `is_instance_valid()`, que
SÍ es seguro sobre cualquier Variant, se evalúe primero por el orden izquierda-a-derecha).
A pedido del usuario ("échales un ojo para ver si tienen la misma lógica"), se revisaron
los otros 4 sitios con el mismo patrón (`X is Node` sin guardia) detectados por grep en el
mismo sistema de efectos continuos — los 4 tenían exactamente el mismo hueco:

- `ContinuousEffectManager._get_card_id()` (línea 359) y `_get_card_name()` (línea 373).
- `ContinuousEffectManager._resolve_targets()` (línea ~681) — **el más peligroso de los 4**:
  lee `modifier.target` directo, el MISMO campo (`mod.target`) que causó el bug original en
  `ContinuousVisualSync.update_all_card_visuals()` (un modificador cuyo objetivo salió de
  juego sin limpiarse de `_modifiers`/`_modifiers_by_target`) — y se llama desde
  `ModifierRegistry.register_modifier()`/`unregister_modifier()` cada vez que se
  registra/limpia CUALQUIER modificador, un camino bastante más caliente que el de
  refresco visual.
- `KeywordManager._get_card_name()` (línea 957).

**Arreglo:** mismo patrón en los 4 — `is_instance_valid(x) and x is Node` en vez de `x is
Node` bare (con o sin `is_instance_valid` después). `card is String`/`card is Dictionary`/
`card is Array` en las mismas funciones NO se tocaron — esos chequeos de tipo builtin (no
contra una clase de Object) son seguros incluso sobre una referencia liberada, según lo
verificado en el bug original; solo los chequeos `is <ClaseDeObject>` (Node, Control,
clases custom, etc.) necesitan la guardia.

**No auditado más allá de estos 5 sitios totales (el original + 4)** — no se hizo un
barrido del proyecto entero buscando el mismo patrón fuera de `core/effects/continuous/`;
si aparece el mismo error en otro archivo, aplicar el mismo criterio ahí.

## 11. Multiplayer — relay desplegado en producción (2026-09-19/20)

**Contexto:** el diseño de `docs/plans/2026-09-09-multiplayer-remoto-design.md` (Anfitrión-
autoritativo vía relay WebSocket propio) ya tenía bastante código real escrito
(`NetworkClient.gd`, `RemotePlayerController.gd`, `RemoteMirrorController.gd`,
`GameStateBroadcaster.gd`, `OnlineConnect.gd`, `relay-server/`) pero nunca se había
desplegado ni probado de punta a punta — el propio diseño lo dejaba como "Verificación:
prueba manual pendiente" y `OnlineConnect.gd` apuntaba a `ws://localhost:8080` por defecto
(solo funcionaba si tú mismo corrías el relay a mano).

**Comparación de opciones (a pedido del usuario, "revisa bien cuál es la mejor"):** el
diseño ya había descartado con buena razón las alternativas (Godot MultiplayerAPI/ENet —
mal encaje para un juego por turnos basado en mensajes; WebRTC P2P — señalización + TURN
de respaldo, más piezas móviles; servicios de terceros tipo Photon/Nakama/Steam
networking — pensados para escala, overkill para 2 amigos). La única decisión real
pendiente era DÓNDE hostear el relay ya construido — se comparó Railway (CLI, deploy
directo desde carpeta local, sin necesitar push a GitHub, trial de USD 5 sin tarjeta +
plan gratis permanente de USD 1/mes en créditos de uso — confirmado en railway.com/pricing
el 2026-09-19) contra Render (requiere conectar un repo de GitHub, y el free tier de Web
Services se duerme tras 15 min de inactividad) y Fly.io (requiere tarjeta desde hace un
tiempo, aunque sea para el free tier). **Se eligió Railway** — sin tarjeta, sin necesitar
resolver primero que `relay-server/` no estaba pusheado a `origin` (5 commits locales sin
subir a esa fecha), deploy directo desde el filesystem local.

**Desplegado:**
- Proyecto Railway `mitos-relay-server` (cuenta `tomaseduardom@gmail.com`), servicio creado
  vía `railway init --name mitos-relay-server` + `railway up --ci` desde `relay-server/`
  local (sin pasar por GitHub).
- Dominio público: `https://mitos-relay-server-production.up.railway.app` — el WebSocket
  real queda en `wss://` sobre esa misma URL. Target port fijado a **8080** a mano
  (`railway domain update ... --port 8080`) porque Railway no infirió el puerto solo (el
  server no expone ningún health-check HTTP, solo abre el WebSocket — el dominio quedaba
  con "Target port: -" hasta fijarlo).
- **Verificado end-to-end** con un script Node ad-hoc (`ws` — la misma dependencia real del
  server) conectando al dominio público y haciendo `create_room` → recibió `room_created`
  con código real. El relay en producción funciona.
- `scripts/menu/OnlineConnect.gd`: `DEFAULT_RELAY_URL` actualizado de
  `ws://localhost:8080` a la URL `wss://` de Railway — la pantalla de conexión ya apunta al
  relay real por defecto, sin que el jugador tenga que escribir nada.

**Pendiente (siguiente paso lógico, no hecho en esta sesión):** el propio diseño de
2026-09-09 dejó como plan de verificación "primero 2 instancias de Godot en la misma
máquina contra el relay ya desplegado, después con otra persona real en otra red" — con el
relay ya en producción, ese es el paso que falta para confirmar que TODO el flujo
(intercambio de mazo, `RemoteMirrorController`, `GameStateBroadcaster`,
`RemotePlayerController`) funciona jugando de verdad, no solo que el relay reenvía
mensajes. No se auditó en esta sesión si ese flujo está completo o si quedó algo a medias
desde 2026-09-10/11 (los commits reales de esa parte).

**Costo/mantenimiento:** el relay es un proceso Node casi todo el tiempo inactivo (solo
reenvía mensajes cortos durante una partida) — el plan gratis permanente de Railway (USD
1/mes en créditos de uso) debería alcanzar de sobra para uso hobby entre amigos, pero no
se dejó ningún monitoreo de gasto configurado. Si Railway pausa el servicio por créditos
agotados en algún momento, `railway up` desde `relay-server/` lo vuelve a desplegar.

## 12. Build portable Windows (2026-09-20)

**A pedido del usuario** ("poder abrir mi app en otro computador para probarlo") — no
existía ningún preset de exportación ni Export Templates descargados en la máquina pese a
tener Godot 4.6 instalado (`Desktop/Godot_v4.6-stable_win64.exe/`).

**Hecho:**
- Export Templates 4.6.stable descargados de
  `github.com/godotengine/godot/releases/download/4.6-stable/Godot_v4.6-stable_export_templates.tpz`
  (~1.25GB) e instalados en `%APPDATA%\Godot\export_templates\4.6.stable\` (la ruta exacta
  que Godot 4.6 espera — `4.6.stable`, con puntos, no guiones).
- `export_presets.cfg` (nuevo, no existía) — un preset `"Windows Desktop"`,
  `binary_format/embed_pck=true` (todo en un solo `.exe`, sin carpeta ni `.pck` aparte —
  la definición real de "portable": se copia el archivo solo a un pendrive/otra PC y corre
  sin instalar nada, mismo criterio de arquitectura x86_64 en ambas máquinas).
- Build exportado: `build/windows/MitosOnline.exe` (~1.96GB — el tamaño real viene de los
  assets de cartas/fuentes embebidos, no de Godot en sí). Comando real usado:
  ```
  Godot_v4.6-stable_win64.exe --headless --export-release "Windows Desktop" "build/windows/MitosOnline.exe"
  ```
- `build/` agregado a `.gitignore` — el `.exe` no se versiona (se regenera con el comando
  de arriba cuando haga falta un build nuevo).

**Sin verificar en la práctica:** no se pudo abrir/jugar el `.exe` resultante desde esta
sesión (sin acceso a interfaz gráfica) — falta que el usuario lo abra en su propia máquina
para confirmar que arranca bien, y después copiarlo/probarlo en la otra PC de verdad. Si
no abre o falta algo (íconos, texturas, etc.), revisar `export_filter`/`include_filter` en
`export_presets.cfg` (hoy `"all_resources"`, debería incluir todo por defecto).

**Para reexportar más adelante** (después de cualquier cambio de código): repetir el mismo
comando `--headless --export-release "Windows Desktop" ...` — no hace falta repetir la
descarga de templates ni recrear el preset, ambos quedan persistentes.

### 12.1 Bugs reales encontrados probando el build en OTRA PC (2026-09-20)

**A pedido/reporte del usuario, primera prueba real cross-máquina.** Tres problemas
reales, los tres con causa raíz confirmada:

**1. "No me salen los mazos" en la otra PC.** Causa: `res://data/decks/` (la carpeta
BUNDLEADA que sí viaja con el `.exe`, ver `DeckLoader.get_bundled_decks()`) estaba
**vacía** — los 8 mazos preset reales (`preset-bestia/caballero/dragon/eterno/guerrero/
heroe/sacerdote/sombra.json`) solo existían en `user://decks/` de ESTA máquina de
desarrollo (`%APPDATA%\Godot\app_userdata\Mitos y Leyendas\decks\` — el nombre de carpeta
real es "Mitos y Leyendas", `config/name` en `project.godot`, no "MitosOnline"), que es
por-máquina y nunca viaja con el build. **Arreglo:** copiados esos 8 archivos a
`data/decks/` (mismo formato exacto, sin transformar nada) y reexportado. También
confirmado que `res://data/cards.json` (el catálogo bundleado de ~5600 cartas) **no
existe en el proyecto** — el juego depende de caché local (`user://`, vacía en una PC
nueva) o de la API externa en vivo (`iterva.pythonanywhere.com`, confirmada funcionando
en §4) como respaldo. No se bundleó `cards.json` en esta sesión (alcance más grande,
necesita disparar una carga real desde la API y exportar — `CardDatabase.
export_for_bundling()` ya existe para eso) — si en la otra PC las CARTAS en sí (no los
mazos) tampoco cargan bien, ese es el siguiente sospechoso.

**2. Multiplayer "entraba a la partida sin esperar a nadie" — síntoma, no bug aparte.**
Causa real: con `data/decks/` vacío (bug 1), la única forma de avanzar en el selector de
mazos era el botón "Mazos aleatorios" (`DeckSelector._on_random_pressed()`), que emitía
`decks_selected({}, {}, false, false)` incondicionalmente — `GameBootstrap.
_on_decks_selected()` trata datos vacíos como señal de "usar flujo de prueba local" y
hace `return` ANTES de llegar a chequear `NetworkClient.room_code`, saltándose TODO el
intercambio de mazos por red. Con el bug 1 arreglado (mazos reales disponibles), el botón
Confirmar normal ya pasa por el camino de red correcto (verificado leyendo `_on_decks_
selected()`/`_load_opponent_deck_from_network()`/`_send_own_deck_and_wait_for_host()` —
la lógica de espera YA estaba bien escrita, simplemente nunca se alcanzaba). Arreglo
adicional por las dudas: `_on_random_pressed()` ahora, si hay una sala de red activa,
elige un mazo real al azar de los bundleados y sigue el mismo camino que Confirmar, en
vez de mandar datos vacíos — para que ese botón tampoco pueda saltarse la sincronización
si alguien lo usa estando online.

**3. UX pedida — "esperando jugador" en vez de un botón "Continuar":**
- `OnlineConnect.gd`: `continue_button` oculto (no borrado); `_on_room_joined()`/
  `_on_peer_ready()` ahora pasan solo a `Main.tscn` en vez de habilitar un botón.
- `GameBootstrap._load_opponent_deck_from_network()` (lado Anfitrión): antes esperaba en
  silencio el mazo del Remoto — ahora muestra el mismo overlay "ESPERANDO JUGADOR" que ya
  usaba el lado Remoto (`_send_deck_to_host()`, reformulado con el mismo texto) para el
  caso simétrico.

**Gotcha real de exportación descubierto en el camino — anotar para la próxima vez:**
un reexport headless (`--headless --export-release`) puede fallar en silencio con `Parse
Error: Could not find type "GameOverOverlay" in the current scope` si se agregó un script
nuevo con `class_name` (aquí, `GameOverOverlay.gd`) sin que el EDITOR completo lo haya
indexado nunca en `.godot/global_script_class_cache.cfg` — el modo `--headless --export-*`
solo no alcanza a reconstruir ese caché para clases nuevas. El export en sí NO frena con
error visible (exit code 0) pero empaqueta un `.pck` roto/truncado (102 recursos en vez de
cientos) que revienta al abrir el juego. **Fix/ritual:** antes de exportar, correr una vez
`Godot... --headless --editor --quit-after 60` (fuerza un reescaneo completo del proyecto
y regenera el caché de clases) — solo después `--export-release`. De paso, ese mismo
reescaneo podó del paquete un montón de `.ctex` huérfanos en `.godot/imported`
(imports cacheados sin archivo fuente real en `res://` — parecen restos de una época
anterior con arte de cartas bundleado localmente, antes de migrar a Cloudinary) que
habían inflado el primer build a ~1.96GB; el build real, correcto, pesa ~150MB.

### 12.2 Duelo de dados sin sincronizar en multiplayer (2026-09-20)

**A pedido del usuario:** "no tiene sentido que en cada pantalla se tiren 4 dados
distintos... el host va a ser el dado de la izquierda y el participante el de la derecha
— y lo mismo para todas las fases antes de jugar, se debe esperar al otro jugador".

**Bug de fondo encontrado al investigar (no relacionado con multiplayer, preexistente):**
`DiceDuel3D.start_roll()` tenía un **resultado hardcodeado** desde 2026-09-11 (`_result1 =
20; _result2 = 1`, comentario propio: "DEBUG TEMPORAL... sacar antes de jugar en serio")
que nunca se revirtió — TODO sorteo de dados hasta hoy, local o en red, era 100%
determinístico (Jugador 1/izquierda siempre ganaba con 20). Restaurado el sorteo real
(`randi_range(1, 20)`, con re-tiro si empatan).

**Multiplayer — antes:** cada cliente (Anfitrión y Remoto) instanciaba su propio
`DiceDuel3D` de forma completamente independiente — con el bug de arriba, esto daba el
mismo resultado fijo en ambos lados por casualidad, pero la arquitectura en sí no tenía
NINGUNA sincronización: cada lado tiraba (o iba a tirar, una vez arreglado el hardcode) su
propio azar sin relación con el otro. Peor aún: el Remoto **nunca veía el duelo de dados
en absoluto** — su `GameBootstrap` se detiene en "esperando jugador" apenas manda su mazo
(diseño ya existente, correcto) y nada mostraba el sorteo de ese lado.

**Arreglo — Anfitrión autoritativo, mismo criterio que el resto del protocolo de red:**
- `DiceDuel3D.gd`: nuevas `forced_result1`/`forced_result2` (-1 = tirar al azar como
  siempre; si ambos > 0, usar esos valores en vez de tirar) y señal nueva
  `result_decided(result1, result2, winner_id)`, emitida ANTES de la animación (apenas se
  decide el resultado, no al final). También `winner_text_p0`/`winner_text_p1`
  parametrizables (antes "¡TÚ PARTES!"/"¡OPONENTE PARTE!" hardcodeado — no tiene sentido
  decir "TÚ" en una vista espejo que no controla al jugador 0 de verdad).
- `GameBootstrap._show_dice_roll()` (lado Anfitrión): si hay sala de red activa, escucha
  `result_decided` y manda `{"op":"dice_roll","result1":...,"result2":...}` por
  `NetworkClient` apenas el Anfitrión decide el resultado — no espera a que termine la
  animación.
- `RemoteMirrorController.gd` (lado Remoto, nuevo): escucha `"dice_roll"`, instancia su
  propio `DiceDuel3D` con `forced_result1`/`forced_result2` puestos a los valores
  recibidos (reproduce la MISMA tirada, no tira la suya), textos de banner adaptados
  ("¡EMPIEZA EL ANFITRIÓN!"/"¡EMPEZÁS TÚ!"), y vuelve a mostrar "ESPERANDO JUGADOR" al
  terminar (mientras el Anfitrión hace su propio mulligan).
- Geometría sin cambios a propósito: el dado 1 (izquierda) ya era estructuralmente
  "Jugador 0" en el código existente — Anfitrión SIEMPRE es jugador 0 en el protocolo de
  red (ver §11) — así que "Anfitrión = izquierda, Remoto = derecha" ya se cumplía sin
  tocar posiciones, una vez que ambos lados ven la MISMA tirada.

**Mulligan — ya estaba bien, verificado, no tocado:** `MulliganController._end_mulligan_
phase()` ya hace `await _main._easy_bot.run_mulligan(...)` cuando el jugador 1 es un
Remoto — `GameManager.start_game()` no corre hasta que la elección de mulligan del Remoto
vuelve por red. Sí queda como orden secuencial (no paralelo): el Anfitrión termina su
propio mulligan ANTES de que se le mande siquiera el prompt de mulligan al Remoto — no es
un bug de sincronización (nadie avanza sin el otro), pero el Remoto puede quedarse un rato
en "esperando" sin más contexto mientras el Anfitrión decide su propia mano. No se tocó —
fuera del pedido explícito de esta sesión (era sobre los dados); anotado como posible
mejora de UX futura si se pide.

**Sin verificar en partida real todavía** — mismo motivo que el resto de esta sesión, sin
poder correr 2 instancias con interfaz gráfica desde aquí.

### 12.3 Habilidad faltante: "voragh el devorador" — descuento de coste por descarte nunca implementado (2026-09-20)

**Reporte del usuario:** "etoy viendo que el voragh no puedo jugarlo reduciendo su coste
en un oro". El texto impreso de "voragh el devorador" (id 20588/20598) tiene 3
habilidades:

1. **"Puedes Descartar una carta para reducir su coste en un Oro."**
2. "En tu Vigilia, una vez por turno, busca en un Castillo dos cartas y ponlas en el
   Cementerio."
3. "Una vez por turno, puedes Destruir una de tus cartas para generar un Oro para jugar
   Aliados."

Un `grep -rln "voragh" scripts/` confirmó que las habilidades 2 y 3 ya tenían código; la
1 no tenía ninguna referencia en todo el proyecto — coincide exactamente con el reporte.

**Arreglo:** se modeló sobre el patrón ya existente `_get_reveal_cost_reduction_pattern()`/
`_resolve_reveal_cost_reduction()` de `GoldManagerTax.gd` (usado por "El Rey y el
Verdugo"/Shiji, "Muestra X para reducir el coste"), que se engancha en
`GoldManager.play_card()` justo ANTES de calcular `coste_real`. Se agregó el par
equivalente para voragh:

- `GoldManagerTax._get_discard_cost_reduction_pattern(card)` — detecta el substring
  "puedes descartar una carta para reducir su coste en un oro" en `card_ability`.
- `GoldManagerTax._resolve_discard_cost_reduction(card)` — costo OPCIONAL ("Puedes"):
  ofrece elegir una carta distinta de la mano vía `await_target(..., cancellable=true)`
  (ESC declina sin penalidad) y, si se elige una, la descarta de verdad con
  `ActionModule.discard(0, [chosen], "voragh el devorador", true)` — a diferencia del
  patrón de Shiji, aquí la carta entregada se DESCARTA, no solo se "muestra".
- Forwarders en `GoldManager.gd` y un bloque nuevo en `play_card()` (mismo lugar que el
  bloque de `reveal_pattern`) que aplica `PaymentManager.agregar_modificador_coste(card,
  -1, ..., false)` si el descarte ocurrió.

La limpieza de `PaymentManager.remover_modificador_coste(card)` ya existente en la rama de
fondos insuficientes de `play_card()` cubre este modificador nuevo sin cambios adicionales
(mismo sistema `cost_modifiers` subyacente).

**De paso:** se encontró y corrigió un residuo de voseo argentino ("¡EMPEZÁS TÚ!" en
`RemoteMirrorController.gd`, texto del banner de dados agregado en §12.2 el mismo día,
después del barrido de limpieza de español neutro) → "¡EMPIEZAS TÚ!".

**Sin verificar en partida real todavía** — mismo motivo que el resto de esta sesión.

### 12.4 Auditoría completa de habilidades faltantes (539 cartas) + primeras 3 implementadas: Primer/Segundo/Tercer Sello

**2026-09-20, a pedido del usuario ("podrias hacer una revisión de que cartas estarían
faltando").** Se cruzó el catálogo completo (2426 cartas, 1606 nombres únicos con texto de
regla real tras descartar las de solo-keyword) contra todo `scripts/` con un script Python
(nombre de carta + ~250 substrings/62 regex extraídos de los parsers de habilidad reales
del proyecto) — **539 cartas sin ninguna cobertura detectada**, verificadas a mano ~24 casos
de la lista (torii, arpón sagrado, heracles, van helsing, Rito de Pontchartrain, etc.),
todas confirmadas como huecos reales. Desglose por tipo: Aliado 249, Talismán 154 (nota:
la etiqueta de tipo salió invertida Oro↔Talismán en el resumen inicial dado al usuario —
corregido en la propia conversación, no en este documento aparte, verificado con la
distribución de coste real: Oro siempre coste 0), Oro 51, Arma 50, Tótem 35. Archivos de
trabajo (script de cruce, JSON de las 539) quedaron en el scratchpad de la sesión, no en
el repo.

**El "patrón grande" de 154 Talismanes NO es un solo patrón** (corrección sobre la hipótesis
inicial): revisado el texto real de una muestra, son 154 efectos completamente distintos
(destierros, anulaciones, conversión en Tótem, robo condicional, etc.), no una plantilla
compartida como voragh — cada uno necesita su propia implementación, one-by-one.

**A pedido del usuario ("Familia de los Sellos primero"), implementadas las primeras 3 de
un ciclo real de 7 + 1** (`Ángeles y Demonios: Vigilantes`: Primer/Segundo/.../Séptimo
Sello + "Los Siete Sellos", un Oro) — alcance acotado explícitamente a Primer/Segundo/
Tercer Sello; Cuarto/Quinto/Sexto/Séptimo Sello y "Los Siete Sellos" quedan sin
implementar a propósito (sí son objetivos válidos de "busca un Sello", ver abajo).

**Infraestructura compartida — `SearchOwnZonePatterns._search_sello_to_hand()`:** "Sello"
no es una Raza impresa (campo `raza` vacío en los datos) — se identifica por nombre vía
`ActionModule.search()` con `{"type": TALISMAN, "name_contains": "sello"}` (el filtro por
tipo excluye "Los Siete Sellos", que es Oro, sin necesitar una lista de exclusión aparte).

**Hallazgo de arquitectura importante:** un Talismán abre su propia ventana de respuesta
en `TriggerSystem.resolve_talisman()` ANTES de despachar a cualquier patrón — las 3
funciones nuevas NO abren la suya (se habría preguntado dos veces), mismo criterio ya
documentado en el propio código para Golpe Solar/Tempilcahue/Acabar la Esperanza.

**Primer Sello** (`try_execute_primer_sello_pattern`): búsqueda + Bota (mill) al oponente
1 + cartas "Sello" ya en el Cementerio propio. Tercera cláusula ("si está en tu
Cementerio, una vez por turno, cuando juegues una carta Sello, tu oponente Bota una
carta") es una **habilidad activa DESDE EL CEMENTERIO — sin precedente en el proyecto**;
implementada en `GoldManager._check_primer_sello_cemetery_trigger()`, enganchada al
principio de `_trigger_enter_play()` (el único punto real por el que pasa TODA carta
jugada de cualquier tipo, Talismán incluido) en vez de inventar un signal `card_played`
nuevo. "Una vez por turno" vía `UniversalCardParser.turn_registry` (mismo mecanismo que
Crono Diamante), clave sintética `"primer_sello_cemetery:%d" % controller_id` (no por
copia física — es una habilidad de "tener la carta en el Cementerio", no de una instancia
puntual).

**Segundo Sello** (`try_execute_segundo_sello_pattern`): búsqueda + hasta 2 Aliados eligen
+2 Fuerza (`await_multi_target`, sin lock) este turno. "Su daño de combate... es enviado
al Destierro" se interpretó como referido a esos 2 Aliados recién buffeados (no a cartas
Sello, que nunca hacen daño de combate en esta familia) — reactiva `Card.
damage_goes_to_exile` (**infraestructura muerta encontrada**: `BattleManager.
_check_damage_to_exile_effect()` ya consultaba `card.get("damage_goes_to_exile")` desde
antes de esta sesión, pero ninguna carta del proyecto la declaraba ni asignaba nunca — se
declaró el campo en `Card.gd` y se asigna aquí, sin tocar `BattleManager.gd`). Limitación
conocida heredada de esa función preexistente: solo cubre daño AL CASTILLO, no destrucción
carta-contra-carta en combate ni daño directo fuera de combate. Tercera cláusula ("si está
en tu Cementerio, tus Sello no pueden ser Anulados") — protección estática agregada en
`LinkedEffectRegistry._execute_annul()`, mismo criterio que la protección "no pueden ser
canceladas" de Drácula ya existente ahí (`_execute_cancel()`), del lado Anular y
consultando el Cementerio del controlador de la carta objetivo.

**Tercer Sello** (`try_execute_tercer_sello_pattern`) — el más complejo de los 3: búsqueda
+ debuff GLOBAL -3 Fuerza a TODOS los Aliados en juego Y que entren después (ambos
jugadores), vía el target dinámico `"ALL"` + `filter{type:ALIADO}` de `ModifierRegistry`
(mecanismo de auras "Tus Aliados" ya existente, generalizado aquí sin filtrar por dueño —
así un Aliado que ENTRE en juego después del efecto también queda afectado sin tener que
reaplicar el modificador a mano en cada ETB rival). Duración `TIMED` con
`duration_value=2`: `ContinuousEffectManager._on_turn_ended()` descuenta en CADA fin de
turno de cualquier jugador (no filtra por quién) — jugada en tu propio turno, sobrevive tu
fin de turno (2→1) y expira al fin del turno rival (1→0), justo antes de tu turno
siguiente: "hasta tu próximo turno" exacto, sin necesidad de un nuevo tipo de duración.
"Si tienen Fuerza 0 no pueden disparar sus habilidades" — **sin precedente en el
proyecto** (condición ligada a un valor de Fuerza calculado en el momento, no a una fuente
viva en juego, a diferencia de `_opponent_type_silence_sources` ya existente en
`KeywordManager.gd`); se agregó `KeywordManager.register_zero_strength_ability_lock()`/
`_is_silenced_by_zero_strength_lock()`, un contador de turnos independiente pero con el
mismo valor (2) para que se apague junto con el debuff de Fuerza, consultado desde
`is_silenced()` (el mismo choke point real que ya usa `TriggerSystem._check_trigger_
conditions()`). "Baraja los Aliados oponentes de Fuerza 0" — limpieza puntual una sola vez
DESPUÉS de aplicar el debuff (para capturar Aliados que llegan a 0 recién con este mismo
efecto), respetando Prevención (tag `"leave_play"`, mismo criterio que
`ActionReturnDiscard.return_to_deck()`).

**De paso:** verificado y confirmado el mapeo real `Constants.CardType` (ORO=0, ALIADO=1,
ARMA=2, TALISMAN=3, TOTEM=4) contra la distribución de coste real de `cards.json`
(Oro=coste 0 en 370/373 casos) — sin bugs de mapeo encontrados, la inversión Oro↔Talismán
mencionada arriba fue solo un error de etiquetado en el resumen dado al usuario, no un bug
de código.

**Sin verificar en partida real todavía** — mismo motivo que el resto de esta sesión. En
particular, el debuff global de Tercer Sello y el "no puede ser Anulado desde el
Cementerio" de Segundo Sello son los dos con mayor superficie de riesgo (tocan sistemas
compartidos, `ModifierRegistry`/`LinkedEffectRegistry`) — probar estas 3 cartas
puntualmente antes de seguir con el resto de los 154 Talismanes faltantes.

### 12.5 Resto del ciclo de Sellos: Cuarto/Quinto/Sexto/Séptimo Sello + "Los Siete Sellos" (2026-09-20)

**A pedido del usuario ("sigue con el resto de la familia de sellos"),** completa la
familia de 8 cartas iniciada en §12.4. Implementado por un fork dedicado (interrumpido una
vez por límite de sesión y retomado sin pérdida de trabajo — el estado en disco se
conservó). Build reexportado tras retomar, **0 errores de parseo**, verificado que las
funciones nuevas existen realmente en el código (no solo en el resumen del fork).

**Cuarto Sello** (`try_execute_cuarto_sello_pattern`, en `SearchOwnZonePatterns.gd`):
búsqueda compartida + Destruye hasta una carta de coste 4 o menos (cualquier tipo/jugador)
+ costo opcional: pagar 1 Oro y descartarlo (nueva `GoldManager._discard_oro_from_
reserva()` — no existía antes forma de descartar un Oro ya puesto en Reserva) para que un
Aliado pierda su habilidad y 4 de Fuerza este turno, luego Roba dos cartas. La cláusula
"puedes jugarlo al comienzo de cualquier Fase" no necesitó código: se confirmó por grep que
el motor no restringe en qué momento se puede jugar un Talismán.

**Quinto Sello** (`try_execute_quinto_sello_pattern`): búsqueda + nueva
`_shuffle_up_to_from_cemeteries()` (variante "solo Barajar" de la función ya usada por
Armería del Guerrero) + elección A/B: jugar un Aliado del Cementerio a coste -1 Oro (mínimo
0) o un Sello pagando su coste completo. Tercera cláusula ("no se pueden jugar más de
cinco cartas por turno") es la de mayor riesgo: nuevo contador global
`TurnManager.cards_played_count_this_turn`, reseteado en cada cambio de turno, gateado en
`GoldManager.play_card()`. **Limitación real y deliberada:** el gateo solo cubre el camino
normal de jugar desde la mano — NO se tocaron `play_card_from_exile/cemetery/for_free`
(3 caminos alternativos existentes) por no poder validarlo en partida real; si alguna carta
juega por esas rutas mientras Quinto Sello está en Cementerio, el límite de 5 no se aplica
ahí todavía.

**Sexto Sello** (`try_execute_sexto_sello_pattern`): búsqueda + protección "No puede ser
Anulado" **incondicional y genérica**, agregada de nuevo en `LinkedEffectRegistry.
_execute_annul()` (antes de esta carta solo existía la versión condicional que agregó
Segundo Sello, atada a "está en tu Cementerio"; esta es simple y sin condición, beneficia
automáticamente a cualquier carta futura con ese texto exacto, no solo a Sexto/Séptimo
Sello) + elección A/B Destruir/Desterrar todas las cartas que no sean Oro (ambos
jugadores) + mill 6 a cada jugador + mill adicional al oponente por cada Sello molido de
esta forma.

**Séptimo Sello** (`try_execute_septimo_sello_pattern`) — sin cláusula de búsqueda, la
única distinta del resto: reutiliza la protección "No puede ser Anulado" recién agregada +
convierte tu Oro y hasta una carta oponente **por cada coste distinto presente en juego**
(mecanismo nuevo — el sistema de Convertir existente en `GoldConversionPatterns.gd` era de
un solo objetivo, no "uno por cada coste distinto") en cartas de Fuerza 0 y sin habilidad,
usando la operación `"set"` de `ModifierRegistry` (ya existía en el registro pero ningún
efecto real la usaba hasta ahora) + otorga Indestructible e Indesterrable a una carta
propia + elección A/B robar 2 cartas o botar 1 al oponente por cada Sello en tu Cementerio
(tope 7).

**"Los Siete Sellos"** (Oro, `GoldManager._check_los_siete_sellos_trigger()`): dos de sus
tres cláusulas resultaron ya cubiertas por infraestructura genérica existente sin escribir
nada nuevo — "Oro Inicial" ya se detecta por texto en `GameBootstrap._setup_oro_inicial()`,
y "no puede ser convertido" ya lo cubre la validación genérica de Convertir
(`_target_text_denies`). Se agregó solo el trigger reactivo real: hasta 2 veces por turno
(dos claves de `turn_registry`, `los_siete_sellos_1`/`_2`), cuando se resuelve el efecto de
un Talismán Sello propio, el oponente Bota 2 cartas — enganchado justo después de
`resolve_talisman()` dentro de `_trigger_enter_play()`. **Cláusula NO implementada
(deliberado):** "no pagas costes adicionales mientras juegas o utilizas la habilidad de
cartas Sello" — no existe en todo el proyecto ningún efecto real que imponga un coste
adicional al oponente sobre cartas Sello, así que no hay nada que exceptuar todavía; se
deja documentado en vez de construir una protección sin caso de uso real que la dispare.

**Sin verificar en partida real todavía** — probar en especial el tope de 5 cartas/turno de
Quinto Sello y la conversión múltiple por coste distinto de Séptimo Sello, los dos
mecanismos más nuevos de este lote.

### 12.6 Primer lote de Tótems faltantes: 1 completo + 2 parciales, 5 diferidos a propósito (2026-09-20)

**A pedido del usuario ("por mientras podrías ver otras cartas"),** en paralelo al resto
del ciclo de Sellos, se atacó un lote de 8 Tótems del grupo de 539 sin cobertura (mismo
origen que §12.4). Archivo nuevo `scripts/core/effects/triggers/TotemAbilityPatterns.gd`;
modificados `TriggerSystem.gd` (registro del módulo) y `TriggerResolution.gd` (despacho en
`on_enter_play`/`on_leave_play`). Build reexportado, **0 errores de parseo**.

**arco del triunfo** — completo, sus 2 cláusulas:
- ETB/salida compartida (mismo texto cubre ambos disparadores): revela cartas del Castillo
  hasta mostrar un Aliado o Tótem de coste 2, elige ponerla en juego o en la mano, baraja
  el resto.
- Aura estática mientras está en juego: +1 Fuerza a tus Aliados (mecanismo de auras "Tus
  Aliados" ya existente) + daño de combate redirigido al Destierro — reactivó
  infraestructura muerta (`TriggerSystem.register_continuous_effect`/
  `get_active_continuous_effects("damage_to_exile")`, ya consultada por `BattleManager`
  pero sin ninguna carta del proyecto que la usara hasta ahora). Se limpia sola al salir
  de juego.

**kotoku-in** y **metropolitan** — solo su cláusula de entrada implementada (genera Oro
restringido para cartas no-Talismán / elige entre generar Oro restringido o robar 2
cartas), reutilizando `GoldManager.generar_oro_virtual_restringido()` ya existente. Sus
cláusulas restantes (activada en Vigilia para kotoku-in; conversión en Aliado y "cuando
ataca" para metropolitan) quedaron **deliberadamente sin implementar**.

**Diferidos a propósito, sin código todavía:** Estación Fantasma, hojo-shi, iga ryu, hangar
de la ciudadela, la rueda de la fortuna — decisión explícita del fork encargado, priorizando
terminar bien lo que alcanzaba en vez de forzar 8 implementaciones apuradas. Motivo común:
requieren mecanismos genuinamente nuevos sin ningún precedente en el proyecto (conversión
Tótem↔Aliado, robo de control de carta oponente, bloqueo global de Botar/Desterrar,
"debe atacar todos los turnos" forzado, autodestrucción al ser Botado por daño desde el
Castillo, o habilidades ACTIVADAS que necesitarían un botón nuevo en
`CardInspectionLayer`). Quedan para una próxima tanda.

**Sin verificar en partida real todavía** — mismo motivo que el resto de esta sesión.

### 12.7 kotoku-in completo, metropolitan 2/3, resto de Tótems sigue pendiente (2026-09-20)

**A pedido del usuario ("sigue con los tótems pendientes"),** segunda tanda sobre el mismo
fork de §12.6, ahora con su contexto completo de lo ya construido. Build reexportado,
**0 errores de parseo** — se encontró y corrigió en el camino un error de inferencia de
tipo (`var old_parent := ...` sobre variable de bucle sin tipo estático, mismo patrón de
bug ya visto en `LinkedEffectRegistry.gd` esta sesión) en el propio código nuevo antes de
exportar.

**kotoku-in — completo, sus 2 cláusulas.** La activada de Vigilia (elegir Destruir una
carta de coste 2 o menos, o anular sin efecto el próximo Talismán rival este turno) resultó
más simple de enganchar de lo esperado: **hallazgo de arquitectura** — las habilidades
ACTIVADAS (no solo los triggers ETB) ya pasan por el mismo despachador compartido
(`_resolve_look_and_play_patterns()`), y `CardInspectionLayer._build_ability_buttons()`
genera el botón automáticamente a partir del texto parseado sin necesidad de tocar ningún
código de UI — solo hubo que registrar la función nueva en ese despachador. La opción "el
próximo Talismán rival se resuelve sin efecto" es un flag de una sola vez, consumido dentro
de `TriggerSystem.resolve_talisman()` — mecanismo nuevo, sin precedente previo de
"anulación diferida" (que se dispara en la PRÓXIMA carta jugada, no en la carta actual) en
el proyecto.

**metropolitan — 2 de 3 cláusulas.** Conversión en Aliado de Fuerza 3 hasta la Fase Final
(activada de Vigilia) reutiliza un precedente real ya existente
(`ConvertAndMiscResolver.try_execute_mill_convert_to_ally_pattern`, el mismo patrón usado
por "Sherlock Holmes") — mover de contenedor, cambiar `card_type`, aplicar modificador de
Fuerza fija; la reversión automática en la Fase Final se conecta a la señal
`GameManager.phase_changed` existente. **Pendiente:** "Cuando ataca, un Aliado que no sea
Metropolitan se convierte por el turno en Fuerza y coste 5" — solo aplica una vez ya
convertido en Aliado y atacando; no se alcanzó a verificar con solidez la selección del
Aliado objetivo ni el timing exacto, se dejó sin implementar en vez de arriesgar un bug.

**Infraestructura adicional encontrada esta vez (al revisar de nuevo, como se pidió) que
NO se llegó a usar por falta de tiempo:** `ContinuousEffectManager.gain_control_of_card()`
(robo de control de carta oponente, ya usado por "shedo titan" — serviría para iga ryu) y
`_main._card_name_search.open_and_wait()` ("nombra una carta" — serviría para Estación
Fantasma). Quedan documentadas aquí para la próxima tanda, para no tener que redescubrirlas.

**Siguen sin implementar:** Estación Fantasma, hojo-shi, iga ryu, hangar de la ciudadela,
la rueda de la fortuna. Cada una combina 2-3 mecanismos nuevos (ataque forzado cada turno,
bloqueo global de Botar/Desterrar, autodestrucción condicional por daño, "agrupar" cartas,
conversión múltiple de Tótems) — con la infraestructura adicional recién encontrada el
trabajo restante es menor de lo que parecía en §12.6, pero no se alcanzó a completar con
la misma solidez que el resto en este pase.

**Sin verificar en partida real todavía** — mismo motivo que el resto de esta sesión.

### 12.8 Tercera tanda de Tótems — la rueda de la fortuna y metropolitan completas; hojo-shi revela un problema real de arquitectura (2026-09-20)

**A pedido del usuario ("sigue con estos 5"),** tercera tanda sobre el mismo fork de
§12.6-12.7. Build reexportado, **0 errores de parseo**.

**la rueda de la fortuna — completa, sus 2 cláusulas:** revela la carta superior del
Castillo (sin sacarla), tus Aliados en juego ganan Fuerza permanente igual al coste de esa
carta (mismo criterio de pump puntual que Kuchiku Kan, no un aura a futuro); si es un Oro,
puedes tomarlo y robar una carta. Segunda cláusula: se autodestruye para dar protección a
tus Aliados este turno, reutilizando el campo `protection_type: "ALL"` del sistema de
Protección ya existente — cobertura real pero parcial (solo cubre los puntos del código que
de verdad consultan esa protección hoy, no es una garantía absoluta contra todo efecto).

**metropolitan — ahora completa, sus 3 cláusulas.** Se agregó la última ("cuando ataca, un
Aliado que no sea Metropolitan se convierte por el turno en Fuerza y coste 5"), que dispara
de forma natural una vez que metropolitan ya se convirtió en Aliado vía su propia
habilidad de Vigilia (§12.7) y ataca.

**iga ryu, Estación Fantasma, hangar de la ciudadela — 1 cláusula cada una:**
- iga ryu: solo el ETB "gana el control de cualquier carta oponente" (reutiliza
  `ContinuousEffectManager.gain_control_of_card()`, ya usado por "shedo titan"). La rama
  alternativa "agrupa dos cartas" quedó sin implementar — no existe ningún verbo
  "Agrupar"/`is_tapped` en todo el motor (el juego no modela tapear/agrupar cartas como
  mecánica genérica), así que antes de inventar algo hay que confirmar contra el DAR qué
  significa realmente "agrupar" en este contexto.
- Estación Fantasma: solo la activada "nombra una carta, tu oponente baraja las que
  controle con ese nombre" (reutiliza `_card_name_search.open_and_wait()` y
  `ActionModule.return_to_deck()`).
- hangar de la ciudadela: solo el ETB "tu oponente baraja una carta de su mano y tú robas
  dos" — de paso se encontró que `main.opponent_hand` no existe como tal; la mano real del
  oponente (con datos reales, aunque se muestre boca abajo en la UI) vive en
  `main._opponent_fan`, corregido para usar la referencia correcta.

**hojo-shi — sin tocar, y con un hallazgo de arquitectura más importante que la carta
misma:** el bloqueo global de Botar/Desterrar existe como gancho en `ActionValidator.gd`,
pero resultó **poco confiable como mecanismo real** — la mayoría de las llamadas a
Botar/Desterrar del proyecto (incluidas varias agregadas esta misma sesión, ver §12.5)
pasan `skip_validation=true` y se saltan ese validador por completo, así que un bloqueo
puesto ahí no gatearía casi ningún caso real hoy. "Debe atacar todos los turnos" tampoco
tiene ningún precedente de ataque forzado en `PhaseFlowController.gd`. **No es un problema
de esta carta puntual — es deuda de arquitectura preexistente** (`ActionValidator` como
punto único de verdad para Botar/Desterrar no se cumple en la práctica): si se necesita
implementar hojo-shi (o cualquier otra carta futura con el mismo tipo de restricción), hay
que decidir primero si se endurece `ActionValidator` como gate real (auditando cada
`skip_validation=true` existente) o si se diseña la restricción de otra forma.

**Pendientes sin tocar, documentadas para una futura tanda:** hojo-shi (ambas cláusulas,
ver arriba); iga ryu (silencio al primer Aliado bajo control rival cada turno, conversión
múltiple de Tótems en Aliados de Fuerza 4); Estación Fantasma (prevenir daño de hasta 2
Aliados con Furia propios + destierro proporcional a la Fuerza del oponente); hangar de la
ciudadela (bloqueo de ataque/habilidad para Aliados de coste o Fuerza 0, autodestrucción
condicional al ser botada por daño desde el Castillo).

**Sin verificar en partida real todavía** — mismo motivo que el resto de esta sesión.

### 12.9 Bug real encontrado en revisión de código: kotoku-in y metropolitan disparaban su habilidad de Vigilia al ENTRAR en juego, no al activarla (2026-09-20)

**No reportado por el usuario — encontrado por el coordinador al verificar una alerta del
fork de Armas** (§12.10 más abajo): al implementar `try_execute_sable_corto_vigilia_
pattern()`, ese fork identificó y documentó un riesgo real en el despachador compartido
`_resolve_look_and_play_patterns()` (ver su docstring en `TriggerResolution.gd`): la misma
función se recorre tanto para resolver una habilidad ACTIVADA real (con el texto YA AISLADO
a una sola cláusula, vía `StackStepResolver._resolve_ability()`) como para el trigger
`on_enter_play` de Aliados/Armas/Oro (con el texto COMPLETO de la carta, SIN aislar). Una
función de habilidad activada que solo revisa "¿mi texto de gatillo está en el string que
recibí?" sin distinguir el contexto se dispara igual en ambos casos.

El fork de Armas se protegió a sí mismo para sus funciones nuevas (guardia `"el portador
gana" not in texto` en `sable_corto_vigilia_pattern`, y sacó `canon_naval_final_pattern` de
la lista compartida por completo) — pero las funciones de Tótems de tandas ANTERIORES
(§12.7) no tenían esa guardia. Se verificó el camino real con `Card.has_trigger()`/
`CardTriggerRuntime.gd`: solo se ve afectado un Tótem si tiene una cláusula "cuando entra en
juego" REAL (si no la tiene, ni siquiera se lo encola para `on_enter_play`, así que la rueda
de la fortuna y Estación Fantasma NO estaban afectadas — solo importa cuando el mismo Tótem
tiene una cláusula de entrada Y una cláusula activada por separado).

**Confirmado afectados y corregidos:**
- **kotoku-in**: jugarlo disparaba de inmediato la elección "Destruir carta ≤2 / anular
  próximo Talismán rival", en vez de esperar a la activación real en Vigilia. Guardia
  agregada: `if "genera un oro por el turno" in lower: return false` (su propia cláusula de
  entrada, ausente en una activación real con texto ya aislado).
- **metropolitan**: jugarlo lo convertía en Aliado de inmediato, en vez de esperar la
  activación real en Vigilia. Guardia agregada: `if "genera un oro para aliados" in lower:
  return false`.

Build reexportado tras el fix, **0 errores de parseo**. Sin verificar en partida real
todavía, pero el mecanismo del bug (y de la corrección) quedó confirmado leyendo el camino
real de ejecución, no solo por inspección superficial.

**Nota para el futuro:** cualquier función nueva de habilidad ACTIVADA que se registre en
`_resolve_look_and_play_patterns()` para una carta que TAMBIÉN tenga una cláusula "cuando
entra en juego" propia necesita esta misma guardia (o sacarse de la lista compartida, como
hizo `canon_naval_final_pattern`). Vale la pena, en algún momento, endurecer el despachador
mismo para que distinga el contexto (p.ej. un parámetro `is_isolated: bool`) en vez de
confiar en que cada función nueva recuerde agregar su propia guardia de texto — deuda de
diseño anotada, no resuelta esta sesión.

### 12.10 Primer lote de Armas: 6 de 8 completas o mayormente completas (2026-09-20)

**A pedido del usuario ("sigue con otro grupo entonces"),** grupo de 8 Armas del grupo de
539 sin cobertura (mismo origen que §12.4), en paralelo/después de los Tótems. Archivo
nuevo `scripts/core/effects/triggers/WeaponAbilityPatterns.gd`. Build reexportado,
**0 errores de parseo**, verificado que las 9 funciones nuevas existen realmente en el
código.

**Completas o mayormente completas:**
- **Cañón Naval**: efecto compartido activado/al-salir (oponente bota 5 + destierra hasta 3
  de un Cementerio) + activada de Fase Final (bota 2 propias para generar 1 Oro, sin
  restricción de para qué sirve, interpretando "agrupar" como "generar" igual que el resto
  del catálogo de esta sesión).
- **flechar xoon**: al salir, destierro opcional de coste ≤2. Su cláusula de Anular (una vez
  por turno, sube una carta a mano para Anular Talismán/Tótem ≤2) se implementó en
  `EffectController.offer_flechar_xoon_annul()` — mismo mecanismo real que Almirante Akari
  (`offer_counter_annul()`; este motor no modela una pila interceptable de verdad, "Anular"
  se resuelve como "destruir justo cuando la carta objetivo termina de entrar/resolver").
- **sable corto**: reducción de coste "si controlas Armas" (nueva rama en `PaymentManager.
  _conditional_boolean_discount()`) + activada de Vigilia (elige un Aliado, el oponente bota
  tantas cartas como su Fuerza) — con la guardia `"el portador gana" not in texto` que
  motivó el hallazgo de §12.9.
- **nehushtan**: al salir, Roba dos cartas. Su bloqueo de Botar/Desterrar en Línea de
  Defensa NO se implementó — mismo hallazgo de deuda de arquitectura que hojo-shi (§12.8):
  `ActionValidator` no es un gate confiable por el uso generalizado de `skip_validation=true`.
- **azusa yumi**: bono de Fuerza dinámico por copias controladas + daño al Destierro (nueva
  rama en `GoldManager._register_weapon_strength_bonus()`, reutilizando `Card.damage_goes_
  to_exile` de §12.6) + entra/sale: robas 1, oponente bota 2.
- **nodachi**: "Talismanes cuestan un Oro adicional" para ambos jugadores — nueva
  `GoldManager._register_weapon_talisman_tax()`, **primer uso real de un coste ADICIONAL
  (positivo) en el proyecto** (`PaymentManager.agregar_modificador_coste()` solo se había
  usado con valores negativos hasta ahora) + ETB: mira mano rival, descarta hasta 2
  Talismanes cuyo coste sume ≤2. Su cláusula de Fuerza condicional por raza + "no puede ser
  Barajado" quedó sin implementar — esa protección específica no existe en ningún lado del
  proyecto todavía.

**Sin implementar:**
- **kabutowari**: ninguna cláusula — pero se agregó una guardia en `_register_weapon_
  strength_bonus()` para que el parser genérico NO le aplicara un bono de Fuerza FIJO
  incorrecto (su ganancia real es dinámica y condicionada a la fase "Guerra de Talismanes",
  habría sido un bug nuevo y no reportado, detectado al escribir este código antes de que
  llegara a producción).
- **Armadura Celestial**: solo su cláusula de recuperación (descartar una carta para
  recuperarla del Cementerio a la mano) al salir del juego. Su habilidad "Destruir el
  portador para Anular un Talismán o cancelar una habilidad" quedó sin implementar — sin
  disparador ni objetivo claro identificado en este motor todavía.
- Las excepciones de FASE en que se puede jugar el Arma fuera del timing normal (nehushtan
  "en Guerra de Talismanes", azusa yumi "al comienzo de cualquier Fase", kabutowari "en la
  Declaración de Bloqueo") no se tocaron — el punto único de verdad que regula cuándo se
  puede jugar una carta es compartido por TODO el catálogo, no seguro de tocar en este pase.

**Sin verificar en partida real todavía** — mismo motivo que el resto de esta sesión.

### 12.11 Primer lote de Oros: 5 de 8 completas, 2 hallazgos de arquitectura nuevos (2026-09-20)

**A pedido del usuario ("otro grupo"),** grupo de 8 Oros reales (`Constants.CardType.ORO`,
no confundir con los Talismanes-jugados-como-Oro de §12.5/§12.11 — ver corrección de tipos
en §12.4) del grupo de 539 sin cobertura. Archivo nuevo
`scripts/core/effects/triggers/OroAbilityPatterns.gd`. Build reexportado, **0 errores de
parseo**, verificado que las 7 funciones nuevas existen realmente en el código.

**Completas, todas sus cláusulas:**
- **hidromiel**: ETB — baraja hasta 3 cartas de los Cementerios + roba 2.
- **udjat**: activada "una vez por turno" (un Aliado gana/pierde 1 Fuerza este turno, o
  baraja una carta de mano para robar) + activada de Fase Final (destierra 1 de tu
  Cementerio para desterrar hasta 2 del Cementerio rival) — reutiliza el picker de
  Cementerio ya usado por Mariano Osorio/Primer Sello.
- **torii**: "Oro Inicial"/"Única" ya cubiertos gratis por infraestructura existente (§12.5)
  + cláusula de Agrupación (mirar 2 cartas del Castillo, elegir una para la mano, sin robar
  al final del turno si se usó) + cláusula de Fase Final (robar si tienes ≤2 cartas en
  mano). Se agregaron 2 frases nuevas a `Card.TRIGGER_KEYWORDS` que faltaban ("al comienzo
  de tu agrupación", "en la fase final, si tienes" — esta última angosta a propósito para no
  colisionar con "en la fase final oponente" de Biblioteca de Caballería).
- **Llave del Abismo**: aura permanente (+1 Fuerza e Indestructible a tus Aliados) + reactiva
  (cuando un Aliado con Furia propio entra en juego, el oponente bota una carta) —
  implementada con un chequeo directo en `GoldManager._trigger_enter_play()` (mismo criterio
  que Primer Sello/Los Siete Sellos) en vez de depender del parseo de frases de trigger,
  porque el texto real ("cuando un Aliado CON FURIA entra... BAJO TU CONTROL") no calzaba
  con ninguna frase fija existente.
- **libro de thoth**: activada "una vez por turno, paga 1 Oro" (roba 1 + elige entre Furia,
  duplicar Fuerza o daño al Destierro este turno, con reversión real de un turno vía
  `GameManager.turn_started`, mismo mecanismo que Segundo Sello).

**Parcial:** libro de thoth — su cláusula "Cuando bloquees, genera un Oro por el turno"
quedó SIN implementar por un hallazgo de arquitectura (ver abajo).

**Deferidas por completo:**
- **compendium maleficarum**: restringir qué cartas puede jugar el oponente por nombre no
  tiene precedente en el proyecto, y se descubrió que el único choke point real de
  validación para el jugador humano (`PaymentManager.puede_jugar_carta()`) **nunca se llama
  para el bot** (`EasyBotController` usa `GameState.puede_pagar()` directo) — una
  implementación correcta habría exigido parchear dos caminos distintos de golpe.
- **Alicanto** (el Oro, Raza Dragón — no confundir con el Aliado homónimo, Raza Bestia,
  carta totalmente distinta): ambas cláusulas dependen de infraestructura que no existe (ver
  hallazgo abajo) y la conversión "de la mano directo a Oro Pagado" es distinta de cualquier
  conversión ya implementada en el proyecto (todas operan sobre cartas YA en juego).

**Hallazgo de arquitectura nuevo — dos tipos de trigger completamente muertos en el motor:**
`on_block` y `on_damage_received` están clasificados por texto en `Card.TRIGGER_KEYWORDS`
(así que el juego SABE que una carta tiene ese tipo de habilidad) pero **no tienen ningún
branch de resolución en `TriggerResolution.gd`** — no es un caso aislado de libro de
thoth/Alicanto, es un hueco real del pipeline de triggers que bloqueará cualquier carta
futura con "cuando bloquees" o "en respuesta a que fueras a recibir daño" hasta que se
construya ese pipeline completo (recolección + resolución), no solo el patrón de la carta
puntual.

**Sin verificar en partida real todavía** — mismo motivo que el resto de esta sesión.

### 12.12 Bug real encontrado revisando libro de thoth: "este turno" duraba un turno de más (afecta también a Segundo Sello) (2026-09-20)

**A pedido del usuario ("revisa por ejemplo el libro de thoth"),** revisión de código
manual (no un fork) sobre `try_execute_libro_de_thoth_pay_pattern()` (§12.11). La rama
"su daño es enviado al Destierro este turno" reutilizaba el mecanismo de `Card.damage_goes_
to_exile` + limpieza vía `GameManager.turn_started` que introdujo Segundo Sello (§12.5) —
y copió fielmente un bug que ya estaba ahí sin detectar: el callback de limpieza filtraba
`if started_player_id != owner_id: return`, es decir, esperaba a que volviera a ser el
turno del MISMO jugador que activó la habilidad para recién limpiar el flag. Resultado
real: el efecto seguía activo durante TODO el turno del oponente de más — un turno entero
más de lo que dice el texto ("este turno"), inconsistente además con el modificador de
+2 Fuerza del propio Segundo Sello en el mismo bloque de código, que sí usa
`ModifierDuration.UNTIL_END_TURN` (limpia en `_on_turn_ended()` sin filtrar por jugador,
confirmado leyendo `ContinuousEffectManager._on_turn_ended()`).

**Corregido en los dos lugares que compartían el mecanismo** (`SearchOwnZonePatterns.gd`
— Segundo Sello — y `OroAbilityPatterns.gd` — libro de thoth): se quitó el filtro por
jugador, el flag se limpia ahora en el PRÓXIMO `turn_started` sin importar de quién sea,
igual que cualquier otro efecto "este turno" del proyecto. Build reexportado, **0 errores
de parseo**.

**Nota:** este bug ya estaba en producción desde §12.5 (Segundo Sello, documentado ahí como
"completo") — no se detectó en su momento porque nadie volvió a revisar ese código hasta
ahora. Vale la pena, en algún momento, auditar si algún otro efecto "este turno" del
proyecto usa el mismo patrón de filtro por jugador en vez de `ModifierDuration.UNTIL_END_
TURN` o un callback sin filtrar — no se hizo una búsqueda exhaustiva de más casos esta vez.

**Sin verificar en partida real todavía** — mismo motivo que el resto de esta sesión.

### 12.13 Pipeline `on_block` construido desde cero — libro de thoth queda completo (2026-09-20)

**A pedido del usuario ("una de las habilidades del libro es que cuando bloquees generas
oro por el turno"),** se cerró el hueco de arquitectura documentado en §12.11: el trigger
`on_block` no tenía ningún branch de resolución en todo el motor.

**Pipeline construido, siguiendo el molde exacto de `on_attack`:**
- `EffectController.gd`: nueva señal `on_card_blocks(player_id, card)`.
- `GameManager.gd`: nueva función `confirm_blockers_and_collect_triggers()` — por cada
  bloqueador realmente confirmado, emite la señal y recolecta `on_block` vía
  `TriggerSystem._collect_triggers_for_event()`. **No se reutilizó** la función existente
  `confirm_blockers()` — verificado por grep que nunca tenía ningún call site real en todo
  el proyecto (código muerto), y contenía además un reset manual de `priority_player_id`/
  `players_passed_priority` que hoy ya maneja solo `PriorityManager` escuchando
  `phase_changed`; reutilizarla arriesgaba pisar ese estado. Queda documentada como
  huérfana en el propio código, no se borró.
- `PhaseFlowController.gd`: el único call site real (rama `Constants.Phase.BLOQUEO` de
  `_on_priority_both_passed_main()`) pasó de llamar `GameManager.advance_to_phase()` directo
  a `await GameManager.confirm_blockers_and_collect_triggers()`.
- `TriggerResolution.gd`: nueva rama `elif trigger_type == "on_block":`, para el caso de una
  habilidad "cuando bloquee" impresa en el propio Aliado bloqueador (mismo aislamiento de
  cláusula que `on_attack`). Ningún Aliado del catálogo actual la usa todavía, pero el
  camino queda listo para la próxima carta que la necesite.

**libro de thoth NO pasa por ese camino genérico** — su cláusula es de una carta Oro pasiva
reaccionando a que TU Aliado bloquee, no una habilidad impresa en el propio bloqueador (el
despachador genérico solo alcanza a la carta que disparó el evento). Se resolvió aparte con
`GoldManager.check_libro_de_thoth_block()` — chequeo directo del Oro en Reserva/Oro Pagado,
mismo patrón que Llave del Abismo (§12.11) — que genera 1 Oro sin restricción vía
`generar_oro_virtual_restringido()`. **libro de thoth queda completo, sus 2 cláusulas.**

Build reexportado, **0 errores de parseo**, verificado que no queda ningún call site
huérfano apuntando a la función vieja `confirm_blockers()`.

**Sin verificado en partida real todavía**, y con una advertencia extra por tocar una
función core del flujo de batalla: no se pudo hacer una prueba de humo jugando una partida
real. Se verificó estáticamente que la rama de Bloqueo era el único call site real, que
`blockers` se limpia cada Vigilia (sin arrastre entre batallas), y que `controller_id` (no
`owner_id`) es la propiedad correcta para "quién controla ahora" — pero recomendado probar
la fase de Bloqueo específicamente antes de seguir construyendo sobre este pipeline nuevo.

### 12.14 Bug real reportado por el usuario tras probar §12.13: "se queda pegado en Guerra de Talismanes, el botón ¿Paso? desaparece" (2026-09-20)

**Confirmado que este es el mismo bug recurrente ya documentado dos veces antes** (ver
`PhaseFlowController._try_recover_stuck_phase_priority_window()`, comentarios 2026-09-04 y
2026-09-06: una ventana de prioridad ANIDADA que `StackStepResolver._execute_step_d()` abre
sobre la misma instancia de `PriorityManager` cuando algo pasa por la pila del
`ActionPipeline` durante Bloqueo/Guerra de Talismanes a veces no se restaura al cerrarse,
dejando `priority_window_active=false` con la fase todavía "viva" y ningún botón con qué
reaccionar). Ya existía una función de recuperación para exactamente este estado, pero
**nunca se podía disparar desde la UI**: `update_paso_button_state()` ocultaba el botón
`¿Paso?` en esta misma condición (`priority_window_active=false` + fase Guerra de
Talismanes/Bloqueo no está en la lista `relevant_phase` de la rama sin ventana activa) —
círculo cerrado, sin salida real para el jugador.

**Corregido:** `GameHUDModule.update_paso_button_state()` ahora mantiene el botón visible en
Guerra de Talismanes/Bloqueo sin ventana activa, sin importar de quién sea `active_player_id`
(mismo motivo que ya obligó a usar `PriorityManager.current_priority_player` en vez de
`active_player_id` en la rama CON ventana activa: defendiendo, el oponente es el jugador
activo pero la prioridad de defensor te toca a ti primero, DAR 5.C3). Al presionarlo,
`PhaseFlowController._on_paso_pressed()` ya llama `_try_recover_stuck_phase_priority_window()`
en esa rama (código preexistente, sin tocar) — si de verdad no hay nada que recuperar, no
hace nada y el jugador ve "Sin ventana de prioridad activa" en vez de quedarse sin ningún
botón. Build reexportado (con rescan de caché de clases primero — `CombatJuiceModule` volvió
a dar el mismo error de indexado que `GameOverOverlay` en §12, ver nota del usuario), **0
errores de parseo**.

**No se investigó la causa raíz de por qué la ventana anidada de Paso D no se restaura**
(sería la tercera vez que se ataca el síntoma en vez del origen) — es posible que la nueva
recolección de `on_block` de §12.13 haya hecho más frecuente un race condition preexistente
al agregar awaits nuevos justo en la costura entre el cierre de la ventana de Bloqueo y la
apertura de la de Guerra de Talismanes, pero no se confirmó con certeza. Este fix hace el
síntoma recuperable desde la UI sin más fricción, no lo elimina de raíz. Sin verificar en
partida real todavía.

## 13. Integración real con ShadowForge: login in-game + mazos públicos (2026-09-22)

**A pedido del usuario** ("que te conectes con tu cuenta de ShadowForge y te salgan tus
mazos privados, si quieres mazos públicos también puedes hacerlo"). Ya existía bastante
código (`ExternalApiClient.gd`, `DeckSelector._fetch_mazos()`) pero nunca se había probado
con credenciales reales, y el único "login" posible era editar a mano `user://shadowforge_
credentials.json` — sin pantalla dentro del juego.

**Investigación previa (la parte más valiosa de esta tarea):** se bajó y grepeó el bundle JS
compilado REAL del frontend Angular de `shadow-forge-deck.vercel.app` (`main-*.js` + sus
~34 chunks lazy-loaded, no solo el archivo inicial) para confirmar los endpoints reales en
vez de seguir adivinando. Se encontró el `AuthService` y el `DeckService` completos del
sitio real:

- `POST /api/auth/google/` con un `credential` (ID token de Google Identity Services) —
  **Google Sign-In existe en el sitio**, Client ID público `739285382559-c10lo6ddtaa7j7fi
  07halv5jr1e6laju.apps.googleusercontent.com` confirmado — pero NO se implementó: depende
  de que el origen desde donde corra el script de Google esté autorizado para ese Client
  ID, algo fuera de control de este proyecto y no verificable sin probarlo en vivo. El
  usuario preguntó por esto explícitamente y aceptó priorizar login normal en su lugar.
- `GET /api/decks/public/?search=&page=&format=&race=&ordering=` → `{results, count}` —
  **listado real de mazos públicos**, paginado, con búsqueda de texto y filtros por formato
  (imp/esc/imp_r/fx/pe/pb) y raza. No existía ningún endpoint de listado conocido antes de
  esta sesión — el único precedente (`tools/import_public_deck.ps1`) traía un mazo público
  puntual por ID ya conocido, no permitía buscar.
- `GET /api/decks/public/{id}/` — coincide exactamente con lo que ya usaba (y ya tenía
  verificado en producción) `tools/import_public_deck.ps1`.
- `GET /api/decks/my/?search=&page=&format=&race=&ordering=` → mismo shape `{results,
  count}` — **reemplaza** `/external/my-decks/`, que el propio código admitía nunca haber
  podido verificar ("no se pudo verificar sin credenciales reales", parser a ciegas
  probando varias claves posibles). El login (`/external/token/`) NO se tocó — ya estaba
  verificado en producción por el mismo script de PowerShell, y su token (campo `access`,
  confirmado también en el `AuthService` real del sitio) es el mismo que ya usa `/decks/
  public/{id}/` con éxito, así que es razonable esperar que sirva igual para el resto de
  `/decks/*`.

**Implementado:**
- `ExternalApiClient.gd`: `fetch_my_decks()` corregido a `/decks/my/` con el shape real
  (parser simplificado, ya no adivina claves). Nuevas: `fetch_public_decks()`,
  `fetch_public_deck_entries()`, `fetch_my_profile()`, `save_credentials()`, `logout()`.
- Pantalla de login real: `scripts/menu/ShadowForgeLogin.gd` + `scenes/menu/ShadowForgeLogin.
  tscn` (mismo estilo que `OnlineConnect.gd`) — usuario/contraseña, estado de carga/error,
  cerrar sesión. Botón nuevo "SHADOWFORGE" en `MainMenu`.
- `DeckSelector.gd`: botón "Mazos públicos de ShadowForge" abre un popup con búsqueda +
  lista + paginación; al elegir uno arma un `Dictionary` con la misma forma que ya consume
  `_populate_options()`, reutilizando el carrusel/selección/confirmación existentes sin
  duplicar el pipeline de carga.

Build reexportado (con rescan de caché de clases primero, `ShadowForgeLogin` es
`class_name` nuevo), **0 errores de parseo**.

**Sin verificar con una cuenta real todavía** — el fork no tiene credenciales de
ShadowForge; solo se confirmó que compila y la UI se arma bien. Falta que el usuario
(que sí tiene cuenta real) pruebe: login real, que `/decks/my/` responda de verdad con el
shape esperado, y que el token de `/external/token/` autorice contra toda la familia
`/decks/*` (confirmado solo para `/decks/public/{id}/` hasta ahora).

### 13.1 Eliminada la zona de "TESTEO" del menú principal (2026-09-22)

**A pedido del usuario** ("elimina el botón de testeo y todo lo que contenía"). Se
verificó primero que nada del juego real dependía de esos scripts — las únicas menciones
fuera de `scripts/test/` eran comentarios de texto en `ContinuousEffectParser.gd`/
`ActionExecutor.gd` citando un bug encontrado ahí, no imports ni dependencias reales.

- `MainMenu.gd`/`MainMenu.tscn`: sacado el botón "TESTEO" (nodo, `@onready var`, conexión
  de señal, handler `_on_test_pressed()`), `VBoxContainer` reajustado a la altura de 6
  botones.
- Borrados por completo: `scripts/test/` (`TestScene.gd`, `TestCardLoader.gd`,
  `TestCardResolvers.gd`, `TestUIBuilder.gd`, `TestActionLog.gd`,
  `TestCardInspectionFromLog.gd`, `TestPauseMenu.gd`) y `scenes/test/TestScene.tscn`.
- No se tocó `CardDatabase.run_smoke_test()` (atajo F9 en `DebugInputModule.gd`) — vive en
  `CardDatabase.gd`, no en la zona de testeo, y el usuario pidió específicamente el botón
  del menú, no los atajos de depuración en partida.

Build reexportado (con rescan de caché primero), **0 errores de parseo**, confirmado por
grep que no queda ninguna referencia colgante a `res://scenes/test` ni `res://scripts/test`
en ningún `.tscn`/`.gd` del proyecto.

### 13.2 "Mis mazos" fusiona privados + públicos en un solo carrusel (2026-09-22)

**A pedido del usuario** ("la idea es que el botón mis mazos te muestre los mazos privados
y públicos"). Hasta ahora los públicos solo se podían ver detrás de un popup de búsqueda
aparte (§13). Build reexportado, **0 errores de parseo**, verificado que todo el código
nuevo existe realmente.

**Bug real encontrado y corregido de paso (antes de que llegara a probarse con una cuenta
real):** ni `/decks/my/` ni `/decks/public/` (las dos listas resumidas, ver §13) traen
`entries` — solo datos de vista previa. `_on_confirm_pressed()` emitía el mazo elegido TAL
CUAL sin `entries` desde que se cambió a estos endpoints reales — confirmar uno de tus
mazos de ShadowForge habría arrancado una partida con el mazo vacío, en silencio, sin que
nadie lo notara hasta jugar con una cuenta real.

**Corregido:**
- `ExternalApiClient.fetch_my_deck_entries(deck_id)` — nueva, misma forma que
  `fetch_public_deck_entries()` pero contra `GET /decks/my/{id}/` (Bearer auth). Señales
  propias (`my_deck_detail_received`/`_failed`), separadas de las de mazos públicos para no
  cruzar resultados si ambos fetches están en vuelo a la vez.
- `DeckSelector._on_external_decks_received()`: etiqueta cada mazo privado con
  `_shadowforge_kind = "my"`, y en vez de poblar el carrusel directo, encadena
  `_fetch_and_merge_public_decks()` — trae una primera página de públicos ordenada por
  "popular", los agrega a `_mazos` con `"<mazo> — por <owner>"` en el nombre (diferenciación
  visual mínima, sin tocar el layout de las cards) y `_shadowforge_kind = "public"`, y
  recién ahí puebla el carrusel. El popup de búsqueda (§13) sigue intacto para buscar algo
  puntual más allá de esa primera página.
- `_needs_entries_fetch()`/`_resolve_deck_entries()`: al confirmar (jugador U oponente
  aleatorio), si el mazo elegido no tiene `entries` todavía, se bajan on-demand según su
  `_shadowforge_kind`, con timeout de salvaguarda de 20s y error visible en vez de fallo
  silencioso; si falla el mazo del oponente aleatorio, cae a un preset/local de respaldo en
  vez de arrancar la partida vacía.

**Sin verificar con cuenta real** — mismo motivo de siempre. En particular, `/decks/my/{id}/`
(el endpoint nuevo de este cambio) nunca se probó puntualmente; `/decks/public/{id}/` sí
está confirmado en producción por `tools/import_public_deck.ps1`, misma familia de API,
mismo patrón esperado pero no idéntico hasta probarlo.

### 13.3 Bug real: borrar `scripts/test/` no alcanzaba — quedaba un artefacto de exportación cacheado (2026-09-22)

**Reportado por el usuario tras probar el build de §13.1:** errores de parseo citando
`res://scripts/test/TestScene.gd` — un archivo ya borrado. Causa real: **misma familia de
bug que la bitácora ya documenta en §12** (artefactos huérfanos en `.godot/exported/` que
sobreviven al borrado de su fuente real y se siguen empaquetando en el `.pck`) — esta vez
no eran miles de `.ctex` sueltos, sino un solo `.godot/exported/133200997/export-<hash>-
TestScene.scn`, el cacheo de la escena convertida de `TestScene.tscn`. Ni borrar los `.gd`
ni el rescan de caché de clases (`--headless --editor --quit-after 60`) lo tocaba, porque
ese comando reindexa `class_name`, no purga artefactos de exportación ya generados.

**Corregido:** se borró ese artefacto (y el `.cfg` de folding del editor para ese mismo
archivo) a mano, después rescan + reexport normales. Build reexportado, **0 errores de
parseo**, confirmado por grep que no queda ninguna referencia real a los scripts de test
borrados en `.godot/` (solo quedan 3 archivos de estado de UI del editor — pestañas
abiertas, layout de docks — que nunca se empaquetan en un export, inofensivos).

**Nota para el futuro:** si al borrar un archivo con escena/script propio (`class_name`,
`.tscn`) el build sigue fallando después de un rescan normal, revisar
`.godot/exported/*/export-*-<NombreDelArchivoBorrado>.*` antes de asumir que el borrado no
se aplicó de verdad.

### 13.4 "Mazos" se quedaba cargando para siempre — sin vigía global sobre la cadena de fetches (2026-09-22)

**Reportado por el usuario tras probar §13.1-13.3:** el selector de mazos se queda en
"Invocando grimorios ancestrales..." y nunca termina. Causa real: la cadena de carga tiene
3 pasos encadenados (mazos privados → mazos públicos → `_populate_options()`), cada uno con
su propio timeout HTTP individual (15-20s), pero **ningún límite global sobre la cadena
completa** — si cualquier eslabón no dispara ninguna de sus señales (`decks_received`/
`_failed`, `public_decks_received`/`_failed`), nada fuerza el fallback y la pantalla de
carga queda así para siempre.

**Corregido:** nuevo `_mazos_load_resolved: bool`, marcado en los dos caminos TERMINALES
reales (`_populate_options()`, `_populate_with_error()`) y chequeado al principio de cada
callback intermedio (`_on_external_decks_received/_failed`,
`_on_initial_public_decks_received/_failed`) para no reprocesar si ya se resolvió por otro
lado. Un vigía de 25s (`get_tree().create_timer(25.0)`, más que cualquier timeout HTTP
individual) fuerza `_load_local_fallback()` si para entonces nada resolvió solo — que ya
mostraba "No se encontraron grimorios disponibles" (§ ya existente, `_populate_with_error()`)
si ni los mazos preset ni los locales aparecen, cubriendo exactamente el pedido del usuario
("si no tengo mazos, que me salga no se han encontrado mazos").

**No se identificó con certeza la causa raíz original del colgado** — la hipótesis más
probable, no confirmada, es que `iterva.pythonanywhere.com` (hosting gratuito de
PythonAnywhere) tarde mucho en "despertar" tras estar inactivo, lo cual en casos extremos
podría superar incluso el timeout HTTP individual de 15-20s de forma intermitente. El vigía
de 25s convierte esto de "cuelgue permanente" a "espera larga con resultado garantizado",
pero no lo acelera. Build reexportado, **0 errores de parseo**.

### 13.5 §13.1 no había limpiado todo: quedaba un `test_scene.tscn` duplicado suelto en la raíz del proyecto (2026-09-22)

**El error de `TestScene.gd` volvió a aparecer** después de §13.3 (que arregló UN artefacto
de caché huérfano) — esta vez ni borrar de nuevo `.godot/exported/` completo alcanzaba: el
mismo error reaparecía export tras export. Causa real encontrada con
`find . -iname "*TestScene*"` sobre el proyecto ENTERO (no solo `.godot/`): existía un
**`test_scene.tscn` duplicado, suelto en la raíz del repo** (no en `scenes/test/`, que sí se
había borrado bien en §13.1) — un archivo aparentemente viejo, nunca visto ni buscado fuera
de esa carpeta, que seguía apuntando a `res://scripts/test/TestScene.gd`. Cada rescan del
editor lo volvía a indexar (`filesystem_cache10`) y a empaquetar en el build, sin importar
cuántas veces se limpiara la caché de exportación.

**Corregido:** borrado `test_scene.tscn` (raíz), confirmado por grep que nada lo
referenciaba, más una limpieza de caché más agresiva esta vez (`.godot/exported/` completo
+ `.godot/editor/filesystem_cache10`, no solo el artefacto puntual). Se verificó también que
no quedan copias sueltas de ningún otro script de la zona de testeo fuera de `scripts/test/`
(ya borrado). Build reexportado, **0 errores de parseo**.

**Nota para el futuro, más importante que la de §13.3:** al borrar una carpeta completa,
buscar el nombre del archivo en TODO el proyecto (`find . -iname "*NombreDelArchivo*"`), no
asumir que la única copia vivía en la carpeta borrada — este archivo llevaba ahí sin que
nadie lo supiera hasta que el propio error de build lo delató.

### 13.6 `test_scene.tscn` seguía resucitando solo — la causa real era `editor_layout.cfg`/`project_metadata.cfg` (2026-09-22)

**El mismo error volvió una TERCERA vez** después de §13.5 (que borró el duplicado suelto
en la raíz) — el archivo `test_scene.tscn` reaparecía en disco con el MISMO tamaño exacto
después de cada rescan del editor, incluso habiendo confirmado su ausencia justo antes.
Causa real: `.godot/editor/editor_layout.cfg` tenía `current_scene="res://test_scene.tscn"`
y lo listaba en `open_scenes`/`open_scripts` (la escena y el script quedaron "abiertos" en
la última sesión real del editor, antes de que existiera esta limpieza) —
`.godot/editor/project_metadata.cfg` lo repetía en su propia lista `scenes=[...]`. Al
arrancar el editor headless para el rescan, Godot intenta reabrir esas pestañas guardadas, y
algo en ese camino termina reescribiendo el archivo en disco — no se confirmó el mecanismo
interno exacto, pero bastaba con que la referencia siguiera en esos `.cfg` para que
resucitara sin importar cuántas veces se borrara el `.tscn` o se limpiara
`.godot/exported/`.

**Corregido de raíz:** se editaron a mano `editor_layout.cfg` (sacado `test_scene.tscn` de
`open_scenes`/`current_scene`, y `TestScene.gd` de `open_scripts`) y `project_metadata.cfg`
(sacado de `scenes=[...]`), más `script_editor_cache.cfg` (sacada la sección
`[res://scripts/test/TestScene.gd]` completa) y los cachés de folding/UID sueltos
(`.godot/editor/test_scene.tscn-folding-*.cfg`, `.godot/uid_cache.bin` — este último se
regenera solo, seguro de borrar). Recién con estos 3 archivos de estado del editor limpios
—no solo el `.tscn` y `.godot/exported/`— el archivo dejó de resucitar: verificado con 2
rescans + export consecutivos sin que reapareciera.

**Nota para el futuro, la más importante de las tres de esta sesión:** si un archivo
borrado sigue reapareciendo después de limpiar su carpeta, el duplicado en otro lado, Y
`.godot/exported/`, revisar `.godot/editor/editor_layout.cfg` y
`.godot/editor/project_metadata.cfg` por si el editor lo recuerda como "pestaña abierta" de
una sesión anterior — ese estado sobrevive tanto al borrado del archivo real como a la
limpieza de caché de exportación.

**Actualización — la causa real de por qué seguía resucitando:** volvió a aparecer una
CUARTA vez después de esto mismo. La explicación real: hay una instancia del editor de
Godot con INTERFAZ GRÁFICA abierta en la máquina (no solo las invocaciones `--headless` de
esta sesión) que todavía tiene `test_scene.tscn` como pestaña de una sesión vieja — cada vez
que esa instancia guarda su estado (o se reabre), recrea el archivo y reescribe
`editor_layout.cfg`/`script_editor_cache.cfg` con la referencia vieja, sin importar cuántas
veces se limpien desde acá. Si esto vuelve a pasar: cerrar esa pestaña en el editor gráfico
real (o cerrar el editor del todo) antes de limpiar los `.cfg` de nuevo — si el editor
gráfico sigue abierto con la pestaña vieja, la limpieza dura hasta el próximo guardado suyo.

### 13.7 Portada real de los mazos de ShadowForge en el carrusel de "mis mazos" (2026-09-22)

**A pedido del usuario** ("será posible que los mazos además muestren la imagen como de
portada"). El carrusel de selección (`DeckSelector._build_deck_card()`) ya tenía un slot de
ilustración interior ("DeckCoverInlay", dentro del marco de cuero del tomo) — hasta ahora
siempre mostraba una de 9 texturas genéricas por raza (`_get_card_texture()`), nunca la
portada real del mazo.

**Implementado:** si el mazo tiene `image_url` (mazos de ShadowForge, privados o públicos —
ver §13), se baja de forma asíncrona (`_load_deck_cover_image()`, mismo mecanismo que
`DeckManager._load_cover_image()`: webp/png/jpg, `ImageTexture.create_from_image()`) y
reemplaza la ilustración genérica en cuanto termina — la genérica queda de placeholder
mientras carga, sin hueco en blanco. **Bug encontrado de paso:** los 2 lugares donde se
arma el Dictionary de un mazo público (`_on_initial_public_decks_received()` para la
fusión automática, `_on_public_deck_detail_received()` para el popup de búsqueda) nunca
copiaban `image_url` del dato real de la API al Dictionary interno que usa el carrusel —
se agregó en ambos. Los mazos privados (`"my"`) no necesitaron el mismo arreglo: su
Dictionary se usa tal cual viene de la API, sin reconstruirlo, así que ya traía el campo.

Build reexportado, **0 errores de parseo**. Sin verificar con cuenta real todavía — mismo
motivo de siempre.

### 13.8 Separador visual entre "mis mazos" y "mazos públicos" en el carrusel (2026-09-22)

**A pedido del usuario** ("que estén separados los mazos públicos y privados, primero los
míos, en otra columna los públicos"). El orden real de `_mazos` ya ponía privados+presets
primero y públicos al final (§13.2) — solo faltaba hacer esa separación visualmente obvia
en el carrusel, que es una sola tira horizontal con flechas, no columnas de verdad.

**Implementado:** `_build_section_divider()` — un separador angosto (línea dorada +
etiqueta vertical "MAZOS PÚBLICOS DE SHADOWFORGE") insertado en `_populate_options()` justo
antes de la primera carta pública, detectando la transición por `_shadowforge_kind`. Es un
`Control` aparte, nunca se agrega a `_player_cards`, así que los índices de selección
(`_selected_player_idx` / `_mazos`) no se desalinean con las cartas reales — el separador es
puramente visual, no ocupa un slot de mazo. Solo aparece si hay al menos un mazo "mío" antes
del primer público (si el jugador no tiene ninguno propio, no hay nada que separar).

Build reexportado, **0 errores de parseo**. `test_scene.tscn` volvió a aparecer una quinta
vez durante este mismo pase (confirma la causa real de §13.6/13.7: una instancia gráfica
del editor sigue viva en la máquina y restaura su sesión vieja) — limpiado de nuevo antes de
exportar. Sin verificar con cuenta real todavía.

### 13.9 La causa REAL de "no encontró los mazos" en 2 PCs: `_get_preset_decks()` leía `user://decks/` en vez de los presets embebidos en el `.exe` (2026-09-23)

**Diagnóstico propio, sin esperar otra prueba del usuario:** se agregó un log temporal en
`DeckLoader._ready()` llamando `get_bundled_decks()` al arrancar, se reexportó, y se corrió
el `.exe` ya exportado en modo `--headless` en esta misma máquina — confirmó que
`get_bundled_decks()` (lee `res://data/decks/*.json`, los 8 presets EMBEBIDOS en el propio
`.exe`) funciona perfecto: **8 mazos encontrados**, siempre, sin depender de nada externo.

**La causa real estaba en otro lado:** `DeckSelector._get_preset_decks()` — la función que
arma la lista de "mazos preset" que se suma a los privados de ShadowForge — usaba
`DeckLoader.get_local_decks()` en vez de `get_bundled_decks()`. `get_local_decks()` lee
`user://decks/`, una carpeta **por máquina** que en cualquier instalación nueva del `.exe`
empieza completamente vacía. En la máquina de desarrollo "funcionaba" de pura casualidad —
ahí se acumularon **183 mazos** guardados en esa carpeta a lo largo de toda esta sesión
(exports de prueba, `export_deck_for_bundling()`, etc.), así que el bug quedó invisible acá
hasta que el usuario probó en una PC realmente limpia (dos, de hecho) y `get_local_decks()`
devolvió 0 — sin ShadowForge (login pendiente/fallido) y sin presets, `_mazos` terminaba
vacío del todo: "No se encontraron mazos", el bug real reportado.

**Corregido:** `_get_preset_decks()` ahora combina `get_bundled_decks()` (primero, SIEMPRE
disponible, garantiza que el carrusel nunca esté vacío en una PC nueva) con
`get_local_decks()` (extra, si la máquina tiene algo guardado localmente), deduplicando por
`slug`. Se sacó el log temporal de diagnóstico una vez confirmada la causa.

**De paso:** se agregó `[debug] file_logging/enable_file_logging=true` a `project.godot` y
se cambió `export_presets.cfg` (`debug/export_console_wrapper` de `1` "automático" — sin
consola en release — a `2` "siempre") porque hasta ahora no había NINGUNA forma de ver la
consola ni un log real desde el `.exe` empaquetado — cada bug reportado por el usuario exigía
adivinar a ciegas. Ahora cada partida deja un log real en
`user://logs/godot.log` (`%APPDATA%\Godot\app_userdata\Mitos y Leyendas\logs\`).

Build reexportado, **0 errores de parseo**. Verificado en esta máquina que
`get_bundled_decks()` sigue devolviendo 8 mazos tras el cambio — pendiente que el usuario
confirme en una PC limpia que el carrusel ya no aparece vacío.

### 13.10 Logging limpiado + login/fetch de ShadowForge verificado 100% funcional contra la API real (2026-09-23)

**A pedido del usuario** ("eliminar tanto log innecesario, quiero entender lo que está
pasando" + "sigo sin poder conectar con los mazos revisalo bien").

**Limpieza de logging:** se agregó `Constants.VERBOSE_DIAG_LOGS: bool = false` y se
apagaron detrás de ese flag los 5 prints `[DIAG]` que disparaban en cada click/cambio de
prioridad (`GameHUDModule.update_paso_button_state()` x2, `CardInteraction.gd` gui_input
x2, `PhaseFlowController.gd` x3) — quedan disponibles con solo poner el flag en `true` si
hace falta cazar un bug similar de nuevo, sin reescribir nada. Se borró por completo (no
gateado, sin valor real) el spam `[CardDatabase] Posible Oro: ...` — un debug viejo que
además tenía falsos positivos (matcheaba cualquier nombre que contuviera "oro" como
substring: "orochimaru", "tesoro", "dorotea").

**Verificación exhaustiva de ShadowForge, en dos capas independientes:**
1. `curl` directo contra la API real (`https://iterva.pythonanywhere.com/api`) con las
   credenciales guardadas (`Tomas`/`Bastian123`) — `POST /external/token/` devolvió 200 con
   token real; `GET /decks/my/` con ese token devolvió 200 con **2 mazos privados reales**
   ("Caballero combo", "tumamita") en el shape exacto ya documentado en §13. Confirma que
   la API, las credenciales y los endpoints están bien de punta a punta, fuera del juego.
2. Prueba temporal DENTRO del juego real: se conectó `fetch_my_decks()` directo a
   `ExternalApiClient._ready()` (dispara solo al arrancar el autoload, sin depender de
   llegar al selector de mazos), se reexportó, y se corrió el `.exe` ya exportado en modo
   `--headless` en esta máquina (nota: `--quit-after N` cuenta FRAMES, no segundos — en
   headless sin vsync corren casi instantáneo, hacía falta `timeout <segundos_reales>` sin
   `--quit-after` para dejar que la red real respondiera). Resultado: **`decks_received: 2
   mazo(s)`** con los mismos 2 mazos reales — confirma que el camino completo
   (`ExternalApiClient` → señales → parseo) funciona perfecto dentro del propio juego
   exportado, no solo por curl. Prueba temporal sacada una vez confirmado.

**Conclusión:** no se encontró ningún bug en el código de login/fetch — está probado
funcionando de punta a punta, dos veces, por dos caminos independientes. Si el jugador
sigue sin ver sus mazos reales, las causas que quedan son o bien específicas de la otra PC
(credenciales nunca cargadas ahí — son por máquina, `user://shadowforge_credentials.json —
o red/firewall distinto ahí) o una cuestión de reconocer visualmente sus 2 mazos reales
entre los ~30 que ya muestra el carrusel (nombran "Caballero combo"/"tumamita", sin
distinción visual fuerte hoy más allá del nombre — no tienen `image_url` en la respuesta de
`/decks/my/`, así que usan el arte genérico de raza como cualquier preset, ver §13.7).

Build reexportado, **0 errores de parseo**.

### 13.11 "No se pudo cargar este mazo (revisa tu conexión)" al confirmar — también probado y funcionando en aislamiento; diagnóstico preciso agregado para la próxima prueba real (2026-09-23)

**Progreso confirmado por el usuario:** el carrusel ya muestra mazos (§13.9/§13.10
funcionaron) — el error nuevo aparece un paso más adelante, al CONFIRMAR un mazo privado
para jugar: `_resolve_deck_entries()` (§13.2) devuelve vacío, mostrando el mensaje de error.

**Se probó `fetch_my_deck_entries()` específicamente** (no solo `fetch_my_decks()`, ya
probado en §13.10) con el mismo método de dos capas: `curl` directo a
`GET /decks/my/150/` (mazo real "Caballero combo") → 200, `entries[]` completas y bien
formadas; y una prueba sintética temporal DENTRO del `.exe` real (conectada a
`ExternalApiClient._ready()`, llamando `fetch_my_deck_entries(150)` directo) →
`my_deck_detail_received` disparó con **33 entries reales**. Ambas capas funcionan
perfecto, igual que en §13.10 — no se encontró ningún bug reproducible en aislamiento.

**No se pudo reproducir el error real** porque `_resolve_deck_entries()`/
`_on_confirm_pressed()` viven en `DeckSelector` (no es autoload, no se puede disparar sin
pasar por la UI real: cargar cartas, llegar al selector, elegir un mazo y confirmar) — a
diferencia de `ExternalApiClient`, no hay forma de invocar este camino específico desde un
`--headless` sintético sin escribir un arnés de prueba mucho más grande.

**En vez de seguir adivinando, se agregaron 3 prints PRECISOS y permanentes (no gateados
por `Constants.VERBOSE_DIAG_LOGS` — baja frecuencia, alto valor) directo en el camino real**
(`_resolve_deck_entries()`): nombre/id/kind del mazo al entrar, y al salir si `done` se
cumplió por señal o por timeout de 20s, y si el resultado quedó vacío. La próxima vez que
el usuario confirme un mazo y vea el error, el log real va a mostrar exactamente en qué
paso se cae (id inválido, autoload no encontrado, timeout de verdad, o señal de fallo real
con su razón) — algo que hasta ahora solo se podía inferir a ciegas.

Build reexportado, **0 errores de parseo**. Sin resolver todavía — pendiente el próximo log
real del usuario.

**Actualización — probada también la secuencia REAL completa (my_decks → public_decks →
deck_entries), no solo la llamada aislada:** mismo resultado, las 3 funcionaron en cadena
sin ningún problema (`decks_received 2`, `public_decks_received 20/40`,
`my_deck_detail_received entries=33`). Tampoco se reprodujo así. La causa real del cuelgue
de 20s en la partida real del usuario sigue sin identificarse — los 3 prints agregados en
`_resolve_deck_entries()` (arriba) quedan como la mejor pista disponible para el próximo
log real.

### 13.12 Barrido de español neutro sobre todo el código agregado en §13 (2026-09-23)

**A pedido del usuario** ("todo el layout... no me puede preguntar 'querés jugar'") —
encontró voseo real en el popup de "JUGAR" agregado esta sesión. Se hizo un barrido
completo (no solo ese caso puntual) sobre TODO lo agregado en la sección §13
(ShadowForge, fusión de mazos, separador visual, logging) buscando voseo, "acá" y "recién"
en sentido rioplatense — el código de secciones anteriores (§1-§12) ya se había limpiado en
una sesión previa y no se volvió a auditar completo, solo lo nuevo.

**Corregido:**
- `MainMenu.gd`: `"¿Cómo querés jugar?"` → `"¿Cómo quieres jugar?"` (el bug reportado,
  título del popup de elegir modo de juego, §13.9 mid-sesión).
- `CardInteractionModule.gd`: `"elegí a qué atacante rival"` → `"elige a qué atacante
  rival"` (texto real mostrado al jugador al declarar bloqueo, no era nuevo de esta
  sesión — se coló en una limpieza anterior).
- 4 "acá" → "aquí" (comentarios en `DeckSelector.gd` x3, `Constants.gd` x1 — todos
  agregados en esta misma sesión, §13).
- 5 "recién" en sentido rioplatense ("no antes de que...") → "solo"/"justo" según el caso
  (`DeckSelector.gd` x2, `SelectionManager.gd`, `GoldManager.gd` x2). Se revisaron también
  otros ~15 usos de "recién" en el resto del código — todos en el sentido neutro universal
  de "hace poco/apenas" ("carta recién jugada", "copia recién creada"), no rioplatense, se
  dejaron sin tocar.
- 1 "elegí" (comentario, no texto de jugador) en `PreventionAbilityHandler_AE.gd` (x2) y
  `GoldManagerTax.gd` (x1).

**Verificado limpio tras la corrección:** grep de voseo (vos/querés/podés/tenés/etc.),
"acá" y "dale" sobre todo `scripts/` y `scenes/` — sin resultados nuevos. `.tscn` sin
ningún texto hardcodeado en voseo.

Build reexportado, **0 errores de parseo**.

### 13.13 Hipótesis fuerte para el cuelgue de 20s: hasta 20 descargas de portada simultáneas saturando la red — limitadas y canceladas al confirmar (2026-09-23)

**El usuario reprodujo el mismo cuelgue exacto una segunda vez, idéntico** (`done=false
waited=20.0s`, sin ninguna señal, ni éxito ni error) — descarta definitivamente que haya
sido casualidad de una sola corrida. Dado que las pruebas sintéticas (§13.10/§13.11, dos
veces, incluida la secuencia real completa de 3 llamadas) SIEMPRE funcionaron sin
excepción, hay que buscar la diferencia real entre esas pruebas y la partida real —no el
código de fetch en sí, ya probado en aislamiento repetidas veces.

**Diferencia real encontrada:** las pruebas sintéticas nunca pasan por
`DeckSelector._build_deck_card()` — solo llaman `ExternalApiClient` directo. La partida
real sí: con hasta ~20 mazos públicos mostrados en el carrusel (§13.2/§13.8), cada uno
dispara su propia descarga de portada (§13.7) — hasta **20 `HTTPRequest` simultáneos hacia
Cloudinary** apenas se puebla el carrusel. Es la única diferencia real identificada entre
ambos escenarios. **No confirmado con certeza absoluta** (no se pudo reproducir el cuelgue
en ningún entorno de prueba propio para verificarlo de forma directa), pero es la hipótesis
más fuerte disponible y una limitación real de todos modos (nada bueno sale de 20 conexiones
HTTP simultáneas para portadas decorativas).

**Corregido:**
- `_load_deck_cover_image()` ya no dispara la descarga directo — encola en
  `_cover_image_queue` y `_process_cover_image_queue()` respeta un tope real de
  `MAX_CONCURRENT_COVER_DOWNLOADS = 3` simultáneos, arrancando la siguiente de la cola
  recién cuando una termina.
- `_on_confirm_pressed()`: nueva `_cancel_all_cover_image_downloads()` — vacía la cola Y
  cancela de verdad (`HTTPRequest.cancel_request()`) cualquier descarga de portada
  todavía en vuelo apenas el jugador confirma un mazo, liberando cualquier capacidad de
  red disponible antes del pedido crítico (`/decks/my/{id}/` o `/decks/public/{id}/`).

Build reexportado, **0 errores de parseo**. Los 3 prints de diagnóstico en
`_resolve_deck_entries()` (§13.11) se dejan en su lugar — si el cuelgue vuelve a pasar
DESPUÉS de este fix, confirma que la hipótesis de las portadas era incorrecta y hay que
seguir buscando; si no vuelve a pasar, la confirma sin necesidad de más instrumentación.

### 13.14 §13.13 no era la causa — mismo cuelgue exacto con las portadas ya limitadas; instrumentación profunda a nivel de `HTTPClient` (2026-09-23)

**El usuario reprodujo el cuelgue una TERCERA vez, idéntico**, ya con el límite de 3
portadas concurrentes y la cancelación al confirmar de §13.13 aplicados — descarta esa
hipótesis. `done=false waited=20.0s` sigue siendo el único síntoma, sin importar qué se
ajuste alrededor de la llamada.

**Instrumentación mucho más profunda agregada, directo en `_authed_request()`**
(`ExternalApiClient.gd`, el choke point real de TODA petición autenticada — no solo del
caso que falla): imprime el código de retorno de `http.request()` apenas se llama
(confirma si el pedido arrancó bien a nivel de Godot), y sondea cada 2 segundos mientras
espera `http.get_http_client_status()` + `http.get_downloaded_bytes()` — el estado real
interno del `HTTPClient` (conectando, resolviendo DNS, enviando, esperando respuesta,
etc.), algo que hasta ahora era una caja negra completa. La próxima vez que el usuario
reproduzca el cuelgue, el log va a mostrar en qué paso EXACTO del ciclo de vida de la
conexión HTTP se traba — ya no hay más terreno para hipótesis sin confirmar, esto debería
señalar la causa raíz real de una vez.

Build reexportado, **0 errores de parseo**. Sin resolver todavía — pendiente el próximo
log real del usuario, esta vez con detalle a nivel de protocolo.

### 13.15 CAUSA RAÍZ REAL ENCONTRADA: `_on_confirm_pressed()` sin guarda de re-entrada — 3 clicks de impaciencia mandaban 3 pedidos simultáneos al mismo mazo (2026-09-23)

**El log con la instrumentación profunda de §13.14 reveló la causa real.** Dos datos
decisivos en el mismo log:
1. `status=6` (`HTTPClient.STATUS_REQUESTING`) — la conexión se establece bien (DNS,
   TCP, TLS todo OK), el pedido se manda, pero el servidor nunca responde. No es un
   problema de conectividad del cliente — es el servidor el que no contesta.
2. **`[DeckSelector] _resolve_deck_entries: nombre='Caballero combo' id=150 kind='my'`
   aparece 3 VECES SEGUIDAS** en el mismo log, cada una con su propio
   `request(.../decks/my/150/) -> err=0` — `_on_confirm_pressed()` se llamó 3 veces para
   el mismo mazo. El botón "Confirmar" no tenía ninguna guarda contra re-entrada: como no
   había NINGÚN feedback visible mientras `_resolve_deck_entries()` esperaba (ni el botón
   se deshabilitaba, ni había señal de "ya se está procesando" más allá del texto del
   banner), el jugador —razonablemente, ante la falta de respuesta visible— clickeó
   "Confirmar" 2 veces más, disparando 3 pedidos **simultáneos** al mismo endpoint
   (`GET /decks/my/150/`). El backend gratuito de PythonAnywhere (probablemente un solo
   worker/proceso) recibió las 3 peticiones a la vez y ninguna llegó a resolverse dentro
   de los 20s de espera — coincide exactamente con el patrón observado (las 3 tardan
   `waited=20.0s` iguales, ninguna con éxito ni error real, solo timeout).

**Esto explica también por qué nunca se pudo reproducir en pruebas sintéticas**: todas las
pruebas anteriores (§13.10, §13.11, dos veces) llamaban `fetch_my_deck_entries()` UNA sola
vez cada vez — nunca 3 veces en simultáneo contra el mismo recurso.

**Corregido:** nueva guarda de re-entrada `_confirming: bool` en `DeckSelector` —
`_on_confirm_pressed()` ahora ignora clicks repetidos mientras ya está procesando uno, y
además deshabilita físicamente `_btn_confirm_clicker` (`disabled = true`) durante la
espera, reactivándolo solo si el mazo falla en cargar (para poder reintentar) — en éxito no
hace falta, la pantalla cambia. Se sacó la instrumentación pesada de sondeo cada 2s en
`ExternalApiClient._authed_request()` (§13.14, ya cumplió su función) — se dejan los 3
prints livianos de `_resolve_deck_entries()` (§13.11) por si hace falta confirmar en el
futuro que el fix realmente cerró el problema.

Build reexportado, **0 errores de parseo**. Sin verificar todavía con el usuario que el fix
resuelve el síntoma de verdad, pero la causa raíz quedó identificada con evidencia directa
del log real (no es una hipótesis sin confirmar, como las dos anteriores) — 3 llamadas
simultáneas visibles en el propio log, algo que el código nunca debería haber permitido.

### 13.16 §13.15 no era la causa completa — la guarda de re-entrada funcionó (confirmado: solo 1 llamada) pero UN solo pedido también se cuelga 20s exactos (2026-09-23)

**El usuario probó de nuevo con la guarda de §13.15 puesta.** Buena noticia parcial:
`_resolve_deck_entries` apareció **una sola vez** en el log — la guarda de re-entrada
funciona, ya no hay clicks duplicados. Mala noticia: el mismo cuelgue de
`waited=20.0s result_vacio=true` pasó igual, con un solo pedido, sin concurrencia. Esto
descarta que las 3 llamadas simultáneas de §13.15 fueran la ÚNICA causa (aunque de todos
modos era un bug real que valía la pena arreglar).

**Nueva hipótesis, la más simple que queda sin descartar:** dado que `status=6`
(`STATUS_REQUESTING`) en §13.14 ya mostró que la conexión se establece bien y el pedido se
manda, y que ni `curl` ni las pruebas sintéticas propias tardan nada — el backend gratuito
de PythonAnywhere podría simplemente tardar en "despertar" tras estar inactivo (comportamiento
conocido de ese hosting) más de lo que el proyecto le daba de margen (20s). No hay forma de
confirmar esto con certeza sin verlo completar tarde.

**Corregido (probando esta hipótesis directamente):** subidos todos los timeouts de HTTP
en `ExternalApiClient.gd` — login 15s→30s, `_authed_request()` (el que usan
`fetch_my_decks()`/`fetch_my_deck_entries()`) 20s→60s, `fetch_public_decks()` 20s→60s,
`fetch_public_deck_entries()` 20s→60s. El timeout de salvaguarda espejo en
`DeckSelector._resolve_deck_entries()` subido de 20s a 60s para que coincida (si el
`HTTPRequest` interno completa recién a los 35-40s, la espera de arriba tiene que alcanzar
para verlo).

**Cómo leer el próximo resultado:** si el mazo carga bien esta vez (aunque tarde más),
confirma que era lentitud real del backend gratuito, no un bug — y probablemente valga la
pena, en una sesión futura, agregar un "ping" de precalentamiento apenas arranca el juego
en vez de hacer esperar al jugador recién al confirmar. Si se cuelga otra vez EXACTAMENTE a
los 60s, descarta la lentitud y confirma que es un colgado real e indefinido — haría falta
investigar directo del lado del backend (fuera del alcance de este proyecto) o, como
recurso, mostrarle al jugador la opción de seguir con un mazo local mientras se resuelve.

Build reexportado, **0 errores de parseo**.


### 13.17 CAUSA RAÍZ REAL Y DEFINITIVA del cuelgue (por fin reproducido en esta misma máquina, sin depender del usuario) — bug de captura por valor en lambdas de GDScript, no un problema de red (2026-09-23)

**Se consiguió reproducir el cuelgue localmente por primera vez**, agregando una
automatización temporal (`--auto-test-deck`) que navega sola desde el menú hasta
confirmar el mazo "Caballero combo" sin clicks manuales, dentro del propio `.exe`
exportado. El cuelgue de `waited=60.0s result_vacio=true` se repitió exacto, tanto en
modo ventana real (con GPU/Vulkan) como en `--headless` — descartando de una vez la
teoría de que dependía del modo de ejecución.

Se probaron y descartaron, en orden, con pruebas reales contra este mismo repro:
`use_threads=false` en el `HTTPRequest` (sin cambio), no cancelar las descargas de
portada antes de confirmar (sin cambio), desactivar las portadas por completo (sin
cambio), header `Connection: close` (sin cambio). Una prueba aislada mínima (sin
DeckSelector, sin UI, solo `fetch_my_decks()` → esperar 2s → `fetch_my_deck_entries()`
directo desde el autoload) **no se colgó** — pero agregarle el `fetch_public_decks()`
concurrente que `DeckSelector._fetch_mazos()` también dispara **sí lo reprodujo**.

**Causa real, confirmada leyendo el código con lupa:** en GDScript, los lambdas
capturan las variables locales **por valor, no por referencia** (comportamiento
documentado del lenguaje, no un bug de Godot). `_resolve_deck_entries()` en
`DeckSelector.gd` usaba:
```gdscript
var done := false
var on_ok := func(deck_data): result = ...; done = true
```
La señal `my_deck_detail_received` **sí llegaba, casi al instante** (la petición HTTP
nunca fue el problema) — pero `done = true` dentro del lambda modificaba una copia
propia de esa variable, nunca la `done` que el bucle `while not done and waited < 60.0`
estaba mirando. El bucle jamás se enteraba de que ya había respuesta y agotaba siempre
el timeout completo, devolviendo `{}` (mazo vacío) pese a que el pedido real había
funcionado perfecto — coincide 100% con por qué `curl` y cualquier prueba que usara
`await señal` directo en vez de este patrón de sondeo con lambda siempre funcionaron.

**Arreglado** guardando el estado en un `Dictionary` en vez de variables sueltas
(`var _state := {"done": false, "result": {}}`, mutando `_state["done"]`/
`_state["result"]` adentro del lambda) — un `Dictionary` SÍ se captura por referencia
(la "copia por valor" es una copia del puntero al mismo objeto), así que mutar sus
claves adentro del lambda es visible afuera. Confirmado con el mismo repro automatizado:
el mazo real ahora se resuelve en menos de un segundo, sin cuelgue.

**Segundo bug real, escondido detrás del primero:** con el cuelgue resuelto, el mazo
"Caballero combo" SÍ llegaba pero fallaba igual con "No se encontraron cartas... usando
mazo aleatorio" — 33/33 cartas no encontradas. Confirmado con `curl` directo contra
`/decks/my/150/`: cada entry trae `"id": 25652` (la fila `DeckEntry` de ShadowForge, NO
la carta) y el `myl_id` real de la carta está anidado en `entry.card_detail.myl_id`
(ej. `"20584"`). `DeckLoader._process_external_deck_data()` y
`_process_deck_data()` usaban `entry.get("myl_id", entry.get("card_id", entry.get("id", "")))`
sin mirar `card_detail` — como ninguna entry real trae `myl_id`/`card_id` en el nivel
superior, siempre caía al `id` de la fila (equivocado), y el mazo del jugador NUNCA
había cargado sus propias cartas desde que se integró ShadowForge, cayendo siempre en
silencio al mazo aleatorio de respaldo. Arreglado en ambas funciones: se mira primero
`entry.card_detail.myl_id`.

**Verificado de punta a punta con el mismo repro automatizado:** "Caballero combo"
carga sus 49 cartas reales (33 únicas), sin cuelgue, sin caer a mazo aleatorio.
Toda la automatización temporal (`--auto-test-deck`, `--auto-test-raw` y los prints
`[AUTO-TEST]`/`[RAW-TEST]`) fue retirada del código tras confirmar el arreglo.

**Nota para el futuro:** el mismo patrón de captura por valor (`var race_done := false`
reasignado dentro de un lambda) existe también en
`scripts/core/effects/triggers/ConvertAndMiscResolver.gd:120-122` (resolución de
Castillo al Convertir). No se tocó en esta sesión por estar fuera de alcance, pero es
candidato a la misma clase de bug si algún jugador reporta que esa carrera no corta
bien al Castillo.

## 14. Fase 3 del plan de paridad remota — `SelectionManager` en red (2026-09-30)

**Contexto:** `docs/plans/2026-09-20-remote-multiplayer-parity.md` dejaba la Fase 3
("`SelectionManager` en red") como la pieza grande sin empezar — más de 100 sitios
reales del motor de efectos usan `SelectionManager`/`SelectionDialogs` para que el
jugador elija algo, y ninguno sabía que el "jugador" podía ser un Remoto real. El plan
mismo flageaba una decisión de diseño pendiente ("¿qué firma de retorno debe tener
`_delegate_to_remote()`...") para confirmar con el usuario antes de escribir código —
se auditaron las firmas reales primero, como pedía esa nota.

**Hallazgo de arquitectura que cambió el enfoque del plan (para mejor):** las "4
funciones" que el plan nombraba (`open_selection()`, `await_single_pick()`,
`await_multi_pick()`, `await_two_choice()`) NO son 4 puntos de entrada independientes.
`await_single_pick()`/`await_multi_pick()`/`open_search()`/`open_exhumar()` — y
cualquier llamador directo de `open_selection()`/`open()`, incluido el patrón a mano de
`ActionSearch._select_search_results()` (el camino real de "busca una carta", que ni
siquiera pasa por las 4 funciones nombradas) — todos terminan en el mismo
`SelectionManager.open_selection()`. `await_two_choice()` es aparte (en realidad
`await_choice()` con 2 opciones, UI de texto, no de grilla de cartas).
**Conclusión:** interceptar en `open_selection()` cubre la gran mayoría de los ~100
sitios de una sola vez, no 4 sitios cada uno con su propio chequeo.

**Hallazgo nuevo, no documentado en el plan:** casi todos los patrones "busca..." que
usan `SelectionManager` tienen una guarda `if controller_id != 0: return true  # el bot
no usa esta habilidad todavía` — HOY esas habilidades ni se disparan para el jugador 1
(bot o Remoto). Para la demostración de la Task 3.2 hacía falta una carta SIN esa
guarda — se usó **Kuchiku Kan** (Aliado, "Cuando entra en juego, busca un Aliado en tu
Castillo o Cementerio..."), la única revisada que llama a `ActionModule.search()` sin
ninguna restricción de `controller_id`. De hecho esto confirma un bug real YA
EXISTENTE sin relación con la red: hoy, si el BOT juega Kuchiku Kan con 2+ Aliados
candidatos, el picker se abre en la pantalla del humano local (quien termina eligiendo
por el bot) — no se tocó ese caso (sin sala de red activa, fuera de alcance de esta
sesión), solo se corrigió el camino cuando SÍ hay un Remoto real conectado.

**Implementado (Task 3.1 — puente genérico):**
- `NetworkClient.gd`: nuevo `await_intent(expected_kinds: Array) -> Dictionary`
  (lógica movida desde `RemotePlayerController._await_intent()`, que ahora delega aquí
  sin tocar sus 5 llamadores) — compartido entre `RemotePlayerController.gd` y
  `SelectionManager.gd`, mismo criterio que el plan pedía para `_card_public_data()`.
- `SelectionManager.open_selection()`: nuevo parámetro `chooser_id: int = 0` (default a
  propósito — ningún llamador existente de los ~100 sitios necesita cambiar). Si
  `chooser_id == 1 and NetworkClient.room_code != "" and NetworkClient.is_host`, en vez
  de abrir la UI local delega en `_delegate_selection_to_remote()`: manda
  `{"op":"prompt","kind":"select_cards",...}` con los candidatos que pasan el filtro
  (identificados por ÍNDICE en el array mandado — son `Dictionary` de datos crudos, no
  nodos Card con `instance_id`), espera `{"op":"intent","kind":"select_cards_choice",
  "indices":[...]}` vía `NetworkClient.await_intent()`, y emite las MISMAS señales
  (`card_selected`/`selection_completed`/`selection_cancelled`) que la UI local
  emitiría — así que todo lo que ya escucha esas señales (las 4 funciones de
  `SelectionDialogs.gd`, `open_search()`/`open_exhumar()`, y código con su propio loop
  de señales como `ActionSearch._select_search_results()`) funciona sin que haga falta
  tocarlo.
- `SelectionManager.open_search()` y `ActionSearch.search()`/`_select_search_results()`
  (incluida la recursión de `distinct_names`): threadearon `player_id` hasta
  `chooser_id` — único cambio fuera de `SelectionManager.gd` que hizo falta para la
  demo, porque es el único camino real que usa Kuchiku Kan.
- `RemoteMirrorController.gd`: nuevo caso `"select_cards"` (`_show_select_cards_prompt()`),
  mismo estilo de UI de texto sin pulir que `choose_wielder`/`declare_attackers` —
  1 clic si `max_selections == 1` (mismo criterio que el panel local cierra en el primer
  clic), checkboxes + Confirmar si es multi-selección, o un simple "Continuar" si
  `max_selections <= 0` (modo REVEAL, sin elección real).

**Task 3.2 (caso convertido):** Kuchiku Kan ya llegaba a `ActionModule.search()` sin
ninguna guarda — cero cambios en `SearchOwnZonePatterns.gd`. El `player_id`
(=`controller_id` de Kuchiku Kan) ya se threadea solo por la cadena de arriba.

**Criterio para convertir el resto de los ~100 sitios** (no se completó la Fase 3
entera, a propósito, mismo criterio ya usado en §10.14 y siguientes): cualquier patrón
de trigger que hoy tenga `if controller_id != 0: return true` y use
`SelectionManager`/`ActionSearch`/`await_single_pick`/`await_multi_pick`/`open_exhumar`
puede levantar esa guarda SIN tocar `SelectionManager.gd` — la cadena ya threadea
`chooser_id` donde `ActionSearch` está de por medio; los demás necesitan agregar
`chooser_id`/`player_id` como parámetro en su propia cadena de llamadas (mismo patrón
que se hizo acá para `open_search()`), apuntando siempre a `controller_id`. **Pendiente,
fuera de esta sesión:** `await_choice()`/`await_two_choice()` (la otra familia de UI,
popups de texto en vez de grilla de cartas) todavía no tiene el mismo puente — ningún
patrón que usa `await_two_choice()` llega hoy a ejecutarlo con `controller_id == 1`
(todos están guardados con `if controller_id == 0:` antes de esa llamada puntual), así
que no bloqueó la demo, pero hace falta el mismo tratamiento el día que se convierta un
patrón que sí lo necesite.

**Sin verificar en partida real todavía** — mismo motivo que el resto de la sesión de
multiplayer (§11, §12.2, §12.3): sin poder correr 2 instancias con interfaz gráfica
desde aquí. Verificación pendiente: Anfitrión y Remoto conectados por el relay real,
Remoto juega Kuchiku Kan con 2+ Aliados en su Castillo, confirmar que el prompt de
elección le llega a ÉL (no al Anfitrión) y que el Aliado elegido aparece en su mano.

### 14.1 Puente de `await_choice()`/`await_two_choice()` + 6 cartas más convertidas (2026-09-30)

**A pedido del usuario ("sigue con el resto"):** con el puente de `open_selection()`
probado (Kuchiku Kan), se completó la otra mitad de la Fase 3 y se convirtió un lote
chico más de cartas reales, deteniéndose ahí a propósito (ver más abajo por qué).

**Puente de `await_choice()`/`await_two_choice()`:** mismo criterio que
`_delegate_selection_to_remote()` (§14) — nuevo parámetro `chooser_id: int = 0` en
ambas funciones (`SelectionManager.gd` y, donde vive la implementación real,
`SelectionDialogs.gd`). Si `chooser_id == 1` y hay un Remoto real conectado, en vez de
abrir el popup de texto local se manda `{"op":"prompt","kind":"choose_option",...}`,
se espera `{"op":"intent","kind":"choose_option_choice","index":N}` vía
`NetworkClient.await_intent()`, y se devuelve el índice directo (esta función SÍ
devuelve un valor por `await`, a diferencia de `open_selection()` — no hizo falta
emular señales). `RemoteMirrorController._show_choose_option_prompt()` nuevo, mismo
estilo de fila de botones que el resto.

**113 sitios reales con `if controller_id != 0: return true  # el bot no usa esta
habilidad todavía` encontrados** (16 archivos de `scripts/core/effects/triggers/`) —
número real confirmado por grep, no estimado. Lejos de "unos pocos sitios más". Dado el
riesgo real de convertir a ciegas (muchos patrones mezclan `SelectionManager` CON
`CardInteractionModule.await_target()`/`await_multi_target()` u otros diálogos a medida
como `await_card_pair_choice()`/`ZoneViewerModule.open_cemetery_target_picker()` —
ninguno de esos otros dos sistemas tiene puente de red todavía — convertir solo la
MITAD de un patrón mixto deja la otra mitad mostrándole el popup al Anfitrión en vez
del Remoto, un bug sutil y peor que no tocar nada), se le preguntó al usuario cuánto
seguir y eligió una tanda chica.

**6 cartas convertidas, todas usando ÚNICAMENTE mecanismos ya bridgeados
(`SelectionManager.await_two_choice()`/`ActionModule.search()`/`ActionModule.draw()`,
nunca `CardInteractionModule`/`ZoneViewerModule`/diálogos a medida) — mismo cambio
mecánico en cada una: borrar la guarda `if controller_id != 0: return true` y agregar
`controller_id` como último argumento a cualquier `await_two_choice()` de la función
(no hace falta en `ActionModule.search()`/`draw()`, que ya threadean `player_id` solo):**
- `SearchOwnZonePatterns.gd`: La Torre, Dulce Canasta, alto prime (simétrica para los
  dos jugadores, sin ningún diálogo — solo 2 `ActionModule.search()` en loop `[0, 1]`),
  Belta, Aurora de Chile (doble búsqueda secuencial, sin diálogo).
- `ShuffleDrawPatterns.gd`: Escarapela Nacional.

**Efecto secundario conocido, mismo que ya se documentó para Kuchiku Kan (no es nuevo,
solo se extiende a más cartas):** en partida local contra el BOT (sin sala de red
activa), estas 6 habilidades ahora SÍ disparan cuando el bot juega esas cartas — y como
`EasyBotController` no tiene lógica real para decidir, el diálogo se le muestra al
humano local, que termina eligiendo por el bot. Antes, la guarda hacía que el bot
simplemente nunca activara estas habilidades (silencioso). Se considera preferible
(la habilidad SÍ se resuelve, aunque la elija la persona equivocada) a que siga sin
implementarse para el bot — no se tocó para arreglarlo "bien" (requeriría IA real en
`EasyBotController`, fuera de alcance de esta sesión).

**Verificado con el headless check (`--check-only`) después de cada tanda — sin
errores de parseo. Sin verificar en partida real todavía**, mismo motivo que el resto.

**Quedan 107 sitios** (113 menos los 6 de arriba) para conversión incremental futura —
criterio para elegir el próximo lote: preferir patrones que usen SOLO
`SelectionManager`/`ActionSearch` (ya bridgeados) por sobre los que mezclan
`CardInteractionModule`/`ZoneViewerModule`/diálogos a medida (esos necesitan su propio
puente antes, uno nuevo por sistema).

### 14.2 Bug de diseño real encontrado al convertir más cartas: "quién elige" no siempre es "de quién es la zona" — 6 cartas más + fix de infraestructura (2026-09-30)

**A pedido del usuario ("dale nomás lo que consideres correcto"):** se encontró un bug
real en el diseño de §14/§14.1 antes de que llegara a afectar una partida real —
`ActionSearch.search(player_id, ...)` asumía que `player_id` (de quién es la zona/
destino buscado) es siempre quien ELIGE qué cartas se llevan. Eso es cierto para "busca
en TU Castillo" (la mayoría, §14.1), pero NO para "busca en el Castillo OPONENTE y
Destiérralas": ahí `player_id` = la víctima (su Castillo, su Destierro), pero quien
decide QUÉ desterrar es el controlador de la habilidad. Con el bridge tal cual estaba,
convertir una carta así hubiera enrutado la elección al jugador EQUIVOCADO en una
partida online real (la víctima elige qué le destruyen a sí misma, en vez del atacante).

**Arreglado:** nuevo parámetro `chooser_id: int = -1` en `ActionModule.search()`/
`ActionSearch.search()` — default -1 significa "usar player_id" (cero cambios para
cualquier llamador existente que no lo pase, incluidas las 7 cartas ya convertidas en
§14/§14.1, donde `player_id` siempre coincidía con `controller_id`). Los patrones que
buscan en zona RIVAL ahora pasan `controller_id` explícito como 11º argumento. También
`TargetedEffectExecutor._choose_search_zone_owner()` (helper compartido por varios
patrones): su rama Cementerio (`await_two_choice("¿Tu Cementerio o el del oponente?")`)
ahora pasa `controller_id` como chooser — la rama Castillo sigue sin bridge (usa
`await_castillo_pick()`, el diálogo a medida todavía no convertido, ver §14/§14.1).

**6 cartas más convertidas** (mismo criterio de §14.1: solo mecanismos ya bridgeados,
nunca `CardInteractionModule`/`ZoneViewerModule`), 3 de ellas ejercitando el fix nuevo
de arriba (zona rival ≠ quién elige):
- `BanishOpponentPatterns.gd`: ea poe (paga Oros + destierra del Castillo rival, sin
  búsqueda interactiva — solo `await_choice` para el monto), shoki (elige Cementerio
  propio/rival vía `_choose_search_zone_owner`, luego destierra 2 de ahí —
  `chooser_id=controller_id` explícito), resistencia de acero (busca 3 en el Castillo
  RIVAL — `chooser_id=controller_id` explícito, el caso que expuso el bug).
- `PlayFromCemeteryPatterns.gd`: aku aku.
- `TotemAbilityPatterns.gd`: metropolitan.
- `OroAbilityPatterns.gd`: torii.

**Total acumulado: 13 de 113 sitios convertidos.** Verificado con el headless check
después de cada paso — sin errores. **Sin verificar en partida real todavía**, mismo
motivo que el resto de la sesión. Se frenó la conversión acá por decisión propia (no
hay más candidatos "solo con mecanismos bridgeados" triviales sin auditar cada uno a
mano) — quedan 100 sitios, mismo criterio de §14.1 para elegir el próximo lote.

### 14.3 6 cartas más (19 de 113) + confirmado el próximo bloqueo real: `ZoneViewerModule`/`CardInteractionModule` sin puente (2026-09-30)

**A pedido del usuario ("sigamos integrando las cartas de la Fase 3"):** Garfio Pirata,
almirante akari, El Rey y el Verdugo, la rueda de la fortuna (revelado), arco del
triunfo y Fisión Nuclear — mismo criterio de siempre (solo `SelectionManager.
await_two_choice()`/`await_choice()`/`ActionModule.search()`/`draw()`, cero
`CardInteractionModule`/`ZoneViewerModule`). Dos de estas (El Rey y el Verdugo, arco
del triunfo) manipulaban `CardManager.shuffle_deck()` directo sin la animación de
barajado — mismo bug que Azi Sruvara (§15, ver más abajo en el documento) —
corregido de paso en ambas.

**Auditado a fondo y descartado por ahora: `DSR_CemeteryBanishDraw.gd` (7 sitios) +
`WeaponSearchShuffleExecutor.gd` (3 sitios) + varios sueltos en otros archivos.** Todos
dependen de `ZoneViewerModule.open_cemetery_target_picker()` (el picker de "ambos
Cementerios lado a lado con click directo") y/o `CardInteractionModule.await_target()`/
`await_multi_target()` — ninguno de los dos tiene puente de red. A diferencia de
`SelectionManager` (candidatos = `Dictionary` planos, sin nodos), `ZoneViewerModule`
instancia Nodos Card TEMPORALES y asume SIEMPRE "jugador 0 = propio, jugador 1 =
rival" en vez de mirar `controller_id` — bridgearlo es una tarea aparte, más grande que
lo hecho hasta ahora para `SelectionManager`, no una extensión incremental trivial.

**Total acumulado: 19 de 113.** Criterio para seguir: lo que queda SIN tocar
`CardInteractionModule`/`ZoneViewerModule` es cada vez más escaso (se audita cada
patrón entero a mano, no hay atajo) — el siguiente salto de productividad real
necesita el puente de `ZoneViewerModule.open_cemetery_target_picker()`, no más
barrido manual de lo que queda.

## 15. Jabberwocky y Azi Sruvara: habilidades faltantes implementadas + 3 bugs reales encontrados en el camino (2026-09-30)

**A pedido del usuario** ("necesito que veas la habilidad de yaberwokki y azi
zubara" + "implementa el azi como el yabber"), auditadas y completadas ambas:

**Jabberwocky** — faltaba la cláusula "Cuando entra en juego o ataca, convierte la
primera carta del Castillo oponente en un Oro sin habilidad y ponlo en tu Oro Pagado"
(la otra cláusula, el descuento de coste, ya estaba en `PaymentManager.gd`).
Implementada en `ConvertAndMiscResolver.gd` (`try_execute_jabberwocky_convert_
opponent_top_pattern`), mismo mecanismo de conversión real a Oro que `GoldManager.
convert_ally_to_gold_in_pagado()` (Jormundgander)/`try_execute_no_allies_convert_
castillo_top_pattern()` (Biblioteca de Caballería): re-tipar los datos crudos antes de
crear el Node, no silenciar uno ya existente. De paso: el texto real dice "ataca"
(indicativo), no "ataque" (subjuntivo) — la frase que `Card.TRIGGER_KEYWORDS` ya
reconocía — agregada la variante a `on_enter_play` y `on_attack`, si no el trigger
nunca se disparaba.

**Azi Sruvara** — dos partes:
1. Bug real reportado por el usuario: la búsqueda del Aliado Azi manipulaba
   `CardManager.get_deck()` directo (no vía `ActionModule.search()`) y nunca disparaba
   la animación de barajado — se sentía "automático, sin feedback". Agregado el mismo
   `AnimationQueue.CUSTOM` que usa cualquier otra búsqueda real.
2. Segunda cláusula implementada ("convierte una carta de coste 1 o menos en un Oro
   con la habilidad 'Cancelar la habilidad de tus Aliados de coste 4 o más cuesta un
   Oro adicional' y muévelo a tu Oro Pagado"): elige entre tus cartas en juego de
   coste ≤1 (automático si hay 1, `CardInteractionModule.await_target()` si hay 2+) y
   la convierte con el mismo mecanismo de Jormundgander. **Límite conocido a
   propósito:** el TEXTO de la habilidad nueva queda bien asignado, pero no hay ningún
   hook funcional que de verdad cobre ese Oro extra al cancelar una habilidad (viviría
   en `LinkedEffectRegistry._execute_cancel()`, el mismo camino que protege a Drácula)
   — no auditado en esta sesión, mismo motivo que el dev original dejó esto sin
   terminar la primera vez.

**3 bugs reales encontrados/reportados en el camino, los 3 preexistentes (no
introducidos por este trabajo, solo expuestos por él):**
1. `scripts/entities/Card.gd`: `center_piv` usado sin declarar en
   `_refresh_disabled_rotation()` — rompía el parseo del script ENTERO (todo el juego).
   Apareció en medio de esta sesión por una edición externa a medias; arreglado con el
   punto central obvio por el patrón del código alrededor.
2. `ConvertAndMiscResolver.gd` — `try_execute_convert_ally_to_gold_pattern()`
   (Jormundgander) usaba `_executor._main._gold_manager`/`_card_interaction` directo.
   `_executor._main` en este archivo es en realidad el nodo `TriggerSystem`, no el
   `Main` real (`_targeted_executor.setup(self)` en `TriggerSystem._ready()` — mismo
   bug ya documentado una vez en `TargetedEffectExecutor.gd:441-445` pero que se había
   quedado sin aplicar acá). "Invalid access to property or key" apenas algo intentaba
   resolver a Jormundgander. Arreglado con la misma indirección
   (`_executor._main.get_node_or_null("/root/Main")`) que ya usa el patrón de
   Jabberwocky nuevo.
3. `PaymentManager.gd:calcular_coste_real()` — el chequeo propio de Jabberwocky ("si
   no controlas Aliados de coste 1 o menos") llamaba `calcular_coste_real(c)` por cada
   Aliado del campo para saber su coste — con Jabberwocky en juego, la llamada termina
   llamándose a sí misma (su propio coste depende de si hay un Aliado de coste ≤1, y
   para saberlo de ESE Aliado — que puede ser ella misma — vuelve a entrar a la misma
   función), "Stack overflow". Cambiado a leer `card_cost` (coste BASE, sin
   modificadores) en vez de recursar — mismo criterio que los chequeos hermanos
   (Armas/Dragones) un poco más arriba en el mismo archivo, que tampoco recurren.
   Este bug era anterior a esta sesión, pero recién se disparaba la primera vez que
   alguien jugaba a Jabberwocky de verdad con su segunda cláusula funcionando — lo
   cual solo pasó a partir de la implementación de arriba.

**Sin verificar en partida real todavía** — mismo motivo que el resto de la sesión.
Verificado solo con el headless check (`--check-only`) después de cada fix, sin
errores de parseo.

## 16. Tercer puente de red: `ZoneViewerModule` (picker de Cementerios + revelado del Castillo) — Fase 3 (2026-09-30)

**A pedido del usuario ("dale, encaralo")**, tras identificar en §14.3 que
`ZoneViewerModule.open_cemetery_target_picker()`/`open_reveal_picker()` eran el
siguiente bloqueo real para seguir convirtiendo cartas de la Fase 3.

**Por qué es distinto de `SelectionManager` (§14):** ahí los candidatos ya eran
`Dictionary` planos — acá el `filter` que cada carta pasa espera un **Node** (lee
`.owner_id`/`.card_type`/`.current_zone`, etc.), así que el puente SÍ necesita
construir los Nodos Card temporales de siempre (`_create_selectable_popup_card()`),
pero sin agregarlos nunca al árbol real ni mostrar ningún Control — se descartan
apenas se junta la lista de candidatos que pasan el filtro, y de ahí en más todo
viaja como datos planos (mismo protocolo prompt/intent que el resto).

**Implementado:**
- `ZoneViewerModule.open_cemetery_target_picker()`: nuevo `chooser_id: int = 0`.
  Si el que elige es el jugador 1 con un Remoto real conectado, delega en
  `_delegate_cemetery_picker_to_remote()` en vez de abrir el popup "ambos
  Cementerios lado a lado" (que además asume siempre "pid 0 = propio, pid 1 =
  rival" sin mirar quién pregunta — por eso no alcanzaba con solo chequear
  `controller_id` adentro, hacía falta este puente aparte).
- `ZoneViewerModule.open_reveal_picker()`: nuevo `chooser_id: int = -1` (default =
  usar `owner_id`, mismo criterio que `ActionSearch.search()` en §14.2 — ningún
  llamador existente de los 8+ sitios que ya usan esta función necesita cambiar).
  Delega en `_delegate_reveal_picker_to_remote()`.
- `RemoteMirrorController.gd`: nuevo caso `"select_cemetery_cards"`
  (`_show_select_cemetery_cards_prompt()`) — mismo estilo que `"select_cards"`, más
  etiquetas opcionales de zona ("Cementerio"/"Destierro") y lado ("tuyo"/"rival")
  cuando el payload las trae (el picker de Cementerios las manda; el de revelado
  del Castillo no, al ser un solo pool sin lado rival).

**2 cartas convertidas como demostración** (mismo criterio de siempre: solo
mecanismos ya bridgeados en TODA la función, nada mixto con `CardInteractionModule`
sin puente):
- `DSR_CemeteryBanishDraw.gd`: Mariano Osorio ("Destierra hasta tres cartas del
  Cementerio oponente").
- `ShuffleDrawPatterns.gd`: Caín (usa el puente nuevo DOS veces + `await_two_choice`
  dos veces — la demo más rica hasta ahora de varios mecanismos combinados).

**Total acumulado: 21 de 113.** Lo que queda de `DSR_CemeteryBanishDraw.gd` (6
sitios más) y buena parte de `LookRevealPatternsA/B.gd`/`ShuffleDrawPatterns.gd`
(que usan `open_reveal_picker()`) debería ahora ser mucho más fácil de convertir —
el bloqueo real que quedaba era el puente, no cada carta puntual. Lo que sigue
bloqueado: todo lo que usa `CardInteractionModule.await_target()`/
`await_multi_target()` directo sobre Nodos YA en juego (elegir un Aliado del campo,
un Arma equipada, etc.) — ese es un cuarto sistema, todavía sin puente.

**Sin verificar en partida real todavía.** Verificado con el headless check — sin
errores de parseo.

## 17. Cuarto puente de red: `CardInteractionModule` (objetivo sobre cartas YA en juego) — Fase 3 (2026-09-30)

**A pedido del usuario ("dale con el cuarto sistema")** — el último de los 4 sistemas
de selección identificados en esta sesión.

**Por qué es el más simple de los 4 en un sentido y el más delicado en otro:** acá las
cartas NO son temporales ni datos crudos — son los Nodos REALES y persistentes del
tablero (mano, campo, Oro, Oro Pagado de cualquiera de los dos jugadores). No hace
falta instanciar nada para evaluar el `filter`. Pero por eso mismo hace falta una
identidad ESTABLE para mandar por red y volver a encontrar el mismo Nodo al resolver
la respuesta — se usa `get_instance_id()`/`instance_from_id()`, mismo criterio que
`RemotePlayerController._card_ref()`/`_find_card_by_id()` (Fase 1).

**Implementado:**
- `CardInteractionModule.await_target()`: nuevo `chooser_id: int = 0`. Si el que elige
  es el jugador 1 con un Remoto real conectado, `_delegate_target_to_remote()` barre
  las mismas 10 zonas de tablero + mano/abanico que `_glow_valid_targets()` ya usa,
  aplica el filtro, y manda los candidatos que pasan por red.
- `CardInteractionModule.await_multi_target()`: mismo criterio, nuevo `chooser_id: int
  = 0` al final de la firma. **Simplificación a propósito:** `_delegate_multi_target_
  to_remote()` NO enforcea `lock_group_key`/`dynamic_filter` del lado del Remoto —
  ningún patrón convertido hasta ahora los necesita de verdad (los que sí los usan,
  p.ej. Tempilcahue/Lobo Sagrado con presupuesto de coste en vivo, quedan sin
  convertir a propósito por esto).
- `RemoteMirrorController.gd`: nuevos casos `"await_target"`/`"await_multi_target"`
  (`_show_await_target_prompt()`/`_show_await_multi_target_prompt()`) — mismo estilo
  de siempre, `card_id` viaja como string de `get_instance_id()`.
- Dos helpers COMPARTIDOS arreglados en el camino (alto apalancamiento — benefician a
  cualquier conversión futura sin tocarlos de nuevo):
  - `TargetedEffectExecutor._select_convert_target()` (usado por Acabar la Esperanza
    y otros patrones de "Convertir") — nuevo `chooser_id`.
  - `TargetedEffectExecutor._select_hand_cards_for_discard()` (compartido por 8+
    cartas de descarte mandatorio de a 1) — nuevo `chooser_id`, sin
    `lock_group_key`/`dynamic_filter` así que no choca con la simplificación de
    arriba.

**7 cartas convertidas:** shedo titan, manuel rodriguez, peripillan, Acabar la
Esperanza (+ animación de barajado que también le faltaba), Carcosa, estacion gaia,
dyyavol titan. Esta última expuso OTRO bug real del mismo tipo que Azi Sruvara: leía
`player_hand` siempre, sin mirar `owner_id` — para el jugador 1 había que leer
`_opponent_fan` — arreglado de paso.

**Total acumulado: 28 de 113.** Con los 4 sistemas ya bridgeados, lo que queda sin
convertir es sobre todo: patrones con `lock_group_key`/`dynamic_filter` reales (no
soportados a propósito, ver arriba), los 3 diálogos a medida que ningún puente cubre
(`await_card_pair_choice()`, `await_castillo_pick()`, `CardNameSearchDialog.open_and_
wait()` — cada uno un caso único, no una familia grande), y simplemente cartas que
todavía no se auditaron una por una.

**Sin verificar en partida real todavía.** Verificado con el headless check — sin
errores de parseo.


## 18. Grupos grandes de cartas, no una por una — Fase 3 (2026-09-30)

**A pedido del usuario ("sigue con más cartas pero grupos grandes")** — en vez de
seguir carta por carta, esta tanda priorizó familias enteras que comparten un mismo
helper o un mismo patrón de bug, para apalancar cada arreglo sobre varias cartas a
la vez.

**`DSR_ShuffleDrawCombos.gd` — mismo bug en 4 funciones:** Aaru, Manuel Bulnes,
Trono del Dragón y Espada Vikinga compartían el mismo defecto (mano fija
`main.player_hand` en vez de mirar `owner_id`, sin `chooser_id` en
`await_multi_target()`/`await_target()`, y sin animación de barajado) — arregladas
con el mismo ternario `hand_container = main.player_hand if controller_id == 0 else
main._opponent_fan` en las 3 primeras; Espada Vikinga además perdió su fallback
"el bot elige al azar" (`candidates.shuffle(); chosen = candidates[0]`), ahora
siempre resuelve con `await_target(..., true, controller_id)`.

**El cluster de mayor tráfico de `TargetedEffectExecutor.gd` — 5 funciones, ~15
call sites externos:** `_select_ally_target()`, `_select_annul_target_cost_filter()`,
`_select_destroy_target_cost_filter()`, `_select_banish_target_cost_filter()` y
`_select_ally_or_totem_target()` son, según el propio header del archivo, "el
cluster de mayor tráfico externo de todo este archivo" — decenas de call sites en
`PreventionAbilityHandler_*.gd`, `SearchAbilityHandler_*.gd`,
`BanishOpponentPatterns.gd`, `ShuffleDrawPatterns.gd`, etc. Las 5 ganaron
`chooser_id: int = 0` y lo reenvían a `await_target()`. Los 6 call sites INTERNOS
(`_execute_targeted_buff/destroy/banish/silence/return_to_deck/annul`) también se
actualizaron para pasar el `controller_id`/`card.controller_id` real en vez de
dejarlo en el default.

**Cartas/helpers desbloqueados por ese cluster (guard "el bot no usa esta
habilidad todavía" levantado + `chooser_id` enchufado):**
- `BanishOpponentPatterns.gd`: Ciempiés-SP (`try_execute_annul_cost_max_pattern`),
  Dragón Dorado (`try_execute_annul_then_shuffle_hand_by_cost_pattern` — además
  tenía mano fija y sin animación de barajado, igual que el grupo de arriba),
  akuma el terrible (`try_execute_banish_cost_or_search_two_banish_pattern` —
  también le faltaba `chooser_id` en su propio `await_two_choice()`).
- `HandCementerioAbilityHandler.gd`: Espada del Juicio (activada desde Cementerio).
- `PreventionAbilityHandler_AE.gd`: Dulce Canasta, ereshkigal.
- `PreventionAbilityHandler_EP.gd`: gran kraken y la habilidad de Arma de Paladín
  Bestiarium — **bug real encontrado**: el filtro de "elige 1 carta de tu mano"
  de ambas sólo miraba `current_zone == MANO`, sin filtrar por `owner_id` — un
  jugador podía clickear una carta de la mano del RIVAL. Arreglado agregando
  `and c.get("owner_id") == owner_id` al filtro (y de paso Paladín Bestiarium
  tenía los 3 campos de armas (`player_field`/`_linea_ataque`/`_linea_apoyo`)
  fijos al Anfitrión — ahora elige entre los propios o los del rival según
  `owner_id`).
- `SearchAbilityHandler_JV.gd`: Tenshi Z (mismo bug de filtro de mano sin
  `owner_id`, más mano fija y animación de barajado faltante).
- `WeaponSearchShuffleExecutor.gd`: `_return_equipped_weapon_to_hand()` — helper
  compartido con "Padre de la Patria" — mandaba el Arma SIEMPRE a
  `main.player_hand`; ahora usa `weapon.owner_id` para elegir la mano real.
- `SearchAbilityHandler_AI.gd`: Aho se dejó **a propósito sin convertir** — depende
  de `await_castillo_pick()`, que el plan deja fuera de esta Fase (mismo motivo que
  La Ouija/Malleus Maleficarum).

**`ShuffleDrawPatterns.gd` — las 8 candidatas identificadas antes del corte,
todas convertidas:** Caín (segunda carta/impresión, "Baraja hasta una... o Roba
dos", distinta de la ya convertida), vision heroica ("Baraja... o Anula Talismán"),
el caleuche, manuel rodriguez (ataca solo — trivial, sin selección, solo se le
quitó el guard), amazona desafiante, Abrazo de Maipú, Ofrendas al Dragón y Tótem
del Dragón Ancestral (ETB, ambas ya tenían el guard levantado de una tanda previa
pero les faltaba enchufar `chooser_id` en los helpers que llaman). De paso, el
patrón hermano de Caín (`try_execute_cain_damage_shuffle_search_pattern`, el de
"Barajalo para buscar dos Aliados") tenía dos bugs sueltos no relacionados con
`chooser_id`: sin animación de barajado y mano fija al poner la carta no jugada
"en tu mano" — arreglados de paso.

**Familia de `GoldManager._resolve_armeria_barajar_desterrar()` — ahora completa:**
con el helper ya corregido (`chooser_id` agregado en la tanda anterior), se
completó el enchufado en sus 4 llamadoras restantes que todavía tenían el guard de
bot puesto: Belta, Perla de Sangre, Torre de Babel y uriel
(`PreventionAbilityHandler_AE.gd`/`PreventionAbilityHandler_PV.gd`). Torre de Babel
y uriel tenían además el mismo bug de filtro de mano sin `owner_id` y mano fija
que gran kraken/Tenshi Z — arreglado igual. La habilidad ACTIVADA de Tótem del
Dragón Ancestral ("Barajarlo para Anular o cancelar", distinta de su ETB) también
se desbloqueó y ganó animación de barajado que le faltaba.

**Dejado fuera a propósito:** la habilidad de vision heroica usable desde el
Cementerio (`_activate_vision_heroica_pay_raise_draw`) depende de
`GoldManager.puede_pagar()`/`pagar_coste()`, que no reciben `player_id` — pagan
siempre desde la Reserva del Anfitrión. Esto es una limitación estructural de
todo el sistema de pago, no algo que un `chooser_id` de selección pueda arreglar;
queda fuera del alcance de esta Fase (igual que la Reserva de Oro del Remoto en
general).

**24 cartas/nombres nuevos convertidos en esta tanda:** Aaru, Manuel Bulnes, Trono
del Dragón, Espada Vikinga, Ciempiés-SP, Dragón Dorado, akuma el terrible, Espada
del Juicio, Dulce Canasta, ereshkigal, gran kraken, Paladín Bestiarium, Tenshi Z,
Caín (2do print), vision heroica (ETB), el caleuche, amazona desafiante, Abrazo de
Maipú, Ofrendas al Dragón, Tótem del Dragón Ancestral, Belta, Perla de Sangre,
Torre de Babel, uriel.

**Total acumulado: 52 de 113.**


## 19. Dos familias temáticas completas: `WeaponAbilityPatterns.gd` y `TotemAbilityPatterns.gd` (2026-10-05)

**A pedido del usuario ("continuemos")** — siguiendo el mismo criterio de "grupos
grandes", esta tanda agotó dos archivos temáticos completos (Armas y Tótems "sin
cobertura en la auditoría de 539 cartas") en vez de picotear cartas sueltas.

**`WeaponAbilityPatterns.gd` — las 7 Armas del archivo, todas desbloqueadas:**
Cañón Naval (3 patrones comparten el mismo guard: activado, on_leave_play y el de
Fase Final — los tres liberados juntos; su `open_cemetery_target_picker()` y su
`await_two_choice()` ganaron `chooser_id`), flechar xoon, sable corto, nehushtan
(trivial, sin selección), azusa yumi (trivial), nodachi y Armadura Celestial.
**Dos bugs reales encontrados:** nodachi leía SIEMPRE `main._opponent_fan` para
"la mano de tu oponente" sin importar quién controla la carta — si el Remoto la
controla, su oponente es el Anfitrión (`main.player_hand`, no `_opponent_fan`) —
arreglado con `opponent_hand = main.player_hand if opponent_id == 0 else main.
_opponent_fan`. Armadura Celestial tenía la mano fija a `main.player_hand` al
recuperarse del Cementerio — mismo arreglo con contenedor por `owner_id`.

**`TotemAbilityPatterns.gd` — 3 Tótems nuevos + 3 bugs en Tótems ya contados
antes:** kotoku-in (solo su habilidad de Vigilia — la de "Cuando entra en juego,
genera un Oro..." se deja a propósito sin convertir, ver más abajo), iga ryu,
hangar de la ciudadela. Además, tres Tótems que ya estaban en el total de
`§17`/`§14` (metropolitan, la rueda de la fortuna, arco del triunfo) tenían bugs
sueltos no relacionados con el guard de bot: arco del triunfo y la rueda de la
fortuna mandaban la carta encontrada/revelada SIEMPRE a `main.player_hand` (mismo
patrón de bug de siempre) — arreglado con el mismo contenedor por `owner_id`;
metropolitan ganó dos patrones adicionales desbloqueados (conversión en Aliado de
Vigilia y el buff de Fuerza/coste al atacar), ninguno de los dos depende de la
economía de Oro así que se liberaron sin reparos. hangar de la ciudadela tenía el
mismo bug que nodachi (`_opponent_fan` fijo asumiendo que el oponente siempre es
jugador 1) — mismo arreglo.

**Dejado fuera a propósito — misma limitación estructural que vision heroica
(§18):** la cláusula de ENTRADA de kotoku-in y la primera rama de metropolitan
("genera un Oro para Aliados de coste 2 o más") dependen de `GoldManager.
generar_oro_virtual_restringido()`, que tampoco recibe `player_id` — es el mismo
sistema de Oro de un solo jugador que `puede_pagar()`/`pagar_coste()`. Estación
Fantasma también se deja sin convertir: depende de `CardNameSearchDialog.
open_and_wait()`, que el plan excluye explícitamente (mismo caso que Malleus
Maleficarum/Alicia en Wonderland).

**10 cartas/nombres nuevos convertidos en esta tanda:** Cañón Naval, flechar xoon,
sable corto, nehushtan, azusa yumi, nodachi, Armadura Celestial, kotoku-in, iga
ryu, hangar de la ciudadela.

**Total acumulado: 62 de 113.**

**Sin verificar en partida real todavía.** Verificado con el headless check — sin
errores de parseo.


## 20. `BanishOpponentPatterns.gd` completo (salvo una excepción documentada) (2026-10-05)

**A pedido del usuario ("continuemos con más cartas")** — el archivo entero de
patrones "destierro/mill/anulación dirigidos al oponente" quedó convertido salvo
una sola excepción documentada.

**9 cartas nuevas:** ignis desatado, colaborador titan, Asmodeus, cuervo nocturno,
cruzar el bosque, Culto a la Muerte, templo de hatshepsut, necro-titan, akari
musashi.

**Tres bugs reales del mismo patrón recurrente, encontrados y arreglados:**
ignis desatado, Asmodeus y estacion gaia (esta última YA estaba contada desde
`§17` — este es un arreglo adicional, no una conversión nueva) leían la mano o el
campo "del oponente"/"propio" con un contenedor fijo (`main.player_hand`/
`main._opponent_fan`/`main.player_field`) en vez de resolverlo por `owner_id`/
`controller_id` real — exactamente el mismo patrón de bug ya encontrado varias
veces en tandas anteriores (nodachi, hangar de la ciudadela, gran kraken, Tenshi
Z...). colaborador titan tenía el mismo problema pero sobre SUS PROPIOS campos
(contaba Aliados Titán/Ignis siempre en `player_field`, nunca en
`opponent_field`).

**Dejada fuera a propósito — caso nuevo, no de economía de Oro:** Ngenechén
(`try_execute_banish_opponent_cost_sum_six_pattern`) usa `dynamic_filter`
(presupuesto en vivo, "costes sumen hasta 6") en `await_multi_target()` — el
mismo parámetro que el puente de red NO enforcea del lado del Remoto a
propósito (documentado desde `§17`: "los que sí los usan... quedan sin
convertir a propósito por esto"). A diferencia de los Tempilcahue/Lobo Sagrado
ya documentados, este caso se encontró recién ahora al barrer el archivo
completo — se deja con su guard intacto en vez de desbloquearlo a medias (el
Remoto podría desterrar de más sin que el límite de coste se respete de
verdad).

**9 cartas/nombres nuevos convertidos en esta tanda** (el arreglo de `estacion
gaia` no suma porque ya estaba contada desde `§17`): ignis desatado, colaborador
titan, Asmodeus, cuervo nocturno, cruzar el bosque, Culto a la Muerte, templo de
hatshepsut, necro-titan, akari musashi.

**Total acumulado: 71 de 113.**

**Sin verificar en partida real todavía.** Verificado con el headless check — sin
errores de parseo.


## 21. `SearchOwnZonePatterns.gd` completo, incluida toda la familia de los 7 Sellos (2026-10-05)

**A pedido del usuario ("continua con más cartas")** — este archivo tenía la
concentración más alta de guards de bot restantes (10), incluida la familia
completa de los 7 Sellos (Ángeles y Demonios: Vigilantes), que comparte el
helper `_search_sello_to_hand()`.

**10 cartas nuevas:** Kuchiku Kan, Danza de Dragones, duelo espacial, y los 7
Sellos (Primer/Segundo/Tercer/Cuarto/Quinto/Sexto/Séptimo Sello).

**Bug real encontrado en Kuchiku Kan, independiente de la red:** el código
original solo ofrecía la elección "¿Castillo o Cementerio?" cuando
`controller_id == 0`; para cualquier otro jugador asumía SIEMPRE Castillo sin
preguntar — no era un guard de bot, era una rama condicional que directamente
nunca le daba la opción al jugador 1. Arreglado para que ambos controladores
reciban la misma elección vía `await_two_choice(..., controller_id)`.

**El mismo patrón recurrente de mano/campo fijo, encontrado 4 veces más:** La
Torre, Danza de Dragones, Azi Sruvara (su cláusula de búsqueda Y la de
conversión — el guard de bot cubría las DOS, así que la conversión que se
"convirtió" en la tanda de Jabberwocky/Azi Sruvara nunca llegó a ejecutarse de
verdad para el jugador 1 hasta ahora) y duelo espacial/Quinto Sello mandaban o
leían la mano SIEMPRE de `main.player_hand` — mismo arreglo de siempre
(`hand_container` por `owner_id`/`controller_id`).

**Dos bugs reales nuevos, no relacionados con mano/campo:** Cuarto y Séptimo
Sello leían `main.gold_cards.filter(... current_zone == RESERVA_ORO)` para
"el Oro propio" — pero `gold_cards` es un Array GLOBAL con el Oro físico de
AMBOS jugadores (`Main.gd:107`), sin ningún filtro por dueño; sin el bug
intervenía el Oro del RIVAL como si fuera propio, cualquiera fuera el jugador
que resolviera la habilidad. Arreglado agregando `and g.get("owner_id") ==
controller_id` al filtro — bug preexistente, no introducido por la red.

**Helper compartido completado:** `_shuffle_up_to_from_cemeteries()` (usado
por Quinto Sello) ganó `chooser_id` y la animación de barajado que le
faltaba.

**Dejada fuera a propósito:** asedio naval usa `lock_group_key` (candado
"mismo tipo que la primera elegida") en `await_multi_target()` — mismo caso
que Ngenechén en `§20`, el puente de red no lo enforcea del lado del Remoto,
así que se deja con su guard intacto.

**Total acumulado: 81 de 113.**

**Sin verificar en partida real todavía.** Verificado con el headless check — sin
errores de parseo.


## 22. `PreventionAbilityHandler_PV.gd` — descubrimiento clave: `GoldManager` es de un solo jugador (2026-10-05)

**A pedido del usuario ("falta poquito sigamos")** — al barrer este archivo
(9 guards restantes) se confirmó, leyendo el código real de `GoldManager.
puede_pagar()`/`pagar_coste()` (no solo infiriéndolo), un límite arquitectónico
más amplio de lo documentado hasta ahora.

**Hallazgo central:** `puede_pagar()` lee `GameState.get_oro_reserva(0)` (el 0
está hardcodeado) y `oros_virtuales` es una variable de instancia ÚNICA (no un
Array/Dictionary por jugador) — es decir, **todo el sistema de pago de Oro real
de GoldManager es, hoy, de un solo jugador** (el Anfitrión), no solo
`generar_oro_virtual_restringido()` como se había documentado en `§18`/`§19`.
Cualquier habilidad cuyo COSTO sea pagar Oro real (`pagar_coste()`) queda en la
misma categoría de exclusión, no solo las que generan Oro Virtual.

**5 cartas nuevas convertidas** (ninguna de ellas paga Oro como costo): Quantum
Megumi, quimera voragh, Shub-Niggurath (solo su habilidad "Barajar o Botar
cartas" — la otra, que genera Oro Virtual, se deja fuera), skofnung, sumi el
terrible.

**Dejadas fuera a propósito por el hallazgo de arriba:** Piruquina (costo: pagar
1 Oro), Sake (costo: pagar 1 Oro) y la habilidad de Shub-Niggurath que genera
Oro Virtual — las tres ya habían sido tocadas sin querer en el primer pase de
esta tanda y se revirtieron al confirmar el problema real en el código de
GoldManager.

**Sexto tipo de diálogo sin puente, encontrado nuevo:** Perla de Sangre
("buscar en tu Castillo un Aliado... o jugarlo") usa `SelectionManager.
await_single_pick()` — un modal de lista con `Dictionary` crudos que NO es
ninguno de los 4 sistemas bridgeados en la Fase 3 (no `open_selection`/
`open_search`, no `await_choice`/`await_two_choice`, no el picker de Zonas, no
`CardInteractionModule`) y no tiene `chooser_id` en su firma. Se deja
documentado como gap nuevo, igual categoría que `await_card_pair_choice()`/
`await_castillo_pick()`/`CardNameSearchDialog.open_and_wait()`.

**Total acumulado: 86 de 113.**

**Sin verificar en partida real todavía.** Verificado con el headless check — sin
errores de parseo.


## 23. `PreventionAbilityHandler_AE.gd` — el límite de un solo jugador también cubre `play_card()`/`_play_card_to_field()` (2026-10-05)

**A pedido del usuario ("continuemos")** — al barrer este archivo (8 guards)
se confirmó que el límite de "un solo jugador" de `GoldManager` (§22) no es
solo de `puede_pagar()`/`pagar_coste()`/`generar_oro_virtual_restringido()`:
también cubre la ruta de JUGAR una carta.

**5 cartas nuevas convertidas** (ninguna toca Oro real ni juega una carta
desde la mano): akari, atenea en wonderland, Campanita, Espíritu de la
Máquina, Macu (comparte el mismo handler/texto que Espíritu de la Máquina).
También se completó la habilidad ACTIVADA de akuma el terrible (distinta de
su ETB, ya contada en `§20`) con `chooser_id`.

**Hallazgo nuevo: `GoldManager.play_card()`/`_play_card_to_field()` también
son de un solo jugador.** `play_card()` rechaza con "No es tu turno" cuando
`GameManager.active_player_id != 0` (hardcodeado, salvo Talismanes
instantáneos); `_play_card_to_field()` registra `"played_ally_cost2plus:0"`
con el 0 fijo y sacude `_main.player_hand.cards` directo. Dos cartas que
resuelven jugando una carta por este camino se dejan sin desbloquear:
- Belta (la OTRA habilidad, "Destierra 2 para ponerla en juego desde el
  Cementerio" — distinta de la ya convertida en `§17`/`§18`).
- Crono Diamante ("Descartar para jugar un Aliado con descuento").

**Séptimo tipo de diálogo sin puente, encontrado nuevo:** Espada de O'Higgins
usa `CardInteractionModule.await_target_or_castillo_pick()` — una carrera
entre clickear una carta o el Castillo propio, sin `chooser_id`. Se deja
documentado junto a `await_single_pick()` (`§22`).

**Total acumulado: 91 de 113.**

**Sin verificar en partida real todavía.** Verificado con el headless check — sin
errores de parseo.


## 24. `HandCementerioAbilityHandler.gd` — habilidades activadas desde mano/Cementerio (2026-10-05)

**A pedido del usuario ("continuemos")** — este archivo cubre habilidades
ACTIVADAS usables desde la MANO o el CEMENTERIO, antes de jugar la carta
(Tyet, Ramón Freire, Espada del Juicio, Drácula, Estaca, La Ouija, Sacrificio
Solar, sandraudiga).

**3 cartas nuevas convertidas:** Tyet (sus 2 habilidades — "silenciar un Oro y
moverlo a Oro Pagado" confirmada SEGURA porque `GoldManager._mover_oro_a_
pagado()` ya resuelve por `card.controller_id` real, no hardcodeado; "mandar
esta y otra carta al fondo del mazo" sin costo de Oro), Drácula, Estaca (+
animación de barajado que le faltaba en sus DOS barajados).

**Dejadas fuera a propósito, las 4 restantes, todas por los límites ya
documentados en `§22`/`§23`:**
- sandraudiga: paga 1 Oro real Y usa `await_single_pick()` para "mira la mano
  rival" (dos motivos independientes).
- Ramón Freire: `generar_oro_virtual_restringido()`.
- La Ouija: reusa `GoldManager.play_card()` completo, y además lee
  `CardManager.get_cemetery(0)` con el 0 hardcodeado explícito en el propio
  código (no solo vía el wrapper de GoldManager).
- Sacrificio Solar: paga 1 Oro real.

**Total acumulado: 94 de 113.**

**Sin verificar en partida real todavía.** Verificado con el headless check — sin
errores de parseo.


## 25. `PreventionAbilityHandler_EP.gd` — `play_card_for_free()` también hardcodea el jugador, y esto es RETROACTIVO (2026-10-05)

**A pedido del usuario ("sigamos")** — al barrer este archivo (5 guards) se
confirmó, leyendo `GoldManager.play_card_for_free()` línea por línea, un
tercer punto de la misma falla de "un solo jugador" (después de `puede_
pagar()`/`pagar_coste()` en `§22` y `play_card()`/`_play_card_to_field()` en
`§23`) — y esta vez afecta a VARIAS cartas que esta sesión ya marcó como
"convertidas" en tandas anteriores.

**3 cartas nuevas convertidas** (ninguna toca Oro ni juega una carta):
Frankenstein o El Moderno Prometeo (sus 2 habilidades), lanza argenta, y la
segunda habilidad de nu-galahad el bastión ("porta hasta tres cartas de un
Cementerio como Armas" — usa `GoldManager._equip_weapon()`, que ancla el
Arma como hijo del Aliado portador sin pasar por ningún contenedor de
jugador, así que es seguro). Se completó además la habilidad activada de
Kuchiku Kan (su ETB ya estaba contada en `§21`).

**Hallazgo retroactivo:** `GoldManager.play_card_for_free(card_data)`
hardcodea `card.owner_id = 0` en su primera línea — sin importar qué
`owner_id` tenía el jugador real que disparó el efecto. Como varias cartas
YA convertidas en tandas anteriores de esta sesión terminan su resolución
llamando a esta función, **esas conversiones son solo PARCIALES**: el paso
de selección/objetivo sí quedó bridgeado para el Remoto, pero la carta
jugada al final siempre se le atribuye al jugador 0, sin importar quién
la jugó de verdad. Grep confirma estas llamadas en: `SearchOwnZonePatterns.gd`
(La Torre), `TotemAbilityPatterns.gd` (arco del triunfo), `ShuffleDrawPatterns.
gd` (Caín), `PlayFromCemeteryPatterns.gd` (aku aku y otra), `WeaponSearchShuffle
Executor.gd`, `DSR_SearchGoldCombos.gd` y `LookRevealPatternsA/B.gd` (estos dos
últimos archivos con varias funciones aún sin convertir, pendiente de revisar
cuál llega a necesitarlo).

**Por qué no se corrigió ahora:** arreglar el helper compartido
(parametrizar `play_card_for_free(card_data, owner_id=0)` y hacer que
`_play_card_to_field()` enrute por `card.owner_id` en vez de `_main.player_*`
fijo) es un cambio de mayor alcance que un `chooser_id` de selección —
toca la función que TAMBIÉN usa el flujo normal del Anfitrión jugando sus
propias cartas, y conviene decidirlo con el usuario antes de tocarlo en vez
de hacerlo de paso en una tanda de conversión de cartas.

**nu-galahad el bastión, primera habilidad, y Paladín Bestiarium (descuento
de Arma) se dejan sin desbloquear** por el mismo motivo que Crono Diamante/
Belta en `§23` (`play_card_for_free()`/`play_card()` directo).

**Total acumulado: 97 de 113.**

**Sin verificar en partida real todavía.** Verificado con el headless check — sin
errores de parseo.


## 26. Arreglo retroactivo: `play_card_for_free()`/`_play_card_to_field()`/`_play_talisman()` ya enrutan por `owner_id` real (2026-10-05)

**A pedido explícito del usuario** (eligió "Arreglar el helper ahora" frente a
la alternativa de seguir convirtiendo cartas y dejarlo para después) — se
corrigió la causa raíz del hallazgo de `§25` en vez de solo documentarla.

**Qué cambió en `GoldManager.gd`:**
- `play_card_for_free(card_data, owner_id: int = 0)`: nuevo parámetro,
  reemplaza el `card.owner_id = 0` fijo. Default `0` preserva el
  comportamiento viejo para cualquier llamador que no lo pase.
- `_play_card_to_field(card)`: ya no asume `_main.player_hand`/`player_field`/
  `player_linea_apoyo` — ahora lee `card.owner_id` (que ya llega asignado
  correctamente desde los 3 caminos que la llaman) y enruta a los
  contenedores del jugador real. También corrige el registro de 'played_
  ally_cost2plus:0' (fijo) a usar el `owner_id` real — Crono Diamante lee esa
  marca por jugador.
- `_play_talisman(card)`: mismo arreglo, reutilizando `talisman_owner` (ya
  existía localmente, calculado desde `card.owner_id`, sin tocar).
- `_select_weapon_wielder(chooser_id: int = 0)`: nuevo parámetro, reenviado a
  `await_target()` — antes el "¿qué Aliado porta el Arma?" de un Arma jugada
  gratis SIEMPRE se resolvía como si el que elegía fuera el jugador 0.

**7 llamadores existentes actualizados para pasar el `owner_id`/`controller_id`
real** (arregla retroactivamente su correctitud, sin cambiar el total de
cartas ya contado en secciones anteriores): La Torre (`§17`), Caín (`§18`),
arco del triunfo (`§14`/`§19`), Padre de la Patria, sumi el terrible (ETB),
Shiji.

**2 cartas nuevas, desbloqueadas porque el motivo de exclusión ya no aplica:**
Titán Abismal y la primera habilidad de nu-galahad el bastión (ambas usaban
`play_card_for_free()`, la razón exacta por la que estaban excluidas en
`§25`).

**1 bug nuevo encontrado y corregido en sentido inverso — aku aku quedó MAL
convertido en una tanda anterior a esta sesión:** resuelve con `gold_manager.
play_card(card_node)` directo (no `play_card_for_free()`), que rechaza con
"No es tu turno" cuando `GameManager.active_player_id != 0` — exactamente la
situación normal cuando el disparador es de verdad el jugador 1. Arreglar
`play_card()`'s puerta de turno queda fuera de alcance de esta tarea (afecta
también el flujo normal de jugar cartas del Anfitrión) — se le devolvió el
guard hasta que se decida tocarla.

**Confirmado seguro sin tocar nada — `LookRevealPatternsA.gd`:** sus llamadas
a `play_card_for_free()` ya estaban detrás de `if controller_id == 0: ...
else: await main._easy_bot.play_free_ally_from_data(...)` — un camino
paralelo ya owner-aware para el jugador 1, independiente de este arreglo.

**Total acumulado: 99 de 113.**

**Sin verificar en partida real todavía.** Verificado con el headless check — sin
errores de parseo.


## 27. `SearchAbilityHandler_JV.gd` (2026-10-05)

**A pedido del usuario ("sigamos con más cartas")** — 9 guards en este
archivo.

**4 cartas nuevas convertidas:** Jinete de la Peste, Espíritu Kotaix (+
animación de barajado que le faltaba), Kuchiku El Cazador (solo su habilidad
"Destruir + Botar", la otra queda excluida — ver abajo), voragh el devorador
(solo "busca en un Castillo", la otra queda excluida). Se completó además
quimera voragh (su ETB ya estaba contado en `§22`).

**Bug real encontrado — guard FALTANTE, no de más:** `_activate_padre_
patria_gold()` no tenía ningún guard (corría para cualquier `owner_id`), pero
resuelve con `generar_oro_virtual_restringido()`, de un solo jugador (`§22`).
Sin el guard, el jugador 1 activando Padre de la Patria le generaba Oro
Virtual al Anfitrión por error — se le agregó el guard que le faltaba.

**Dejadas fuera a propósito, 4 funciones, por los 3 motivos ya documentados:**
- Kuchiku El Cazador ("busca y juega con descuento") y Miguel: `gold_manager.
  play_card()` directo (`§23`) — distinto de `play_card_for_free()`, que ya
  se arregló en `§26`.
- lider del comite y Tesoro de los Césares: `CardNameSearchDialog.
  open_and_wait()` (excluido desde el plan original).
- voragh el devorador (la otra habilidad, "Destruir una propia para generar
  Oro"): `generar_oro_virtual_restringido()`.

**Total acumulado: 103 de 113.**

**Sin verificar en partida real todavía.** Verificado con el headless check — sin
errores de parseo.


## 28. `SearchAbilityHandler_AI.gd` — nuevo límite confirmado: `generar_oros_virtuales()` también es de un solo jugador (2026-10-05)

**A pedido del usuario ("prosigamos")** — 7 guards en este archivo (incluido
Aho, ya excluido desde `§14`).

**3 cartas nuevas convertidas:** Belcebú, Cuerno de Titán (+ animación de
barajado que le faltaba), Espada de O'Higgins (su habilidad de Vigilia A/B
"Barajar o buscar Oro" — distinta de la que ya quedó excluida en `§23`, que
usa `await_target_or_castillo_pick()`).

**Hallazgo nuevo:** `GoldManager.generar_oros_virtuales(cantidad)` (sin
"restringido") también incrementa `oros_virtuales`, la misma variable de
instancia única sin dimensión de jugador — mismo límite que `generar_oro_
virtual_restringido()` (`§19`/`§22`), confirmado ahora para esta variante
"sin restricción de para qué sirve". Asmodeus y Cetro Demoniaco (ambas la
usan) se dejan sin desbloquear por este motivo.

**Dejadas fuera, 4 funciones en total:**
- Asmodeus, Cetro Demoniaco: `generar_oros_virtuales()`.
- Chakram: `SelectionManager.await_single_pick()` (`§22`).
- Infernum Vox: `await_castillo_pick()` (excluido desde el plan original).

**Total acumulado: 106 de 113.**

**Sin verificar en partida real todavía.** Verificado con el headless check — sin
errores de parseo.


## 29. `OroAbilityPatterns.gd` — descubrimiento: `GameState.puede_pagar()`/`pagar_oro()` SÍ son por jugador (2026-10-05)

**A pedido del usuario ("las ultimas cartas")** — 5 guards en este archivo.

**4 cartas nuevas convertidas:** hidromiel, udjat (sus 2 habilidades, + mano
fija y animación de barajado arregladas en la de Vigilia), libro de thoth,
torii (sus 2 habilidades, + mano fija arreglada en la de Agrupación).

**Hallazgo que AMPLÍA el alcance, no lo reduce:** `GameState.puede_pagar(player_
id, cantidad)`/`pagar_oro(player_id, cantidad)` SÍ reciben `player_id` real y
leen/escriben `oro_reserva[player_id]`/`oro_pagado[player_id]` — Dictionaries
indexados por jugador, a diferencia de `GoldManager.puede_pagar()`/
`pagar_coste()` (de un solo jugador, `§22`). libro de thoth paga por este
camino seguro, así que NO había que excluirla — se confirma que "paga un
Oro" no es automáticamente motivo de exclusión; depende de qué función
exacta se usa para cobrarlo.

**Total acumulado: 110 de 113.**

**Sin verificar en partida real todavía.** Verificado con el headless check — sin
errores de parseo.


## 30. `GoldConversionPatterns.gd` + `MiscUniquePatterns.gd` (2026-10-05)

**A pedido del usuario ("las ultimas cartas")** — 2 guards en cada archivo.

**2 cartas nuevas convertidas:** leon indiferente (ya era owner-aware por
dentro, solo le faltaba levantar el guard), Transformación (+ arreglo de
campos propios fijos a `player_*`, mismo patrón de siempre).

**Dejadas fuera, 2 funciones, por motivos ya documentados:**
- Espíritu de la Máquina (la cláusula condicional de Oro, distinta de su
  otra habilidad ya convertida en `§23`): `generar_oro_virtual_restringido()`.
- Malleus Maleficarum: `CardNameSearchDialog.open_and_wait()` (excluida
  desde el plan original).

**Total acumulado: 112 de 113.**

**Sin verificar en partida real todavía.** Verificado con el headless check — sin
errores de parseo.


## 31. `ShuffleDrawPatterns.gd` (completo) + `DSR_CemeteryBanishDraw.gd` (completo) (2026-10-05)

**A pedido del usuario ("las ultimas cartas")** — estos dos archivos quedaron
completamente libres de guards; ninguna función en ellos depende de los
motivos de exclusión ya documentados.

**7 cartas nuevas convertidas:** Príncipe Orión, blanca nieves (+ animación
de barajado), kaitai, rafael (+ animación) en `ShuffleDrawPatterns.gd`;
Tamales (+ animación), Capitán O'Brien, Hanta el Samurai en
`DSR_CemeteryBanishDraw.gd`. Se completaron además aku aku, Quantum Megumi,
Espada de O'Higgins y Campanita (su segunda habilidad, "Barajar o subir del
Cementerio" + animación de barajado) — las cuatro ya estaban contadas por
otra habilidad suya.

**Nota sobre el denominador:** el "113" venía de un conteo aproximado hecho
al principio de esta tanda de conversiones — con varias cartas con MÚLTIPLES
habilidades contando una sola vez, y nuevas exclusiones encontradas sobre la
marcha, deja de ser una cifra exacta a estas alturas. De acá en adelante el
total se reporta como "cartas únicas confirmadas convertidas", sin ceiling
fijo.

**Bug real encontrado en `MiscTargetedPatterns._resolve_banish_from_both_
cemeteries()`** (helper compartido de Espada de O'Higgins): ya tenía
`controller_id` en su firma pero no lo pasaba al picker, y su único
llamador (`try_execute_banish_from_cemeteries_and_draw_pattern`) tenía un
`and controller_id == 0` extra bloqueando toda la rama de Destierro para el
jugador 1. Arreglados ambos — este helper también lo usa cualquier futura
carta con el mismo patrón.

**Total acumulado (cartas únicas confirmadas): 119.**

**Sin verificar en partida real todavía.** Verificado con el headless check — sin
errores de parseo.


## 32. Barrido final — `LookRevealPatternsA.gd`/`LookRevealPatternsB.gd` completos + `DSR_DiscardChoicePatterns.gd` documentado (2026-10-05)

**A pedido del usuario ("las ultimas cartas")** — últimos dos archivos
grandes de la familia LookReveal (1 + 9 guards), más la documentación final
de los 2 guards de `DSR_DiscardChoicePatterns.gd` (ya correctamente
excluidos, sin necesitar cambios de código).

**7 cartas nuevas convertidas:** kitsune - sp (`LookRevealPatternsA.gd` —
+ arreglo de "mano del oponente" fija a `_opponent_fan` sin importar quién
controla la carta, mismo patrón recurrente de siempre); Duelo de Dragones
(mismo arreglo), Activar Tenshi Z, Cabeza de Mimir, metalmorfo, Diadema
Celestial, Alicia en Wonderland (`LookRevealPatternsB.gd` — las 6 tenían el
mismo bug de mano fija a `player_hand` y ninguna tenía animación de
barajado, ambos arreglados en las 9 funciones de este archivo). Se
completaron además akari, atenea en wonderland y gran kraken (otras
habilidades suyas ya contadas) — gran kraken, en particular, ya podía
desbloquearse porque usa `play_card_for_free()`, arreglado en `§26`.

**Dejadas fuera, documentadas sin cambios de código:**
- contra el caos: `CardNameSearchDialog.open_and_wait()`.
- Tempilcahue: `dynamic_filter` en `await_multi_target()` (excluida desde
  el plan original, igual que Lobo Sagrado/Ngenechén/asedio naval).
- Golpe Solar: `gold_manager.pagar_coste()` directo, de un solo jugador.

**Con esto, cada guard que queda en el proyecto (34, repartidos en 15
archivos) tiene un motivo verificado y documentado para seguir excluido** —
`CardNameSearchDialog`/`await_card_pair_choice()`/`await_castillo_pick()`/
`await_single_pick()`/`await_target_or_castillo_pick()` (diálogos sin
puente de red), `dynamic_filter`/`lock_group_key` (presupuesto en vivo no
enforceado del lado del Remoto), o alguna de las 4 funciones de `GoldManager`
que resultaron ser de un solo jugador (`puede_pagar()`/`pagar_coste()`,
`play_card()`, `generar_oro_virtual_restringido()`,
`generar_oros_virtuales()`). No queda ninguna carta sin convertir por simple
descuido — el barrido de "grupos grandes" iniciado hace varias tandas llega
a su fin natural.

**Total acumulado (cartas únicas confirmadas): 126.**

**Sin verificar en partida real todavía.** Verificado con el headless check — sin
errores de parseo.

## 33. Refactor de `GoldManager` — Oro Virtual y Oro Restringido pasan a ser por jugador (2026-10-07)

**A pedido del usuario** ("haz el refactor de goldmanager"), tras confirmar en
§22/§26/§28/§29/§32 que el límite real no era todo el sistema de Oro sino
cuatro funciones puntuales de `GoldManager.gd`: `puede_pagar()`,
`pagar_coste()`, `generar_oros_virtuales()` y `generar_oro_virtual_restringido()`
operaban siempre sobre la billetera del jugador 0, sin importar quién
necesitara pagar o recibir el Oro. `GameState.puede_pagar()`/`pagar_oro()`
y `PaymentManager.puede_jugar_carta()` ya eran genuinamente por jugador desde
antes (confirmado leyendo el código, no asumido) — el arreglo quedó acotado a
`GoldManager` y a los sitios que llamaban a sus cuatro funciones de un solo
jugador.

**Qué cambió:**
- `oros_virtuales`, `virtual_gold_tokens` y `restricted_gold_pools` pasaron de
  `int`/`Array` sueltos a `Dictionary = {0: ..., 1: ...}` indexados por
  `player_id`.
- `puede_pagar()`, `pagar_coste()`, `generar_oros_virtuales()`,
  `generar_oro_virtual_restringido()`, y sus helpers internos
  (`_choose_physical_gold_to_spend()`, `_resolve_gold_paid_reaction()`,
  `_restricted_gold_available_for()`, `_consume_restricted_gold_for()`,
  `_spawn_gold_token()`/`_despawn_gold_token()`/`_despawn_virtual_gold_token()`,
  `get_oro_disponible/pagado/total()`) ganaron un parámetro final
  `player_id: int = 0` (default = compatibilidad retroactiva con todo
  llamador viejo) y ahora leen/escriben por el jugador que corresponde, no
  siempre el 0. `limpiar_oros_virtuales()`/`limpiar_oro_restringido()` limpian
  ambos jugadores siempre (recorren `[0, 1]`).
- `PaymentManager.puede_jugar_carta(card, player_id)`: se sacó la guardia
  `if player_id == 0` que forzaba a leer el Oro Virtual/Restringido del
  jugador 0 sin importar el `player_id` recibido.
- `ActionPipeline.gd`: la rama de coste en Oro de `activate_ability()`/
  `can_activate_ability()` (habilidades activadas genéricas) estaba partida
  en dos caminos — jugador 0 por `GoldManager`, jugador 1 por
  `EasyBotController._pay_oro_for_bot()` — y se unificó a un solo llamado a
  `pagar_coste()`/`puede_pagar()` con el `controller_id` real. Confirmado
  por grep que `RemotePlayerController.gd` llama a
  `ActionPipeline.activate_ability()` directo, así que esta rama sí es
  camino real del Remoto.
- `GoldManagerVisuals._spawn_gold_token()`/`_despawn_gold_token()`: eligen el
  contenedor de Reserva (`player_gold`/`opponent_gold`) por `player_id` en vez
  de siempre `_main.player_gold`.

**Bug encontrado y arreglado de pasada:** `SearchAbilityHandler_JV.gd:384`
sumaba `GameState.get_oro_reserva(0) + gold_manager.oros_virtuales` — tras
convertir `oros_virtuales` a `Dictionary` esto hubiera reventado en tiempo de
ejecución (`int + Dictionary`); arreglado a `.oros_virtuales.get(0, 0)`.
Verificado con grep en todo `scripts/` que no quedó ningún otro acceso crudo
(sin `.get()`/indexado) a las tres variables convertidas.

**Cartas desbloqueadas o completadas por este refactor:** vision heroica,
Piruquina, Sake, la habilidad de Oro de Shub-Niggurath
(`PreventionAbilityHandler_PV.gd`); Ramón Freire, Sacrificio Solar (+ arreglo
de animación de barajado faltante, mismo patrón recurrente de siempre)
(`HandCementerioAbilityHandler.gd`); Asmodeus, Cetro Demoniaco
(`SearchAbilityHandler_AI.gd`); Padre de la Patria (re-desbloqueada — la
guardia agregada antes en la sesión por este mismo límite se sacó), voragh el
devorador (`SearchAbilityHandler_JV.gd`); Legión Paladín, Levisterio
(`DSR_SearchGoldCombos.gd`); Garfio Pirata, manuel rodriguez (+ animación de
barajado faltante), almirante akari, Espíritu de la Máquina
(`GoldConversionPatterns.gd`, completando el archivo); Golpe Solar
(`DSR_DiscardChoicePatterns.gd` — mano fija a `player_hand` arreglada en 3
sitios, `chooser_id` agregado a sus dos `await_target()`, y
`ally_node.owner_id` seteado explícitamente para el caso "jugado desde
Cementerio"); el patrón genérico de Armas "cuando el portador ataque, genera
un Oro... roba una carta" (`GameManager._resolve_wielder_attack_choice()`,
guardia `player_id != 0` sacada). De pasada, arreglado un bug silencioso
preexistente en `BanishOpponentPatterns.gd` (ea poe): la función no tenía
guardia pero sí usaba siempre el Oro del jugador 0 sin verificar
`controller_id` — ahora enruta por el `controller_id` real.

**Deliberadamente fuera de alcance, sin cambios:**
- `GoldManager.play_card()`/`play_card_from_exile()`/`play_card_from_cemetery()`
  — siguen con la guardia `active_player_id != 0`. Usadas por el flujo normal
  de jugar cartas del Anfitrión; el Remoto ya tiene su propio pipeline
  independiente (`RemotePlayerController.gd`/`EasyBotController.gd`) que no
  pasa por estas funciones, así que sacar la guardia no ayudaría al Remoto y
  sí arriesgaría desestabilizar el flujo del Anfitrión. Mismo criterio que
  en §23/§25/§26 — las cartas que llaman a `play_card()` directo (Crono
  Diamante, segunda habilidad de Belta, Miguel, el descuento de Paladín
  Bestiarium, La Ouija, el descuento de Kuchiku Cazador) siguen excluidas por
  esta misma razón.
- `GoldManagerRestrictions._can_play_weapons_in_guerra_talismanes()` — se
  queda acotado al jugador 0, consistente con que `play_card()` también se
  queda así.
- sandraudiga y la segunda habilidad de Perla de Sangre — bloqueadas por
  `SelectionManager.await_single_pick()` (un sexto tipo de diálogo sin puente
  de red), no por Oro. Sin cambios.
- asedio naval (`lock_group_key`), Tempilcahue (`dynamic_filter`), contra el
  caos (`CardNameSearchDialog`) — exclusiones ya documentadas en §32/§10.14,
  no relacionadas con este refactor. Se verificó específicamente que asedio
  naval no necesitaba este arreglo de Oro — su guardia es por el candado de
  "mismo tipo", no por `GoldManager`.

**Total acumulado (cartas únicas confirmadas): 143.**

**Verificado con el headless check tras cada tanda de cambios — sin errores
de parseo. Sin verificar en partida real todavía.**
