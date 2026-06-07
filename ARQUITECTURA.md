# ARQUITECTURA.md

Mapa de **módulos** y **cómo se interconectan** en Cobranza ISP. Objetivo: que
cualquiera (humano o IA) que reabra el repo entienda la estructura y el flujo de
datos sin leer todo el código.

> Este doc es el **"cómo se conecta"** (wiring). Para REGLAS/invariantes y el
> catálogo de features, la fuente de verdad es **`CLAUDE.md`** (secciones "Mapa
> funcional", "Tablas principales", "Invariantes de dinero", "Audit log"). Para
> el estado real del proyecto, **`ESTADO-APP.md`** / **`REPORTE-SESION.md`**.
> Para columnas exactas de cada tabla, **`lib/powersync/schema.dart`**.

---

## Índice

1. [Visión de capas](#1-visión-de-capas)
2. [El núcleo del wiring (main.dart + PowerSync + router)](#2-el-núcleo-del-wiring)
3. [Módulos funcionales](#3-módulos-funcionales)
4. [Flujos de datos críticos end-to-end](#4-flujos-de-datos-críticos-end-to-end)
5. [Reglas de wiring que NO se deben romper](#5-reglas-de-wiring-que-no-se-deben-romper)
6. [Mapa rápido archivo → responsabilidad](#6-mapa-rápido-archivo--responsabilidad)

---

## 1. Visión de capas

```
┌─────────────────────────────────────────────────────────────────────────┐
│ UI  ·  lib/features/<modulo>/*.dart                                       │
│   ShellRoute por rol: AppShell (cobrador) · AdminShell · SuperShell       │
│   go_router (config/router.dart) decide qué shell según el rol            │
└───────────────▲───────────────────────────────────┬──────────────────────┘
                │ ref.watch / ref.read               │ context.go/push (navegación)
┌───────────────┴───────────────────────────────────▼──────────────────────┐
│ STATE  ·  Riverpod  ·  lib/data/providers/*  +  *RepoProvider             │
│   StreamProvider (watch SQLite) · FutureProvider.family · StateProvider   │
│   Casi todos hacen ref.watch(dbEpochProvider) para recrearse al cambiar DB│
└───────────────▲───────────────────────────────────┬──────────────────────┘
                │                                     │
┌───────────────┴─────────────────┐  ┌───────────────▼──────────────────────┐
│ DATA repos · lib/data/repos/*    │  │ DATA services · lib/data/services/*   │
│   PagosRepo, ClientesRepo,       │  │   FotoComprobante, Impresora, Logo,   │
│   CuotasRepo, SettingsRepo →     │  │   Impersonation, ErrorLog, MapTile,   │
│   leen/escriben SQLite local     │  │   Update, Visitas, ExternalActions    │
│   SuperAdminRepo → RPC/Edge (no  │  │   (Storage, Bluetooth, OS, RPC)       │
│   toca SQLite)                   │  │                                       │
└───────────────▲──────────────────┘  └───────────────────────────────────────┘
                │ ps.db.watch / .execute / .writeTransaction
┌───────────────┴──────────────────────────────────────────────────────────┐
│ PowerSync (SQLite local)  ·  lib/powersync/{db,schema,connector}.dart      │
│   `ps.db` = PowerSyncDatabase per-user (sitecsa_{uid}_v16.db)              │
│   schema.dart declara las tablas locales · connector.dart drena la CRUD    │
│   queue → Supabase REST                                                     │
└───────────────▲───────────────────────────────────┬──────────────────────┘
        download │ (sync rules: buckets por rol)      │ upload (CRUD queue)
┌───────────────┴───────────────────────────────────▼──────────────────────┐
│ SUPABASE  ·  Postgres + RLS + Triggers + Edge Functions (Deno) + Storage   │
│   powersync/sync-rules.yaml define QUÉ filas baja cada rol                 │
│   Triggers = fuente de verdad de dinero y audit (server gana)             │
└───────────────────────────────────────────────────────────────────────────┘
```

**Quién habla con quién (regla general):**
- La **UI nunca llama a Supabase directo** para data operativa → pasa por
  providers → repos/services → `ps.db` (SQLite). Excepción: `SuperAdminRepo` y
  los Edge Functions (operaciones cross-tenant / auth admin) que sí van directo
  a Supabase vía RPC/`functions.invoke`.
- **Escrituras operativas** = `ps.db.execute` / `writeTransaction` → PowerSync
  las encola → `connector.dart` las sube → triggers de Postgres aplican efectos
  reales → la data corregida vuelve a bajar por sync rules.
- **Lecturas** = `ps.db.watch(SELECT ...)` envuelto en un `StreamProvider`.

---

## 2. El núcleo del wiring

### `lib/main.dart` — bootstrap y ciclo de vida de sesión
- `runZonedGuarded` + `ErrorLogService.init()` capturan los 3 tipos de error
  (FlutterError / PlatformDispatcher / zone) → tabla `error_logs`.
- Crea el **`ProviderContainer` a mano** (no dentro de `ProviderScope`) para que
  el listener de auth pueda mutar `authIdentityProvider`.
- **`auth.onAuthStateChange`** maneja el ciclo: en `signedIn`/`initialSession`
  → `ps.openDatabaseForUser(uid)` + `ps.connectPowerSync()`; en `signedOut`
  → `disconnectPowerSync()` (la data local NO se borra; el sync gate la protege).
- Telemetría `[SYNC-DIAG]` + captura al `ErrorLogService` en cada paso (debug del
  bug histórico "sync gate stuck").
- Al cambiar de DB (`ps.onDatabaseSwitched`) bumpea **`dbEpochProvider`**, que
  recrea TODOS los providers globales bound a `ps.db` (mecanismo central para no
  quedar con streams de la DB anterior).
- Worker de fondo: cuando hay conexión, sube fotos pendientes
  (`FotoComprobanteService.sincronizarPendientes`), reintenta error_logs, cachea
  el logo de empresa para impresión offline.

### `lib/powersync/` — la capa de datos local
- **`db.dart`**: `ps.db` global (se recrea per-user). `_schemaVersion = 16` está
  en el nombre del archivo SQLite → bumpearlo fuerza DB fresca para todos.
  `openDatabaseForUser` serializa con un `Completer` lock.
- **`schema.dart`**: declara cada tabla local y sus columnas/índices. Toda
  columna de Postgres que la app lee/escribe DEBE estar acá.
- **`connector.dart`** (`SupabaseConnector`): `fetchCredentials` (token Supabase)
  + `uploadData` (drena la CRUD queue vía `supabase.from(table).upsert/update/
  delete`). Errores no-retryables (P0001 triggers, 23xxx constraints, 4xxxx) se
  loguean y se **saltan** (no bloquean el sync) + se emiten a `uploadErrorsController`.

### `lib/config/router.dart` — navegación por rol + gates
- `routerProvider` (GoRouter). Tres `ShellRoute`: **AppShell** (cobrador, `/*`),
  **AdminShell** (`/admin/*`), **SuperShell** (`/super/*`).
- Providers locales clave del router:
  - `_rolUsuarioProvider` → `SELECT rol FROM cobradores WHERE id = uid` (decide
    el landing y los guards por rol).
  - `empresaNombreProvider` → `settings 'empresa.nombre'` (lo lee el reporte).
- **Gates en orden** (función `redirect`): no-logueado → `/login`; flow
  recovery/invite → `/set-password`; **sync gate** (`/sync-gate`) mientras
  `!syncReady || rol == null` y sin grace timeout; luego landing por rol;
  guards `soloAdmin` para `admin_cobranza`; `/super/*` solo super_admin;
  impersonación mueve al super_admin entre `/super/*` y `/admin/*`.

---

## 3. Módulos funcionales

> Convención: "lee/escribe" = tablas SQLite locales (= Postgres vía PowerSync),
> salvo que se aclare "RPC"/"Edge"/"Storage".

### Cobro (campo, móvil) — `lib/features/cobro/cobro_screen.dart`
- **Providers**: `cobradorActualProvider`, `tenantIdProvider`,
  `fotoComprobanteServiceProvider`, `pagosRepoProvider`, `appSettingsProvider`
  (cargos auto reconexión / descuento pronto pago), `estaImpersonandoProvider`
  (bloquea cobro si super_admin impersona).
- **Repos/services**: `PagosRepo.registrarCobro` / `registrarCobroMultiple`
  (transacción local: `cargos_extra` → `pagos` → `recibos` → mirror local de
  `cuotas.monto_pagado/estado/cargos_neto`); `FotoComprobanteService` (foto a
  Storage `comprobantes-pago/...`).
- **Tablas**: escribe `pagos`, `recibos`, `cargos_extra`, `cuotas` (mirror).
- **Interconexiones**: navega con `context.pushReplacement('/recibo/{id}')` →
  módulo **recibo** → **impresora**. El correlativo del recibo se calcula
  consultando el MAX en el server (Supabase REST directo) porque las sync rules
  excluyen recibos anulados del cobrador. El mirror local de `cuota` espeja el
  trigger server `recalcular_cuota_desde_pagos` vía `calcularEstadoCuota`
  (`data/utils/cuota_estado.dart`). Sus pagos los leen **dashboard** y **reportes**.

### Cuotas — `lib/features/cuotas/cuotas_list_screen.dart` (cobrador y admin) · `lib/features/admin/cuotas/cuotas_admin_screen.dart`
- **Providers**: `cuotasFiltroProvider` (StateProvider de filtros),
  `cuotas_repo`/streams locales, `cobradorActualProvider`.
- **Tablas**: lee `cuotas` (+ join lógico con `clientes`/`contratos`/`planes`).
- **Estado**: `pendiente/parcial/pagada/anulada` son los persistidos; `vencida`
  y `en_gracia` se **derivan en Dart** desde `fecha_vencimiento` + días de gracia
  (NUNCA se escriben). Multi-select (long-press) → `/cobro/id1,id2,...` (batch).
- **Interconexiones**: entrega cuotas al módulo **cobro**; `HistorialCuotaWidget`
  agrega su timeline (cuota + pagos + recibos).

### Clientes — cobrador: `lib/features/clientes/*` · admin: `lib/features/admin/clientes/*`
- **Providers**: paginados (`clientes_repo`), `tenantIdProvider`, `formDirtyProvider`.
- **Repos/services**: `ClientesRepo`, `FotoGalleryWidget` + `fotos_cliente`,
  `VisitasService` (`visitas`), `ExternalActions` (WhatsApp/llamar/mapas).
- **Tablas**: lee/escribe `clientes`, `fotos_cliente`, `visitas`; lee
  `comunidades`/`municipios`/`departamentos` (geo).
- **Interconexiones**: el detalle (`cliente_detail_screen.dart`, compartido
  admin+cobrador) muestra **contratos** del cliente y abre el módulo
  **contratos**; `HistorialClienteWidget` agrega cliente + visitas + fotos +
  contratos (solo superficie). Geo via `geo_picker.dart` → módulo **geografía**.

### Contratos — `lib/features/contratos/*` (detalle) · `lib/features/admin/contratos/*` (CRUD)
- **Providers**: `contrato_providers.dart` (streams del contrato y sus cuotas),
  `tenantIdProvider`.
- **Tablas**: lee/escribe `contratos`; lee `planes`, `cuotas`, `pagos`.
- **Interconexiones**: al crear contrato, un **trigger server** genera las
  `cuotas` mensuales (server gana — el cliente no las crea). El detalle
  (`contrato_detail_*.dart`) muestra cuotas (multi-select → cobro), pagos, cambio
  de estado, documento (Storage), e historial. El "total fijo / recaudado /
  pendiente" sigue los invariantes de dinero de CLAUDE.md.

### Planes — `lib/features/admin/planes/planes_admin_screen.dart`
- **Tablas**: CRUD de `planes` (solo admin, no admin_cobranza).
- **Interconexiones**: consumido por **contratos** (precio_mensual define el total
  fijo) y mostrado en **cuotas**/recibo. Tiene change log propio (migración 0076).

### Recibo — `lib/features/recibo/*` (recibo_screen, recibo_ticket, recibo_pdf, recibo_mora)
- **Tablas**: lee `recibos` + `pagos` + `cuotas`/`clientes` para renderizar.
- **Repos/services**: `ImpresoraService` (`imprimirImagen`), `LogoCacheService`
  (logo offline), reimpresión actualiza `recibos.reimpresiones`.
- **Interconexiones**: lo abre **cobro** post-pago. `ReciboTicket` se captura a
  imagen y se manda al módulo **impresora**; alternativa `_imprimirSistema`
  (PDF nativo). Layout configurable desde **settings** (`recibo_layout`).

### Impresora — `lib/features/impresora/impresora_setup_screen.dart` + `lib/data/services/impresora/*`
- **Service**: `ImpresoraService` con split por plataforma
  (`impresora_service_io.dart` Bluetooth térmico / `..._web.dart` no-op),
  `impresoraServiceProvider`, estado en `impresora_provider.dart`.
- **Interconexiones**: 100% local/Bluetooth, **nunca toca la red**; por eso el
  logo se cachea en disco (`LogoCacheService`, refrescado en main.dart cuando hay
  conexión). Consumido por **recibo** y **perfil** (pairing).

### Mapa — `lib/features/mapa/mapa_screen.dart`
- **Service**: `MapTileCache` (tiles OSM en disco, Android/Windows; web cae a red).
- **Tablas**: lee `clientes` (lat/lng). Compartido cobrador (`/mapa`) y admin
  (`/admin/mapa`). El cobro NO guarda geo (lat/lng null).

### Reportes — `lib/features/admin/reportes/*`
- **Providers**: `empresaNombreProvider` (nombre del ISP en el header).
- **Genera**: `excel/reporte_excel.dart` (.xlsx) + `pdf/reporte_*_pdf.dart` (8
  reportes + arqueo) → `descarga_archivo.dart` (`file_picker.saveFile`, solo
  Windows/Android). `arqueo_calculo.dart` consolida caja.
- **Tablas**: lee `pagos`, `cuotas`, `clientes`, `contratos`, `cobradores` (todo
  local, queries SQLite con corte por día/mes en hora Nicaragua UTC-6).
- **Interconexiones**: consume lo que escribió **cobro**; los totales deben
  coincidir con **dashboard** y detalle de **contrato** (invariante #10).

### Dashboard admin — `lib/features/admin/dashboard/dashboard_admin_screen.dart`
- **Providers**: `dashboard_providers.dart` (KPIs como `StreamProvider` cacheados:
  cobros hoy/semana/mes, mora, top cobradores), `moraCountProvider`.
- **Tablas**: lee `pagos`, `cuotas`, `clientes` (agregaciones SQLite).
- **Interconexiones**: misma base de datos que reportes; KPIs derivan de `pagos`
  no anulados.

### Historial / Home — `lib/features/historial/historial_screen.dart` (+ `/` cobrador = CuotasListScreen)
- **Tablas**: lee `pagos`/`recibos` del cobrador. La landing del cobrador es la
  pantalla de Cobros (`CuotasListScreen`), no una home dedicada.

### Settings — `lib/features/admin/settings/*` + `lib/data/repositories/settings_repo.dart`
- **Providers**: `appSettingsProvider` (en `settings_repo.dart`) — config tipada
  del tenant; el router hace `ref.listen(appSettingsProvider)` para reaccionar a
  toggles (ej. `auditVisibleAdmin`).
- **Tablas**: `settings` (`clave/valor JSONB`, serializado con `jsonEncode`).
- **Interconexiones**: alimenta a casi todos los módulos (cargos auto en cobro,
  layout en recibo, días de gracia en cuotas, empresa en reportes/recibo).
  Algunos settings son super-only (migraciones 0085/0086/0089).

### Auth — `lib/features/auth/*` + `lib/data/providers/auth_identity_provider.dart`
- **Providers**: `authIdentityProvider` (detecta user-switch para el sync gate),
  `auth_flow_provider.dart` (`initialAuthFlowProvider`/`Error` desde la URL),
  `syncReadyProvider`, `syncGateGraceProvider`.
- **Flujo**: `login_screen` (email+password, sin signup público),
  `set_password_screen` (recovery/invite), `cambiar_password_dialog`. PKCE/implicit
  resueltos en `main.dart`.
- **Interconexiones**: el evento auth dispara connect/disconnect de PowerSync y
  los `ref.invalidate` del router. El **sync gate** (`sync_gate_screen.dart`)
  bloquea la UI hasta que PowerSync confirme sync post-cambio de identidad.

### Super Admin — `lib/features/super_admin/*` + `lib/data/repositories/super_admin_repo.dart`
- **Repo**: `SuperAdminRepo` habla **por RPC/Edge a Supabase, NO toca SQLite**
  (las tablas `modulos`/`tenant_modulos`/`tenants` no se sincronizan).
- **Pantallas**: `tenants_list_screen`, `tenant_modulos_screen` (toggle módulos),
  `miembro_detalle_screen` (forzar password / cambiar email / rol / eliminar vía
  Edge Functions), `error_logs_screen` (`/super/logs`, RPC `list_error_logs`).
- **Impersonación**: `ImpersonationService` escribe `super_admin_impersonation`
  (único write-path, auditado) → `impersonatedTenantIdProvider` lo detecta vía
  el bucket sync `impersonated_tenant` → el router lleva al super_admin a
  `/admin/*` con la data del tenant. `tenantIdProvider` retorna el tenant
  impersonado; las acciones de campo (cobro) se **bloquean** durante impersonación.

### Geografía — `lib/features/admin/geografia/geografia_admin_screen.dart` + `widgets/geo_picker.dart`
- **Tablas**: CRUD jerárquico `departamentos → municipios → comunidades`
  (**globales, sin tenant_id**; bucket `geografia` lo baja a todos).
- **Interconexiones**: `geo_picker.dart` lo consume desde **clientes**. Nota:
  estas tablas NO tienen el trigger genérico de audit (ver pendiente en CLAUDE.md).

### Tickets / Técnico — `lib/features/admin/tickets/*` (admin) · `lib/features/tecnico/*` (técnico) — MÓDULO OPCIONAL (Fase 3)
- **Gating**: módulo `tickets` (`es_base=false`, OFF por defecto; el super_admin lo
  enciende en `/super/tenants/:id`). Migraciones **0103** (roles+tablas+RLS+trigger de
  transición), **0104** (Storage `ticket-adjuntos`), **0105** (pausa SLA exacta).
- **Tablas**: `ticket_tipos` (catálogo con `sla_horas` por tipo), `tickets`
  (correlativo `T-00001`, estado [8] validado por trigger server-side, `cliente_id`/
  `puerto_id`/`incidente_id` nullable, `segundos_pausado`+`en_espera_desde` para la
  pausa de SLA), `ticket_eventos` (bitácora **append-only**), `ticket_adjuntos` (fotos).
- **Roles** (1 por usuario, `set_cobrador_rol`): `tecnico` (móvil-first, shell propio) y
  `admin_tickets` (admin acotado — **DIFERIDO**, aún no asignable). RLS: lectura =
  miembro del tenant; escritura = `is_ticket_staff()` (admin/admin_tickets/**tecnico**).
- **SLA derivado en Dart** (`lib/data/utils/ticket_sla.dart`, patrón de `cuota_estado`):
  `deadline = created_at + sla_horas + segundos_pausado`; estados en plazo/por vencer/
  vencido/en espera/cerrado. La pausa la acumula el trigger 0105 con device-time
  (offline-safe); el cliente sólo la suma.
- **Admin (3A)**: `/admin/tickets` (lista, filtro de estado en SQL) · `ticket_tipos`
  (CRUD) · `ticket_form` (crear + asignar) · `ticket_detail` (transiciones con
  re-validación en tx + reasignar + comentar + bitácora + adjuntos). Gateado a
  `soloAdmin` + módulo.
- **Técnico (3B)**: `TecnicoShell` (bottom-nav **Mis tickets · Mapa · Perfil**),
  offline-first como el cobrador. `MisTicketsScreen` (sus tickets, filtro activos/
  cerrados) → `TicketDetailScreen(tecnicoMode)` en `/tecnico/tickets/:id` (transiciones
  acotadas a avanzar/pausar/resolver, sin reasignar). Reusa `MapaScreen`+`PerfilScreen`.
  Router lo **contiene** en `/tecnico/*` (no toca dinero/admin/super).
- **Interconexiones**: `cliente_id` → **clientes** · `puerto_id` → **red** (soft) ·
  **`ticket_materiales` → inventario (3C, HECHO)**: registrar un material dispara un
  trigger SECURITY DEFINER (0106) que inserta `inv_movimientos 'consumo'` (descuenta del
  origen) y marca el serial `'instalado'` en el cliente del ticket → el equipo aparece en
  "Equipos instalados" del cliente y en `equipos_en_baja`. El técnico consume de su
  custodia (`inv_ubicaciones tipo='tecnico'`). · (3D) `incidente_id` → **incidentes**
  (outages). Eventos de la bitácora en la timeline del ticket; el consumo se surfacea en el
  cuna-a-tumba del serial (via `ticket_materiales`). El audit_log genérico cubre las 5 tablas.
- **Sync (buckets)**: admin/impersonado bajan las 5 tablas de ticket (`todo_tenant_admin`/
  `impersonated_tenant`). El **técnico** baja sólo lo suyo: `por_tecnico` (ticket_tipos +
  cobradores + catálogo inv), `por_tecnico_tickets` (dinámico: sus tickets + bitácora +
  adjuntos + **materiales**), `por_tecnico_clientes` (dinámico: **sólo `clientes`** de sus
  tickets — CERO dinero), **`por_tecnico_inventario`** (dinámico: su custodia `tipo='tecnico'`
  — ubicación + seriales + ledger de esa ubicación). `admin_cobranza` NO baja tickets (intencional).

---

## 4. Flujos de datos críticos end-to-end

### (a) Cobro de campo (cobrador, offline → sync → trigger → reportes)
1. Cobrador en `/cobro/:cuotaId` ingresa monto/método/foto. La foto va a
   `FotoComprobanteService` (Storage cuando hay red; cola local si no).
2. `PagosRepo.registrarCobro` abre `writeTransaction` en SQLite: inserta
   `cargos_extra` (si hay), `pagos`, `recibos`, y **espeja** localmente
   `cuotas.monto_pagado/estado/cargos_neto` con `calcularEstadoCuota`.
3. Navega a `/recibo/:id` → renderiza `ReciboTicket` → **impresora** Bluetooth.
4. Cuando vuelve la red, `connector.dart.uploadData` sube la CRUD queue a Postgres.
5. En el server, el **trigger `recalcular_cuota_desde_pagos`** recalcula
   `cuota.monto_pagado/estado` (fuente de verdad) y `audit_changelog_trg` graba
   en `audit_log`. Esa data corregida baja de vuelta por sync rules.
6. **Dashboard** y **reportes** del admin (que sincronizan el tenant entero) leen
   `pagos`/`cuotas` ya consolidados desde su SQLite.

### (b) Generación mensual de cuotas (trigger / cron server)
1. Al crear/editar un **contrato**, un trigger de Postgres genera las `cuotas`
   del período (server gana — el cliente no las crea).
2. Las cuotas bajan al cobrador asignado (bucket `por_cobrador`, filtro
   `cobrador_id`) y al admin (bucket `todo_tenant_admin`).
3. Un **cron diario** (medianoche Nicaragua, 06:05 UTC) genera filas en
   `notificaciones_mora` para cuotas vencidas → módulo notificaciones / badge mora.

### (c) Anular un pago (restaura la cuota)
1. Admin en `/admin/pagos` → `PagosRepo.anularPago`: marca `pagos.anulado=1` +
   `recibos.anulado=1` y **espeja** local la resta en `cuotas.monto_pagado/estado`.
2. Sube → trigger server recalcula la cuota de forma autoritativa. El pago
   anulado **se preserva** (audit trail, nunca se borra).
3. Las sync rules del cobrador filtran `anulado=false` → el cobrador deja de ver
   ese pago/recibo, pero el saldo de la cuota ya quedó correcto vía trigger.

### (d) Change log / audit (trigger genérico → audit_log → UI)
1. Cualquier INSERT/UPDATE/DELETE en una tabla operativa dispara
   `audit_changelog_trg` (AFTER, guard `pg_trigger_depth() < 2`) → fila en
   `audit_log` (snapshot create/update/delete). El cliente solo aporta
   `ocurrido_en` (device-time, offline-first).
2. `audit_log` baja a admin/admin_cobranza por sync rules.
3. **`HistorialCambiosWidget`** (`SELECT ... FROM audit_log WHERE registro_id=? AND
   tabla=?`) renderiza el timeline. Los agregadores (`HistorialCuotaWidget`,
   `HistorialClienteWidget`) unen hijas leyendo el `padre_id` del snapshot JSON.
   Config de campos visibles en `data/utils/audit_changelog.dart`.

### (e) Onboarding de tenant (super_admin → Edge crear-tenant)
1. `/super/tenants` → form (switch "Enviar email" en OFF por default).
2. `SuperAdminRepo.crearTenant` → `functions.invoke('crear-tenant')` (Edge Deno):
   inserta `tenants` (trigger habilita módulos base), habilita módulos extra,
   crea el admin en `auth.users` (con password aleatoria si no-email,
   `email_confirm=true`) y devuelve `admin_password` para compartir por canal
   externo. Rollback completo si algo falla (borra user + tenant).
3. El admin entra por `/login` con email+password → `_rolUsuarioProvider`
   resuelve `admin` → landing `/admin`.

---

## 5. Reglas de wiring que NO se deben romper

(Detalle y justificación en CLAUDE.md — acá el resumen accionable.)

| Regla | Dónde se enforcea | Qué romper la viola |
|---|---|---|
| **RLS por tenant** | Postgres policies (`current_tenant_id()`); sync rules por bucket | Crear tabla sin `tenant_id`/RLS, o leer cross-tenant sin impersonación |
| **Server gana** | Triggers de Postgres = fuente de verdad de dinero/estado | Calcular y persistir estado final en el cliente sin espejar el trigger |
| **Audit append-only** | `audit_changelog_trg` + Edge Functions | Borrar filas de `audit_log` (se agregan filas, nunca delete) |
| **Invariantes de dinero** | `pagos_repo.dart` + triggers + `invariantes_dinero.sql` | Sumar lo entregado/vuelto al recaudado; recalcular `monto_pagado` a mano |
| **Cadena DB↔schema↔sync↔version** | schema.dart + sync-rules.yaml + `_schemaVersion` en db.dart | Agregar columna en Postgres sin declararla en schema.dart, redeployar sync rules y bumpear `_schemaVersion` |
| **`dbEpochProvider` en streams globales** | cada `StreamProvider` que watchea `ps.db` | Watchear `ps.db` sin `ref.watch(dbEpochProvider)` → stream de la DB vieja tras user-switch |
| **Denormalizar `cobrador_id` en INSERTs** | `pagos_repo.dart`, sync-rules.yaml | Las sync rules del cobrador filtran por `cobrador_id`; los triggers SQLite no corren local |

---

## 6. Mapa rápido archivo → responsabilidad

| Archivo | Responsabilidad |
|---|---|
| `lib/main.dart` | Bootstrap: Supabase init, ErrorLogService, abrir/conectar PowerSync según sesión, container global, workers de fondo |
| `lib/app.dart` | `IspBillingApp` (MaterialApp.router con `routerProvider`) |
| `lib/config/router.dart` | GoRouter, 3 ShellRoutes por rol, gates (login/set-password/sync-gate/rol/impersonación), `_rolUsuarioProvider`, `empresaNombreProvider` |
| `lib/config/env.dart` | Env vars (`--dart-define-from-file=.env.json`): Supabase + PowerSync URLs/keys |
| `lib/powersync/db.dart` | `ps.db` per-user, `openDatabaseForUser`, `connect/disconnectPowerSync`, `_schemaVersion`, `onDatabaseSwitched` |
| `lib/powersync/schema.dart` | Declaración de todas las tablas/columnas/índices del SQLite local |
| `lib/powersync/connector.dart` | `SupabaseConnector`: credenciales + drenado de CRUD queue a Postgres, manejo de errores no-retryables |
| `powersync/sync-rules.yaml` | Buckets por rol: qué filas baja cobrador / admin / admin_cobranza / super_admin / impersonación |
| `lib/data/providers/db_epoch_provider.dart` | Contador que recrea todos los providers bound a `ps.db` al cambiar de DB |
| `lib/data/providers/cobrador_provider.dart` | `cobradorActualProvider` (usuario actual) + `tenantIdProvider` (tenant efectivo, respeta impersonación) |
| `lib/data/providers/impersonation_provider.dart` | `impersonatedTenantIdProvider` / `estaImpersonandoProvider` (lee `super_admin_impersonation`) |
| `lib/data/providers/auth_identity_provider.dart` | Identidad para el sync gate (detección de user-switch) |
| `lib/data/providers/dashboard_providers.dart` | KPIs del dashboard admin como StreamProviders cacheados |
| `lib/data/repositories/pagos_repo.dart` | `registrarCobro`/`registrarCobroMultiple`/`anularPago`/`editarPago` (transacción local + mirror de cuota) |
| `lib/data/repositories/clientes_repo.dart` | CRUD/paginación de clientes |
| `lib/data/repositories/cuotas_repo.dart` | Queries de cuotas (cobrador/admin) |
| `lib/data/repositories/settings_repo.dart` | `SettingsRepo` (read/update/upsert JSON) + `appSettingsProvider` tipado |
| `lib/data/repositories/super_admin_repo.dart` | Panel /super/* vía RPC/Edge (NO toca SQLite): crearTenant, módulos, miembros |
| `lib/data/utils/cuota_estado.dart` | `calcularEstadoCuota` — espejo Dart del trigger `recalcular_cuota_desde_pagos` |
| `lib/data/utils/audit_changelog.dart` | Config de campos visibles/labels del change log |
| `lib/data/utils/edge_functions.dart` | Helper `invokeEdgeFunction` + humanización de errores |
| `lib/data/services/foto_comprobante_service.dart` | Foto del comprobante: cola local + upload a Storage |
| `lib/data/services/impresora/impresora_service.dart` | `ImpresoraService` (split io/web): `imprimirImagen` Bluetooth térmico |
| `lib/data/services/impersonation_service.dart` | Único write-path de impersonación (escribe tabla + audit) |
| `lib/data/services/error_log_service.dart` | Singleton de captura de errores → `error_logs` |
| `lib/data/services/logo_cache_service.dart` | Cachea el logo de empresa en disco para impresión offline |
| `lib/data/services/map_tile_cache.dart` | Caché de tiles OSM en disco |
| `lib/data/services/visitas_service.dart` | Registrar/watch de `visitas` |
| `lib/features/cobro/cobro_screen.dart` | Flow de cobro (monto/método/foto/cargos) → `pagosRepo` → recibo |
| `lib/features/recibo/recibo_screen.dart` | Preview + imprimir (térmica o PDF sistema), reimpresión |
| `lib/features/admin/reportes/descarga_archivo.dart` | Guardado nativo de PDF/Excel (Windows/Android) |
| `lib/features/shared/widgets/historial_cambios_widget.dart` | Render del change log desde `audit_log` (patrón Simple) |
| `lib/features/shared/widgets/sync_gate_screen.dart` | Pantalla del sync gate con escape hatches (reintentar/login) |
| `supabase/functions/crear-tenant/index.ts` | Alta de ISP + admin (con/sin email) + rollback |
| `supabase/functions/_shared/*.ts` | Helpers compartidos: `passwords.ts`, `auth_errors.ts`, `response.ts` |

---

_Última actualización del wiring verificada contra: `_schemaVersion = 16`,
16 tablas en `schema.dart`, 6 buckets de sync, 6 Edge Functions._
