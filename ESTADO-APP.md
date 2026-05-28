# ESTADO-APP.md — Snapshot del estado de SITECSA CRM

> **Propósito**: foto del estado real de la app en un punto dado. Se lee
> JUNTO con `CLAUDE.md` al abrir una sesión nueva de Claude Code, para
> continuar exactamente desde acá sin re-descubrir el contexto.
>
> **Última actualización**: 2026-05-28 (commit `8b241f0`, branch
> `claude/powersync-sdk-setup-KZF1R`).
>
> Generado por un audit exhaustivo de 5 agentes en paralelo (backend/DB,
> dinero/contabilidad, frontend code quality, QA funcional por rol,
> seguridad). Cuando se cierre un sprint que cambie el estado, **actualizar
> este archivo**.

---

## 1. Veredicto general

| Dimensión | Estado | Resumen |
|---|---|---|
| **Backend / DB** | 🟢 SÓLIDO | 65 migraciones secuenciales sin gaps, RLS completo, triggers coherentes, schema chain v10 consistente |
| **Dinero / contabilidad** | 🟢 SÓLIDO | Modelo de vuelto correcto y centralizado; recaudado reconcilia cross-pantalla; 9/9 invariantes en 0 |
| **Frontend code quality** | 🟢 BUENO | 0 SQL incompatible con SQLite, 0 rutas rotas, 0 providers faltantes, stream lifecycle disciplinado |
| **Seguridad multi-tenant** | 🟢 SAFE | Aislamiento sólido; 1 vector de escalación in-tenant a endurecer (M1-SEC) |
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
| Archivos Dart (`lib/`) | ~131 (~35k LOC) |
| Migraciones SQL | 65 (0001 → 0065) |
| Funciones server-side (RPC/triggers) | ~51 |
| Edge Functions (Deno) | 6 |
| Schema version (PowerSync) | v10 |
| Storage buckets | 4 (comprobantes-pago, fotos-clientes, logos-empresa, contratos-documentos) |
| Tests automatizados | 8 archivos (todos unit de funciones puras) |

---

## 3. Findings abiertos (prioridad para próximos sprints)

### 🟡 MEDIUM (atacar pronto)

| ID | Área | Archivo | Problema |
|---|---|---|---|
| **M1-SEC** | Seguridad | `cobradores` (RLS 0013/0026) | Falta trigger que congele `rol`. Un admin podría auto-escalar a `super_admin` vía REST directo (`UPDATE cobradores SET rol='super_admin'`). La app usa RPC (seguro), pero RLS no lo previene. Fix: trigger `BEFORE UPDATE/INSERT` que rechace `rol='super_admin'` y mutación de `rol`/`tenant_id` salvo `is_super_admin()`. |
| **M2-DB** | Backend | geo tables (0003/0016) | `departamentos/municipios/comunidades` sin policy UPDATE/DELETE. Si `/admin/geografia` expone editar/borrar, falla silenciosamente. Verificar UI y agregar policies. |
| **M3-MONEY** | Dinero | `pagos_repo.dart:206`, `cobro_screen.dart:177` | `cargos_neto` no se actualiza en SQLite local al aplicar cargo offline (solo lo hace el trigger Postgres al sync). Saldo en lista clientes/dashboard/mora queda desfasado hasta sincronizar. Transitorio, no corrompe datos. |
| **M4-MONEY** | Dinero | `pagos_repo.dart:436`, `pagos_admin_screen.dart:405` | `editarPago` no recalcula `vuelto_cordobas` ni respeta el invariante de moneda. Editar un pago con vuelto rompe INV (visualmente); recaudado sigue OK. |
| **M5-FE** | Frontend | `clientes_admin_screen.dart:582` | `_Lista` llama `ps.db.watch()` inline en `build()` (anti-patrón). Funciona por el cache de PowerSync, pero re-suscribe en cada rebuild. Único callsite vivo del anti-patrón. Fix: StatefulWidget + `late Stream` en initState. |
| **M6-DB** | Backend | `clientes` (0020 + 0055) | Dos triggers de cascada de reasignación de cobrador independientes (uno → contratos/cuotas/notif/cargos, otro → fotos). Riesgo de desincronización si se edita uno sin el otro. |

### 🟢 LOW / NIT

- **L1**: "Pendiente de contrato" (precio×meses) vs "Saldo de cuotas" (suma per-cuota) son números legítimamente distintos pero un admin podría compararlos. Documentar la distinción en UI.
- **L2**: `_CuotaRow` (detalle contrato) muestra saldo sin `cargos_neto` (cosmético).
- **L3**: `actualizar_notificaciones_mora` calcula `monto_adeudado` sin `cargos_neto` (reporte mora levemente inexacto).
- **L4**: Cascadas de reasignación no se auditan individualmente (`pg_trigger_depth() < 2` las salta — por diseño, evita ruido).
- **Dead code (3 archivos)**: `lib/data/models/contrato.dart` (nunca instanciado), `lib/data/services/foto_cliente_service.dart` (superseded), `lib/features/admin/reportes/pdf/reporte_estado_cuenta_pdf.dart` (nunca cableado al menú).
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

**Mitigación actual**: `supabase/tests/invariantes_dinero.sql` (9 invariantes
contables) cubre la correctitud de la DATA aunque no del CÓDIGO. Correr post-deploy.

---

## 6. Lo que se hizo en la sesión que generó este snapshot

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

1. **M1-SEC**: trigger de congelamiento de `rol` en `cobradores` (cierra el único
   vector de escalación de privilegios).
2. **Tests de `pagos_repo`** (P0): el dinero merece tests de repo, no solo de la
   matemática pura.
3. **M3/M4-MONEY**: cargos_neto local offline + editarPago con vuelto.
4. **Decidir destino de los flags**: implementar o quitar `modo_ruta` y `caja_chica`
   (hoy prometen algo que no hacen).
5. **M5-FE**: arreglar el último `watch`-in-`build` (`_Lista`).
6. **Limpieza**: borrar los 3 archivos dead code + corregir copy "Reasignar".
7. **Refactor god files** (no urgente): `reportes_admin_screen` y `cuotas_admin_screen`
   son los mejores candidatos (varios componentes independientes en un archivo).

---

## 8. Reglas para mantener este documento

- Actualizar la fecha + commit del header en cada cierre de sprint relevante.
- Mover findings resueltos de la sección 3 a un changelog corto.
- Si una feature pasa de flag a implementada, moverla en la sección 4.
- Cuando se agreguen tests, actualizar la sección 5.
- Este archivo NO reemplaza CLAUDE.md (que tiene las reglas/proceso). Es el
  COMPLEMENTO de estado: "dónde estamos parados hoy".
