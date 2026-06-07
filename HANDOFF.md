# HANDOFF — dónde vamos quedando

> **Claude: leé ESTO PRIMERO al abrir la sesión.** Es el estado vivo del
> proyecto, en una pantalla. Mantenelo CORTO (≤1 pantalla). El detalle vive en
> los otros docs (links abajo). **Actualizá este archivo al CERRAR cada sesión**
> (es parte del lifecycle de CLAUDE.md, Fase 6).

---

## Fase 3 — Tickets (slice 3A COMPLETO + backlog vaciado → arrancando 3B)

Propuesta aprobada en `FASE3-PLAN.md` (decisiones: D1 trigger server-side de
descuento de stock · D2 trigger de transición de estado · D3 shell propio del
técnico · D4 correlativo `T-00001` · D5 3A completo).

> **3A cerrado y auditado, SIN backlog pendiente** (ver "BACKLOG VACIADO" abajo).
> Próximo: **slice 3B (técnico)** — roles asignables + shell móvil + bucket `por_tecnico`.

**3A capa 1 — HECHA** (commits `a62a8fb`, `04a5999`):
- **Migración 0103** (server-side, idempotente, transaccional): roles `tecnico`+
  `admin_tickets` (CHECK + `set_cobrador_rol`) · módulo `tickets` (es_base=false) ·
  tablas `ticket_tipos`/`tickets`/`ticket_eventos`(append-only)/`ticket_adjuntos`
  con RLS, super_admin_all, audit triggers · helpers `is_admin_or_tickets`/
  `is_ticket_staff` · trigger de validación de transición de estado.
- **Cadena de integridad**: sync-rules (4 tablas en `todo_tenant_admin` +
  `impersonated_tenant`) · schema.dart (4 tablas) · `_schemaVersion` **20→21** ·
  audit_changelog (4 entidades + value-labels de estado/evento) · modelo
  `Cobrador.esTecnico/esAdminTickets`.

**3A capa 2-3 — HECHA** (commits `dd0ac10`, `5067bd9`):
- `ticket_sla.dart`: SLA derivado (created_at + sla_horas, pausa en_espera) +
  código `T-00001` + transiciones válidas (espejan el trigger) + labels/colores.
- **ticket_tipos CRUD** (`ticket_tipos_screen`) con SLA + guarda de borrado.
- **tickets**: lista (filtro por grupo + badges estado/SLA), crear
  (`ticket_form`, correlativo MAX+1, evento 'creado'), detalle
  (`ticket_detail`: header + SLA + transiciones con re-validación + reasignar +
  comentar + bitácora `ticket_eventos`).
- **Gating**: `/admin/tickets` + 4 rutas + `soloAdmin` + gate de módulo + ítem
  de menú (`moduloKey:'tickets'`).
- **Adjuntos**: migración **0104** (bucket `ticket-adjuntos` + policies) +
  `TicketAdjuntosWidget` (galería + evento 'adjunto') en el detalle.
- ✅ **Audit de 3A HECHO** (3 agentes): DB integrity **limpio**; Code+QA convergieron.
  Fixes aplicados (`5238eac`): `_reasignar` re-valida el estado en la tx · Reasignar
  oculto en estados terminales.

**3A — BACKLOG VACIADO antes de 3B** (sesión 2026-06-07 cont., auditado 2 agentes):
- ✅ **Coalescing de transiciones offline (era ALTA):** **FALSO POSITIVO, cerrado.**
  Verificado (docs PowerSync + WebSearch): la cola CRUD es **FIFO y NO coalescea**
  varias updates a la misma fila — cada `_cambiarEstado` es su propia tx → su propia op
  CRUD que sube en orden. El trigger de transición (0103) ve cada salto individual →
  no rechaza. Sin cambio de trigger.
- ✅ **SLA pausa EXACTA — HECHO** (migración **0105**): trigger acumula en
  `tickets.segundos_pausado` TODO el tiempo en `en_espera` usando el device-time
  `ocurrido_en` de cada transición (offline-safe, FIFO server-side); el SLA derivado
  en el cliente suma `segundos_pausado` al plazo. Ya NO es "pausa solo si está en
  espera AHORA". Columnas `segundos_pausado`+`en_espera_desde` en schema, **schema v22**.
- ✅ **Lista de tickets — filtro en SQL** (no en memoria): `WHERE estado IN (?)` +
  `LIMIT 300`, stream se recrea al cambiar el chip. (Antes cargaba todo + filtraba en
  memoria.)
- ✅ **Umbral "por vencer"** (fix audit E1): techo del 50% del SLA → un SLA corto (1-5h)
  ya no nace en "por vencer".
- ✅ Matriz de transiciones cliente↔server **verificada idéntica** (incl. terminal→reabrir).

**3A — DEFERRED A v2 (documentado, NO bloquea):**
- **`reabierto` nace vencido** (G1): al reabrir un ticket viejo, `deadline = created_at +
  sla + pausa` ya pasó → muestra "Vencido" al instante. Consistente ("SLA corre desde la
  creación") pero quizá no deseado. v2: anclar el SLA del reabierto a `resuelto_en` o
  un campo `sla_reabierto_desde`. Decisión de producto.
- **Over-count por clock-skew inter-device** (C2): si 2 devices con relojes
  desincronizados tocan el MISMO ticket, la pausa puede sobre-contarse (deadline menos
  urgente). Edge case sin fix limpio offline-first; MVP-tolerable.
- **Lista sin "cargar más"** (LIMIT 300): un tenant con >300 tickets activos ve solo los
  300 más recientes. Cursor/paginación cuando crezca.
- **Borrado de adjunto no-atómico** (fila DB + objeto Storage en awaits separados,
  posible huérfano; **mismo patrón aceptado que fotos_cliente** — no es regresión nueva).
- **Correlativo offline multi-device** (R-class, igual que recibos: UNIQUE rechaza el 2º).
- **admin_cobranza sin tickets**: intencional — `is_admin_or_tickets/is_ticket_staff`
  excluyen ese rol (RLS) + router gatea a `soloAdmin` + bucket sin tickets. Consistente.

**Wiring de roles `tecnico`/`admin_tickets` → 3B:** exponerlos en el picker de rol
(`tenant_dialogs_miembro.dart`), darles **shell propio** (técnico) + **landing** +
**bucket `por_tecnico`** + guard de router. Hoy NO se pueden asignar (a propósito,
para no crear un login roto).

> ⚠️ Deploy Fase 3 (al final del slice): correr `0103` + **`0104`** + **`0105`** por
> Dashboard (en orden — `0104`/`0105` dependen de `0103`) + redeploy sync rules
> (tablas + columnas nuevas) + restart (**schema v22**). El super_admin enciende
> 'tickets' del tenant en `/super/tenants/:id`.

## Estado actual

- **AUDIT INTEGRAL DE FASE 2 — HECHO** (7 expertos paralelos: inventario, red/geo,
  dinero, multi-tenant/RLS, sync, audit/change-log, cross-módulo/lifecycle).
  Cimientos LIMPIOS (dinero+invariantes, aislamiento inventario↔dinero, integridad
  DB↔schema↔sync, RLS/impersonación/gating). **Todos los findings accionables
  CORREGIDOS** (commits `aa669a9`→`df5fc56`, grupos A-F): A1 re-validación de
  estado · guarda es_serializado · try/catch de pickers · `_cambiarEstado` ·
  fuga cross-tenant geo/red (F1) · **equipo-en-baja** (al cancelar contrato/
  desactivar cliente ofrece devolver/retirar los equipos) · trazabilidad
  Agregador del equipo + equipos en contrato/cliente · MAC en ingreso · guard de
  router para cobrador · **migración 0102** (guardas de borrado server-side +
  ledger append-only estricto). Decisiones: puerto **soft** en equipo+ticket
  (endurecer cuando la red esté viva); equipo dañado se mantiene como está.
- **AUDIT FINAL de verificación — HECHO** (3 agentes: correctness de los fixes ·
  migración 0102/DB · QA-regresión). Resultado: fixes correctos, sin regresiones.
  Ajustes aplicados: 0102 idempotente (`a039418`) · completar el filtro tenant en
  geo_picker/red_picker (`6d9e77f`, era el gap del fix C) · motivo cosmético.
  El "leak de inventario" que marcó un agente es **falso positivo**: `inv_*` NO
  está en `catalogo_tenant` (solo en buckets admin/impersonado parametrizados),
  igual que clientes/contratos → no se filtra a propósito (verificado en
  sync-rules). **→ Fase 2 cerrada y limpia, listo para arrancar Fase 3.**
- **Branch ÚNICA de trabajo:** `claude/new-features-inventory-tickets-and-technicians`
  (tip en `origin`). Contiene TODO: 2C-2/2D + el vaciado de backlog pre-Fase 3. Es la
  branch viva — desarrollar acá. Las viejas (`nifty-cori-KF2PZ`,
  `inventory-tickets-technician-role`) se borraron LOCALMENTE.
  ⚠️ **Borrado de ramas REMOTAS bloqueado por el entorno** (el proxy git devuelve 403 en
  `push --delete`; los MCP de GitHub no exponen delete). **Pendiente: Rubén limpia desde
  GitHub UI** — 40 ramas mergeadas (safe) + 29 con commits únicos (revisar). Lista y
  comando `git push origin --delete ...` en el chat de cierre de esta sesión.
- **Schema PowerSync:** `_schemaVersion = 22` (`lib/powersync/db.dart`). Inventario reusa
  0099-0101 (sin bump). Tickets sumó 0103 (v21, 4 tablas) + 0105 (v22, columnas de pausa SLA).
- **Plataformas target:** Android + Windows (web degrada sin romper, NO es target).
- **App version:** v0.9.0 (ver `RELEASE.md`).

## Objetivo de este branch

**Plan completo y alcance APROBADO en `PLAN-INVENTARIO-TICKETS-RED.md`** (leer ahí el detalle).
Resumen: 4 features aditivos, por fases (cada una su PR + audit + testing):
1. **Fase 1 (próxima):** Geografía global→per-tenant (con backfill + reconexión de
   `clientes.comunidad_id`) + Topología de red per-tenant (Nodo→Hub→Puerto, `clientes.puerto_id`).
2. **Fase 2:** Inventario (ledger de movimientos, módulo opcional ya seedeado).
3. **Fase 3:** Tickets + roles `tecnico`/`admin_tickets` + `incidentes` (outages).

Decisiones cerradas: 1 rol por usuario; red opcional en cliente pero requerida para
ticket/asignar equipos; SLA por tipo; notificaciones in-app; etc. (detalle en el PLAN).

> ⚠️ Tocan DB/roles/RLS → checklist de integridad de CLAUDE.md. Fase 2 ya cumplida
> (propuesta aprobada); **falta aprobar el detalle de la Fase 1 antes de implementar**.
> ⚠️ Geografía toca DATA VIVA (FK de clientes) → migración con backfill + testing con data real.

## Sesión anterior (2026-06-06 cont.) — qué se hizo

Lote UX/reportes, **sin migraciones**, auditado (3 agentes, 0 bloqueantes):
1. **Reportes con detalle USD** (cobros/por cobrador/fiscal): columnas Moneda /
   Entregado (orig.) / Tasa / Vuelto. Recaudado sigue = `monto_cordobas`. PDFs en landscape.
2. **Impresora del sistema en PC** (recibo, solo desktop): `Printing.layoutPdf`.
3. **Búsqueda multi-campo en el mapa**: nombre/cédula/teléfono/código cliente/código contrato.
4. **Transición entre vistas** — varias iteraciones hasta que cerró:
   (a) `AnimatedSwitcher`/`_ShellFade` envolviendo el body → fallaba (el Navigator
   interno del ShellRoute cruzaba 2 pantallas encimadas);
   (b) fade secuencial por ruta con `Interval` → Rubén lo vio brusco/parpadeo;
   (c) FadeThrough (zoom+fade) → seguía viéndose overlap (un fade ES un cruce de
   opacidades, siempre muestra las 2 un instante);
   (d) **FINAL (`c2a8edf`): `_CoverSlide`** — deslizamiento con COBERTURA OPACA
   (la entrante entra desde la derecha tapando a la saliente; z-order + fondo
   opaco → nunca se ven las dos). Por ruta en `router.dart`, 320ms.
   **Lección:** en `ShellRoute` la transición va a NIVEL DE PÁGINA (pageBuilder);
   y NINGÚN fade cumple "que no se vean encimadas" → para eso hay que tapar (slide opaco).
   ⏳ Falta OK de Rubén de este modo.
5. **Dashboard** sin card "Acciones rápidas".

Detalle completo → `REPORTE-SESION.md` (entrada 2026-06-06 cont.).

## Fase 2 — Inventario (EN CURSO, por slices auditados)

Módulo OPCIONAL: gateado por `tenant_modulos` ('inventario', es_base=false → OFF
por defecto; el super_admin lo habilita en `/super/tenants/:id`). Decisiones:
stock se DERIVA del ledger (`inv_movimientos`, slice 2C) — **sin** tabla inv_stock
ni trigger de proyección. Fase 2 es admin-facing; custodia por técnico = Fase 3.

- ✅ **2A (gating + catálogo)** commit `cf32f3d`, **en auditoría**: migración 0099
  (inv_categorias/proveedores/productos + RLS + audit + `id` en tenant_modulos para
  sync); `tenant_modulos` synced + `modulosHabilitadosProvider` + `_MenuItem.moduloKey`
  (no lo bypassa el super_admin); `InventarioScreen` = catálogo Productos (CRUD +
  categoría inline + serializado/granel + historial). schema **v18**.
- ✅ **2B (ubicaciones + proveedores)** commit `d690c13`, **en auditoría**: migración
  0100 (inv_ubicaciones); InventarioScreen en pestañas (Productos|Ubicaciones|
  Proveedores), CRUD+historial en cada una. schema **v19**.
- ✅ **2C-1 (ledger + ingreso + existencias)** commits `5e55f47`+fix, **auditado**:
  migración 0101 (inv_seriales + inv_movimientos append-only); pestaña Existencias
  (stock derivado = Σdestino−Σorigen); Ingreso (serializado/granel, **atómico vía
  writeTransaction**). schema **v20**. `costo_promedio` NO se auto-recalcula aún.
- ✅ **2C-2 (ciclo de movimientos) — HECHO + AUDITADO** (sesión 2026-06-07, branch
  `nifty-cori-KF2PZ`). **NO** requirió migración ni bump (0099-0101 ya cubrían todo).
  - **Asignar** (`580f111`): stock de SERIALIZADOS pasa a derivarse del **estado del
    serial** (`COUNT(estado='en_stock')`), no del ledger → cierra las 2 divergencias del
    audit (doble-asignación / ubicación NULL ya no inflan/desinflan). Guard
    `estado='en_stock'` re-validado DENTRO del writeTransaction. Captura `contrato_id`
    (auto si 1, `_ContratoPicker` si varios). Aviso suave si el cliente no tiene
    `puerto_id` (no bloquea — se endurece cuando la red esté en prod). Búsqueda de
    cliente multi-campo (nombre/código/cédula/teléfono).
  - **Ciclo del serial** (`c66eea4`): Devolver a stock / Transferir de ubicación / Dar de
    baja (dañado/retirado/baja, con motivo). Cada una atómica + re-valida estado.
  - **Granel** (`e554446`): Egreso / Ajuste± (motivo obligatorio) / Transferencia vía 2º
    FAB en Existencias. Stock de granel sigue = `Σdestino − Σorigen`.
  - **Guardas de borrado** (`b33c5be`): producto/ubicación no se borran si están en uso.
  - **Fixes del audit** (`d380c82`): guarda de borrado de proveedor; feedback del stock
    resultante (avisa si negativo) en movimiento de granel; estado vacío del diálogo de
    granel; "Cambiar estado" vs "Dar de baja" según el estado del equipo.
- ✅ **2D (equipos instalados en la ficha del cliente) — HECHO** (`df266ab`):
  `cliente_detail_screen.dart` sección "Equipos instalados" (serial/producto/MAC),
  gateada por módulo inventario + rol admin/admin_cobranza (las inv_ no sincronizan al cobrador).
- ✅ **Backlog 2C/2D — VACIADO antes de Fase 3** (sesión 2026-06-07 cont., auditado 3 agentes, 0 Alta/Media salvo el fix abajo):
  - **stock por UBICACIÓN** (M2): tap en un producto → desglose por ubicación;
    el origen de egreso/transferencia se restringe a ubicaciones con stock y avisa
    si la cantidad supera lo disponible (`bcc78c8`, `bbdb4d3`, `c89954e`).
  - **`costo_promedio` ponderado**: el ingreso recalcula el promedio móvil; Existencias
    muestra costo/valor (`bcc78c8`).
  - **value-labels** de tipos de movimiento / estados de serial en el change-log (`44d70e6`).
  - **TOCTOU** de guardas de borrado: re-chequeo dentro del `writeTransaction` (`527ac9e`).
  - **connector.dart**: log del CRUD rechazado con tipo de op + divergencia (`527ac9e`).
  - **Decisiones cerradas (no son código):** equipo dañado-en-casa-del-cliente → se
    mantiene como está (sale de la ficha, el historial lo preserva — decisión de Rubén).
    **R2** (unicidad de serial multi-admin offline) → ACEPTADO: el `UNIQUE` server +
    el surfaceo del connector son suficientes (single-admin en prod). **R1** (FK del
    puerto de red) → se pliega a la Fase 3 (que reworkea la red para tickets).

> ⚠️ Deploy Fase 2 (al final, todo junto): correr `0099` + `0100` + `0101` +
> **`0102`** por Dashboard, redeploy sync rules, restart (**schema v20**). 2C-2/2D
> NO agregaron migraciones; **0102 es server-side puro** (triggers de guarda de
> borrado + ledger append-only estricto), NO toca schema/sync → no necesita bump
> ni redeploy de sync rules, solo correr el SQL. Para ver Inventario el
> super_admin habilita 'inventario' del tenant en `/super/tenants/:id`.

## Fase 1.1 — Fixes + features de red post-testing de Rubén (HECHO)

Rubén testeó (super_admin impersonando) y reportó bugs/pedidos. Estado:
- ✅ **Puerto no persistía** (`a93ab98`): el `RedPicker` dejaba `_puertosStream` vacío
  al elegir Hub (faltó espejar `_watchPuertos(id)`). Era MI bug, confirmado por
  rastreo de data-flow (no era impersonación). Afectaba a todos los roles.
- ✅ **Banner impersonación duplicado** (`3ac3597`): el inline en detalle cliente/
  contrato se sumaba al del AdminShell → gateado por `!enAdminShell`.
- ✅ **Map-picker + notas del nodo** (`c2ea65d`): `MapaPickerScreen` extraído a
  shared; `_NodoDialog` con notas + "Elegir en el mapa"; soporta edición.
- ✅ **Red editable + historial** (`9115a7f`): menú Editar/Historial por nodo/hub/
  puerto (UPDATE + `HistorialCambiosWidget`).
- ✅ **Geografía: historial** (`cb76bab`): 🕐 por depto/municipio/comunidad.

**HECHO (en auditoría):**
- ✅ **Filtro por Nodo** en lista de clientes (`c211a38`: `_NodoChip` + subquery
  `c.puerto_id IN (red_puertos del nodo via hub)`) y en **mapa** (LEFT JOINs
  puerto→hub→nodo + dropdown "Nodo" + `pasaNodo`).
- ✅ **Editar + Eliminar** geo y **Eliminar** red (`c03dd8b`): menú por fila
  Editar/Historial/Eliminar. Eliminar = **borrado duro con guarda de "en uso"**
  (no borra si tiene hijas/clientes; puerto se chequea a mano porque su FK es
  ON DELETE SET NULL). Geo editar reusa `_promptNombre(inicial:)`. Decidí NO
  soft-delete: el guard evita el caso "valor asignado que desaparece" sin migración.
- Corriendo auditoría del lote (foco: lógica de las guardas + binding de params).

**PENDIENTE (opcional / próximo):**
- (Opcional) mostrar nodo en `/admin/mapa` como capa, badge libre/ocupado del puerto.
- Fases 2/3 (Inventario / Tickets) — ver PLAN.

**⚠️ Backlog — estado tras el vaciado pre-Fase 3 (2026-06-07 cont.):**
- ✅ `connector.dart` errores no-retryables: ENDURECIDO (`527ac9e`) — el log ahora
  lleva tipo de op + código + marca de divergencia local-server para diagnóstico.
- ⏭️ **R1 — borrar puerto bajo multi-admin offline** (FK `ON DELETE SET NULL`): se
  **pliega a la Fase 3** (que reworkea la red para tickets; ahí se evalúa pasar la FK
  a `RESTRICT` o mover el borrado a RPC). No es single-admin issue. NO standalone backlog.
- ✅ **R2 — unicidad de serial multi-admin offline**: ACEPTADO como está. El `UNIQUE`
  (tenant,serial) del server + el surfaceo del connector (ya no silencioso) son
  suficientes para single-admin (la realidad de prod). Cerrado por decisión.
- ✅ **costo_promedio**: RESUELTO (`bcc78c8`) — el ingreso recalcula el promedio
  ponderado móvil del producto; Existencias muestra costo/valor.

## Fase 1 — CÓDIGO COMPLETO, falta DEPLOY + TESTING de Rubén

Geografía per-tenant + topología de red (Nodo→Hub→Puerto). Auditada por 4 agentes
(Code+DB, QA UI, QA UX, especialista red); findings aplicados, incluido 1 BLOQUEANTE
de seguridad (policies geo viejas no dropeadas → fuga cross-tenant, ya corregido).
Commits clave: `6f80653` (datos), `32f9bb0` (UI), `26f9705` (fixes audit),
`ffb373c` (campos red: tipo/lat/lng/notas). Schema **v17**.

**Pendiente: Rubén deploya y testea** (pasos detallados que le pasé en el chat):
1. SQL Editor (Dashboard): correr `0097_geografia_per_tenant.sql` y después
   `0098_red_topologia.sql`. ⚠️ 0097 **vacía la geografía** de prueba y nulea
   `clientes.comunidad_id` (data de prueba, OK).
2. PowerSync: **redeploy sync rules** (geo dejó de ser global; +red).
3. App: **restart desde cero** (bump schema v16→17 → DB local nueva).
4. Probar: Admin › Red (crear Nodo→Hub→Puerto), asignar puerto en form de cliente,
   ver "Red"/"Comunidad" en el detalle del cliente, recargar geografía por tenant.

**Recordatorio Fases 2/3 (Inventario/Tickets):** módulos solo activables por
**super_admin**, **deshabilitados por defecto** en el tenant (`tenant_modulos`). Red NO
(es base de cobranza). Notas del especialista para incidentes: tabla `incidentes` con
3 FK nullables nodo/hub/puerto + CHECK; backhaul nodo→nodo cuando un ISP lo pida.

## Otros pendientes
- 📄 `ARQUITECTURA.md` — revisar exactitud (3 puntos marcados) cuando haya tiempo.
- Backlog persistente: ver fin de `CLAUDE.md` (no re-flaggear ítems ya resueltos).

## Docs del proyecto (qué leer y para qué)

| Doc | Para qué |
|---|---|
| `HANDOFF.md` (este) | Dónde quedamos AHORA. Leer primero. |
| `CLAUDE.md` | Reglas, proceso/lifecycle, invariantes de dinero, backlog. |
| `ARQUITECTURA.md` | Módulos y cómo se interconectan (flujo de datos). |
| `ESTADO-APP.md` | Snapshot detallado de estado/cobertura/findings. |
| `REPORTE-SESION.md` | Comportamiento esperado por feature + historial de fixes. |
| `TESTING.md` | Cómo se testea (setup + loop manual por feature). |
| `STACK.md` / `ROADMAP.md` | Stack técnico / plan a futuro. |
