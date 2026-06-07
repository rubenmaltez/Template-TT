# FASE 3 — Tickets + Roles (técnico / admin_tickets) + Incidentes

> **Estado: PROPUESTA para aprobación de Rubén** (lifecycle CLAUDE.md Fase 2 →
> aprobar → implementar por slices auditados). Base: `PLAN-INVENTARIO-TICKETS-RED.md`
> §Fase 3 + decisiones ya cerradas ahí. Branch:
> `claude/new-features-inventory-tickets-and-technicians`. Schema base: **v20**;
> última migración: **0102**.

## Visión

Cerrar el ciclo operativo del ISP: además de cobrar (Fase 0-2) y tener el catálogo
de red+inventario (Fase 1-2), el ISP gestiona el **trabajo de campo**: instalaciones,
reparaciones, reclamos y **cortes masivos (outages)**. Un **técnico** sale a campo
(móvil-first, offline) con sus tickets asignados, los resuelve, consume materiales
del inventario (descuenta stock) y deja bitácora; el admin ve SLA, asigna y cierra.

Aditivo y opcional: **módulo `tickets`** gateado por tenant (OFF por defecto, lo
enciende el super_admin), sin tocar nada de cobranza.

## Decisiones cerradas (del PLAN, hechas concretas acá)

- **1 rol por usuario.** Se agregan `tecnico` y `admin_tickets` al CHECK de
  `cobradores.rol` (hoy `super_admin/admin/admin_cobranza/cobrador`, 0026) + se
  extiende `set_cobrador_rol` (0093) + getters `esTecnico`/`esAdminTickets` en el
  modelo `Cobrador`.
- **Módulo opcional** `tickets` (`modulos`, `es_base=false` → OFF por defecto;
  el super_admin lo enciende en `/super/tenants/:id`). Gateado por `tenant_modulos`
  + `modulosHabilitadosProvider` + `moduloKey` en menú/router.
- **Estados del ticket:** `abierto → asignado → en_progreso → en_espera → resuelto
  → cerrado` (+ `reabierto`, `cancelado`). Técnico **resuelve**, admin **cierra**.
- **SLA por TIPO** (cada `ticket_tipo` define `sla_horas`); prioridad = etiqueta.
  **SLA derivado en el cliente** (patrón `vencida`/`en_gracia` de `cuota_estado.dart`,
  con `-6h` Nicaragua) + **pausa por `en_espera`** (el tiempo en espera no consume
  SLA). Reapertura = nuevo tramo.
- **Bitácora unificada append-only** (`ticket_eventos`): creación, asignación,
  cambio de estado, comentario, material, adjunto, reapertura. Como el ledger de
  inventario y el audit_log: sin update/delete, se corrige con fila nueva.
- **`cliente_id` nullable** (outage / instalación pre-contrato).
- **Puerto requerido = SOFT** (aviso, no bloqueo) — **unificado con inventario**
  (decisión de Rubén en el cierre de Fase 2: soft hasta que la red esté en prod).
- **Descuento de stock = SERVER-SIDE** (no en SQLite): el técnico registra el
  material consumido offline; al sincronizar, un **trigger server-side** sobre
  `ticket_materiales` inserta el `inv_movimientos` tipo `consumo` que descuenta el
  stock (respeta "server gana" + offline-first). `costo_unit_snapshot` en el material.
- **Transiciones de estado validadas server-side** (trigger sobre `tickets`).
- **Notificaciones in-app** (cero email): tabla `notificaciones` + badge, patrón
  de `notificaciones_mora` / `mora_count_provider`.
- **Incidentes (outages):** `incidentes` apunta a nodo/hub/puerto; los clientes
  afectados se DERIVAN de la cadena; los tickets pueden agruparse por `incidente_id`.
- **Postergado a v2** (del PLAN): checklists por tipo, calendario, firma del cliente,
  auto-cierre, escalation SLA, SLA×prioridad, WhatsApp, código de barras, reservas.

---

## Modelo de datos (tablas nuevas, todas per-tenant, checklist CLAUDE.md)

Todas: `id uuid PK`, `tenant_id NOT NULL` + FK `ON DELETE CASCADE`, RLS scopeada por
`current_tenant_id()` + policy `super_admin_all` a mano, trigger `audit_changelog_trg`,
declaradas en `schema.dart` + `sync-rules.yaml` + bump `_schemaVersion`, registradas
en `audit_changelog.dart`. `ocurrido_en` (device-time) donde se crea/edita offline.

### `ticket_tipos` (catálogo per-tenant)
`nombre`, `descripcion?`, `sla_horas int` (NULL = sin SLA), `color?` (etiqueta),
`activo`, `orden`, `created_at`. CRUD admin (patrón `planes`/inventario).

### `tickets`
`codigo` (correlativo per-tenant, patrón recibos — ver decisión D4), `tipo_id` FK
`ticket_tipos`, `cliente_id` FK `clientes` **nullable**, `puerto_id` FK `red_puertos`
nullable (derivable del cliente; explícito para outage), `incidente_id` FK
`incidentes` nullable, `titulo`, `descripcion`, `estado` CHECK(8 estados),
`prioridad?`, `asignado_a` FK `cobradores` nullable (técnico), `creado_por` FK
`cobradores`, `resuelto_en?`, `cerrado_en?`, `created_at`, `ocurrido_en`. SLA se
**deriva en Dart** (created_at + tipo.sla_horas − tiempo en `en_espera`).

### `ticket_eventos` (bitácora APPEND-ONLY)
`ticket_id` FK, `tipo_evento` CHECK(`creado/asignado/cambio_estado/comentario/
material/adjunto/reabierto/cerrado/cancelado`), `estado_anterior?`, `estado_nuevo?`,
`comentario?`, `hecho_por` FK cobradores, `ocurrido_en`, `created_at`. RLS read+insert
(sin update/delete). Render con `HistorialCambiosWidget`/Agregador (timeline del ticket).

### `ticket_adjuntos` (fotos del ticket)
`ticket_id` FK, `storage_path`, `descripcion?`, `subido_por`, `created_at`. Storage
bucket `ticket-adjuntos/{tenant}/{ticket}/...` (patrón `comprobantes-pago`/`fotos_cliente`).

### `ticket_materiales` (engancha INVENTARIO)
`ticket_id` FK, `producto_id` FK `inv_productos`, `serial_id?` FK `inv_seriales`
(serializado), `cantidad`, `ubicacion_origen_id` FK `inv_ubicaciones` (custodia del
técnico), `costo_unit_snapshot`, `hecho_por`, `ocurrido_en`, `created_at`.
**Trigger AFTER INSERT → inserta `inv_movimientos` tipo `consumo`** (origen =
ubicacion_origen, producto, cantidad; serial → estado `instalado` + cliente del
ticket). Descuento de stock 100% server-side (ver decisión D1).

### `incidentes` (outages)
`titulo`, `descripcion?`, `nodo_id?`/`hub_id?`/`puerto_id?` (FK red, **CHECK: al
menos uno o todos NULL para corte general**), `estado` CHECK(`abierto/resuelto`),
`inicio`, `fin?`, `created_at`. Los clientes afectados se DERIVAN
(`clientes.puerto_id` → hub → nodo). Los tickets se agrupan por `incidente_id`.

### Cambios a tablas existentes
- `cobradores.rol`: ALTER CHECK + `tecnico` + `admin_tickets`.
- `modulos`: INSERT `tickets` (es_base=false).
- (Opcional) `inv_movimientos.ticket_id` ya existe (0101, sin FK) → ahora se usa.

---

## Roles, shell y router

- **`admin_tickets`**: como un admin acotado a tickets/inventario (ve tickets,
  asigna, cierra, ve inventario; NO cobranza/settings sensibles). Vive en el
  **AdminShell** con guardia de menú (subconjunto, como `admin_cobranza`).
- **`tecnico`**: **móvil-first, shell propio** (nuevo `ShellRoute` con bottom-nav,
  estilo `AppShell` del cobrador). Tabs: **Mis tickets** · **Mapa** (clientes/red) ·
  **Perfil** (custodia de inventario, impresora). Landing del router: rol `tecnico`
  → `/tecnico`. Offline-first total (como el cobrador).
- Router: `moduloKey:'tickets'` en las rutas; el técnico no entra a `/admin/*`
  (mismo guard que agregamos para el cobrador).

## Sync rules (offline-first por rol)

- **Admin / admin_cobranza / admin_tickets / impersonated**: `ticket_tipos`,
  `tickets`, `ticket_eventos`, `ticket_adjuntos`, `ticket_materiales`, `incidentes`
  (todo el tenant, `WHERE tenant_id = bucket.tenant_id`).
- **Nuevo bucket `por_tecnico`**: el técnico baja **sus tickets asignados** + sus
  eventos/adjuntos/materiales + el **inventario de su custodia** (`inv_*` filtrado a
  su ubicación `tipo='tecnico'`) + ticket_tipos + la red/geo (catalogo_tenant) +
  clientes de sus tickets. (Diseño cuidado: el técnico NO baja TODO el inventario
  ni todos los clientes — solo lo suyo.)
- Bump `_schemaVersion` **20 → 21** + redeploy sync rules + restart.

## Integridad (cadena CLAUDE.md)

Por cada tabla nueva: schema.dart (tipos bool→int, uuid/ts→text, numeric→real) +
sync-rules `SELECT *` por bucket + `_schemaVersion=21` + `audit_changelog.dart`
(camposVisibles + catálogo + label + value-labels de estados/tipos) + trigger
`audit_changelog_trg`. Verificar SQLite-compat (sin FILTER/::cast/ILIKE) y `-6h`
en toda lógica de límite de día del SLA.

---

## Slicing (cada slice = su PR + audit 3 agentes + testing, patrón Fase 2)

- **3A — Fundación (roles + módulo + ticket core).** Migración(es): roles CHECK +
  `set_cobrador_rol` + módulo `tickets` + `ticket_tipos`/`tickets`/`ticket_eventos`
  + RLS + audit + trigger de transición de estado. App: schema/sync/v21, modelo
  Cobrador, gating, CRUD de tipos (admin), lista/crear/detalle de ticket con
  **timeline (ticket_eventos)** + cambio de estado + **SLA derivado** + adjuntos.
- **3B — Técnico.** Rol `tecnico` shell móvil-first + bucket `por_tecnico` + "Mis
  tickets" + flujo de resolución (cambiar estado, comentar, foto) offline-first.
- **3C — Materiales (engancha inventario).** `ticket_materiales` + **trigger de
  descuento de stock** (`consumo`) + `costo_unit_snapshot` + UI de "agregar
  material" en el ticket (serial/granel desde la custodia del técnico).
- **3D — Incidentes (outages).** `incidentes` + clientes afectados derivados +
  agrupar tickets por incidente + (opcional) capa en el mapa.
- **3E — Notificaciones in-app + audit integral.** Tabla `notificaciones` + badge +
  eventos (ticket asignado, SLA por vencer, incidente). Audit integral de cierre.

## Riesgos

- **`set_cobrador_rol` + RLS de impersonación**: agregar roles toca auth — testear
  que el técnico no acceda a cobranza y que la impersonación siga sana.
- **Descuento de stock server-side**: el trigger de `ticket_materiales`→`consumo`
  debe ser idempotente y respetar stock negativo offline (como inventario).
- **Bucket `por_tecnico`**: el filtro de "su custodia / sus tickets" debe ser
  correcto para no filtrar de menos (técnico sin data) ni de más (fuga).
- **Toca DB/roles/RLS** → checklist de integridad completo + testing con data real.

---

## Decisiones abiertas (necesito tu OK antes de 3A)

- **D1 — Descuento de stock:** ¿trigger `AFTER INSERT` en `ticket_materiales` que
  inserta el `inv_movimientos consumo` (server-side, offline-safe, recomendado), o
  RPC explícito que el cliente llama al confirmar (más control, pero no offline)?
- **D2 — Transiciones de estado:** ¿trigger server-side que valida la transición
  (rechaza saltos inválidos, "server gana", recomendado), o solo validación en la
  UI? El PLAN pide server-side.
- **D3 — Shell del técnico:** ¿`ShellRoute` nuevo móvil-first (recomendado, como el
  cobrador), o reusar el shell del cobrador con tabs por rol?
- **D4 — Código de ticket:** ¿correlativo per-tenant legible (T-00001, patrón
  recibos, recomendado para referencia humana), o solo UUID?
- **D5 — Alcance del primer slice (3A):** ¿arrancamos 3A completo (tipos + tickets +
  timeline + estados + SLA + adjuntos), o partimos 3A en dos (core sin adjuntos/SLA
  primero)?
