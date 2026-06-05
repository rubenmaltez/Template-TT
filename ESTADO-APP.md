# ESTADO-APP.md — Snapshot del estado de SITECSA CRM (Cobranza ISP)

> **Propósito**: foto del estado real de la app en un punto dado. Se lee
> JUNTO con `CLAUDE.md` al abrir una sesión nueva de Claude Code, para
> continuar exactamente desde acá sin re-descubrir el contexto.
>
> **Última actualización**: 2026-06-05 (branch `claude/stoic-tesla-cGkJ6`).
> **Release v0.8.1 — checkpoint con impresión térmica RESUELTA + limpieza.**
> v0.8.1 quitó el botón de diagnóstico y los métodos B/C de prueba (GS v 0 quedó
> como único método). Sesión larga
> v0.6.4 → v0.8.0 — ver **§10** (resumen completo) y §9 (detalle de v0.6.4).
> Migraciones hasta **0095**, schema **v16** (sin cambios — todas las migr
> nuevas son filas/RPC/índice/constraint, no columnas sincronizadas).
> Distribución: `Install Steps/` (guías) + `Releases\vX.Y.Z\` (instaladores
> versionados). **Impresión térmica resuelta** (v0.7.6→v0.8.0): el bug era la
> CODIFICACIÓN ESC/POS (no la imagen) — se reemplazó `gen.imageRaster` por
> **GS v 0 armado a mano** (polaridad/ancho explícitos), confirmado en la
> GOOJPRT PT-210 vía un diagnóstico A/B (3 métodos). Layout del recibo afinado
> (márgenes mínimos, interlineado 1.12, totales/mora justificados, letra
> grande). Historial de cuota: recibo emitido fundido en "Pago registrado";
> notas del cobrador completas. Snapshots previos: 2026-06-04 v0.7.5; 2026-06-03
> v0.6.4 (§9); 2026-06-02 `83fec70` (audit total).

---

## 1. Veredicto general (audit total 2026-06-02)

| Dimensión | Estado | Resumen |
|---|---|---|
| **Backend / DB** | 🟢 SÓLIDO | 87 migraciones secuenciales sin gaps, schema↔Postgres↔sync coherentes (17 tablas), RLS multi-tenant completa + super_admin bypass, triggers (audit/dinero/coherencia/inmutabilidad) correctos, timezone server 0087. 0 CRITICAL/HIGH, 4 LOW. |
| **Dinero / contabilidad** | 🟢 SÓLIDO | Matemática del vuelto verificada a mano (NIO/USD, single/multi, arqueo USD). recaudado/total-fijo/trigger-mirror/anular/correlativo correctos. 10/10 invariantes. **F1 (saldo sin cargos_neto en /admin/cuotas) corregido.** |
| **Frontend correctness** | 🟢 LIMPIO | 0 SQL incompatible con SQLite, 0 `date('now')` pelados (norma TZ 100% en 30+ queries), 0 rutas rotas, 0 stream-lifecycle latentes, guards de rol coherentes. 1 archivo dead code. |
| **Seguridad multi-tenant** | 🟢 SAFE | Aislamiento RLS sólido; super-only enforced server-side (0085/0086); impersonación con defensa en capas (guards cliente + `validar_tenant_coherente` server); 6 edge functions robustas. 5 LOW (hardening), S4 corregido. |
| **QA funcional** | 🟢 AMPLIA | Todos los roles/módulos/tabs mapeados y funcionales con data real. ~5 features son flag/stub (documentadas). Reportes (8 PDF + 8 CSV + arqueo) completos. |
| **Tests automatizados** | 🟡 MEDIO | Unit de funciones puras + suite de repo de `pagos_repo` (14 tests) contra PowerSyncDatabase real (cobro/parcial/vuelto/USD/cargos_neto/multi-cuota/correlativo/anular/editar-guard). **CI verde: 210 passed** — los 14 del dinero corren en cada push. Falta integración y widget. |

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
| Tests automatizados | 8 archivos unit puros + `pagos_repo_test.dart` (14 repo) + `invariantes_dinero.sql` (11 invariantes). CI verde (210 passed). |

---

## 3. Findings del audit total (2026-06-02)

### ✅ CORREGIDOS en este audit

| ID | Sev | Qué era / cómo se resolvió |
|---|---|---|
| **F1** | 🟠 ALTA (dinero) | `/admin/cuotas` (`cuotas_admin_screen.dart:779`) mostraba `saldo = monto − pagado`, **omitiendo `cargos_neto`** → divergía de las otras ~6 pantallas (viola regla #10). Ej: cuota 500 + reconexión 100, paga 300 → mostraba 200 en vez de 300. Fix: `saldo = monto + cargos_neto − pagado` (el dato ya venía en el SELECT). |
| **S4** | 🟡 LOW (seguridad) | `historial._anular` no chequeaba impersonación (a diferencia de cobro/cargo/visita). Se agregó el guard `estaImpersonandoProvider` por consistencia. (Bajo impacto: anular es UPDATE benigno que no mueve tenant.) |

### ✅ LIQUIDADOS — backlog del audit (commit `83fec70`)

Todo el backlog accionable del audit se cerró:
- **L3** (migr 0088): `actualizar_notificaciones_mora.monto_adeudado` con `cargos_neto` (mora server-side exacta).
- **DB F2** (migr 0088): storage RLS extrae `pago_id` con `regexp_replace` (cualquier extensión), no acoplado a `.jpg`.
- **L2**: saldo del detalle de contrato con `cargos_neto` (+ columna al SELECT).
- **Dinero F2**: KPIs de cobros del dashboard en hora Nicaragua (UTC-6), unificado con el resto.
- **S2**: `cambiar-email` escribe audit del signOut fallido (igual que `forzar-password`).
- **INV11**: contrato fijo activo = exactamente `duracion_meses` cuotas (regla #5).
- **Doc estados de cuota** + **checklist `super_admin_all`** (DB F4) en CLAUDE.md.
- **Copy "Reasignar"** → path real (Clientes → cambiar cobrador).
- **Dead code**: `app_version_label.dart` borrado (los otros 3 ya no existían).
- **`ps.db.watch` inline**: barrido — solo 2 by-design en `geo_picker` (documentado).

**No-fix justificados** (no son backlog de bugs): dead code de migración 0054
(append-only, inocuo); S3 `reenviar-invitacion` sin lock (solo con super_admins
concurrentes — Rubén es 1); S5 ghost user (ya mitigado con cleanup).

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

### admin_cobranza — ✅ subconjunto (router `soloAdmin`) — AMPLIADO en v0.7.0
VE: dashboard, clientes (+detalle), Cobros, contratos, reportes, mapa. Desde
**v0.7.0** también: **editar clientes, crear/editar contratos, asignar cobrador,
y cobrar** (con su prefijo de recibo). Puede registrar visitas, anular pagos,
cambiar estado de contrato, editar fotos. **NO accede** (sigue negado por rol):
cobradores/Personal, planes, geografía, audit, settings. (Ver §10.1.)

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
`edge_functions`, `cuota_estado`, `error_log_entry`) + **`pagos_repo_test.dart` (14 tests de
repo)** contra una PowerSyncDatabase real (no mocks). **0 widget, 0 integración.**

Gaps por riesgo (dinero primero):
1. ✅ **HECHO** — ~~`pagos_repo` (correlativo, estado, vuelto, cargos_neto)~~: suite de 14 tests
   (completo/parcial/sobrepago-vuelto/USD/cargos_extra/multi-cuota/correlativo/anular/editar-guard),
   aserta contra la DB, verifica invariantes #1/#3/#4. Corre con `flutter test` + el core nativo
   `powersync_x64.dll` en la raíz (instrucciones en la cabecera del test).
2. **P1** — orden consecutivo multi-select; auto-detección de cargos; Edge Functions (rollback/ghost-user).
3. ✅ **HECHO** — ~~invariantes SQL de regla #5/#6 (total fijo)~~: INV11 agregada (contrato fijo
   activo tiene exactamente `duracion_meses` cuotas).
4. **P2** — matriz de redirects del router; widget tests.

**Mitigación**: `invariantes_dinero.sql` (**11 invariantes**) cubre la DATA; `pagos_repo_test.dart`
cubre el CÓDIGO de la transacción de cobro. Correr ambos tras cada deploy que toque dinero.

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

> El backlog accionable del audit quedó **liquidado** (§3), los **tests de
> `pagos_repo` pasan** (§5) y el **backlog persistente se re-verificó contra el
> código** (2026-06-03 — ver el bloque al tope del backlog en CLAUDE.md: el grueso
> ya estaba hecho, incluido el rework super_admin completo). Lo que queda son ítems
> LOW o features, a decidir como esfuerzo propio:

1. ✅ **HECHO** — ~~Tests de `pagos_repo`~~: suite de 14 tests de repo contra una
   PowerSyncDatabase real (no mocks), verde. Era el gap de cobertura más importante.
2. **Flags muertos `modo_ruta` / `caja_chica`**: hoy ocultos e inocuos. Decisión actual:
   **dejarlos ocultos**. Reabrir si se decide implementar la feature o limpiar los seeds/getters.
3. **Geo del cobro**: re-introducir captura de lat/lng en el cobro (se quitó `GpsService`).
   Decisión actual: **no por ahora**.
4. ✅ **HECHO** — ~~CI~~: `ci.yml` corre `flutter analyze` + `flutter test` (incl. los 14 tests de
   `pagos_repo`, vía `libpowersync*.so` del pub cache + `LD_LIBRARY_PATH`) en cada push. Verde en
   `c1da038` (**210 passed, 0 failed**). De paso se arreglaron 5 tests stale de `periodoRecibo`
   que tenían el CI en rojo (asertaban la vieja "regla del 15"; la función ya usa facturación vencida).
5. ✅ **HECHO** (2026-06-03) — liquidados los pendientes accionables del backlog re-verificado:
   R12 `==`/`hashCode` (Pago/Modulo/Setting/CobradorStats) · botón "Borrar logs" en `/super/logs` ·
   chequeo `SYSTEM_TENANT` en `forzar-password` · cancelación del listener de `ErrorLogService`.
   El resto del backlog persistente es LOW / edge-case (ver el bloque de re-verificación en CLAUDE.md).

---

## 8. Reglas para mantener este documento

- Actualizar fecha + commit del header en cada cierre de sprint relevante.
- Mover findings resueltos a un changelog corto; los nuevos a §3.
- Si una feature pasa de flag a implementada, moverla en §4/§4b.
- Cuando se agreguen tests, actualizar §5.
- NO reemplaza CLAUDE.md (reglas/proceso). Es el COMPLEMENTO de estado.

---

## 9. Release v0.6.4 (2026-06-03)

Branch `claude/stoic-tesla-cGkJ6`. Cuatro cambios + reorg de distribución.
Cada uno pasó audit (correctness + QA + deployment-safety), 0 findings.

### Cambios funcionales
1. **Auditoría oculta para el admin por defecto.** El item `/admin/audit` pasó a
   ser super-only por tenant: nueva clave `cobranza.audit_visible_admin`
   (default OFF, `editable_por='super_admin'`, migr **0089**). El super_admin la
   ve **siempre** (incluso impersonando — bypass por rol en menú y router); el
   admin solo si el super la habilita en Ajustes → Avanzado → "Pantallas
   opcionales del admin"; `admin_cobranza` nunca (sigue gateado por `soloAdmin`).
   Mismo patrón que `cobranza.pantalla_pagos`/`pantalla_notificaciones`.
2. **Se quitó el wizard de onboarding.** Borrado `onboarding_screen.dart`, su
   ruta, el redirect forzado, el provider `empresaNombreRowExistsProvider` y el
   gate de carga de `admin_shell`. El admin entra directo al dashboard y
   configura empresa en Ajustes → Empresa y planes en Administración → Planes.
   `empresaNombreProvider` se mantiene (lo lee el reporte; vivo vía `ref.listen`).
3. **Versión visible.** Nuevo `AppVersionLabel` (lee `package_info`) al pie del
   sidebar admin (rail + drawer), en el login y en el perfil del cobrador.
4. **Fix toggles del diseñador de recibo.** El editor guardaba con `update`
   (UPDATE puro); los tenants creados después de 0080 no tienen la fila
   `recibo.layout` (ni `recibo.mostrar_cedula`, agregada en 0079) sembrada → el
   UPDATE afectaba 0 filas y el toggle rebotaba. Fix: el editor usa `upsert`
   (crea la fila si falta) en sus 3 call sites; migr **0090** suma esas 2 claves
   al seed de alta de tenant + backfillea los existentes. Correr 0090 repara
   tenants viejos al instante (incluso en 0.6.3). `recibo.titulo` y
   `recibo.mostrar_adeudado` ya estaban en el seed (0045).

### Migraciones
- **0089** — `cobranza.audit_visible_admin` (super-only, default OFF) en
  `seed_settings_super_only` + backfill. Solo filas en `settings` → sin bump de
  schema ni redeploy de sync rules.
- **0090** — `seed_settings_recibo_layout` (recibo.layout + recibo.mostrar_cedula),
  sumada al trigger `tenants_seed_settings_trg` + backfill. Idem: sin bump.

### Reorg de distribución (orden absoluto)
- **`Install Steps/`** — fuente única de cómo publicar e instalar: guías
  numeradas (1 publicar, 2 PC, 3 Android) + `install-latest.ps1` + `uninstall.ps1`.
  Reemplaza a la vieja `instalador/` (tenía copias **stale** de CLAUDE/ESTADO/
  REPORTE — borradas; las canónicas viven en la raíz).
- **`build-release.ps1`** — ahora archiva instaladores **versionados**
  (`SITECSA-CRM-vX.Y.Z.msix/.apk`) en `Releases\vX.Y.Z\` (se apilan) + copia al
  Escritorio, y sube a GitHub los de nombre **fijo** (`SITECSA-CRM.msix/.apk`)
  para que el auto-update por `latest/download/` siga resolviendo. `Releases/`
  gitignored.

### Deploy
Correr **0089 y 0090** en orden (Dashboard → SQL Editor), después
`.\build-release.ps1`. Ninguna toca schema/sync rules. Ver
`Install Steps/1-Publicar-nueva-version.md`.

---

## 10. Sesión v0.6.4 → v0.7.5 (2026-06-04)

Sesión muy larga: features de roles, fix de drift de DB, reorg de distribución,
y un **rework completo de la impresión del recibo** (varias iteraciones). Todo
en branch `claude/stoic-tesla-cGkJ6`. Cada batch pasó audits (correctness + QA/
offline + deployment-safety), con fixes aplicados antes de commitear.

### 10.1 Releases y qué trajo cada uno
- **v0.6.4** (§9): auditoría super-only (0089), quitar onboarding, versión
  visible, fix toggles del recibo (`upsert` + 0090).
- **Fix de drift de DB (crítico)**: el Postgres del usuario estaba desfasado —
  faltaba **0077** (`contratos.codigo`) → el alta de contrato fallaba con
  "codigo column not found". Se aplicó 0077 + `notify pgrst` + redeploy de sync
  rules. Se corrió una **query de verificación de drift** (information_schema vs
  lo que `schema.dart` espera) → confirmó que era el ÚNICO faltante. **Lección:
  verificar drift Postgres-vs-repo al abrir sesión** (ver §10.4).
- **v0.7.0** — **roles + backlog de testing**:
  - `admin_cobranza` ahora gestiona clientes y contratos: editar cliente, crear/
    editar contrato, asignar cobrador, y cobrar. Se unificó `esAdmin` →
    `puedeGestionar` (admin ∪ admin_cobranza) en `cliente_detail_screen`. Sigue
    NEGADO para admin_cobranza: Settings, Personal, Planes, Geografía, Auditoría.
  - **Prefijo de recibo** para los 3 roles que cobran (cobrador/admin/
    admin_cobranza): cliente + invite + RPC `set_cobrador_rol` (**0093**) +
    índice único de prefijo por tenant (**0092**).
  - **Cobrador visible y asignable desde el detalle del cliente** (inline + form).
  - **Navegación Android 11+** arreglada (`<queries>` en manifest + `launchUrl`
    directo, sin `canLaunchUrl`).
  - **Botón WhatsApp oculto** en el detalle de cliente.
  - **Admin puede forzar password** (edge function `forzar-password-cobrador`
    relajada: acepta admin sobre targets de su tenant no-admin/no-super + botón
    en Personal). admin_cobranza NO (no tiene Personal).
  - **Email visible en Personal** (RPC `list_cobrador_emails` **0091**).
  - **super_admin impersonando puede invitar cobrador** (manda `tenant_id` en el
    body; `invitar-cobrador` ajustada).
  - `super_shell` ahora escucha `crudUploadErrorProvider`.
  - **Migraciones 0091/0092/0093**; edge functions `forzar-password-cobrador` e
    `invitar-cobrador` redeployadas.
- **v0.7.1–v0.7.5 — saga de IMPRESIÓN** (ver §10.2).

### 10.2 Impresión del recibo (el tema más iterado)
Problema raíz: la térmica del usuario (PT-210) viene en codepage chino (GB18030)
y NO cambia de codepage confiablemente → tildes salían como chino. Se probaron
enfoques hasta dar con el sólido:
- **v0.7.1**: codepage CP850 + reset ESC @ + logo raster (cache local offline) +
  fuente NotoSans embebida en los PDF (arregla ⊠ en reportes). → tildes seguían
  mal (codepage es por-modelo, no universal).
- **v0.7.2**: térmica = rasterizar el PDF del recibo (`Printing.raster`/PDFium) +
  58mm estándar (migr **0094** 57→58) + recibo limpio sin líneas + subset de
  fuente ampliado. → **PDFium NO renderizó la fuente embebida** → imprimía SOLO
  el logo (texto invisible).
- **v0.7.3**: **enfoque definitivo** — un solo widget **`ReciboTicket`**
  (Flutter/Skia) usado para la **preview Y la impresión** (se captura con
  `screenshot` → raster ESC/POS). Skia sí renderiza las tildes en cualquier
  impresora, offline; **preview = lo que se imprime** (WYSIWYG). Se quitó el
  badge/conteo de reimpresión. Banner "red inestable" ya no aparece en falso al
  arrancar (no cuenta el parpadeo de la ventana de arranque, ~25s).
  Matemática del dinero del ticket = **copia exacta del PDF** (auditada campo
  por campo). El "Descargar PDF" (solo web) sigue usando `recibo_pdf`.
- **v0.7.4**: la captura traía transparencia → recibo en negativo; se **aplana
  sobre blanco**. Error de sync al imprimir 58mm: el CHECK `recibos_ultimo_
  formato_mm_check` (0006) solo aceptaba 57/80 → migr **0095** acepta 57/58/80.
  Preview chica → `FittedBox.scaleDown` → `contain`.
- **v0.7.5**: fondo aún oscuro → el `targetSize 384×5000` dejaba área no-blanca;
  ahora el ticket va en un **Container blanco que cubre todo el targetSize** →
  captura 100% blanca + recorte → positivo. Letras chicas → `baseFont` pasó de
  `anchoDots/576` a `anchoDots/384` (58mm 1.0×, 80mm 1.5×).

**Arquitectura de impresión actual (v0.7.5)**:
`ReciboTicket` (widget, ancho = dots del papel, fondo blanco) → `screenshot`
captura a PNG (targetSize ancho×5000 sobre Container blanco, pixelRatio 1.0) →
`ImpresoraService.imprimirImagen(pngBytes)`: decode → aplanar sobre blanco →
resize a dots → grayscale → recortar blanco → dither Floyd-Steinberg →
`gen.imageRaster` → BT. 100% offline. **80mm es el estándar de producción**
(576 dots); 58mm es el de testing de Rubén (384 dots).

### 10.3 Reset total + distribución
- **Reset de testing**: se wipeó todo (tenants/usuarios/data) preservando SOLO
  el super_admin + tenant System, vía SQL guardado (sin `session_replication_
  role` — restringido en Supabase; se borró en orden hijo→padre con guard).
- **Distribución (orden absoluto)**: `build-release.ps1` archiva instaladores
  **versionados** en `Releases\vX.Y.Z\` + Escritorio, y sube a GitHub los de
  nombre **fijo** (auto-update por `latest/download`). Carpeta **`Install Steps/`**
  con guías numeradas + scripts. Versión visible en login/sidebar/perfil.
- **Ícono Android**: el fuente vivía en `assets/` untracked y se perdió en un
  `git restore`; se regeneró con `flutter_launcher_icons` y se **commiteó el
  fuente** (`assets/icon/app_icon.png`) + mipmaps para que no se pierda.

### 10.4 Pendiente de validar / backlog de la sesión
- **VALIDAR v0.7.5 en impresora real**: que el recibo salga **fondo blanco +
  letras grandes** (online y offline, 58 y 80mm). Si AÚN sale oscuro, el plan es
  guardar el PNG capturado a archivo para inspeccionar qué produce `screenshot`.
- **Drift Postgres-vs-repo**: correr la query de verificación (information_schema)
  al abrir cada sesión; el Postgres puede estar atrás de las migraciones del repo.
- **NITs documentados** (no bloquean): rasterizar/dither corre en el hilo de UI
  (~1-2s con spinner; mover a isolate si molesta); `_cachearLogoSiHay` corre en
  cada `status.connected` (dedupe por logoPath pendiente); `recibo.template_57mm`
  string huérfano oculto; sample row del diseñador sin `contrato_id` (no muestra
  mora en la preview de settings, by-design).
- **Pendiente de decisión del dueño**: si admin_cobranza también debería tener
  Personal/Auditoría (hoy NO, por seguridad — decisión actual confirmada).

### 10.5 Comunicación / proceso (acuerdo de la sesión)
Rubén pidió: cuando una regla vieja (de CLAUDE.md o de pedidos previos) **entre
en conflicto** con una decisión nueva, **explicar el conflicto claro (qué es,
cómo afecta) y preguntar**, en vez de asumir la regla vieja — la app evoluciona.

### 10.6 Impresión RESUELTA + recibo afinado (v0.7.6 → v0.8.0, 2026-06-05)
Tras dos fixes fallidos (v0.7.4/v0.7.5 seguían imprimiendo negativo/angosto/
chico), se cambió de estrategia: **dejar de adivinar y DIAGNOSTICAR**.
- **v0.7.6 — diagnóstico**: botón "Diagnóstico: ver imagen a imprimir" que
  muestra el **PNG crudo de la captura** + el **bitmap final que va a la
  térmica** (sobre fondo magenta para ver transparencia) + métricas (dims,
  alpha, luminancia). Resultado clave: **el bitmap salía CORRECTO** (positivo,
  ancho completo, legible). → El bug NO era la imagen.
- **v0.7.7 — fix real**: si el bitmap está bien pero imprime mal, el problema
  está en la CODIFICACIÓN ESC/POS. Se reemplazó `gen.imageRaster` (de
  esc_pos_utils_plus) por **`_rasterGsv0` armado a mano**: GS v 0 con polaridad
  (1=negro), ancho en bytes y partición en bandas de 255 filas, todo explícito.
  El diagnóstico quedó con **3 botones A/B/C** (gsv0 / gsv0 invertido / ESC *
  columnas) para A/B-testear el método sin round-trips. Letra más grande
  (`baseFont` desacoplado del ancho: 58mm 1.5×, 80mm 1.9×).
  **Confirmado por Rubén en la PT-210: Método A (GS v 0 normal) = correcto.**
  B salía negativo (su impresora no necesita invertir); C en blanco (la PT-210
  no soporta ESC * columnas).
- **v0.7.8 — aprovechar el papel**: márgenes h. 24→6px, interlineado 1.3→1.12,
  gaps entre bloques a la mitad, padding vertical 16→4, avance ESC d 3→2,
  recorte blanco pad 8→4. Los valores dejaron de saltar de línea.
- **v0.8.0 — checkpoint**: (1) **totales/mora justificados**: `_totalLine` tenía
  la etiqueta en `Flexible` flex 1 → el valor quedaba a media página; con
  `flex: 0` el valor se pega al margen derecho igual que el resto. (2) **Recibo
  emitido fundido en "Pago registrado"** en el historial de la cuota (su número
  va al subtítulo); la **anulación** de recibo sigue como entrada propia
  (decisión confirmada con Rubén — mantiene la regla #5 para lo importante).
  (3) **Notas del cobrador completas**: el formateador del change log cortaba
  todo valor >30 chars con "…"; subido a 500 (el tile ya hace wrap).

**Arquitectura de impresión actual (v0.8.1)**:
`ReciboTicket` (widget, ancho = dots del papel, fondo blanco, márgenes mínimos)
→ `screenshot` captura a PNG (targetSize ancho×5000 sobre Container blanco,
pixelRatio 1.0) → `ImpresoraService.imprimirImagen`: decode → aplanar sobre
blanco → resize a dots → grayscale → recortar blanco → dither Floyd-Steinberg →
**`_rasterGsv0`** (GS v 0 manual, 1=negro, bandas de 255) → BT. 100% offline.
80mm producción (576 dots), 58mm testing PT-210 (384 dots).

**v0.8.1 — limpieza (hecho)**: Rubén confirmó el recibo en la PT-210; se
**quitó el botón de diagnóstico, los métodos B/C, `imprimirImagenMetodo`,
`diagnosticar`, `DiagnosticoImpresion` y el archivo `impresora_diagnostico.dart`**.
`imprimirImagen` ahora hace GS v 0 directo. Sin cambios en cómo imprime.
