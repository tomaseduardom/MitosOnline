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

## Pendiente de detallar (próxima sesión de diseño)

Estos puntos quedaron identificados pero no resueltos en el nivel de detalle necesario para
implementar — son la continuación natural de este documento:

1. **Resucitar `StackObjectType.CARD_PLAYED`**: cómo exactamente `GoldManager.play_card()` /
   `_play_talisman()` / `_play_card_to_field()` (hoy juegan directo, sin pila) pasan a declarar
   la carta (Pasos A/B como ya existen para habilidades activadas) y empujarla a la pila ANTES de
   resolver su efecto — separando claramente "esto es un costo" (Golpe Solar autodestierro) de
   "esto ya se puede responder" (targets elegidos, lista para el Paso D).
2. **Plan de migración concreto de los ~30 archivos de triggers**: orden, cómo verificar cada uno
   sin romper el resto (mismo patrón de auditoría por lotes ya usado hoy con `return_to_deck`).
3. **Lógica de decisión del bot dentro de la ventana**: `EasyBotController` necesita un criterio
   real para decidir si responde o pasa (hoy solo decide jugadas propias, nunca reacciona a nada).
4. **Rediseño visual concreto de `ResponseWindowHandler`**: mockup del panel con N botones
   dinámicos, posición, cómo convive con el botón "¿Paso?" de fase que ya existe (evitar
   duplicar UI para lo mismo).
5. Cómo interactúa esta pila con el protocolo de red del diseño de multiplayer (una vez esta
   pila exista, el protocolo `intent`/instrucciones va a necesitar expresar "tengo prioridad,
   ¿respondés?" en vez de solo "jugué una carta").
