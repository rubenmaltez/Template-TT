# ROADMAP — Cobranza ISP

Plan de bulks para llevar el producto desde su estado actual (pre-MVP-beta)
hasta producción general y features comerciales.

**Cómo usar este documento**:
- Cada sesión de Claude Code lee este archivo para retomar el hilo sin
  perder contexto.
- Los bulks van en orden de dependencia. NO saltarse bulks sin razón
  documentada — el orden refleja prerequisitos técnicos y operativos.
- Cuando se completa un sprint, se marca `✅` con el número de PR.
- Cuando se cierra un bulk entero, se hace audit ligero + smoke test
  del flow que ese bulk debería habilitar.

**Estado actual**: BULKs 1-6 en progreso. BULK 6 E2E descubrió 7 bugs
(2 HIGH blockers para piloto). Próxima sesión: fixear sync gate stuck
+ CRUD rejection silenciosa, completar E2E.
Sesión inicial (2026-05-22): 34 PRs infraestructura.
Sesión 2 (2026-05-23/24): 14 PRs (#36-#49) BULKs 1-6.

---

## Snapshot de capacidades (al 2026-05-22)

| Aspecto | Estado |
|---|---|
| Multi-tenant + RLS | ✅ Sólido |
| Onboarding workflow (sin email) | ✅ Funcional |
| Cobro offline-first | ✅ Funcional |
| Recibo Bluetooth térmico | ✅ Funcional |
| Audit log | ✅ Sólido |
| Logger de errores end-to-end | ✅ Deployed |
| Tests automatizados | ✅ 109 tests acumulados |
| Sync gate UX | ✅ Mejorado |
| PopScope guards en forms | ✅ Cliente + Contrato |
| Validator de teléfono (PhoneTextField) | ✅ 5 forms con widget compartido |
| Animaciones de transición | ✅ Fade global |
| Distribución | ⚠️ Solo web |
| Email/Resend | ⚠️ Sandbox |
| Paginación clientes (admin + cobrador) | ✅ LIMIT 50/200 + Cargar más |
| Sync gate stuck bug | ⚠️ Esperando reproducción con telemetría |
| Super_admin UI completo | ⚠️ Sprint futuro grande |
| Tests de Edge Functions | ❌ Sin |
| App nativa | ❌ Sin |
| Cobro con tarjeta | ❌ Simbólico |

---

## 🎯 BULK 1 — Operacional crítico pre-beta

**Objetivo**: poder poner el producto en manos de un ISP piloto real.

**Bloqueantes**: sin esto, el cliente tiene UX rota en flows comunes
(forzar password genera stuck, listados grandes explotan, sidebar
pierde data sin warning).

| Sprint | Tiempo | Criterio de éxito | PR |
|---|---|---|---|
| Diagnóstico sync gate stuck | 1-2h | Reproducir post-forzar-password → ver telemetría `[SYNC-DIAG]` en `/super/logs` → fixear causa raíz | ⏸ esperando repro |
| Paginación clientes admin + cobrador | 3-4h | Listado fluido con 10k+ clientes (cursor o offset+limit con "Cargar más") | ✅ PR #37 |
| PopScope coverage en sidebar | 2-3h | Coordinar shell ↔ form vía Provider. Sidebar pregunta dirty antes de navegar | ✅ PR #38 |

**Tiempo total**: ~6-9h (1 sesión larga o 2 cortas).

**Validación del bulk**: smoke test del flow completo
- Admin crea cliente con varios campos → cambia mid-flow → toca sidebar
  → ve dialog "¿Descartar?".
- Super_admin fuerza password al admin de un tenant → admin logea → ve
  sync gate fluido (con o sin bug, capturado por telemetría).
- Listado de 10k clientes simulados navega fluido.

---

## 🔧 BULK 2 — Hardening backend (Edge Functions + race conditions)

**Objetivo**: estabilizar Edge Functions y race conditions que hoy son
latentes pero pueden romper bajo carga real.

**Prerequisito**: migrar de Supabase Dashboard a CLI (habilita `_shared/`).

| Sprint | Tiempo | Criterio de éxito | PR |
|---|---|---|---|
| Migración a Supabase CLI | 2-3h | `supabase init` + deploy desde local | ✅ sesión interactiva |
| Consolidar `humanizeAuthError` en `_shared/` | 1h | 5 funciones importan del shared, cero duplicación | ✅ PR #40 |
| forzar-password: audit row de signOut failed | 30 min | Trail de fallos de signOut global | ✅ PR #40 |
| reenviar-invitacion: lock contra concurrencia | 1h | 2 super_admins concurrentes → uno bloquea hasta el otro | ⏭ skippeado (ya mitigado por 404 check) |
| cambiar-email: paginación >1000 users | 1-2h | Migrar `listUsers({perPage: 1000})` a RPC SECURITY DEFINER | ✅ PR #40 + migración 0036 |
| invitar-cobrador: cleanup ghost user | 1h | Rollback elimina user huérfano si falla post-createUser | ✅ PR #40 |
| Race del `_rolUsuarioProvider` | 1h | Post-login super_admin no flashea `/admin` | ✅ PR #40 |
| Auth listener cleanup en main.dart | 30 min | Hot-restart en dev no tira exception | ✅ PR #40 |
| R8 — StreamController.broadcast replaya | 1h | Tras F5, último UploadResult con failures re-emite | ✅ PR #40 |

**Tiempo total**: ~9-12h (2-3 sesiones). **Completado en 1 sesión.**

**Validación**: 6 Edge Functions deployadas via CLI con `_shared/` imports
funcionando. Migración 0036 aplicada en producción.

---

## 📊 BULK 3 — Observability hardening (logger + offline + onboarding)

**Objetivo**: el logger ya está en producción uso (sprint inicial).
Refinarlo aumenta utilidad de soporte cuando haya clientes reales.

| Sprint | Tiempo | Criterio de éxito | PR |
|---|---|---|---|
| Paginación viewer `/super/logs` | 1-2h | Cursor / "Cargar más" cuando hay >100 logs | ✅ PR #42 |
| Retention policy | 2h | Cron diario purga logs >90 días + RPC `purge_error_logs` | ✅ PR #42 (migración 0037) |
| Rate limit en cliente | 1h | Max 1 entry / 5s por mensaje similar (anti crash-loop floods) | ✅ PR #42 |
| Índice por `error_type` en BD | 30 min | `CREATE INDEX` en migración | ✅ PR #42 (migración 0037) |
| Debounce search en viewer | 30 min | 400ms onChanged en vez de onSubmitted | ✅ PR #42 |
| Capturar user_agent del browser | 30 min | `package:web` o equivalente | ✅ PR #42 (Flutter Web/platform) |
| OfflineBanner — indicador red inestable | 1-2h | Sutil ícono en topbar con N flickers en M segundos | ✅ PR #42 |
| OfflineBanner — botón Reintentar | 30 min | `disconnect+connect` igual que SyncGate retry | ✅ PR #42 |
| OfflineBanner — AnimatedSwitcher fade | 15 min | Fade-in 150ms en vez de pop | ✅ PR #42 |
| Onboarding wizard PopScope guard | 1-2h | Salir del wizard a medio llenar pregunta "¿Descartar?" | ✅ PR #42 |

**Tiempo total**: ~8-11h (2-3 sesiones). **Completado en 1 sesión.**

**Validación**: migraciones 0037+0038 deployadas. 6 Edge Functions
redeployadas. Audit retroactivo de seguridad aplicado (PR #43):
user enumeration cerrado, crear-tenant migrado a RPC, error fallback
sanitizado.

---

## 🧪 BULK 4 — Test coverage + barrido anti-patrón

**Objetivo**: estabilizar el codebase antes del rework grande del bulk 5.
Tests previenen regresión durante los cambios estructurales que vienen.

| Sprint | Tiempo | Criterio de éxito | PR |
|---|---|---|---|
| Tests Fmt restantes (fechaLarga/mes/diaSemana) | 30 min | +10 tests al archivo existente | — |
| Tests `cobrador_helpers.dart` | 30 min | Cobertura de helpers de UI | — |
| Tests `edge_functions.dart` (`humanizarError`) | 30 min | 3 paths (Exception, FunctionException, raw) | — |
| Tests PowerSync integration | 3-4h | Mock de `ps.db` para StreamProviders | — |
| Barrido anti-patrón `ps.db.watch` (10 archivos admin) | 4-5h | Clientes, contratos, planes, cuotas, pagos del admin a StatefulWidget | — |
| Barrido anti-patrón (10 archivos restantes) | 4-5h | Audit, reportes, recibo, historial, perfil, etc. | — |

**Tiempo total**: ~12-15h (3-4 sesiones).

**Validación**: `flutter test` pasa todo. Cada pantalla del barrido
funcional en smoke test.

---

## 🎨 BULK 5 — Rework super_admin UI/UX + animaciones

**Objetivo**: super_admin con capacidad real de operar como admin de
cualquier tenant (impersonate con audit). Decisión de Rubén tomada
en la sesión inicial.

**Prerequisito**: codebase estable (bulks 1-4 cerrados).

| Sprint | Tiempo | Criterio de éxito | PR |
|---|---|---|---|
| Refactor `current_tenant_id()` SQL | 2-3h | Soporta override via tabla impersonation. 30+ RLS policies se adaptan automáticamente | ✅ PR #46 (migración 0039) |
| Selector de tenant en super_admin | 3-4h | Botón "Entrar como admin" en tenant list + detail + audit row | ✅ PR #46 |
| Super_admin accede al AdminShell con tenant elegido | 2-3h | super_admin ve `/admin/clientes` del tenant impersonado | ✅ PR #46 |
| Toggle módulos por tenant — refinar UI | 1-2h | Botón "Entrar" visible desde el detalle del tenant | ✅ PR #46 |
| Flash setup wizard residual | 1-2h | Animación de transición + refactor del guard | ➡️ Movido a BULK 6 |
| Sync gate slow optimization | 3-4h | Revisar `sync-rules.yaml`, shared workers, delete-and-replace | ➡️ Optimización futura |
| Indicador "estás viendo tenant X" persistente | 1h | Banner verde "Super Admin · Viendo: {nombre}" con botón Salir | ✅ PR #46 |

**Tiempo total**: ~13-19h estimadas. **Core completado en 1 sesión.**

**Validación** (smoke testing manual):
- ✅ Super_admin elige tenant → ve AdminShell con 204 clientes.
- ✅ Banner "Super Admin · Viendo: prueba prueba jeje" persistente.
- ✅ Botón Salir → data limpia, banner desaparece, Tenants vuelve al sidebar.
- ⚠️ Navegación post-exit: queda en `/admin` en vez de `/super/tenants`
  (TODO para rework UI/UX super_admin).

**Pendientes para rework UI/UX futuro:**
- Navegación automática a `/super/tenants` post-exit.
- Sync gate optimization para impersonate de tenants grandes.
- Flash setup wizard (movido de este BULK).

---

## 🌐 BULK 6 — Pre-producción

**Objetivo**: producto listo para entregar a ISP piloto real.

**Prerequisito**: super_admin funcional (bulk 5).

| Sprint | Tiempo | Criterio de éxito | PR |
|---|---|---|---|
| Resend dominio verificado | 30 min setup + DNS | Email funciona con cualquier destinatario | ➡️ Futuro (ya implementado, solo falta config DNS) |
| Paginación en otros listados (cuotas/pagos/audit) | 2-3h | Todos los listados grandes paginados | ✅ PR #49 |
| Reportes PDF descargables | 2-3 días | Package `pdf` + templates cobros + mora | ✅ PR #49 |
| Validación end-to-end del flujo ISP completo | 1 día | Flujo completo probado | 🔴 En progreso — bugs encontrados |

**Tiempo total**: ~5-7 días.

**E2E findings (bugs descubiertos durante validación, sesión 2)**:

| # | Bug | Severidad | Fix para próxima sesión |
|---|---|---|---|
| 1 | **Sync gate stuck** post-login y post-invitación. PowerSync queda en "Sincronizando datos..." indefinidamente. F5 lo desbloquea. Reproducido 2 veces en E2E. | **HIGH (BLOCKER para piloto)** | Diagnosticar con logs [SYNC-DIAG], fix en PowerSync connector o auth listener |
| 2 | **CRUD rejection silenciosa**: contrato rechazado por trigger en Postgres pero PowerSync no muestra el error al user. El dato queda en SQLite local como si se hubiera guardado. | **HIGH** | Surfacear errores del CRUD upload al user vía SnackBar/dialog |
| 3 | **Trigger bloquea contrato sin cobrador**: `contratos_check_cliente_con_cobrador()` requiere cobrador asignado antes de crear contrato. Workflow admin forzado sin documentar. | **MEDIUM** | Evaluar: relajar trigger (permitir NULL cobrador) o documentar workflow |
| 4 | **Cobrador no aparece post-invitación**: probablemente relacionado con bug #1 (sync stuck). El cobrador se creó server-side pero nunca se sincronizó al local. | **MEDIUM** | Se resuelve con fix del bug #1 |
| 5 | **Onboarding no resetea formDirtyProvider**: dialog "¿Descartar?" espurio después de completar el wizard. | **LOW** | Reset provider en `_finalizar()` |
| 6 | **DropdownButton assertion** transitoria en contratos: red screen ~1s cuando plan/cliente carga antes que el dropdown. | **LOW** | Guard en el widget |
| 7 | **Banner "Red inestable"** durante heartbeats normales de PowerSync. | **LOW** | Subir threshold de 3 a 5 flickers |

**Validación**: poner producto en manos de **1 ISP piloto real**.
Recoger feedback durante 2-4 semanas.

---

## 📱 BULK 7 — Distribución multi-plataforma

**Objetivo**: apps nativas para clientes que lo pidan (Android +
Windows).

**Prerequisito**: producto validado con piloto (bulk 6).

| Sprint | Tiempo | Criterio de éxito | PR |
|---|---|---|---|
| Build Android | 3-4 días | APK funcional con offline-first nativo | — |
| Build Windows installer | 2-3 días | `.msi` con auto-update | — |
| Deep links Android (app links) | 1-2 días | Link de invite/recovery abre la app | — |
| URL scheme Windows | 1 día | `cobranza-isp://...` registrado | — |
| PWA mejorado para web | 1 día | Service worker + offline cache + instalable | — |

**Tiempo total**: ~2 semanas.

**Validación**: testear cada plataforma en device real. APK en
mid-range Android. Windows en máquina típica del ISP. Cobrador en
campo con APK.

---

## 🚀 BULK 8 — Features comerciales

**Objetivo**: agregar features que dependen de feedback real de
clientes pagos. Cada item independiente, se elige según demanda.

| Feature | Tiempo | Cuándo arrancar |
|---|---|---|
| Módulo Inventario (routers/ONUs) | 1 semana | Cuando un ISP pida tracking de equipos |
| WhatsApp Business API | 1 semana + costos | Si necesitás envíos automáticos de mora |
| Cobro automático con tarjeta | 2 semanas + PCI | Cuando el mercado lo pida + tengas presupuesto pasarela |
| App nativa iOS | 1 semana | Si un cliente pide iOS |
| Multi-idioma (portugués/inglés) | 2-3 días | Si expandís a Brasil o angloparlantes |

---

## Cronograma estimado

```
SEMANA 1-2:   BULK 1 (operacional crítico)
SEMANA 3-4:   BULK 2 (hardening backend)
SEMANA 5-6:   BULK 3 (observability hardening)
SEMANA 7-8:   BULK 4 (tests + barrido watch)
SEMANA 9-12:  BULK 5 (rework super_admin)         ← sprint más grande
SEMANA 13-14: BULK 6 (pre-producción)
                                                  ↓
                                            PRIMER CLIENTE PILOTO
                                                  ↓
SEMANA 15-18: Iterar según feedback piloto
SEMANA 19-22: BULK 7 (distribución)
                                                  ↓
                                            PRODUCTO GENERAL
                                                  ↓
SEMANA 23+:   BULK 8 (features comerciales según demanda)
```

**Total estimado hasta producción general**: 4-5 meses con 10-20h/semana
dedicadas al proyecto.

---

## Workflow por bulk

Cada bulk se trata como mini-roadmap dentro de su(s) sesión(es):

1. **Pre-bulk**: re-verificar que los items siguen vigentes (que no
   se hayan resuelto incidentalmente desde la última actualización
   de este doc).
2. **Sprint por sprint**: cada item es un PR independiente con
   commit + push + review + merge.
3. **Smoke test al final del bulk**: validar el flow end-to-end que
   el bulk debería habilitar.
4. **Audit ligero post-bulk**: agent de code audit revisa los
   cambios.
5. **Refinement**: si el audit encuentra bugs, mini-sprint de fixes.
6. **Update CLAUDE.md + ROADMAP.md**: backlog actualizado, items
   resueltos eliminados, items nuevos descubiertos agregados,
   sprints completados marcados con PR number en la tabla.

---

## Sesiones completadas

### Sesión inicial — 2026-05-22 (34 PRs)
**Bloques**: infraestructura previa a los bulks.
- Logger end-to-end + viewer `/super/logs` (PR #4).
- Fix bugs descubiertos con el logger (#5, #14, #15, #16, #17).
- Sync gate UX redesign (#6).
- Helper `closeModalsAndGo` para shells (#7).
- Fixes operativos chicos (#8, #10, #11, #20, #21, #22, #23, #25).
- PhoneTextField widget compartido (#26).
- Documentación persistente y backlog cleanup (#9, #12, #13, #18, #19, #24).
- Tests base + 109 tests acumulados (#27, #28, #29, #30).
- UX final: AppBar back arrow, PopScope guards, fade transition (#31, #32, #33).
- Audit + fixes finales (#34).

### Sesión 2 — 2026-05-23 (4 PRs: #36-#38 + docs)
**Bloques**: BULK 1 operacional + documentación persistente.
- STACK.md con explicación del stack tecnológico (PR #36).
- Paginación clientes admin + cobrador con LIMIT + "Cargar más" (PR #37).
  - LIMIT 50 sin search, LIMIT 200 con search activa.
  - Widget compartido `CargarMasButton` con loading state anti-doble-tap.
  - Fixes de audit: selección huérfana, padding unificado.
- PopScope guard en sidebar (PR #38).
  - `formDirtyProvider` global para coordinar shell ↔ form.
  - `closeModalsAndGoGuarded` con pre-check de dialogs críticos.
  - Dialog "¿Descartar?" con botones invertidos (convención UX destructiva).
  - Fixes de audit: doble dispose, race PopScope+sidebar, botones.
- Smoke testing manual de los 8 escenarios (paginación + PopScope).
  - Inyección de 200 clientes de prueba vía SQL seed.
  - Sprint 1 (sync gate stuck) en pausa — esperando reproducción natural.
- BULK 2 completo (PR #40): hardening backend.
  - Supabase CLI v2.101.0 instalado + deploy verificado.
  - `_shared/` consolidación: 309 líneas de duplicación eliminadas.
  - Audit row signOut failed en forzar-password.
  - RPC `check_email_exists_in_auth` reemplaza listUsers (migración 0036).
  - Ghost user cleanup en invitar-cobrador.
  - Race rol provider: fresh install ahora usa sync gate.
  - Auth listener cleanup: _authSub global cancelada en hot restart.
  - Broadcast replay: FotoComprobanteService replaya último UploadResult.
  - 6 Edge Functions deployadas via CLI en producción.
- BULK 3 completo (PR #42): observability hardening.
  - Paginación /super/logs con "Cargar más" (LIMIT 50).
  - Migración 0037: índices error_type + ts + RPC purge_error_logs.
  - Rate limit 5s en ErrorLogService (anti crash-loop).
  - Debounce 400ms en búsqueda de logs.
  - User agent capturado (Flutter Web/platform).
  - OfflineBanner: AnimatedSwitcher fade + botón Reintentar + indicador
    "Red inestable" (3+ flickers en 30s → strip amber).
  - Onboarding wizard con PopScope + formDirtyProvider.
- Audit retroactivo de seguridad (PR #43):
  - Migración 0038: REVOKE check_email_exists_in_auth de public.
  - crear-tenant migrado de listUsers a RPC (3/3 callsites consistentes).
  - humanizeAuthError fallback sanitizado (no raw errors al cliente).
- BULK 4 completo (PR #45): tests + barrido anti-patrón.
  - +45 tests nuevos (Fmt, cobrador_helpers, edge_functions). Total: 154.
  - 19 archivos refactoreados: ps.db.watch inline → StatefulWidget con
    late Stream en initState + didUpdateWidget.
  - Audit: mapa stream documentado, mora setState fix.
- BULK 5 completo (PRs #46, #47): impersonación de tenants.
  - Migración 0039: tabla super_admin_impersonation + current_tenant_id()
    modificada. 30+ RLS policies se adaptan automáticamente.
  - Sync rules v4: bucket impersonated_tenant + impersonation row en
    super_admin_self.
  - ImpersonationService: enter/exit con audit_log + PowerSync reconnect.
  - effectiveTenantIdProvider: tenant impersonado para INSERT/UPDATE.
  - Router impersonation-aware: redirect a /admin cuando impersonando.
  - AdminShell: banner "Super Admin · Viendo: {nombre}" + botón Salir.
  - Tenant list + detail: botón "Entrar como admin".
  - Audit seguridad: dual write path eliminado, guard System tenant.
  - Compile fix: widget.diasGracia en cuotas_list_screen (PR #47).
  - Smoke testing manual: 9 escenarios validados.
