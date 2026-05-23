# CLAUDE.md

Contexto persistente del proyecto **Cobranza ISP** para sesiones futuras de Claude Code.
Si estás abriendo este repo por primera vez en esta sesión, leé este archivo primero.

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
   con foto del comprobante y geo del cobro, imprime recibo Bluetooth térmico.
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
- `/admin/reportes` — reportes operativos.
- `/admin/audit` — log de cambios sensibles del tenant (solo admin).
- `/admin/geografia` — CRUD jerárquico depto → municipio → comunidad
  (solo admin).
- `/admin/settings` — config del tenant: empresa, cobranza, pagos, recibos
  (solo admin).
- `/admin/onboarding` — wizard inicial (cuando `empresa.nombre` vacío).

**`admin_cobranza`** ve un subconjunto del admin: NO accede a planes,
cobradores, audit, geografía, settings (guardia explícita en el router).

**Cobrador** (`/*`, móvil-first)
- `/` — pantalla inicio con resumen del día.
- `/clientes` — lista de clientes asignados.
- `/cuotas` — cuotas pendientes (ordenadas por mora descendente).
- `/mapa` — clientes geolocalizados (planificada o libre según setting
  `cobranza.modo_ruta`).
- `/historial` — sus cobros anteriores.
- `/perfil` — datos del cobrador, config impresora Bluetooth.
- `/clientes/:id` — detalle de un cliente (push, fuera del shell).
- `/cobro/:cuotaId` — flow de cobro: monto, método, foto del comprobante,
  geo del cobro, imprimir recibo.
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
- `cuotas` — generadas mensualmente del contrato (estados:
  `pendiente` / `parcial` / `pagada` / `en_gracia` / `vencida` / `anulada`).
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


| Capa | Tecnología |
|---|---|
| Frontend | Flutter Web (foco actual). Eventualmente Android + Windows installer (R8 distribución). |
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

### Limitación conocida del Dashboard
NO soporta multi-file via paste — `_shared/passwords.ts` no funcionaría. Por eso
`generarPasswordSegura` está **duplicada inline** en crear-tenant y reenviar-invitacion
(comentado en código). Si migramos a CLI en el futuro, mover a `_shared/`.

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

- **`ps.db.watch` inline en `build()` — anti-patrón a barrer del repo**.
  Resuelto en `geografia_admin_screen.dart` (Screen + tiles convertidos
  a StatefulWidget con stream `late final` en initState). Quedan
  ~25 callsites más con el mismo anti-patrón: clientes, contratos,
  planes, cuotas, pagos, audit, recibo, historial, perfil, geo_picker,
  reportes, etc. Hoy no crashean porque sus widgets parent no reciben
  triggers de rebuild externos, pero replican el bug latente. Sprint
  propio de hardening cuando aparezca el primer crash o cuando se
  toque alguna de esas pantallas por otra razón. Patrón fix:
  StatefulWidget + `late final Stream` en `initState`, `didUpdateWidget`
  defensivo si los params del query dependen del widget.
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
- **Animación brusca login → shell** post-sync-gate. El spinner desaparece y aparece
  el shell sin transición. Recomendado: fade transition de 200-300ms.
- **Edge Functions — `humanizeAuthError` duplicado en 5 funciones**. Cada Edge
  Function tiene su propia copia inline del helper (limitación del Dashboard
  que no soporta `_shared/`). Cuando migremos a CLI, consolidar en `_shared/`.
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
    - `cambiar-email-cobrador` pre-flight cap a 1000 users: `listUsers` con
      `perPage:1000` cubre hasta 1000 totales. Si el sistema crece más allá,
      el pre-flight da falsos negativos silenciosos → vuelve la polución
      del audit. Migrar a RPC SECURITY DEFINER cuando importe.
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
- **PopScope guard en forms con cambios sin guardar** — hoy un tap accidental
  en Cancelar, browser back o cambio de tab descarta cambios silenciosamente.
  Usar `PopScope(canPop: !_dirty, onPopInvokedWithResult: …)` cuando se
  ataque.
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
- **Resend en sandbox** — limita el flow email a "self-invite del owner". Por eso el modo
  no-email es el default operacional. Cuando Rubén compre dominio, verificarlo en Resend
  y el switch ON del crear-tenant funciona naturalmente.
- **Distribución desktop/Android pendiente**. Hoy solo web. `Uri.base.origin` usado en
  4 lugares con guard `kIsWeb` — cuando portemos, reemplazar con deep links (app links
  Android, scheme registrado Windows).
- **Sin pagination** en `clientesAsignadosProvider` y la lista admin de clientes — explota
  a 10k+ rows. R15 del sprint hardening.

---

## Estado del sprint actual

Ver **`SPRINT-HARDENING.md`** para el detalle del sprint en curso (DB integrity + Edge
Functions resilience + Frontend bugs).
