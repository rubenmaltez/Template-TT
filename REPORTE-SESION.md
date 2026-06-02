# REPORTE-SESION.md

**Bitácora viva del proyecto Cobranza ISP**: cómo se ESPERA que funcione la app
(comportamiento esperado por feature + lifecycle de uso real) y el HISTORIAL de
fixes aplicados (error → fix → expectativa, por sesión).

> **Para Claude (sesiones futuras):** leé este archivo junto a `CLAUDE.md` y
> `ESTADO-APP.md`. Antes de tocar un feature, revisá acá su **comportamiento
> esperado**. Al cerrar cada sesión/sprint de fixes, **agregá una entrada nueva**
> en "Historial de fixes" (más reciente arriba) con el formato error → fix →
> expectativa + commits + archivos.

---

## 1. Expectativas de comportamiento (referencia rápida)

Cómo DEBE comportarse cada área. Si el código no cumple esto, es un bug.

### Código de cliente
- Identificador simbólico corto por cliente (ej. `CL00042`), **único por tenant**
  y **case-insensitive** (índice `UNIQUE (tenant_id, upper(codigo))`).
- **Inmutable** una vez asignado para admin/cobrador; **solo el super_admin**
  puede corregirlo.
- Se normaliza a **MAYÚSCULAS** al tipear y al guardar.
- Buscable por código en: lista del cobrador, lista del admin y búsqueda global.
- Si se intenta duplicar: aviso **en vivo** mientras se tipea + bloqueo al guardar.
  El `UNIQUE` de Postgres es la red dura final (cubre el caso offline).

### Settings que GATEAN comportamiento (no son decorativos)
Un setting guardado DEBE cambiar el comportamiento real de la app:
- **Settings super-only (gateados por el super_admin, no por el admin)**: cuatro
  claves las controla SOLO el dueño del SaaS — `editable_por='super_admin'` +
  RLS `settings_write_admin` endurecida (migración 0085). El admin NO las ve en
  la UI (tab Avanzado solo super) ni las puede escribir server-side:
  - `cobranza.comprobante_habilitado` ON → el cobro muestra el picker de foto
    para métodos con comprobante; OFF → solo guarda el número de referencia
    (no consume Storage). Es el switch maestro de la foto.
  - `cobranza.foto_obligatoria` → sub-opción del anterior (solo aplica si la
    foto está habilitada).
  - `cobranza.pantalla_pagos` / `cobranza.pantalla_notificaciones` ON → aparece
    el item en el menú admin y la pantalla es accesible; OFF → el menú la oculta
    y el guard de pantalla bloquea el acceso por URL directa.
- `cobranza.foto_obligatoria` ON → no se puede confirmar un cobro **con método
  que requiere comprobante** sin foto. (Efectivo no se bloquea: no muestra picker.)
- `cobranza.pago_parcial` OFF → en cobro de una cuota se exige cubrir el **saldo
  completo**. (Multi-cuota cobra el total por diseño.)
- `recibo.titulo` → aparece como título del recibo en **las 3 superficies**
  (pantalla, PDF, impresión térmica), recibo simple y multi-cuota.
- `recibo.mostrar_adeudado` ON → el recibo muestra "Saldo cuota" si quedó saldo;
  OFF → no lo muestra.
- `empresa.whatsapp` → aparece en el pie del recibo en las 3 superficies.

### Roles
- El **rol** de un usuario solo lo cambia el **super_admin** (trigger
  `cobradores_freeze_rol` lo fuerza server-side). En la UI del admin el control
  de rol está **deshabilitado** con aviso — nunca debe fallar en silencio.
- El cambio de rol del super_admin va por la RPC `set_cobrador_rol` (queda en
  `audit_log`).

### Generación de cuotas y mes del recibo (facturación vencida)
- **Un solo campo de fecha** en el form de contrato: **fecha de instalación**.
  El día de pago mensual = el día de esa fecha; no hay campo separado.
- **Facturación vencida**: la **primera cuota vence el MES SIGUIENTE** a la
  instalación, mismo día (clamp a fin de mes). Instalado el 14/may → 1ª cuota
  vence 14/jun. El form muestra esa fecha estimada.
- **Mes simbólico del recibo** = el mes calendario con **MÁS días** dentro del
  período de servicio que **termina** en el vencimiento y arranca el mismo día
  del mes anterior. Empate exacto → gana el mes del vencimiento. **No se
  almacena**: se deriva al mostrar desde `(periodo, dia_pago)` vía
  `Fmt.mesServicio`. Debe dar idéntico en recibo (pantalla/PDF/térmica),
  detalle de contrato (cuotas + pagos), lista del cobrador, admin de cuotas y
  tarjetas de cobro. Cuotas manuales (sin contrato) → mes del periodo crudo.
  - Ejemplos: instala 14/may → 1ª cuota **MAYO**; 5/abr → **ABRIL**;
    25/abr → **MAYO**; día 16 (mes de 30) → mes anterior; día 17 → mes venc.
- **Contrato fijo**: se generan exactamente `duracion_meses` cuotas (12/24).
- **Contrato indefinido**: se generan retroactivo desde el primer mes hasta hoy
  + colchón de 3 meses; el cron mensual extiende el colchón.
- **Campos informativos**: `costo_instalacion` y `notas` del contrato se cargan
  en el form y se muestran en el detalle. El costo NO genera un cobro automático.

### Invariantes de dinero (resumen — ver CLAUDE.md para el detalle)
- `recaudado` = `SUM(pagos.monto_cordobas)` no anulados.
- Total de contrato fijo = `precio_mensual × duracion_meses` (definido al crear,
  **nunca** re-derivado de fechas ni sumando cuotas). `pendiente = total − recaudado`.
- Contrato indefinido: solo "recaudado acumulado", sin pendiente.
- **Consistencia cross-pantalla**: saldo/recaudado dan idéntico en lista de
  clientes, detalle de contrato y reportes.

### Change log / historial de cambios (toda entidad editable)
- **Universal**: toda entidad que el usuario crea/edita/borra tiene historial
  accesible desde su pantalla (ícono 🕐). Regla y contrato completo en CLAUDE.md
  ("Modelo del change log").
- **Quién lo genera**: el trigger server-side `audit_changelog_trg`, NO el
  cliente. Offline el dato se ve al toque, pero la ENTRADA del historial aparece
  recién al sincronizar; queda en su hora real porque `ocurrido_en` carga el
  device-time.
- **Profundidad**: el log de un padre muestra sus hijas DIRECTAS, nunca nietas.
  Log del **cliente** = cliente + visitas + fotos (completo) + contratos (solo
  superficie: alta/baja/estado/reasignación de cobrador). Un pago a una cuota
  NO aparece en el log del cliente — vive en el log de esa **cuota** (cuota +
  pagos).
- **Sin límites**: el historial muestra la vida completa de la entidad.

---

## 2. Lifecycle de uso real (end-to-end)

**"Un día en WispNorte"** — un WISP chico en Estelí, Nicaragua. Es el recorrido
canónico que el producto debe resolver de punta a punta.

1. **Alta del ISP (super_admin — Rubén).** Crea el tenant *WispNorte* desde
   `/super/tenants` con el switch de email en OFF. El server genera una
   contraseña; Rubén se la pasa al dueño, **Don Carlos**, por WhatsApp.

2. **Configuración (admin — Don Carlos).** En `/admin/settings`: empresa
   (nombre, RUC, **WhatsApp 8888-1234**), Cobranza (**foto obligatoria ON**,
   **pago parcial OFF**), Recibos (título **"RECIBO OFICIAL WISPNORTE"**,
   **mostrar adeudado ON**).

3. **Catálogo.** Crea el plan *Residencial 10MB — C$500/mes*. Da de alta
   clientes con código (doña Rosa = **CL00042**; si tipea `cl42` se guarda
   `CL00042`). Si intenta reusar un código, lo ve antes de guardar. Crea el
   contrato de doña Rosa: **un solo campo** — fecha de instalación
   (**14/may**) + **duración 1 año** → se guarda `duracion_meses = 12`, se
   generan las **12 cuotas** y la primera **vence el 14/jun** (mes siguiente,
   facturación vencida). Opcional: carga **costo de instalación** y **notas**.

4. **Campo (cobrador — María).** Sale con el celular (offline-first). Busca
   **"42"** y encuentra a doña Rosa al toque. Abre el cobro de la primera cuota,
   que en el recibo figura como **MAYO** (el mes que doña Rosa más usó: del
   14/may al 14/jun son más días de mayo), aunque se cobra en junio:
   - Doña Rosa quiere pagar **C$300** → el sistema **no deja** (*"cobrá el total
     de C$500"*). Paga los 500 por transferencia.
   - María intenta confirmar y el sistema le **exige la foto** del comprobante.
   - Imprime el recibo térmico: **"RECIBO OFICIAL WISPNORTE"** arriba, el detalle,
     **saldo C$0**, y abajo el **WhatsApp 8888-1234**.

5. **Sincronización y control (admin).** Vuelve la señal → PowerSync sincroniza.
   Don Carlos abre el contrato de doña Rosa: **Total C$6.000** (500×12, estable),
   **Recaudado C$500**, **Pendiente C$5.500** — idéntico en lista, detalle y
   reportes.

6. **Equipo.** Don Carlos quiere ascender a María; ve el rol **bloqueado**
   (*"Solo el super_admin puede cambiar el rol"*). Llama a Rubén, que lo hace
   desde su panel; queda en `audit_log`.

**Resultado:** el ISP reemplaza su Excel + WhatsApp por un ciclo trazable:
catálogo → cuotas → cobro con respaldo (foto + recibo identificado) → reportes
consistentes → auditoría.

---

## 3. Historial de fixes

> Más reciente arriba. Formato por ítem: error → fix → expectativa.

### 2026-06-02 — Audit integral post-snapshot + 4 fixes

Audit de 4 agentes en paralelo (integridad DB↔schema↔sync, dinero, frontend,
seguridad/impersonación) sobre el trabajo posterior al snapshot. **No encontró
bugs reales nuevos.** Commits `c43957d`→`c6cbebd`, migración **0085** (RLS, sin
cambios de schema/sync). Auditado estático (sin `flutter`/`dart` en el entorno;
correr `flutter analyze` al pull). Migración 0085 se deploya por Dashboard.

**#1 — Settings super-only solo se gateaban en la UI** (🟠 Media)
- *Error:* las 4 claves que controla el dueño del SaaS por tenant (foto de
  comprobante → consume Storage; pantallas admin opcionales) tenían el gate
  `esSuperAdmin` solo client-side. Server-side, `settings_write_admin` (0004)
  dejaba a CUALQUIER admin del tenant escribir CUALQUIER fila de `settings` →
  un admin podía re-activar la foto o las pantallas que el super dejó en OFF,
  escribiendo el setting por PowerSync/REST. No cruzaba tenants (RLS scopa),
  pero anulaba el control de costo/política del SaaS.
- *Fix:* migración 0085 — las 4 claves pasan a `editable_por='super_admin'`;
  `settings_write_admin` agrega `editable_por <> 'super_admin'` (el admin ya no
  las toca; el super sí, vía `super_admin_all` 0026); `seed_settings_super_only`
  las siembra en tenants nuevos (el seed default no las incluía). Guard de
  pantalla (`EmptyState`) en `/admin/pagos` y `/admin/notificaciones` para el
  acceso por URL directa.
- *Expectativa:* ver §1 "Settings super-only". El super_admin las prende/apaga
  por tenant desde el tab Avanzado; el admin nunca las ve ni las escribe.

**F3 — Impersonación no se limpiaba en 2 signOut crudos** (🟡 Baja)
- *Error:* `sync_gate_screen` y `set_password_screen` llamaban `auth.signOut()`
  directo, sin salir de impersonación. Un super_admin impersonando que cerraba
  sesión ahí dejaba la fila viva → al re-loguear entraba impersonando el tenant
  viejo.
- *Fix:* `limpiarImpersonacionSiActiva()` (ahora pública) corre antes de ambos
  signOut. La limpieza es un write server-side que necesita el JWT vivo → va
  antes del signOut, no en un listener posterior.

**O1 — Faltaba el invariante de coherencia de tenant** (🟡 Baja)
- *Error:* el test `invariantes_dinero.sql` no verificaba lo que el trigger
  `validar_tenant_coherente` (0082) enforça.
- *Fix:* INV10 — `pagos`/`recibos`/`cargos_extra` deben tener el mismo
  `tenant_id` que su padre.

**#2 — El "Detalle de mora" no se imprimía en Bluetooth térmico** (🟡 Baja)
- *Error:* el bloque `mora` salía en pantalla y PDF, pero el caller `_imprimir`
  no pasaba `moraRows` al service térmico → salía vacío.
- *Fix:* se computa igual que el PDF (`fetchMoraContrato` + filtro de cuotas del
  grupo) y se pasa; stub web espeja la firma. Las 3 superficies quedan en paridad.
- *Expectativa:* el recibo térmico muestra `EN MORA` + meses adeudados + `TOTAL
  MORA`, igual que pantalla y PDF.

### 2026-05-31 — Change log universal (cliente agregado + planes + regla)

Sprint de trazabilidad. Commits `04e909f` + `65cc6df` (+ docs), migración
**0076**. Sin cambios de schema/sync (solo trigger + UI + curaduría). Auditado
estático (sin `flutter`/`dart` en el entorno; correr `flutter analyze` al pull).

**A — Historial del cliente ahora es timeline agregada**
- *Gap:* el detalle del cliente solo mostraba los cambios del propio registro
  `clientes`. Las visitas, fotos y contratos del cliente tenían su audit en
  `audit_log` pero no se veían desde el cliente.
- *Fix:* `HistorialClienteWidget` une cliente + visitas + fotos + contratos en
  una sola línea de tiempo. Hijas localizadas por `cliente_id` leído del
  snapshot JSON (`json_extract`), así una foto borrada físico sigue apareciendo.
- *Expectativa:* ver §1 "Change log / historial de cambios".

**B — Contratos en el log del cliente = solo superficie**
- *Decisión (Rubén):* desde el cliente se ve que un contrato existe / cambió de
  estado / se reasignó cobrador, pero NO las ediciones puntuales (precio, día,
  plan) ni los pagos de sus cuotas. Esos viven en el log del contrato / cuota.
- *Fix:* `kAuditCamposSuperficie` restringe los campos visibles del contrato a
  `{estado, cobrador_id}` dentro del log del cliente; un update que solo tocó
  otros campos queda vacío y se oculta.

**C — Planes entran al change log**
- *Gap:* `planes` (editable por el admin) no tenía trigger de audit.
- *Fix:* migración 0076 (`trg_changelog_planes`) + curaduría en
  `audit_changelog.dart` + botón 🕐 por fila en la pantalla de planes.

**D — Sin límites en el historial**
- *Error:* las queries tenían `LIMIT 50` / `LIMIT 100`.
- *Fix:* se quitaron; el historial muestra la vida completa de la entidad.

**Pendiente:** geografía (departamentos/municipios/comunidades) son globales sin
`tenant_id` → el trigger genérico no aplica; documentado en CLAUDE.md.

### 2026-05-30 (noche) — Facturación vencida + mes simbólico del recibo

Sprint de modelo de cobranza. Commits `e69c37a` + `5c82ac7` + `7a96887`,
migración **0074**, schema local **v15**. Auditado (2 audits estáticos, ambos
limpios — sin `flutter`/`dart` en el entorno; correr `flutter analyze` al pull).

**A — Form de contrato vuelve a un solo campo (revierte parte del 0073)**
- *Error:* el 0073 había agregado un segundo selector ("Fecha del primer cobro")
  además de la instalación. Rubén lo pidió simplificar: un solo dato, el resto
  derivado. Dos campos de fecha eran confusos y redundantes.
- *Fix:* el form pide **solo "Fecha de instalación"**. El día de pago = el día de
  esa fecha; el primer cobro se deriva (mes siguiente) y se muestra como texto
  informativo. Se eliminó el selector manual de primer cobro y el param muerto
  `_SelectorFecha.primeraFecha`.
- *Archivos:* `contrato_form_screen.dart`.

**B — Facturación vencida (la primera cuota es mes vencido)**
- *Error:* el 0073 anclaba la primera cuota al mes de instalación, lo que en la
  práctica era facturación adelantada. El negocio real es **vencido**: el cliente
  paga al final del período de servicio.
- *Fix:* `generar_cuotas_contrato` reescrita (migración 0074): la primera cuota
  vence el **mes siguiente** a la instalación. **Fijos** generan exactamente
  `duracion_meses` cuotas; **indefinidos** se generan retroactivo hasta hoy +
  colchón de 3 meses, y el cron extiende el colchón. `generar_cuotas_mes` y el
  cron ahora **delegan** en `generar_cuotas_contrato` (una sola fuente de verdad).
- *Expectativa:* ver §1 "Generación de cuotas y mes del recibo".

**C — Mes simbólico del recibo = mes con más días (reemplaza la "regla del 15")**
- *Error:* el recibo derivaba el mes con una "regla del 15" aproximada
  (`Fmt.periodoRecibo`) que fallaba en los bordes (día 16 vs 17) y, peor, estaba
  **inconsistente entre pantallas**: lista del cobrador, admin y detalle de
  contrato mostraban `Fmt.mes(periodo)` crudo (mes calendario), no el mes de
  servicio. Dos vistas del mismo período mostraban meses distintos.
- *Fix:* `Fmt.mesServicio` / `mesServicioLabel` calculan el mes con **más días**
  del período que termina en el vencimiento (empate → mes del vencimiento). Se
  unificó en **todas** las superficies: recibo (pantalla/PDF/térmica), detalle de
  contrato (cuotas + pagos), lista del cobrador, admin de cuotas y tarjetas de
  cobro. Se deriva al mostrar desde `(periodo, dia_pago)` — **no se almacena**, así
  que no migra cuotas viejas ni toca el control de duplicados. Cuotas manuales
  (sin contrato) → mes del periodo crudo.
- *Expectativa:* ver §1. Mismo período = mismo mes en toda la app.

**D — Campos `costo_instalacion` + `notas` (informativos)**
- *Fix:* columnas nuevas en `contratos` (migración 0074), cargables en el form y
  visibles en el detalle. El costo **no** genera un cobro automático (decisión
  explícita: dato informativo por ahora). schema v14→15.
- *Archivos:* migración 0074, `schema.dart`, `db.dart`, `formatters.dart`,
  `contrato_form_screen`, `contrato_providers`, `contrato_detail_header`,
  `contrato_detail_cuotas`, `contrato_detail_pagos`, `cuotas_list_screen`,
  `cuotas_admin_screen`, `cobro_screen`, `recibo_screen`, `recibo_pdf`.

> **Nota sobre el 0073:** la entrada de abajo ("Fecha del primer cobro explícita")
> queda **superada** por esta tanda. El modelo vigente es el de acá: un solo
> campo + facturación vencida + mes de servicio derivado.

**Deploy de esta tanda:** migración **0074** + redeploy de **sync rules**
(columnas `costo_instalacion`/`notas` vía `SELECT *`) + schema local **v15**
(DB fresca al reiniciar). Correr `flutter analyze` antes de testear.


### 2026-05-30 (tarde) — Navegación + creación de contratos

Hallazgos durante el primer testing manual. Commit `a31e42d` + migración 0073.

**A — Submenú "Administración" en el sidebar**
- *Error:* el rework de BULK 12 simplificó el sidebar con la intención de
  mover Planes/Geografía/Auditoría "dentro de Configuración", pero los links
  nunca se agregaron. Las rutas existían y funcionaban, pero **no había forma
  de llegar a ellas desde la UI** (Planes y Geografía inalcanzables).
- *Fix:* ítem expandible "Administración" que agrupa Personal + Planes +
  Geografía + Auditoría. `ExpansionTile` compartido por rail (desktop) y drawer
  (mobile); arranca expandido si la ruta actual cae dentro del grupo.
- *Archivos:* `admin_shell.dart`.

**B — Documento del contrato opcional en el alta**
- *Error:* la subida de documento solo existía en el detalle del contrato; el
  form de creación no tenía campo.
- *Fix:* picker opcional en el form. Con conexión sube apenas se crea el
  contrato (bucket `contratos-documentos`); offline o sin adjuntar, el contrato
  se crea igual y el doc se sube luego desde el detalle (best-effort, no rompe
  offline-first). Solo en alta.
- *Archivos:* `contrato_form_screen.dart`.

**C — Fecha del primer cobro explícita** ⚠️ *(superado por la tanda 0074 — ver
arriba: el modelo vigente es un solo campo + facturación vencida)*
- *Error:* el form solo pedía fecha de instalación + día de pago; la fecha de
  la primera cuota la derivaba un trigger y no se mostraba ni se controlaba.
- *Fix:* campo "Fecha del primer cobro"; el día de pago mensual se deriva de su
  día del mes (se eliminó el campo "Día de pago" separado). Migración 0073:
  columna `fecha_primer_cobro` + backfill con la fecha que el sistema ya
  calculaba (no cambia cuotas existentes) + `generar_cuotas_contrato` reescrita
  para anclar el período inicial al primer cobro (idempotente). Mes completo,
  sin prorrateo. schema v13→14.
- *Expectativa:* la primera cuota vence en la fecha elegida; las siguientes,
  mensuales en el mismo día. Editar el primer cobro de un contrato existente
  recalcula solo las cuotas futuras pendientes (trigger 0018), no las pagadas.
- *Archivos:* migración 0073, `schema.dart`, `db.dart`, `contrato_form_screen.dart`.

**Deploy de esta tanda:** migración **0073** + redeploy de **sync rules** +
schema local **v14**. A y B son client-side (solo `flutter run`).


### 2026-05-30 — Código de cliente (C1–C7) + P1–P5

Hilo conductor: varios **settings existían en la base y en la UI pero no estaban
cableados** al comportamiento real (se guardaban y no hacían nada).

| Commit | Ítem |
|---|---|
| `feab367` | Código de cliente — feature base (migración 0071) |
| `6798e27` | C1–C7 — completar el feature tras audit |
| `a19008b` | P1 — rol de cobrador |
| `2f23b19` | P3 foto · P4 pago parcial · P5 recibo |
| `1831096` | P2 — duración inmutable del contrato (migración 0072) |

**Código de cliente (C1–C7)**
- *Error:* los clientes solo se identificaban por nombre/cédula/teléfono — en el
  campo, homónimos indistinguibles y cédula no siempre cargada. El feature base
  estaba a medias (búsqueda sin código, sin normalización, errores poco claros).
- *Fix:* columna `codigo` + `UNIQUE (tenant_id, upper(codigo))`; búsqueda por
  código en las 3 listas; inmutabilidad (solo super_admin edita); normalización a
  mayúsculas; chequeo de duplicado en vivo (debounce + try/catch) con mensaje
  claro; error amigable en duplicado offline; hints actualizados.
- *Expectativa:* ver §1 "Código de cliente".
- *Archivos:* `clientes_repo`, `clientes_list_screen`, `clientes_admin_screen`,
  `global_search_delegate`, `cliente_form_screen`, `admin_shell`, migración 0071.

**P1 — Cambio de rol de cobrador (bug real, silencioso)**
- *Error:* el admin tenía un dropdown de rol, pero el trigger
  `cobradores_freeze_rol` (0066) rechaza el cambio server-side. El `UPDATE` subía,
  el trigger lo bloqueaba y el cambio se **revertía sin aviso** → el admin creía
  haber ascendido a alguien y no pasaba nada.
- *Fix:* dropdown deshabilitado para no-super_admin con aviso; el `UPDATE` local
  excluye `rol`; si el editor es super_admin y cambió el rol, se rutea por la RPC
  `set_cobrador_rol` (validada server-side).
- *Expectativa:* ver §1 "Roles".
- *Archivos:* `cobradores_admin_screen`, `super_admin_repo`, trigger 0066 / RPC 0030.

**P3 — Foto del comprobante obligatoria**
- *Error:* el setting `foto_obligatoria` existía pero no se leía en el cobro; se
  podía confirmar sin foto.
- *Fix:* en `_confirmar()`, si `foto_obligatoria` ON + método requiere comprobante
  + sin foto → bloquea. Scopeado a métodos con comprobante (efectivo no se traba).
- *Archivos:* `cobro_screen`.

**P4 — Pago parcial deshabilitado**
- *Error:* el setting `pago_parcial` no se aplicaba; además el getter tenía un typo
  (`pagoParicialPermitido`) que lo hacía inusable.
- *Fix:* typo corregido (`pagoParcialPermitido`); en `_confirmar()`, si OFF y es
  cobro de una cuota, se exige cubrir el saldo completo.
- *Archivos:* `settings_repo`, `cobro_screen`.

**P5 — Recibo respeta su configuración**
- *Error:* `recibo.titulo`, `recibo.mostrar_adeudado` y `empresa.whatsapp` existían
  pero no se cableaban a ninguna superficie (título no salía, adeudado siempre se
  mostraba, WhatsApp nunca).
- *Fix:* cableados en pantalla + PDF + impresión térmica, recibo simple y
  multi-cuota. (En el PDF se evitó meter un `Builder` de Flutter en el árbol `pw.`
  — no compila; el saldo se calcula como variable local.)
- *Archivos:* `recibo_screen`, `recibo_pdf`, `impresora_service_io/web`.

**P2 — Total del contrato a prueba de futuro (hardening, NO era bug vivo)**
- *Hallazgo:* no hay divergencia entre pantallas (todas dan igual). El único punto:
  el total se derivaba de `precio_mensual × (fecha_fin − fecha_inicio)`,
  recalculado cada vez. Correcto hoy, pero violaría el invariante #5 si a futuro se
  permite editar `fecha_fin` (extensión/renovación).
- *Fix:* columna `contratos.duracion_meses` (migración 0072) + backfill con la
  misma fórmula; el form la fija al crear desde el enum (12/24/NULL); el detalle la
  usa como fuente de verdad (fallback a fechas para contratos viejos). schema v12→13.
- *Expectativa:* ver §1 "Invariantes de dinero".
- *Archivos:* migración 0072, `schema.dart`, `db.dart`, `contrato_providers`,
  `contrato_form_screen`, `contrato_detail_header`.

**Deploy requerido de esta sesión:** migración **0071** (si no estaba) + **0072**,
redeploy de **sync rules** (PowerSync), schema local **v13** (DB fresca al reiniciar).
Los demás fixes (P1, P3, P4, P5, C1–C7 en código) son client-side: solo `flutter run`.
