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
- Edge Functions usan `@supabase/supabase-js@2.45.0` + Deno std 0.224.0.

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

- **OfflineBanner false-positive** durante handshake inicial PowerSync (~2s "Sin conexión"
  antes de establecerse). Necesita debounce de ~3s.
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
