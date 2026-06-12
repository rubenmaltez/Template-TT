# AGENTS.md

Reglas y proceso de trabajo del proyecto **Cobranza ISP (SITECSA CRM)** para
CUALQUIER agente de AI (Claude Code, OpenCode, Codex, Cursor, Antigravity,
etc.). Si estás abriendo este repo, leé esto primero. (Claude Code lo carga
vía el shim `CLAUDE.md`, que es solo `@AGENTS.md`; las demás herramientas
leen este archivo directo por el estándar AGENTS.md.)

---

## 📚 EL SISTEMA DE DOCUMENTOS (leer en este orden al abrir una sesión)

| # | Documento | Qué responde | Cuándo actualizarlo |
|---|---|---|---|
| 1 | **`BITACORA.md`** | ¿Dónde quedamos? Estado vivo + historial de cambios con su porqué | **SIEMPRE al cerrar la sesión** (Fase 6) |
| 2 | **`AGENTS.md`** (este) | Reglas, invariantes, proceso | Solo si cambia una regla/proceso |
| 3 | **`PRODUCTO.md`** | Qué es la app, misión, roles, día a día, stack y porqués | Si cambia misión/roles/módulos de producto/stack |
| 4 | **`ARQUITECTURA.md`** | Cómo está construida: módulos, conexiones, settings y **RECETAS de cambios** | Si cambia un módulo/tabla/setting/ruta/conexión |
| 5 | `TESTING.md` §0 | Loop de testing manual con Rubén | Si un feature nuevo trae flujo de testing |
| 6 | `Install Steps/` | Build, release, versionado e instalación | Si cambia el flujo de build |
| 7 | `Troubleshooting SQL/` | Corregir DATA de un tenant en producción vía SQL (guía para AI: acoplamiento de tablas, triggers que recalculan solos, recetario de fixes seguros) | Si cambia un trigger/cascada/invariante de dinero |
| 8 | `CLAUDE.md` | Shim de 1 línea (`@AGENTS.md`) para que Claude Code cargue este archivo automáticamente | NUNCA — las reglas se editan ACÁ |

**Para hacer un CAMBIO en el código**: buscá tu caso en `ARQUITECTURA.md` §0
(índice de cambios → recetas R1-R12). Eso evita escanear el repo.
**Históricos**: `docs/archive/` (HANDOFF, REPORTE-SESION, ESTADO-APP, STACK,
ROADMAP, planes y audits viejos — solo para arqueología, NO mantener).

---

## Producto (resumen mínimo — detalle en `PRODUCTO.md`)

SaaS **multi-tenant** de cobranza para ISPs de Centroamérica (Nicaragua).
Roles: `super_admin` (Rubén, dueño del SaaS) · `admin` / `admin_cobranza`
(ISP) · `cobrador` (campo, offline-first) · `tecnico` (módulo tickets).
Onboarding **SIN email** (password server-side por WhatsApp); no hay signup
público → findings de seguridad "si signup estuviera habilitado…" = fuera de
scope. Foco: bugs reales, no hardening hipotético.

Stack: Flutter (Android + Windows) · Supabase (Postgres+Auth+Edge+Storage) ·
PowerSync (offline-first, schema **v27** — verificar SIEMPRE en
`lib/powersync/db.dart`, no confiar en docs) · Riverpod · go_router.

---

## Principios arquitecturales a respetar SIEMPRE

1. **Multi-tenant con RLS** — toda tabla operativa tiene `tenant_id` NOT NULL
   y policies por `current_tenant_id()`; super_admin bypassa con
   `is_super_admin()`. Tabla nueva → checklist completo en ARQUITECTURA
   **Receta R10** (incluye `super_admin_all` A MANO + gate de módulo 0114).
2. **Offline-first** — el cobrador/técnico opera sin internet. Features que
   requieran conexión sincrónica deben declararse explícitamente.
3. **Server gana** — Postgres es la fuente de verdad. El cliente espeja
   triggers (mirrors) SOLO para UX instantánea offline.
4. **Audit log append-only** — nunca borrar rows; para "deshacer" se agregan
   rows nuevas.
5. **Workflow sin email** — toda feature que asuma "envía email" necesita
   fallback no-email.

## Invariantes de dinero (NUNCA violar — la base del negocio)

Cualquier cambio que toque `pagos`, `cuotas`, `recibos`, `contratos`,
`cargos_extra` o flujos de cobro DEBE respetarlas y el audit DEBE verificarlas:

1. **`pagos.monto_cordobas` = lo APLICADO a la cuota** (lo que entra a caja).
   NUNCA lo entregado por el cliente.
2. **`pagos.vuelto_cordobas` = lo devuelto, SIEMPRE en córdobas.** El cliente
   puede pagar en USD; el vuelto jamás se da en USD.
3. **`pagos.monto_original` = lo ENTREGADO en la moneda original.**
   Invariante: `monto_original × tasa ≈ monto_cordobas + vuelto_cordobas`.
4. **`recaudado` = `SUM(pagos.monto_cordobas)` no anulados.** Nunca sumar lo
   entregado ni incluir vuelto.
5. **Total de contrato fijo = `precio_mensual × meses`** (nunca la suma de
   cuotas). `pendiente = total − recaudado`.
6. **Contratos indefinidos**: solo "total recaudado"; no hay "pendiente".
7. **`cuota.monto_pagado` = SUM(pagos aplicados no anulados)** — lo mantiene
   un trigger server. El cliente NUNCA lo calcula a mano (solo espeja).
8. **Anular un pago restaura** la cuota (trigger) y el pago se PRESERVA.
9. **Cargos manuales** se asocian al contrato; cuentan para recaudado, NO
   para el total fijo.
10. **Consistencia cross-pantalla**: el saldo/recaudado debe dar IDÉNTICO en
    todas las pantallas (fórmula canónica:
    `monto + COALESCE(cargos_neto,0) − monto_pagado`). Si dos difieren, una
    está mal — investigar antes de seguir.

**Verificación**: `supabase/tests/invariantes_dinero.sql` después de cada
deploy que toque dinero. Toda fila debe dar `violaciones = 0`.

## Modelo del change log (obligatorio para TODA entidad editable)

**Toda entidad que un usuario pueda crear/editar/borrar tiene historial
accesible desde su pantalla.** Fuente de verdad = server: las filas las
genera `audit_changelog_trg` (AFTER I/U/D, guard `pg_trigger_depth()<2`);
el cliente solo escribe `ocurrido_en` (device-time, `.toUtc()`).

- **Patrones de UI**: Simple (`HistorialCambiosWidget`) para entidades
  self-contained; **Agregador** (Historial{Cuota,Cliente,Serial,Ticket}Widget)
  para contenedoras — une hijas DIRECTAS leyendo el `$.padre_id` del
  **snapshot JSON** (nunca `IN (SELECT)`, para que las borradas físico sigan
  apareciendo) y ordena por `COALESCE(ocurrido_en, created_at)`.
- **Regla de profundidad**: el padre agrega solo hijas directas (un nivel);
  hijas contenedoras → solo eventos de superficie (`kAuditCamposSuperficie`).
  Única excepción: el recibo en el log de la cuota (hoja 1:1 del pago).
- **Sin LIMIT** en los historiales per-entidad (vida completa).
- **Contrato al agregar entidad nueva**: trigger + registro en
  `data/utils/audit_changelog.dart` (labels/campos) + historial en su
  pantalla + (si es hija de un agregador) sumarla a la query del padre.
  Detalle operativo: ARQUITECTURA **Receta R10**.

---

## Proceso mandatorio de fixes y features (lifecycle)

**Fase 1 — Entender:** leer el pedido → `BITACORA.md` (dónde quedamos) →
este AGENTS.md → `ARQUITECTURA.md` §0 (¿hay receta para este cambio?).

**Fase 2 — Pre-evaluación:** investigar archivos (la receta dice cuáles),
evaluar riesgos/dependencias, **presentar propuesta con opciones y ESPERAR
aprobación (OBLIGATORIO)**.

**Fase 3 — Implementación:** cambio por cambio, committeando. Si toca
tablas/columnas: cadena de integridad completa (Receta R4/R10).

**Fase 4 — Audit post-implementación (OBLIGATORIO):** lanzar agentes (Code +
DB integrity mínimo; 3 en paralelo para cambios significativos: Code Audit +
QA + el tercero según el cambio: UX / Deployment Safety / Security).
**Presentar findings con el formato de reporte** (abajo) y esperar aprobación
de los fixes. Aplicar fixes convergentes.

**Fase 5 — Testing:** paso a paso para Rubén (formato `TESTING.md` §0: qué
hacer → qué debería ver → si falla). Indicar restart completo vs hot reload,
comandos exactos de migraciones, y si hay redeploy de sync rules.

**Fase 6 — Cierre (OBLIGATORIO, no saltear):**
1. **Actualizar `BITACORA.md`**: bloque ESTADO ACTUAL + entrada nueva arriba
   (qué se pidió/por qué/qué se hizo/commits/pendientes).
2. Si cambió un módulo/tabla/setting/conexión → **actualizar
   `ARQUITECTURA.md`** (sección del módulo y/o recetas).
3. Si cambió misión/roles/stack → `PRODUCTO.md`.
4. Si hay flujo de testing nuevo → `TESTING.md` §0.3.
> Sin este cierre, la próxima sesión arranca a ciegas. Documentar toma
> minutos; no hacerlo cuesta horas.

**NUNCA saltar fases.**

## Checklist de audit obligatorio (post-implementación)

**1. SQL SQLite vs Postgres (CRÍTICO, scope: TODO el codebase):**
   - `grep -rn 'FILTER' lib/ --include="*.dart"` → 0 `FILTER (WHERE ...)`.
   - `::text/::int/::uuid/::jsonb`, `RETURNING`, `ILIKE`, `ANY(`, `ARRAY[`
     → 0 en `lib/` (son Postgres-only; SQLite usa `CAST`, `SUM(CASE WHEN…)`).

**1b. Zona horaria / día local (CRÍTICO — norma general):**
   - Lógica de LÍMITE DE DÍA (vencidas/mora/gracia/"hoy"/rangos/conteos) usa
     SIEMPRE `date('now','-6 hours')` y `julianday('now','-6 hours')` — NUNCA
     `date('now')` pelado (SQLite es UTC; el negocio es Nicaragua UTC-6 sin
     DST). Aplica a TODO módulo actual y futuro.
   - Server-side: NO cambiar el timezone global de la DB. Funciones con
     lógica de día → `SET timezone = 'America/Managua'` (patrón 0087).
     Crons a medianoche Nicaragua = 06:05 UTC.
   - Convención de timestamps: `ocurrido_en`/`aplicado_en`/`anulada_en` en
     **UTC** (`.toUtc()`); `fecha_pago` y `tickets.created_at` **local-naive
     A PROPÓSITO** (su wall-clock sostiene el bucketing por `date()` — NO
     normalizarlos sin migrar los cortes). El SLA parsea `created_at` con
     `parseTicketWallClock`.

**2. Stream lifecycle Riverpod:** `ConsumerStatefulWidget` + `ref.watch` en
   build + stream creado en `initState` → el stream vive en `late final` /
   `_buildStream()` / provider (o `.asBroadcastStream()`). Sin `ps.db.watch`
   inline en build de Consumers (excepción documentada: `geo_picker`).

**3. Regresión full-codebase:** el audit NO se limita a lo modificado.
   Grep de patrones rotos conocidos (SQL incompatible, imports rotos,
   columnas droppeadas, providers huérfanos).

**4. Cadena de integridad ampliada:** toda query del codebase que toque las
   tablas modificadas (`grep -rn 'tabla' lib/`).

**5. Rutas GoRouter completas:** cada `context.push/go` debe existir en
   `router.dart` (ambas variantes de los paths condicionales
   `enAdminShell ? '/admin/x' : '/x'`).

**6. Denormalización en INSERTs:** columnas denormalizadas (`cobrador_id`)
   SIEMPRE en el INSERT desde Dart (los triggers no corren en SQLite).

### Formato obligatorio del reporte de audit
```
## REPORTE DE AUDIT — [nombre]
### Metodología (agentes, scope, archivos)
### Findings que requieren fix
| # | Severidad | Archivo:línea | Problema | Impacto en usuario |
(por finding: quién lo encontró · código antes · escenario real · código después)
### Clean — sin problemas (tabla por categoría)
### Backlog (no bloquea)
```
El reporte se presenta ANTES del pull/testing. Sin reporte, el sprint no está
auditado.

## Modelo de testing de 4 capas

| Capa | Qué | Cuándo |
|---|---|---|
| 1. Audit estático | agentes leen código (sintaxis/SQL/RLS/imports) | post-implementación |
| 2. Invariantes SQL | `invariantes_dinero.sql` contra data real | tras cada deploy que toque dinero |
| 3. Tests de repo | `flutter test` (suite `pagos_repo` + unit) | cada cambio + CI |
| 4. Manual (Rubén) | escenarios reales en la app | antes de cerrar sprint |

**Regla:** cambios de dinero pasan por 1+2+3 antes del manual.

## Principio de diseño: evaluar ANTES de implementar

Antes de elegir herramienta/servicio para algo nuevo: ¿se resuelve con el
stack existente? ¿agrega pasos manuales al workflow? ¿tiene límites
conocidos? ¿cómo se ve end-to-end para el usuario? Elegir lo más simple y
documentar el trade-off en el commit.

---

## Cómo deployar (preferencia: Dashboard, NO CLI)

### Migración SQL
1. `Get-Content supabase\migrations\NNNN_*.sql -Raw | Set-Clipboard`
2. Verificar el paste en Notepad → Dashboard → SQL Editor → Run →
   `Success. No rows returned`.
3. **NUNCA asumir que una migración corrió — verificar con query**
   (`information_schema.columns` / `pg_tables` / `pg_trigger`; para regclass
   comparar por OID `'tabla'::regclass`, no `::text`).

### Edge Function
1. `Get-Content supabase\functions\NOMBRE\index.ts -Raw | Set-Clipboard`
2. Dashboard → Edge Functions → función → tab Code → reemplazar → Deploy
   updates → verificar "a few seconds ago".
3. **`_shared/*.ts`**: el editor del Dashboard tiene árbol FILES con los
   `_shared` bundleados — editables ahí. OJO: cada función es un bundle
   independiente → cambiar un `_shared` exige repetir edit+deploy EN CADA
   función que lo importa (`passwords.ts` → crear-tenant, invitar-cobrador,
   reenviar-invitacion). El repo es la fuente de verdad DRY.

### Checklist al agregar columna/tabla
Ver ARQUITECTURA **Receta R4** (columna) y **R10** (tabla). Resumen:
migración corrida y VERIFICADA → schema.dart → bump `_schemaVersion` →
redeploy sync rules ("Active") → Dart consistente → app desde cero.

### Build / release de la app
**`Install Steps/1-Publicar-nueva-version.md`** (bump de versión en
`pubspec.yaml` → migraciones → `Install Steps\build-release.ps1`). Tras
cualquier cambio mergeado que Rubén quiera distribuir, guiarlo ahí.

---

## Git / branching (modelo desde 2026-06-09)

- **`main` es la ÚNICA rama permanente** y la default del repo. Siempre
  refleja el último estado estable/auditado.
- Cada sesión de trabajo desarrolla en una **rama efímera creada desde
  `main`** (la que asigne el entorno, p.ej. `claude/*`). Al cerrar el
  trabajo aprobado: **merge a `main` y BORRAR la rama** — no acumular ramas.
- **Hitos/checkpoints = TAGS, nunca ramas** (`git tag <nombre>` + push del
  tag). Política de limpieza (decisión Rubén 2026-06-12): en GitHub se
  conserva SOLO el tag/release de la versión vigente — al publicar una
  versión nueva se borran el release y el tag anteriores
  (`gh release delete vX --cleanup-tag`). Los checkpoints `pre-mvp-v1/v2`
  fueron eliminados (el historial de `main` los contiene igual).
- No reescribir historia de `main` (sin force-push).

## Reglas de comunicación con Rubén

- Pasos detallados, **un comando por vez** cuando el output importa, con
  output esperado al lado y verificación explícita antes de avanzar.
- NO asumir confirmación; pedirla después de cada sub-paso.
- Mismo error 2 veces → FRENAR y diagnosticar, no repetir instrucciones.
- Decisiones técnicas → tabla de pros/cons, recomendar honestamente, dejarlo
  elegir.
- Idioma: español rioplatense (vos). Strings de UI 100% español. Commits en
  español, primera línea ≤72 chars, sin co-authored-by ni firmas.

---

## Backlog y estado

El backlog vivo y el estado actual viven en **`BITACORA.md`** (§ESTADO ACTUAL
y §Backlog vivo). No re-flagear en audits lo que figure ahí como resuelto o
aceptado. Los ítems parqueados por decisión de Rubén: flags
`modo_ruta`/`caja_chica` (ocultos) · geo del cobro · Resend/dominio.
