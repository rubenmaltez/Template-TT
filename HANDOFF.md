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

## Fase 1.1 — Fixes + features de red post-testing de Rubén (EN CURSO)

Rubén testeó (super_admin impersonando) y reportó bugs/pedidos. Estado:
- ✅ **Puerto no persistía** (`a93ab98`): el `RedPicker` dejaba `_puertosStream` vacío
  al elegir Hub (faltó espejar `_watchPuertos(id)`). Era MI bug, confirmado por
  rastreo de data-flow (no era impersonación). Afectaba a todos los roles.
- ✅ **Banner impersonación duplicado** (`3ac3597`): el inline en detalle cliente/
  contrato se sumaba al del AdminShell → gateado por `!enAdminShell`.
- ✅ **Map-picker + notas del nodo** (`c2ea65d`): `MapaPickerScreen` extraído a
  shared; `_NodoDialog` con notas + "Elegir en el mapa"; soporta edición.
- ✅ **Red editable + historial** (`9115a7f`): menú Editar/Historial por nodo/hub/
  puerto (UPDATE + `HistorialCambiosWidget`).
- ✅ **Geografía: historial** (`cb76bab`): 🕐 por depto/municipio/comunidad.

**PENDIENTE (próximo, bien especificado por los agentes):**
- **Filtro por Nodo** en lista de clientes (`clientes_admin_screen`: clonar
  `_ComunidadChip` → `_NodoChip` + subquery `c.puerto_id IN (SELECT p.id FROM
  red_puertos p JOIN red_hubs h ... WHERE h.nodo_id=?)`) y en **mapa**
  (`mapa_screen`: traer `c.puerto_id`+nodo vía LEFT JOINs, `DropdownFiltro` Nodo).
- **Eliminar (soft, activo=0)** nodo/hub/puerto + geo → requiere filtrar `activo=1`
  en red_admin/red_picker/geografia (varias queries) → su propio pase con audit.
- **Geo: editar** (parametrizar `_promptNombre`) para consistencia con red.
- (Opcional) mostrar nodo en `/admin/mapa`, badge libre/ocupado del puerto.

**⚠️ Foot-gun latente (backlog):** `connector.dart:68-86` traga errores de upload
no-retryables → una fila podría quedar local-only sin persistir (hoy no se dispara
porque RLS permite los INSERT). Documentar/endurecer a futuro.

## Fase 1 — CÓDIGO COMPLETO, falta DEPLOY + TESTING de Rubén

Geografía per-tenant + topología de red (Nodo→Hub→Puerto). Auditada por 4 agentes
(Code+DB, QA UI, QA UX, especialista red); findings aplicados, incluido 1 BLOQUEANTE
de seguridad (policies geo viejas no dropeadas → fuga cross-tenant, ya corregido).
Commits clave: `6f80653` (datos), `32f9bb0` (UI), `26f9705` (fixes audit),
`ffb373c` (campos red: tipo/lat/lng/notas). Schema **v17**.

**Pendiente: Rubén deploya y testea** (pasos detallados que le pasé en el chat):
1. SQL Editor (Dashboard): correr `0097_geografia_per_tenant.sql` y después
   `0098_red_topologia.sql`. ⚠️ 0097 **vacía la geografía** de prueba y nulea
   `clientes.comunidad_id` (data de prueba, OK).
2. PowerSync: **redeploy sync rules** (geo dejó de ser global; +red).
3. App: **restart desde cero** (bump schema v16→17 → DB local nueva).
4. Probar: Admin › Red (crear Nodo→Hub→Puerto), asignar puerto en form de cliente,
   ver "Red"/"Comunidad" en el detalle del cliente, recargar geografía por tenant.

**Recordatorio Fases 2/3 (Inventario/Tickets):** módulos solo activables por
**super_admin**, **deshabilitados por defecto** en el tenant (`tenant_modulos`). Red NO
(es base de cobranza). Notas del especialista para incidentes: tabla `incidentes` con
3 FK nullables nodo/hub/puerto + CHECK; backhaul nodo→nodo cuando un ISP lo pida.

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
