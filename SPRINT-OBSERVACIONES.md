# SPRINT-OBSERVACIONES.md

Backlog de 9 observaciones de Rubén (2026-05-31). Se atacan **EN ORDEN**.
**Pull + testing al FINAL** de todo (no por ítem). Estado vivo acá.

| # | Ítem | Tipo | Estado |
|---|------|------|--------|
| 1 | Código en contratos (tipo código de cliente) | Feature | ⏳ esperando decisiones |
| 2 | TypeError filtro cliente/comunidad | Bug | ✅ |
| 3 | Reportes filtrados por fecha de cobro (rango) | Bug/spec | ⬜ |
| 4 | Fecha de cobro en el log de recibo/pago | Curaduría | ⬜ |
| 5 | Anular pago: sacar botón "recrear" + prompt + log completo | Bug+UX (plata) | ⬜ |
| 6 | Multi-pago: selector USD/Córdoba | Falta feature | ⬜ |
| 7 | Cambio de usuario: data vieja / settings vacío (F5) | Bug estado | ⬜ |
| 8 | Rework settings + diseñador visual de recibo | Feature grande | ⬜ |
| 9 | Interfaz super_admin (administrar/entrar a tenants) | Feature grande | ⬜ |

## Notas / decisiones por ítem

### #1 — Código de contrato
- Cliente hoy: `codigo` MANUAL, uppercase, único por tenant (case-insensitive),
  inmutable una vez guardado (trigger 0071), super_admin puede cambiarlo, opcional.
- Pendiente: ¿manual (igual cliente) o auto-generado? ¿dónde se muestra?

### #2 — TypeError filtros ✅
- Causa: `ps.db.watch` devuelve filas `Row`; `firstWhere(orElse: () => <Map literal>)`
  choca contra el tipo `Row Function()?` (chequeo covariante en runtime). Solo
  explotaba al ELEGIR un filtro (si no, el firstWhere no corría → latente).
- Fix: reemplazado por `.where()` + `isNotEmpty`/`first` en 4 sitios:
  `clientes_admin_screen.dart` (cobrador + comunidad), `clientes_list_screen.dart`
  (comunidad), `contrato_detail_cuotas.dart` (primera pendiente).
