# AUDIT INTEGRAL — Cobranza ISP (2026-06-08)

Auditoría exhaustiva multi-agente (11 agentes especialistas Opus, read-only, máxima
profundidad) de TODA la app antes de deployar las migraciones 0111/0112. Objetivo:
verificar que cada módulo/toggle/campo activo esté lógicamente bien codeado y resuelto
en UI/UX siguiendo la visión del lifecycle, y dejar el backlog en su estado real.

- **177 archivos Dart (~36k líneas)** · 112 migraciones · 7 Edge Functions · `_schemaVersion=26`.
- Cobertura: 8 agentes por módulo + 3 cross-cutting (dinero/change-log, DB/RLS/sync, backlog/dead-code).

## Veredicto global

**La app está sólida.** Los invariantes de dinero (#1–#10) se cumplen en el código real,
la RLS multi-tenant es completa, el SQL es 100% SQLite-compatible, la TZ -6h está al 100%,
y todas las rutas existen. La nueva cancelación de contratos (0111/0112 + A3/B2) quedó
correcta y consistente. **No hay findings críticos de seguridad ni corrupción de datos.**

Hallazgos accionables: **1 ALTA · 9 MEDIA · ~25 BAJA**. El tema más repetido es la
**inconsistencia del guard de impersonación** y unos **gaps de surfacing del change-log**.

---

## 1. Findings consolidados (priorizados)

### 🔴 ALTA (1)

| # | Módulo | file:line | Problema | Impacto | Fix |
|---|---|---|---|---|---|
| **A1** | Cobrador | `cuotas_list_screen.dart:507-508, 837-838` | La tab **"Por cobrar"** (vista de trabajo principal del cobrador) calcula el saldo por fila como `monto − monto_pagado`, **omitiendo `cargos_neto`** (ni lo trae el SELECT). Es el **mismo bug F1 que se corrigió en `/admin/cuotas`**, replicado en la pantalla del cobrador. | Una cuota C$500 + reconexión C$100 muestra **C$500** en la lista cuando el cobrador va a cobrar **C$600** (la pantalla de cobro y la tab "Por cliente" sí dan 600). Viola #10 (consistencia cross-pantalla). | Agregar `cu.cargos_neto` al SELECT y `saldo = monto + COALESCE(cargos_neto,0) − monto_pagado` (clamp ≥0). 1 línea SQL + 1 Dart. |

### 🟠 MEDIA (9)

| # | Módulo | file:line | Problema | Impacto | Fix |
|---|---|---|---|---|---|
| **M1** | Cuotas | `cuotas_admin_screen.dart:1010-1027` | "Anular cuota" sobre una cuota **parcial** hace solo `UPDATE cuotas SET estado='anulada'` **sin espejar la cascada** del trigger 0023 (que anula el pago + recibo). Offline el pago queda `anulado=0` local. | Hasta el sync, el pago anulado-por-cascada **sigue contando como recaudado** (contrato + dashboard inflados). El contrato de cancelación SÍ espeja la cascada; acá no. | Dentro de un `writeTransaction`, replicar local el `UPDATE pagos/recibos SET anulado=1...` igual que hace el server (mismo patrón que la cancelación de contrato). |
| **M2** | Cuotas | `cuotas_admin_screen.dart:1066-1067` | El diálogo "Anular cuota" dice *"Los pagos ya aplicados no se modifican"* — **falso**: el trigger 0023 los anula. | El admin anula una cuota parcial creyendo conservar el pago, cuando en realidad lo revierte (saca plata del recaudado). | Corregir el copy: *"Los pagos y recibos aplicados se anularán y dejarán de contar como recaudado."* |
| **M3** | Cuotas/Pagos | `pagos_admin_screen.dart:480-508`, `cuotas_admin_screen.dart:251,962,997` | Ninguna acción de `/admin/pagos` ni `/admin/cuotas` chequea `estaImpersonandoProvider`: anular/editar pago, anular cuota, editar monto y crear cuota manual están disponibles **mientras el super_admin impersona**. El resto del dinero (cobro/cargo/visita/cancelar) sí lo bloquea. | Acciones del tenant quedan auditadas bajo la fila System del super_admin. Inconsistencia de defensa (mismo motivo que el guard S4). | Agregar el guard `estaImpersonandoProvider` al inicio de esas acciones (mismo patrón que `aplicar_cargo_dialog:81`). |
| **M4** | Settings | `settings_repo.dart:15,108-330` + `router.dart:83` | `settingsMapProvider`/`empresaNombreProvider` leen `SELECT * FROM settings` **sin `WHERE tenant_id`**. Impersonando, el SQLite tiene settings de 2 tenants con las mismas claves → `map[clave]` gana la última fila (no determinista). | Solo super_admin impersonando: Settings, `appSettingsProvider` (diasGracia, recibo, métodos) y **reportes** (empresaNombre) pueden usar el valor del tenant System (empresa vacía → header "ISP"). Writes van al tenant correcto. | Filtrar el read por `tenantIdProvider`: `watchAll`/`read`/`empresaNombreProvider` con `WHERE tenant_id=?`. |
| **M5** | Contratos | `router.dart:400` + `contrato_detail_screen.dart` | La pantalla de **edición de contrato es inalcanzable**: la ruta `/admin/contratos/:id/editar` y todo el modo `_esEdicion` existen, pero **ningún widget navega a ella** (el detalle no tiene botón Editar). | El admin NO puede corregir un contrato (plan, fechas, costo, notas). ~100 líneas + ruta son dead code hoy. | Decisión: (a) agregar botón Editar en el detalle, o (b) borrar la ruta + modo edición. Ver M6 antes de (a). |
| **M6** | Contratos | `contrato_form_screen.dart:421-423` | El mensaje de éxito al editar dice *"Cuotas futuras se ajustaron automáticamente"* — **no hay trigger** que regenere cuotas al UPDATE. Cambiar plan/fecha deja las cuotas viejas intactas. | Si M5 se habilita: el admin cambia el plan C$500→C$700, ve "cuotas ajustadas", pero las cuotas siguen con el precio viejo → divergencia silenciosa contrato↔cuotas. Latente mientras la pantalla sea inalcanzable. | Corregir el copy a algo honesto y/o bloquear edición de campos sensibles en contratos con cuotas pagadas. |
| **M7** | Dinero (test) | `supabase/tests/invariantes_dinero.sql:209-222` | **INV11 da falso positivo**: cuenta `COUNT(*) FROM cuotas WHERE contrato_id=ct.id` esperando `= duracion_meses`, asumiendo que las cuotas manuales tienen `contrato_id NULL`, pero el código **las auto-asocia** un `contrato_id` (con `tipo_cargo_manual` set). | El test de la **capa 2** (que vos vas a correr post-deploy) reporta `violaciones > 0` en cualquier ISP con un cargo de reconexión sobre un contrato fijo, aunque la data esté sana → ruido que oculta violaciones reales. | `... AND cu.tipo_cargo_manual IS NULL` en el COUNT. Corregir el comentario. |
| **M8** | Change-log | `inventario_screen.dart:2121` (sin callsite de historial) | `inv_categorias` tiene trigger (0099) y está registrada, pero **no expone su historial en ninguna pantalla**, y es editable (se crean inline). Viola el contrato "toda entidad editable tiene su historial accesible". | Un rename/baja de categoría queda en `audit_log` pero el admin no lo ve. | Agregar botón 🕐 (patrón Simple) en categorías, o exponer una mini-pantalla de categorías con su historial. |
| **M9** | Change-log | `ticket_detail_screen.dart:55-61` | El detalle de ticket muestra el **timeline de dominio** (`ticket_eventos`), NO el change-log de `audit_log`. Ediciones de título/prioridad de `tickets` y altas/bajas de `ticket_adjuntos` no se surfacean. | Editar el título de un ticket o borrar un adjunto queda en `audit_log` sin vía de visualización. Trazabilidad incompleta vs el contrato. | Agregar `HistorialCambiosWidget(tabla:'tickets')` (+ adjuntos como hija) o documentar que `ticket_eventos` es el change-log oficial (hoy un UPDATE de campo NO genera evento de dominio). |

### 🟡 BAJA (selección — ver detalle por módulo abajo)

| # | Módulo | Problema | Fix |
|---|---|---|---|
| B1 | Change-log | `cargos_extra` no se surfacea en `HistorialCuotaWidget` (tiene trigger pero no UI) | Sumar `cargos_extra` (hija directa) a la query de la cuota |
| B2 | Contratos | Transiciones a `completado`/`activo` NO se bloquean al impersonar (solo `cancelado`) | Por consistencia con A3, bloquear todo el dropdown al impersonar |
| B3 | Settings | `/admin/pagos` y `/admin/notificaciones` sin guard de ruta directa por setting (solo se ocultan del menú) | Guard simétrico al de `/admin/audit` en el router |
| B4 | Settings | Settings `cuotas.manuales`/`editar_monto`/`descuento_pronto_pago` cableados pero **sin tab** (inalcanzables desde UI) | Exponer tab "Cuotas" o documentar como parqueados |
| B5 | Settings | Chips del viewer de Auditoría hardcodeados a 5 tablas (hoy hay ~25 entidades) | Derivar de `kAuditCamposCatalogo` |
| B6 | Inventario | Categorías solo se crean, nunca se editan/borran; dup local con falla silenciosa al sync | CRUD de categorías + pre-check local de duplicado |
| B7 | Inventario | `admin_cobranza` sincroniza las 6 tablas inv_ pero el router le bloquea `/admin/inventario` | Sacar inv_ de su bucket, o darle acceso a la pantalla |
| B8 | Técnico | "Ver cliente" del mapa del técnico pushea `/clientes/:id` → el router lo rebota a `/tecnico` (botón muerto) | Ocultar el botón/chips de cobranza en `tecnicoMode` |
| B9 | Reportes | Los PDF no muestran SnackBar de éxito al guardar (el Excel sí) | Espejar el patrón del Excel |
| B10 | Cobrador/Cuotas | `aplicado_en`/`anulada_en` en hora local (no UTC) en 3 spots | Normalizar a `.toUtc()` los 3 juntos (ya en backlog) |
| B11 | Varios | Badges "Vencida hace X"/"diasMora" con `DateTime.now()` local en vez de base Nicaragua | Derivar el "hoy" con base UTC-6 |
| B12 | Edge/Auth | `_humanizarError` duplicado en 3 lugares (2 byte-idénticos) | Helper público desde `edge_functions.dart` |

### Dead code confirmado

| Símbolo | file:line | Acción |
|---|---|---|
| `PendingScreen` | `empty_state.dart:50` | 0 referencias → borrar |
| `Cuota.estadoVisual()` + `enum CuotaEstadoVisual` | `cuota.dart:25-47,89-106` | 0 call sites (la derivación la hace `cuota_estado.dart`) → borrar o documentar |
| `ClientesRepo.getById` (probable) | `clientes_repo.dart:16-20` | Verificar y borrar si sin uso |

### Doc drift (no es bug de código, desorienta)

- **`_schemaVersion` real = 26** (db.dart) pero CLAUDE.md dice 20, ARQUITECTURA.md 16, ESTADO-APP.md 22.
- **`/admin/onboarding`** sigue listado en CLAUDE.md pero el wizard se **eliminó** en v0.6.4.
- **Reportes -6h**: ESTADO-APP/REPORTE-SESION dicen que las queries de reportes usan `date(...,'-6h')`; el código usa `date(fecha_pago)` raw (que es lo **correcto** porque `fecha_pago` ya es wall-clock Nicaragua). Riesgo: que una sesión futura "re-arregle" e introduzca un doble-shift.

---

## 2. Temas convergentes (aparecen en varios módulos)

1. **Guard de impersonación inconsistente** (M3, M4, B2): cobro/cargo/visita/cancelar-contrato bloquean al impersonar, pero `/admin/pagos`, `/admin/cuotas`, las transiciones de estado no-cancelado, y los **reads de settings** no. Conviene unificar la política.
2. **Espejo offline de cascadas** (M1): la cancelación de contrato espeja la cascada de anulación localmente; "anular cuota" no → recaudado inflado offline. Mismo patrón debería aplicarse.
3. **`cargos_neto` en el saldo** (A1): el bug F1 ya corregido en admin sigue vivo en la lista del cobrador.
4. **Surfacing del change-log** (M8, M9, B1): inv_categorias, tickets/adjuntos y cargos_extra tienen trigger pero su historial no es visible desde la UI → incumplen el contrato "toda entidad editable tiene su historial accesible".
5. **Copy que miente** (M2, M6): mensajes de éxito/diálogo que describen un comportamiento distinto al real.

---

## 3. Reporte por módulo

### 3.1 Cobrador (campo) — móvil-first, offline-first

**Alcance:** flujo de campo del cobrador. Rutas `/`, `/clientes`, `/cuotas`, `/mapa`,
`/historial`, `/perfil`, `/clientes/:id`, `/cobro/:cuotaId`, `/recibo/:reciboId`,
`/perfil/impresora`. Cobro online/offline, multi-cuota, foto comprobante, recibo
correlativo, impresión Bluetooth térmica.

**Lifecycle (USD con vuelto, offline→sync):** cobrador abre `/cuotas` (tab Por cobrar) →
cuota mayo C$500 → `/cobro` → método Efectivo, toggle US$, tipea 15 (tasa 36.5) → preview
"C$547,50, vuelto C$47,50" → confirma → `aplicado=500` (a caja), `vuelto=47.50` (siempre
C$), `monto_original=15`. Persiste `monto_cordobas=500`, recibo con correlativo (piso del
server), espejo local de la cuota → `pagada`. Todo local (offline). Imprime BT térmica.
Vuelve la red → sube la CRUD queue → trigger confirma (server gana).

**Inventario de opciones (verificado):** tabs Por cliente / Por cobrar / filtros
(Pendientes/En mora/En gracia/Parciales/Vencen hoy) · multi-select long-press (orden
obligatorio, guard de cuota manual) · campo monto + toggle C$/US$ + métodos + nº
referencia + foto + notas + fecha editable · cargo reconexión auto + descuento pronto pago
auto · recibo (imprimir BT / sistema / descargar PDF / configurar impresora / ver cliente)
· historial (editar/anular gated por setting) · búsqueda multi-campo · mapa con filtros y
caché offline. **Todos OK salvo A1.**

**Findings:** **A1 (ALTA)** saldo "Por cobrar" sin cargos_neto. BAJA: aplicado_en local
(B10), diasMora display (B11), detección reconexión con `DateTime.now()` (cosmético).

**Limpio:** invariantes #1–#3 (single+multi) herméticos, vuelto nunca infla monto_cordobas,
correlativo consulta server, mirror local = trigger, offline-first real, TZ -6h, streams
cacheados, rutas OK, guards de impersonación/prefijo presentes.

### 3.2 Admin — Clientes / Contratos / Planes

**Alcance:** CRUD de clientes (paginado + bulk-assign + geo/red picker), contratos (alta
genera cuotas, edición, estado, cancelación), planes, y el detalle de contrato compartido.

**Lifecycle (contrato fijo 12 meses C$500):** alta `CT00012` → trigger genera 12 cuotas
pendientes → resumen Total = 500×12 = C$6.000 (#5, no suma de cuotas) → cobra cuota 1
(C$500) + parcial de cuota 2 (C$300) → cancela: cuotas 3-12 → anuladas, cuota 2 → descuento
C$200 + mirror → `pagada`; el pago C$300 se preserva → recaudado real C$800, resumen "Total
recaudado C$800 / Pendiente 0".

**Inventario de opciones (verificado):** búsqueda/filtros/paginación · bulk-assign cobrador
· crear/editar cliente (código único/inmutable/mayúsculas, guard desasignar con contratos)
· estado cliente (switch solo admin) · geo/red picker · lista contratos + filtro activos ·
crear contrato (genera cuotas) · **editar contrato (inalcanzable — M5)** · resumen
financiero (#5/#6) · dropdown estado (cancelar = A3/B2 OK) · cuotas/pagos/documento del
contrato · historiales (cliente agregador, cuota agregador, contrato/plan simple) · CRUD
planes. **Todos OK salvo M5/M6.**

**Findings:** **M5** edición de contrato inalcanzable (dead code/feature faltante), **M6**
mensaje de "cuotas ajustadas" engañoso. BAJA: `_activo` semi-muerto, impersonación
completado/activo no bloqueada (B2), cuota parcial cancelada muestra monto completo,
parciales leídas fuera de la tx. **0 bugs de dinero.**

**Limpio:** cancelación matemáticamente correcta (mirror = trigger), #5/#6, B2 terminal, A3,
switch de estado quitado del form, change-log con regla de profundidad exacta.

### 3.3 Admin — Cuotas / Pagos / Mora / Cargos

**Alcance:** `/admin/cuotas` (lista + crear manual + editar monto + anular), `/admin/pagos`
(historial + editar/anular + recrear vía cobro + grupo_cobro), `/admin/notificaciones`
(bandeja de mora), diálogo de cargo.

**Lifecycle:** cuota C$500 + reconexión C$100 (`cargos_neto=+100`) → parcial C$300 →
`parcial`, saldo C$300 → mora (cron 06:00 Nicaragua, `monto_adeudado=300` con cargos_neto) →
anular pago → restaura `monto_pagado=0` + reabre mora, pago preservado.

**Inventario de opciones (verificado):** buscar/chips de estado · saldo con cargos_neto (F1
ya corregido acá) · crear cuota manual · editar monto · **anular cuota (M1/M2)** · buscar
pago/ver anulados · badge grupo_cobro · editar/anular pago (bloquea vuelto/USD) · historial
del pago · bandeja de mora (marcar vista/copiar tel/ver cliente) · diálogo de cargo (topes,
guard de impersonación presente). **OK salvo M1/M2/M3.**

**Findings:** **M1** anular cuota parcial no espeja cascada offline, **M2** copy falso,
**M3** acciones no bloqueadas al impersonar. BAJA: badge TZ local (B11), validación de
descuento contra base.

**Limpio:** saldo canónico consistente cross-pantalla, monto_pagado nunca a mano, anular
restaura+preserva (#8), cargos_neto = mirror del trigger, mora server-side correcta
(resolución al pagar Y al anular con 0112), estados derivados en Dart.

### 3.4 Admin — Reportes

**Alcance:** 8 reportes + arqueo + padrón, cada uno en PDF y Excel. Tarjetas analíticas en
vivo + reportes descargables (diálogo nativo de guardado).

**Lifecycle ("Cobros" 1 USD + 1 C$):** pago US$30 (monto_cordobas=1095) + pago C$500 →
query `FROM pagos` (grain = pago, sin fan-out) → Excel/PDF con columnas idénticas → Total
"C$1.595,00" = SUM(monto_cordobas) = lo aplicado (#1/#4, no entregado ni vuelto).

**Inventario (los 10 datasets verificados):** Cobros, Mora, Por cobrador, **Estado de
clientes (bug cont.13 CONFIRMADO CORREGIDO** — 3 subqueries correlacionadas, sin fan-out),
Fiscal (partido por moneda), Eficiencia, Inactivos, Anulaciones, Arqueo (caja por cobrador,
USD a tasa histórica), Padrón (solo Excel). **Todos OK.**

**Findings:** solo BAJA — doc drift -6h (código correcto), supuesto de device-TZ Nicaragua,
**B9** sin SnackBar de éxito en PDF, asimetría arqueo vs eficiencia (by-design). **0
ALTA/MEDIA, 0 fan-out, 0 SQL Postgres-only.**

**Limpio:** paridad Excel↔PDF header-por-header, recaudado = aplicado, TZ consistente con
dashboard, degradación kIsWeb, sin fuga cross-tenant.

### 3.5 Admin — Settings / Geografía / Cobradores / Audit / Dashboard

**Alcance:** Ajustes (empresa/cobranza/pagos/recibos/avanzado super-only), geografía CRUD
per-tenant, gestión de cobradores, viewer de auditoría, dashboard de KPIs.

**Lifecycle:** admin apaga "Permitir pago parcial" → `UPDATE settings` → sube → trigger
audita → re-emite → `appSettingsProvider` → en el cobro exige saldo completo. **El toggle
gatea comportamiento real.**

**Inventario (cada setting trazado hasta su consumo):** la gran mayoría **gatea de verdad**
(empresa, dias_gracia, dias_cuotas_visibles, pago_parcial, pago_adelantado,
cobrador_edita/anula, métodos de pago, USD+tasa, recibos, comprobante/foto, descuentos,
reconexión, audit_visible). **Decorativos-ocultos by-design:** modo_ruta, caja_chica,
recrear_pago_anulado, templates viejos de recibo. **Cableados pero sin tab (B4):**
cuotas.manuales, editar_monto, descuento_pronto_pago.

**Findings:** **M4** reads de settings sin filtro de tenant (impersonación). BAJA: **B3**
pantallas opcionales sin guard de ruta directa, **B5** chips de audit hardcodeados, **B4**
settings sin tab, doc onboarding eliminado, seed inconsistente pago_adelantado.

**Limpio:** enforcement super-only server-side (0085/0086) + UI, gating de rol coherente
router↔menú, geografía per-tenant con historial, rol de cobrador bloqueado salvo super,
dashboard TZ-correcto sin fan-out, boolean defense.

### 3.6 Super_admin / Impersonación / Auth / Router

**Alcance:** `/super/*`, impersonación, login/set-password/recovery, router por rol, error
logs.

**Lifecycle:** super crea ISP sin email → password server-side copiable → admin loguea sin
PKCE. Super impersona tenant X → banner "Viendo: X" → `current_tenant_id()` override (solo
si `is_super_admin()`) → intenta cancelar contrato → bloqueado (A3) → sale → audit
start/end.

**Inventario (verificado):** login/recovery/set-password/cambiar-pass · gates del router
(no-logueado, recovery, sync-gate, landing por rol, técnico/cobrador/admin_cobranza/super) ·
crear tenant · entrar al tenant (impersonar) · toggle de módulo · gestión de miembros
(forzar pass/reset/reenviar/cambiar rol/email/activar/eliminar) · salir de impersonación ·
viewer de error logs + borrar. **Todos OK.**

**Findings:** **0 ALTA/MEDIA reales.** BAJA: orden upsert-antes-de-audit en enter() (F-F1),
exit() no re-arma el sync-gate, PKCE recovery user-switch, error logs cap, race del rol
provider (mitigada), `_humanizarError` dup (B12).

**Limpio:** threat model de impersonación sólido (RLS `is_super_admin()` server-side, no
forjeable, no se puede impersonar "en nombre de" otro), banner siempre visible, acciones de
campo bloqueadas, técnico contenido, lifecycle de sesión robusto, Edge Functions con auth
correcta.

### 3.7 Tickets / Técnico / Incidentes / Red (Fase 3)

**Alcance:** tickets con SLA, rol técnico aislado (móvil-first), incidentes/outages con
alcance, topología de red.

**Lifecycle:** admin crea tipo con SLA + checklist → ticket `T-00001` asignado al técnico →
SLA efectivo = min(tipo, prioridad), cuenta regresiva offline → técnico (SQLite SIN dinero)
avanza/pausa/consume material/firma/resuelve offline → sync: trigger descuenta stock +
instala serial → admin cierra (o cron auto-cierre).

**Inventario (verificado):** gates de módulo + soloAdmin · CRUD tipos + SLA por prioridad +
auto-cierre · crear ticket (correlativo, snapshot checklist) · transiciones (matriz cliente
= trigger; técnico acotado) · reasignar/vincular incidente (admin) · comentar/adjuntar/firma
· checklist · badge "en riesgo" · técnico (mis tickets/mapa/perfil) · materiales 3C ·
incidentes (alcance excluyente, afectados derivados, snapshot) · red CRUD + sync al
cobrador. **Todos OK.**

**Findings:** **0 ALTA/MEDIA.** BAJA: **B8** "Ver cliente" del mapa del técnico es botón
muerto, asimetría de stock granel offline (by-design), created_at naive.

**Limpio:** aislamiento del técnico (dinero) con doble defensa (sync rules + router), SLA
con pausa exacta server-side, materiales 3C con co-tenencia validada e idempotencia,
incidentes con snapshot que sobrevive al borrado, red con guards server-side.

### 3.8 Inventario

**Alcance:** catálogo (categorías/proveedores/productos) → ubicaciones → ledger
(movimientos) → seriales. Stock = proyección derivada del ledger. 5 tabs.

**Lifecycle:** alta producto serializado → ingreso (serial+movimiento+costo promedio) →
transferir a custodia del técnico → consumir en ticket (trigger baja stock + serial
`instalado`) → historial cuna-a-tumba (serial + movimientos + ticket_materiales).

**Inventario (verificado):** existencias (stock derivado serial/granel) · ingreso/egreso/
ajuste/transferencia · equipos (asignar/transferir/devolver/baja/historial) · CRUD
productos/ubicaciones/proveedores · escanear código de barras · stock mínimo + badge ·
gestión de equipos en baja. **Todos OK.**

**Findings:** **0 ALTA/MEDIA.** BAJA: **B6** categorías sin editar/borrar + dup silenciosa,
**M8** (categorías sin historial — listado arriba como MEDIA por el contrato de change-log),
**B7** admin_cobranza sync vs router, sin tests.

**Limpio:** stock derivado consistente sin fan-out, atomicidad + re-validación TOCTOU,
ledger append-only server-side, consumo 3C hermético, change-log completo (salvo el surface
de categorías), cadena DB↔schema↔sync↔version OK.

---

## 4. Cross-cutting

### 4.1 Invariantes de dinero — los 10 se cumplen ✅

`monto_cordobas`=aplicado · `vuelto`=siempre C$ · `monto_original`×tasa≈cordobas+vuelto ·
recaudado=SUM(no anulados) · total fijo=precio×meses · indefinidos solo recaudado ·
monto_pagado por trigger · anular restaura+preserva · cargos al contrato · consistencia
cross-pantalla. **Sin fan-out, sin leaks de entregado/vuelto.** Único finding: el TEST
INV11 (M7), no el código.

### 4.2 Change-log — cobertura casi completa

27 entidades con trigger + registradas en `.dart`. Regla de profundidad correcta en los 3
agregadores (cliente/cuota/serial). **Gaps de surfacing en UI:** inv_categorias (M8),
tickets/adjuntos (M9), cargos_extra (B1) — tienen trigger pero su historial no es visible.

### 4.3 DB / RLS / Seguridad — limpio ✅

Todas las tablas operativas con tenant_id + RLS + super_admin_all + trigger audit. SQLite
100% compatible, TZ -6h al 100%, rutas OK, Edge Functions con auth correcta (callerClient
sujeto a RLS; service_role solo auth.admin.*), co-tenencia validada en los SECURITY DEFINER.

---

## 5. Estado real del backlog

- ✅ **RESUELTOS (~19, tachables):** ps.db.watch inline · OfflineBanner (inestable/reintentar/
  fade) · error logging (paginación/rate-limit/índice/debounce/borrar/auth-listener) ·
  forzar-password SYSTEM_TENANT · R12 ==/hashCode (4 modelos) · edge fn signout-failed audit ·
  edge fn ghost user · flash wizard (moot, onboarding eliminado) · PopScope context.go ·
  race _rolUsuarioProvider · rework super_admin (impersonación completa).
- 🔶 **PARCIALES (~8):** error retention (RPC sí, cron no) · reported_at delta · user-agent real ·
  double-connect lock · sync-gate-stuck (telemetría sí, fix raíz no) · FotoComprobante F5 ·
  distribución (MSIX sí, applicationId+deep-links no).
- ❌ **ABIERTOS reales (~9, mayoría LOW/edge):** OfflineBanner primeros-3s · _humanizarError 3x ·
  _currentRoute GoRouter · filtro fechas error logs · reenviar-invitacion lock · aplicado_en/
  anulada_en local (3 spots) · tests widget/integración/redirects · 4 edge_fn tests skipped ·
  edge teóricos (cross-tab, autoDispose, lastSyncedAt, PKCE).
- 🅿️ **PARQUEADOS (Rubén):** Resend sandbox · flags modo_ruta/caja_chica/recrear_pago · geo del cobro.

---

## 6. Plan de fixes recomendado (orden de valor)

**Antes de deployar (tocan dinero/consistencia):**
1. **A1** — cargos_neto en el saldo del cobrador (ALTA, 2 líneas).
2. **M7** — fix del test INV11 (afecta tu capa-2 post-deploy).
3. **M1 + M2** — anular cuota parcial: espejar cascada + corregir copy.
4. **M3 + M4 + B2** — unificar guard de impersonación (acciones admin + reads de settings).

**Calidad/UX (no bloquean deploy):**
5. **M5 + M6** — decidir edición de contrato (habilitar con copy correcto, o borrar dead code).
6. **M8 + M9 + B1** — surfacing del change-log (categorías, tickets, cargos_extra).
7. **B-varios** — guards de ruta, chips de audit, SnackBar PDF, mapa del técnico, etc.
8. **Dead code** — PendingScreen, Cuota.estadoVisual.
9. **Doc drift** — actualizar schema version, onboarding, -6h en los docs.

**Backlog para vaciar:** _humanizarError, aplicado_en/anulada_en a UTC, cron de retention +
filtro de fechas, lock de reenviar-invitacion. Edge-cases y tests = esfuerzos mayores aparte.
