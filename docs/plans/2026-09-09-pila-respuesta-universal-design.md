# Pila de Respuesta Universal (DAR Sección 6 — generalizada a toda acción)

Fecha: 2026-09-09
Estado: diseño en progreso, validado por secciones — quedan puntos pendientes de detallar
Precede a: `2026-09-09-multiplayer-remoto-design.md` (se implementa ANTES del multiplayer, a
pedido del usuario, porque el protocolo de red asume "acciones simples" y necesita conocer esta
pila para poder sincronizar ventanas de prioridad reales entre Anfitrión y Remoto)
Reemplaza en parte a: `2026-09-02-prevention-response-window-design.md` (esa Prevención reactiva
ya se implementó — ver `project_reactive_prevention_system.md` — pero como mecanismo PROPIO y
paralelo; este documento la fusiona dentro de la ventana genérica en vez de mantenerla aparte)

## Problema

Hoy, cuando el rival juega una carta o usa una habilidad, no hay ninguna oportunidad real de
reaccionar — todo resuelve en cadena fija. Esto era aceptable cuando "el rival" nunca actuaba de
forma independiente, pero ya no es así: `EasyBotController` juega solo, y pronto habrá un
jugador Remoto real (ver diseño de multiplayer). El usuario pidió, explícitamente y "como
siempre dijo que iba a ser", una **pila de prioridad real y recursiva, lo más fiel posible al
DAR**: cada acción (jugar una carta o usar una habilidad, disparada o activada) abre una ventana
donde el otro jugador puede responder con SU propia carta/habilidad, lo cual a su vez abre una
ventana de vuelta — sin límite de profundidad — y todo resuelve en orden LIFO (lo último jugado
resuelve primero) cuando ambos pasan consecutivamente.

## Hallazgo clave: ya existe una base real, mal conectada

Antes de diseñar desde cero, se auditó el código y se encontró una implementación sustancial ya
escrita pero apenas usada:

- **`ActionPipeline.gd` + `StackStepResolver.gd`**: pila LIFO real con Pasos A-E (DAR Sección 6),
  anular/cancelar/fizzle, resolución por capas. Funciona de verdad, pero **solo las habilidades
  ACTIVADAS pasan por acá** (`AbilityButtonSupport.gd` → `ActionPipeline.activate_ability()`), más
  un único caso disparado (Exhumar, vía `SelectionModule.gd`). El soporte para **cartas jugadas**
  (`StackObjectType.CARD_PLAYED`) fue borrado en 2026-08-27 por no tener llamador real — nada las
  mete a la pila hoy.
- **`PriorityManager`**: motor de prioridad real, con un botón "¿Paso?" YA FUNCIONANDO en el HUD
  (brillo cuando te toca actuar, usado hoy en Guerra de Talismanes y Bloqueo) — no es un mockup,
  es la pieza que de verdad hay que generalizar.
- **`ResponseWindowHandler.gd`**: overlay visual para el Paso D de la pila ("⏸ Ventana de
  Respuesta") — pero se auto-pasa sola a los **2 segundos para ambos lados sin preguntar nada de
  verdad**, porque hasta ahora el "oponente" nunca podía responder de verdad.
- **~30 archivos de patrones de triggers** (`LookAndPlayResolver` y sus 7 mitades, `DSR_*`,
  `TargetedEffectExecutor`, etc.) resuelven TODO directo, sin tocar la pila jamás.
- El sistema de **Prevención reactiva** construido hoy mismo (`EffectController.offer_prevention()`)
  es un mecanismo PROPIO y paralelo, con sus propios diálogos — no pasa por esta pila.
- **Bernardo O'Higgins** (habilidad activada con coste alternativo) tiene su propio dispatcher
  especial en `CardInspectionLayer`/`BernardoAbilityHandler.gd`, tampoco pasa por
  `ActionPipeline.activate_ability()` como el resto de las activadas.

Conclusión: no hay que inventar el motor, hay que **terminar de conectarlo** a todo lo que hoy lo
esquiva, y rediseñar la ventana para que de verdad espere una decisión real.

## Decisiones validadas con el usuario

1. **Alcance**: pila completa y recursiva, sin acotar a un solo nivel de respuesta — fidelidad al
   DAR por sobre la simplicidad.
2. **También contra el bot**, no solo para el futuro Remoto — es una mejora del motor central,
   independiente del multiplayer, que además el Remoto hereda gratis después.
3. **Anti-filtración de información**: la ventana de respuesta **siempre se abre**, con un
   temporizador (base 5 segundos), aunque el jugador no tenga nada elegible — así el rival nunca
   puede inferir "no abrió nada = no tiene cartas" por la sola ausencia de pausa. Es clickeable
   para pasar desde el instante 0, así que no frena el ritmo de la partida si nadie quiere
   reaccionar.
4. **Contra el bot, la misma pausa de 5 segundos es indiferente** (confirmado por el usuario) —
   no hace falta un camino especial más rápido para el bot; un solo mecanismo sirve para los dos
   casos (bot y humano).
5. **Granularidad confirmada con el ejemplo real de Golpe Solar** (Talismán):
   - El **costo** (autodestierro) resuelve de inmediato, nunca se responde — mismo principio ya
     usado en Prevención ("los costos nunca son efectos").
   - El jugador activo declara TODO lo demás (objetivos a barajar, cartas a descartar, elección de
     Aliado) — la carta queda "anunciada" con sus decisiones ya tomadas.
   - **Recién ahí** se abre la ventana de respuesta (p.ej. Anular con Espada Vikinga/Ciempiés).
   - Responder es en sí mismo jugar algo → abre una ventana nueva de vuelta al jugador original
     (recursión).
   - Si nadie responde más, resuelve todo en cadena LIFO. Si el efecto resuelto juega un Aliado, o
     ese Aliado dispara su "Cuando entra en juego", cada uno de esos es una acción nueva con su
     propia ventana.

## Estrategia de integración (para no reescribir 30 archivos desde cero)

Casi todos los archivos de patrones de triggers ya tienen la misma forma interna: detectar texto →
(guard de "el bot no usa esto todavía") → elegir objetivo/modo con `await` → recién ahí ejecutar el
efecto (`ActionModule.destroy/banish/...`). Ese límite entre "ya se declaró todo" y "ejecutar el
efecto" ya existe de forma natural en cada función — es el mismo lugar donde hoy insertamos
`EffectController.offer_prevention()` en los choke points de destroy/exile/etc.

La integración consiste en insertar, en ese mismo límite, una llamada nueva (p.ej.
`await TriggerSystem.open_response_window(source_card, ability_data, targets_ya_elegidos)`) que:
- Empuja un objeto a la Pila de `ActionPipeline` (que YA sabe procesar Pasos C/D/E).
- Abre el Paso D para el rival, usando el `PriorityManager` YA real (mismo botón "¿Paso?").
- Si alguien anula/cancela, la función que llamó aborta antes de ejecutar sus líneas de efecto.
- Si nadie responde, la función sigue exactamente igual que hoy.

Es la MISMA técnica mecánica que ya se usó dos veces esta sesión (ripple de `await` en
`silence_card()`/`return_to_deck()`), solo que a mayor escala (~30 archivos en vez de ~20-23).

## La ventana de respuesta (diseño de contenido, reutilizando lo que ya detecta el motor)

**Candidatos ofrecidos** — sin inventar un detector nuevo, reusando lo que YA existe:
- Talismanes de respuesta en mano (`_is_response_only_talisman()` — Red de Plata, Sheut,
  Sacrificio Solar).
- Habilidades activadas legales en ese momento (`ActionPipeline.can_activate_ability()` — ya
  valida fase/candado/coste), incluyendo casos hoy especiales como Bernardo, que deberían dejar de
  tener un dispatcher aparte y sumarse al camino genérico de `activate_ability()`.
- Las 5 entradas del registro de Prevención (`EffectController._prevention_registry`) que apliquen
  al objeto del tope de la pila.

**Fusión con Prevención**: `offer_prevention_for_player()` deja de abrir su propio diálogo — pasa
a registrar sus candidatos como opciones dentro de esta ventana genérica. Ajuste acotado sobre lo
construido hoy, no se descarta nada del trabajo ya hecho.

**El panel**: rediseño de `ResponseWindowHandler` — siempre visible, temporizador de 5 segundos,
botón "Pasar" clickeable desde el instante 0, un botón más por cada candidato real. Mismo
comportamiento sin importar si hay 0 o varios candidatos.

## Fusión con Prevención — resuelta de forma acotada (2026-09-09)

Durante la migración mecánica de los ~30 archivos de triggers apareció el problema real
anticipado más arriba: varios choke points ya protegidos por el sistema de Prevención de hoy
(`ActionModule.destroy()`/`banish()` con `can_be_prevented=true` por defecto, `KeywordManager.
silence_card()`, `ActionModule.return_to_deck()` — los 4 SIEMPRE consultan `EffectController.
offer_prevention()` internamente, sin ningún parámetro para saltarlo) terminaban con la ventana
genérica nueva preguntando ANTES, y el chequeo de Prevención preguntando DE NUEVO adentro —
doble pregunta por el mismo efecto.

En vez de la fusión completa en una sola UI (candidatos de Prevención + Talismanes de respuesta +
activadas en un solo diálogo — la Capa 2 completa, todavía no construida), se resolvió con un
criterio más simple y suficiente por ahora: **la ventana genérica NO se inserta antes de una
llamada a `destroy()`/`banish()`/`silence_card()`/`return_to_deck()`**, porque esas 4 funciones YA
tienen su propio chequeo de Prevención adentro — agregarla ahí sería puro trabajo duplicado sin
agregar nada. La ventana genérica se queda cubriendo exactamente lo que Prevención NO toca hoy:
buscar (`ActionModule.search()`, confirmado que nunca consulta Prevención), generar Oro, robar,
descartar, convertir sin silenciar, robar control, bloquear habilidad por nombre (mecanismo
distinto a `silence_card()`), y jugar una carta gratis. Se revisó cada uno de los ~30 sitios ya
migrados para confirmar cuál categoría le tocaba; se sacó la ventana genérica de los ~10 que
resultaron redundantes (dejando un comentario explicando por qué en cada uno).

Esto dejaba pendiente la fusión "de verdad" (un solo diálogo con todas las opciones) para más
adelante, pero sin doble-preguntado mientras tanto — que era el riesgo real, no la estética del
diálogo.

## Fusión visual completa (2026-09-09, punto 1 cerrado)

`EffectController.offer_prevention_for_player()` dejó de abrir su propio diálogo aparte
(`SelectionManager.await_two_choice()`/`await_single_pick()`) — ahora, para el humano, muestra el
MISMO panel visual que la ventana genérica (`_ask_prevention_panel()`, nueva función en
`EffectController.gd`: mismo título "⏸ Ventana de Respuesta", mismo tamaño/posición, mismo timer
de 5 segundos, "Pasar" clickeable desde el instante 0, un botón "Usar <carta>" por candidata). No
se construyó sobre `ActionPipeline`/`ResponseWindowHandler` directamente porque `EffectController`
(autoload) no tiene una referencia al `CardInspectionLayer` del humano — se duplicó la
construcción del panel (CanvasLayer/PanelContainer con el mismo estilo) en vez de agregar un
acoplamiento cruzado nuevo entre dos módulos de UI separados.

Sigue siendo, a propósito, un mecanismo separado de `ActionPipeline`/Paso D (Prevención no empuja
un objeto a la pila) — la fusión lograda es de **presentación** (un solo estilo de "ventana de
respuesta" en todo el juego, sin doble-preguntado), no de mecanismo interno; Prevención sigue
resolviendo en su propio choke point puntual (dentro de destroy/banish/silence_card/
return_to_deck), que es donde el DAR real la dispara, no en el momento más genérico donde abre la
ventana de la ability completa.

## Estado de la migración (actualizado 2026-09-09)

Migrados a la ventana real, con verificación de compile check en cada paso:
- Casos simples (un solo punto declarar→resolver): ~35 funciones en `BanishOpponentPatterns.gd`,
  `ShuffleDrawPatterns.gd`, `SearchOwnZonePatterns.gd`, `GoldConversionPatterns.gd`,
  `PlayFromCemeteryPatterns.gd`, `MiscUniquePatterns.gd`, `ConvertAndMiscResolver.gd`,
  `DSR_DiscardChoicePatterns.gd`, `TargetedEffectExecutor._execute_targeted_discard`,
  `WeaponSearchShuffleExecutor._execute_targeted_search` (esta última cubre muchas cartas de
  "busca X" a la vez, por ser la resolutora genérica).
- `DSR_CemeteryBanishDraw.gd` y `DSR_SearchGoldCombos.gd`: completos (8/8 y 4/4) — se les hiló el
  parámetro `card` que les faltaba (mismo patrón que el ripple de `return_to_deck`/`silence_card`
  de la sesión anterior: agregarlo al final de la firma, al forwarder de `DrawShuffleResolver.gd`,
  y al único llamador real en `TriggerResolution.gd`).
- Casos multi-parte reordenados al patrón "declarar TODO → UNA ventana → resolver TODO": Golpe
  Solar (el caso de estudio original), Dragón Dorado ('Luego' — dos ventanas separadas porque son
  dos efectos secuenciales, no uno), cruzar el bosque, Acabar la Esperanza, y Sherlock Holmes (el
  más complejo — selección por carrera Castillo-vs-carta ya separaba declarar/ejecutar en la rama
  de cartas; se agregó la ventana ahí y antes del revelado en la rama de Castillo).

- **`LookRevealPatternsB.gd` — completo (8/8)**: las 8 funciones "muestra/revela hasta encontrar
  X" (Cabeza de Mimir, metalmorfo, Activar Tenshi Z, akari, Alicia en Wonderland, gran kraken,
  atenea en wonderland, contra el caos) se hilaron con `card` por las 3 capas de facade
  (`LookRevealPatternsB.gd` → `LookRevealPatterns.gd` → `LookAndPlayResolver.gd` →
  `TriggerResolution.gd`) y llevan la ventana AL PRINCIPIO (antes de empezar a revelar) — no hay
  objetivo real que declarar (orden del mazo), así que se abre una sola vez por toda la
  resolución, salvo "contra el caos" que sí tiene un declare real (nombrar carta) y la ventana va
  después de eso. Queda deliberadamente fuera `try_execute_peek_hand_banish_search_castillo_
  cemetery_draw_pattern` (Duelo de Dragones) — tiene objetivos reales entrelazados con ejecución
  inmediata vía `ActionModule.search()`, complejo, para otra sesión.
- **`ShuffleDrawPatterns.gd` — completo (11/11)**: 7 funciones sin `card` se hilaron igual que
  arriba (Caín A/B, el caleuche, manuel rodriguez, amazona desafiante, Abrazo de Maipú, Príncipe
  Orión, kaitai); 2 que ya tenían `card` (Caín post-combate, Tótem del Dragón Ancestral) recibieron
  su ventana en el cuerpo. `vision heroica` se dejó sin ventana a propósito (solo resuelve vía
  `return_to_deck()`, ya cubierto por Prevención interna). `Ofrendas al Dragón` (`try_execute_
  shuffle_banish_four_cemeteries_pattern`) queda diferida: es un wrapper puro de
  `GoldManager._resolve_armeria_barajar_desterrar()`, que resuelve elección-por-carta intercalada
  (Cementerio→Castillo o Destierro) sin ningún punto declarar-todo-antes-de-resolver — meterle una
  ventana requeriría rehacer ese helper compartido (también usado por Belta), mismo nivel de
  complejidad que Duelo de Dragones arriba.
- **`DSR_ShuffleDrawCombos.gd` — completo (5/5, contando `try_execute_draw_and_shuffle_opponent_
  card_pattern` que ya estaba)**: El Rey y el Verdugo, Manuel Bulnes y Trono del Dragón hilados
  igual que arriba. `try_execute_shuffle_hand_and_draw_plus_two_pattern` (Aaru) se dejó sin tocar
  a propósito: es un Talismán, ya cubierto por el choke point único de `resolve_talisman()` —
  agregarle ventana propia sería double-ask.
- **Barrido completo de los ~30 archivos de triggers — hecho (2026-09-10)**: se resolvió el punto
  2 de "Pendiente de detallar" (abajo) auditando función por función CADA archivo de
  `scripts/core/effects/triggers/` (conteo de `open_response_window` por archivo como checklist).
  Quedaron completos, además de los ya mencionados arriba: `DSR_DiscardChoicePatterns.gd`
  (Escamas de Dragón hilada; Tempilcahue/Golpe Solar confirmados ya cubiertos por
  `resolve_talisman()`), `GoldConversionPatterns.gd` (7/7 — peripillan, almirante akari,
  Espíritu de la Máquina), `PlayFromCemeteryPatterns.gd` (3/3 — Titán Abismal y sumi el terrible,
  cada rama A/B con su propia ventana), `SearchOwnZonePatterns.gd` (10/10 — Danza de Dragones,
  asedio naval, Azi Sruvara), `BanishOpponentPatterns.gd` (el más grande, 18 funciones — ignis
  desatado, Asmodeus, cuervo nocturno, cruzar el bosque, Carcosa, estacion gaia, akari musashi;
  ea poe confirmado ya cubierto por ser Talismán), `ConvertAndMiscResolver.gd` (6/6 — Biblioteca
  de Caballería, Jormundgander, Espada del Juicio, Miguel), `MiscUniquePatterns.gd` (Fisión
  Nuclear, con DOS ventanas — una para la burbuja inmediata, otra dentro del callback diferido de
  Fase Final; Transformación confirmada Talismán ya cubierto), `WeaponSearchShuffleExecutor.gd`
  (Bernardo O'Higgins, Lobo Sagrado, Padre de la Patria — el costo resuelve antes de la ventana,
  el efecto después, mismo criterio DAR de todo el documento), `LookRevealPatternsA.gd` (Tesoro
  de los Césares, Signo Amarillo, kitsune - sp). Confirmados ya completos sin cambios:
  `DSR_CemeteryBanishDraw.gd`, `DSR_SearchGoldCombos.gd`, `MiscTargetedPatterns.gd`,
  `TargetedEffectExecutor.gd` (incluye `_execute_targeted_annul()`, que a propósito NO lleva
  ventana — ver su propio docstring, "alcance acordado"). Quedan diferidos por complejidad real
  (no por descuido): Duelo de Dragones (`try_execute_peek_hand_banish_search_castillo_cemetery_
  draw_pattern`, objetivos entrelazados con ejecución inmediata) y el helper compartido
  `GoldManager._resolve_armeria_barajar_desterrar()` (Ofrendas al Dragón/Belta, elección
  intercalada carta-por-carta sin punto declarar-todo-antes-de-resolver).
- ~~Los helpers compartidos `_resolve_search_cemetery_to_hand()`/`_resolve_banish_from_both_
  cemeteries()`~~ — resueltos: el primero ya queda cubierto por la ventana que envuelve TODA la
  habilidad de Legión Paladín en su llamador; el segundo (Espada de O'Higgins) se reordenó igual
  que Golpe Solar (declarar las 2 selecciones, UNA ventana, resolver los 2 destierros).
- ~~Presente (`try_execute_look_play_or_hand_pattern`)~~ — arreglado el mismo bug de bot-decline
  que Tangata Manu/Perder la Razón, con ventana de respuesta agregada de paso.
- ~~La fusión completa de Prevención en un único diálogo~~ — hecha (2026-09-09, ver más abajo).
- Capa 2, avance parcial (2026-09-09): el bot YA decide de verdad en dos frentes reales —
  1. **Prevención** (`EffectController.offer_prevention_for_player()`): se sacó el early-return
     "el bot no responde Prevención todavía" — ahora, si hay candidatos, el bot decide solo (sin
     diálogo) al azar si usa una o ninguna. Este chequeo vive en su propio choke point (dentro de
     destroy()/banish()/silence_card()/return_to_deck()), separado de la ventana genérica.
  2. **Habilidades activadas** (`EasyBotController.try_respond_with_activated_ability()`, llamado
     desde `ResponseWindowHandler._bot_pass_after()` antes de pasar): el bot escanea sus propias
     cartas en juego, junta las habilidades ACTIVADAS legales y decide al azar si usa una.
     Alcance v1 acotado a propósito: solo costo NONE u ONCE_PER_TURN sin recurso (Oro/Descarte/
     Girar) — `ActionPipeline.activate_ability()` paga esos 3 tipos SIEMPRE contra el GoldManager/
     mano del jugador 0 (mismo motivo de fondo que ya bloqueaba `play_card_for_free()` para el
     bot), así que activarlas ahora pagaría del lado equivocado. Tampoco pasa por
     `can_activate_ability()` (exige ser tu propio turno activo — pensado para el botón de Zoom,
     no para una respuesta instantánea en el turno rival).
  3. **Habilidades activadas con costo de Oro o Girar — hecho (2026-09-10)**: se sacó de
     `ActionPipeline.can_activate_ability()` el chequeo `active_player_id == controller_id`
     ("No es tu turno") — el DAR no lo exige para habilidades instantáneas en Vigilia/Guerra de
     Talismanes, y era lo único que bloqueaba responder en el turno rival tanto al bot como al
     humano. El Paso B (pago) y el chequeo de saldo ahora distinguen: `controller_id == 0` sigue
     yendo por `GoldManager` (Oro Virtual/restringido incluido); cualquier otro usa
     `GameState.puede_pagar()`/`GameState.get_oro_reserva()` y paga físico real vía
     `EasyBotController._pay_oro_for_bot()` (mismo helper ya usado para jugar cartas). Girar (TAP)
     no necesitó cambios — nunca dependió de qué jugador es. `try_respond_with_activated_ability()`
     amplió su filtro de candidatos para incluir Oro y Girar (con chequeo de saldo/ya-girada antes
     de ofrecerla como candidata).
  **Sigue sin cubrir**: Talismanes de respuesta (Red de Plata, Sheut, etc.) — el bot no sabe jugar
  Talismanes en general todavía (ni siquiera fuera de una respuesta); y habilidades activadas con
  costo de Descarte — el bot no tiene su mano representada como Nodos, así que no hay de dónde
  elegir qué descartar (requeriría construir esa representación primero).
- **`CARD_PLAYED` para Talismanes — hecho (2026-09-09)**: en vez de resucitar el `StackObjectType.
  CARD_PLAYED` de `ActionPipeline` (que habría exigido rehacer Pasos A/B ahí para cartas jugadas,
  un camino paralelo al de `GoldManager`), se encontró un choke point único y suficiente:
  `TriggerSystem.resolve_talisman(card)` — para un Talismán, "jugarlo" y "que su efecto resuelva"
  son EL MISMO momento del DAR (a diferencia de un Aliado, no hay estado intermedio de "en
  juego"). Ahora `resolve_talisman()` abre `open_response_window()` ANTES de resolver el efecto y
  devuelve `bool` (true = anulado/cancelado); `GoldManager._trigger_enter_play()` propaga ese bool
  (cambimétodo de `-> void` a `-> bool`); `_play_talisman()` lo usa: si fue anulado, manda la
  carta directo al Cementerio (`EffectController.destroy_card(..., false)`) SIN mirar su propio
  texto ("destiérralo"/"barájala" no aplican a un efecto que nunca ocurrió) y sin ejecutar nada de
  su efecto. Esto cubre a TODOS los Talismanes de una sola vez, no solo a los migrados
  individualmente — las 3 patrones que ya tenían su propia ventana interna de cuando no existía
  este choke point (Golpe Solar, Tempilcahue, Acabar la Esperanza) se la sacaron para no
  preguntar dos veces.
  **Aliado/Arma/Tótem/Oro — hecho (2026-09-10)**: ver el punto 1 de "Pendiente de detallar" más
  abajo, ya resuelto — su "ser jugado" ahora también abre una ventana, con la aproximación
  pragmática acordada con el usuario (justo antes del ETB, no antes de animar el Node). Detalle
  completo más abajo, no se repite acá.

## Pendiente de detallar (próxima sesión de diseño)

Estos puntos quedaron identificados pero no resueltos en el nivel de detalle necesario para
implementar — son la continuación natural de este documento:

1. ~~CARD_PLAYED para Aliado/Arma/Tótem/Oro~~ — hecho (2026-09-10). Decisión con el usuario
   (`AskUserQuestion`): en vez de reescribir el destino en cada camino de juego (`play_card`,
   `_equip_weapon`, `_place_card_as_gold`, las búsquedas que colocan directo — todas terminan en
   `_trigger_enter_play()`) para abrir la ventana ANTES de crear/animar el Node, se optó por la
   aproximación pragmática: la ventana se abre dentro de `GoldManager._trigger_enter_play()`
   (rama no-Talismán), justo antes de `CardFactory.on_card_enters_play()`/el disparo de
   `on_enter_play` — la carta YA se animó y está en una zona de juego válida (igual que hoy), pero
   si se Anula/Cancela ahí su ETB nunca dispara: va directo al Cementerio vía
   `EffectController.destroy_card(controller_id, card, false)` (mismo criterio que ya usaba
   `_play_talisman()` para su propio caso), sin tocar ninguno de los 7 call sites de
   `_trigger_enter_play()` (todos solo hacían `await` sin usar el resultado, así que centralizar
   el manejo de anulación ADENTRO de la función no rompió nada). `controller_id` se deriva de
   `card.owner_id` (mismo patrón que `TriggerSystem.resolve_talisman()`). La habilidad puntual de
   Almirante Akari (`EffectController.offer_counter_annul()`, DESPUÉS del ETB) queda intacta
   sin cambios — es un mecanismo aparte, no registrado en el sistema de Prevención/ventana
   genérica, así que no hay double-ask: si la ventana genérica de arriba ya anuló la carta, ni
   siquiera se llega a esa línea (return true corta antes).
   **Limitación conocida, aceptada**: la carta se ve entrar en juego (posición final, animación
   completa) incluso si termina anulada un instante después — no es una interrupción DAR perfecta
   (el objetivo real, "Anular ANTES de que su ETB resuelva", sí se cumple; lo que no se cumple es
   "impedir que se la vea aparecer en el campo"). Reescribir eso completo (fidelidad total) queda
   documentado como alternativa más cara, descartada por ahora.
2. ~~Plan de migración concreto de los ~30 archivos de triggers~~ — hecho (2026-09-10, ver
   "Barrido completo" arriba): los ~30 archivos de `scripts/core/effects/triggers/` quedaron
   auditados función por función; solo Duelo de Dragones y el helper compartido de Ofrendas al
   Dragón/Belta quedan diferidos por complejidad real de reordenamiento, no por descuido.
   **Ampliación 2026-09-10**: al revisar esos dos casos se descubrió que Duelo de Dragones y
   Ofrendas al Dragón son Talismanes (`tipo: 3` en el cache) — ya cubiertos por el choke point de
   `resolve_talisman()`, sin trabajo pendiente real. El "helper de Belta" resultó ser algo más
   grande: `GoldManager._resolve_armeria_barajar_desterrar()` la usan sobre todo **habilidades
   ACTIVADAS** de un sistema totalmente aparte (`scripts/ui/inspection/PreventionAbilityHandler_
   AE.gd`/`_EP.gd`/`_PV.gd`, `SearchAbilityHandler_AI.gd`/`_JV.gd`, `HandCementerioAbilityHandler.
   gd`, `BernardoAbilityHandler.gd`) que resuelve el efecto directo al clickear el botón del Zoom,
   sin pasar por `ActionPipeline.activate_ability()` ni por ninguna ventana — el mismo sistema ya
   anotado como pendiente en `[[project_pending_helper_sweep]]`. Se auditaron las **66 funciones
   `_activate_*`** de esos 7 archivos función por función (mismo criterio de todo este documento:
   ¿el camino de resolución ya pasa por `destroy()`/`banish()`/`silence_card()`/`return_to_deck()`
   protegidos, o por `play_card()`/`play_card_for_free()`/`_equip_weapon()`/`_play_card_to_field()`
   ya cubiertos por el CARD_PLAYED de más arriba, o por `_execute_targeted_discard()` que ya abre
   su propia ventana? Si sí, no hace falta nada más; si no, se le agregó `TriggerSystem.
   open_response_window()` en el límite declarar→resolver). Resultado: ~46 funciones recibieron
   ventana nueva, ~20 ya estaban cubiertas por alguno de esos caminos y se dejaron intactas.
   Detalle no trivial encontrado en varias cartas (akari, Campanita, lanza argenta, Chakram/etc.):
   cuando la propia carta activadora se autodestierra/autodestruye/autodescarta como parte de su
   costo, `open_response_window(source_card, ...)` deja de servir después de eso (`source_card`
   exige `is_instance_valid()`) — en esos casos la ventana se movió a ANTES del autocosto, no
   después, documentado puntualmente en cada función tocada.
3. **Lógica de decisión del bot dentro de la ventana** — avance parcial, ver "Capa 2" arriba
   (Prevención + habilidades activadas de costo NONE/ONCE_PER_TURN/GOLD/TAP); sigue faltando
   Descarte (sin mano representada como Nodos) y Talismanes de respuesta.
4. **Rediseño visual concreto de `ResponseWindowHandler`**: mockup del panel con N botones
   dinámicos, posición, cómo convive con el botón "¿Paso?" de fase que ya existe (evitar
   duplicar UI para lo mismo).
5. Cómo interactúa esta pila con el protocolo de red del diseño de multiplayer (una vez esta
   pila exista, el protocolo `intent`/instrucciones va a necesitar expresar "tengo prioridad,
   ¿respondés?" en vez de solo "jugué una carta").

## Bug real encontrado en juego (2026-09-10) — bucle en Fase Final/Vigilia

El usuario reportó (con log de consola) un bucle real: "Biblioteca de Caballería" (`on_opponent_
turn_end`, un trigger de Fase Final) resolviéndose DOS veces seguidas, y el mismo patrón con
Drácula en Vigilia. Diagnóstico: `TriggerResolution.resolve_next_trigger()` (el camino VIEJO de
resolución instantánea de triggers, de 2026-08-17 — "el bot nunca responde nada de verdad, así
que la ventana era pura fricción") ponía `awaiting_response = false` ANTES de ejecutar el efecto
real (`_execute_trigger_effect()`). `PhaseFlowController._on_priority_both_passed_main()` tiene
una guardia explícita (`if TriggerSystem.awaiting_response: return`) documentada exactamente para
"no reacciones a una ventana anidada de un trigger, es suya" — pero como `awaiting_response` ya
estaba en `false` para cuando `open_response_window()` (agregada HOY a ~40 patrones de trigger)
abre su ventana real desde DENTRO de `_execute_trigger_effect()`, esa ventana nueva quedaba fuera
de la guardia.

**Arreglado**: `awaiting_response` ahora sigue en `true` durante TODA la ejecución del efecto, no
solo durante el chequeo previo — `resolve_next_trigger()` en `TriggerResolution.gd`.

**Confirmado (2026-09-11)**: el arreglo de arriba resolvió el bucle/doble-resolución original, pero
destapó un segundo problema real, más grave — el juego quedaba TOTALMENTE congelado en Fase Final,
sin ningún log posterior (`TriggerSystem.awaiting_response`/`is_resolving` atascados en `true` para
siempre, confirmado por el usuario: un click extra en ¿Paso? no producía ningún log nuevo).

**Diagnóstico** (por lectura estática — no se pudo reproducir en vivo): el sospechoso más probable
es `ActionPipeline.add_triggered_ability_to_stack_and_await()` — la función que `open_response_
window()` usa para esperar a que SU objeto puntual reciba Paso D/E. Si por algún motivo ese objeto
nunca llega a procesarse (p.ej. `add_triggered_ability_to_stack()`'s guard `if not _is_resolving:
_process_stack()` no relanza el loop porque `_is_resolving` quedó en `true` por alguna otra razón),
el `while not done: await get_tree().process_frame` de esa función espera PARA SIEMPRE — sin
ningún timeout, sin ningún log — exactamente el síntoma reportado.

**Arreglado**: se agregó un timeout de 8 segundos a esa espera (calzado con el timer real de 5s de
la ventana de respuesta — margen suficiente sin arriesgar cortar una decisión legítima de nadie,
mismo criterio que ya usa `_wait_for_response_window()`/Signo Amarillo). Si se agota, la función
ahora deja un `push_warning()` con diagnóstico concreto (`stack_id`, `_is_resolving`, tamaño de la
pila) y devuelve "sin anular/cancelar" (el llamador sigue con su efecto normal, mismo criterio de
"no fricción" del resto del sistema) en vez de congelar el juego entero para siempre.

**Sigue sin confirmarse la causa raíz exacta** — esto es una salvaguarda de recuperación, no una
prueba de qué la estaba causando. Si el `push_warning` vuelve a aparecer en la consola, ESE
mensaje (con los valores reales de `_is_resolving`/tamaño de pila en el momento del cuelgue) es la
pista real a seguir la próxima vez, en vez de seguir especulando por lectura estática.
