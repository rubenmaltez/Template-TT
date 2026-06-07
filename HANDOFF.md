# HANDOFF — dónde vamos quedando

> **Claude: leé ESTO PRIMERO al abrir la sesión.** Es el estado vivo del
> proyecto, en una pantalla. Mantenelo CORTO (≤1 pantalla). El detalle vive en
> los otros docs (links abajo). **Actualizá este archivo al CERRAR cada sesión**
> (es parte del lifecycle de CLAUDE.md, Fase 6).

---

## Estado actual

- **Branch de trabajo (sesión 2026-06-07):** `claude/nifty-cori-KF2PZ`, tip `d380c82`
  (salió de `6e2b03a`, el mismo punto que `claude/inventory-tickets-technician-role`).
  ⚠️ **Las dos branches DIVERGIERON**: todo el 2C-2/2D de esta sesión está SOLO en
  `nifty-cori-KF2PZ` (6 commits por encima). `inventory-tickets-technician-role` quedó
  en `6e2b03a`. Reconciliar (merge/ff) cuando Rubén lo decida — no se tocó esa branch.
- **Branch BACKUP (no tocar):** `claude/stoic-tesla-cGkJ6` — congelado en `7bc16aa`.
- **Schema PowerSync:** `_schemaVersion = 20` (`lib/powersync/db.dart`). 2C-2/2D NO
  agregaron tablas → sin bump nuevo, sin redeploy de sync rules.
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

## Fase 2 — Inventario (EN CURSO, por slices auditados)

Módulo OPCIONAL: gateado por `tenant_modulos` ('inventario', es_base=false → OFF
por defecto; el super_admin lo habilita en `/super/tenants/:id`). Decisiones:
stock se DERIVA del ledger (`inv_movimientos`, slice 2C) — **sin** tabla inv_stock
ni trigger de proyección. Fase 2 es admin-facing; custodia por técnico = Fase 3.

- ✅ **2A (gating + catálogo)** commit `cf32f3d`, **en auditoría**: migración 0099
  (inv_categorias/proveedores/productos + RLS + audit + `id` en tenant_modulos para
  sync); `tenant_modulos` synced + `modulosHabilitadosProvider` + `_MenuItem.moduloKey`
  (no lo bypassa el super_admin); `InventarioScreen` = catálogo Productos (CRUD +
  categoría inline + serializado/granel + historial). schema **v18**.
- ✅ **2B (ubicaciones + proveedores)** commit `d690c13`, **en auditoría**: migración
  0100 (inv_ubicaciones); InventarioScreen en pestañas (Productos|Ubicaciones|
  Proveedores), CRUD+historial en cada una. schema **v19**.
- ✅ **2C-1 (ledger + ingreso + existencias)** commits `5e55f47`+fix, **auditado**:
  migración 0101 (inv_seriales + inv_movimientos append-only); pestaña Existencias
  (stock derivado = Σdestino−Σorigen); Ingreso (serializado/granel, **atómico vía
  writeTransaction**). schema **v20**. `costo_promedio` NO se auto-recalcula aún.
- ✅ **2C-2 (ciclo de movimientos) — HECHO + AUDITADO** (sesión 2026-06-07, branch
  `nifty-cori-KF2PZ`). **NO** requirió migración ni bump (0099-0101 ya cubrían todo).
  - **Asignar** (`580f111`): stock de SERIALIZADOS pasa a derivarse del **estado del
    serial** (`COUNT(estado='en_stock')`), no del ledger → cierra las 2 divergencias del
    audit (doble-asignación / ubicación NULL ya no inflan/desinflan). Guard
    `estado='en_stock'` re-validado DENTRO del writeTransaction. Captura `contrato_id`
    (auto si 1, `_ContratoPicker` si varios). Aviso suave si el cliente no tiene
    `puerto_id` (no bloquea — se endurece cuando la red esté en prod). Búsqueda de
    cliente multi-campo (nombre/código/cédula/teléfono).
  - **Ciclo del serial** (`c66eea4`): Devolver a stock / Transferir de ubicación / Dar de
    baja (dañado/retirado/baja, con motivo). Cada una atómica + re-valida estado.
  - **Granel** (`e554446`): Egreso / Ajuste± (motivo obligatorio) / Transferencia vía 2º
    FAB en Existencias. Stock de granel sigue = `Σdestino − Σorigen`.
  - **Guardas de borrado** (`b33c5be`): producto/ubicación no se borran si están en uso.
  - **Fixes del audit** (`d380c82`): guarda de borrado de proveedor; feedback del stock
    resultante (avisa si negativo) en movimiento de granel; estado vacío del diálogo de
    granel; "Cambiar estado" vs "Dar de baja" según el estado del equipo.
- ✅ **2D (equipos instalados en la ficha del cliente) — HECHO** (`df266ab`):
  `cliente_detail_screen.dart` sección "Equipos instalados" (serial/producto/MAC),
  gateada por módulo inventario + rol admin/admin_cobranza (las inv_ no sincronizan al cobrador).
- ⏳ **Backlog 2C/2D (documentado, NO bloquea):** stock por UBICACIÓN (hoy es global por
  producto → se puede "egresar de la ubicación equivocada" sin error, M2 del audit) ·
  ciclo del equipo dañado-en-casa-del-cliente (hoy "dañado" limpia el vínculo y sale de
  la ficha; el historial lo preserva — Rubén OK con esto) · `costo_promedio` ponderado ·
  value-labels de tipos de movimiento en el change-log (hoy muestran el valor crudo) ·
  TOCTOU advisory en guardas de borrado (server con FK respalda).

> ⚠️ Deploy Fase 2 (al final, todo junto): correr `0099` + `0100` + `0101` por
> Dashboard, redeploy sync rules, restart (**schema v20**). 2C-2/2D NO agregaron
> migraciones (reusan 0099-0101). Para ver Inventario el super_admin habilita
> 'inventario' del tenant en `/super/tenants/:id`.

## Fase 1.1 — Fixes + features de red post-testing de Rubén (HECHO)

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

**HECHO (en auditoría):**
- ✅ **Filtro por Nodo** en lista de clientes (`c211a38`: `_NodoChip` + subquery
  `c.puerto_id IN (red_puertos del nodo via hub)`) y en **mapa** (LEFT JOINs
  puerto→hub→nodo + dropdown "Nodo" + `pasaNodo`).
- ✅ **Editar + Eliminar** geo y **Eliminar** red (`c03dd8b`): menú por fila
  Editar/Historial/Eliminar. Eliminar = **borrado duro con guarda de "en uso"**
  (no borra si tiene hijas/clientes; puerto se chequea a mano porque su FK es
  ON DELETE SET NULL). Geo editar reusa `_promptNombre(inicial:)`. Decidí NO
  soft-delete: el guard evita el caso "valor asignado que desaparece" sin migración.
- Corriendo auditoría del lote (foco: lógica de las guardas + binding de params).

**PENDIENTE (opcional / próximo):**
- (Opcional) mostrar nodo en `/admin/mapa` como capa, badge libre/ocupado del puerto.
- Fases 2/3 (Inventario / Tickets) — ver PLAN.

**⚠️ Backlog (no bloqueante):**
- `connector.dart:68-86` traga errores de upload no-retryables → fila podría quedar
  local-only (hoy no se dispara). Documentar/endurecer.
- **R1 — borrar puerto bajo multi-admin offline**: la guarda cuenta clientes en
  SQLite local y `clientes.puerto_id` es `ON DELETE SET NULL` → si una asignación
  hecha por otro admin no sincronizó, borrar el puerto nulea ese vínculo en server
  en silencio (recableable, no se pierde el cliente). No pasa en single-admin.
  **Hardening si se decide:** cambiar la FK a `ON DELETE RESTRICT` (migración nueva,
  alinea con la guarda + uniforme con geo) o mover el borrado a RPC server-side.
- **R2 — unicidad de serial bajo multi-admin offline (inv)**: el pre-check de
  `inv_seriales.serial` lee SQLite local; si otro device creó el serial sin
  sincronizar, el INSERT choca el UNIQUE server (23505). Ya NO es silencioso (el
  connector surfacea el error CRUD en SnackBar). Bajo en single-admin. Hardening
  futuro: RPC server-side de ingreso, o aceptar el surfaceo actual.
- **costo_promedio**: hoy se guarda `costo_unitario` por movimiento/serial pero NO
  se recalcula el promedio ponderado del producto. Agregar cuando se quiera valuación.

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
