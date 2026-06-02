# ESTADO-APP.md — Snapshot del estado de SITECSA CRM (Cobranza ISP)

> **Propósito**: foto del estado real de la app en un punto dado. Se lee
> JUNTO con `CLAUDE.md` al abrir una sesión nueva de Claude Code, para
> continuar exactamente desde acá sin re-descubrir el contexto.
>
> **Última actualización**: 2026-06-02 (commit `c34479d`, branch
> `claude/inspiring-dijkstra-wKs5h`). **Audit EXHAUSTIVO TOTAL** de toda la app
> (5 agentes en paralelo: integridad DB, dinero, correctness frontend,
> cobertura funcional admin-side, cobertura funcional cobrador + seguridad).
> Migración **0087**, schema **v16**. Resultado: **0 findings CRITICAL/HIGH**;
> 1 bug de dinero (F1) y 1 de seguridad (S4) corregidos; resto LOW → backlog.
> Ver §3.

---

## 1. Veredicto general (audit total 2026-06-02)

| Dimensión | Estado | Resumen |
|---|---|---|
| **Backend / DB** | 🟢 SÓLIDO | 87 migraciones secuenciales sin gaps, schema↔Postgres↔sync coherentes (17 tablas), RLS multi-tenant completa + super_admin bypass, triggers (audit/dinero/coherencia/inmutabilidad) correctos, timezone server 0087. 0 CRITICAL/HIGH, 4 LOW. |
| **Dinero / contabilidad** | 🟢 SÓLIDO | Matemática del vuelto verificada a mano (NIO/USD, single/multi, arqueo USD). recaudado/total-fijo/trigger-mirror/anular/correlativo correctos. 10/10 invariantes. **F1 (saldo sin cargos_neto en /admin/cuotas) corregido.** |
| **Frontend correctness** | 🟢 LIMPIO | 0 SQL incompatible con SQLite, 0 `date('now')` pelados (norma TZ 100% en 30+ queries), 0 rutas rotas, 0 stream-lifecycle latentes, guards de rol coherentes. 1 archivo dead code. |
| **Seguridad multi-tenant** | 🟢 SAFE | Aislamiento RLS sólido; super-only enforced server-side (0085/0086); impersonación con defensa en capas (guards cliente + `validar_tenant_coherente` server); 6 edge functions robustas. 5 LOW (hardening), S4 corregido. |
| **QA funcional** | 🟢 AMPLIA | Todos los roles/módulos/tabs mapeados y funcionales con data real. ~5 features son flag/stub (documentadas). Reportes (8 PDF + 8 CSV + arqueo) completos. |
| **Tests automatizados** | 🔴 BAJO | Solo unit de funciones puras; 0 tests de repos de dinero, 0 integración, 0 widget. |

**Sin findings CRITICAL/HIGH abiertos.** El audit total no encontró bugs graves;
la app está en estado sólido y consistente end-to-end.

---

## 2. Métricas del codebase

| Métrica | Valor |
|---|---|
| Archivos Dart (`lib/`) | ~145 (~38k LOC) |
| Migraciones SQL | 87 (0001 → 0087) |
| Funciones server-side (RPC/triggers) | ~58 |
| Edge Functions (Deno) | 6 (`_shared/` con passwords/auth_errors/response) |
| Schema version (PowerSync) | v16 |
| Tablas sincronizadas | 17 (operativas + globales) |
| Storage buckets | comprobantes-pago, fotos-clientes, logos-empresa, contratos-documentos, geografia |
| Tests automatizados | 8 archivos (unit puros) + `invariantes_dinero.sql` (10 invariantes) |

---

## 3. Findings del audit total (2026-06-02)

### ✅ CORREGIDOS en este audit

| ID | Sev | Qué era / cómo se resolvió |
|---|---|---|
| **F1** | 🟠 ALTA (dinero) | `/admin/cuotas` (`cuotas_admin_screen.dart:779`) mostraba `saldo = monto − pagado`, **omitiendo `cargos_neto`** → divergía de las otras ~6 pantallas (viola regla #10). Ej: cuota 500 + reconexión 100, paga 300 → mostraba 200 en vez de 300. Fix: `saldo = monto + cargos_neto − pagado` (el dato ya venía en el SELECT). |
| **S4** | 🟡 LOW (seguridad) | `historial._anular` no chequeaba impersonación (a diferencia de cobro/cargo/visita). Se agregó el guard `estaImpersonandoProvider` por consistencia. (Bajo impacto: anular es UPDATE benigno que no mueve tenant.) |

### 🟢 LOW / backlog (no bloqueantes, del audit total)

**DB:**
- **Storage RLS acopla `.jpg`** (`0022`): la policy extrae `pago_id` con `replace(...,'.jpg','')`. Hoy OK (cliente sube jpg). Latente si se habilita png/webp → generalizar a `regexp_replace(...,'\.[^.]+$','')`.
- **`super_admin_all` no es automático** para tablas nuevas (el `do$$` de 0026 enumera tablas fijas). fotos_cliente/visitas lo agregaron a mano OK, pero es foot-gun → checklist al crear tabla operativa.
- **Dead code de migración**: `generar_cuotas_mes` de 0054 superado por 0074 (inocuo).
- **Doc estados de cuota**: el CHECK de DB tiene 4 (`pendiente/parcial/pagada/anulada`); `en_gracia`/`vencida` son derivados en el cliente. Aclarado en CLAUDE.md.

**Dinero:**
- **F2 (media)**: KPIs de cobros del dashboard usan `date(fecha_pago)` vs `DateTime.now()` local, mientras mora usa `date('now','-6 hours')`. Coincide en browser Nicaragua (supuesto operativo); no toca la matemática del dinero. Unificar reloj a futuro.
- **Gap de invariantes**: las reglas #5 (total fijo=precio×meses) y #6 (indefinidos sin pendiente) viven solo en Dart, sin invariante SQL. Sugerir invariante de `duracion_meses` coherente + `total≥recaudado`.

**Seguridad (hardening, ya en backlog):**
- S2: `cambiar-email` no escribe audit del signout-fallido como sí hace `forzar-password` (inconsistencia trivial).
- S3: `reenviar-invitacion` ventana sin lock (solo explotable con super_admins concurrentes; Rubén es 1).
- S5: ghost user en `invitar-cobrador` (ya mitigado con cleanup).

**Frontend:**
- **Dead code real (1)**: `lib/features/shared/widgets/app_version_label.dart` (`AppVersionLabel`, 0 referencias tras quitar el drawer del cobrador). Decidir: borrar o re-cablear.
- 2 `ps.db.watch` inline en `geo_picker.dart:109,138` — by-design (StatefulWidget no-Consumer, params en cascada). Anti-patrón controlado.

### Histórico (resuelto en sesiones previas)
- Audit integral 2026-06-02 previo (commits c43957d→c6cbebd): super-only enforce (0085), impersonación en signOut, INV10, mora térmica.
- 6 MEDIUM (2026-05-28): freeze rol (0066), geo RLS (0067), cargos_neto local (M3), bloquear editar pago con vuelto (M4), watch-inline (M5), cascada reasignación (0068).
- Fix crítico del vuelto (0061/0064/0065): monto_cordobas=aplicado, vuelto siempre NIO.

---

## 4. Cobertura funcional por rol (estado real)

### super_admin (`/super/*`) — ✅ completo
Lista de tenants, crear ISP (con/sin email), detalle tenant (toggle módulos, miembros),
acciones por miembro (forzar/reset password, cambiar email/rol, activar/desactivar,
eliminar, reenviar invitación — todas con guardas), `/super/logs` (viewer error_logs),
**impersonación** (entrar a un tenant → AdminShell con su data + banner ámbar + acciones
de campo bloqueadas + audit start/end). Sin email es el path operacional (Resend sandbox).

### admin (`/admin/*`) — ✅ completo
Dashboard (KPIs + sparkline), clientes (CRUD + búsqueda por código-contrato + detalle 360
+ asignación masiva de cobrador), contratos (lista + detalle financiero + form con **código
obligatorio**), `/admin/cobros` (vista de cobros del admin con filtros cobrador/zona, NUEVO),
`/admin/cuotas`, pagos* + notificaciones* (gated por setting super-only), reportes, mapa
(estado + satélite + filtros admin), settings (5 tabs), cobradores, planes, geografía, audit,
onboarding. (*= visibles solo si el super lo habilita.)

### admin_cobranza — ✅ subconjunto (router `soloAdmin`)
VE: dashboard, clientes (+detalle), Cobros, contratos, reportes, mapa. Puede registrar
visitas, anular pagos, cambiar estado de contrato, editar fotos. NO accede: cobradores,
planes, geografía, audit, settings, pantallas Pagos/Notificaciones gateadas.

### cobrador (`/`, móvil-first, bottom-nav) — ✅ completo
Cobros (tabs Por cliente/Por cobrar + 5 filtros estado + multi-select consecutivo),
Clientes (búsqueda multi-campo + filtros + contador contratos), Mapa (estado + satélite),
Perfil (impresora BT, sync, fotos pendientes, historial, cambiar pass). **Flujo de cobro**:
monto, método (efectivo/transf/depósito/tarjeta según settings), vuelto, USD (toggle+tasa
snapshot), foto comprobante (gated), descuento/cargo (super-only), reconexión auto
(super-only), multi-cuota (cada cuota completa, vuelto al último), pago parcial. Recibo
(pantalla + PDF web + térmica BT + bloques configurables + mora). Invariantes de dinero
correctos + correlativo server-MAX + denormalización en INSERT.

### Reportes (`/admin/reportes`) — ✅ completo
8 PDF (cobros, mora, por cobrador, estado de clientes, fiscal, eficiencia, inactivos,
anulaciones) + 8 CSV (los mismos + arqueo) + **arqueo/cierre por cobrador** (efectivo por
moneda US$/C$, vuelto, electrónico, equivalente a tasa). Date picker compacto con presets.
Matemática verificada: reportes de saldo usan `cargos_neto`; reportes de caja usan `pagos`.

### Settings (`/admin/settings`) — ✅ completo
Tabs **Empresa · Cobranza · Pagos · Recibos** + **Avanzado** (super-only). Recibos = editor
visual de bloques (drag-reorder + visible/tamaño + preview en vivo). Avanzado: foto-comprobante,
pantallas opcionales, **descuentos**, **reconexión** (todos super-only, gateados por tenant).

---

## 4b. Features flag / stub / NO implementadas

- 🔴 **`cobranza.modo_ruta`** (ruta planificada vs libre): setting huérfano, 0 usos, sin getter. Mapa siempre modo libre. Oculto.
- 🔴 **`caja_chica.habilitada`**: feature en desarrollo (tabla + UI pendientes). Oculto.
- 🔴 **`cobranza.recrear_pago_anulado`**: feature eliminada (anular es void puro). Seed huérfano oculto.
- 🟡 **Geo del cobro**: `GpsService` removido — el cobro guarda lat/lng null.
- 🟡 **Change-log de geografía**: `departamentos/municipios/comunidades` globales sin tenant_id → el trigger genérico no aplica. Pendiente conocido.
- 🟡 **Notificaciones de mora**: bandeja read-only; el envío al cliente es manual (WhatsApp/llamada), no desde la UI.

---

## 5. Cobertura de tests — gaps prioritizados

8 archivos unit puros (`cobro_calculo`, `pago`, `formatters`, `validators`, `cobrador_helpers`,
`edge_functions`, `cuota_estado`, `error_log_entry`). **0 widget, 0 integración, 0 repos.**

Gaps por riesgo (dinero primero):
1. **P0** — `pagos_repo.registrarCobro` / `Multiple` / `anular` / `editar` (correlativo, estado, vuelto, cargos_neto). Core del dinero, sin test de repo.
2. **P1** — orden consecutivo multi-select; auto-detección de cargos; Edge Functions (rollback/ghost-user).
3. **P1** — invariantes SQL de regla #5/#6 (total fijo) — gap detectado en el audit.
4. **P2** — matriz de redirects del router.

**Mitigación**: `invariantes_dinero.sql` (10 invariantes) cubre la DATA, no el CÓDIGO. Correr post-deploy.

---

## 6. Sesión que generó este snapshot (2026-06-02)

Sesión larga con: audit integral + 4 fixes (super-only enforce 0085, impersonación signOut,
INV10, mora térmica) · rediseño del cobrador a bottom-nav · fix sync `notificaciones_mora` ·
filtros de cuotas a día local · historial de auditoría oculto al cobrador · descuentos +
reconexión → super-only (0086) · clientes (contador + búsqueda por código de contrato) ·
mapa (estado + satélite + filtros admin) · código de contrato obligatorio · date picker
compacto · vista Cobros del admin · **timezone Nicaragua end-to-end** (cliente `-6h` + server
0087) · y este **audit exhaustivo total** (5 agentes) con F1/S4 corregidos.

---

## 7. Próximos pasos sugeridos (orden de ROI)

1. **Tests de `pagos_repo`** (P0): el gap más importante — el dinero merece tests de repo.
2. **Decidir destino de los flags**: implementar o quitar `modo_ruta` y `caja_chica`.
3. **Limpieza**: decidir `app_version_label.dart` (borrar/cablear); dead code de migración 0054.
4. **Hardening de backlog**: generalizar `.jpg` en storage RLS; checklist `super_admin_all`; invariante SQL de regla #5/#6; unificar reloj del dashboard (F2).
5. **Geo del cobro** (si se quiere): re-introducir captura de lat/lng en el cobro.

---

## 8. Reglas para mantener este documento

- Actualizar fecha + commit del header en cada cierre de sprint relevante.
- Mover findings resueltos a un changelog corto; los nuevos a §3.
- Si una feature pasa de flag a implementada, moverla en §4/§4b.
- Cuando se agreguen tests, actualizar §5.
- NO reemplaza CLAUDE.md (reglas/proceso). Es el COMPLEMENTO de estado.
