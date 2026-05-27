# BULK 12 — Rework UI/UX Admin (Plan de Diseño)

Referencia para el refactor completo de la interfaz admin.
Claude Code debe leer este archivo junto con CLAUDE.md y ROADMAP.md.

---

## Principios de diseño

1. **Navegación jerárquica centrada en el cliente**: toda la data operativa
   (contratos, cuotas, pagos) vive dentro del cliente, no en tabs separados.
2. **Una sola interfaz para todos los roles**: admin, admin_cobranza y cobrador
   ven la misma pantalla. Campos/acciones se ocultan según rol y settings.
3. **Sidebar + tabs internos**: sidebar para secciones principales, tabs
   dentro de cada sección para subsecciones.
4. **Panel lateral en desktop**: en pantallas anchas (≥900px), el detalle
   se abre en un panel lateral sin perder la lista. En mobile, push navigation.
5. **Contratos inmutables**: un contrato creado no se edita — se anula/desactiva
   y se crea uno nuevo.

---

## Sidebar principal

```
┌─────────────────────┐
│ Logo / Nombre ISP   │
│ Usuario + Rol       │
├─────────────────────┤
│ 📊 Resumen          │  ← Dashboard con KPIs
│ 👥 Clientes         │  ← Gestión integral del cliente
│ 👷 Personal         │  ← Cobradores + admins del tenant
│ 📋 Planes           │  ← Catálogo de planes (solo admin)
│ 📈 Reportes         │  ← PDFs + CSV
│ 🗺️ Mapa             │  ← Clientes geolocalizados
│ 🔔 Mora             │  ← Notificaciones de mora
│ 📝 Auditoría        │  ← Log de cambios (solo admin)
│ 🌍 Geografía        │  ← Depto/Municipio/Comunidad (solo admin)
│ ⚙️ Configuración    │  ← Settings panel
├─────────────────────┤
│ 🔑 Cambiar contraseña│
│ 🚪 Cerrar sesión    │
│ v0.4.0              │
└─────────────────────┘
```

**Tabs eliminados del sidebar** (ahora viven dentro de Clientes):
- ~~Contratos~~ → dentro del detalle del cliente
- ~~Cuotas~~ → dentro del contrato del cliente
- ~~Pagos~~ → dentro del contrato/cuota del cliente

**Visibilidad por rol**:
| Item | admin | admin_cobranza | cobrador |
|------|-------|----------------|----------|
| Resumen | ✅ Dashboard completo | ✅ Dashboard | ✅ Home cobrador |
| Clientes | ✅ Todos | ✅ Todos | ✅ Solo asignados |
| Personal | ✅ | ❌ | ❌ |
| Planes | ✅ | ❌ | ❌ |
| Reportes | ✅ | ✅ | ❌ |
| Mapa | ✅ | ✅ | ✅ |
| Mora | ✅ | ✅ | ✅ (solo suyas) |
| Auditoría | ✅ | Toggle | ❌ |
| Geografía | ✅ | ❌ | ❌ |
| Configuración | ✅ | ❌ | ❌ |

---

## Flujo de navegación: Clientes

### Lista de clientes
```
┌────────────────────────────────────────────────────┐
│ 🔍 Buscar por nombre, cédula, teléfono             │
│ [Cobrador ▼] [Comunidad ▼] [Sin cobrador] [Mora]  │
├────────────────────────────────────────────────────┤
│ 👤 Juan Pérez                                      │
│    La Racachaca · Cobrador: Pedro                  │
│    2 contratos · 3 cuotas vencidas · C$ 1,500 mora│
│                                                    │
│ 👤 María López                                     │
│    Altagracia · Cobrador: Pedro                    │
│    1 contrato · Al día                             │
│                                                    │
│ [+ Nuevo cliente]                                  │
└────────────────────────────────────────────────────┘
```

**Cada card de cliente muestra**:
- Nombre, comunidad, cobrador asignado
- Cantidad de contratos activos
- Estado de mora (cuotas vencidas + monto)
- Badge si tiene cuotas manuales pendientes

---

### Detalle del cliente

**Desktop (≥900px)**: Panel lateral que se abre a la derecha de la lista.
**Mobile (<900px)**: Push navigation (pantalla completa).

```
┌────────────────────────────────────────────────────┐
│ ← abby test                              [Editar] │
├────────────────────────────────────────────────────┤
│                                                    │
│ ┌─ Información ──────────────────────────────────┐ │
│ │ Cédula: 001-140697-1001X                       │ │
│ │ Teléfono: 86879520     [Llamar] [WhatsApp]     │ │
│ │ Dirección: puma altagracia...                  │ │
│ │ GPS: 12.13889, -86.28973  [Navegar]            │ │
│ │ Cobrador: Cobrador Piloto                      │ │
│ └────────────────────────────────────────────────┘ │
│                                                    │
│ ┌─ Fotos ────────────────────────────────────────┐ │
│ │ [foto1] [foto2] [foto3] [+ Agregar]            │ │
│ └────────────────────────────────────────────────┘ │
│                                                    │
│ ┌─ Contratos (2 activos) ────────────────────────┐ │
│ │                                                │ │
│ │ 📋 Plan Básico 10 Mbps                         │ │
│ │    Desde 01/01/2026 · 24 cuotas · 4 vencidas   │ │
│ │    Estado: Activo                      [Ver →]  │ │
│ │                                                │ │
│ │ 📋 TV Cable Premium                            │ │
│ │    Desde 01/03/2026 · 12 cuotas · Al día       │ │
│ │    Estado: Activo                      [Ver →]  │ │
│ │                                                │ │
│ │ [+ Nuevo contrato]                             │ │
│ └────────────────────────────────────────────────┘ │
│                                                    │
│ ┌─ Cuotas manuales (sin contrato) ──────────────┐ │
│ │ 📝 Reconexión · Mayo 2026 · 531 C$    [Cobrar] │ │
│ │ 📝 Instalación · Mayo 2026 · 400 C$   [Cobrar] │ │
│ │ [+ Nueva cuota manual]                         │ │
│ └────────────────────────────────────────────────┘ │
│                                                    │
│ ┌─ Visitas recientes ───────────────────────────┐ │
│ │ 24/05 - Visita fallida, no estaba en casa      │ │
│ │ [Registrar visita]                             │ │
│ └────────────────────────────────────────────────┘ │
│                                                    │
│ ┌─ Historial de pagos ──────────────────────────┐ │
│ │ CP-00003 · 500 C$ · Efectivo · 26/05/2026     │ │
│ │ CP-00002 · 550 C$ · Anulado                   │ │
│ │ [Ver todos →]                                  │ │
│ └────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────┘
```

**Acciones del admin** (ocultas al cobrador):
- Botón "Editar" en la info del cliente
- "Nuevo contrato"
- "Nueva cuota manual"
- Asignar/reasignar cobrador

**Acciones del cobrador**:
- Cobrar cuotas (botón en cada cuota pendiente)
- Registrar visita
- Llamar / WhatsApp / Navegar

---

### Detalle del contrato

Se abre al tocar "Ver →" en un contrato. En desktop: panel lateral
más ancho o reemplaza el detalle del cliente. En mobile: push.

```
┌────────────────────────────────────────────────────┐
│ ← Plan Básico 10 Mbps — abby test                 │
├────────────────────────────────────────────────────┤
│                                                    │
│ ┌─ Datos del contrato ──────────────────────────┐ │
│ │ Plan: Plan Básico 10 Mbps (500 C$/mes)         │ │
│ │ Inicio: 01/01/2026                             │ │
│ │ Día de pago: 15 de cada mes                    │ │
│ │ Cuotas: 4/24 pagadas                           │ │
│ │ Monto total: 12,000 C$                         │ │
│ │ Pendiente: 10,000 C$                           │ │
│ │ Estado: Activo                                 │ │
│ │                                [Anular contrato]│ │
│ └────────────────────────────────────────────────┘ │
│                                                    │
│ ┌─ Cuotas ──────────────────────────────────────┐ │
│ │ ☑ Enero 2026   · Vencida 105d  · 500 C$       │ │
│ │ ☑ Febrero 2026 · Vencida 77d   · 500 C$       │ │
│ │ □ Marzo 2026   · Vencida 46d   · 500 C$       │ │
│ │ □ Abril 2026   · Vencida 16d   · 500 C$       │ │
│ │ □ Mayo 2026    · Al día         · 500 C$       │ │
│ │ □ Junio 2026   · 6d             · 500 C$       │ │
│ │ ...                                            │ │
│ │                                                │ │
│ │ [Cobrar 2 cuotas]  ← FAB cuando hay selección │ │
│ └────────────────────────────────────────────────┘ │
│                                                    │
│ ┌─ Pagos de este contrato ──────────────────────┐ │
│ │ CP-00003 · 500 C$ · Efectivo · 26/05  [🕐]    │ │
│ │ CP-00002 · 550 C$ · Anulado           [🕐]    │ │
│ │ CP-00001 · 500 C$ · Anulado           [🕐]    │ │
│ └────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────┘
```

**Multi-select con orden obligatorio**: Mismo comportamiento que ya
implementamos — solo cuotas consecutivas desde la más vieja.

**Contrato inmutable**: No hay botón "Editar". Solo "Anular contrato"
que desactiva el contrato y sus cuotas pendientes.

---

## Cambios técnicos requeridos

### Pantallas a crear/reescribir
| Pantalla | Estado | Qué cambia |
|----------|--------|------------|
| `ClienteDetailScreen` | REWRITE | Unificada admin+cobrador, secciones expandibles |
| `ContratoDetailScreen` | NEW | Vista de contrato con cuotas + pagos |
| `AdminShell` sidebar | MODIFY | Quitar Contratos/Cuotas/Pagos tabs |
| `AppShell` (cobrador) | MODIFY | Mismo sidebar simplificado |
| `ClienteFormScreen` | KEEP | Se accede desde el detalle del cliente |
| `ContratoFormScreen` | MODIFY | Se accede desde el detalle del cliente |
| `ClienteFotosWidget` | NEW | Galería de fotos con upload múltiple |

### Pantallas a eliminar
| Pantalla | Razón |
|----------|-------|
| `contratos_admin_screen.dart` | Contratos viven dentro del cliente |
| `cuotas_admin_screen.dart` | Cuotas viven dentro del contrato |
| `pagos_admin_screen.dart` | Pagos viven dentro del contrato |
| `cobradores_admin_screen.dart` | Renombrado a "Personal" |

### Pantallas que se mantienen
| Pantalla | Cambios |
|----------|---------|
| Dashboard admin | Se mantiene igual |
| Planes | Se mantiene (solo admin) |
| Reportes | Se mantiene |
| Mapa | Se mantiene |
| Mora | Se mantiene |
| Auditoría | Se mantiene |
| Geografía | Se mantiene |
| Configuración | Se mantiene |

---

## Sprints propuestos

### Sprint 1: Sidebar unificado + routing ✅
- ✅ Sidebar simplificado (6 items)
- ✅ Ruta /admin/clientes/:id → detalle unificado
- ✅ Admin list navega al detalle (no al form)

### Sprint 2: Detalle del cliente unificado (EN PROGRESO)
- ✅ Sección contratos (activos + cancelados colapsable)
- ✅ Botón Editar (admin only) + Historial (admin only)
- ✅ Role detection (esAdmin, esCobrador, enAdminShell)
- ⏳ Quitar cuotas/pagos del detalle (mover a Sprint 3)
- ⏳ Foto del cliente visible en el detalle (no solo en edición)
- ⏳ Filtro activos/inactivos en lista de clientes
- ⏳ Quitar toggle activo del form del cobrador

### Sprint 3: Detalle del contrato
- Pantalla nueva ContratoDetailScreen
- Cuotas del contrato con multi-select + orden obligatorio
- Pagos del contrato con historial de cambios
- Contrato inmutable (solo cambiar estado)
- Navegación desde detalle cliente → contrato

### Sprint 4: Fotos múltiples del cliente
- Upload múltiple (max 10) a Storage
- Galería visible en el detalle del cliente
- Solo admin/admin_cobranza pueden subir/eliminar

### Sprint 5: Polish + testing integral desde cero
- Testing completo de todas las interfaces nuevas
- Consistencia visual, labels, colores
- Audit integral final

---

## Decisiones confirmadas

1. **Fotos máximo por cliente**: 10. Storage bucket `fotos-clientes/{tenant}/{cliente_id}/`.
2. **Quién sube fotos**: Solo admin y admin_cobranza. Cobrador ve las fotos
   pero no puede subir/eliminar.
3. **Anulación de contrato**: Al anular, todas las cuotas pendientes del
   contrato se anulan automáticamente. El contrato queda en estado "anulado"
   visible en un filtro "Anulados" (separado de los activos). Todo queda
   en registros para auditoría.
4. **Personal**: El tab "Personal" incluye la funcionalidad de invitar
   nuevo personal (cobradores, admin_cobranza) con sus respectivos roles.
   Reemplaza el actual tab "Cobradores".

## Decisiones Sprint 2 (detalle del cliente)

### Permisos por rol
| Acción | Admin | Admin cobranza | Cobrador |
|--------|-------|----------------|----------|
| Ver detalle cliente | ✅ | ✅ | ✅ |
| Editar info cliente | ✅ | ✅ | ❌ |
| Desactivar/reactivar cliente | ✅ | ✅ | ❌ |
| Ver contratos | ✅ | ✅ | ✅ (solo ver) |
| Crear contrato nuevo | ✅ | ✅ | ❌ |
| Cambiar estado contrato | ✅ | ✅ | ❌ |
| Ver cuotas del contrato | ✅ | ✅ | ✅ (todas con filtro) |
| Editar cuotas | ✅ | ✅ | ❌ |
| Cobrar cuotas | ✅ | ✅ | ✅ |
| Registrar visita | ✅ | ✅ | ✅ |
| Ver historial cambios | ✅ | Toggle | ❌ |
| Subir fotos | ✅ | ✅ | ❌ |
| Llamar/WhatsApp/Navegar | ✅ | ✅ | ✅ |

### Cliente inactivo
- Estado del cliente se edita dentro del formulario de edición.
- La lista de clientes tiene filtro por estado (activo/inactivo).
- Clientes inactivos se pueden reactivar.
- Solo admin y admin_cobranza pueden cambiar estado.

### Editar cliente
- Botón "Editar" cambia la vista a modo edición inline.
- Todos los campos se vuelven editables en la misma pantalla.
- Botón "Guardar" / "Cancelar" al cambiar a modo edición.
- Estado del cliente (activo/inactivo) es uno de los campos editables.

### Estados del contrato
- **Activo**: cliente tiene servicio, cuotas se generan y se cobran.
- **Completado**: todas las cuotas pagadas (solo contratos 1-2 años, no indefinido).
  Se marca automáticamente cuando la última cuota se paga.
- **Cancelado**: cliente canceló el servicio. No aparece en la lista principal.
  Visible en sección "Contratos cancelados" (colapsable).

### Visualización de contratos
- Dos secciones: "Contratos activos" arriba, "Contratos cancelados" abajo (colapsable).
- Solo admin + admin_cobranza pueden cambiar estado.
- El contrato NO se puede editar (es inmutable). Solo cambiar estado.

### Cobrar cuotas (todos los roles)
- Tap individual en cuota pendiente → abre cobro directo.
- Long-press → multi-select con orden obligatorio → FAB "Cobrar N cuotas".
- Mismo patrón que ya está implementado.

### Nuevo contrato
- En desktop: panel lateral que se abre al lado.
- En mobile: push a pantalla completa.
- Se accede desde botón "Nuevo contrato" en el detalle del cliente.

### Historial de cambios (change log)
- Botón de historial (🕐) por sección: info del cliente, cada contrato,
  cada pago. Abre bottom sheet con timeline de cambios.
- Usa el widget HistorialCambiosWidget reutilizable.

### Change log automático
- Al crear cliente: se registra toda la info inicial.
- Al crear contrato: se registra toda la info del contrato + cuotas generadas.
- Al editar cualquier campo: se registra qué cambió, quién y cuándo.
- Triggers genéricos en Postgres ya capturan todo esto (migración 0047).
