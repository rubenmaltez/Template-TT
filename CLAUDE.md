# CLAUDE.md

Contexto persistente del proyecto **Cobranza ISP** para sesiones futuras de Claude Code.
Si estás abriendo este repo por primera vez en esta sesión, leé este archivo primero.

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
(clientes, contratos, cuotas, pagos, recibos, visitas, fotos, cargos) DEBE
generar una fila en `audit_log` vía los triggers genéricos
(`audit_changelog_trg`, migración 0047 + 0062). Reglas:

1. **Creación** → row con `accion='create'`, `valor_anterior=NULL`,
   `valor_nuevo=` snapshot completo. El historial de toda entidad arranca
   con su fila de creación (quién, cuándo, con qué datos).
2. **Edición** → `accion='update'` con `valor_anterior` + `valor_nuevo`.
3. **Eliminación** → `accion='delete'` con snapshot en `valor_anterior`.
4. Al crear una tabla operativa nueva, SIEMPRE agregar su trigger
   `AFTER INSERT OR UPDATE OR DELETE` con el guard `pg_trigger_depth() < 2`.
5. El `HistorialCambiosWidget` renderiza los 3 casos. Verificar que toda
   entidad nueva tenga su historial accesible desde la UI.


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

**Tablas sincronizadas** (via `SELECT *`):
- clientes, contratos, cuotas, pagos, recibos, cargos_extra
- notificaciones_mora, planes, settings, audit_log
- departamentos, municipios, comunidades (globales)
- cobradores (campos selectivos, no `SELECT *`)

**Última versión deployada**: Sync Rules version 4 (0037), deployed May 26, 2026.

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
18. Dar paso a paso detallado al usuario.
19. Cada paso incluye: qué hacer, qué debería ver, qué hacer si falla.
20. Si hay migraciones, incluir comandos exactos.
21. Indicar si necesita redeploy de sync rules.

**Documentos a leer en cada sesión:**
- CLAUDE.md, ROADMAP.md, BULK11-PLAN.md
- powersync/sync-rules.yaml
- lib/powersync/schema.dart + db.dart
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
