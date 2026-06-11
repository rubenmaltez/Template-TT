# REPORTE DE AUDIT — Integral profundo 2026-06-11

> Audit integral de TODA la app pedido por Rubén: módulos, entidades,
> interacciones, UI, UX y lógica — con foco en bugs NO encontrados
> previamente. READ-ONLY: ningún fix aplicado todavía (esperan aprobación,
> Fase 4 del lifecycle).

---

## Metodología (agentes, scope, archivos)

**8 agentes especializados en paralelo**, cada uno con scope acotado, las
reglas de AGENTS.md y la lista de exclusiones (backlog vivo + parqueados +
hipotéticos de signup). Todos los findings CRITICAL/HIGH fueron
**re-verificados a mano contra el código** por el orquestador antes de
entrar a este reporte.

| Agente | Scope | Cobertura |
|---|---|---|
| Dinero e invariantes | cobro, pagos, cuotas, contratos, recibos, reportes, triggers 0012-0112, tests | Las 10 invariantes verificadas una por una; ~14 superficies de saldo comparadas |
| Offline / SQL / PowerSync | schema v26, connector, sync-rules, TODAS las queries SQL de lib/ | Script: 78 INSERT + 61 UPDATE + 370 SELECT cruzados contra schema; greps del checklist §1/§1b |
| Seguridad / multi-tenant | RLS de las 114 migraciones, 6 Edge Functions, Storage, RPCs, impersonación, guards | RLS por tabla, functions línea por línea, vectores REST directos |
| UI Flutter | lib/features/ completo (lifecycle, async gaps, doble-submit, forms, overflow) | Pasada por carpeta priorizando dinero |
| UX / flujos | 6 journeys completos por rol (~30 pantallas leídas de punta a punta) | Cobrador, admin, auth, updater, técnico, súper |
| Tickets / Inventario / Incidentes | módulos opcionales + migraciones 0097-0110 + 0114 | Ledger, SLA, materiales↔stock, gates, adjuntos |
| Change log universal | trigger 0047+, 5 widgets de historial, matriz de 27 entidades | Matriz entidad × trigger × labels × UI × agregador |
| Integridad estructural | 49 rutas × navegaciones, contratos Edge↔Dart, modelos↔schema, updater, pubspec, drift docs | 6 cruces completados |

Reportes individuales completos de los agentes: se generaron en `/tmp/audit/`
durante la sesión; el contenido relevante está consolidado acá.

**Veredicto general:** la app está sólida — las invariantes de dinero
aguantan, el aislamiento multi-tenant no tiene NINGUNA fuga, el SQL es 100%
SQLite-compatible y la TZ Nicaragua está bien en 48/48 cortes. Los problemas
reales se concentran en (a) el camino de la **divergencia silenciosa**
(connector que descarta, UI que avisa 6 segundos) y (b) **escrituras
concurrentes/offline** sin guard server-side fuera del núcleo de dinero.

---

## Findings que requieren fix

### Tabla resumen (CRITICAL + HIGH — todos re-verificados a mano)

| # | Severidad | Archivo:línea | Problema | Impacto en usuario |
|---|---|---|---|---|
| 1 | CRITICAL | `lib/powersync/connector.dart:103-120` | `_isNonRetryable` clasifica por prefijo `'P'`/`'4'` → descarta errores TRANSITORIOS (PGRST301 JWT expirado, PGRST000/002, 429) como permanentes | Un cobro hecho offline puede borrarse de la cola de upload PARA SIEMPRE: el server nunca recibe el pago |
| 2 | HIGH | `lib/data/repositories/pagos_repo.dart:84-136` (ídem 269-320) | Correlativo de recibo se reusa offline si el admin anuló el último recibo (bucket filtra `anulado=false` y borra la fila local; piso server con `catch (_) {}`) | Recibo impreso con número duplicado + INSERT descartado por 23505 → pago en server SIN recibo |
| 3 | HIGH | `lib/features/cobro/cobro_screen.dart:585-596` | Aplicar cargo/descuento manual recalcula el total SOLO desde DB y pisa el ajuste de `_cargosAuto` (que no se limpia y se inserta igual al confirmar) | Sobrepago con pronto pago (viola INV4), cuota "completa ✓" que queda parcial con reconexión, o DOBLE cargo de reconexión |
| 4 | HIGH | `supabase/migrations/0046_pagos_update_cobrador.sql:8-22` | Settings `cobrador_anula_cobros`/`cobrador_edita_cobros` (default false) solo gatean la UI; la RLS permite al cobrador UPDATE de SUS pagos vía REST sin congelamiento de columnas | Vector de fraude: cobrador cobra efectivo, registra y luego anula por REST → se queda con la plata; queda solo rastro en audit_log |
| 5 | HIGH | `lib/features/shell/app_shell.dart:23-34` + connector | Write rechazado por el server = SnackBar de 6s con el error CRUDO de Postgres en inglés; la divergencia local no deja rastro visible después | Cobro "fantasma": la app del cobrador dice pagada, el server no — nadie se entera hasta el arqueo |
| 6 | HIGH | `lib/features/cobro/cobro_screen.dart` (sin PopScope) | El back de Android descarta el cobro (monto/foto/referencia) sin confirmar; el botón "Cancelar" sí confirma | Cobro perdido por un gesto accidental, quizá sin que el cobrador lo note |
| 7 | HIGH | `lib/features/admin/contratos/contrato_form_screen.dart:203-268` y `cliente_form_screen.dart:149-193` | Los guards async (`await ps.db.getAll` ×2-3) corren ANTES de `_guardando = true` → ventana de doble-submit | Doble-click en Windows = 2 clientes/contratos locales duplicados (el server rechaza el 2º al sync, pero offline persisten y se puede operar sobre el duplicado) |
| 8 | HIGH | `lib/features/contratos/contrato_detail_header.dart:80-92` + `contrato_detail_screen.dart:105-112` | "Cancelado" (acción TERMINAL: anula cuotas + inserta descuentos liquidadores) se ejecuta directo desde el PopupMenu sin diálogo de confirmación | Tap equivocado en el menú = contrato cancelado irreversible con efectos de dinero; anular UN pago exige motivo, cancelar el contrato entero no pide nada |
| 9 | HIGH | `lib/features/admin/cobradores/cobradores_admin_screen.dart:774-787` | `cobradores` es editable (nombre/teléfono/prefijo_recibo/activo) y NO tiene trigger de changelog, ni labels, ni historial — único gap en 27 tablas | Cambiar el prefijo de recibo (numeración = rastro de dinero) no deja registro de quién/cuándo |
| 10 | HIGH | `lib/features/admin/inventario/inventario_screen.dart:1769-1884` | `_asignar`/`_devolver`/`_transferir` validan estado del serial SOLO contra SQLite local; en Postgres no hay trigger de transiciones (el guard 0106 solo cubre consumo por ticket) → last-writer-wins | Dos devices offline asignan el MISMO serial a clientes distintos; o el UPDATE ciego del admin pisa el consumo del técnico → el sistema dice que el equipo está donde no está |

### Detalle de los CRITICAL/HIGH

**#1 — Connector descarta transitorios (CRITICAL · agente Offline, verificado a mano)**
```dart
if (code.startsWith('40')) return false;          // salva 401/408 por accidente
if (code.startsWith('P') || code.startsWith('2') || code.startsWith('4')) {
  return true;                                     // ← PGRST301 matchea 'P' → descartado
}
```
Escenario: el cobrador pasa el día sin señal (JWT vence, expiry 1h). Al
recuperar cobertura, PowerSync dispara `uploadData` antes de que el SDK
refresque el token → PostgREST responde `PGRST301` → la op se descarta con
`transaction.complete()`. El INSERT del pago queda solo en SQLite local.
Fix: allowlist explícita — `code == 'P0001' || startsWith('23') ||
startsWith('42') || startsWith('22')` → non-retryable; TODO lo demás
(PGRST*, desconocidos) → retryable.

**#2 — Correlativo de recibo offline (HIGH · agente Offline, verificado)**
El MAX local pierde los anulados (el bucket `por_cobrador` filtra
`anulado = false` → PowerSync borra la fila local al anularse) y el piso del
server es `try { ... } catch (_) {}`. Admin anula el último recibo → cobrador
sale sin señal → reimprime ese número → 23505 al subir (legítimamente
non-retryable) → recibo descartado.
Fix: high-water mark local que nunca decrece por `(cobrador, prefijo)`
(tabla local-only o SharedPreferences), o bajar también los recibos anulados
al cobrador y filtrar el ruido en la UI.

**#3 — Cargo manual pisa cargos auto (HIGH · agente Dinero, verificado)**
`_cargar()` ajusta totales con `_cargosAuto` aún no insertados (reconexión
suma, pronto pago resta). Al volver del `AplicarCargoDialog`:
`_totalesACobrar[0] = await repo.totalACobrar(...)` — solo cargos en DB;
`_cargosAuto` no se limpia ni re-aplica, y en `_confirmar()` se insertan
igual. Tres escenarios verificados: sobrepago (pronto pago), cuota que queda
parcial debiendo la reconexión, y doble cargo de reconexión (el dedupe
`existing.isEmpty` corrió solo al cargar la pantalla).
Fix: tras aplicar cargo manual, re-chequear el dedupe de `_cargosAuto`
contra DB, limpiar los tipos ya insertados y re-aplicar el ajuste de los
restantes sobre el total nuevo.

**#4 — Anulación de pagos burlable por REST (HIGH · agente Seguridad, verificado)**
La policy 0046 lo declara intencional en su comentario ("los toggles
controlan la UI"), pero ambos settings tienen default `false` y el admin que
los apaga espera un control real. No hay BEFORE UPDATE de congelamiento en
`pagos` (sí en `cuotas` 0111 y `recibos` 0048). Mitigación parcial: queda
rastro en audit_log.
Fix (o aceptación formal documentada): trigger BEFORE UPDATE en `pagos`
replicando el patrón 0085 — si `current_user_rol()='cobrador'`, rechazar
cambio de `anulado` salvo setting `cobrador_anula_cobros`, y cambios de
montos salvo `cobrador_edita_cobros`.

**#5 — Divergencia silenciosa en la UI (HIGH · agente UX, verificado)**
`SnackBar('Error al sincronizar ${error.table}: ${error.message}')` — crudo,
inglés, 6 segundos, sin acción. Después del SnackBar no queda NINGÚN rastro
visible (sí en error_logs, que el cobrador no ve).
Fix: persistir los rechazos en una lista visible (Perfil → "Cobros sin
sincronizar"), mensaje humano en español, y clasificar los códigos comunes.
Complementa el fix #1 (menos descartes) — este cubre los descartes legítimos.

**#6 — Cobro sin PopScope (HIGH · agente UX, verificado)**
Cero `PopScope` en `cobro_screen.dart` (verificado por grep); los forms de
cliente/contrato SÍ usan PopScope + formDirtyProvider. Fix: ~10 líneas
reusando la lógica de `_cancelar()`.

**#7 — Doble-submit en forms (HIGH · agente UI, verificado)**
En ambos forms los pre-chequeos con `await` corren con el botón habilitado;
`_guardando = true` recién se setea después. Contraste: `cobro_screen`
setea `_enviando = true` SINCRÓNICAMENTE antes del primer await (correcto).
Fix: mover el `setState(_guardando = true)` al inicio y revertirlo en cada
early-return de validación.

**#8 — Cancelar contrato sin confirmación (HIGH · agente UI, verificado)**
`PopupMenuButton(onSelected: onEstadoChanged)` → `_cambiarEstado('cancelado')`
→ `_cancelarYLiquidarCuotas` directo. Tiene guard de doble-tap e
impersonación, pero ningún "¿Estás seguro?". Fix: AlertDialog con motivo
(mismo estilo que anular pago) para la transición a 'cancelado'.

**#9 — `cobradores` sin changelog (HIGH · agente Change Log, verificado)**
Verificado por grep: ningún `trg_changelog_cobradores` en migraciones; sin
labels en `audit_changelog.dart`; sin historial en su pantalla. Solo
rol/activo-del-súper/passwords se auditan a mano vía RPCs.
Fix: migración (columna `ocurrido_en` + trigger genérico) + labels + widget.

**#10 — Seriales sin guard server (HIGH · agente Tickets/Inventario, verificado)**
Único trigger sobre `inv_seriales` = el de changelog (verificado por grep).
El stock agregado no se corrompe, pero la trazabilidad y la ubicación física
del equipo sí. Fix: trigger BEFORE UPDATE que valide transiciones de estado
del serial (server gana), dejando que el connector surfacee el rechazo.

### MEDIUM (20 únicos tras dedupe — por área)

**Dinero:**
- **M1** `cuotas_admin_screen.dart:986-993` — "Editar monto" no recalcula
  estado ni en cliente ni en server (no hay trigger sobre `cuotas.monto`):
  cuota parcial editada por debajo de lo pagado queda atascada en 'parcial'
  con saldo negativo (viola INV3, rompe invariante #10 cross-pantalla).
  Fix: mirror `calcularEstadoCuota` en el write + trigger server
  `AFTER UPDATE OF monto`.
- **M2** `pagos_admin_screen.dart:589` + `historial_screen.dart:308` +
  `pagos_repo.dart:474-585` — Editar pago sin tope contra el saldo: typo
  infla el recaudado silenciosamente (viola INV4). Fix: validar
  `montoNuevo <= saldo + montoPrevio` en `editarPago`.
- **M3** `pagos_repo.dart:407-469` — Anular pago NO revierte el descuento
  pronto-pago que ese cobro insertó (cargos_extra no tiene `anulado` ni hay
  DELETE en ningún flujo): la cuota queda con el total rebajado para siempre.
  Fix: marcar origen (pago_id) en cargos auto y revertirlos al anular.
- **M4** Saldo clampeado a ≥0 en cuotas_list/cobro pero NO en clientes_list
  ni dashboard (invariante #10 con data anómala). Fix: unificar semántica.

**Offline/PowerSync:**
- **M5** `db.dart:73-132` — lock `_pendingOp` despierta a TODOS los
  esperantes sin re-check → disconnect+connect del flow forzar-password
  pueden correr concurrentes. Fix: encadenar futures o while con re-check.
- **M6** `pagos_repo.dart:88-98` — query del piso del correlativo SIN
  `.timeout()`: con señal degradada el flujo de COBRO se cuelga minutos.
  Fix: `.timeout(Duration(seconds: 5))`.

**Seguridad:**
- **M7** Topes de descuento (`descuento_max_*`) y reconexión (settings
  super-only 0086) no se enforcean en el INSERT vía REST. Defensa en
  profundidad; decidir si cerrar o aceptar.

**UI:**
- **M8** `cobro_screen.dart:647-663` (+cuotas_admin 656/755) — la coma
  decimal se FILTRA en silencio: "500,50" → "50050" (monto_original inflado,
  vuelto gigante). Fix: aceptar coma y normalizar a punto (helper compartido).
- **M9** `settings_admin_screen.dart:1013-1026` — settings numéricos (incl.
  TASA USD): parse inválido o salir antes del debounce de 600ms = cambio
  perdido EN SILENCIO. Fix: errorText + flush del debounce en dispose.
- **M10** `ticket_form_screen.dart:333-392` + `inventario_screen.dart:1959-2031`
  (SOSPECHA fuerte) — `ps.db.watch` inline en build de los sheets de búsqueda
  de cliente (violación checklist §2): reabrir el sheet puede dejar la lista
  "Sin resultados" para siempre; además ignoran `snap.hasError`.
- **M11** `recibo_screen.dart:145-160` + patrón transversal `initialData: []`
  — flash de "Recibo no encontrado" justo después de cobrar (estado de error
  del flujo principal de dinero durante la carga); ídem "Nada por cobrar".
  Fix: distinguir `connectionState.waiting` → skeleton.

**UX:**
- **M12** `cuotas_list_screen.dart:87-101` — el ADMIN que filtra "En mora"
  marca las notificaciones como vistas y borra el badge del COBRADOR.
  Fix: no marcar en adminMode (1 línea).
- **M13** `dashboard_admin_screen.dart:81+` — KPIs desaparecen MUDOS en
  error (`error: (_,__) => SizedBox.shrink()`). Fix: estado de error visible.
- **M14** Patrón transversal (~15 sitios) — `Error: $e` crudo en pantalla
  (SQLite/Postgres en inglés). Fix: helper `ErrorRetry` compartido.
- **M15** `historial_screen.dart:158-180` — Editar/Anular del cobrador:
  permite abrir edición de pagos USD/con vuelto que el repo rechaza al final
  con "Exception:"; el diálogo de anulación no identifica el pago (cliente/
  monto/recibo) y los targets son de 32px. El admin ya lo resuelve bien.
- **M16** `ticket_detail_screen.dart:316-320` — "Resuelto" a un tap sin
  confirmación y SIN vuelta atrás para el técnico (las transiciones de
  vuelta son del admin). Fix: confirmar transiciones terminales por rol.
- **M17** `update_banner.dart:162-211` — tras conceder el permiso de
  instalación, "Actualizar de nuevo" RE-DESCARGA el APK completo (zona rural
  3G). Fix: cachear el File descargado.

**Tickets/Inventario/Change log:**
- **M18** `ticket_form_screen.dart:252-255` — correlativo de ticket MAX+1
  por TENANT (no por creador como recibos): colisión multi-device offline →
  23505 → el ticket entero se DESCARTA al subir. Fix: trigger server que
  re-asigne en conflicto.
- **M19** `ticket_detail_screen.dart:550-566` — estado rechazado por el
  server (P0001) deja el `ticket_evento` 'cambio_estado' huérfano: bitácora
  que miente ("→ Resuelto" en un ticket cancelado). Fix: generar el evento
  server-side.
- **M20** `ticket_adjuntos_widget.dart:70-104` — adjuntos y FIRMA del
  cliente requieren conexión sincrónica (sin cola de retry): el técnico
  rural no puede capturar la firma en casa del cliente. Fix: reusar el
  patrón `foto_comprobante_service`/UploadResult.
- **M21** `inventario_screen.dart` (8 call-sites) + `equipos_en_baja.dart:103`
  — `inv_movimientos.ocurrido_en` local-naive SIN `.toUtc()` (los consumos
  de tickets sí van en UTC): el historial del serial muestra eventos
  desordenados ±6h. Fix: `.toUtc()` en los 8 sitios.
- **M22** `historial_cambios_widget.dart:397-405,663-666` — 4 agregadores
  usan `IN (SELECT)` en vez de `$.padre_id` del snapshot (contra la regla
  escrita): un DELETE físico de cargo/material borra su rastro del historial
  de la cuota/serial. Fix: `json_extract($.cuota_id/$.serial_id)`.
- **M23** `0026:161-167` — `audit_log` NO es append-only para el súper
  (`super_admin_all FOR ALL` permite UPDATE/DELETE del log; 0102 corrigió
  esto para inv_movimientos). Fix: reemplazar por SELECT+INSERT.
- **M24** (SOSPECHA) `0106:14-20` — el guard `pg_trigger_depth()<2`
  probablemente NO filtra los derivados del consumo (el WHEN se evalúa a
  depth 1): triple card por consumo serializado en el historial. Verificar
  con un INSERT de prueba en staging antes de tocar nada.

**Estructural:**
- **M25** `router.dart:420-421` — `/admin/cuotas` (CuotasAdminScreen) quedó
  SIN ningún punto de entrada en la UI (quitada del menú en BULK 12); en
  desktop/móvil no hay barra de URL → pantalla inalcanzable. ARQUITECTURA.md
  §3 la documenta como activa → drift. Decidir: re-linkear o eliminar.
- **M26** `version.json` + `build-release.ps1:86-89` — `release_notes` NUNCA
  se actualiza (el script solo toca `version`): el banner de la 0.11.0
  mostraría las notas de la 0.8.1. Fix: parámetro -Notes en el script.

### LOW (resumen — detalle en los reportes de agentes)

- Lectura de inventario/tickets sin gate de rol en RLS (cobrador puede leer
  costos/seriales vía REST; intra-tenant, sync rules ya no se lo bajan).
- `cobro_screen.dart:123-153` — C3/C4 (reconexión/pronto pago) usan
  `DateTime.now()` device en vez de `Fmt.hoyNicaragua()` (norma 1b).
- `pagos_repo.dart:114/297` — `cargos_extra.aplicado_en` local-naive (0
  consumidores hoy; deuda de consistencia).
- Retry de batch parcial genera filas audit 'update' fantasma (old==new) —
  fix server: `WHEN (OLD.* IS DISTINCT FROM NEW.*)`.
- `ticket_adjuntos._delete` borra la fila local ANTES del storage.remove →
  binario huérfano sin GC.
- `ticket_materiales_widget` — post-sync el técnico ve "Serial: —" (el
  serial salió del bucket al consumirse). Fix: snapshotear el texto.
- settings sin label en el viewer de audit; tenants/tenant_modulos sin
  rastro (solo súper); doc R10 dice que el guard depth<2 está "en la
  función" (vive en el WHEN de cada trigger).
- Historial de cobros LIMIT 100 sin "cargar más"; multi-cuota solo por
  long-press sin hint; copy técnico en permisos Bluetooth; AuthException
  cruda en set-password/cambiar-password; SuperShell sin OfflineBanner;
  diálogos de anulación del admin sin identificar la entidad.
- `cuotas_list` en adminMode navega a rutas full-screen del cobrador (el
  admin pierde el shell); overflow posible en `_CuotaCompactRow` a 320dp.
- mounted faltante tras await: `cliente_form._cargar`, `_subirLogo`,
  `recibo._imprimir` (2º await), `cobro` ref.read tras dialog.
- Diálogo "Editar pago" del cobrador: monto inválido falla en silencio.
- `geolocator` declarado sin un solo import (plugin nativo compilado al
  pedo); `flutter_web_plugins` usado sin declarar (resuelve por transitiva).
- `_isNewer` silencia versiones con sufijo no numérico ("0.11.0-rc1") —
  documentar convención X.Y.Z estricta.
- `correlativoCompleter` en pagos_repo: código muerto.

---

## Clean — verificado sin problemas

| Categoría | Resultado |
|---|---|
| **Invariantes de dinero (10/10)** | Verificadas una por una con evidencia archivo:línea. Fórmula canónica idéntica en ~14 superficies; `recaudado` siempre `SUM(monto_cordobas) anulado=0`; vuelto SIEMPRE NIO; `monto_original × tasa` exacto por fila; arqueo algebraicamente consistente; total fijo nunca derivado de cuotas; cancelados respetados en todas las superficies |
| **Aislamiento multi-tenant** | CERO fugas cross-tenant (lectura o escritura). `super_admin_all` presente A MANO en todas las tablas nuevas; 0078 valida coherencia de tenant server-side; WITH CHECK correcto en todas las policies de escritura |
| **Edge Functions (6/6)** | Todas validan caller (getUser + rol); admin acotado a SU tenant; service_role solo para auth.admin/rollback; inputs validados; sin secretos en logs. Contratos body/response Dart↔server consistentes campo por campo |
| **SQL SQLite-compatible** | 0 FILTER / casts / RETURNING / ILIKE / ANY / ARRAY en lib/ (greps exactos en el reporte del agente) |
| **TZ Nicaragua** | 48/48 cortes de día con `'-6 hours'`; 0 `date('now')` pelados; Dart espejado con `hoyNicaragua()` (única excepción: C3/C4, LOW) |
| **Schema ↔ queries** | Script: 78 INSERT + 61 UPDATE + 370 SELECT → 0 columnas fantasma en ambas direcciones (33 tablas) |
| **Mirrors vs triggers server** | `calcularEstadoCuota` ≡ 0083; `_deltaCargosExtra` ≡ 0023; cascada de anulación ≡ 0023; cancelar contrato consistente; ticket_materiales sin mirror A PROPÓSITO (correcto) |
| **Rutas GoRouter** | 49 rutas × todas las navegaciones del codebase: TODAS resuelven, ambas variantes de los condicionales verificadas (única excepción: /admin/cuotas, ruta muerta M25) |
| **Change log** | 27 tablas con trigger I/U/D + guard; snapshots con todos los padre_id; labels humanos completos para módulos nuevos; orden COALESCE correcto; sin LIMIT; cliente jamás escribe/borra el log (gap único: cobradores, #9) |
| **Doble-submit en dinero** | cobro (`_enviando` síncrono), anulaciones (idempotentes `WHERE anulado=0`), cancelar contrato (`_procesandoEstado`) — correctos. Solo los 2 forms de alta tienen la ventana (#7) |
| **Imports / providers / alcanzabilidad** | 0 imports rotos; 0 providers huérfanos; 174/177 archivos alcanzables (3 restantes = imports condicionales web, correcto) |
| **Updater** | Comparación de versiones numérica por segmento correcta (0.10.0 > 0.9.0); URLs al repo correcto; tolerante a campos faltantes; timeouts por chunk |
| **Offline UX** | OfflineBanner con debounce en 3 shells (falta súper, LOW); sync gate con progreso real + escape hatches; login con errores humanizados — "el mejor flujo de la app" |
| **Sync rules vs roles** | Gaps todos intencionales y gateados en UI (audit_log/cobrador, incidentes/técnico, inv/cobrador) |
| **dbEpochProvider** | Presente como primera línea en todos los providers globales que tocan ps.db |
| **Storage** | Paths por tenant validados (0019/0022/0088/0104); comprobantes por pago propio del cobrador |
| **Impersonación** | Banner ámbar en todas las pantallas; acciones de campo bloqueadas; re-armado del sync gate al entrar; coherencia server-side |

## Backlog (no bloquea — sin re-flagear lo ya aceptado)

1. Test SQL de humo para zanjar la SOSPECHA M24 (depth guard del consumo).
2. Tests unit para `_isNonRetryable` y el flujo de correlativo con anulado
   removido (los dos HIGH offline son exactamente testeables).
3. Gaps de tests de dinero en los puntos de los findings M1-M3.
4. Unificar semántica del filtro `c.activo` entre dashboard/mora (incluyen
   clientes desactivados) y cuotas_list/clientes (los excluyen).
5. Chips del viewer /admin/audit: agregar tickets/inv_seriales.
6. `kAuditCamposSuperficie` para inv_seriales en el log del cliente.
7. Quick wins UX (del agente UX, priorizados): CTA "Crear contrato" post-alta
   de cliente · saldo total del cliente en el header del detalle · hint
   one-time de multi-cuota · "Cargar más" en historial de cobros.

---

## Sugerencias de plan de ataque (propuesta, espera aprobación)

**Sprint 1 — "que ningún cobro se pierda en silencio"** (los 3 que se
refuerzan entre sí): #1 allowlist del connector + #5 rechazos persistentes
visibles + #2 high-water mark del correlativo. Con M6 (timeout del piso) de
yapa — son 4 cambios chicos y testeables en unit.

**Sprint 2 — dinero exacto**: #3 cargos auto + M1 editar monto + M2 tope de
edición + M3 reversión de descuentos + M8 coma decimal.

**Sprint 3 — guardas y fricción**: #4 (decisión: enforce server o aceptación
documentada) + #6 PopScope + #7 doble-submit + #8 confirmación de cancelar +
#10 trigger de seriales + #9 changelog de cobradores.

**Sprint 4 — pulido**: MEDIUMs de UX/tickets/changelog restantes + LOWs que
Rubén elija.
