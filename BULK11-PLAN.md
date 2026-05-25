# BULK 11 — UI/UX Refactor + Features Plan

Referencia persistente para el refactor de UI/UX y features del BULK 11.
Claude Code debe leer este archivo junto con CLAUDE.md y ROADMAP.md al
inicio de cada sesión.

---

## Design System

### Nombre del producto
**SITECSA CRM** — nombre oficial para branding (header, login, recibo,
installer, título de ventana).

### Tema visual
- **Estilo**: iOS-inspired — limpio, blanco prominente, bordes suaves.
- **Modo**: Solo light (sin dark mode).
- **Fondo principal**: blanco (#FFFFFF).
- **Fondo containers/sidebar**: gris claro iOS (#F2F2F7).
- **Color primario/accent**: azul celeste iOS (#007AFF) para acciones,
  selección, íconos activos, FABs, toggles, links.
- **Texto primario**: negro/gris oscuro (#1C1C1E).
- **Texto secundario**: gris medio (#8E8E93).
- **Error**: rojo iOS (#FF3B30).
- **Success**: verde iOS (#34C759).
- **Warning**: amber/naranja iOS (#FF9500).
- **Cards**: flat, sin sombra, borde 1px gris claro (#E5E5EA). iOS style puro.
- **Border radius**: 12-16px en cards, 8-10px en inputs, 20px en chips.
- **Sombras**: ninguna en cards. Solo en FAB y modals (elevation mínima).

### Sidebar / Navigation
- **Desktop (≥900px)**: NavigationRail fondo gris claro (#F2F2F7),
  íconos azul celeste cuando activos, gris cuando inactivos.
- **Mobile (<900px)**: Drawer fondo blanco, mismos colores de íconos.

---

## Configuración por tenant (Settings Panel)

### Categorías

```
/admin/settings
├── 📋 Empresa
│   ├── Nombre comercial, dirección, teléfono, RUC
│   ├── Logo (upload imagen → Storage)
│   └── Template de recibo (editor visual con preview)
│
├── 💰 Cobranza
│   ├── Días de gracia (int, default 5)
│   ├── Toggle: cobrador puede editar fecha de cobro
│   ├── Toggle: cobrador puede anular cobros
│   ├── Toggle: cobrador puede editar cobros post-registro
│   ├── Toggle: foto comprobante obligatoria
│   ├── Toggle: permitir pago parcial
│   ├── Toggle: permitir pago adelantado (multi-cuota)
│   ├── Métodos de pago habilitados (efectivo ✅, transferencia ☐, tarjeta ☐)
│   └── Cargo por reconexión (monto, 0 = deshabilitado)
│
├── 💲 Moneda
│   ├── Moneda principal (NIO/USD)
│   ├── Tasa de cambio actual
│   └── Histórico de tasas (tabla fecha + tasa, append-only)
│
├── 📄 Cuotas
│   ├── Toggle: admin puede crear cuotas manuales
│   ├── Toggle: admin puede modificar monto de cuota generada
│   └── Descuento pronto pago (% o monto fijo, 0 = deshabilitado)
│
└── 🧾 Recibos
    ├── Template visual con preview
    ├── Pie de recibo (texto libre)
    └── Formato de numeración
```

### Cómo se almacena
Tabla `settings` existente: `tenant_id + clave + valor (JSONB)`.
Cada toggle es una row: `clave='cobranza.cobrador_edita_fecha'`,
`valor='"true"'`. El provider `appSettingsProvider` ya lee de esta
tabla — extender con los nuevos campos.

---

## Decisiones operativas (respuestas de Rubén)

### Cobranza
- Fecha de cobro editable por cobrador SI el admin lo habilita (toggle).
- Cobrador puede anular cobros SI el admin lo habilita (toggle).
- Cobrador puede editar cobros SI el admin lo habilita (toggle).
- Sin ventana de tiempo para correcciones (siempre editable si habilitado).
- Recibo anulado queda en la BD marcado como anulado — data usable en
  reporte de anulaciones para auditoría.
- Foto comprobante siempre opcional, habilitable como obligatoria (toggle).

### Cobros y recibos
- Cobros históricos quedan asociados al cobrador original (auditoría).
- Cobrador desactivado NO puede acceder al tenant.
- Cuotas ordenadas por contrato (no mezcladas).
- NO se puede pagar cuotas de diferentes contratos en un solo cobro.
- SÍ se puede pagar múltiples cuotas del MISMO contrato en un solo cobro.
- Recibo global para pago multi-cuota (lista las N cuotas cubiertas).
- Recibo refleja de qué contrato es cada pago.

### Cuotas
- Admin puede crear cuotas manuales (toggle en settings).
- Admin puede modificar monto de cuota generada (toggle en settings).
- Admin puede anular cuota específica sin anular contrato.
- Cargo por reconexión configurable por admin (monto en settings).
- Descuento por pronto pago configurable (% o monto fijo en settings).

### Moneda
- Tasa de cambio actualizable por admin.
- Histórico de tasas: pagos pasados conservan la tasa del momento.
- Precio de planes configurable en NIO o USD.

### Cobrador UX
- Botón "Cómo llegar" abre Google Maps/Waze con geo del cliente.
- Registro de interacciones: visitas fallidas, notas de contacto.
- NO hay botón "Llamar" ni "WhatsApp" — solo mostrar info del cliente.
- Mensaje pre-armado de mora: feature futuro (no BULK 11).

### Reportes
- Reporte fiscal/contable (ingresos por mes).
- Reporte eficiencia por cobrador.
- Reporte clientes inactivos.
- Reporte de anulaciones (cobros/recibos anulados con motivo).
- Exportar a CSV/Excel en cada reporte.

### Seguridad
- Cobrador NO ve montos de otros cobradores (RLS).
- Admin VE geo + timestamp de cada cobro (auditoría, no visible al cobrador).
- Admin puede reasignar clientes individual o masivamente.

---

## Sprints por fase

### FASE A: Settings Panel (base para todo)
| Sprint | Tiempo | Qué |
|---|---|---|
| A1 | 3-4h | Settings UI refactor con categorías (tabs/accordion) |
| A2 | 2-3h | Logo upload a Storage + mostrar en recibo + shell |
| A3 | 3-4h | Recibo template editor con preview visual |

### FASE B: Cobranza flexible
| Sprint | Tiempo | Qué |
|---|---|---|
| B1 | 2-3h | Fecha de cobro editable (respeta toggle) |
| B2 | 2-3h | Anulación de cobros (respeta toggle, marca recibo) |
| B3 | 2-3h | Edición de cobros post-registro (respeta toggle) |
| B4 | 3-4h | Pago multi-cuota + recibo global |
| B5 | 2h | Métodos de pago configurables |

### FASE C: Cuotas y finanzas
| Sprint | Tiempo | Qué |
|---|---|---|
| C1 | 2h | Cuotas manuales |
| C2 | 1-2h | Editar monto de cuota generada |
| C3 | 2-3h | Cargo por reconexión automático |
| C4 | 2h | Descuento pronto pago |
| C5 | 2-3h | Tasa de cambio con histórico |

### FASE D: Cobrador UX
| Sprint | Tiempo | Qué |
|---|---|---|
| D1 | 2h | Registro de interacciones/visitas |
| D2 | 2h | Botón "Cómo llegar" (Google Maps/Waze) |
| D3 | 1-2h | Cuotas agrupadas por contrato |

### FASE E: Reportes avanzados
| Sprint | Tiempo | Qué |
|---|---|---|
| E1 | 2-3h | Reporte fiscal/contable PDF |
| E2 | 2h | Reporte eficiencia por cobrador PDF |
| E3 | 1-2h | Reporte clientes inactivos PDF |
| E4 | 2-3h | Reporte de anulaciones PDF |
| E5 | 2-3h | Exportar CSV/Excel |

### FASE F: UI polish
| Sprint | Tiempo | Qué |
|---|---|---|
| F1 | 2-3h | Design system documentado |
| F2 | 3-4h | Tema blanco + azul celeste iOS-style |
| F3 | 2-3h | Módulos template (patrón visual consistente) |
| F4 | 2h | Responsive polish (desktop grids + mobile full-width) |

**Total: 25 sprints, ~54-69h estimadas (3-4 sesiones).**
