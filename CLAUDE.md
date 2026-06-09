# CLAUDE.md

Contexto persistente del proyecto **Cobranza ISP** para sesiones futuras de Claude Code.
Si estás abriendo este repo por primera vez en esta sesión, leé este archivo primero.

> **⚡ ANTES QUE NADA leé `HANDOFF.md`** — el estado vivo en una pantalla (branch,
> último commit, qué se hizo, qué falta). Es el "dónde quedamos". Y al CERRAR la
> sesión, **actualizalo** (Fase 6 del lifecycle). Mapa completo de módulos e
> interconexiones en `ARQUITECTURA.md`.

> **Leé también `ESTADO-APP.md`** — es el snapshot del estado real de la app
> (findings abiertos, cobertura de features y tests, próximos pasos). CLAUDE.md
> tiene las REGLAS y el PROCESO; ESTADO-APP.md tiene el "dónde estamos parados
> hoy". Los dos juntos dan el contexto completo para continuar.

> **Leé también `REPORTE-SESION.md`** — bitácora viva: cómo se ESPERA que
> funcione la app (comportamiento esperado por feature + lifecycle de uso
> real end-to-end) y el HISTORIAL de fixes (error → fix → expectativa, por
> sesión). Revisá el comportamiento esperado de un feature ANTES de tocarlo;
> al cerrar cada sesión/sprint de fixes, agregá una entrada nueva.

---

## Producto

**Cobranza ISP** — SaaS multi-tenant para ISPs/WISPs en Centroamérica (mercado primario:
Nicaragua). Modelo B2B: el dueño del SaaS (Rubén, "super_admin") provee la plataforma;
cada ISP cliente es un "tenant" con sus admins y cobradores.

### Roles
- **`super_admin`**: vive en el tenant fijo "System" (`UUID 00000000-...`). Único que puede
  crear/configurar tenants, gestionar miembros cross-tenant, ver audit log global. Es Rubén.
- **`admin`**: dueño operativo del ISP. Invita cobradores, configura su empresa, ve reportes.
- **`admin_cobranza`**: rol intermedio — admin sin acceso a config sensible (planes, settings).
- **`cobrador`**: usuario de campo. Móvil-first. Ve sus clientes/cuotas asignadas, registra
  cobros offline-first (PowerSync sync cuando vuelve la conexión).

### Decisión de workflow CRÍTICA (Rubén explícito)
El super_admin NO depende de email para invitar tenants/cobradores. Modelo actual:
1. Super_admin crea ISP nuevo desde `/super/tenants` → form con switch **"Enviar email
   de invitación" en OFF**.
2. Server genera password aleatoria server-side → la devuelve al super_admin para copiar.
3. Super_admin comparte email + password al cliente vía WhatsApp / llamada / canal seguro.
4. Cliente entra a `/login` con email + password, sin PKCE, sin magic-links, sin Resend.

**No vamos a verificar dominio Resend ni habilitar signup público.** Cualquier finding de
audit que diga "esto se podría exploit si signup estuviera habilitado" se considera fuera
de scope porque signup está deshabilitado en Dashboard. Foco en BUGS reales del código,
no en hardening por escenarios hipotéticos.

---

## Mapa funcional de la app

Visión panorámica de qué hay implementado y dónde vive. Mantener actualizado
cuando se agregan/quitan features. **Leer esto antes de empezar cualquier
task** — orienta rápido el área que va a tocar el cambio.

### Misión del producto
Resolver el **ciclo completo de cobranza de internet residencial** para ISPs
chicos/medianos de Centroamérica:

1. El admin del ISP carga su catálogo (planes, clientes, contratos).
2. El sistema genera cuotas mensuales automáticamente desde el contrato.
3. El cobrador sale a campo con la app móvil-first (offline-first), cobra
   con foto del comprobante, imprime recibo Bluetooth térmico. (La geo del
   cobro NO está implementada — se quitó `GpsService`; el cobro guarda
   lat/lng null.)
4. Vuelve la conexión → PowerSync sincroniza → super_admin y admin ven
   reportes y auditoría.

**Foco del trabajo**: cada sprint debe acercar al MVP de "un ISP real
puede usar esto para reemplazar su Excel + WhatsApp de cobranza". No
features experimentales, no abstracciones prematuras.

### Rutas por rol

**Super Admin** (`/super/*`, exclusivo de Rubén)
- `/super/tenants` — lista de ISPs. Crear nuevo (con/sin email, default sin
  email + password generada server-side para pasar por canal externo).
- `/super/tenants/:id` — detalle del tenant: toggle de módulos
  (Cobranza base + Inventario opcional), lista de miembros.
- `/super/tenants/:tid/miembros/:cid` — detalle del miembro con acciones
  cross-tenant: forzar contraseña, cambiar email, cambiar rol, activar/
  desactivar, eliminar.
- `/super/logs` — viewer de errores del cliente Flutter (logger del sprint
  0035). Filtros tenant/tipo/búsqueda, stack expansible, copiar al portapapeles.

**Admin del Tenant** (`/admin/*`)
- `/admin` — dashboard con KPIs (hoy/semana/mes, clientes activos, cuotas
  por cobrar, mora, top cobradores, distribución de cuotas).
- `/admin/clientes` + `/admin/clientes/nuevo` + `/admin/clientes/:id/editar`
  — CRUD de clientes (nombre, teléfono, dirección, geo).
- `/admin/contratos` + nuevo + editar — contratos cliente↔plan (asigna
  plan, día de pago, fecha alta).
- `/admin/planes` — catálogo de planes de internet (solo admin, no
  admin_cobranza).
- `/admin/cobradores` — invita/gestiona cobradores del tenant (solo admin).
- `/admin/cuotas` — todas las cuotas del tenant con filtros.
- `/admin/pagos` — historial de pagos, ver comprobantes, anular.
- `/admin/notificaciones` — gestión de mora (cron diario genera filas
  en `notificaciones_mora`).
- `/admin/mapa` — mapa con clientes geolocalizados (flutter_map + OSM).
- `/admin/reportes` — reportes operativos. Cada reporte se descarga en **PDF**
  y en **Excel `.xlsx`** (8 reportes + arqueo) vía diálogo nativo de guardado
  (`file_picker.saveFile`: "Guardar como" en Windows, selector en Android). El
  Excel reemplazó el viejo "copiar CSV al portapapeles". Headers de columna
  alineados Excel↔PDF; fechas y cortes por día/mes en hora Nicaragua (UTC-6).
- `/admin/audit` — log de cambios sensibles del tenant (solo admin).
- `/admin/geografia` — CRUD jerárquico depto → municipio → comunidad
  (solo admin).
- `/admin/settings` — config del tenant: empresa, cobranza, pagos, recibos
  (solo admin). El onboarding/wizard inicial se ELIMINÓ en v0.6.4 — ya no hay
  ruta `/admin/onboarding`; la config inicial se hace directo en Ajustes.

**`admin_cobranza`** ve un subconjunto del admin: NO accede a planes,
cobradores, audit, geografía, settings (guardia explícita en el router).

**Cobrador** (`/*`, móvil-first)
- `/` — pantalla inicio con resumen del día.
- `/clientes` — lista de clientes asignados.
- `/cuotas` — cuotas pendientes (ordenadas por mora descendente).
- `/mapa` — clientes geolocalizados (flutter_map + OSM). NOTA: el setting
  `cobranza.modo_ruta` (planificada vs libre) NO está implementado — el mapa
  siempre es modo libre y el toggle está oculto en settings. Aspiracional.
- `/historial` — sus cobros anteriores.
- `/perfil` — datos del cobrador, config impresora Bluetooth.
- `/clientes/:id` — detalle de un cliente (push, fuera del shell).
- `/cobro/:cuotaId` — flow de cobro: monto, método, foto del comprobante,
  imprimir recibo. (Geo del cobro NO implementada: `GpsService` se quitó, el
  cobro guarda lat/lng null.)
- `/recibo/:reciboId` — preview del recibo.
- `/perfil/impresora` — pairing Bluetooth con la impresora térmica.

### Edge Functions (Deno, deployadas via Dashboard)
- `crear-tenant` — alta de ISP nuevo + admin (con/sin email).
- `invitar-cobrador` — admin invita cobrador a su tenant.
- `reenviar-invitacion` — regenera invitación con password nueva.
- `forzar-password-cobrador` — super_admin o admin fuerza nueva password
  (signOut global del target).
- `cambiar-email-cobrador` — cambia email preservando user_id.
- `eliminar-cobrador` — soft delete con cascada.

Todas usan `callerClient` (JWT sujeto a RLS) para DB y `service_role` solo
para `auth.admin.*` y rollbacks.

### Tablas principales (Postgres)
- `tenants` — los ISPs (cada uno es un "cliente" del SaaS).
- `cobradores` — todos los users del tenant (admins + cobradores).
  Replica `auth.users.id`.
- `clientes` + `contratos` + `planes` — catálogo del ISP.
- `cuotas` — generadas mensualmente del contrato. Estados PERSISTIDOS en DB
  (CHECK): `pendiente` / `parcial` / `pagada` / `anulada` (los únicos que el
  trigger escribe). `en_gracia` y `vencida` son estados DERIVADOS en el cliente
  (Dart, desde `fecha_vencimiento` + días de gracia) — nunca se escriben en DB,
  no intentar `UPDATE estado='vencida'` (choca el CHECK).
- `pagos` + `recibos` — registros de cobranza, con foto en Storage
  `comprobantes-pago/{tenant}/comp/{pago_id}.{jpg|png|webp}`.
- `cargos_extra` — descuentos/cargos sobre cuotas.
- `notificaciones_mora` — generadas por cron diario.
- `settings` — config per-tenant (`clave / valor JSONB`).
- `audit_log` — trail append-only de cambios sensibles.
- `modulos` + `tenant_modulos` — feature flags per-tenant.
- `error_logs` — captura de crashes del cliente Flutter (migración 0035).

### Principios arquitecturales a respetar SIEMPRE
1. **Multi-tenant con RLS** — toda tabla operativa tiene `tenant_id` NOT
   NULL. Las policies usan `current_tenant_id()`. Super_admin bypassa con
   `is_super_admin()`. NUNCA crear una tabla sin RLS o sin tenant_id.
   **Checklist al agregar una tabla operativa**: (a) `tenant_id` NOT NULL + FK;
   (b) RLS scopeada por `current_tenant_id()`; (c) agregar a mano su policy
   `super_admin_all` (`for all using is_super_admin() with check is_super_admin()`)
   — el bloque `do$$` de 0026 enumera tablas FIJAS, las nuevas NO la heredan
   (foot-gun: fotos_cliente/visitas la agregaron a mano en 0053/0056);
   (d) trigger `audit_changelog_trg`; (e) declararla en `schema.dart` + sync rules.
2. **Offline-first** — el cobrador debe poder operar sin internet. Cualquier
   feature nueva que requiera conexión sincrónica debe declararse
   explícitamente (no es el default).
3. **Server gana** — el cliente PowerSync sincroniza, pero las queries
   críticas pasan por RPC o Edge Function. La fuente de verdad es Postgres.
4. **Audit log append-only** — nunca borrar rows. Agregar rows nuevas para
   "deshacer" (ej. patrón intent + success en forzar-password).
5. **Workflow sin email del super_admin** — no dependemos de Resend para
   onboarding de tenants. Cualquier feature que asuma "envía email" debe
   tener fallback no-email con password generada server-side.

### Invariantes de dinero (NUNCA violar — la base del negocio)

El control de dinero es la razón de ser del producto. Estas reglas son
inviolables. Cualquier cambio que toque `pagos`, `cuotas`, `recibos`,
`contratos`, `cargos_extra` o flujos de cobro DEBE respetarlas, y el audit
DEBE verificarlas explícitamente:

1. **`pagos.monto_cordobas` = lo APLICADO a la cuota** (lo que entra a la
   caja del ISP). NUNCA lo entregado por el cliente.
2. **`pagos.vuelto_cordobas` = lo devuelto al cliente, SIEMPRE en córdobas.**
   El cliente puede pagar en USD, pero el vuelto nunca se da en USD — solo
   el ISP recibe dólares como efectivo.
3. **`pagos.monto_original` = lo ENTREGADO en la moneda original** (US$30 si
   pagó 30 dólares). Invariante: `monto_original × tasa_conversion ≈
   monto_cordobas + vuelto_cordobas`.
4. **`recaudado` de un contrato = `SUM(pagos.monto_cordobas)` no anulados.**
   NUNCA sumar lo entregado ni incluir vuelto.
5. **Total de un contrato fijo = `precio_mensual × meses`** (lo definido al
   crear). NUNCA la suma de cuotas (las cuotas manuales/anuladas la
   distorsionan). `pendiente = total − recaudado`.
6. **Contratos indefinidos**: solo se reporta "total recaudado" acumulado;
   no hay "pendiente" porque no hay fin definido.
7. **`cuota.monto_pagado` = `SUM(pagos aplicados no anulados)`** de esa cuota.
   Lo mantiene un trigger server-side. El cliente NUNCA lo calcula a mano.
8. **Anular un pago restaura** `cuota.monto_pagado` y el estado de la cuota
   (trigger). El pago anulado se PRESERVA en DB (audit trail), no se borra.
9. **Cargos manuales (reconexión, etc.) se asocian al contrato** que provee
   el servicio. Cuentan para el recaudado pero NO para el total fijo del
   contrato.
10. **Consistencia cross-pantalla**: el saldo/recaudado de un cliente debe
    dar idéntico en lista de clientes, detalle de contrato, y reportes. Si
    dos pantallas calculan distinto, una está mal — investigar antes de
    seguir.

**Verificación**: `supabase/tests/invariantes_dinero.sql` corre todas estas
reglas contra la data real. Correr DESPUÉS de cada deploy que toque dinero.
Toda fila debe dar `violaciones = 0`.

### Trazabilidad / audit log (obligatorio para toda entidad)

Toda creación, edición o eliminación de cualquier entidad operativa
(clientes, contratos, cuotas, pagos, recibos, visitas, fotos, cargos, planes)
DEBE generar una fila en `audit_log` vía los triggers genéricos
(`audit_changelog_trg`, migraciones 0047 + 0062 + 0069 + 0076). Reglas:

1. **Creación** → row con `accion='create'`, `valor_anterior=NULL`,
   `valor_nuevo=` snapshot completo. El historial de toda entidad arranca
   con su fila de creación (quién, cuándo, con qué datos).
2. **Edición** → `accion='update'` con `valor_anterior` + `valor_nuevo`.
3. **Eliminación** → `accion='delete'` con snapshot en `valor_anterior`.
4. Al crear una tabla operativa nueva, SIEMPRE agregar su trigger
   `AFTER INSERT OR UPDATE OR DELETE` con el guard `pg_trigger_depth() < 2`.
5. El `HistorialCambiosWidget` renderiza los 3 casos. Verificar que toda
   entidad nueva tenga su historial accesible desde la UI.

#### Modelo del change log (consistente para TODA entidad editable)

El change log NO es opcional ni selectivo: **toda entidad que un usuario pueda
crear/editar/borrar tiene su historial accesible desde su pantalla**, con el
mismo modelo. Aplica a las entidades actuales y a CUALQUIER módulo/tabla que se
agregue en el futuro.

**Fuente de verdad = server.** Las filas del change log las genera el trigger
`audit_changelog_trg` (server-side), NUNCA el cliente. El cliente solo escribe
`ocurrido_en` (device-time) en la fila operativa; el trigger lo propaga a
`audit_log`. Respeta "Server gana" y evita duplicar la lógica de snapshot en
Dart (los triggers de Postgres no corren en SQLite local).

**Dos patrones de UI:**
- **Simple** — `HistorialCambiosWidget(tabla, registroId)`: entidad
  self-contained. Muestra create/update/delete de esa fila. Ej: planes, recibo.
- **Agregador** — widget dedicado (`HistorialCuotaWidget`,
  `HistorialClienteWidget`): entidad que "posee" hijas. Une en UNA timeline
  cronológica los cambios propios + los de sus hijas DIRECTAS. El link a las
  hijas se lee del snapshot JSON
  (`json_extract(COALESCE(valor_nuevo, valor_anterior), '$.<padre>_id')`), NO
  de un `IN (SELECT...)`, para que las hijas borradas físico (ej. fotos) no
  desaparezcan del historial.

**Regla de profundidad (CRÍTICA):** el log del padre agrega solo sus hijas
**DIRECTAS (un nivel)**, nunca nietas. Y para una hija que es a su vez
**contenedora** de otras entidades (ej. contrato → cuotas → pagos), el padre
muestra solo sus eventos de **superficie** (alta / baja / cambio de estado /
reasignación de cobrador), NO sus ediciones puntuales de campos — esas viven
en el log propio de esa hija. Se implementa con `kAuditCamposSuperficie`.
   - Ej: el log del **cliente** muestra cliente + visitas + fotos (completo) +
     contratos (solo superficie). NO muestra cuotas ni pagos: un pago a una
     cuota de un contrato es un evento del log de esa **cuota**, no del cliente.
   - El log de la **cuota** muestra cuota + pagos + recibos (completo). El
     recibo es nieto (cuota → pago → recibo): es la ÚNICA excepción permitida
     a la regla de profundidad, justificada porque es hoja 1:1 del pago, no
     tiene hijas propias, y su número/anulación son parte del rastro de dinero
     (#5). Se vincula por el `pago_id` del snapshot del audit_log, no por JOIN
     a `recibos` (las sync rules excluyen recibos anulados del cobrador).

**Contrato al agregar una entidad/módulo editable nuevo:**
1. Tabla con `tenant_id`, `id` + RLS. Si se crea/edita OFFLINE, agregar
   `ocurrido_en` (device-time); si es online-only del admin, se puede omitir
   (el trigger cae a `created_at`).
2. Trigger `AFTER INSERT OR UPDATE OR DELETE ... EXECUTE FUNCTION
   audit_changelog_trg()`.
3. Registrar la entidad en `audit_changelog.dart`: `kAuditCamposVisiblesDefault`
   + `kAuditCamposCatalogo` + `kAuditEntidadLabel` (+ labels de campos en
   `auditFieldLabel` si faltan).
4. (Opcional) verbo/ícono propio en el switch `_labelFor` del `_CambioTile`.
5. Exponer el historial en su pantalla de detalle (patrón Simple o Agregador).
   Si la pantalla es una lista sin detalle, agregar un botón 🕐 por fila que
   abra el bottom sheet (patrón de `planes` / `cliente`).
6. Si es HIJA de un agregador existente, sumarla a la query del padre
   (`tabla IN (...)` + filtro `$.<padre>_id`), respetando la regla de
   profundidad (hoja → completo; contenedora → superficie).

**Sin límites:** las queries del historial NO llevan `LIMIT` — el change log de
una entidad muestra su vida completa.

**Lifecycle online/offline:** online el flujo es write local → sync sube →
trigger corre → `audit_log` baja → la UI muestra la entrada. Offline el dato
operativo se ve YA (es local), pero la ENTRADA del change log aparece recién al
sincronizar (el trigger es server-side); como `ocurrido_en` carga el
device-time, cuando aparece queda en su hora real, no en la de sync. No se
pierde data.

**Cobertura actual:** trigger en clientes, contratos, cuotas, pagos, recibos,
cargos_extra, visitas, fotos_cliente (0062) + **planes** (0076) + **geografía
per-tenant** (departamentos/municipios/comunidades, 0097) + **red**
(red_nodos/red_hubs/red_puertos, 0098) + **inventario** (inv_categorias/
inv_proveedores/inv_productos/inv_ubicaciones/inv_seriales/inv_movimientos,
0099-0101) + **tickets** (ticket_tipos/tickets/ticket_eventos/ticket_adjuntos,
0103; **ticket_materiales**, 0106; **incidentes**, 0107). Los eventos de **recibos** (emitido / anulado)
se SURFACEAN en el timeline de la cuota (`HistorialCuotaWidget`). Los **movimientos
de inventario** y los cambios del **serial** se unen en `HistorialSerialWidget`
(Agregador cuna-a-tumba), que **TAMBIÉN une `ticket_materiales`** (3C): el consumo
en un ticket instala el serial, pero el `inv_movimientos`/serial derivados los hace
un trigger a depth 2 (no se auditan), así que la fila `ticket_materiales` (sí
auditada, depth 0) es la que surfacea el evento de consumo en el rastro del serial.
Los equipos del cliente se surfacean en `HistorialClienteWidget` (un consumo-install
NO aparece en el log del cliente: es nieto vía ticket → regla de profundidad).
Value-labels de `inv_movimientos.tipo` e `inv_seriales.estado` en `_fmtField`.
**Geografía: gap CERRADO** — al pasar a per-tenant (0097) ya tiene `tenant_id` +
trigger `audit_changelog_trg` + historial en `geografia_admin` (patrón Simple).


| Capa | Tecnología |
|---|---|
| Frontend | Flutter **Android + Windows** (foco actual, distribución vía APK + MSIX). Web existe pero NO es target: el código degrada con `kIsWeb` sin romper (mapa cae a red, descarga de reportes avisa "solo Windows/Android"). |
| State | Riverpod (StreamProvider, FutureProvider.family, StateProvider). |
| Router | go_router con ShellRoute por rol (cobrador / admin / super_admin). |
| Backend | Supabase (Postgres + Auth + Edge Functions Deno + Storage). |
| Sync | PowerSync (offline-first, buckets per-rol con sync rules). |
| SMTP | Resend en sandbox (sin dominio verificado — solo email del owner). |
| Distribución | Hoy: `flutter run -d chrome` local. Producción: TBD (Vercel/Netlify cuando haya dominio). |

### Versiones / paquetes clave
- `supabase_flutter: 2.x`
- `flutter_riverpod: 2.x`
- `go_router: latest`
- `package_info_plus` para anexar app version a los error logs.
- `flutter_map: ^7.0.2` + `flutter_map_cache: ^2.1.0` + `http_cache_file_store: ^2.0.1`
  — caché de tiles del mapa en disco (offline Android/Windows). FMTC se descartó
  porque su última exige flutter_map 8; flutter_map_cache cubre flutter_map 6-8.
- `excel: ^4.0.6` — genera los reportes `.xlsx` (Dart puro). `file_picker` (ya
  existía) hace el guardado/descarga del archivo. OJO: `excel` baja `archive` a
  3.6.1 e `image` a 4.3.0 por constraint — compatible con `pdf`/`printing`.
- Edge Functions usan `@supabase/supabase-js@2.45.0` + Deno std 0.224.0.

### Error logging
Singleton `ErrorLogService` en `lib/data/services/error_log_service.dart`
captura `FlutterError.onError` + `PlatformDispatcher.onError` + zone errors
(via `runZonedGuarded` en `main.dart`). Persiste local en SharedPreferences
(FIFO 200) y sube async a tabla `error_logs` (migración 0035). El viewer
`/super/logs` solo lo alcanza super_admin — usa RPC `list_error_logs` que
hace JOIN con `tenants` y `cobradores`. Pre-login (sin `auth.uid()`) los
logs quedan solo locales porque la RLS exige `user_id = auth.uid()` y
atribuir post-hoc sería incorrecto.

---

## Estructura del repo

```
lib/
├── config/
│   ├── env.dart           # Env vars (--dart-define-from-file=.env.json)
│   └── router.dart        # GoRouter + redirect logic + empresaNombreProvider público
├── data/
│   ├── models/            # Cliente, Cuota, Pago, Recibo, CobradorAdmin, etc.
│   ├── providers/         # cobrador_provider, sync_status_provider, foto_comprobante_provider
│   ├── repositories/      # super_admin_repo, pagos_repo, clientes_repo, settings_repo
│   ├── services/          # foto_comprobante_service, external_actions
│   └── utils/             # formatters, cobrador_helpers, validators (TODO centralize)
├── features/
│   ├── admin/             # Panel del admin del tenant
│   ├── auth/              # login, set_password, cambiar_password_dialog, auth_flow_provider
│   ├── clientes/          # Lista cliente para cobrador (móvil)
│   ├── cobro/             # Flow de cobro en campo
│   ├── cuotas/, historial/, home/, mapa/
│   ├── impresora/         # Bluetooth térmica (kIsWeb gated)
│   ├── recibo/, settings/
│   ├── shared/widgets/    # animated_list_entry, chips, credenciales_dialog, etc.
│   ├── shell/             # AppShell del cobrador
│   └── super_admin/       # /super/tenants, tenant_modulos, miembro_detalle, tenants_list
├── powersync/
│   ├── db.dart, connector.dart, schema.dart
└── main.dart              # Init: Supabase, PowerSync, auth listener, exchangeCodeForSession

supabase/
├── migrations/            # 34 archivos SQL (0001 → 0034+). Linear, append-only.
└── functions/             # 6 Edge Functions Deno
    ├── crear-tenant/, invitar-cobrador/, reenviar-invitacion/
    ├── forzar-password-cobrador/, cambiar-email-cobrador/, eliminar-cobrador/

powersync/sync-rules.yaml  # Bucket definitions per-rol
```

---

## Convenciones de código y workflow

### Idioma y tono
- Español rioplatense (vos, tipear, mandá, etc.). Strings de UI 100% español.
- Comentarios en código: español con términos técnicos en inglés cuando aplica
  ("trigger", "cascade", "rollback", "audit log", etc.).
- Commits: español, primera línea ≤72 chars, cuerpo con bullets cuando hace falta.
- Sin co-authored-by ni firmas tipo "Generated with...".

### Patrón de review obligatorio
**Después de cada cambio significativo, lanzar 3 agentes en paralelo** vía `Agent` tool:
1. **Code Audit** — correctness, security, regressions técnicas.
2. **QA** — escenarios de uso, regresiones funcionales, edge cases.
3. **UX/UI o Deployment Safety** — el tercero varía según el commit (UX para frontend,
   Deployment Safety para migraciones SQL, Security para Edge Functions auth changes).

Aplicar fixes convergentes. NIT individuales se anotan al backlog.

### Audit integral post-BULK
**Al cerrar cada BULK**, lanzar un audit integral (además del audit por PR):
- Cross-BULK consistency: imports rotos, providers huérfanos, dead code.
- Migrations secuenciales, sync rules vs schema.
- Verificar que cada archivo nuevo se usa en al menos un lugar.

### Verificación de integridad DB ↔ Schema ↔ Sync Rules (OBLIGATORIO)
**Antes de cada commit que toque tablas/columnas**, verificar la cadena completa:

1. **Postgres** (Supabase): ¿la columna/tabla existe en la DB real?
   - NO asumir que una migración se ejecutó. Verificar con query.
   - `SELECT column_name FROM information_schema.columns WHERE table_name = 'X'`

2. **PowerSync schema** (`lib/powersync/schema.dart`): ¿la columna está declarada?
   - Cada columna de Postgres que se usa en la app DEBE estar en schema.dart.

3. **Sync Rules** (`powersync/sync-rules.yaml`): ¿el `SELECT *` cubre la columna?
   - Después de agregar columnas a Postgres, SIEMPRE redeployar sync rules.
   - Verificar en PowerSync Dashboard que dice "Active" post-deploy.

4. **Schema version** (`lib/powersync/db.dart`): ¿necesita bump?
   - Si se agregó columna/tabla al schema.dart, bumpear `_schemaVersion`.
   - Sin bump, las DBs locales existentes no ven la columna nueva.

5. **Dart code**: ¿el código que lee/escribe la columna es consistente?
   - INSERT, UPDATE, SELECT, fromRow() — todos deben usar el mismo nombre.

**Checklist de deploy cuando se agrega una columna:**
```
□ Migración SQL corrida en Supabase (ALTER TABLE ADD COLUMN)
□ Verificar en Table Editor que la columna existe
□ schema.dart actualizado con Column.text/real/integer
□ _schemaVersion bumpeado en db.dart
□ Sync rules redeployadas en PowerSync Dashboard
□ Verificar "Active" en PowerSync Dashboard post-deploy
□ App reiniciada desde cero (q + flutter run)
```

**NUNCA asumir que algo existe — verificar siempre.** El costo de verificar
es 30 segundos. El costo de no verificar es horas de debugging.

### Estado actual de sync rules
Las sync rules usan `SELECT *` para todas las tablas operativas.
Esto significa que columnas nuevas se incluyen automáticamente DESPUÉS
de redeployar. Sin redeploy, PowerSync no ve las columnas nuevas.

**Tablas sincronizadas** (via `SELECT *`), por bucket de rol:
- **Todos los roles** (cobrador incluido): clientes, contratos, cuotas, pagos,
  recibos, cargos_extra, notificaciones_mora, planes, settings, visitas,
  fotos_cliente, y **departamentos/municipios/comunidades (per-tenant desde
  0097)** + **red_nodos/red_hubs/red_puertos (0098)** — el cobrador necesita la
  geo/puerto del cliente.
- **Solo admin / admin_cobranza / super_admin impersonando**: `audit_log` +
  **inv_categorias/inv_proveedores/inv_productos/inv_ubicaciones/inv_seriales/
  inv_movimientos (0099-0101)** — inventario es admin-facing, NO baja al cobrador.
- `tenant_modulos`: read-only, SÍ se sincroniza (campos selectivos, `id` agregado
  en 0099 para que PowerSync sincronice la PK) — gatea los módulos opcionales.
- `cobradores` (campos selectivos, no `SELECT *`).

**Schema version ACTUAL (fuente de verdad)**: `_schemaVersion = 26` en
`lib/powersync/db.dart` (cada user tiene su SQLite `sitecsa_{uid}_v26.db`). v17
agregó geo per-tenant + red; v18-v20 el inventario (catálogo→ubicaciones→ledger);
v21-v26 tickets/técnico/incidentes + inventario v2 (stock mínimo, ticket_materiales).
Las menciones a "Schema v4/v6/v16/v20" más abajo o arriba son registros históricos,
NO el valor actual — el real es **26**. Cada bump de schema redeploya sync rules.
Verificar siempre el número en `db.dart`, no confiar en los logs de sprint.

### Proceso mandatorio de fixes y features (lifecycle)

**Fase 1 — Entender el pedido:**
1. Leer el mensaje del usuario.
2. Leer CLAUDE.md (contexto, stack, backlog, checklist de integridad).
3. Leer ROADMAP.md y BULK11-PLAN.md para estado actual.
4. Si toca tablas/columnas, verificar cadena de integridad completa.

**Fase 2 — Pre-evaluación:**
5. Investigar archivos relevantes (grep, read).
6. Identificar qué archivos necesitan cambios.
7. Evaluar riesgos, dependencias, trade-offs.
8. **Presentar propuesta al usuario con opciones (OBLIGATORIO).**
9. **Esperar aprobación antes de implementar (OBLIGATORIO).**

**Fase 3 — Implementación:**
10. Implementar cambio por cambio, committeando cada uno.
11. Si toca tablas/columnas, seguir checklist de integridad DB ↔ Schema.
12. Commit con mensaje descriptivo.

**Fase 4 — Audit post-implementación (OBLIGATORIO):**
13. Lanzar agentes de audit (Code + DB integrity como mínimo).
14. **Presentar findings detallados al usuario:**
    - Qué se encontró exactamente (archivo, línea).
    - Por qué ocurre (causa raíz técnica).
    - Escenario real de impacto (qué le pasa al usuario).
    - Propuestas de solución con trade-offs.
15. **Esperar aprobación del approach de solución (OBLIGATORIO).**
16. Implementar fixes aprobados.
17. Si los fixes son significativos, lanzar audit adicional.

**Fase 5 — Testing:**
18. Dar paso a paso detallado al usuario (formato de `TESTING.md` §0: qué hacer
    → qué debería ver → si falla). Indicar si necesita restart completo vs hot reload.
19. Cada paso incluye: qué hacer, qué debería ver, qué hacer si falla.
20. Si hay migraciones, incluir comandos exactos.
21. Indicar si necesita redeploy de sync rules.

**Fase 6 — Cierre de sesión (OBLIGATORIO, no saltear):**
22. **Actualizar `HANDOFF.md`** — estado actual: branch, último commit, qué se
    hizo, qué queda pendiente / próximo paso. Es lo PRIMERO que se lee al reabrir;
    mantenerlo ≤1 pantalla.
23. **Agregar entrada nueva en `REPORTE-SESION.md`** (más reciente arriba):
    error → fix → expectativa + commits + archivos, y el comportamiento ESPERADO
    de cada feature tocado.
24. **Actualizar `ESTADO-APP.md`** si cambió cobertura/findings/estado real.
25. Si se agregó/cambió un MÓDULO o una interconexión, actualizar `ARQUITECTURA.md`.
26. Si el feature introduce un flujo de testing nuevo, agregar su checklist a
    `TESTING.md` §0.3.
> Sin este cierre, la próxima sesión arranca a ciegas y Rubén pierde tiempo
> re-explicando. El costo de documentar el cierre es minutos.

**Documentos a leer al ABRIR cada sesión (en este orden):**
- **`HANDOFF.md`** (dónde quedamos — SIEMPRE primero)
- CLAUDE.md (reglas/proceso/invariantes/backlog) + `ARQUITECTURA.md` (módulos e interconexiones)
- ESTADO-APP.md + REPORTE-SESION.md (estado real + comportamiento esperado del feature a tocar)
- TESTING.md §0 (loop de testing) · ROADMAP.md
- powersync/sync-rules.yaml · lib/powersync/schema.dart + db.dart
- Archivos específicos del feature

**NUNCA saltar fases.** El costo de seguir el proceso es minutos.
El costo de saltarlo es horas de debugging.

### Checklist de audit obligatorio (post-implementación)

Además de correctness/security/QA, el audit DEBE incluir estos checks
específicos que han causado bugs en producción:

**1. Compatibilidad SQL SQLite vs Postgres (CRÍTICO):**
   - `grep -rn 'FILTER' lib/ --include="*.dart"` → NO debe haber
     `FILTER (WHERE ...)` en NINGÚN archivo. Es sintaxis Postgres,
     SQLite no la soporta. Reemplazar con `SUM(CASE WHEN...THEN 1 ELSE 0 END)`.
   - `grep -rn 'RETURNING\|::text\|::int\|::uuid\|::jsonb' lib/` →
     casts `::tipo` son Postgres-only. SQLite usa `CAST(x AS tipo)`.
   - `grep -rn 'ILIKE\|ANY(\|ARRAY\[' lib/` → funciones Postgres-only.
   - **Scope: TODO el codebase**, no solo archivos modificados.

**1b. Zona horaria / día local (CRÍTICO — norma general):**
   - Para lógica de LÍMITE DE DÍA (vencidas, mora, gracia, "vencen hoy",
     rangos por fecha, conteos "este mes" / "últimos N días") usar SIEMPRE
     `date('now', '-6 hours')` y `julianday('now', '-6 hours')` — **NUNCA
     `date('now')` pelado**. SQLite `date('now')` es UTC; el negocio opera en
     hora de Nicaragua (UTC-6, sin DST), así que el `-6 hours` da el día
     correcto en web y nativo, y coincide con los badges de la UI
     (`DateTime.now()` local). **Aplica a TODO módulo actual y futuro.**
   - `grep -rn "date('now')\|julianday('now')" lib/ --include="*.dart"` →
     cada uno DEBE llevar `'-6 hours'` (los pelados corren 1 día de noche).
   - Server-side (Postgres): **NO** cambiar el timezone global de la DB (rompe
     el wire-format de TODOS los `timestamptz` → PowerSync/cliente). Para
     funciones con lógica de límite de día (mora, generación de cuotas,
     triggers de contrato) agregar `SET timezone = 'America/Managua'` a la
     función (patrón de la migración 0087) — así su `current_date`/`now()` dan
     el día Nicaragua aun llamadas ad-hoc (triggers). Los crons ya se agendan a
     la medianoche Nicaragua (06:05 UTC). Alternativa puntual en una query
     suelta: `(now() AT TIME ZONE 'America/Managua')::date`.

**2. Stream lifecycle con Riverpod (CRÍTICO):**
   - Si un widget es `ConsumerStatefulWidget` y usa `ref.watch()` en
     `build()`, los streams creados en `initState()` DEBEN ser
     `.asBroadcastStream()`. Sin esto, un rebuild por cambio de provider
     causa "Bad state: Stream has already been listened to".
   - **Scope: TODO archivo que combine ConsumerStatefulWidget + StreamBuilder.**

**3. Regresión full-codebase (OBLIGATORIO):**
   - El audit NO se limita a archivos modificados. Debe escanear el
     codebase completo para patrones rotos conocidos:
     - SQL incompatible con SQLite
     - Imports rotos (archivos que importan algo que se movió/renombró)
     - Referencias a columnas droppeadas (ej: `contratos.activo`)
     - Providers huérfanos o dead code
   - Usar grep/find para verificar, no confiar en análisis manual.

**4. Cadena de integridad DB ampliada:**
   - Verificar no solo los archivos modificados sino TODAS las queries
     SQL del codebase que referencien las tablas tocadas.
   - `grep -rn 'tabla_modificada' lib/ --include="*.dart"` para cada
     tabla que haya cambiado de schema.

**5. Rutas GoRouter completas:**
   - Si un widget usa `context.push('/ruta')` o `context.go('/ruta')`,
     esa ruta DEBE existir en `router.dart`.
   - Especial atención a rutas condicionales tipo
     `enAdminShell ? '/admin/x' : '/x'` — ambas variantes deben existir.
   - `grep -rn "context.push\|context.go" lib/ --include="*.dart"` →
     cruzar cada path con las rutas declaradas en router.dart.

**6. Denormalización completa en INSERTs:**
   - Si una tabla tiene columnas denormalizadas (cobrador_id copiado
     de otra tabla), el INSERT desde Dart DEBE incluirlas. Los triggers
     de Postgres NO corren en SQLite local.
   - Verificar cada `INSERT INTO` y comparar columnas con schema.dart.

### Formato obligatorio del reporte de audit

Después de cada audit, presentar un reporte con esta estructura:

```
## REPORTE DE AUDIT — [nombre del sprint/feature]

### Metodología
- Cuántos agentes, qué scope tenía cada uno, cuántos archivos escanearon

### Findings que requieren fix
| # | Severidad | Archivo:línea | Problema | Impacto en usuario |
Para cada finding:
1. **Encontrado por:** qué agente
2. **El error:** código antes (snippet)
3. **Cómo afectaba al usuario:** paso a paso del escenario real
4. **Cómo funciona ahora:** código después (snippet)

### Clean — Sin problemas
Tabla con cada categoría auditada y resultado

### Backlog
Items que no bloquean pero son anti-patterns para sprint futuro
```

**El reporte NO es opcional.** Se presenta al usuario ANTES de hacer
pull/testing. El usuario debe ver exactamente qué se encontró, por qué
pasaba, y cómo se corrigió. Sin este reporte, el sprint no se considera
auditado.

### Modelo de testing de 4 capas (defensa en profundidad)

Los audits estáticos (agentes que leen código) atrapan sintaxis, imports,
SQL incompatible, RLS faltante. NO atrapan bugs de comportamiento con data
real (ej: "el recaudado da 1000 cuando debería dar 500"). Por eso usamos
4 capas complementarias:

| Capa | Qué es | Atrapa | Cuándo correr |
|---|---|---|---|
| **1. Audit estático** | Agentes en paralelo leen código | Sintaxis, imports, SQL Postgres-only, RLS, null safety | Post-implementación, antes del pull |
| **2. Invariantes SQL** | `supabase/tests/invariantes_dinero.sql` | Bugs contables, data corrupta, sobrepagos, recibos huérfanos | Después de cada deploy que toque dinero |
| **3. Tests de repo** | `flutter test` sobre `pagos_repo` y lógica crítica | Lógica de cobro/vuelto/anular/recrear | En cada cambio + CI |
| **4. Manual (Rubén)** | Testing en browser con escenarios reales | UX, flujos completos, percepción visual | Antes de cerrar el sprint |

**Regla:** cualquier cambio que toque dinero (`pagos`, `cuotas`, `recibos`,
`contratos`, cobro, reportes) DEBE pasar por las capas 1, 2 y 3 antes del
testing manual. Las capas 2 y 3 son las que atrapan los bugs que el audit
estático no puede ver.

**Por qué se escaparon bugs históricamente** (lecciones documentadas):
- Bug del vuelto (recaudado inflado): capa 2 lo hubiera atrapado (INV1/INV4).
- Triggers audit solo en UPDATE: requería cruzar `CREATE TRIGGER` con la
  función — el audit ahora verifica explícitamente los eventos suscritos.
- Pagos recientes vacío: solo se ve en runtime — capa 3 (test de la query)
  lo hubiera atrapado.

### Principio de diseño: evaluar ANTES de implementar
Antes de elegir una herramienta/servicio para un feature nuevo (ej:
dónde hosear un archivo, qué package usar, qué API consumir), evaluar
**todas las opciones del stack existente** y elegir la más simple que
resuelva el problema sin agregar dependencias ni pasos manuales. No
asumir que "ya tenemos X, usemos X" sin verificar si hay alternativa
más directa. Documentar la decisión y el trade-off en un comment o en
el commit message.

Checklist pre-implementación:
1. ¿Puedo resolver esto con lo que ya existe en el stack? (GitHub,
   Supabase, PowerSync, Flutter built-in).
2. ¿El approach elegido agrega pasos manuales al workflow del user?
   Si sí, ¿hay alternativa que los elimine?
3. ¿El approach tiene limitaciones conocidas (RLS, file size, rate
   limits) que podrían bloquear después?
4. ¿Cómo se ve el flujo end-to-end desde la perspectiva del user
   (no solo del developer)?

### Audit log es append-only
Las RPCs y Edge Functions que modifican estado sensible escriben a `audit_log`.
**Nunca borrar rows del audit_log** — el patrón es agregar rows (ej: intent + success
para forzar-password). El comment del código explica la decisión.

### Multi-tenant
- TODA tabla operativa tiene `tenant_id` NOT NULL con FK a `tenants(id)`.
- RLS scopa por `current_tenant_id()` (función SECURITY DEFINER que lee del JWT).
- Super_admin tiene policy `super_admin_all` que bypassa scoping (vía `is_super_admin()`).
- Edge Functions usan `callerClient` (JWT del caller, sujeto a RLS) para DB ops normales.
  Sólo `service_role` para `auth.admin.*` y rollback que requiere bypass.

### Server gana
Cuando hay duda entre cliente y server, **server es la fuente de verdad**. El cliente
PowerSync sincroniza, pero queries críticas pasan por server vía RPC o Edge Function.

---

## Cómo deployar (preferencia: NO CLI)

Rubén prefiere Supabase Dashboard sobre CLI por ahora. Workflows:

### Aplicar migración SQL
1. PowerShell: `Get-Content supabase\migrations\NNNN_*.sql -Raw | Set-Clipboard`
2. Verificar el paste en Notepad (primeras + últimas líneas).
3. Supabase Dashboard → SQL Editor → New query → Ctrl+V → Run.
4. Esperá `Success. No rows returned`.

### Redeploy de Edge Function
1. PowerShell: `Get-Content supabase\functions\NOMBRE\index.ts -Raw | Set-Clipboard`
2. Verificar contenido en Notepad.
3. Dashboard → Edge Functions → click función → tab "Code" → Ctrl+A → Delete → Ctrl+V → Deploy updates.
4. Verificar timestamp "a few seconds ago" en la lista.

### Helpers compartidos de Edge Functions (`_shared/`)
Ya existe `supabase/functions/_shared/` y todas las funciones lo importan:
`passwords.ts` (`generarPasswordSegura`), `auth_errors.ts` (`humanizeAuthError`)
y `response.ts` (`corsHeaders`, `jsonError`). Ya NO hay copias inline
duplicadas. **Nota de deploy por Dashboard**: el Dashboard no soporta subir
varios archivos en un paste; al editar una función por Dashboard hay que
asegurarse de que los `_shared/*.ts` ya estén deployados (se mantienen vía
CLI/repo). El bundler de Edge Functions resuelve los imports relativos en
deploy, así que el código fuente queda DRY aunque el flujo de Dashboard sea
por-función.

---

## Reglas de comunicación con Rubén

- Pasos detallados, **un comando por vez** cuando el output importa, con verificación
  explícita antes de avanzar.
- NO asumir confirmación. Si das varios sub-pasos en un bloque, pedí confirmación
  explícita después de cada uno.
- Si se ve el mismo error 2 veces, FRENAR y diagnosticar, no repetir instrucciones.
- Output esperado al lado de cada comando — Rubén compara.
- Mostrar tabla de pros/cons cuando hay decisiones técnicas; recomendar honestamente
  pero dejarlo elegir.

---

## Backlog persistente (no de un sprint específico)

Estos viven acá hasta que se ataquen explícitamente. NO re-flag en audits.

> **⚠️ RE-VERIFICACIÓN 2026-06-03 (leé esto ANTES de tocar el backlog de abajo).**
> Se auditó CADA ítem contra el código real (3 agentes). MUCHOS estaban resueltos
> pero sin tachar — **NO los re-flaggees**. Estado real:
>
> **YA RESUELTOS (aunque el bullet de abajo siga sin tachar):**
> - **Rework super_admin COMPLETO** — impersonación (migr 0039/0078/0082) + "entrar
>   como tenant" + toggle de módulos + audit start/end + banner "Viendo: X". Ya NO es
>   "sprint futuro grande". Las acciones de campo se bloquean adrede en impersonación.
> - **Paginación** de clientes (admin + cobrador). `clientesAsignadosProvider` ya no existe.
> - **PopScope sidebar** (forms dirty): `closeModalsAndGoGuarded` + `formDirtyProvider`.
> - **OfflineBanner**: botón Reintentar + fade + indicador de red inestable.
> - **Error logging**: rate-limit (5s), índice `error_type`, debounce search (400ms),
>   RPC `purge_error_logs` + **botón "Borrar logs"** en `/super/logs`, user-agent (proxy plataforma).
> - **main.dart double-connect** (guard por identidad) + **listener de ErrorLogService** (se cancela).
> - **Edge Functions**: audit row si signOut-fail + ghost-user cleanup + chequeo `SYSTEM_TENANT`.
> - **R12 `==`/`hashCode`**: Pago/Modulo/Setting/CobradorStats (Contrato no aplica, es `Map`).
> - **Admin pagos**: badge `grupo_cobro`. **Distribución**: scaffolds Android/Windows + update
>   service + MSIX ya están (falta SOLO config de producción: applicationId, cert, deep-links).
>
> **GENUINAMENTE PENDIENTES (todos LOW):**
> - `reenviar-invitacion`: lock delete→create (race solo con super_admins concurrentes).
> - `_humanizarError`: 2 copias en pantallas (gated a un fix del SDK de `FunctionException`).
> - `FotoComprobanteService`: persistir último resultado (F5 lo pierde; replay en memoria sí).
> - Error logging: filtro fechas desde/hasta · cron diario de purga >90d · UA real (`package:web`).
> - Tests: widget + integración + redirects del router (0 hoy) · 4 tests edge_functions skipped (falta mockito).
> - UX parciales (mitigados): sync-gate stuck (telemetría puesta, falta repro) · flash wizard (flows
>   secundarios) · race `_rolUsuarioProvider` (enmascarado por sync-gate).
> - Edge cases bajo valor: `lastSyncedAt` semantics · cross-tab sin sync · race autoDispose entre
>   tenants · PKCE recovery user-switch · BULK 12 Sprint 5 (polish) · Resend dominio (externo).
>
> **PARQUEADOS por decisión de Rubén:** flags `modo_ruta`/`caja_chica` (ocultas) · geo del cobro (no por ahora).

- ~~**`ps.db.watch` inline en `build()` — anti-patrón a barrer del repo**~~.
  RESUELTO (audit total 2026-06-02): el barrido está prácticamente completo.
  El resto de las pantallas ya migró a `late final Stream` en `initState` /
  `_buildStream()` / provider (verificado: 0 callsites inline en
  ConsumerStatefulWidget con `ref.watch` en build). Quedan SOLO 2 callsites
  inline en `geo_picker.dart:109,138` (municipios/comunidades) y son
  **by-design**: el widget es `StatefulWidget` plano (NO Consumer, no
  `ref.watch` en build), así que rebuilds externos no lo afectan; sus params
  cambian en cascada (depto→municipio→comunidad) con su propio `setState`.
  Anti-patrón controlado, no crash-prone.
- **OfflineBanner follow-ups del sprint debounce**:
    - **Indicador de red inestable**: el debounce de 3s silencia flickers
      rápidos (`false → true → false` en <3s) — bueno para ocultar el
      handshake, malo para señalar "red intermitente real". Agregar un
      indicador sutil aparte del banner (ej. ícono de nube en topbar
      con opacity menor) cuando hubo N flickers en M segundos.
    - **Indicador durante los primeros 3s offline**: el cobrador en
      modo avión tipea data por 3s sin feedback visual. Aunque la data
      persiste offline-first, sería bueno un indicador más leve antes
      del banner full (ej. nube en topbar atenuada).
    - **Botón "Reintentar" en el banner**: hoy el user puede solo
      esperar al heartbeat de PowerSync. Botón que llame
      `disconnectPowerSync() + connectPowerSync()` (mismo flow del
      SyncGate retry) ayudaría en red caída transient.
    - **AnimatedSwitcher para fade del banner**: hoy es pop visual.
      Fade 150ms al entrar/salir es más pulido.
- **Error logging — follow-ups del sprint 0035**:
    - **Paginación del viewer `/super/logs`**: hoy limit hard-coded a 100
      con cap server-side a 500. Sin cursor ni filtro de rango fechas.
      Cuando la tabla crezca, agregar `desde/hasta` + "Cargar más".
    - **Retention policy**: tabla crece sin cota. Cron diario que purgue
      logs > 90 días + RPC `purge_error_logs(p_before timestamptz)` con
      guard super_admin para purga manual.
    - **Rate limit**: un device en crash-loop puede meter cientos de rows/seg.
      Bajo MVP el RLS `user_id = auth.uid()` evita spam anónimo, pero
      no spam autenticado. Mitigación: rate limit en cliente (max 1 entry
      / 5s por mensaje similar) o función `insert_error_log` con cooldown.
    - **Índice por `error_type`**: hoy seq scan en el filtro de chips.
      OK bajo 10k rows, escala mal.
    - **Debounce en search del viewer**: hoy `onSubmitted` (sin debounce).
      Consistente con `audit_admin` que también es onSubmitted, pero los
      otros buscadores del repo usan ~400ms debounce.
    - **`_currentRoute()` lee `Uri.base.path`**, no la ruta de GoRouter.
      Con `pathUrlStrategy` ambas coinciden en web normalmente, pero si
      en el futuro el path-vs-url diverge, queda stale. Inyectar
      `GoRouterState` actual cuando se exponga vía un provider.
    - **Botón "Borrar logs" en `/super/logs`**: super_admin no puede purgar
      desde UI (solo `clearLocal()` que es local). Útil con la RPC de
      retention.
    - **Auth listener de `ErrorLogService.init()` nunca se cancela** —
      mismo patrón del listener de `main.dart` ya anotado en backlog.
      Cuando se ataque uno, atacar el otro.
    - **`reported_at` vs `ts` redundantes en UI**: hoy el viewer solo
      muestra `ts`. El delta (`reported_at - ts`) sería útil para detectar
      crashes offline subidos tarde. Agregar como columna o detail.
    - **User agent del browser**: el cliente lo deja null hoy (no usamos
      `package:web`). Útil para diagnosticar bugs específicos de browser.
- ~~**Edge Functions — `humanizeAuthError` duplicado en 5 funciones**~~.
  RESUELTO: consolidado en `supabase/functions/_shared/auth_errors.ts`; las 6
  funciones lo importan. Ya no hay copias inline. (Mismo `_shared/` aloja
  `passwords.ts` y `response.ts`.)
- **`invokeEdgeFunction` workaround `_humanizarError` duplicado**. Aparece copy-
  pasted en `tenant_dialogs_invitar.dart`, `cobradores_admin_screen.dart` y
  en el catch defensivo del helper mismo. Cuando el SDK arregle el type mismatch
  de `FunctionException`, hay 3 lugares que limpiar. Considerar exportar como
  helper público desde `edge_functions.dart` y consumirlo en callers.
- **Race teórica del double-connect en `main.dart`**. El listener async de
  `onAuthStateChange` y el fallback manual de connect pueden ejecutarse en
  paralelo. El comment lo reconoce pero no usa un lock/latch. Probable que
  PowerSync.connect sea idempotente; verificar y/o agregar guard.
- **`forzar-password-cobrador` no chequea `tenant_id === SYSTEM_TENANT`**.
  Bloquea targets con `rol === 'super_admin'` pero no defiende contra un admin
  que esté en el tenant System por algún bug futuro. Defensa en profundidad.
- **R12 cobertura incompleta**: `Pago`, `Contrato`, `Modulo`, `Setting`,
  `CobradorStats` siguen sin `==`/`hashCode`. `Modulo` se usa en
  `FutureProvider<List<Modulo>>` (`super_admin_repo.dart`). Si en el futuro
  se exponen los demás como Streams, el flicker reaparece.
- **Cross-tab no sync entre tabs del mismo browser**. Tab A queda con sesión
  vieja si tab B hace signOut — los `onAuthStateChange` events son por
  `SupabaseClient` instance, no cross-tab. Hasta el refresh del token (~1h)
  o reload manual.
- **Race autoDispose en navegación rápida entre tenants**. Si el user navega
  super rápido entre 2 tenants y el `read(.future)` del provider autoDispose
  sigue en vuelo, puede tirar `ProviderDisposedException` o devolver datos
  del tenant equivocado. Edge case, no reproducible en flujo normal.
- **Edge Functions — hardening incremental (security audit MEDIUM)**:
    - `forzar-password-cobrador`: si `auth.admin.signOut(uid, "global")` falla
      post-éxito, el target sigue con JWT viejo hasta ~1h. Hoy solo se loguea.
      Agregar audit row `force_password_reset_signout_failed` para trazabilidad.
    - `reenviar-invitacion`: ventana entre `deleteUser` y `createUser` sin
      lock — explotable solo con super_admins concurrentes (Rubén es 1 en
      producción, marcado como hardening defensivo).
    - ~~`cambiar-email-cobrador` pre-flight cap a 1000 users~~. RESUELTO: el
      pre-flight ya usa una RPC SECURITY DEFINER que consulta `auth.users`
      directamente, sin el tope de `listUsers({ perPage: 1000 })`. Sin falsos
      negativos por escala.
    - `invitar-cobrador`: ghost user si una excepción tira post-
      `createUser` exitoso (path no-email). El user queda creado con
      password aleatoria que nadie verá. Recuperable vía
      `forzar-password-cobrador`. Replicar el patrón `userIdParcial`
      outer-scope + cleanup de `crear-tenant` si vale el esfuerzo.
- **Sync gate se cuelga indefinidamente post-forzar-password (F5 lo desbloquea)**.
  Caso reproducido en smoke testing: tras `forzar-password-cobrador`, el
  admin afectado logea y entra al sync gate. El gate aparece, muestra el
  mensaje de 30s ("primer sync puede tardar varios minutos"), pero NO
  avanza ni libera nunca. Sólo un refresh manual del browser (F5) lo
  desbloquea — después de F5, el sync completa rápido y la app carga
  normal. Esto sugiere que el `connectPowerSync()` que se dispara en el
  `onAuthStateChange.signedIn` listener queda en algún estado limbo
  (¿race con el sync gate? ¿`lastSyncedAt` no se emite tras el primer
  checkpoint?). F5 reinicializa todo desde cero y funciona.
  **Estado actual**: PR #17 deployó telemetría con prefix `[SYNC-DIAG]`
  en consola + captura al `ErrorLogService` de excepciones que antes
  quedaban silenciadas en los `await` async del listener
  (`connectPowerSync` post-signedIn, fallback manual, `status.anyError`).
  La próxima reproducción del bug aparecerá en `/super/logs` con info
  concreta. Hipótesis a confirmar con los logs: PowerSync entra en
  estado de error post-signOut global sin emitir checkpoint, o el
  `connectPowerSync` tira excepción que estaba siendo tragada.
- **Flash del setup wizard al loguearse — fix incompleto del PR #8**.
  El PR #8 resolvió el caso post-forzar-password (signOut global resetea
  cache → settings vacío al primer build → guard redirigía a onboarding).
  Pero el flash persiste en flows secundarios: hot restart de Flutter
  durante dev, posiblemente otros casos de race entre los providers
  `empresaNombreProvider` y `empresaNombreRowExistsProvider` cuando los
  streams de PowerSync emiten en orden distinto. UX menor — el user
  termina en `/admin` correctamente, solo ve un destello del wizard
  durante <500ms. Decidimos atacarlo cuando enfoquemos sprint de UI/UX
  multi-plataforma (web + Android + Windows installer) — ahí podemos
  agregar animaciones de transición que enmascaren el flash y/o
  refactorear el guard del router para ser más estable.
- **PopScope guard NO cubre `context.go(...)` del sidebar** — el guard
  implementado en `cliente_form_screen.dart` y `contrato_form_screen.dart`
  intercepta `Navigator.pop()` (browser back, hardware back, botón
  Cancelar imperativo), pero NO la navegación con `context.go(...)`
  porque ese es replace de ruta, no pop. Si el user tiene un form
  dirty y toca un item del sidebar (que usa `closeModalsAndGo`), los
  cambios se pierden sin warning. Fix futuro: coordinar shell ↔ form
  vía Provider/InheritedWidget — el shell consulta si la pantalla
  actual tiene dirty antes de navegar. Workaround actual: el back
  arrow del PR #31 usa `closeModalsAndGo` — mismo gap. Forms wizards
  (onboarding multi-step) tampoco están cubiertos. Sprint propio.
- **Race del `_rolUsuarioProvider`** cuando se navega a `/super/*` vía URL directa o refresh —
  el rol provider tarda en cargar y el guard del router rebota a `/admin`. Same fix que el
  back button (gate en shell + smart provider state).
  **Manifestación adicional confirmada**: post-login del super_admin, el redirect
  inicial cae en `/admin` por ~1-2s antes de corregir a `/super/tenants` cuando llega
  el rol del provider. Decisión del user: aceptable por ahora — atacar cuando se
  haga el rework de super_admin UI/UX (ver item siguiente).
- **Rework del super_admin UI/UX (sprint futuro grande)**. El super_admin actual
  vive con una shell minimal (`/super/tenants` + `/super/logs` + detalle de tenant/
  miembros). El user quiere que pueda:
    1. **Hacer todo lo que un admin puede** — el super_admin debe tener TODO el
       acceso del admin del tenant, no un subconjunto.
    2. **Seleccionar un tenant y actuar como su admin** (impersonate). Hoy si el
       super_admin quiere ver/editar clientes del tenant X, no tiene UI para
       "entrar como admin de X". Necesitaría: selector de tenant en super_admin
       que cambie `current_tenant_id` y le dé al super_admin la vista del
       `AdminShell` con la data del tenant elegido. Requiere refactor de
       `current_tenant_id()` SQL (que hoy lee de `cobradores`) para que
       super_admin pueda overridear vía algún state cliente o JWT claim
       custom. **Sensible: hay que pensar el threat model — un override de
       tenant del super_admin debe quedar en audit_log con un timestamp y
       UI que muestre claramente "estás viendo el tenant X" para evitar
       confusión / cambios en el tenant equivocado.**
    3. **Toggle de activar/desactivar módulos por tenant**, ya implementado
       en `/super/tenants/:id` (`tenant_modulos_screen.dart`) — vale revisar
       que la UI de modules sea fácil de descubrir desde el flow nuevo de
       "entrar a un tenant".
  Decisión operativa del user: este rework se planea cuando enfoquemos sprint
  de UI/UX multi-plataforma (web + Android + Windows installer). Hoy el
  super_admin opera ok como está, solo es ineficiente.
- **PowerSync `lastSyncedAt` semantics** — verificar (con docs PowerSync) si el checkpoint
  signal puede llegar antes de aplicar los DELETEs de buckets descartados. Si sí, queda una
  ventana de race de algunos ms post-sync-gate donde la UI ve cache stale.
- **PKCE recovery con user-switch** (edge case raro): user A loggeado + user B clickea
  recovery link en el mismo browser → flow termina mostrando sync gate post-set-password.
  UX inesperada pero técnicamente correcta. Documentar o detectar y skipear.
- **Auth listener en main.dart nunca se cancela** — causa exceptions en consola al hot-restart
  en dev (intenta `container.read` sobre container disposed). En prod no se manifiesta.
- **R8 follow-ups**: el `StreamController.broadcast()` del `FotoComprobanteService` no replaya, así
  que F5/reload pierde el último UploadResult con failures. Mitigación futura: persistir
  `lastFailureSummary` en SharedPreferences o agregar un badge en el shell con count de fallidas
  recientes. El próximo intento de upload re-emite si la causa persiste, así que en práctica el
  user se entera eventualmente.
- ~~**`aplicado_en` / `anulada_en` en hora LOCAL, no UTC**~~. RESUELTO (B10 del audit
  2026-06-08): los 3 sitios (`aplicar_cargo_dialog`, `_anular` de `cuotas_admin_screen`,
  `_cancelarYLiquidarCuotas` de `contrato_detail_screen`) ya escriben `.toUtc()`,
  consistente con `ocurrido_en`. **NOTA de convención (audit 2026-06-09)**: `fecha_pago`
  y `tickets.created_at` quedan **local-naive A PROPÓSITO** — su wall-clock Nicaragua
  almacenado "como si fuera UTC" es lo que mantiene correcto el bucketing por
  `date(fecha_pago)` de reportes/arqueo. NO normalizarlos a `.toUtc()` sin migrar
  también todos los cortes por día. El SLA de tickets lee `created_at` vía
  `parseTicketWallClock` (ticket_sla.dart) que interpreta los componentes como
  wall-clock local — correcto pre y post-sync.
- **Resend en sandbox** — limita el flow email a "self-invite del owner". Por eso el modo
  no-email es el default operacional. Cuando Rubén compre dominio, verificarlo en Resend
  y el switch ON del crear-tenant funciona naturalmente.
- **Distribución desktop/Android pendiente**. Hoy solo web. `Uri.base.origin` usado en
  4 lugares con guard `kIsWeb` — cuando portemos, reemplazar con deep links (app links
  Android, scheme registrado Windows).
- **Sin pagination** en `clientesAsignadosProvider` y la lista admin de clientes — explota
  a 10k+ rows. R15 del sprint hardening.
- **BULK 11 backlog completado + audit integral aplicado** (B4 + C3 + C4):
    - B4 Multi-cuota: ✅ long-press multi-select + cobro batch + recibo global.
      Guard: cuotas manuales (contrato_id NULL) no permiten multi-select.
      Monto read-only en multi-cuota. Recibo filtra anulados.
    - C3 Cargo reconexión: ✅ auto-insert en transacción del cobro.
    - C4 Descuento pronto pago: ✅ tipo explícito (porcentaje/monto) via setting.
    - Migraciones 0043 (grupo_cobro), 0044 (descuento tipo), 0045 (seed actualizado).
    - Bluetooth print: nullable-safe para cuotas manuales (plan_nombre/dia_pago).
    - Pago model: campo grupo_cobro en Pago.fromRow.
- **Sesión 3 — Per-user DB + Change Log + UX Sprint**:
    - Per-user PowerSync DB: cada usuario tiene su propio SQLite (sitecsa_{uid}_v4.db).
      Resuelve sync gate stuck sin re-descargar data. Schema version en filename.
    - Change Log: triggers genéricos en pagos/cuotas/clientes/contratos/recibos.
      Widget HistorialCambiosWidget reutilizable. Migración 0047.
    - Sign-out: confirmarSignOut() verifica CRUD pendiente antes de cerrar sesión.
    - UX Sprint (7 items): tenant name en AppBar, cuotas tabs (por cobrar + por
      cliente con card-per-client), multi-select con orden obligatorio, próximas
      visitas en home, búsqueda global, post-cobro botones en recibo, sparkline.
    - Tipo cargo manual: dropdown (reconexión/instalación/mora/reparación/otro)
      con columna tipo_cargo_manual + badges visuales en 3 vistas.
    - Recrear pago anulado: botón en admin pagos, guard contra doble-pago.
    - Colores mejorados: En gracia → ámbar (no verde).
    - Guard correlativo: SIEMPRE consulta server MAX antes de generar recibo
      (sync rules excluyen recibos anulados del cobrador).
    - Boolean defense: settingValue maneja strings "true"/"false" de PowerSync.
    - StreamBuilders: 23 archivos fixeados con initialData + hasError.
    - Banner red inestable: solo cuenta desconexiones reales (no lifecycle).
    - Migraciones 0043-0051 deployadas. Schema v4. Sync Rules redeployadas.
    - Admin cuotas: orden ASC + filtro pendiente con rango de días.
    - BULK 12 Sprint 1 completado: sidebar simplificado (6 items).
- **BULK 12 — Rework UI/UX Admin** (en progreso):
    - Sprint 1 ✅: sidebar simplificado.
    - Sprint 2 ✅: detalle cliente unificado (admin+cobrador), filtro activos,
      sección contratos, role detection.
    - Sprint 3 ✅: ContratoDetailScreen (cuotas multi-select, pagos, status
      change dropdown, historial cambios). Migración 0052 (contrato.estado).
      Rutas /admin/contratos/:id y /contratos/:id.
    - Sprint 4 ✅: fotos múltiples (tabla fotos_cliente, FotoGalleryWidget,
      max 10, upload via image_picker, sync rules). Migración 0053. Schema v6.
    - Sprint 5 pendiente: polish + testing integral.
    - Ver BULK12-PLAN.md para wireframes y decisiones confirmadas.
- **Admin pagos sin grupo_cobro visual**: los pagos multi-cuota aparecen como N
    filas separadas en `/admin/pagos` sin indicador de agrupación. UX aceptable
    por ahora — sprint futuro si un admin lo pide.

---

## Estado del sprint actual

Ver **`SPRINT-HARDENING.md`** para el detalle del sprint en curso (DB integrity + Edge
Functions resilience + Frontend bugs).
