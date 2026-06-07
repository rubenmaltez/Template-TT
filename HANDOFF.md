# HANDOFF — dónde vamos quedando

> **Claude: leé ESTO PRIMERO al abrir la sesión.** Es el estado vivo del
> proyecto, en una pantalla. Mantenelo CORTO (≤1 pantalla). El detalle vive en
> los otros docs (links abajo). **Actualizá este archivo al CERRAR cada sesión**
> (es parte del lifecycle de CLAUDE.md, Fase 6).

---

## Estado actual

- **Branch de trabajo:** `claude/inventory-tickets-technician-role` (NUEVO).
- **Branch BACKUP (no tocar):** `claude/stoic-tesla-cGkJ6` — congelado en `7bc16aa`,
  respaldo completo por si hay que volver atrás.
- **Salió de:** `7bc16aa` (todo el trabajo previo está incluido).
- **Schema PowerSync:** `_schemaVersion = 16` (`lib/powersync/db.dart`). Sin cambios de DB pendientes.
- **Plataformas target:** Android + Windows (web degrada sin romper, NO es target).
- **App version:** v0.9.0 (ver `RELEASE.md`).

## Objetivo de este branch

**Plan completo y alcance APROBADO en `PLAN-INVENTARIO-TICKETS-RED.md`** (leer ahí el detalle).
Resumen: 4 features aditivos, por fases (cada una su PR + audit + testing):
1. **Fase 1 (próxima):** Geografía global→per-tenant (con backfill + reconexión de
   `clientes.comunidad_id`) + Topología de red per-tenant (Nodo→Hub→Puerto, `clientes.puerto_id`).
2. **Fase 2:** Inventario (ledger de movimientos, módulo opcional ya seedeado).
3. **Fase 3:** Tickets + roles `tecnico`/`admin_tickets` + `incidentes` (outages).

Decisiones cerradas: 1 rol por usuario; red opcional en cliente pero requerida para
ticket/asignar equipos; SLA por tipo; notificaciones in-app; etc. (detalle en el PLAN).

> ⚠️ Tocan DB/roles/RLS → checklist de integridad de CLAUDE.md. Fase 2 ya cumplida
> (propuesta aprobada); **falta aprobar el detalle de la Fase 1 antes de implementar**.
> ⚠️ Geografía toca DATA VIVA (FK de clientes) → migración con backfill + testing con data real.

## Sesión anterior (2026-06-06 cont.) — qué se hizo

Lote UX/reportes, **sin migraciones**, auditado (3 agentes, 0 bloqueantes):
1. **Reportes con detalle USD** (cobros/por cobrador/fiscal): columnas Moneda /
   Entregado (orig.) / Tasa / Vuelto. Recaudado sigue = `monto_cordobas`. PDFs en landscape.
2. **Impresora del sistema en PC** (recibo, solo desktop): `Printing.layoutPdf`.
3. **Búsqueda multi-campo en el mapa**: nombre/cédula/teléfono/código cliente/código contrato.
4. **Transición entre vistas** — varias iteraciones hasta que cerró:
   (a) `AnimatedSwitcher`/`_ShellFade` envolviendo el body → fallaba (el Navigator
   interno del ShellRoute cruzaba 2 pantallas encimadas);
   (b) fade secuencial por ruta con `Interval` → Rubén lo vio brusco/parpadeo;
   (c) FadeThrough (zoom+fade) → seguía viéndose overlap (un fade ES un cruce de
   opacidades, siempre muestra las 2 un instante);
   (d) **FINAL (`c2a8edf`): `_CoverSlide`** — deslizamiento con COBERTURA OPACA
   (la entrante entra desde la derecha tapando a la saliente; z-order + fondo
   opaco → nunca se ven las dos). Por ruta en `router.dart`, 320ms.
   **Lección:** en `ShellRoute` la transición va a NIVEL DE PÁGINA (pageBuilder);
   y NINGÚN fade cumple "que no se vean encimadas" → para eso hay que tapar (slide opaco).
   ⏳ Falta OK de Rubén de este modo.
5. **Dashboard** sin card "Acciones rápidas".

Detalle completo → `REPORTE-SESION.md` (entrada 2026-06-06 cont.).

## Fase 1 EN CURSO (capa de datos lista)

Migraciones **0097** (geografía per-tenant) + **0098** (red Nodo→Hub→Puerto +
`clientes.puerto_id`). Schema bump **16→17**. Sync rules: geografía dejó de ser
bucket global, geo+red van per-tenant en `catalogo_tenant` + `impersonated_tenant`.
Audit registrado (6 entidades + lookups). **Geografía per-tenant COMPLETA**
(DB + sync + escrituras con tenant_id en geo_picker y geografia_admin_screen + audit).

**Pendiente Fase 1 (próximo):**
- **UI de RED:** pantalla CRUD admin (Nodo/Hub/Puerto) + selector en cascada en el
  form de cliente (`clientes.puerto_id`) + ruta en router + ítem de menú.
- Luego: audit (Code+DB+QA) + pasos de testing. Migraciones las deploya Rubén por
  Dashboard (0097 es destructiva de geo test — vacía geo y nulea `clientes.comunidad_id`).
- ⚠️ **No deployar/testear hasta cerrar la UI de red** (queda coherente todo junto).

## Otros pendientes
- 📄 `ARQUITECTURA.md` — revisar exactitud (3 puntos marcados) cuando haya tiempo.
- Backlog persistente: ver fin de `CLAUDE.md` (no re-flaggear ítems ya resueltos).

## Docs del proyecto (qué leer y para qué)

| Doc | Para qué |
|---|---|
| `HANDOFF.md` (este) | Dónde quedamos AHORA. Leer primero. |
| `CLAUDE.md` | Reglas, proceso/lifecycle, invariantes de dinero, backlog. |
| `ARQUITECTURA.md` | Módulos y cómo se interconectan (flujo de datos). |
| `ESTADO-APP.md` | Snapshot detallado de estado/cobertura/findings. |
| `REPORTE-SESION.md` | Comportamiento esperado por feature + historial de fixes. |
| `TESTING.md` | Cómo se testea (setup + loop manual por feature). |
| `STACK.md` / `ROADMAP.md` | Stack técnico / plan a futuro. |
