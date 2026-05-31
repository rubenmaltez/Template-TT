# SPRINT-OBSERVACIONES.md

Backlog de 9 observaciones de Rubén (2026-05-31). Se atacan **EN ORDEN**.
**Pull + testing al FINAL** de todo (no por ítem). Estado vivo acá.

| # | Ítem | Tipo | Estado |
|---|------|------|--------|
| 1 | Código en contratos (tipo código de cliente) | Feature | ✅ |
| 2 | TypeError filtro cliente/comunidad | Bug | ✅ |
| 3 | Reportes filtrados por fecha de cobro (rango) | Bug/spec | ✅ audit OK |
| 4 | Fecha de cobro en el log de recibo/pago | Curaduría | ✅ |
| 5 | Anular pago: sacar botón "recrear" + prompt + log completo | Bug+UX (plata) | ✅ |
| 6 | Multi-pago: selector USD/Córdoba | Falta feature | ⬜ |
| 7 | Cambio de usuario: data vieja / settings vacío (F5) | Bug estado | ⬜ |
| 8 | Rework settings + diseñador visual de recibo | Feature grande | ⬜ |
| 9 | Interfaz super_admin (administrar/entrar a tenants) | Feature grande | ⬜ |

## Notas / decisiones por ítem

### #1 — Código de contrato ✅
- Decisión: MANUAL igual que cliente (OPCIONAL, uppercase, único por tenant,
  inmutable, super lo cambia). Visible en detalle + lista/tarjeta + auditoría
  (NO en recibo).
- Hecho: migración 0077 (columna + índice único `contratos_codigo_tenant_uq` +
  trigger inmutabilidad), schema.dart + `_schemaVersion` 16, form (campo +
  dup-check + INSERT/UPDATE), detalle header, 2 tarjetas (admin + cliente),
  curaduría (visibles + catálogo).
- ⚠️ DEPLOY: correr 0077 + REDEPLOY sync rules (contratos usa SELECT *) +
  schema v16 recrea las DBs locales.

### #3 — Reportes por fecha de cobro (rango)
- Hoy: reportes de cobros clavados a `date('now','start of month')`. Sin rango.
- Decisión: selector GLOBAL con presets (Este mes / Mes pasado / Personalizado),
  aplica SOLO a reportes descargables (PDF/CSV); las tarjetas en pantalla quedan
  en 'mes actual'. Default 'Este mes' (no cambia lo actual).
- Reportes afectados (filtran `fecha_pago`): cobros, por_cobrador, anulaciones,
  fiscal, eficiencia, CSV. NO: mora / inactivos / estado de clientes (son foto).
- Próximo: StateProvider de rango + selector UI (en la pantalla de reportes) +
  threading desde/hasta en las queries (reemplazar `start of month` por `BETWEEN`).

### #2 — TypeError filtros ✅
- Causa: `ps.db.watch` devuelve filas `Row`; `firstWhere(orElse: () => <Map literal>)`
  choca contra el tipo `Row Function()?` (chequeo covariante en runtime). Solo
  explotaba al ELEGIR un filtro (si no, el firstWhere no corría → latente).
- Fix: reemplazado por `.where()` + `isNotEmpty`/`first` en 4 sitios:
  `clientes_admin_screen.dart` (cobrador + comunidad), `clientes_list_screen.dart`
  (comunidad), `contrato_detail_cuotas.dart` (primera pendiente).

### #5 — Anular pago ✅
- Decisión (Rubén): **Opción 3** — anular = void puro. La cuota vuelve a
  pendiente, el recibo queda inválido, NO se recrea. Para corregir un cobro:
  anular + recobrar a mano desde la cuota. Audit: **completo (recibo + labels)**.
- Hecho (3 commits):
  - **A) Sacar "recrear"**: elimina `recrearPago()` (pagos_repo) + botones y
    handlers `_recrear` (pagos_admin_screen, contrato_detail_pagos) + getter
    `recrearPagoAnulado` (settings_repo). El setting `cobranza.recrear_pago_anulado`
    queda orphaned en DB (seed 0045/0051) y se oculta vía `_hidden` del settings
    screen (patrón del repo: ocultar, no migrar).
  - **B) Prompt**: el dialog de anular ahora guía "Para volver a cobrar,
    registrá el cobro de nuevo desde la cuota" (los 2 dialogs).
  - **C) Log completo**: `HistorialCuotaWidget` ahora surfacea los eventos de
    `recibos` (emitido / anulado) en el timeline, vinculados por el `pago_id`
    del snapshot JSON (robusto al filtrado de sync de recibos anulados).
    `_labelFor` gana `case 'recibos'` (Recibo emitido/anulado/eliminado/
    actualizado). Fix de ruido: omitir `reimpresiones: 0` en el snapshot de
    creación. Al anular se ve: **Pago anulado · Recibo anulado · Cuota
    actualizada (Pagada → Pendiente)**.
- Nota de arquitectura: el recibo es nieto de la cuota → extiende la regla de
  profundidad. Documentado en CLAUDE.md como excepción única (hoja 1:1 del
  pago, sin hijas, parte del rastro de dinero).
- Sin migración ni redeploy de sync rules (no toca schema). Testing al final.
