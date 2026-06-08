# HANDOFF — dónde vamos quedando

> **Claude: leé ESTO PRIMERO al abrir la sesión.** Es el estado vivo del
> proyecto, en una pantalla. Mantenelo CORTO (≤1 pantalla). El detalle vive en
> los otros docs (links abajo). **Actualizá este archivo al CERRAR cada sesión**
> (es parte del lifecycle de CLAUDE.md, Fase 6).

---

## 2026-06-08 — AUDIT INTEGRAL multi-agente + fixes ✅ código, falta DEPLOY

Audit exhaustivo de TODA la app (11 agentes Opus) → `AUDIT-INTEGRAL-2026-06-08.md`.
Veredicto: app sólida (10/10 invariantes de dinero, RLS completa, SQLite/TZ/rutas OK).
Hallazgos: 1 ALTA + 9 MEDIA + ~25 BAJA. **Casi todo fixeado** (16 commits, `5e0013b`→`a7a2b99`),
2 agentes de review confirmaron los cambios de dinero/impersonación limpios.

**Fixeado:** A1 (saldo cobrador con cargos_neto) · M1/M2 (anular cuota parcial espeja cascada
+ copy) · M3/M4/B2 (guard de impersonación unificado: pagos/cuotas/settings/estado) · M5/M6
(edición de contrato eliminada — form create-only) · M7 (test INV11 falso positivo) · M8/B6
(tab Categorías de inventario con CRUD+historial) · M9 (historial de cambios del ticket) · B1
(cargos_extra en historial de cuota) · B3 (guard ruta pagos/notif) · B5 (chips de auditoría) ·
B7 (doc sync admin_cobranza) · B8 (mapa técnico) · B9 (snackbar PDF) · B10 (timestamps UTC) ·
B11 (badges hora Nicaragua) · B12 (humanizarEdgeError DRY) · dead code · doc-drift (schema v26).

**Backlog REAL que queda** (esfuerzo grande / server-deploy / edge — ver §6 del AUDIT y
ESTADO-APP): suite de tests · config de distribución (applicationId/deep-links) · filtro de
fechas + cron de retención en /super/logs (RPC) · lock de reenviar-invitación (edge fn) ·
edge cases teóricos (cross-tab, autoDispose, lastSyncedAt, PKCE user-switch) · _currentRoute
GoRouter · FotoComprobante F5 · OfflineBanner primeros-3s.

> ⚠️ **Deploy pendiente:** correr `0111` + `0112` (Dashboard) → rebuild de la app (mucho código
> Dart nuevo) → `invariantes_dinero.sql` (ya SIN falso positivo por M7). **Tab Categorías** es
> UI nueva (sin migración). **B7/sync-rules** NO requiere redeploy (solo comentario). Después:
> **testing completo** (TESTING.md §0.3 + el del audit). Correr `dart format` (algunas
> indentaciones de collection-if quedaron sin normalizar).

---

## 2026-06-08 — Cancelar contrato = saldo a 0 (+ RLS + B2/A3) ✅ código, falta DEPLOY

Bug HIGH: cancelar un contrato **no** dejaba de cobrar sus cuotas (cobrador las veía, mora
las contaba, saldo mal). Arreglado + auditado (3 agentes, 2 ALTA corregidas). Commits
`c9e5667` → `d6b94b0` → `a2aa04a`.

- **Cancelar** (`contrato_detail_screen.dart`): anula pendientes (sin pago) + liquida las
  parciales con un **descuento de cancelación** (`cargos_extra` 'descuento_monto') que las deja
  `pagada` — **preserva la plata real cobrada** (decisión "Opción A"). Espejo LOCAL de
  cargos_neto/estado (saldo 0 al instante, también offline).
- **Resumen** del contrato cancelado → "Total recaudado" / Pendiente 0.
- **B2 (terminal):** cancelado NO se reactiva (dropdown desaparece). **A3:** no se cancela
  impersonando (opción oculta + guard). **Gap cerrado:** el switch activo/cancelado del *form*
  de edición (cancelaba sin liquidar + reactivaba) se quitó — el estado se gestiona SOLO desde
  el dropdown del detalle.
- **2 migraciones server-side puras** (sin bump de schema, sin redeploy de sync rules):
  `0111_cuotas_cobrador_no_desanular` (RLS: el cobrador no des-anula cuotas — el ítem que pidió
  Rubén) + `0112_mora_resolver_al_anular` (resuelve la mora también al anular).

> ⚠️ **Deploy pendiente (Rubén):** correr `0111` y `0112` por Dashboard (en orden) → rebuild de
> la app (código Dart) → correr `supabase/tests/invariantes_dinero.sql` (toca dinero, debe dar
> 0 violaciones). **NO** hay bump de schema ni redeploy de sync rules. Detalle + pasos de
> testing en `REPORTE-SESION.md` (entrada 2026-06-08).

---

## Fase 3 — Tickets (3A+3B+3C+3D+3E COMPLETOS y auditados ✅)

Propuesta aprobada en `FASE3-PLAN.md` (decisiones: D1 trigger server-side de
descuento de stock · D2 trigger de transición de estado · D3 shell propio del
técnico · D4 correlativo `T-00001` · D5 3A completo).

> **Fase 3 COMPLETA (3A→3E) y auditada, SIN backlog bloqueante.** El loop completo
> funciona: admin crea/asigna → técnico resuelve offline + **consume materiales de su
> custodia (descuenta inventario)** → sincroniza → admin cierra; los cortes se agrupan
> como **incidentes** con clientes afectados derivados de la red. **3E reframeó
> "notificaciones" → cuenta regresiva de SLA OFFLINE por ticket + badge en riesgo
> (lean, sin tabla)**, con SLA híbrido por prioridad. Ver bloque 3E abajo.

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

**3B — TÉCNICO HECHO + AUDITADO** (commit `9ca9fdc`, 3 agentes: sync-rules ·
router/roles/regresión · Dart/regresión — **0 ALTA/MEDIA**, SIN migración nueva):
- **Sync rules** (sólo redeploy, NO bump): `por_tecnico` (ticket_tipos + cobradores
  del tenant, gateado a rol='tecnico') · `por_tecnico_tickets` (dinámico por ticket
  asignado: ticket + bitácora + adjuntos) · `por_tecnico_clientes` (dinámico:
  **sólo `clientes`** de sus tickets, CERO dinero). Geo/red/settings los hereda de
  `catalogo_tenant`. Verificado: DSL-compliant + money-safe + scopeado por `asignado_a`.
- **Rol `tecnico` asignable** desde el picker del super_admin (`tenant_dialogs_miembro`).
- **Shell móvil-first** `TecnicoShell` (bottom-nav Mis tickets/Mapa/Perfil) +
  `MisTicketsScreen` (filtro activos/cerrados en SQL) + reuse de `MapaScreen`
  (vista de campo) y `PerfilScreen(tecnicoMode)`.
- **Resolución**: `TicketDetailScreen(tecnicoMode)` push en `/tecnico/tickets/:id`
  (Scaffold propio); transiciones acotadas a avanzar/pausar/resolver
  (`kEstadosDestinoTecnico`), sin reasignar. RLS `is_ticket_staff` cubre el write.
- **Router**: landing + guard de contención (el técnico vive en `/tecnico/*`, no
  llega a /admin, /super, dinero; whitelist sólo `/perfil/impresora`).
- **`admin_tickets` DIFERIDO** (decisión de Rubén): NO expuesto en el picker, sin
  shell/bucket → no hay login roto. Su shell acotado en AdminShell es un slice propio.
- **Accepted (no bugs, no re-flag):** título por-tab del AppBar cae al nombre del ISP
  (idéntico al `AppShell` shippeado) · `por_tecnico` baja todos los campos de cobradores
  del tenant (consistente con el bucket admin; la own-row los necesita) · `por_tecnico_tickets`
  crece 1 bucket por ticket de por vida (MVP-ok) · whitelist exact-match (sin sub-rutas hoy).

**3C — MATERIALES (engancha INVENTARIO) HECHO + AUDITADO** (commits `56c2a49`,
`3393461`, `65fc29d`, `f349f1f`; 4 agentes: trigger/inventario/dinero · cross-módulo ·
sync/RLS · Dart/UI — dinero **hermético**, **1 ALTA fixed**, resto BAJA):
- **Migración 0106**: tabla `ticket_materiales` (append-only, RLS insert=`is_ticket_staff`
  → el técnico registra) + FK `inv_movimientos.ticket_id` + trigger **SECURITY DEFINER**
  `ticket_materiales_consumo`: inserta `inv_movimientos 'consumo'` (descuenta del origen)
  y marca el serial `'instalado'` en el cliente del ticket. Offline-safe ("server gana"),
  no bloquea por stock (tolerancia negativa). **schema v22→v23**.
- **UI**: `TicketMaterialesWidget` en el detalle (gateado por módulo inventario): lista
  lo consumido + "Agregar" (custodia del técnico auto, o cualquier ubicación para admin;
  serial de stock o granel + cantidad). Inserta `ticket_materiales` + evento `'material'`.
- **Sync**: `ticket_materiales` en admin/impersonado + `por_tecnico_tickets`; catálogo inv
  en `por_tecnico`; **nuevo bucket `por_tecnico_inventario`** (custodia `tipo='tecnico'`:
  su ubicación + seriales + ledger de esa ubicación — SÓLO lo suyo).
- **Trazabilidad** (decisión de Rubén: vía `ticket_materiales`): la fila auditada
  surfacea el consumo en la bitácora del ticket + en el cuna-a-tumba del serial
  (`HistorialSerialWidget` la une). El `inv_movimientos`/serial derivados NO se auditan
  (proyección, depth 2 los saltea).
- **Cross-módulo verificado**: consumo → serial instalado en cliente → "Equipos
  instalados" (2D) + `equipos_en_baja` (FIX `f349f1f`: la cancelación de contrato ahora
  también barre los equipos del cliente SIN contrato — los instalados vía ticket).
- **Fix ALTA (`65fc29d`)**: el trigger SECURITY DEFINER valida que producto/ubicación/
  serial pertenezcan a `NEW.tenant_id` (aislamiento multi-tenant; SECURITY DEFINER saltea RLS).
- **Accepted/v2 (no re-flag):** granel offline puede doble-descontar (tolerancia negativa,
  por diseño) · el consumo-install NO aparece en el change-log del **cliente** (es nieto
  vía ticket → regla de profundidad; sí en el del serial + ticket) · snack "se descuenta
  al sincronizar". (El "serial en ticket sin cliente" SE CERRÓ en 3D: se bloquea el
  consumo serializado si el ticket no tiene cliente.)

**3D — INCIDENTES (outages) HECHO + AUDITADO** (commits `5d43dd9`, `ab8f5b0`, `5d8a218`;
3 agentes: DB/RLS/sync · cross-módulo/lifecycle · Dart/UI — **0 ALTA**, 1 MEDIA fixed):
- **Migración 0107**: tabla `incidentes` (alcance nodo|hub|puerto|general con CHECK de
  un-solo-nivel, estado abierto/resuelto, inicio/fin) + FK diferida `tickets.incidente_id`
  → incidentes (ON DELETE SET NULL). RLS write=`is_admin_or_tickets` (el técnico NO crea).
  **Migración 0108**: `alcance_label` (snapshot del alcance, fix MEDIA del audit).
  schema **v23→v25**.
- **UI** (admin-only, módulo tickets): `/admin/incidentes` lista + crear (alcance en
  cascada nodo→hub→puerto) + detalle con **clientes afectados DERIVADOS de la red**
  (puerto→hub→nodo) + tickets agrupados + resolver + historial. ticket_form: picker de
  incidente. ticket_detail: muestra el incidente + acción **"Vincular a incidente"**
  (admin, para tickets ya creados — el flujo real es tickets-primero).
- **Cross-módulo verificado**: incidentes↔red (FK SET NULL + delete-guard) · incidentes↔
  clientes (derivación correcta por nivel, money-clean) · incidentes↔tickets (grouping,
  picker sólo outages abiertos) · **técnico aislado** (no sincroniza incidentes, degrada
  sin crash) · dinero **hermético**.
- **Fixes del audit (`5d8a218`)**: snapshot `alcance_label` (MEDIA) · vincular ticket
  existente (alto valor real) · filtro tenant_id en corte general (defensa).
- **Accepted (no re-flag):** índice por scope (perf, ISP chico) · `_evento` duplicado en
  ticket_form/detail (preexistente, candidato a helper) · lista de afectados cap 50.

**3E — CUENTA REGRESIVA DE SLA (offline) HECHO + AUDITADO** (commits `a523157`,
`c1a9869`; 3 agentes: code+DB integrity · QA · UX — **0 bloqueantes**, **SIN
migración / sin bump / sin redeploy de sync rules**):
- **Reframe (Rubén + experto en ticket-mgmt):** "notificaciones" → **cuenta regresiva
  viva del SLA por ticket** ("2h 15m" verde → ámbar → "vencido hace 30m" rojo).
  Matemática pura sobre data local (reloj del device + la fila) → **TICKEA OFFLINE**.
  Notificaciones = **lean** (badge derivado, sin tabla/triggers/cron).
- **SLA híbrido por prioridad** (`slaHorasEfectivas` = min(tipo, prioridad), nulls
  ignorados): setting `tickets.sla_horas_por_prioridad` (default urgente1/alta2/media6/
  baja12, editable en el editor de Tipos). Plazo = created_at + sla_efectivo + segundos_pausado.
- **`TicketSlaCountdown`** (widget shared, `Timer.periodic` self-tick: 1min listas / 1s
  detalle; `compact` en listas) en mis_tickets + tickets_list + detalle (+ fila "Vence").
  en_espera → "SLA pausado" (no tickea); sin SLA/cerrado → nada.
- **Badge "en riesgo"** (`ticketsEnRiesgoCountProvider`) en la tab "Mis tickets" del
  técnico = count(porVencer+vencido); recomputa por sync Y cada 60s (el tiempo solo cruza
  a "por vencer"). Offline-correcto.
- **Fix de BUILD-BREAK PRE-EXISTENTE** (introducido en `ab8f5b0`/3D): `ticket_detail_screen`
  usaba `_chip`/`_row` SIN definirlos → **la app no compilaba**. Restaurados. Barrido
  tickets/tecnico/incidentes: no hay otros del mismo tipo.
- **Fixes del audit (`c1a9869`):** semáforo invertido (enPlazo era AZUL de marca, pausado
  VERDE → ahora verde/ámbar/rojo + gris pausado; `slaColor` solo alimenta el countdown) ·
  rollover a días ("2d 3h") · labels compactos en listas · editor digits-only + nota.
- **Accepted/by-design (no re-flag):** el default-map aplica a tickets YA creados (un ticket
  viejo abierto puede nacer "vencido" — correcto, ES el punto del SLA; hay nota en el editor) ·
  `created_at` device-local-naive (pre-existente, consistente con `fecha_pago`, offline-correcto) ·
  `appSettingsProvider` re-dispara el provider del badge en cualquier cambio de settings (sin
  leak, solo trabajo redundante; memoizar el map en v2).

**CIERRE FASE 3 — AUDIT INTEGRAL HECHO** (commit `3cbd148`; 4 agentes paralelos:
DB/schema/sync/RLS · Dart cross-módulo · dinero+audit-log · aislamiento+offline).
**Veredicto: Fase 3 sólida, 0 ALTA.** Dinero **hermético**, sin fuga cross-tenant /
role-bypass / offline-breaker, cadena DB↔schema↔sync íntegra, audit-log completo con
profundidad bien cableada, state machine CHECK↔trigger↔Dart consistente.
- **Fix MEDIA aplicado + re-auditado SAFE** (trigger consumo **0106**): consumir un
  serial ahora exige que esté EN la ubicación de origen declarada (`ubicacion_id IS NOT
  DISTINCT FROM ubicacion_origen_id`) + el `inv_movimientos` se inserta SOLO si se
  consumió (reorden + early-return). Cierra el hueco de custodia intra-tenant (insert
  crafteado) y el doble-descuento en dup offline del mismo serial. Granel sin cambios.
  **⚠️ 0106 cambió → re-deployar (es `CREATE OR REPLACE`, idempotente).**
- **Cleanups**: borrada `kTicketEstados` (constante muerta) · value-label de
  `tickets.prioridad` en el change-log.
- **Backlog (LOW/by-design, no bloquea):** surface de history del audit_log de tickets
  (la bitácora cubre estado/asignación/comentarios/materiales) · huérfano de Storage al
  borrar adjunto offline (= comprobantes) · enforcement de custodia full para granel ·
  guard serial-sin-cliente en el trigger (la UI ya lo guarda) · comentarios de versión de
  schema en headers de migración desfasados (cosmético; `db.dart`=v25 es la verdad).

**SLA ACCIONABLE (v2 post-Fase 3) — HECHO + auditado SAFE** (commits `d785912`,
`8b9a099`). Approach deliberadamente SIMPLE (lección de Nodos: cero entidades/columnas/
vínculos nuevos). Dos piezas:
- **Slice 1 — badge "en riesgo" del admin** (derivado, cero migración): el item "Tickets"
  del menú admin (rail + drawer) muestra la cuenta de vencidos + por vencer del tenant.
  Reusa `ticketsEnRiesgoCountProvider` de 3E (en el admin cuenta los del tenant, en el
  técnico los suyos — mismo provider, scopeado por bucket).
- **Slice 2 — auto-cierre** (migración **0109**): cron diario (`tickets_auto_cierre`,
  SECURITY DEFINER per-tenant, patrón del cron de mora) cierra los `resuelto` con > N días
  sin reapertura, con evento de bitácora (autor "Sistema"). N = setting
  `tickets.auto_cierre_dias` (**0 = OFF, default**; editable en la pantalla de Tipos).
  Reversible (`cerrado→reabierto`). **Sin tabla/columna nueva → sin bump de schema ni
  redeploy de sync rules** (usa estado/resuelto_en/cerrado_en que ya sincronizan). Audit
  SAFE (CTE correcto, triggers conviven con el actor NULL del cron, idempotencia mejor que
  los crons previos).
- **NO incluye** (a propósito): SLA math en SQL (la escalación es derivada en cliente),
  push/WhatsApp, auto-subir prioridad, columna `escalado_en`.

**CALIDAD DE CAMPO + INVENTARIO v2 — HECHO + auditado (3 agentes, 0 ALTA/MEDIA)**
(commits `df1cd3b`→`6a8e824`). Approach SIMPLE (lección de Nodos: cero entidades/
jerarquías/vínculos nuevos; solo 3 columnas en tablas existentes + 1 paquete).
- **Migración 0110** (3 columnas): `ticket_tipos.checklist_template` (JSONB),
  `tickets.checklist` (JSONB), `inv_productos.stock_minimo` (numeric). **schema v26.**
- **Slice A — Checklists por tipo:** el admin define pasos por tipo (template); al crear el
  ticket se snapshotea en `tickets.checklist` (`[{texto,hecho}]` — editar el template NO toca
  tickets viejos); el técnico/admin tilda en el detalle (progreso X/Y). El tick NO spamea el
  change-log (fuera del allowlist).
- **Slice B — Firma del cliente:** `SignaturePad` propio (sin dependencias, RepaintBoundary →
  PNG); se sube como `ticket_adjunto` "Firma del cliente" (reusa bucket/sync/RLS/audit de
  adjuntos, cero schema). Requiere conexión para subir (igual que las fotos).
- **Slice C — Stock mínimo:** `inv_productos.stock_minimo` (campo en el form); la tab de
  Existencias resalta los bajo-mínimo + **badge** en el item "Inventario" del menú
  (`inventarioStockBajoCountProvider`, derivado del ledger, offline).
- **Slice D — Código de barras:** `mobile_scanner` (la única dep nueva) — botón "Escanear" en
  el ingreso de seriales que agrega el código leído como una línea. Gateado a **Android**
  (Windows/web ocultan el botón → tipeo manual; iOS sacado: no es target + le falta el plist).
- **Audit (3 agentes, 0 ALTA/MEDIA):** pad de firma/upload/scan limpios; integridad y
  snapshot sin drift verificados. Fixes (`6a8e824`): scan solo Android + `stock_minimo`
  trazable en el change-log.
- ⚠️ **Rubén ANTES de confiar en el build:** correr **`flutter pub get`** (el lockfile no
  tiene `mobile_scanner` aún) y **`flutter build windows --release`** — esperado: build OK
  con `mobile_scanner` no-registrado en Windows (como `image_picker`). Si falla → import
  condicional. En Android, la 1ª vez que se escanea aparece el permiso de cámara.

> ⚠️ **Deploy (al final, todo junto)**: migraciones `0103`→`0104`→`0105`→`0106`(actualizado)→`0107`→
> `0108`→`0109`(auto-cierre)→`0110`(checklists/stock) por Dashboard **en orden** + **redeploy
> sync rules** (`SELECT *` ya cubre las columnas nuevas; buckets **`por_tecnico*`** incl.
> `por_tecnico_inventario` + `ticket_materiales` + `incidentes`) + **`flutter pub get`**
> (mobile_scanner) + restart (**schema v26**). Verificar "Active" en PowerSync. El super_admin
> enciende 'tickets' (y 'inventario' para materiales) del tenant en `/super/tenants/:id`, crea
> una ubicación `tipo='tecnico'` con `cobrador_id` del técnico, y la topología de red (nodos/
> hubs/puertos) para poder scopear incidentes.

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
- **Schema PowerSync:** `_schemaVersion = 25` (`lib/powersync/db.dart`). Inventario reusa
  0099-0101 (sin bump). Tickets sumó 0103 (v21, 4 tablas) + 0105 (v22, pausa SLA) + 0106
  (v23, `ticket_materiales`) + 0107 (v24, `incidentes`) + 0108 (v25, `alcance_label`).
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
