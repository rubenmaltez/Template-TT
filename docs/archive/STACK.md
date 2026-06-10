# Stack Tecnológico — Cobranza ISP

Referencia persistente del stack de tecnologías usadas en el proyecto y
**por qué** cada una fue elegida. Útil para onboarding, decisiones futuras,
o cuando aparece alternativa que pretende reemplazar algo del stack.

Última actualización: 2026-05-23 (pre-BULK 1).

---

## Visión panorámica

```
┌─────────────────────────────────────────────────────────────┐
│  Cliente: Flutter Web (eventual Android + Windows)          │
│  ├─ State: Riverpod 2.x                                     │
│  ├─ Router: go_router 14.8.1 (ShellRoute per rol)           │
│  ├─ DB local: PowerSync SQLite (offline-first)              │
│  └─ Auth/HTTP: supabase_flutter 2.x                         │
└────────────────────┬────────────────────────────────────────┘
                     │  HTTPS + WebSocket realtime
                     ▼
┌─────────────────────────────────────────────────────────────┐
│  Backend: Supabase (managed Postgres + Auth + Storage)      │
│  ├─ Postgres 15: tablas + RLS + triggers + RPCs             │
│  ├─ Auth: JWT-based, sin signup público                     │
│  ├─ Storage: bucket comprobantes-pago (fotos de cobros)     │
│  └─ Edge Functions (Deno): crear-tenant, invitar-cobrador,  │
│       forzar-password-cobrador, etc.                        │
└────────────────────┬────────────────────────────────────────┘
                     │  PowerSync Service consume WAL
                     ▼
┌─────────────────────────────────────────────────────────────┐
│  PowerSync Cloud: sync engine                               │
│  ├─ Sync rules YAML → buckets per rol                       │
│  └─ Push cambios local → server vía connector               │
└─────────────────────────────────────────────────────────────┘
```

---

## Cliente

### Flutter
**Qué hace**: framework UI multi-plataforma de Google. Un solo codebase
compilando a Web (JavaScript+WASM), Android (APK), iOS (IPA), Windows
(.exe), macOS (.app), Linux. Hoy el foco es Web; cuando madure la app,
se distribuirá también Android (cobrador en campo) y Windows installer
(admin en oficina).

**Por qué Flutter y no React/React Native/Native**:
- **Un solo codebase para Web + móvil + desktop**: el cobrador en campo
  usa Android, el admin en oficina usa Web (o Windows futuro), el
  super_admin usa Web. Flutter cubre los tres con la misma lógica de
  negocio.
- **AOT compilation**: rendimiento nativo en móvil. En Web, hot reload
  rápido en dev y bundle pequeño en prod.
- **Widget tree explícito**: estructura UI predecible, sin "magia"
  del DOM. Fácil de debuggear.
- **Ecosistema maduro**: paquetes para Bluetooth térmico, mapas,
  cámara, geolocalización, todo lo que necesita un cobrador en campo.

**Trade-off conocido**: bundle Web es más pesado que un SPA React
(arranca ~2-3MB minificado). Mitigado con caching agresivo.

### Dart
**Qué hace**: lenguaje en que está escrito Flutter. Sintaxis tipo
TypeScript/Java, con null safety estricto, soporte async/await,
streams como primitive (clave para offline-first).

**Por qué importa**:
- **Null safety**: imposible olvidar handle de null (errores de
  compilación en vez de runtime crashes).
- **Streams nativos**: `StreamProvider` de Riverpod + `db.watch()` de
  PowerSync se conectan naturalmente.
- **AOT + JIT**: JIT en dev (hot reload <1s), AOT en prod (sin
  overhead de interpretación).

---

## State management

### Riverpod 2.x
**Qué hace**: librería de gestión de estado para Flutter. Reemplaza
`setState` global con providers tipados, observables, con
auto-disposal.

**Cómo lo usamos**:
- **`StreamProvider`**: para data de PowerSync que cambia
  reactivamente (lista de clientes, cuotas, etc.).
- **`FutureProvider.family`**: para queries one-shot parametrizadas
  (detalle de cliente by id).
- **`StateProvider`**: para UI state local (filtros, búsqueda, modo
  de vista).
- **`Provider`**: para servicios singleton (ErrorLogService,
  PowerSync instance).

**Por qué Riverpod y no setState/Provider/BLoC/Redux**:
- **Tipado**: el compilador sabe qué tipo retorna cada provider.
- **Auto-dispose**: los providers `autoDispose` liberan memoria al
  desmontarse la pantalla. Importante con offline-first donde hay
  muchos streams abiertos.
- **Testeable**: providers se overridean en tests con
  `ProviderContainer`.
- **`ref.invalidate()`**: forzar refresh de un provider tras una
  mutación. Patrón clave en formularios que escriben y vuelven a
  leer.

**Trade-off conocido**: curva de aprendizaje, hay que entender
`ref.read` vs `ref.watch`, autoDispose, family modifiers.

---

## Routing

### go_router 14.8.1
**Qué hace**: router declarativo oficial recomendado por el equipo
de Flutter. Usa URLs como source of truth (clave para Web), soporta
deep linking, redirects, guards.

**Cómo lo usamos**:
- **ShellRoute per rol**: 3 shells (`CobradorShell`, `AdminShell`,
  `SuperShell`) con sidebar/bottom nav propios. Cada uno hosting un
  subset de rutas.
- **`redirect` global**: guard que checa rol del usuario + estado
  de onboarding + paths permitidos. Redirige `/admin` → `/login` si
  no hay sesión, etc.
- **`pathUrlStrategy`**: URLs limpias en Web (sin `#`).

**Por qué go_router y no Navigator imperativo o auto_route**:
- **Source of truth en URL**: el state de navegación vive en la URL,
  no en memoria. Refresh del browser preserva el estado. Critical
  para Web.
- **Redirects centralizados**: un solo lugar tiene la lógica de
  "quién puede ir a dónde". Más fácil de auditar que guards
  scattered.
- **Type-safe routes** con `name:`: navegamos con
  `context.goNamed('admin.cliente.editar', pathParameters: {...})`
  en vez de strings frágiles.

**Limitación conocida**: `context.go(...)` hace REPLACE de ruta,
no PUSH. PopScope no lo intercepta. Por eso el sidebar puede
brincar arriba de un form con cambios sin guardar. Tema activo del
backlog (BULK 1 Sprint 3).

---

## Backend

### Supabase
**Qué hace**: backend-as-a-service open-source basado en
PostgreSQL. Da auth, database, storage, edge functions, realtime,
todo gestionado vía Dashboard (web) o CLI.

**Cómo lo usamos**:
- **Postgres + RLS**: la fuente de verdad del producto.
- **Auth**: JWT-based, sin signup público (workflow no-email del
  super_admin).
- **Storage bucket `comprobantes-pago`**: fotos de comprobantes de
  pago subidas por cobradores (uploadAsync + retry).
- **Edge Functions (Deno)**: lógica que necesita `service_role`
  (crear users, signOut global, eliminar con cascada). Usan
  `callerClient` con el JWT del caller para queries normales
  (sujetas a RLS) y `service_role` SÓLO para `auth.admin.*` y
  rollbacks.

**Por qué Supabase y no Firebase/AWS Amplify/backend custom**:
- **Postgres real**: schema relacional, RLS nativo, SQL completo,
  funciones SECURITY DEFINER. Firebase es NoSQL y no escala con
  modelos relacionales como contratos↔cuotas↔pagos↔recibos.
- **RLS por tabla**: multi-tenant casi automático. Cada policy
  filtra por `current_tenant_id()` y queda imposible para tenant
  A ver data de tenant B (sin policy, sin row).
- **Hosted**: sin DevOps, sin servidor que mantener. Backups
  automáticos, point-in-time recovery, dashboard listo.
- **Open-source**: si Supabase quiebra, el código está y se puede
  self-hostear.

### PostgreSQL 15
**Qué hace**: la base de datos. Todo lo crítico vive acá:
`tenants`, `clientes`, `contratos`, `cuotas`, `pagos`, `recibos`,
`audit_log`, `error_logs`, `settings`, `modulos`, etc.

**Features que aprovechamos**:
- **Row-Level Security (RLS)**: cada tabla operativa tiene policies
  que filtran por tenant. Imposible bypassar desde el cliente.
- **Triggers**: `recalcular_cuota_desde_pagos` se ejecuta tras
  INSERT/UPDATE/DELETE en `pagos` para mantener consistencia.
- **JSONB**: `settings.valor` flexible por tenant sin migraciones
  por cada nuevo campo.
- **Functions SECURITY DEFINER**: `current_tenant_id()`,
  `is_super_admin()`, `list_error_logs()`. Bypassean RLS de manera
  controlada.
- **Append-only via política**: `audit_log` no se borra nunca,
  patrón de rows nuevas para "deshacer".

---

## Sync layer

### PowerSync 1.10
**Qué hace**: motor de sincronización offline-first. Mantiene una
réplica local SQLite del subset de data relevante para el user
loggeado, y sincroniza con el server cuando hay conexión.

**Cómo lo usamos**:
- **Sync rules** (`powersync/sync-rules.yaml`): definen buckets per
  rol. El cobrador solo descarga sus clientes asignados; el admin
  descarga todo el tenant; el super_admin tiene buckets cross-tenant.
- **`ps.db.watch(sql)`**: streams reactivos que emiten cuando la
  data local cambia. La UI se actualiza tanto por sync del server
  como por mutaciones locales.
- **Connector**: traduce mutaciones locales (INSERT/UPDATE/DELETE
  en SQLite) a llamadas Supabase (INSERT/UPSERT/DELETE en Postgres).

**Por qué PowerSync y no Firestore offline/CouchDB/sync custom**:
- **Postgres-first**: PowerSync sincroniza desde un WAL de Postgres.
  No requiere cambiar el schema ni adoptar un DB diferente.
- **SQLite local**: queries arbitrarias offline (JOINs, GROUP BY,
  etc.). Firestore offline es key-value y no soporta queries
  complejas.
- **Sync rules declarativas**: control fino de qué data baja a qué
  cliente, sin escribir endpoint por endpoint.
- **Conflicto resuelto server-side**: el server gana siempre. Sin
  CRDTs complicados (que escalan mal en este dominio).

**Trade-off conocido**: la sincronización del primer login puede
tardar varios minutos con muchos tenants/clientes. Tema activo
(BULK 5 — sync optimization).

---

## Edge Functions

### Deno
**Qué hace**: runtime de TypeScript/JavaScript moderno usado por
las Edge Functions de Supabase. Sin `node_modules`, imports vía
URL, tipos nativos, sin tooling adicional.

**Cómo lo usamos**:
- **6 funciones**: crear-tenant, invitar-cobrador, reenviar-invitacion,
  forzar-password-cobrador, cambiar-email-cobrador, eliminar-cobrador.
- **Patrón**: cada función recibe JSON, valida permisos del caller,
  ejecuta la op con `service_role` (auth.admin.*) + rollback en
  catch.
- **`@supabase/supabase-js@2.45.0`** + **Deno std 0.224.0**.

**Por qué Edge Functions y no API server propia**:
- **Sin DevOps**: Supabase corre el runtime. Deploy es paste +
  click en Dashboard.
- **Cerca del DB**: latencia <50ms con Postgres en el mismo region.
- **Auth integrado**: el JWT del caller se valida solo, sin parsear
  manualmente.

**Limitación conocida del Dashboard**: no soporta multi-file via
paste (`_shared/passwords.ts` no funciona). Por eso
`generarPasswordSegura` está duplicada inline. Cuando migremos a
CLI, mover a `_shared/`.

---

## UI y mapas

### flutter_map + OpenStreetMap
**Qué hace**: widget de mapa para Flutter (versión open-source
del flutter_google_maps). Usa tiles de OpenStreetMap (gratuitas,
sin API key).

**Cómo lo usamos**:
- **`/admin/mapa`**: clientes geolocalizados con markers por estado
  de cuota.
- **`/mapa` (cobrador)**: clientes asignados, modo planificada o
  libre según setting `cobranza.modo_ruta`.
- **`GeoPicker`**: widget para seleccionar lat/lng al crear/editar
  un cliente.

**Por qué OSM y no Google Maps/Mapbox**:
- **Gratis**: sin API key, sin límites de quota, sin facturación
  sorpresa.
- **Multi-plataforma**: misma API en Web y móvil sin Native plugins
  diferentes.
- **Sin lock-in**: si cambia el proveedor de tiles, el código no
  cambia (solo la URL del template).

---

## Testing

### flutter_test (built-in)
**Qué hace**: framework de testing oficial. Soporta unit tests,
widget tests, integration tests.

**Cobertura actual**: 109 tests en 4 archivos:
- `cuota_estado_test.dart` (17 tests) — pure function de
  recalcular estado.
- `validators_test.dart` (37 tests) — validadores de formularios.
- `formatters_test.dart` (33 tests) — Fmt.cordobas, fechaRelativa,
  periodoRecibo (regla del 15), etc.
- `error_log_entry_test.dart` (22 tests) — modelo del logger.

**Por qué tests aunque sea MVP**:
- **Guardia contra regresiones sutiles**: `fechaRelativa` tiene
  lógica condicional con muchos boundaries (Hoy/Ayer/Mañana/En N
  días/Hace N días/fecha absoluta). Sin tests, un cambio
  inocente puede romper en producción y nadie se da cuenta hasta
  el reclamo del cobrador.
- **Documentación viva**: el test describe el comportamiento
  esperado mejor que un comment.
- **Confianza para refactor**: con tests, mover código entre
  archivos no da miedo.

---

## Servicios auxiliares

### Resend (email transaccional, en sandbox)
**Qué hace**: API para mandar emails desde el server (invitations,
password resets). Hoy en sandbox: solo manda al email del owner de
la cuenta porque el dominio no está verificado.

**Estado**: **fuera del workflow operativo**. El super_admin no
depende de email para invitar tenants/cobradores. Modelo activo es
password generada server-side compartida via WhatsApp/canal seguro.
Cuando Rubén compre dominio y lo verifique en Resend, el switch
"Enviar email" en `/super/tenants` empieza a funcionar
naturalmente.

### package_info_plus
**Qué hace**: lee versión + build number de la app desde el
binario. Lo usa `ErrorLogService` para anexar `app_version` a cada
error log subido a `error_logs`. Útil para diagnosticar bugs que
afectan solo una build específica.

### shared_preferences
**Qué hace**: KV storage local persistente (LocalStorage en Web,
SharedPreferences en Android, NSUserDefaults en iOS). Usado por
`ErrorLogService` para mantener cola FIFO de 200 entries pendientes
de subir cuando vuelva la conexión.

### image_picker + permission_handler
**Qué hace**: captura de foto vía cámara o galería + manejo de
permisos. Usado en el flow de cobro para foto del comprobante.

### print_bluetooth_thermal + esc_pos_utils_plus
**Qué hace**: pairing y print de recibos a impresoras térmicas
Bluetooth (las clásicas 58mm/80mm que usan tickets). Encapsulan el
protocolo ESC/POS.

**Cómo lo usamos**:
- `/perfil/impresora` pairea con la impresora.
- Al cerrar el flow de cobro, se imprime un recibo con datos del
  cliente, monto, fecha, y un código corto.
- **Gated por `kIsWeb`**: en Web no hay Bluetooth nativo (algunos
  browsers tienen Web Bluetooth pero no soporta ESC/POS
  prácticamente). Solo activo en Android.

### intl (Internationalization)
**Qué hace**: formatters de fecha, número, currency con locales.
`Fmt.cordobas(750.5)` usa `NumberFormat.currency(locale: 'es_NI', symbol: 'C\$')`.
`Fmt.fechaRelativa(...)` usa `DateFormat('EEEE', 'es_NI')` para "lunes",
"martes", etc.

**Requisito clave**: `initializeDateFormatting('es_NI', null)` en
`main.dart` antes del primer uso. Sin esto, los DateFormat con
patrones de nombre fallan con `LocaleDataException`.

### uuid
**Qué hace**: genera UUIDs v4 client-side. Usado en mutaciones
offline-first donde el cliente necesita el id antes de que el
server lo asigne (ej. el cobrador crea un pago, se guarda en
SQLite con UUID, sincroniza después).

### url_launcher
**Qué hace**: abre URLs externas (WhatsApp `wa.me/...`, llamadas
`tel:...`, emails `mailto:...`, maps). Usado en el detalle de
cliente para "Llamar" / "WhatsApp" / "Ver en Google Maps".

---

## ¿Por qué esta combinación es buena?

1. **Offline-first real**: PowerSync + Riverpod StreamProvider + Flutter
   widgets hacen que la UI siga andando sin conexión. El cobrador
   anota cobros en zona rural sin señal y se sincroniza al volver.

2. **Multi-tenant seguro by default**: Postgres RLS + JWT de
   Supabase + `current_tenant_id()` garantizan que un admin
   nunca ve data de otro tenant. No es por discipline del código
   cliente — es físicamente imposible.

3. **Multi-plataforma con un codebase**: Flutter compila a Web,
   Android, iOS, Windows, macOS, Linux. Hoy usamos Web; cuando
   madure, agregamos Android (cobrador) y Windows installer
   (admin oficina) sin reescribir.

4. **Audit y observabilidad desde el día 1**: `audit_log`
   append-only + `error_logs` + `/super/logs` UI. Si algo se
   rompe en producción, hay rastro.

5. **Sin lock-in extremo**: Postgres es estándar, Flutter es
   open-source, Supabase tiene versión self-host, PowerSync tiene
   versión self-host. Si algo de la cadena falla, hay salida.

6. **Stack moderno pero estable**: nada experimental. Todas las
   piezas tienen versiones >1.0, ecosistema maduro, y bug fixes
   activos.

---

## Cuándo revisitar este stack

- **Si la app crece a 100+ tenants concurrentes**: revisar capacity
  de Supabase (probablemente upgrade de plan), considerar caché
  layer (Redis) entre cliente y Supabase para queries frecuentes.
- **Si aparece feature que requiere realtime peer-to-peer**: hoy
  no hay caso de uso. Pero si en el futuro hay chat cobrador↔admin,
  considerar agregar canal Supabase Realtime explícito.
- **Si Flutter Web no escala bien al desktop nativo**: evaluar
  separar el cliente Web del cliente desktop (Tauri, Electron, o
  Flutter Desktop maduro).
- **Si PowerSync no escala con muchos clientes en un tenant**:
  alternativa es agregar paginación + filtros server-side y
  reducir el bucket sincronizado.

Hoy ninguna de estas alarmas está sonando — el stack es adecuado
para el MVP y los próximos 6-12 meses de crecimiento.
