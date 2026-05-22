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

## Stack

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

- **Flash del setup wizard al loguearse como admin**. Cuando un admin de
  tenant (no super_admin) se loguea, por ~1s aparece la pantalla de setup
  inicial del tenant antes de redirigir al dashboard. Es un bug de
  race/hydration: el guard del router (`empresaNombreProvider`) detecta
  `null` hasta que PowerSync sincroniza la tabla `settings`, ahí flippa
  a un valor concreto y rebota a `/admin`. Solo afecta UX (no funcional)
  pero da impresión de que la app está rota. Posible mitigación: mostrar
  SyncGateScreen también cuando el rol admin tenga `empresaNombreProvider`
  en loading inicial (no solo `hasValue && value == null`).
- **OfflineBanner false-positive** durante handshake inicial PowerSync (~2s "Sin conexión"
  antes de establecerse). Necesita debounce de ~3s.
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
- **Dashboard admin: overflow vertical en cards en narrow viewport** (~< 500px). El
  `childAspectRatio: 4` para 1 columna deja altura insuficiente; el contenido (icon +
  label + value + sub) tira "BOTTOM OVERFLOWED BY 18 PIXELS". Pre-existente, no de R10.
  Fix: bajar el ratio a `3.2` o agregar `mainAxisSize: MainAxisSize.min` con padding
  reducido.
- **Validator de teléfono permite letras si hay 8+ dígitos**. El validator usa
  `sanitizePhoneForWhatsApp` (regex `[^0-9]`) para contar dígitos, pero al guardar
  persiste el valor original con letras intactas. Resultado: BD termina con
  `"abc12345678"` en `clientes.telefono`. Al usarlo (llamar, WhatsApp) los sanitizers
  limpian al consumir, pero el form lo muestra horrible. Fix: TextFormField con
  `inputFormatters` que rechace caracteres no `[0-9+]`, o sanitizar al guardar
  además de al validar.
- **Sync gate (R7) sin feedback de progreso en syncs iniciales largos**. Caso
  reproducido en testing manual: super_admin (que ve todos los tenants) se loguea
  tras haber estado como admin de un tenant. PowerSync hace delete-and-replace
  de TODOS los buckets locales — con varios tenants, el sync inicial tarda
  varios MINUTOS, no segundos. El gate técnicamente funciona (espera al sync) pero:
    1. Los timeouts del escape hatch (8s "tardando", 25s botón "Volver al login")
       son arbitrarios y aparecen muy pronto, engañando al user que cree que
       la app está colgada.
    2. No hay feedback de progreso del download (PowerSync expone
       `downloadProgress.downloaded / total` que podríamos mostrar).
    3. El escape hatch no resuelve nada — si el user lo toca y vuelve a entrar,
       el siguiente login será igual de lento.
  Fix futuro: mostrar barra de progreso si `downloadProgress != null`, texto
  explícito "Primera vez sincronizando, esto puede tardar varios minutos en
  cuentas con mucha data", y subir el timeout del escape hatch a ~2 min con
  un mensaje claro de "Reintentar conexión".
- **Switch "Enviar email de invitación" inconsistente entre dialogs**. El dialog
  "Crear nuevo ISP" (super_admin) tiene el switch para alternar entre modo email
  y modo no-email (password generada server-side). Pero los dialogs `InvitarAdminDialog`
  (super_admin invitando admin a tenant existente) y `_InvitarDialog`
  (admin invitando cobrador dentro del tenant) NO tienen ese switch — solo flujo email.
  Inconsistente con el workflow operativo dominante. Fix: replicar el patrón del switch
  en ambos dialogs + manejar el CredencialesDialog post-success cuando viene la password
  del server. La Edge Function `invitar-cobrador` probablemente ya soporta el parámetro
  `enviar_email: false` (verificar). Feature gap, no del sprint.
- **AppBar back arrow ausente en sub-rutas** — el AdminShell y SuperShell tienen
  `drawer:` así que el leading auto-implícito es el hamburger menu, no el back
  arrow, incluso después de un `push` que sí permitiría `canPop()`. Material no
  overridea hamburger por back arrow. R9 mejoró el behavior del browser back y
  el botón Cancelar, pero el affordance visual sigue siendo hamburger. Fix
  futuro: leading condicional en el shell que muestre IconButton(arrow_back)
  cuando `GoRouterState.of(context).matchedLocation` es una sub-ruta CRUD.
- **PopScope guard en forms con cambios sin guardar** — hoy un tap accidental
  en Cancelar, browser back o cambio de tab descarta cambios silenciosamente.
  Usar `PopScope(canPop: !_dirty, onPopInvokedWithResult: …)` cuando se
  ataque.
- **Race del `_rolUsuarioProvider`** cuando se navega a `/super/*` vía URL directa o refresh —
  el rol provider tarda en cargar y el guard del router rebota a `/admin`. Same fix que el
  back button (gate en shell + smart provider state).
- **Super_admin landing va a `/`** después de login en vez de `/super/tenants`. El branch del
  redirect que detecta rol admin/super lo manda a `/admin` por default, pero super_admin
  termina en HomeScreen del cobrador hasta que navegue manual. Pre-existente al R7.
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
- **Sin tests automatizados**. Carpeta `test/` no existe. `pagos_repo._calcularEstado`
  mirror del trigger SQL es riesgo top — primer test a escribir cuando arranquemos.
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
