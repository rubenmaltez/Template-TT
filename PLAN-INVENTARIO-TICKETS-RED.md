# PLAN — Inventario + Tickets + Rol Técnico + Red + Geografía per-tenant

> Branch: `claude/inventory-tickets-technician-role`. Backup: `claude/stoic-tesla-cGkJ6`.
> Estado: **alcance aprobado por Rubén** (decisiones abajo). Implementación por
> fases, cada una su PR + audit + testing. Sigue el lifecycle de CLAUDE.md (Fase
> 2 → aprobación → implementación → audit → testing → cierre).

## Visión

Sobre la app de cobranza ISP multi-tenant se agregan, **de forma aditiva** (sin
romper lo existente), 4 cosas:
1. **Geografía per-tenant** (hoy es global → pasa a per-tenant).
2. **Topología de red per-tenant** (Nodo → Hub → Puerto), nueva.
3. **Inventario** (módulo opcional, ya seedeado en `modulos`).
4. **Tickets** + roles `tecnico` y `admin_tickets` + `incidentes` (outages).

## Decisiones cerradas (con Rubén)

- **Secuencia:** Geografía + Red → Inventario → Tickets.
- **Roles:** un rol por usuario (no multi-capacidad). Se agregan `tecnico` y
  `admin_tickets` al CHECK de `cobradores.rol` (vía migración + RPC `set_cobrador_rol`).
- **Geografía:** al migrar a per-tenant, **replicar la geo global actual a cada
  tenant y re-apuntar `clientes.comunidad_id`** (no arrancar vacío).
- **Red:** jerarquía fija **Nodo → Hub → Puerto** (3 niveles), per-tenant. Cliente
  se conecta a un **Puerto** (`clientes.puerto_id`). Solo nombre/código por nivel
  (sin capacidad/ocupación por ahora).
- **Asignación de red al cliente:** **opcional** en general, pero **requerida**
  cuando se le crea un ticket o se le asignan equipos de inventario (se valida en
  esos flujos, no al crear el cliente).
- **Outages:** tabla `incidentes` que agrupa tickets; el incidente apunta a un
  Nodo/Hub/Puerto → clientes afectados se derivan de la cadena.
- **Inventario (defaults):** stock como **ledger inmutable** (`inv_movimientos`)
  + stock proyección derivada (server). Costo promedio ponderado. Multi-ubicación
  simple (central + 1 custodia por técnico). Serial obligatorio+único en equipos;
  granel por cantidad. Stock negativo offline permitido con alerta (server gana).
  Sin reservas. Recepción con proveedor/factura. Técnico solo consume/instala/
  devuelve; recepción/ajuste = admin. Inventario lo ve solo `admin`.
- **Tickets (defaults):** módulo opcional por tenant. Los crea el staff (el
  técnico también puede, queda `abierto`). SLA **por tipo** (prioridad = etiqueta).
  Estados: abierto → asignado → en_progreso → en_espera → resuelto → cerrado
  (+ reabierto, cancelado). Técnico resuelve, admin cierra. Fotos opcionales.
  Notificaciones **in-app** (cero email). `cliente_id` nullable (outage/instalación
  pre-contrato). Reapertura = nuevo tramo de SLA. SLA **derivado en cliente**
  (patrón `vencida`/`en_gracia`, con `-6h` Nicaragua) + pausa por `en_espera`.
  `costo_unit_snapshot` en materiales. Descuento de stock = RPC server-side al
  sincronizar (no en SQLite). Transiciones de estado validadas server-side.
- **Postergado a v2:** checklists por tipo, calendario visual, firma del cliente,
  auto-cierre, escalation SLA, SLA×prioridad, WhatsApp, código de barras, capacidad
  de puertos, costeo FIFO, reservas, alertas de stock mínimo.

## Principios (heredados de CLAUDE.md, NO violar)

- Toda tabla operativa: `tenant_id NOT NULL` + FK, RLS por `current_tenant_id()`,
  **policy `super_admin_all` agregada a mano** (no se hereda del `do$$` de 0026),
  trigger `audit_changelog_trg`, declarada en `schema.dart` + `sync-rules.yaml` +
  bump `_schemaVersion` en `db.dart`, registrada en `audit_changelog.dart`.
- Offline-first: el técnico opera sin señal (`ocurrido_en` device-time); server gana.
- Append-only en ledgers (inventario movimientos, ticket_eventos): no editar/borrar,
  se corrige con fila nueva.
- Última migración base: **0096**. Schema version base: **16**.

---

## FASE 1 — Geografía per-tenant + Topología de red (PRÓXIMA)

### 1A. Geografía global → per-tenant (toca DATA VIVA — máximo cuidado)

**Tablas afectadas:** `departamentos`, `municipios`, `comunidades` (creadas en
migración 0003, hoy globales sin `tenant_id`). FK viva: `clientes.comunidad_id`.

**Migración (orden):**
1. `ALTER TABLE` agregar `tenant_id uuid` (nullable temporal) + FK a `tenants` a las 3 tablas.
2. **Backfill:** por cada tenant, replicar el árbol global (depto→muni→comunidad)
   creando filas tenant-scoped, manteniendo un mapeo `id_global → id_nuevo` por tenant
   (preservando la jerarquía padre-hijo).
3. **Re-apuntar clientes:** `UPDATE clientes SET comunidad_id = <id_nuevo del mismo
   tenant que corresponde a la comunidad global previa>`. (Cada cliente ya tiene
   `tenant_id`, así que se mapea su comunidad global → la réplica de SU tenant.)
4. Borrar las filas globales viejas (las que tenían `tenant_id` null).
5. `ALTER COLUMN tenant_id SET NOT NULL`.
6. RLS: reemplazar las policies permisivas por scoping `current_tenant_id()` +
   `super_admin_all` a mano. Trigger `audit_changelog_trg` en las 3.

**Cliente / app:**
- `schema.dart`: agregar `Column.text('tenant_id')` + índices por tenant a las 3 tablas. Bump `_schemaVersion` 16 → 17.
- `sync-rules.yaml`: el bucket `geografia` global pasa a parámetro por tenant.
- `audit_changelog.dart`: registrar las 3 entidades (ahora auditables).
- `geo_picker.dart` / `geografia_admin_screen.dart`: sin cambio funcional (ya
  consultan local), validar que el scoping por tenant funcione.

**⚠️ Riesgo:** si el re-apuntado de `clientes.comunidad_id` falla, clientes quedan
sin comunidad. Mitigación: migración idempotente + verificación post (contar
clientes con comunidad antes/después) + tenemos el branch backup. Testing en
Supabase con data real ANTES de confiar.

### 1B. Topología de red (greenfield, sin backfill)

**Tablas nuevas (per-tenant, checklist estándar):**
- `red_nodos` (id, tenant_id, nombre, codigo?, notas, activo).
- `red_hubs` (id, tenant_id, nodo_id FK, nombre, codigo?, activo).
- `red_puertos` (id, tenant_id, hub_id FK, nombre/numero, codigo?, activo).

**Cliente:** `ALTER TABLE clientes ADD COLUMN puerto_id uuid` (nullable, FK a
`red_puertos`). Nodo/Hub se derivan de la cadena `puerto → hub → nodo`.

**App:**
- `schema.dart`: 3 tablas nuevas + `clientes.puerto_id`. (mismo bump v17).
- `sync-rules.yaml`: buckets per-tenant para las 3.
- `audit_changelog.dart`: registrar las 3.
- UI: pantalla CRUD de topología (admin) — patrón de `geografia_admin_screen`.
  Selector en cascada Nodo→Hub→Puerto en el form de cliente — patrón de `geo_picker`.

**Validación condicional (se implementa en Fases 2/3):** al crear ticket o asignar
equipo, exigir que el cliente tenga `puerto_id`.

### Entregable Fase 1
Migración(es) SQL + schema/sync/version + UI CRUD red + picker red en cliente +
audit. Audit (Code + DB integrity + QA) + testing manual con data real.

---

## FASE 2 — Inventario (resumen; se detalla al llegar)

Tablas: `inv_categorias`, `inv_productos`, `inv_seriales`, `inv_ubicaciones`,
`inv_stock` (proyección), `inv_movimientos` (ledger), `inv_proveedores`,
`inv_recepciones`. Stock derivado del ledger por trigger/RPC server-side.
Serial con historial cuna-a-tumba (patrón Agregador del HistorialWidget).
Custodia por técnico (ubicación `tipo='tecnico'`). Gateado por módulo `inventario`.
Equipos instalados visibles en pantalla de cliente/contrato.

## FASE 3 — Tickets + roles + incidentes (resumen; se detalla al llegar)

Roles `tecnico` (móvil-first, shell propio estilo cobrador) y `admin_tickets`.
Tablas: `ticket_tipos`, `tickets`, `ticket_eventos` (bitácora unificada,
append-only), `ticket_adjuntos`, `ticket_materiales` (engancha inventario),
`incidentes` (agrupa por Nodo/Hub/Puerto → clientes afectados derivados).
SLA derivado en cliente + pausa. Notificaciones in-app. Módulo `tickets` nuevo
(INSERT en `modulos`), gateado por `tenant_modulos`. Descuento de stock server-side.
Validar: ticket requiere `cliente.puerto_id`.
