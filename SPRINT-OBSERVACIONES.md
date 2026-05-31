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
| 6 | Multi-pago: selector USD/Córdoba | Falta feature | ✅ |
| 7 | Cambio de usuario: data vieja / settings vacío (F5) | Bug estado | ✅ |
| 8 | Rework settings + diseñador visual de recibo | Feature grande | ✅ |
| 9 | Interfaz super_admin (administrar/entrar a tenants) | Feature grande | ✅ |

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
- **Post-audit (3 agentes: Code/QA/UX):**
  - Fix: el dialog de anular del COBRADOR (`historial_screen.dart`) también
    se actualizó con la guía (Part B era 2/3).
  - Fix: corregido un comentario engañoso — el cobrador NO sincroniza
    `audit_log` (solo admin/admin_cobranza/impersonation), así que el timeline
    de recibos aplica a esos roles; para el cobrador el widget muestra "Sin
    movimientos" igual que antes.
  - Fix: `ORDER BY` con desempate por tabla → orden causal fijo
    pago→recibo→cuota.
  - UX-C: el card "Recibo anulado" ahora muestra el número en el subtítulo
    (vía helper `auditSnapshotField`; el número no cambia al anular y no salía
    en el diff).
  - Decisión: el historial del ícono 🕐 en `/admin/pagos` queda solo-pago (no
    recibo); el log completo con recibo vive en el timeline de la cuota.
  - Backlog (no bloquea): copy de anular duplicada en 3 archivos;
    `auditDetectarAccion` usa `==1` y no `==true` (hardening futuro).

### #6 — Multi-pago selector USD/Córdoba ✅
- Hallazgo: el backend YA soportaba multi+USD (`registrarCobroMultiple` persiste
  moneda/monto_original/tasa por pago); el sprint BULK 11 solo había OCULTO el
  toggle en multi-cuota (`!_esMultiCuota` en cobro_screen) con un comentario
  desactualizado ("requiere tasa por cuota" — falso, una transacción usa una
  sola tasa).
- Decisión (Rubén): enfoque robusto — des-gatear + extraer math + tests.
- Hecho:
  - Extraída la distribución multi-cuota a `CobroCalculo.distribuirMulti` (pura):
    saldos → montos aplicados (a caja) + montos en moneda original por fila +
    vuelto (en NIO, al último pago). `_confirmar` ahora la consume.
  - Des-gateado el `_MonedaToggle` (visible en single y multi si `usdHabilitado`).
  - Tests nuevos en `cobro_calculo_test.dart`: multi NIO/USD, con y sin vuelto,
    invariante `monto_original*tasa ≈ monto_cordobas + vuelto` por pago,
    recaudado = Σ saldos (sin vuelto).
- Invariantes de dinero verificados a mano + en tests. Sin migración ni sync
  rules (no toca schema).
- **Post-audit (2 agentes: math + downstream):**
  - Math: MERGEABLE sin blockers. El auditor portó `distribuirMulti` a JS y
    corrió 40+ asserts con Node (0 fallas). Invariantes + equivalencia con la
    lógica vieja + tests confirmados.
  - Downstream: plata SEGURA — toda agregación de recaudado/reportes/dashboard
    suma `monto_cordobas` (siempre NIO), nunca `monto_original`; cero mezcla
    USD↔NIO.
  - Fix aplicado: el recibo de cobro MÚLTIPLE (pantalla + PDF) no mostraba el
    monto en USD ni la tasa (solo córdobas), a diferencia del recibo single.
    Replicado el patrón: línea "Recibido US$X (tasa Y)" + "PAGADO US$X = C$Y"
    cuando moneda=USD (X = Σ monto_original del grupo).
  - Backlog cerrado (ex-pendiente, ahora hecho — "sin backlog"):
    - (a) **#6a** Impresión Bluetooth de cobro múltiple: nuevo
      `_generarBytesMulti` en `impresora_service_io.dart` itera las N cuotas
      (línea por cuota + totales del grupo + USD), igual que pantalla/PDF.
      `imprimir` rutea por `multiRecibos`; recibo_screen lo pasa.
    - (b) **#6b** Divergencia de tasa: el preview ("Equivalente") y `esCompleto`
      ahora usan `tasaEfectiva = _tasaSnapshot ?? settings.tasaUsd` (la MISMA
      que `_confirmar`), no la tasa live. Sin divergencia si la tasa cambia
      por sync entre elegir USD y confirmar.

### #7 — Data vieja / settings vacío al cambiar de usuario ✅
- Causa raíz: `onDatabaseSwitched` (main.dart) invalidaba una lista HARDCODEADA
  de 5 providers, pero hay ~14 providers GLOBALES bound a `ps.db`. Los que
  faltaban (settings, clientes, cuotas, rol, KPIs dashboard, impersonation)
  quedaban con el stream de la DB del usuario anterior (cerrada) → data vieja /
  settings vacío hasta el F5 (que recrea el container desde cero).
- Decisión (Rubén): enfoque epoch-based (dependencia), no allowlist manual.
- Hecho:
  - Nuevo `dbEpochProvider` (StateProvider<int>). `onDatabaseSwitched` lo bumpea
    (1 línea) en vez de la lista de `invalidate()`.
  - Los 14 providers globales db-bound hacen `ref.watch(dbEpochProvider)` como
    1ª línea → se recrean por dependencia al cambiar de DB: cobradorActual,
    moraCount, syncStatus, impersonatedTenantId, los 4 KPIs del dashboard,
    settingsMap, clientesAsignados, cuotasCobrables, _rolUsuario,
    empresaNombre, empresaNombreRowExists.
  - Nota: a los KPIs `operativo`/`distribucion` (que usan
    `appSettings.select(diasGracia)`) se les puso el watch explícito igual,
    porque `.select` NO recrearía si el valor coincide entre usuarios.
  - Derivados (tenantId, appSettings, logoEmpresaUrl) y autoDispose/family se
    recrean solos. super_admin/error_logs son online (Supabase), no aplican.
  - Contrato documentado en `db_epoch_provider.dart` para no re-introducir el
    bug: todo provider global nuevo que lea ps.db debe observar el epoch.
- Sin migración ni sync rules. Audit pendiente.

### Audit integral final (pre-pull) ✅
Dos agentes en paralelo (correctness/regresión full-codebase + migraciones/DB).
**Veredicto: LISTO para pull + testing, sin blockers.** Highlights verificados:
- SQL: 0 hits de sintaxis Postgres-only en `lib/` (FILTER/ILIKE/::casts/ANY/ARRAY).
- #7 epoch: los 13 providers globales db-bound observan el epoch; ordering
  correcto (bump después de reasignar `ps.db`); main.dart sin imports colgados.
- #8 render: plata intacta en los 6 paths; saneo de `reciboOrdenPie` robusto;
  el sample row del preview tiene los 21 campos que lee `ReciboTicket`.
- #9 guards: sin bypass; `confirmarSignOut` no se rompe (try/catch best-effort).
- Migraciones 0078/0079: seguras, idempotentes, no rompen inserts legítimos,
  claves Dart == seed, defaults cubren tenants nuevos.

4 findings (todos BAJO/INFO). **Cerrados en este commit:**
- Borrado `ImpersonationBannerWrap` (dead code — el banner se usa inline).
- Trigger 0078 extendido a `visitas` (visitas.tenant_id == clientes.tenant_id),
  por consistencia de defensa en profundidad.

INFO sin acción (documentado): anular/editar pago NO llevan guard de
impersonación porque son UPDATE sobre filas ya tenant-correctas (no atribuyen
dinero nuevo a System); el guard #9 cubre INSERTs de dinero nuevo
(cobro/cargo/visita). `tenantId ?? ''` en settings del super_admin es
inalcanzable (el router no lo deja entrar a /admin/settings sin impersonar).
**Pendiente capas 2-4**: correr `flutter analyze`/`flutter test` local
(capa 3), invariantes SQL post-deploy (capa 2), testing manual (capa 4).

### #8 — Rework settings + diseñador visual de recibo ✅
- **8a** Vista previa en vivo (`ReciboPreview`): reusa el widget real
  `ReciboTicket` con datos de ejemplo; se actualiza al instante al cambiar
  cualquier ajuste del recibo. Al tope de la tab Recibos.
- **8b** Ocultar/reordenar bloques (migración **0079** — filas nuevas en
  `settings`, sin columnas → sin bump de schema/sync):
  - Show/hide: `recibo.mostrar_empresa` y `recibo.mostrar_cedula` (toggles
    nuevos, auto-aparecen como tiles) + los existentes (logo, monto en letras,
    adeudado; título/pie/whatsapp por contenido). Gateados en los 6 render
    paths (pantalla/PDF/Bluetooth × single/multi).
  - Reorder: `recibo.orden_pie` (CSV 'pie'/'whatsapp') con editor
    `ReciboPieOrderEditor` (ReorderableListView). Los 3 renderers emiten el pie
    libre y el WhatsApp en ese orden. El núcleo de plata (ítems/método/COBRADO/
    VUELTO/PAGADO) y el saldo adeudado quedan FIJOS — cero líneas de dinero
    tocadas (verificado por diff + balance de paréntesis 0/0/0).
  - El render lo implementó un agente con spec precisa; revisado por diff
    (money core intacto) + el agente mejoró el manejo del divider del
    encabezado (solo si empresa visible o hay título).
- **8c** Reorg de tabs: la infra de labels/descripciones/orden/hidden ya era
  completa; se integraron los settings nuevos (label + orden lógico en la
  sección Recibos) y se ocultó `recibo.orden_pie` del listado genérico (se
  edita con su widget dedicado).
- Requiere correr la migración 0079 en el Dashboard.

### #9 — Super_admin / impersonación: verificar + pulir ✅
- Estado encontrado: la impersonación YA estaba implementada y bien diseñada
  (RLS, sync rules con bucket `impersonated_tenant`, `current_tenant_id()`
  reescrito para respetarla, audit de enter/exit, banner ámbar "Viendo:
  tenant X", gating del router). Los writes de FORMULARIOS del admin (clientes,
  contratos, planes, settings, cuotas, fotos) usan `tenantIdProvider` correcto.
- 🔴 **Hallazgo CRÍTICO (bug de plata latente, lo encontró el agente de
  verificación):** 3 write-paths NO pasaban por `tenantIdProvider` y escribían
  en el tenant **System** (la fila real del super_admin) en vez del impersonado:
  - **Cobro** (`cobro_screen.dart:347/401`): generaba `pagos`/`recibos`
    huérfanos en System, invisibles para el ISP real, con correlativo del
    prefijo equivocado → rompía invariantes de dinero #4 y #10.
  - **Cargo manual** (`aplicar_cargo_dialog.dart:164`).
  - **Visita** (`visitas_service.dart:95`).
- Decisión (Rubén): el super_admin impersona para VER/GESTIONAR, NO para cobrar
  en campo (no tiene identidad de cobrador en el tenant X). → **Deshabilitar
  cobro/cargo/visita mientras impersona.**
- Hecho:
  - Nuevo `estaImpersonandoProvider` (bool).
  - Cobro: botón deshabilitado + mensaje claro + guard defensivo en `_confirmar`.
  - Cargo: trigger oculto en cobro + guard en `_aplicar`.
  - Visita: FAB oculto en cliente_detail + guard (throw) en el service.
  - signOut: `confirmarSignOut` llama `ImpersonationService.exit(reconnect:false)`
    si hay impersonación activa → no queda "pegajosa" al re-loguear.
- Verificado: grep confirma que esos eran los ÚNICOS 3 write-paths con
  `cobrador.tenantId`; el resto usa `tenantIdProvider`.
- Hardening cerrado (ex-backlog, ahora hecho — "sin backlog"):
  - (a) Banner de impersonación extraído a `ImpersonationBanner` (widget
    compartido, self-gating) + `ImpersonationBannerWrap`. Se muestra ahora en
    cobro, recibo (single+multi), detalle de cliente y de contrato — antes solo
    en el AdminShell.
  - (b) `enter()` sobre `enter()` ahora emite `impersonate_end` del tenant
    previo antes de reemplazarlo (trazabilidad completa).
  - (c) Migración **0078**: trigger `validar_tenant_coherente` (BEFORE INSERT en
    pagos/cargos_extra/recibos) rechaza filas cuyo tenant_id no coincida con el
    del padre (cuota/pago). Defensa server-side de la clase de bug. **Requiere
    correr la migración en el Dashboard.**
