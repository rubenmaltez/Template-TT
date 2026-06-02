# ESTADO-APP.md — Snapshot del estado de SITECSA CRM

> **Propósito**: foto del estado real de la app en un punto dado. Se lee
> JUNTO con `CLAUDE.md` al abrir una sesión nueva de Claude Code, para
> continuar exactamente desde acá sin re-descubrir el contexto.
>
> **Última actualización**: 2026-06-02 (commit `c6cbebd`, branch
> `claude/inspiring-dijkstra-wKs5h`). Audit integral post-snapshot (4 agentes:
> integridad DB, dinero, frontend, seguridad/impersonación) — **sin bugs
> nuevos**; 4 findings menores corregidos. Migración **0085**, schema **v16**.
> Ver §3 y REPORTE-SESION §3.
>
> Entre este snapshot y el anterior (0074/v15) hubo sesiones interinas con las
> migraciones 0075-0084: audit de planes (0076), código de contrato (0077),
> coherencia de tenant (0078/0082), layout + bloques de recibo (0079-0080),
> foto de comprobante (0081), blindaje de recalcular_cuota (0083) y pantallas
> admin opcionales (0084).
>
> El snapshot original lo generó un audit de 5 agentes; **los 6 findings MEDIUM
> ya fueron corregidos** (migraciones 0066-0068 + fixes Dart). Cuando se cierre
> un sprint que cambie el estado, **actualizar este archivo**.

---

## 1. Veredicto general

| Dimensión | Estado | Resumen |
|---|---|---|
| **Backend / DB** | 🟢 SÓLIDO | 85 migraciones secuenciales sin gaps, RLS completo, triggers coherentes, schema chain v16 consistente |
| **Dinero / contabilidad** | 🟢 SÓLIDO | Modelo de vuelto correcto y centralizado; recaudado reconcilia cross-pantalla; 10/10 invariantes en 0 (INV10 = coherencia de tenant) |
| **Frontend code quality** | 🟢 BUENO | 0 SQL incompatible con SQLite, 0 rutas rotas, 0 providers faltantes, stream lifecycle disciplinado |
| **Seguridad multi-tenant** | 🟢 SAFE | Aislamiento sólido; settings super-only ahora enforced server-side (0085), no solo en UI |
| **QA funcional** | 🟡 AMPLIA | Mayoría de flujos funcionales; 2 features son solo flags; multi-cuota limitado |
| **Tests automatizados** | 🔴 BAJO | Solo unit tests de funciones puras; 0 tests de repos de dinero, 0 integración, 0 widget |
| **CI/CD** | 🟢 NUEVO | CI creado (analyze + test + sql-compat) — correrá en cada push |

**Sin findings CRITICAL abiertos.** Los 2 bugs críticos de esta sesión
(vuelto inflaba recaudado; constraint `coherencia_moneda` rompía cobros NIO
con vuelto) están resueltos (migraciones 0061/0064/0065).

---

## 2. Métricas del codebase

| Métrica | Valor |
|---|---|
| Archivos Dart (`lib/`) | ~144 (~38k LOC) |
| Migraciones SQL | 85 (0001 → 0085) |
| Funciones server-side (RPC/triggers) | ~56 |
| Edge Functions (Deno) | 6 |
| Schema version (PowerSync) | v16 |
| Storage buckets | 4 (comprobantes-pago, fotos-clientes, logos-empresa, contratos-documentos) |
| Tests automatizados | 8 archivos (todos unit de funciones puras) |

---

## 3. Findings abiertos (prioridad para próximos sprints)

### ✅ RESUELTOS — audit integral post-snapshot (2026-06-02, commits c43957d→c6cbebd)

| ID | Cómo se resolvió |
|---|---|
| **#1 Settings super-only** (🟠 Media) | Migración 0085: las 4 claves que controla el super_admin (foto comprobante, foto obligatoria, pantalla pagos/notificaciones) pasan a `editable_por='super_admin'`; `settings_write_admin` endurecida (el admin ya no las escribe; el super sí, vía `super_admin_all` 0026) + `seed_settings_super_only` para tenants nuevos. Guard de pantalla en `/admin/pagos` y `/admin/notificaciones`. Antes el gate era solo client-side → un admin podía re-activarlas por PowerSync/REST. |
| **F3 Impersonación** (🟡 Baja) | `limpiarImpersonacionSiActiva()` (ahora pública) corre antes de los 2 `auth.signOut()` crudos (sync_gate, set_password). Antes un super_admin impersonando que cerraba sesión ahí re-logueaba en el tenant viejo. |
| **O1 Test dinero** (🟡 Baja) | INV10 (coherencia de tenant: `pagos`/`recibos`/`cargos_extra` deben tener el `tenant_id` de su padre) en `invariantes_dinero.sql`. Cierra el último gap de cobertura del test. |
| **#2 Recibo térmico** (🟡 Baja) | El bloque "Detalle de mora" ahora se imprime en Bluetooth (el caller `_imprimir` no pasaba `moraRows`; pantalla/PDF sí lo mostraban). |

*Documentados (cosméticos, no se tocan)*: **O2** centavo de redondeo en multi-cuota USD (dentro de tolerancia del invariante); **O3** detalle de mora multi-cuota asume un solo contrato (caso normal del producto).

### ✅ RESUELTOS — los 6 MEDIUM del audit (2026-05-28, commits 06b0135→0bb3254)

| ID | Cómo se resolvió |
|---|---|
| **M1-SEC** | Migración 0066: trigger `cobradores_freeze_rol` bloquea escalación a super_admin + mutación de rol/tenant_id por escritura directa de no-super_admins. |
| **M2-DB** | Migración 0067: policies UPDATE/DELETE para geo (admin puede editar/borrar — decisión del producto). |
| **M3-MONEY** | `pagos_repo`: registrarCobro/Multiple actualizan `cargos_neto` local en la transacción (vía `_deltaCargosExtra`, replica el trigger). Saldo offline correcto. |
| **M4-MONEY** | Opción B: bloquear editar pago con vuelto>0. UI (botón disabled + snackbar) + repo (guard que lanza excepción). |
| **M5-FE** | `_Lista` → StatefulWidget con stream en initState/didUpdateWidget. Cierra el item de backlog "watch inline en build()". |
| **M6-DB** | Migración 0068: cascada de reasignación consolidada en una función (incluye fotos_cliente). Trigger separado eliminado. |

### 🟢 LOW / NIT (abiertos)

- **L1**: "Pendiente de contrato" (precio×meses) vs "Saldo de cuotas" (suma per-cuota) son números legítimamente distintos pero un admin podría compararlos. Documentar la distinción en UI.
- **L2**: `_CuotaRow` (detalle contrato) muestra saldo sin `cargos_neto` (cosmético).
- **L3**: `actualizar_notificaciones_mora` calcula `monto_adeudado` sin `cargos_neto` (reporte mora levemente inexacto).
- **L4**: Cascadas de reasignación no se auditan individualmente (`pg_trigger_depth() < 2` las salta — por diseño, evita ruido).
- **Dead code (3 archivos)**: `lib/data/models/contrato.dart` (sigue sin instanciarse — el detalle/form usan maps crudos vía `contrato_providers`; además quedó **desactualizado** tras 0072-0074: le faltan `duracion_meses`, `fecha_primer_cobro`, `costo_instalacion`, `notas` — si se revive, completar antes), `lib/data/services/foto_cliente_service.dart` (superseded), `lib/features/admin/reportes/pdf/reporte_estado_cuenta_pdf.dart` (nunca cableado al menú).
- **NIT**: algunos StreamBuilder sin branch `hasError` explícito (seguros por `initialData`): `perfil_screen.dart:187`, tiles de `geografia_admin_screen.dart`.
- **clientes.foto_path**: columna legacy presente en Postgres + schema.dart pero sin uso (superseded por tabla `fotos_cliente`). Inofensiva.

---

## 4. Features: estado real por flag

### Funcionales ✅
Cobro single-cuota (con vuelto + USD), recibo (web PDF + Bluetooth térmico),
anular/recrear/editar pago, contratos + documento adjunto, cuotas multi-select,
visitas (Postgres, sync), fotos cliente (max 10), audit/historial completo
(create/update/delete), impersonation super_admin, 8 reportes PDF + 7 CSV,
dashboard KPIs, CRUD clientes/contratos/planes/cobradores, geografía,
settings, onboarding wizard.

### Solo flag — implementación pendiente 🔴
- **`cobranza.modo_ruta`** (ruta planificada vs libre): el setting existe pero
  el mapa SIEMPRE es modo libre. Ningún código fuera de settings lo lee.
- **`caja_chica.habilitada`** (migración 0063): flag + getter listos, pero
  CERO UI/tablas. Marcado "Feature en desarrollo". Togglearlo no hace nada aún.

### Parciales 🟡
- **Cobro multi-cuota**: monto read-only (solo saldo exacto) → sin pago parcial,
  sin vuelto, sin USD. Esas 3 cosas solo funcionan en single-cuota.
- **Contrato documento**: online-only (upload/ver requieren conexión). Acceptable
  por ser flujo admin de escritorio, no de campo.
- **Notificaciones mora**: bandeja read-only; envío es manual via WhatsApp/llamada.
- **"Reasignar cobrador"**: varios diálogos dicen "Cobradores → Reasignar" pero
  esa acción NO existe; la reasignación es vía el form de edición de cliente.
  (Copy engañoso — corregir.)

---

## 5. Cobertura de tests — gaps prioritizados

**Estado**: 8 archivos, todos unit de funciones puras
(`cobro_calculo`, `pago`, `formatters`, `validators`, `cobrador_helpers`,
`edge_functions`, `cuota_estado`, `error_log_entry`). **0 widget, 0 integración,
0 repos.**

Gaps por riesgo (dinero primero):
1. **P0** — `pagos_repo.registrarCobro` / `registrarCobroMultiple`: correlativo
   (server MAX + in-transaction), transiciones de estado de cuota, vuelto. Core
   del dinero, sin test.
2. **P0** — `pagos_repo.anularPago` / `recrearPago` / `editarPago`: restauración
   de estado, guard double-pay, audit rows.
3. **P1** — Lógica de orden consecutivo en multi-select (`cuotas_list_screen`).
4. **P1** — Auto-detección de cargos (C3 reconexión / C4 descuento) en `cobro_screen._cargar`.
5. **P1** — Edge Functions (rollback crear-tenant, ghost-user invitar-cobrador).
6. **P2** — Matriz de redirects del router (guards de rol, impersonation, onboarding).

**Mitigación actual**: `supabase/tests/invariantes_dinero.sql` (10 invariantes
contables, INV10 = coherencia de tenant) cubre la correctitud de la DATA aunque
no del CÓDIGO. Correr post-deploy.

---

## 6. Lo que se hizo en la sesión que generó este snapshot

**Sesión 2026-06-02 — Audit integral + fixes**: 4 agentes en paralelo auditaron
el trabajo post-snapshot (integridad DB↔schema↔sync, dinero/contabilidad,
correctness frontend, seguridad/impersonación). **Sin bugs reales nuevos.** Se
corrigieron 4 findings menores (ver §3): enforcement server-side de los settings
super-only (0085), limpieza de impersonación en los signOut crudos, INV10 en el
test de dinero, y el bloque de mora en el recibo térmico.

**Sesiones previas (grueso del snapshot):**

- Migración a per-user PowerSync DB, change log, UX sprint (sesiones previas).
- BULK 12: detalle de cliente unificado, detalle de contrato, fotos múltiples.
- Visitas migradas a Postgres (sync + audit).
- Documento del contrato (PDF/Word/imagen).
- **Fix crítico del vuelto**: `monto_cordobas`=aplicado, `vuelto_cordobas`=devuelto
  (siempre NIO), `monto_original`=entregado. Migraciones 0061/0064/0065.
- Audit completo (INSERT/UPDATE/DELETE) en 8 tablas. Migración 0062.
- Caja chica como feature flag. Migración 0063.
- **5 mejoras de calidad**: invariantes SQL, reglas de dinero en CLAUDE.md,
  tests de `CobroCalculo`/`Pago`, CI (analyze+test+sql-compat), refactor del
  god file `contrato_detail_screen` (1991→359 líneas en 4 part files).

---

## 7. Próximos pasos sugeridos (orden de ROI)

> Los 6 MEDIUM (M1-M6) ya están resueltos. Lo que queda:

1. **Tests de `pagos_repo`** (P0): el dinero merece tests de repo, no solo de la
   matemática pura. El gap más importante que queda.
2. **Decidir destino de los flags**: implementar o quitar `modo_ruta` y `caja_chica`
   (hoy prometen algo que no hacen).
3. **Limpieza**: borrar los 3 archivos dead code + corregir copy "Reasignar".
4. **Refactor god files** (no urgente): `reportes_admin_screen` y `cuotas_admin_screen`
   son los mejores candidatos (varios componentes independientes en un archivo).
5. **LOW/NIT** pendientes (sección 3): documentar distinción saldo vs pendiente,
   cargos_neto en mora report, etc.

---

## 8. Reglas para mantener este documento

- Actualizar la fecha + commit del header en cada cierre de sprint relevante.
- Mover findings resueltos de la sección 3 a un changelog corto.
- Si una feature pasa de flag a implementada, moverla en la sección 4.
- Cuando se agreguen tests, actualizar la sección 5.
- Este archivo NO reemplaza CLAUDE.md (que tiene las reglas/proceso). Es el
  COMPLEMENTO de estado: "dónde estamos parados hoy".
