# ARQUITECTURA.md — Esquema de la app, módulos, conexiones y recetas de cambio

> **Quién lee esto:** humanos que quieren entender cómo conecta todo, y AIs que
> van a MODIFICAR código. **La meta: poder hacer un cambio sin escanear todo el
> repo** — buscá tu caso en §0 (índice de cambios) y andá directo.
> **Cuándo se actualiza (OBLIGATORIO):** al agregar/quitar un módulo, tabla,
> setting, ruta o conexión entre módulos → actualizar la sección del módulo +
> §0 si aparece un tipo de cambio nuevo. Cambios que no alteran el esquema
> (fixes internos) NO se anotan acá (van en `BITACORA.md`).
> **Documentos hermanos:** `PRODUCTO.md` (qué es la app y por qué) ·
> `BITACORA.md` (estado vivo + historial) · `AGENTS.md` (reglas/proceso) ·
> `Install Steps/` (build/release) · `TESTING.md` (testing manual).

---

## §0. ÍNDICE DE CAMBIOS — "quiero modificar X" → dónde ir

| Quiero... | Andá a |
|---|---|
| Cambiar colores de estados de cuota (mapa/listas) | **Receta R1** |
| Tocar el dashboard del admin (KPIs) | **Receta R2** |
| Cambiar el layout/textos del recibo (térmica + PDF) | **Receta R3** |
| Agregar una columna a una tabla existente | **Receta R4** (cadena de integridad) |
| Agregar una pantalla al admin | **Receta R5** |
| Agregar un setting nuevo | **Receta R6** |
| Cambiar lógica de mora/gracia/vencimiento | **Receta R7** |
| Agregar un reporte (PDF + Excel) | **Receta R8** |
| Cambiar textos/branding del recibo | **Receta R9** |
| Tocar el flow de cobro (¡DINERO!) | **Receta R11** + invariantes de `AGENTS.md` |
| Agregar una tabla/entidad/módulo nuevo | **Receta R10** (checklist completo) |
| Cambiar el menú/sidebar del admin | **Receta R12** |
| Tocar tickets/técnico/inventario/incidentes | §3 módulos opcionales |
| Tocar auth/login/sync gate/impersonación | §2 núcleo + §3 auth/super_admin |
| Buildear y publicar una versión | `Install Steps/1-Publicar-nueva-version.md` |

**Reglas de oro antes de CUALQUIER cambio** (detalle en §6):
SQLite ≠ Postgres (sin `FILTER`/`::casts`/`ILIKE` en `lib/`) · TZ Nicaragua
(`date('now','-6 hours')`, nunca pelado) · server gana (el cliente espeja
triggers, no decide) · toda tabla nueva nace con `tenant_id`+RLS+audit ·
provider global que toca `ps.db` lleva `ref.watch(dbEpochProvider)`.

---

## §1. Visión de capas

```
┌─────────────────────────────────────────────────────────────────────────┐
│ UI  ·  lib/features/<modulo>/*.dart                                       │
│   4 shells por rol: AppShell (cobrador `/`) · AdminShell (`/admin`)       │
│   · SuperShell (`/super`) · TecnicoShell (`/tecnico`)                     │
│   go_router (config/router.dart) decide el shell según el rol             │
└───────────────▲───────────────────────────────────┬──────────────────────┘
                │ ref.watch / ref.read               │ context.go/push
┌───────────────┴───────────────────────────────────▼──────────────────────┐
│ STATE  ·  Riverpod  ·  lib/data/providers/* + *RepoProvider               │
│   StreamProvider (watch SQLite) · FutureProvider.family · StateProvider   │
│   Los globales hacen ref.watch(dbEpochProvider) → se recrean al cambiar DB│
└───────────────▲───────────────────────────────────┬──────────────────────┘
┌───────────────┴─────────────────┐  ┌───────────────▼──────────────────────┐
│ DATA repos · lib/data/repos/*    │  │ DATA services · lib/data/services/*   │
│   PagosRepo, ClientesRepo,       │  │   FotoComprobante, Impresora, Logo,   │
│   CuotasRepo, SettingsRepo →     │  │   Impersonation, ErrorLog, MapTile,   │
│   SQLite local                   │  │   Update, Visitas (Storage/BT/OS/RPC) │
│   SuperAdminRepo → RPC/Edge      │  │                                       │
└───────────────▲──────────────────┘  └───────────────────────────────────────┘
                │ ps.db.watch / .execute / .writeTransaction
┌───────────────┴──────────────────────────────────────────────────────────┐
│ PowerSync (SQLite local) · lib/powersync/{db,schema,connector}.dart        │
│   ps.db = PowerSyncDatabase per-user (sitecsa_{uid}_v27.db)                │
│   schema.dart declara tablas · connector.dart sube la CRUD queue           │
└───────────────▲───────────────────────────────────┬──────────────────────┘
        download │ (sync rules: buckets por rol)      │ upload (CRUD queue)
┌───────────────┴───────────────────────────────────▼──────────────────────┐
│ SUPABASE · Postgres + RLS + Triggers + Edge Functions (Deno) + Storage     │
│   powersync/sync-rules.yaml = QUÉ filas baja cada rol                      │
│   Triggers = fuente de verdad de dinero y audit ("server gana")            │
└───────────────────────────────────────────────────────────────────────────┘
```

**Regla general de quién habla con quién:** la UI nunca llama a Supabase
directo para data operativa (pasa por providers → repos → `ps.db`).
Excepciones legítimas: `SuperAdminRepo` (RPC/Edge, cross-tenant),
`ImpersonationService`, el piso del correlativo de recibo (MAX server con
timeout 5s + high-water mark local `CorrelativoStore` que nunca decrece), y
Storage (fotos/logos/documentos).

---

## §2. El núcleo del wiring (leer antes de tocar auth/sync/rutas)

### `lib/main.dart` — bootstrap y ciclo de sesión
`runZonedGuarded` + `ErrorLogService.init()` capturan todo error → `error_logs`.
`auth.onAuthStateChange`: `signedIn` → `ps.openDatabaseForUser(uid)` +
`ps.connectPowerSync()`; `signedOut` → `disconnectPowerSync()` (la data local
NO se borra). **Las 3 operaciones se serializan con el lock `_pendingOp`**
(fix 2026-06-09 — sin esto, el sync gate quedaba colgado post-forzar-password).
Al cambiar de DB, `onDatabaseSwitched` bumpea `dbEpochProvider` → recrea todos
los providers globales. Workers de fondo con conexión: fotos pendientes,
error_logs, caché del logo. Telemetría `[SYNC-DIAG]` en consola.

### `lib/powersync/` — la capa de datos local
- **`db.dart`**: `ps.db` global per-user; **`_schemaVersion = 27`** vive en el
  nombre del archivo SQLite → bumpearlo fuerza DB fresca para todos.
- **`schema.dart`**: TODA columna de Postgres que la app usa DEBE estar acá.
- **`connector.dart`** (`SupabaseConnector`): drena la CRUD queue con
  upsert/update/delete genéricos vía PostgREST. `esCodigoNoRetryable`
  (pública, testeada — audit 2026-06-11 #1): **ALLOWLIST** de permanentes —
  descarta con aviso SOLO `23xxx`/`42xxx`/`22xxx` (SQLSTATE de 5 chars) y
  `P0001`; TODO lo demás (PGRST*, códigos HTTP, clase 40, desconocidos) se
  **REINTENTA** (un permanente raro bloquea la cola a propósito: preserva el
  dato hasta que se corrija server-side). Cada descarte deja TRIPLE rastro:
  `uploadErrorsController` → SnackBar humanizado en los 4 shells ·
  `RechazosSyncService` → card "Cambios sin sincronizar" del Perfil ·
  `error_logs` con el `opData` completo (forense).

### `lib/config/router.dart` — navegación por rol + gates (EN ORDEN)
1. Sin sesión → `/login` · flow recovery/invite → `/set-password`.
2. **Sync gate** (`/sync-gate`): retiene mientras `!syncReady || rol == null`,
   con grace de 8s y escape hatches (SyncGateScreen).
3. Landing por rol: super → `/super/tenants` (o `/admin` si impersona) ·
   admin/admin_cobranza → `/admin` · tecnico → `/tecnico` · cobrador → `/`.
4. Guards: `tecnico` contenido en `/tecnico/*`; `cobrador` rebotado de
   `/admin`; `admin_cobranza` bloqueado de la lista `soloAdmin`; `/admin/audit`
   y `/admin/pagos` gateados por setting; `/admin/inventario|tickets|incidentes`
   gateados por módulo; `/super/*` solo super_admin sin impersonar.
- Providers del router: `_rolUsuarioProvider` (rol desde `cobradores`) y
  `empresaNombreProvider` (setting `empresa.nombre`).

### Providers transversales (el pegamento — viven en `lib/data/providers/`)
| Provider | Expone | Lo usan |
|---|---|---|
| `dbEpochProvider` | contador de recreación de DB | TODO provider global que toque `ps.db` (primera línea) |
| `cobradorActualProvider` | el usuario logueado (`Cobrador`) | casi todas las pantallas |
| `tenantIdProvider` | tenant EFECTIVO (respeta impersonación) | todo INSERT/UPDATE |
| `appSettingsProvider` | settings tipados del tenant | cobro, cuotas, recibo, mapa, shells, router |
| `syncStatusProvider` / `syncReadyProvider` | estado PowerSync / gate listo | shells, router, OfflineBanner |
| `modulosHabilitadosProvider` | set de módulos ON | menú admin, router, inventario/tickets |
| `impersonatedTenantIdProvider` / `estaImpersonandoProvider` | impersonación | banner, guards de acciones de campo |
| `crudUploadErrorProvider` | errores de upload | SnackBars en shells (humanizados; VER → Perfil en cobrador/técnico) |
| `rechazosSyncProvider` | rechazos de sync persistidos (`RechazosSyncService`, SharedPreferences) | card "Cambios sin sincronizar" del Perfil |

---

## §3. Módulos — qué es cada uno, con qué conecta y por qué

> Formato por módulo: **[H]** = explicación humana · **[AI]** = datos técnicos
> para modificar sin escanear. Las tablas locales = Postgres vía PowerSync.

### Cobro (el corazón) — `lib/features/cobro/`
**[H]** La pantalla donde el cobrador registra un pago en campo (single o
multi-cuota): monto, moneda NIO/USD, método, descuentos/cargos, foto. Conecta
con **recibo** (navega al terminar), **cuotas** (de ahí llega), **settings**
(reglas de cobro) e **inventario de dinero** de toda la app (dashboard,
reportes y contratos leen lo que esto escribe).
**[AI]** `cobro_screen.dart` (UI+validaciones) · cálculo puro en
`data/utils/cobro_calculo.dart` (`aplicado=min(entregado,saldo)`,
`vuelto=entregado−aplicado` SIEMPRE NIO; multi-cuota: vuelto al último pago) ·
persistencia en `data/repositories/pagos_repo.dart`
(`registrarCobro`/`registrarCobroMultiple`: una `writeTransaction` con
`cargos_extra`→`pagos`→`recibos`→mirror de `cuotas` vía `calcularEstadoCuota`).
Correlativo: MAX del server como piso (timeout 5s) + hwm `CorrelativoStore`
+ recálculo en tx. Rutas: `/cobro/:ids` (ids = `id1,id2,...`). Settings:
`cobranza.pago_parcial/pago_adelantado/
descuentos_*/cargo_reconexion_*/comprobante_*/foto_obligatoria`,
`pagos.usd_habilitado/tasa_usd_cordoba/metodo_*`. Tablas: escribe `pagos`,
`recibos`, `cargos_extra`, `cuotas` (mirror). Guard: bloqueado impersonando.
Desde el mega-sprint 2026-06-11: montos con `parseMonto` (coma decimal, M8) ·
PopScope con confirmación de descarte (#6, incluye cargos pendientes) ·
`trg_pagos_guard_cobrador` (0116) enforcea server-side
`cobrador_anula_cobros`/`cobrador_edita_cobros` (#4) · anular un pago
revierte SUS descuentos (`pago_id`, 0115/M3 — cubre TAMBIÉN los manuales).
**Rediseño descuentos 2026-06-12:** el cobro NO crea descuentos ni cargos
— solo los REFERENCIA (botón "Ver descuentos y cargos" → sheet solo-lectura
con `_cargosExistentes` de DB + `_cargosAuto` pendientes). La gestión vive
en el detalle del contrato (admin). Los automáticos (reconexión / pronto
pago) siguen diferidos: se insertan al confirmar vía `cargosAuto` (con
`pago_id`) — abandonar el cobro no deja rastro y anular el pago revierte
sus descuentos. Totales derivados de `_totalesBase` + autos
(`_recalcularTotales`, monto default en la MONEDA activa).
**⚠️ Ver Receta R11 + invariantes de dinero en `AGENTS.md` antes de tocar.**

### Cuotas — `lib/features/cuotas/` (cobrador+admin)
**[H]** La lista de qué hay que cobrar. El cobrador ve SUS cuotas (mora
primero, gate de rango para las futuras). Alimenta a **cobro** (multi-select
→ batch). La pantalla admin `/admin/cuotas` se RETIRÓ (2026-06-11, decisión
Rubén): "anular cuota" salió del producto (terminal-peligroso; la única
anulación masiva es Cancelar contrato) y las cuotas manuales también
(`cuotas.manuales` → `_hidden`; un cobro puntual = "+ Cargo" en el cobro).
**[AI]** `cuotas_list_screen.dart` (vista ÚNICA "Por cobrar", 2026-06-14:
sin tabs ni multi-select. UNA fila por contrato = su cuota MÁS ANTIGUA
pendiente — `_saldoCanonico`/`_cmpAntiguedad` agrupan client-side, desempate
por `periodo` igual que el mapa. Buscador de cliente client-side
(nombre/cédula/teléfono/código, no recrea el stream) + chips de estado +
filtros Cobrador/Zona en adminMode. Botón "Pagar" por fila → `/cobro/:id`
**para admin Y cobrador**; tap en la fila → detalle del cliente
(`/clientes/:id` o `/admin/clientes/:id`). Si el contrato tiene >1 cuota
pendiente, la fila muestra "N cuotas · debe C$total"). Estados PERSISTIDOS:
`pendiente/parcial/pagada/anulada` (CHECK en DB); `en_gracia/vencida/hoy/
proxima` son DERIVADOS en Dart (`data/utils/cuota_estado_visual.dart`
`estadoVisualCuota()`: >gracia→mora · 1..gracia→gracia · 0→hoy ·
futuro≤rango→proxima · futuro>rango→fueraDeRango GRIS "no disponible").
NUNCA escribir `estado='vencida'` (choca el CHECK). Settings:
`cobranza.dias_gracia` (10) / `dias_cuotas_visibles` (5) / `colores_estados`.
Saldo canónico: `monto + COALESCE(cargos_neto,0) − monto_pagado` (igual en
TODAS las pantallas — invariante #10).
**DESCUENTOS y CARGOS del admin (0115 + rediseño 0117/2026-06-12 — ÚNICO
punto de creación, el cobrador no descuenta):** la variación legítima de
una cuota es un cargo en `cargos_extra` — `cuotas.monto` NO se muta
("Editar monto" se RETIRÓ). UI: icono % por cuota en el detalle del
contrato → sheet "Descuentos y cargos de la cuota" (lista TODOS los
orígenes; los nacidos de un pago van solo-lectura con candado) con DOS
botones: "Aplicar descuento" (`DescuentoDialog`: selector Ajuste/Promo +
chips de motivo + preview → `aplicarAjuste(origen:)`, origen
'ajuste'|'promo') y "Cargo extra" (`CargoDialog`: Reconexión/Otro →
`aplicarCargo`, origen 'cobro' SIN pago_id). `cargosDeCuota` lista,
`quitarCargo` revierte (protege `pago_id` y 'liquidacion');
`cargos_count` pinta el ícono. Guard REAL server-side
`trg_cargos_ajuste_guard` (0117: `origen IN ('ajuste','promo')`): setting
super-only `cobranza.ajustes_habilitados` + topes
`ajuste_max_porcentaje/_monto` + motivo + solo descuento_*. CONDONACIÓN
(0117): descuento del 100% → total 0 → cuota `pagada` (espejo en
`cuota_estado.dart`). Una promo multi-mes se aplica cuota por cuota (sin
multi-select; `grupo_promo` reservado). Al anular un pago, sus descuentos
(`cargos_extra.pago_id`) se borran — `trg_pagos_revertir_descuentos` +
mirror en `anularPago` (M3); los cargos del admin (sin pago_id) NO se
tocan. El descuento de origen 'cobro' exige motivo server-side
(`trg_cargos_cobro_motivo_guard`, 0117).

### Clientes — `lib/features/clientes/` · `lib/features/admin/clientes/`
**[H]** El catálogo de clientes del ISP. Detalle COMPARTIDO admin+cobrador:
contratos, visitas, fotos, equipos instalados, historial. Conecta con
**contratos**, **geografía** (picker), **red** (puerto del cliente), **mapa**.
**[AI]** Lista cobrador `clientes_list_screen.dart` · admin
`clientes_admin_screen.dart` (paginada, incluye botón de exportación Excel de todos o filtrados usando `descargarExcel`) · detalle compartido
`cliente_detail_screen.dart` (role detection) · form `cliente_form_screen.dart`
(PopScope guard + `formDirtyProvider`) · `widgets/geo_picker.dart` +
`red_picker.dart`. Tablas: `clientes`, `fotos_cliente` (max 10), `visitas`;
lee geo + `red_puertos`. Historial: `HistorialClienteWidget` (agregador:
cliente + visitas + fotos completas + contratos solo-superficie +
inv_seriales; NO cuotas/pagos — regla de profundidad).

### Contratos — `lib/features/contratos/` · `lib/features/admin/contratos/`
**[H]** El vínculo cliente↔plan que GENERA las cuotas (las crea un trigger
server, nunca el cliente). El detalle es el centro de control: cuotas,
pagos, estado, documento. **Cancelar un contrato liquida sus cuotas** dejando
saldo 0 sin borrar plata cobrada (terminal, no se reactiva y exige obligatoriamente ingresar un motivo
que se guarda en el changelog/cuotas/cargos).
**[AI]** `contrato_detail_screen.dart` + `_header/_cuotas/_pagos/_documento`
· form create-only `contrato_form_screen.dart` (la edición se eliminó) ·
providers en `data/providers/contrato_providers.dart`. Total fijo =
`precio_mensual × duracion_meses` (NUNCA suma de cuotas); indefinidos: solo
recaudado. `_cancelarYLiquidarCuotas`: anula pendientes + descuento de
cancelación a parciales (mirror local). Rutas: `/contratos/:id` y
`/admin/contratos/:id` (ambas existen — detalle compartido).

### Recibo + Impresora — `lib/features/recibo/` · `lib/features/impresora/`
**[H]** El comprobante que el cobrador imprime en su térmica Bluetooth,
100% offline (el logo se cachea en disco). El admin lo ve/reimprime y puede
imprimir por la impresora del sistema (PDF). El layout es configurable por
bloques con zonas (encabezado/cuerpo/pie) desde Ajustes.
**[AI]** `recibo_screen.dart` (preview+acciones) · `recibo_ticket.dart`
(render término ESC/POS **GS v 0 armado a mano** — NO usar `gen.imageRaster`,
fue el bug histórico de la PT-210) · `recibo_pdf.dart` · `recibo_mora.dart`.
Layout: modelo `data/models/recibo_layout.dart` (`kReciboBloquesCatalogo`,
`zonaEfectiva()`, bloque `totales` NO ocultable) ↔ setting `recibo.layout` ↔
editor `admin/settings/recibo_layout_editor.dart` + `recibo_preview.dart`.
Impresora: `data/services/impresora/impresora_service{_io,_web}.dart`
(split por plataforma, `kIsWeb` no-op). Settings: `recibo.titulo/pie_libre/
formato_default_mm/mostrar_*`, `empresa.*`. → **Receta R3/R9.**

### Mapa — `lib/features/mapa/mapa_screen.dart` (compartido 3 shells)
**[H]** Clientes geolocalizados coloreados por estado de cuota (6 estados).
El cobrador queda limitado al rango; el admin tiene "Ver todo". Tiles con
caché en disco → funciona offline. Geolocalización en vivo del usuario en
tiempo real (online/offline) con marcador pulsante y botón de centrado rápido.
**[AI]** `MapTileCache` (`data/services/map_tile_cache.dart`, OSM + 
flutter_map_cache, web cae a red). Colores: `cobranza.colores_estados` vía
`estadoVisualCuota()`. Rutas: `/mapa`, `/admin/mapa`, `/tecnico/mapa`.
Búsqueda multi-campo. Ubicación actual vía `geolocator` con marcador
custom (`UbicacionActualMarker`, en `shared/widgets/mapa_widgets_compartidos.dart`
— público, compartido con el picker de ubicación) y centrado en cámara. La geo
del cobro NO existe (lat/lng null by-design). El **selector de ubicación**
(`shared/widgets/mapa_picker_screen.dart`, lo usan el form de cliente y el de
nodo de red) replica la misma UX: rotación + brújula, pin de ubicación actual,
toggle calle/satélite y atribución (2026-06-14).

### Dashboard admin — `lib/features/admin/dashboard/`
**[H]** El "cómo viene el negocio" del admin: cobros hoy/semana/mes, mora,
top cobradores, distribución de cuotas, sparkline. Lee lo mismo que reportes
— si difieren, hay bug (invariante #10).
**[AI]** `dashboard_admin_screen.dart` + `data/providers/dashboard_providers.dart`
(KPIs como StreamProviders con `dbEpochProvider`). Cortes de día en hora
Nicaragua (UTC-6). KPIs derivan de `pagos` no anulados (`monto_cordobas`).
→ **Receta R2.**

### Reportes — `lib/features/admin/reportes/`
**[H]** 8 reportes + arqueo de caja (con detalle USD valuado a la tasa de
cada cobro), cada uno en PDF y Excel con diálogo nativo de guardado.
El **reporte por cobrador** (2026-06-14) es MULTI-select: el selector
incluye cobrador/admin/admin_cobranza activos + cualquier ejecutor con pagos
en el rango (incl. inactivos), default "Todos". PDF agrupado por cobrador
(por `cobrador_id`, a prueba de homónimos) con subtotal + total general;
Excel en una hoja con columna Cobrador. PDF y Excel salen de la MISMA query
`_rowsPorCobrador` → totales idénticos (invariante #10).
**[AI]** `reportes_admin_screen.dart` (queries + tarjetas) ·
`pdf/reporte_*_pdf.dart` · `excel/reporte_excel.dart` ·
`descarga_archivo.dart` (`file_picker.saveFile`, Windows/Android; web avisa)
· `arqueo_calculo.dart`. Headers Excel↔PDF alineados. Cortes por
`date(fecha_pago)` vs boundary Nicaragua (¡`fecha_pago` es local-naive a
propósito — NO normalizarla a UTC!). **Branding** (2026-06-12): los 9 PDF
llevan el LOGO del tenant en `buildHeaderEstandar` (`pdf/pdf_utils.dart`,
bytes de `logoEmpresaBytesProvider` — cache offline del recibo, helper
`_logoParaReportes`); el Excel lleva header tipográfico (empresa/título/
período via `construirExcelBytes`) porque la lib `excel` no embebe imágenes.
→ **Receta R8.**

### Historial / Home / Perfil (cobrador) — `lib/features/historial/`, `settings/perfil_screen.dart`
**[AI]** `historial_screen.dart` (sus cobros; anular si
`cobranza.cobrador_anula_cobros`) · perfil con config de impresora, cambio de
password y card "Cambios sin sincronizar" (`_RechazosSyncCard`: rechazos de
sync persistidos por `RechazosSyncService`; también en el perfil del técnico).
La landing del cobrador es la lista de Cobros (no hay home aparte).

### Settings — `lib/features/admin/settings/` + `data/repositories/settings_repo.dart`
**[H]** El panel de configuración del tenant (tabs Empresa/Cobranza/Pagos/
Recibos/Avanzado). El tab Avanzado es solo del super (reglas sensibles con
`editable_por='super_admin'` enforced server-side).
**[AI]** **`settings_repo.dart` es LA fuente de verdad** de claves/defaults/
getters (`AppSettings`). UI: `settings_admin_screen.dart` renderiza lo
declarado en `settings_groups.dart`. Editor de layout del recibo acá.
Catálogo completo de claves en **§5**. → **Receta R6.**

### Auth + Sync gate — `lib/features/auth/`
**[AI]** `login_screen` (sin signup público) · `set_password_screen`
(invite/recovery) · `auth_flow_provider.dart` · `sync_gate_screen.dart`
(escape hatches a 120s/180s) · `syncReadyProvider`/`syncGateGraceProvider`
(8s) · `authIdentityProvider` (detección de user-switch). El ciclo
connect/disconnect vive en `main.dart` (§2).

### Super admin — `lib/features/super_admin/` + `data/repositories/super_admin_repo.dart`
**[H]** El panel SaaS de Rubén: tenants, módulos por tenant, miembros
(password/email/rol/eliminar vía Edge Functions), logs de errores, e
**impersonación** (entra a un tenant como su admin, con banner, auditoría
start/end y acciones de campo bloqueadas).
**[AI]** `SuperAdminRepo` va por RPC/Edge (NO SQLite). Impersonación:
`data/services/impersonation_service.dart` (único write-path; escribe
`super_admin_impersonation` + `audit_log`) → `impersonatedTenantIdProvider`
→ `tenantIdProvider` resuelve el tenant efectivo → router lo lleva a
`/admin/*`. Edge Functions (6): `crear-tenant`, `invitar-cobrador`,
`reenviar-invitacion`, `forzar-password-cobrador`, `cambiar-email-cobrador`,
`eliminar-cobrador` + `_shared/` (passwords/auth_errors/response). Patrón:
`callerClient` (RLS) para DB; `service_role` SOLO `auth.admin.*`/rollback.

### Geografía — `lib/features/admin/geografia/`
**[AI]** CRUD jerárquico `departamentos→municipios→comunidades`
(**per-tenant desde 0097**, con RLS + audit). Consumido por `geo_picker.dart`
en clientes. Baja a todos los roles (catálogo).

### Red — `lib/features/admin/red/`
**[AI]** Topología `red_nodos→red_hubs→red_puertos` + asignación
cliente↔puerto (`red_picker.dart`). Baja a todos (el cobrador necesita el
puerto del cliente). Consumidor principal: **incidentes** (derivación de
afectados) y tickets (`puerto_id`).

### Inventario (módulo opcional) — `lib/features/admin/inventario/`
> 0118 (Opción A): `trg_inv_seriales_guard_transicion` — 'baja' es terminal (no se puede
> cambiar de estado una vez dado de baja), instalar exige venir de `en_stock`, un
> instalado no cambia de cliente sin pasar por stock, y se bloquean transferencias tardías
> (no se puede cambiar `ubicacion_id` de un `'instalado'` sin pasarlo antes a `'en_stock'`).
> `inv_movimientos.ocurrido_en` en UTC.
**[H]** Stock del ISP: catálogo, ubicaciones (bodega/custodia del técnico),
seriales cuna-a-tumba y ledger de movimientos. El stock NO es un contador:
se DERIVA (serializado = COUNT de seriales `en_stock`; granel = Σdestino−Σorigen).
**[AI]** `inventario_screen.dart` (tabs) + `equipos_en_baja.dart` +
`data/providers/inventario_alerta_provider.dart` (stock mínimo). Tablas:
`inv_categorias/proveedores/productos/ubicaciones/seriales/movimientos`.
Sync: admin-only (NO baja al cobrador; el técnico baja SOLO su custodia).
Gate: módulo `inventario` (menú+router+**RLS 0114**). Historial:
`HistorialSerialWidget` (serial + movimientos + ticket_materiales).

### Tickets + Técnico + Incidentes (módulo opcional) — `lib/features/admin/tickets/`, `lib/features/tecnico/`, `lib/features/admin/incidentes/`
> 0118 (M19): la generación de eventos del ticket se realiza automáticamente en el
> servidor (`trg_tickets_eventos_auto`), eliminando inserciones client-side de
> creación, asignación y cambios de estado.
> 0116 (M18): el correlativo local del ticket es PROVISORIO — en conflicto el
> server lo re-asigna (`trg_tickets_correlativo`). Transiciones terminales por rol confirman.
**[H]** El ciclo de trabajo de campo: admin crea/asigna → técnico resuelve
offline (avanzar/pausar/resolver, checklist, fotos, comentarios) y consume
materiales de su custodia (descuenta inventario e instala el equipo en el
cliente) → admin cierra. Cortes masivos = incidentes con afectados derivados
de la red. SLA con semáforo que tickea offline y se pausa en espera.
**[AI]** Estados (8) con matriz `kTransicionesTicket` en
`data/utils/ticket_sla.dart` — espejo del trigger server (0103/0105). SLA:
`slaHorasEfectivas` (min tipo/prioridad) + `ticketSlaEstado/Restante`;
`created_at` SIEMPRE se parsea con **`parseTicketWallClock`** (wall-clock por
componentes — un `DateTime.parse` crudo corre el deadline 6h post-sync).
Pausa exacta server-side en `segundos_pausado` (0105). Consumo de materiales:
fila en `ticket_materiales` (auditada) → trigger SECURITY DEFINER (0106) →
`inv_movimientos 'consumo'` + serial `instalado` (derivados a depth 2, no
auditados). Incidentes: alcance nodo|hub|puerto|general (CHECK un_solo_nivel),
afectados por JOIN de la red, `alcance_label` snapshot. Settings:
`tickets.sla_horas_por_prioridad`, `tickets.auto_cierre_dias` (cron 0109).
Sync del técnico: SOLO sus tickets/clientes/custodia — cero dinero.
Historial: `HistorialTicketWidget` (ticket + adjuntos + materiales;
eventos excluidos — la bitácora ya los narra). Rol `admin_tickets`: DIFERIDO
(no se ofrece). Gate: módulo `tickets` (menú+router+RLS 0114).

### Audit / Change log — `lib/features/admin/audit/` + `shared/widgets/historial_cambios_widget.dart`
> 0116: `cobradores` ya tiene changelog (#9 — botón Historial en Personal) ·
> `audit_log` es append-only TAMBIÉN para el súper (M23) · la función genérica
> ignora UPDATEs no-op (sin filas fantasma por retries) · los agregadores leen
> `$.padre_id` del snapshot (M22).
**[H]** Toda entidad editable tiene su historial (quién/cuándo/qué) accesible
desde su pantalla. Lo genera el SERVER (trigger genérico), nunca el cliente.
**[AI]** Trigger `audit_changelog_trg` (AFTER I/U/D, guard
`pg_trigger_depth()<2`) en las 27 tablas operativas → `audit_log`
(append-only; baja solo a admin/admin_cobranza/super). Widgets: Simple
(`HistorialCambiosWidget(tabla, registroId)`) y Agregadores
(`HistorialCuotaWidget`/`Cliente`/`Serial`/`Ticket`) que unen hijas por el
`$.padre_id` del **snapshot JSON** (no `IN (SELECT)`) y ordenan por
`COALESCE(ocurrido_en, created_at)`. Regla de profundidad: hijas DIRECTAS;
contenedoras solo superficie (`kAuditCamposSuperficie`); excepción única:
recibo en el log de la cuota. Config de campos/labels:
`data/utils/audit_changelog.dart` (registrar TODA entidad nueva acá).
Viewer global `/admin/audit` (gateado por `cobranza.audit_visible_admin`).

### Shared / Shells
**[AI]** `shared/widgets/`: `offline_banner` (debounce 3s/700ms + red
inestable), `sync_gate_screen`, `impersonation_banner`, `update_banner`
(auto-update IN-APP: descarga con progreso vía `update_service` + instalador
del sistema con open_filex; GitHub Releases `latest` es el endpoint; la firma
del APK usa el keystore local `sitecsa-release.jks` — ver 0-Setup §3b),
`descuento_dialog` (EL diálogo de descuento: el admin graba ajuste/promo
desde el sheet de la cuota) · `cargo_dialog` (reconexión/otro del admin,
graba vía `aplicarCargo`),
`historial_cambios_widget`, `empty_state`, `skeleton`, etc.
Shells: `features/shell/app_shell.dart` (cobrador, bottom-nav) ·
`features/admin/shell/admin_shell.dart` (rail/drawer + `_MenuItem` con gates
— Receta R12) · `super_shell.dart` · `tecnico/tecnico_shell.dart`.
`global_search_delegate.dart` (búsqueda global del admin).

---

## §4. Flujos críticos end-to-end (cómo viaja la data)

### (a) Cobro de campo: offline → sync → trigger → reportes
1. `/cobro/:ids` → `PagosRepo.registrarCobro` escribe TODO local en una
   transacción (pagos+recibos+cargos+mirror de cuota) → UI instantánea.
2. → `/recibo/:id` → térmica Bluetooth (offline).
3. Con red: `connector.uploadData` sube la cola → triggers server
   (`recalcular_cuota_desde_pagos`, `cargos_extra_actualizar_neto`,
   `audit_changelog_trg`) recalculan la VERDAD → baja corregida por sync.
4. Dashboard/reportes del admin leen `pagos`/`cuotas` ya consolidados.

### (b) Generación de cuotas: crear contrato → trigger server genera las
cuotas del período → bajan al cobrador asignado (bucket `por_cobrador`) y al
admin. Cron diario (06:05 UTC = medianoche Nicaragua) genera
`notificaciones_mora`.

### (c) Anular pago: `PagosRepo.anularPago` marca `anulado=1` (pago+recibo) +
mirror local de la resta → trigger server restaura la cuota autoritativo.
El pago anulado SE PRESERVA. Las sync rules del cobrador filtran anulados.

### (d) Change log: write local → sync → trigger server escribe `audit_log`
→ baja al admin → widget. Offline: el dato operativo se ve YA; la entrada
del historial aparece al sincronizar, con su hora real (`ocurrido_en`
device-time en UTC).

### (e) Onboarding de tenant: `/super/tenants` → Edge `crear-tenant`
(tenant + módulos + admin con password server-side, rollback completo) →
el admin entra por `/login` → landing `/admin`.

### (f) Ticket con materiales: admin crea (correlativo T-00001) → técnico
resuelve offline → consume serial de su custodia → sync → trigger 0106
descuenta inventario e instala en el cliente → admin cierra.

---

## §5. Catálogo de settings (fuente de verdad: `settings_repo.dart`)

> Editar un setting NO requiere migración salvo que necesite seed/default
> server-side. La tabla `settings` sincroniza por `SELECT *` → una clave
> nueva llega sola. Súper-only se enforcea server-side (`editable_por`).

| Clave | Default | Controla | Consumido por |
|---|---|---|---|
| `empresa.nombre/direccion/telefono/ruc/whatsapp/logo_path` | "" | branding | recibo, reportes, AppBar |
| `cobranza.dias_gracia` | 10 | vencido→mora | estados de cuota, mora, dashboard |
| `cobranza.dias_cuotas_visibles` | 5 | rango de futuras del cobrador | listas, mapa, cobro |
| `cobranza.colores_estados` | 🔴🟠🔵🟣 | colores mora/gracia/hoy/próxima | mapa, listas, badges (R1) |
| `cobranza.pago_parcial` / `pago_adelantado` | true | reglas de cobro (súper-only) | cobro |
| `cobranza.cobrador_anula_cobros` / `cobrador_edita_cobros` | false | permisos campo (súper-only) | historial, pagos |
| `cobranza.cobrador_edita_fecha` | false | fecha editable en cobro | cobro |
| `cobranza.ajustes_habilitados` + `ajuste_max_porcentaje/_monto` | false / 50 / 0 | descuentos del admin: ajustes y promos (súper-only; grupo "Ajustes de cuota (admin)"; guard 0115/0117) | DescuentoDialog |
| `cobranza.cargo_reconexion_habilitado` + `monto_reconexion` | false | cargo auto reconexión (súper-only) | cobro |
| `cobranza.comprobante_habilitado` + `foto_obligatoria` | false | foto del comprobante (súper-only) | cobro |
| `cobranza.pantalla_pagos` | false | habilita `/admin/pagos` (súper-only; el súper TAMBIÉN la respeta) | menú+router |
| `cobranza.audit_visible_admin` | false | habilita `/admin/audit` al admin (súper-only) | menú+router |
| `pagos.metodo_transferencia/metodo_tarjeta` | false | métodos extra | cobro |
| `pagos.usd_habilitado` + `tasa_usd_cordoba` | true / 36.50 | USD y tasa | cobro, arqueo |
| `recibo.layout` | catálogo | bloques/zonas/tamaños del recibo | recibo (pantalla/PDF/térmica) (R3) |
| `recibo.titulo/pie_libre/formato_default_mm/mostrar_adeudado/mostrar_cedula` | varios | textos/formato del recibo | recibo |
| `recibo.mostrar_descuentos` + `mostrar_motivo_descuentos` | true | desglose de descuentos/cargos en el bloque `cuota` (sub-toggles del diseñador) | recibo (pantalla/PDF/térmica) |
| `cuotas.descuento_pronto_pago(+_tipo)` | 0 | descuento automático por pago antes del vencimiento (grupo "Pronto pago" en Avanzado) | cobro |
| `tickets.sla_horas_por_prioridad` | {urgente:1,alta:2,media:6,baja:12} | SLA por prioridad | tickets (SLA efectivo = min con el del tipo) |
| `tickets.auto_cierre_dias` | 0 (off) | auto-cierre de resueltos | cron 0109 |
| `audit.campos_visibles` | {} | campos visibles del historial por tabla | historial widgets |

Ocultos/aspiracionales (NO implementados): `cobranza.modo_ruta`,
`caja_chica`, `pantalla_notificaciones` (parqueados por decisión).
Retirados (seed preservado, en `_hidden`): `cuotas.editar_monto` (Sprint 2)
· `cuotas.manuales` (2026-06-11, junto con `/admin/cuotas`) ·
`cobranza.descuentos_habilitados/descuento_tipo/descuento_max_*`
(2026-06-12: el cobrador no descuenta — todo va por ajustes del admin).

---

## §R. RECETAS de cambios comunes (paso a paso, sin escanear)

### R1 — Cambiar colores de estados de cuota
**Archivos:** `lib/data/utils/cuota_estado_visual.dart` (enum + 
`ColoresEstados.defaults`/`fromJson` + `estadoVisualCuota()`) · getter en
`settings_repo.dart` (`coloresEstados`) · picker en
`features/admin/settings/` (sección "Colores de estados de cuota").
**Afecta:** mapa, lista de cobros, cuotas admin, detalle de contrato, lista
de clientes — TODOS leen el mismo helper; cambiar el helper cambia todo.
**Cuidado:** el parseo es defensivo (color inválido → default); los 6 estados
visuales incluyen `fueraDeRango` (gris "no disponible") y `sinDeuda` — no
agregar estados sin actualizar el switch exhaustivo de Dart en los consumers.

### R2 — Modificar el dashboard del admin
**Archivos:** `features/admin/dashboard/dashboard_admin_screen.dart` (UI) ·
`data/providers/dashboard_providers.dart` (KPIs).
**Cuidado:** cortes de día/mes SIEMPRE con boundary Nicaragua (patrón
`DateTime.now().toUtc().subtract(Duration(hours: 6))` o
`date('now','-6 hours')` en SQL); los KPIs deben seguir dando idéntico a
reportes (invariante #10); providers nuevos → `ref.watch(dbEpochProvider)`.

### R3 — Layout/bloques del recibo
**Archivos:** `data/models/recibo_layout.dart` (catálogo + zonas) · editor
`features/admin/settings/recibo_layout_editor.dart` + `recibo_preview.dart` ·
renderers `features/recibo/recibo_screen.dart` (pantalla), `recibo_ticket.dart`
(térmica), `recibo_pdf.dart` (PDF) — los 3 iteran el MISMO layout.
**Cuidado:** bloque `totales` no es ocultable; bloques nuevos se agregan al
final automáticamente (fromRaw completa faltantes); bloques desconocidos se
descartan (backward-compatible). Térmica: GS v 0 manual, no tocar el método
de raster.

### R4 — Agregar una columna a una tabla existente (CADENA DE INTEGRIDAD)
**Pasos EN ORDEN (saltarse uno = horas de debugging):**
1. Migración SQL `supabase/migrations/NNNN_*.sql` (`ALTER TABLE ... ADD COLUMN`)
   → correrla en Dashboard → verificar en Table Editor.
2. `lib/powersync/schema.dart`: declarar la `Column.text/real/integer`.
3. `lib/powersync/db.dart`: **bumpear `_schemaVersion`**.
4. **Redeployar sync rules** en PowerSync Dashboard → verificar "Active"
   (con `SELECT *` las columnas nuevas entran solas, pero el redeploy es
   obligatorio para que PowerSync las vea).
5. Dart: modelo (`fromRow`), INSERTs (¡incluir columnas denormalizadas — los
   triggers NO corren en SQLite!), queries.
6. App reiniciada desde cero (`q` + `flutter run`).

### R5 — Agregar una pantalla al admin
1. Pantalla en `lib/features/admin/<modulo>/`.
2. Ruta en `config/router.dart` (dentro del ShellRoute admin; rutas
   específicas ANTES que las dinámicas `:id`).
3. Item en `_adminMenu` de `features/admin/shell/admin_shell.dart` (con
   `adminOnly`/`settingKey`/`moduloKey` según corresponda — R12).
4. Si es admin-only: agregarla a la lista `soloAdmin` del router (guard de
   `admin_cobranza`). Si depende de módulo/setting: gate en router también.
5. Si tiene form editable: PopScope + `formDirtyProvider`.

### R6 — Agregar un setting nuevo
1. Getter tipado en `AppSettings` (`settings_repo.dart`) con
   `settingValue<T>(_map, 'categoria.clave', default)`.
2. Entrada en `settings_groups.dart` (la pantalla la renderiza sola). Si es
   sensible → grupo Avanzado (súper-only).
3. (Opcional) seed con migración (`INSERT INTO settings ... ON CONFLICT DO
   NOTHING`; `editable_por='super_admin'` si es súper-only — el server lo
   enforcea).
4. Consumir con `ref.watch(appSettingsProvider).miGetter`. Sin migración de
   schema ni redeploy de sync (settings ya sincroniza `SELECT *`).

### R7 — Lógica de mora/gracia/vencimiento
**Archivos:** `cuota_estado_visual.dart` (`estadoVisualCuota()` — la
derivación visual) · `cuota_estado.dart` (`calcularEstadoCuota` — espejo del
trigger de dinero, NO confundir) · server: funciones de mora con
`SET timezone='America/Managua'` (patrón 0087).
**Cuidado:** la lógica tiene COPIA server-side (triggers/cron de mora) — si
cambiás el criterio en Dart, migración para el server también. TZ: siempre
`-6 hours`. NUNCA persistir estados derivados.

### R8 — Agregar un reporte
1. Tarjeta + query en `reportes_admin_screen.dart` (filtrar `anulado=0`,
   cortes con boundary Nicaragua).
2. PDF en `reportes/pdf/reporte_<nombre>_pdf.dart` (patrón de los existentes:
   aceptar `Uint8List? logoBytes`, crear `pw.MemoryImage` UNA vez y pasarlo a
   `buildHeaderEstandar(logo:)`; el caller le pasa `_logoParaReportes(ref)`).
3. Excel en `reportes/excel/reporte_excel.dart` (headers IDÉNTICOS al PDF) +
   registrar el tipo en `_tituloReporte`/`_periodoExcel`/`_hojaNombre`.
4. Descarga vía `descarga_archivo.dart`. Recaudado = `SUM(monto_cordobas)` no
   anulados — jamás sumar entregado/vuelto.

### R9 — Textos/branding del recibo
Settings `recibo.titulo/pie_libre` + `empresa.*` (sin código). Cambios de
formato → R3. ESC/POS: ojo con caracteres especiales fuera de code-page.

### R10 — Agregar una tabla/entidad/módulo nuevo (checklist COMPLETO)
1. **Migración**: tabla con `id` UUID PK + `tenant_id` NOT NULL FK + (si se
   edita offline) `ocurrido_en`; índice por tenant.
2. **RLS**: `ENABLE ROW LEVEL SECURITY` + policies por
   `current_tenant_id()` (+ helper de rol) + **`super_admin_all` A MANO**
   (las tablas nuevas NO la heredan del do$$ de 0026) + si es de módulo
   opcional: `tenant_tiene_modulo()` en las write policies (patrón 0114).
3. **Audit**: trigger `AFTER INSERT OR UPDATE OR DELETE ... EXECUTE FUNCTION
   audit_changelog_trg()` (el guard depth<2 ya está en la función).
4. **Cadena local**: `schema.dart` + bump `_schemaVersion` + sync-rules.yaml
   (¿qué buckets/roles la bajan?) + redeploy de sync rules.
5. **Dart**: modelo/repo/pantalla (R5) + registrar la entidad en
   `data/utils/audit_changelog.dart` (labels + campos visibles) + historial
   accesible desde su pantalla (Simple o Agregador — si es hija de un
   agregador existente, sumarla a su query respetando la regla de
   profundidad).
6. **Verificación**: queries de `information_schema`/`pg_trigger` post-deploy
   (nunca asumir que la migración corrió).

### R11 — Flow de cobro (DINERO — máxima precaución)
**Archivos:** `cobro_screen.dart` (UI) · `cobro_calculo.dart` (matemática
pura — los invariantes viven acá) · `pagos_repo.dart` (transacción+mirror).
**Antes de mergear:** correr `flutter test` (suite de `pagos_repo`, 14 tests)
y tras el deploy `supabase/tests/invariantes_dinero.sql` (0 violaciones).
**Cuidado:** vuelto SIEMPRE NIO · tasa snapshot al momento del cobro ·
multi-cuota: vuelto al último pago · NUNCA tocar `monto_pagado` a mano (lo
mantiene el trigger; el cliente solo espeja con `calcularEstadoCuota`) ·
cargos automáticos nuevos requieren actualizar también el trigger server.

### R12 — Menú/sidebar del admin
**Archivo:** `features/admin/shell/admin_shell.dart` → lista `_adminMenu`.
`_MenuItem(icon, label, path, {adminOnly, superAdminOnly, settingKey,
superRespetaSetting, moduloKey, children})`. Gates: `adminOnly` excluye a
`admin_cobranza`; `settingKey` muestra solo con el setting ON (por default el
súper lo ve igual, salvo `superRespetaSetting: true`); `moduloKey` exige el
módulo del tenant (el súper también lo respeta). Badges de alerta en
`_menuLeading` (tickets en riesgo, stock bajo).
**Cuidado:** el menú y el ROUTER deben quedar consistentes (mismo gate en
ambos — el menú oculta, el router rebota).

---

## §6. Reglas de wiring que NO se deben romper

| Regla | Dónde se enforcea | Romperla = |
|---|---|---|
| RLS por tenant | policies `current_tenant_id()` + sync rules | fuga cross-tenant |
| Server gana | triggers Postgres = verdad de dinero/estado | saldos divergentes |
| Audit append-only | trigger genérico; sin DELETE jamás | pérdida de trazabilidad |
| Invariantes de dinero (10) | `cobro_calculo`/`pagos_repo`/triggers/`invariantes_dinero.sql` | plata descuadrada |
| Cadena DB↔schema↔sync↔version | R4 | columnas que no sincronizan |
| `dbEpochProvider` en globales | cada StreamProvider global | streams de la DB vieja tras user-switch |
| Denormalizar `cobrador_id` en INSERTs | repos | el cobrador no baja sus propias filas |
| SQLite ≠ Postgres | grep `FILTER/::/ILIKE/RETURNING` en lib/ = 0 | crash en runtime local |
| TZ `-6 hours` en límites de día | todo `date('now')`/`julianday('now')` | mora corrida 1 día de noche |
| Estados derivados nunca persistidos | CHECK en `cuotas.estado` | constraint violation |
| Timestamps: `ocurrido_en` en UTC; `fecha_pago`/`tickets.created_at` local-naive A PROPÓSITO | convención (ver AGENTS.md backlog L1) | bucketing de reportes roto |
| Módulos opcionales: gate en menú+router+RLS (0114) | `_MenuItem`+redirect+policies | inconsistencia comercial |

---

## §7. Mapa rápido archivo → responsabilidad (los que más se tocan)

| Archivo | Responsabilidad |
|---|---|
| `lib/main.dart` | bootstrap, auth listener, connect/disconnect PowerSync, workers |
| `lib/config/router.dart` | rutas + redirect con TODOS los gates |
| `lib/powersync/db.dart` | `ps.db` per-user, `_schemaVersion`, locks |
| `lib/powersync/schema.dart` | tablas/columnas del SQLite local |
| `lib/powersync/connector.dart` | upload de la CRUD queue + clasificación de errores |
| `powersync/sync-rules.yaml` | buckets por rol (qué baja a quién) |
| `lib/data/repositories/pagos_repo.dart` | TODO el dinero (cobrar/anular/editar + mirrors) |
| `lib/data/repositories/settings_repo.dart` | claves/defaults/getters de settings |
| `lib/data/utils/cobro_calculo.dart` | matemática del cobro (invariantes) |
| `lib/data/utils/cuota_estado.dart` | espejo Dart del trigger de dinero |
| `lib/data/utils/cuota_estado_visual.dart` | estados visuales + colores |
| `lib/data/utils/ticket_sla.dart` | SLA, transiciones, `parseTicketWallClock` |
| `lib/data/utils/audit_changelog.dart` | registro de entidades del change log |
| `lib/data/services/imagen_compresion.dart` | compresión client-side ANTES de todo upload a Storage (isolate; Windows ignora `imageQuality` del picker) |
| `lib/features/admin/shell/admin_shell.dart` | menú admin + gates |
| `lib/features/shared/widgets/historial_cambios_widget.dart` | los 5 widgets de historial |
| `supabase/functions/_shared/*.ts` | helpers de las 6 Edge Functions |
| `supabase/tests/invariantes_dinero.sql` | las 14 verificaciones de dinero |

_Verificado contra: schema v27 · migraciones 0001→0115 · 6 Edge Functions ·
audits 2026-06-09 y 2026-06-11 (Sprints 1-2 aplicados)._
