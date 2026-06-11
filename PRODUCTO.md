# PRODUCTO.md — Misión, visión, día a día y stack de Cobranza ISP (SITECSA CRM)

> **Quién lee esto:** humanos que necesitan entender QUÉ es la app y POR QUÉ
> existe, y AIs que necesitan el contexto de negocio antes de tocar código.
> **Cuándo se actualiza:** cuando cambia la misión, se agrega/quita un módulo
> de producto, cambia un rol, o se reemplaza una pieza del stack. Cambios de
> código del día a día NO se anotan acá (van en `BITACORA.md`).
> **Documentos hermanos:** `ARQUITECTURA.md` (cómo está construida y conectada)
> · `BITACORA.md` (qué se hizo y por qué, sesión por sesión) · `AGENTS.md`
> (reglas y proceso de trabajo para la AI) · `Install Steps/` (build y release).

---

## 1. Misión

Resolver el **ciclo completo de cobranza de internet residencial** para ISPs y
WISPs chicos/medianos de Centroamérica (mercado primario: **Nicaragua**), para
que un ISP real pueda **reemplazar su Excel + WhatsApp** de cobranza con una
sola app que funciona **sin internet** en el campo.

El producto es un SaaS **multi-tenant** modelo B2B:
- El dueño del SaaS (**Rubén**, rol `super_admin`) provee la plataforma.
- Cada ISP cliente es un **tenant** con sus propios admins, cobradores y
  técnicos. Un tenant JAMÁS ve data de otro (aislamiento por RLS en Postgres).

### Visión
Que el dueño de un ISP de 200–2000 clientes abra el dashboard y sepa en 10
segundos cuánto entró hoy, quién debe, y dónde está cada cobrador — y que el
cobrador en una zona rural sin señal cobre, imprima el recibo térmico, y siga
con el próximo cliente sin pensar en "la app". Sin features experimentales,
sin abstracciones prematuras: **cada sprint acerca al MVP del día a día real**.

---

## 2. Roles (quién usa la app y qué ve)

| Rol | Quién es | Dónde vive | Qué hace |
|---|---|---|---|
| `super_admin` | Rubén, dueño del SaaS | `/super/*` (web/desktop) | Crea/configura tenants, gestiona miembros cross-tenant, toggle de módulos por tenant, ve logs de errores. Puede **impersonar** un tenant (entra como su admin, con banner y auditoría; acciones de campo bloqueadas). |
| `admin` | Dueño/gerente del ISP | `/admin/*` (Windows/web) | Catálogo (planes, clientes, contratos), cobradores, cuotas, pagos, reportes, mapa, settings, auditoría, geografía, red. Módulos opcionales: inventario, tickets, incidentes. |
| `admin_cobranza` | Mano derecha del admin | `/admin/*` acotado | Todo lo operativo de cobranza, pero SIN config sensible: no planes, cobradores, settings, geografía, red, inventario, tickets, auditoría. |
| `cobrador` | Usuario de campo | `/*` (Android, móvil-first) | Ve SUS clientes/cuotas asignadas, cobra offline-first (foto del comprobante + recibo térmico Bluetooth), registra visitas. |
| `tecnico` | Técnico de campo (módulo tickets) | `/tecnico/*` (Android) | Ve SUS tickets asignados, los resuelve offline, consume materiales de su custodia (descuenta inventario). No ve dinero. |
| `admin_tickets` | (DIFERIDO — rol incompleto, no se asigna) | — | Admin acotado a tickets/inventario. Existe en DB pero sin shell ni sync propios. |

### Decisión de workflow CRÍTICA (onboarding sin email)
El super_admin NO depende de email para dar de alta tenants/usuarios:
1. Crea el ISP desde `/super/tenants` con el switch "Enviar email" en **OFF**.
2. El server genera una password aleatoria y se la devuelve para copiar.
3. La comparte por WhatsApp/llamada. El cliente entra por `/login` directo.

No hay signup público ni dominio verificado en Resend. **Cualquier finding de
seguridad del tipo "si signup estuviera habilitado..." está fuera de scope.**

---

## 3. El día a día (lifecycle de uso real)

### La jornada del cobrador (el corazón del producto)
1. **Mañana, con señal:** abre la app → PowerSync ya sincronizó su slice
   (sus clientes, cuotas, pagos). Ve "Cobros" ordenado por mora.
2. **Campo, sin señal:** visita al cliente → cobra una cuota (o varias con
   multi-select): monto, método (efectivo NIO/USD, transferencia), descuento
   pronto-pago o cargo de reconexión automáticos según settings, foto del
   comprobante → **todo se guarda en SQLite local al instante**.
3. Imprime el recibo en su térmica Bluetooth (GOOJPRT PT-210; 100% offline,
   logo cacheado en disco). El vuelto SIEMPRE en córdobas, aunque le paguen
   en dólares.
4. Si el cliente no está: registra una **visita** (resultado + nota).
5. **Vuelve la señal:** la cola CRUD sube sola → los triggers de Postgres
   recalculan la verdad (estado de cuota, recaudado) → el admin ve todo.
6. Su recibo lleva **correlativo propio** (prefijo por cobrador) y la mora
   se calcula en hora Nicaragua (UTC-6).

### La jornada del admin
1. Abre el **dashboard**: cobros de hoy/semana/mes, mora, top cobradores.
2. Gestiona el catálogo: alta de cliente → contrato (plan + día de pago) →
   las **cuotas se generan solas** (trigger server, mes a mes).
3. Revisa **pagos** (puede anular con motivo — el pago queda preservado y la
   cuota se restaura), aplica cargos/descuentos, gestiona la mora.
4. Baja **reportes** en PDF y Excel (8 reportes + arqueo de caja con detalle
   USD), con cortes por día en hora Nicaragua.
5. Todo cambio sensible queda en el **change log** (quién, cuándo, qué) —
   accesible desde cada entidad y desde `/admin/audit`.

### La jornada del técnico (módulo opcional tickets)
1. El admin crea un ticket (instalación/reparación/corte) y se lo asigna.
2. El técnico lo ve en su shell, va al campo, lo avanza
   (en progreso → en espera → resuelto) **offline**, con checklist, fotos y
   comentarios. El SLA corre con semáforo (y se pausa en "en espera").
3. Consume materiales de su **custodia** (ej. un router): el inventario se
   descuenta solo y el equipo queda instalado en el cliente.
4. Cortes masivos se agrupan en **incidentes**: el admin marca el nodo/hub/
   puerto caído y los clientes afectados se derivan de la topología de red.

### El mes del dinero (reglas inquebrantables)
El control de dinero es la razón de ser del producto. Las 10 invariantes
exactas viven en `AGENTS.md` § "Invariantes de dinero" (la #1: lo APLICADO a
la cuota es lo que cuenta como recaudado — nunca lo entregado ni el vuelto).
`supabase/tests/invariantes_dinero.sql` las verifica contra data real después
de cada deploy que toque dinero.

---

## 4. Mapa de módulos del producto (qué hay hoy)

**Base (todos los tenants):** clientes · contratos · planes · cuotas · cobro
en campo · pagos · recibos (térmica + PDF) · visitas · fotos · mora /
notificaciones · reportes PDF+Excel · arqueo · mapa offline · dashboard ·
geografía (depto→municipio→comunidad) · red (nodos→hubs→puertos) · change log
universal · settings per-tenant · auditoría.

**Opcionales (toggle por tenant, vendibles por separado):**
- **Inventario**: catálogo (categorías/proveedores/productos), ubicaciones
  (bodega/técnico), seriales cuna-a-tumba, ledger de movimientos, stock mínimo.
- **Tickets + Técnicos + Incidentes**: ciclo de trabajo de campo completo con
  SLA, materiales y outages.

**Panel SaaS (`/super/*`):** tenants, módulos, miembros, impersonación,
error logs de todos los clientes Flutter.

**No implementado a propósito** (decisiones, no olvidos): geo del cobro
(lat/lng null), modo ruta planificada (mapa siempre libre), caja chica,
emails transaccionales (Resend en sandbox).

> El detalle técnico de cada módulo (archivos, providers, tablas, conexiones)
> vive en `ARQUITECTURA.md` §3 — con recetas de cambios comunes en §5.

---

## 5. Stack tecnológico y POR QUÉ cada pieza

**Plataformas objetivo: Android (cobrador/técnico) + Windows (admin)**,
distribución por APK + MSIX con auto-update vía GitHub Releases. Web existe
pero NO es target: el código degrada con `kIsWeb` sin romper.

| Capa | Tecnología | Por qué esta y no otra |
|---|---|---|
| UI | **Flutter** (Dart) | Un codebase para Android + Windows (+ web de cortesía). AOT nativo en móvil. Ecosistema maduro para Bluetooth térmico, mapas, cámara. |
| Estado | **Riverpod 2.x** | Providers tipados y testeables; `StreamProvider` se acopla natural a los streams de PowerSync; `autoDispose` controla memoria con muchos streams abiertos. |
| Navegación | **go_router** | URL como fuente de verdad; `redirect` centralizado = un solo lugar con la lógica "quién puede ir a dónde" (3 shells por rol + gates de sync/módulo/setting). |
| Backend | **Supabase** (Postgres 15 + Auth + Storage + Edge Functions Deno) | Postgres REAL: RLS nativo = multi-tenant físicamente imposible de violar desde el cliente; triggers = fuente de verdad del dinero; JSONB para settings flexibles. Hosted sin DevOps; open-source sin lock-in. |
| Sync | **PowerSync** | Offline-first real: réplica SQLite local por usuario con queries arbitrarias (JOINs/GROUP BY offline); sync rules declarativas = control fino de qué baja a cada rol; conflictos: server gana, sin CRDTs. |
| Impresión | `print_bluetooth_thermal` + ESC/POS **GS v 0 armado a mano** | Las térmicas chinas (PT-210) fallan con `imageRaster` de la lib; el raster manual con polaridad/ancho explícitos fue lo que imprimió bien (resuelto v0.8.0). |
| Mapas | **flutter_map + OSM** + `flutter_map_cache` (tiles en disco) | Gratis, sin API key, offline en Android/Windows. FMTC descartado por conflicto de versiones. |
| Reportes | `pdf`/`printing` + **`excel`** + `file_picker.saveFile` | PDF y .xlsx generados en Dart puro, guardado con diálogo nativo. |
| Email | Resend (**sandbox, fuera del flujo operativo**) | El onboarding es sin email por decisión de producto. |

**Por qué la combinación funciona:** PowerSync + Riverpod + SQLite hacen el
offline-first sin esfuerzo por pantalla; RLS + JWT hacen el multi-tenant sin
esfuerzo por query; los triggers de Postgres hacen el dinero confiable sin
confiar en el cliente. El cliente **espeja** los triggers localmente
(`calcularEstadoCuota`) solo para que la UI sea instantánea offline — al
sincronizar, **el server siempre gana**.

### Números actuales (actualizar en releases mayores)
- App **v0.10.0** · schema PowerSync **v27** · migraciones **0001→0115**.
- ~180 archivos Dart (~54k LOC) · 6 Edge Functions + `_shared/`.
- Tests: 254 en CI (~30 de dinero contra PowerSync real) + 14 invariantes SQL.
- Último audit integral (2026-06-09, 9 agentes): **sin CRITICAL/HIGH** —
  dinero 10/10, RLS sin fugas, integridad estructural limpia.

### Cuándo revisitar el stack
- 100+ tenants concurrentes → revisar plan de Supabase / caché.
- Primer sync lento con tenants enormes → afinar buckets/paginación de sync.
- Hoy ninguna alarma suena: el stack aguanta el MVP y los próximos 6-12 meses.

---

## 6. Principios de producto (los "no negociables")

1. **Offline-first**: el cobrador/técnico opera sin señal. Toda feature nueva
   que exija conexión sincrónica debe declararse explícitamente.
2. **Server gana**: Postgres es la fuente de verdad; el cliente espeja para
   UX instantánea, nunca para decidir.
3. **Multi-tenant con RLS**: toda tabla operativa nace con `tenant_id` + RLS.
4. **Trazabilidad universal**: toda entidad editable tiene change log
   (append-only) accesible desde su pantalla.
5. **Sin email en el onboarding**: password server-side por canal externo.
6. **Simple antes que elegante**: la opción más simple del stack existente
   que resuelva el problema; sin dependencias ni pasos manuales nuevos.
