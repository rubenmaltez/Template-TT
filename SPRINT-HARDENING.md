# Sprint Hardening (pre-producción)

> Archivo **temporal**. Borrar cuando el sprint cierre (después del Día 3 + merge a `main`).
> Para contexto permanente del proyecto, ver `CLAUDE.md`.

---

## Origen

4 audits paralelos sobre `claude/powersync-sdk-setup-KZF1R` antes de
mergear a `main`:

1. **Security** (auth, RLS, edge functions, JWT, signOut global).
2. **Database** (RLS policies, índices, audit_log, integridad referencial).
3. **Edge Functions** (idempotencia, atomicidad, rollback, error
   handling, scrubbing de mensajes internos).
4. **Architecture** (Riverpod patterns, go_router, sync, PowerSync
   buckets, navegación, dispose).

Resultado: 22 findings (R1–R22) — clasificados así:

| Categoría | IDs | Acción |
|---|---|---|
| OUT OF SCOPE (workflow choice) | R3, R4, R5, R6 | No tocar. Signup disabled, no Resend domain, no email path. El usuario asume el trade-off. |
| Día 1 — DB integrity | R2, R16, R17, R18, R19, R20 | ✅ Cerrado (migration 0034). |
| Día 1 — descartado | R1 | RLS de pagos cross-cobrador, ya documentado en 0025 como decisión de producto. |
| Día 2 — Edge Functions resilience | R22 (audit-first), control chars, length caps, scrub mensajes, intent/success split, snapshot pre-recreate | ✅ Cerrado. |
| Día 3 — Frontend bugs + tech debt | R7 ✅, R8 ✅, R9 ✅, R10, R11, R12, R13, R14, R15, R21 | ⏳ En curso (R7+R8+R9 cerrados). |

---

## Día 1 — DB Integrity (CERRADO)

Migration: `supabase/migrations/0034_db_integrity_hardening.sql`.

| ID | Fix | Detalle |
|---|---|---|
| R2 | Storage path regex jpg/jpeg/png/webp | Limita uploads a esos formatos a nivel de policy. |
| R16 | `propagar_cambio_monto_a_cuotas_pendientes` | Sólo toca cuotas con estado `pendiente` o `parcial` — no rescribe cuotas pagadas. |
| R17 | `actualizar_notificaciones_mora` con `SET LOCAL row_security = off` | El cron job ya no se filtra por RLS. |
| R18 | Índice parcial `cuotas_cron_mora_idx` | Acelera el sweep mensual. |
| R19 | `client_local_id` UNIQUE por tenant | DO block con `pg_constraint` para idempotencia + pre-flight de duplicados. Bloqueante encontrado en review, fixed. |
| R20 | `set_tenant_modulo` escribe en `audit_log` | Cambios de toggles ahora trazables. |

**Decisión explícita — R1 (descartado)**: `pagos_insert_propio` permite a
un cobrador insertar pagos como otro cobrador del mismo tenant.
Documentado como trade-off de producto en migration 0025 — los dueños de
ISPs chicos quieren poder marcar pagos a nombre del cobrador que cobró
fuera de la app. No se modifica.

**Commits**: `ce4b856` (WIP) → `0ba6fee` (fixes de los 3 agents).

---

## Día 2 — Edge Functions Resilience (CERRADO)

Tres parches en paralelo: input hygiene, audit append-only con
intent/success split, y rollback atómico para multi-paso.

### Funciones modificadas
1. `invitar-cobrador`
2. `forzar-password-cobrador`
3. `cambiar-email-cobrador`
4. `reenviar-invitacion`
5. `crear-tenant`

### Patrones aplicados a todas

**Input hygiene (de validation a sanitización)**:
- Email regex: `/^[^@\s]+@[^@\s]+\.[^@\s]+$/`
- Strip de control chars: `/[\x00-\x1F\x7F-\x9F]/`
- Length caps: nombre 120, telefono 32 (trim antes de chequear)
- Normalización a lowercase para emails

**Audit-first con intent/success split** (R22):
- ANTES del side effect → insert `valor_nuevo: { action: '*_intent' }`.
  Si falla → abort sin aplicar el cambio.
- DESPUÉS del side effect exitoso → insert `valor_nuevo: { action: '*_success' }`
  o strings (para que `_resumenCambio` muestre el diff genérico).
- Si el side effect falla post-intent → intent queda como evidencia
  del intento, response devuelve el error de Auth.
- Si el success-insert falla → `console.error` loud, el cambio queda
  aplicado y el operador investiga por server logs.

**Mensajes scrubbed**:
- Outer catches devuelven "Error interno" genérico — no filtran el
  string del DB al cliente.
- `humanizeAuthError` local en cada función traduce los errores
  conocidos de Supabase Auth a copy en español.

### Específico por función

**`forzar-password-cobrador`**: intent + success ambos con action map,
nunca se persiste la password en audit_log.

**`cambiar-email-cobrador`**: intent guarda `{ action: 'email_change_intent', intent: nuevoEmail }`,
success guarda `valor_anterior: emailViejo, valor_nuevo: nuevoEmail`
como strings — el timeline lo renderea como diff genérico
"email: viejo → nuevo". signOut global post-cambio para invalidar JWT
con el email viejo (~1h de drift sino).

**`reenviar-invitacion`** (modo no-email):
- Snapshot del cobrador en audit_log con `action: 'snapshot_before_resend'`
  ANTES del delete del user viejo.
- Re-creación con `createUser + email_confirm: true`.
- Audit row post-creación incluye `snapshot: snapshot` inline en
  `valor_anterior` para que el timeline del nuevo user muestre el
  histórico previo a la re-invitación.

**`crear-tenant`** (atomicidad multi-paso):
- Variables outer-scope: `tenantId`, `userIdParcial`, `adminForRollback`,
  `success`.
- `success = true` se setea justo antes del Response final.
- Outer catch wrappea cada delete en su propio try/catch con
  `deleteUserThrow` / `deleteTenantThrow` para que un delete que tira
  no rompa el rollback del otro.
- Inner rollback nullifica las vars para evitar double-rollback noise
  desde el outer catch.
- **Security HIGH** fixed: outer catch antes podía dejar tenant huérfano
  si el delete tiraba sincrónicamente.

### UI side
`lib/features/super_admin/miembro_detalle_screen.dart` — `_accionLabel`
con labels nuevos:
```dart
'force_password_reset_intent' => 'Intento de reset de contraseña',
'force_password_reset_success' => 'Contraseña reseteada por super_admin',
'email_change_intent'          => 'Intento de cambio de email',
'snapshot_before_resend'       => 'Snapshot previo al reenvío',
'force_password_reset'         => 'Contraseña reseteada por super_admin', // legacy
```

**Commits**: `c256593` (WIP) → `104de49` (snapshot_before_resend label)
→ `62748bf` (fixes de los 3 agents).

**Fixes incidentales del review**:
- Control char regex que el Edit tool escribió como literal bytes —
  re-escrito vía script Python con `re.sub` + lambda repl.
- Telefono length check movido después del trim.
- `_accionLabel` faltaba `snapshot_before_resend`.

---

## Día 3 — Frontend bugs + tech debt (EN CURSO)

### R7 — Smart sync gate ✅ CERRADO

**Constraint del usuario** (verbatim):
> "no quiero que este mandando peticiones con data que puede mantener
> local, en todo caso si se cierra la ventana se debe de loguear
> nuevamente y no necesariamente borrar la base de dato local y
> rehacer el llamado"

**Implementado** en commit `79af46f`:
- `authIdentityProvider` (StateNotifier) trackea `(userId, changedAt)`.
- `syncReadyProvider` (Provider derivado) = `lastSyncedAt > changedAt`.
- Persistencia cross-session via `SharedPreferences`
  (`last_known_user_id`) para detectar switch aunque el browser cierre
  entre signOut y signIn.
- `SyncGateScreen` con offline UX (8s slow hint, 25s escape hatch).
- Redirect en `/sync-gate` después del set-password gate.
- Container pre-creado en main.dart con `UncontrolledProviderScope`
  para que el auth listener pueda mutar providers antes de runApp.
- Guard contra double-connect del initial restore fallback.

**Follow-ups (no bloqueantes, ya en CLAUDE.md backlog)**:
- Verificar semantics de `PowerSync.lastSyncedAt` vs aplicación de
  DELETEs de buckets descartados (¿el checkpoint signal puede llegar
  antes de los deletes locales?). Si sí, queda una ventana de race
  de algunos ms.
- PKCE recovery + user-switch (edge case raro): gate post-set-password
  con cache de otro user — UX inesperada pero correcta.
- Listener de auth en main.dart nunca se cancela — dev noise en
  hot-restart.
- Bug pre-existente: super_admin landing post-login va a `/` no a
  `/super/tenants`.

### R8 — Upload error surface ✅ CERRADO

**Implementado** en commit `ce787ca`:
- `UploadResult` class + `StreamController.broadcast()` en
  `foto_comprobante_service`.
- `_sincronizarImpl` cuenta succeeded/failed por corrida y emite el
  summary si hubo intento real de upload (no spam cuando no hay
  pendientes).
- Throttle interno de 2 min entre emisiones de error (evita spam en
  redes intermitentes con error estructural).
- `uploadResultsProvider` (StreamProvider) bridge a Riverpod.
- `rootScaffoldMessengerKey` global + `ref.listen` en `app.dart`.
  SnackBar floating con action "Ver detalles" → /perfil. Gate por
  `currentSession` (no mostrar errores del user anterior en /login).
- `main.dart` consume el service via `container.read(...)` (sino dos
  instancias = dos streams separados).
- Botón "Intentar ahora" en perfil ya no muestra snack de error (lo
  cubre el global).

**Follow-ups (al backlog persistente, no bloqueantes)**:
- Persistencia del último error para sobrevivir F5/reload (broadcast
  stream no replaya).
- Indicador opcional en el shell "X fotos con error reciente".
- `lastErrorMessage` no se surfacea hoy — disponible en el stream
  para diagnóstico futuro.

### R9 — `context.push` refactor ✅ CERRADO

**Implementado** en commit `04e984e`. 10 cambios en 6 archivos.

**Convención adoptada**:
- `push` para entries a sub-rutas (tap fila → editar, botón "Nuevo" → form).
- `pop` (con fallback `go(lista)` para deep-link sin stack) para exits
  (post-save, botón Cancelar).
- `go` se preserva para tabs, redirects de auth, post-submit de creación
  de tenants (donde queremos reemplazar el form en la stack).

**Cambios**:
- `admin/clientes/`: `clientes_admin_screen.dart` (botón Nuevo + tap fila),
  `cliente_form_screen.dart` (post-save + Cancelar).
- `admin/contratos/`: idem patrón.
- `super_admin/tenants_list_screen.dart:216` (tap fila tenant) y
  `tenant_modulos_screen.dart:1036` (tap miembro) — mismo bug, mismo fix.

**NO tocado**:
- `recibo_screen.dart:29` — IconButton(Icons.home) es "ir a home", no back.
- Líneas 61/78 de `tenants_list` — post-submit son correctos con `go`.

**Follow-ups al backlog**:
- PopScope guard en forms con cambios sin guardar.
- AppBar back arrow condicional en AdminShell cuando estás en sub-rutas
  (hoy siempre muestra hamburger porque hay drawer, así que el affordance
  visual no mejoró — solo el behavior del browser back y el botón
  Cancelar).

### R10 — Dashboard recompute
StreamProviders del dashboard recomputan en cada rebuild del parent.
Usar `select` o memoizar el slice.

### R11 — `autoDispose`
Providers que sobreviven a navegaciones por no estar marcados
`autoDispose`. Auditar todos los FutureProvider.family.

### R12 — Modelos `==`/`hashCode`
Modelos manuales sin `==`/`hashCode` causan rebuilds innecesarios en
listas. Migrar a equatable o regenerar.

### R13 — Validators centralizados
Email regex, control char strip, length caps están duplicados en
~5 lugares de UI. Mover a `lib/core/validators.dart`.

### R14 — `_InvitarAdminDialog` usa `_invokeFn`
Hay un dialog que llama directo a `supabase.functions.invoke` en vez
del helper centralizado con retry/timeout.

### R15 — Paginación
Listas de cuotas/pagos cargan todo el dataset del tenant. Implementar
paginación o virtualización.

### R21 — Split `tenant_modulos_screen.dart` (2354 LOC)
Archivo monstruoso. Extraer widgets y dialogs a su propio archivo.

---

## Cierre del sprint

Cuando el Día 3 esté cerrado:

1. PR `claude/powersync-sdk-setup-KZF1R` → `main`.
2. 3 audits (Code Audit + QA + UX/Security) sobre el diff completo.
3. Resolver findings críticos.
4. Merge.
5. **Borrar este archivo** (`SPRINT-HARDENING.md`).
6. Backlog que sobreviva → `CLAUDE.md` sección "Backlog persistente".
