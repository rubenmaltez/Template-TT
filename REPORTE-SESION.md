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
  - `cobranza.audit_visible_admin` ON → el admin del tenant ve el item Auditoría
    (`/admin/audit`) en su menú y accede; OFF → oculto + el router lo rebota a
    `/admin`. El **super_admin la ve siempre** (incluso impersonando), sin
    importar este valor; `admin_cobranza` nunca (gateado por rol).
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

### 2026-06-07 (cont. 3) — Audit integral de Fase 2 + corrección de TODOS los findings

Audit exhaustivo con **7 expertos en paralelo** (uno por módulo + cross-módulo),
con lente de misión/visión e interacción entre módulos. **Cimientos limpios**:
las 10 invariantes de dinero, el aislamiento hermético inventario↔dinero (0 JOINs,
trigger 0083 blindado), la integridad DB↔schema↔sync, y el aislamiento RLS/
impersonación/gating pasaron sin findings. Lo demás se corrigió (grupos A-F):

**Comportamiento esperado (lo nuevo/corregido):**
- **Equipo en baja del cliente:** al cancelar un contrato o desactivar un cliente
  con equipos instalados, la app **avisa y ofrece** devolverlos a stock o
  retirarlos (no quedan "fantasma" instalados en una entidad inactiva).
- **Trazabilidad cuna-a-tumba:** el historial del equipo (Agregador) ahora muestra
  el serial + TODOS sus movimientos (ingreso→asignación→devolución/baja con
  ubicación, proveedor, motivo). El historial del cliente incluye sus equipos; el
  serial dice a quién se asignó. El detalle del contrato muestra sus equipos.
- **MAC:** el ingreso de seriales acepta "serial, MAC" por línea.

**Fixes (error → fix):**
- **A1** (`aa669a9`): `_devolver`/`_darDeBaja` no re-validaban el estado exacto →
  movimiento fantasma en el ledger. Fix: re-validación dentro de la tx.
- **es_serializado** (`aa669a9`): editar el tipo de un producto en uso dejaba
  seriales huérfanos. Fix: guarda si tiene seriales/movimientos.
- **Pickers colgados** (`6cea288`): `red_picker`/`geo_picker` sin try/catch en la
  hidratación → spinner infinito al editar. Fix: try/catch/finally. `geo_picker`
  además alineado al patrón de `RedPicker` (sin watch inline en build).
- **`_cambiarEstado`** (`6cea288`): fallaba en silencio. Fix: try/catch + snack.
- **Fuga cross-tenant geo/red** (`799ca1f`): `SELECT *` sin `WHERE tenant_id` en
  las listas raíz daba la unión System∪impersonado. Fix: filtro por tenant.
- **Trazabilidad** (`1e79006`): `HistorialSerialWidget` Agregador + `cliente_id` en
  allowlist + equipos en log de cliente + sección Equipos en detalle de contrato.
- **0102** (`df5fc56`): guardas de borrado server-side (ubicación/proveedor/puerto/
  comunidad en uso) cascade-safe + ledger `inv_movimientos` append-only estricto
  (super_admin solo SELECT+INSERT). Cierra la orfandad offline multi-device y R1.

**Deploy:** correr 0099-0102 + redeploy sync rules + restart v20. **0102 es
server-side puro** (no toca schema/sync).

### 2026-06-07 (cont. 2) — Vaciado del backlog de inventario + branch única (pre-Fase 3)

Branch ÚNICA `claude/new-features-inventory-tickets-and-technicians` (tip `c89954e`):
reconcilia todo el trabajo y reemplaza a las branches viejas (`nifty-cori-KF2PZ` e
`inventory-tickets-technician-role`, eliminadas — estaban contenidas, nada se perdió).
**Sin migraciones, schema sigue v20.** Auditado por 3 agentes (Code/QA/DB): 0 Alta, 1 Media
(corregida). El objetivo fue **no dejar backlog de inventario antes de empezar Fase 3**.

**Comportamiento esperado (lo nuevo):**
- **Stock por ubicación:** el stock de un producto se puede ver desglosado por ubicación
  (tap en Existencias). En egreso/transferencia, el ORIGEN solo ofrece ubicaciones con
  stock (con la cantidad al lado); sacar más de lo disponible pide confirmación.
- **Costo promedio ponderado:** cada ingreso con costo recalcula `inv_productos.costo_promedio`
  como promedio móvil `(stock·avg + cant·costo)/(stock+cant)`; Existencias muestra costo y valor.
- **Change-log de inventario:** los tipos de movimiento y estados de serial se muestran con
  label humano (Asignación, En stock, Dañado…), no el valor crudo.

**Fixes/decisiones de la sesión:**
- **`44d70e6` value-labels**: el change-log mostraba `asignacion`/`en_stock`/`danado` crudos.
  Fix: `_fmtField` recibe la tabla y traduce `inv_movimientos.tipo` e `inv_seriales.estado`;
  `_labelFor` con íconos/labels propios para ambas tablas.
- **`527ac9e` TOCTOU + connector**: las guardas de borrado tenían una ventana entre el
  pre-check y el DELETE. Fix: `_borrarSiLibre` re-chequea DENTRO del `writeTransaction`.
  `connector.dart` loguea el CRUD rechazado con tipo de op + divergencia.
- **`bcc78c8` costo + stock por ubicación**: ver comportamiento esperado.
- **`bbdb4d3` M2 origen por stock** + **`c89954e` overselling**: el origen de egreso/transf
  se restringe a ubicaciones con stock; si la cantidad supera lo disponible en esa ubicación,
  aviso suave antes de registrar (el modelo permite negativo, pero no en silencio).
- **Decisiones cerradas (no código):** equipo dañado → se mantiene fuera de la ficha (historial
  lo preserva). **R2** (serial offline) → aceptado (UNIQUE server + surfaceo). **R1** (FK puerto)
  → se pliega a Fase 3 (rework de red para tickets).

### 2026-06-07 (cont.) — Inventario 2C-2 (ciclo de movimientos) + 2D (equipos en ficha)

Branch `claude/nifty-cori-KF2PZ` (tip `d380c82`, salió de `6e2b03a`). **Sin migraciones**
(0099-0101 ya cubrían todo); schema sigue en **v20**. Auditado por 3 agentes (Code/QA/DB):
0 bugs de datos. Archivos: `lib/features/admin/inventario/inventario_screen.dart` y
`lib/features/clientes/cliente_detail_screen.dart`.

**Comportamiento esperado (Inventario, módulo opcional admin-facing):**
- **Stock de SERIALIZADOS = nº de seriales en `estado='en_stock'`** (la verdad física del
  equipo manda). Stock de GRANEL = `Σdestino − Σorigen` del ledger `inv_movimientos`.
  Nunca derivar el stock de un serializado del ledger (puede divergir).
- Todo movimiento de equipo (asignar/devolver/transferir/baja) es **atómico**
  (`writeTransaction`: UPDATE del serial + INSERT del movimiento) y **re-valida el estado
  DENTRO de la transacción** antes de mutar (anti doble-acción sobre data stale).
- Un equipo serializado recorre: `en_stock` → (asignar) `instalado` → (devolver) `en_stock`
  / (baja) `danado`/`retirado`/`baja`. `baja` es terminal. Asignar/baja/devolver limpian o
  setean `cliente_id`/`contrato_id`/`ubicacion_id` según corresponda.
- Inventario lo ven SOLO admin/admin_cobranza/super (las tablas `inv_` no sincronizan al
  cobrador). La ficha del cliente muestra "Equipos instalados" solo con módulo activo + rol admin.

**Fixes/features de la sesión (audit del asignar → tramo → fixes del audit):**
- **`580f111` Asignar**: el stock de serializados se inflaba/desinflaba ante doble-asignación
  o serial con `ubicacion_id` NULL (las dos fuentes de verdad —estado y ledger— divergían).
  Fix: stock de serializados = `COUNT(estado='en_stock')` + guard `estado='en_stock'`
  re-validado en la transacción. Además: captura `contrato_id` (auto/`_ContratoPicker`),
  aviso suave si el cliente no tiene `puerto_id`, búsqueda de cliente multi-campo.
- **`c66eea4` Ciclo del serial**: faltaban devolución/baja (instalar era one-way). Fix:
  acciones Devolver a stock (mov `devolucion`+), Transferir (mov `transferencia`), Dar de
  baja (mov `baja`, estado dañado/retirado/baja). Helpers `_pickUbicacion` + `_BajaDialog`.
- **`e554446` Granel**: no había egreso/ajuste/transferencia de productos a granel. Fix: 2º
  FAB en Existencias → `_MovimientoDialog` (egreso −, ajuste ± con motivo obligatorio,
  transferencia origen→destino; valida origen≠destino y cantidad>0).
- **`b33c5be` Guardas de borrado**: producto/ubicación se borraban hard aun con dependientes.
  Fix: bloqueo si hay seriales/movimientos (helper `_contar`).
- **`df266ab` 2D**: la ficha del cliente no mostraba sus equipos. Fix: sección "Equipos
  instalados" (serial/producto/MAC) gateada por módulo + rol admin.
- **`d380c82` Fixes del audit**: (F1) guarda de borrado de proveedor; (M1) el movimiento de
  granel muestra el stock resultante y avisa si quedó negativo; (M5) estado vacío del diálogo
  de granel si no hay productos a granel/ubicaciones; (B3) "Cambiar estado" vs "Dar de baja"
  según el estado del equipo.

**Pendiente documentado (backlog, no bloquea):** stock por UBICACIÓN (hoy global por
producto) · ciclo del equipo dañado-en-casa-del-cliente (Rubén OK con que "dañado" salga de
la ficha; historial lo preserva) · `costo_promedio` ponderado · value-labels de tipos de
movimiento en el change-log · TOCTOU advisory en guardas de borrado (server con FK respalda).

### 2026-06-07 — Fase 2 (Inventario): gating + catálogo + ubicaciones + ledger

Módulo OPCIONAL gateado por `tenant_modulos` ('inventario', es_base=false → OFF
por defecto; super_admin lo habilita en `/super/tenants/:id`). Por slices auditados.
Migraciones **0099** (catálogo: inv_categorias/proveedores/productos + `id` en
tenant_modulos para sync), **0100** (inv_ubicaciones), **0101** (inv_seriales +
inv_movimientos ledger append-only). schema **v20**. Commits `cf32f3d`/`d690c13`/
`5e55f47`/`cf98aa4`.

**Comportamiento esperado**
- **Gating**: el menú/ruta `/admin/inventario` aparece solo si el módulo está ON
  para el tenant (o el impersonado). `modulosHabilitadosProvider` lee
  `tenant_modulos` (synced, filtrado por `tenantIdProvider`, observa `dbEpochProvider`).
  El router rebota `/admin/inventario`→`/admin` si OFF. No lo bypassa el super_admin.
- **Inventario** = pestañas Existencias | Productos | Ubicaciones | Proveedores.
  CRUD + historial en cada catálogo (mismo patrón red/geo). Producto:
  serializado (serial único) vs granel (unidad/decimales).
- **Stock derivado del ledger** (NO se materializa): `Σ(cantidad destino) −
  Σ(cantidad origen)` por producto. **Ingreso** (recepción): serializado→seriales
  uno por línea (unicidad validada), granel→cantidad; crea seriales + movimientos
  'ingreso' **atómicos (writeTransaction)**. `costo_unitario` se guarda; el promedio
  ponderado NO se recalcula aún (backlog).
- Append-only en `inv_movimientos` (RLS solo read+insert). Inventario solo lo ve
  admin; cobrador NO sincroniza inventario (Fase 2 admin-facing; técnico = Fase 3).

**Fixes de audit aplicados**: gating no observaba dbEpoch (stale tras user-switch)
+ filtro por tenant (colisión bajo impersonación) + router gate; ingreso atómico.
**Pendiente** (ver HANDOFF, spec detallada): 2C-2 (asignar equipo a cliente +
egreso/ajuste/transferencia/baja + guardas de borrado) · 2D (equipos en ficha cliente).

---

### 2026-06-07 — Fase 1.1: fixes red + filtro por nodo + editar/eliminar red·geo

Post-testing de Rubén (super_admin impersonando). Commits `a93ab98` (fix puerto),
`3ac3597` (banner), `c2ea65d` (map-picker+notas nodo), `9115a7f` (red editable+
historial), `cb76bab` (geo historial), `c211a38` (filtro nodo), `c03dd8b`
(editar/eliminar). Auditado por agentes con rastreo de data-flow (la ronda
estática previa dejó pasar el bug del puerto).

**Bug del puerto (error → fix → exp)**
- *Error:* el `RedPicker` al elegir Hub dejaba `_puertosStream` en `Stream.empty()`
  en vez de `_watchPuertos(id)` → el dropdown de Puerto nunca poblaba en selección
  fresca → `clientes.puerto_id` se guardaba null. (Bug introducido al "cachear"
  streams; afectaba a TODOS los roles, no era impersonación.)
- *Fix:* `_puertosStream = id==null ? Stream.empty() : _watchPuertos(id)` (espejo
  del patrón Nodo→Hub). *Exp:* elegir Nodo→Hub→Puerto puebla y persiste; el detalle
  del cliente muestra "Red: Nodo → Hub → Puerto".

**Comportamiento esperado — red/geo (lifecycle completo)**
- `/admin/red`: menú por fila **Editar / Historial / Eliminar** en nodo/hub/puerto.
  Nodo con tipo + lat/lng (selección por mapa, reusa `MapaPickerScreen`) + notas;
  hub/puerto con notas. Geografía: mismo menú (antes solo crear+historial).
- **Eliminar = borrado duro con guarda de "en uso"**: no borra si tiene hijas o
  clientes asignados (avisa). Puerto se chequea a mano (su FK es ON DELETE SET NULL).
  Consistente geo↔red, sin soft-delete (evita "valor asignado que desaparece").
- **Historial universal**: nodo/hub/puerto y depto/municipio/comunidad graban en
  `audit_log` (triggers de 0097/0098) y tienen su 🕐/menú de Historial en la UI.
- **Filtro por Nodo** en lista de clientes (chip) y mapa (dropdown), junto a los
  filtros existentes. Cliente conecta a un Puerto → su nodo se deriva por la cadena.
- **Banner de impersonación**: aparece UNA sola vez (gateado por `!enAdminShell`).

**Riesgo conocido (backlog, no bloqueante):** R1 — borrar puerto bajo multi-admin
offline puede nulear `puerto_id` de un cliente en server si la asignación no
sincronizó (SET NULL; recableable). Single-admin no afectado. Ver HANDOFF.

---

### 2026-06-07 — Fase 1: geografía per-tenant + topología de red (Nodo→Hub→Puerto)

Branch `claude/inventory-tickets-technician-role` (sale de `7bc16aa`; backup
`claude/stoic-tesla-cGkJ6`). Primera fase del plan `PLAN-INVENTARIO-TICKETS-RED.md`.
Migraciones **0097** (geografía) + **0098** (red). Schema **v16→17**. Commits
`6f80653`/`32f9bb0`/`26f9705`/`ffb373c`. Auditada por 4 agentes (Code+DB, QA UI, QA
UX, especialista red).

**Comportamiento esperado — Geografía per-tenant**
- `departamentos/municipios/comunidades` pasan de globales a **per-tenant**: cada
  tenant arma la suya; RLS por `current_tenant_id()`; ahora entran al audit log.
- El `geo_picker` (crear inline) y la pantalla de geografía escriben con `tenant_id`.
- Migración: como era data de prueba, **vacía** la geo global y nulea
  `clientes.comunidad_id` (no hay backfill). Para data real habría que replicar+re-apuntar.

**Comportamiento esperado — Topología de red (parte de cobranza base, sin flag)**
- Jerarquía **Nodo → Hub → Puerto** per-tenant. El admin la administra en
  **`/admin/red`** (CRUD anidado, crea inline cada nivel; Nodo tiene tipo
  fibra/wireless/híbrido + lat/lng; Hub/Puerto tienen notas).
- El cliente se conecta a un **Puerto** (`clientes.puerto_id`, opcional) vía un
  **selector en cascada** (solo-selección) en su form. El detalle del cliente
  muestra read-only "Comunidad" y "Red (Nodo→Hub→Puerto)".
- `clientes.puerto_id` es `ON DELETE SET NULL` (recablear/borrar un puerto no se bloquea).
- Decisión: red opcional en el cliente, pero será **requerida** al crear ticket o
  asignar equipos (Fases 2/3).

**Fix de audit destacado (bloqueante de seguridad)**
- *Error:* 0097 dropeaba las policies geo por nombres viejos (`geo_insert_authenticated`)
  pero las reales eran `geo_insert_admins`/`geo_update_admins`/`geo_delete_admins`
  (0016/0067), **sin scoping por tenant** → sobrevivían y un admin podía escribir
  geografía de otro tenant. *Fix:* 0097 dropea los nombres reales. *Exp:* geografía
  escribible solo dentro del propio tenant.

**Pendiente:** deploy (Rubén, Dashboard) + testing. Ver HANDOFF para los pasos.

### 2026-06-06 (cont.) — Reportes con detalle USD + impresora PC + búsqueda mapa + transición + dashboard

Branch `claude/stoic-tesla-cGkJ6`. Lote de UX/reportes pedido por Rubén, **sin
migraciones** (schema v16 intacto; ningún cambio de DB/sync). Auditado con 3
agentes en paralelo (contable + código + QA funcional): 0 bloqueantes, 0
violaciones de invariantes de dinero. Commits: `f0bab7f`, `1860a38`, `c6a3b8f`,
`f1e6935`, `4ccf3f7`, `68577f9`.

**Comportamiento esperado — Detalle de moneda/tasa/vuelto en reportes**
- Reportes **Cobros** y **Por cobrador** (PDF + Excel el de cobros; por_cobrador
  es PDF-only): además del monto, muestran **Moneda** (US$/C$), **Entregado
  (orig.)** (lo que entregó el cliente en su moneda), **Tasa** (solo en pagos
  USD; en C$ va `—`/vacío) y **Vuelto (C$)** (solo si > 0).
- La columna **"Monto cobrado (C$)" / "Total recaudado (C$)" sigue siendo SOLO
  `monto_cordobas` aplicado** (invariante #1/#4 intacto). Los totales NO suman
  entregado ni vuelto.
- Reporte **Fiscal**: ahora agrupa también por `p.moneda` → filas separadas USD
  vs C$, con columna Moneda y **"Total entregado (orig.)"**. Esa columna se
  muestra **solo en filas USD** (dólares físicos que entran); en C$ va `—` para
  no confundir con recaudado+vuelto.
- Los 3 PDF afectados pasaron a **landscape** para que entren las columnas.
- *Por qué:* Rubén necesita ver en los reportes qué se cobró en dólares, a qué
  tasa, y si hubo vuelto — sin que eso distorsione el recaudado.
- *Archivos:* `reportes_admin_screen.dart` (queries + Excel), `pdf/pdf_utils.dart`
  (`monedaSimbolo`/`fmtMontoMoneda`), `pdf/reporte_{cobros,por_cobrador,fiscal}_pdf.dart`.

**Comportamiento esperado — Impresión por impresora del sistema (PC)**
- En el recibo, **solo en desktop** (Windows/Linux/macOS), aparece el botón
  "Imprimir en impresora del sistema" → abre el diálogo nativo de Windows
  (`Printing.layoutPdf`), para imprimir a una impresora **cableada/USB/red**,
  además de la Bluetooth de campo. Tooltip aclara que usa el ancho de rollo
  configurado (pensado para térmica USB). En Android no aparece (usa Bluetooth);
  en web tampoco (usa "Descargar PDF").
- Refactor: `_generarReciboPdf()` comparte la lógica logo+mora entre
  "Descargar PDF" e "Imprimir sistema". *Archivo:* `recibo/recibo_screen.dart`.

**Comportamiento esperado — Búsqueda multi-campo en el mapa**
- El buscador del mapa (lupa) matchea por **nombre, cédula, teléfono (compara
  solo dígitos), código de cliente y código de contrato** — mismos criterios que
  la lista de clientes. El resultado muestra "código · comunidad" para
  desambiguar. *Limitación esperada:* solo busca entre clientes CON lat/lng (es
  el buscador del mapa). *Archivo:* `mapa/mapa_screen.dart` (query + `_matches`).

**Comportamiento esperado — Transición entre vistas**
- Error: el cambio de pantalla del sidebar/nav era un salto brusco. Primer
  intento (`f1e6935`) fue un cross-fade con `AnimatedSwitcher` — Rubén lo vio
  brusco porque **las dos pantallas se veían encimadas** durante el fade.
- *Fix final (`68577f9`):* `_ShellFade` en `router.dart` → **fade SECUENCIAL**:
  la pantalla actual se atenúa a 0, recién ahí se monta la nueva y se atenúa de 0
  a 1 (140ms por fase). **Nunca conviven dos pantallas montadas** (de paso elimina
  el doble `FlutterMap`/stream). Aplica a los 3 shells (cobrador/admin/super).
  *Nota:* cambios en `router.dart` requieren **restart completo**, no hot reload
  (el `GoRouter` se construye una vez en `routerProvider`).

**Otros**
- Dashboard admin: se quitó la card **"Acciones rápidas"** (Rubén no la quería
  ahí). *Archivo:* `dashboard/dashboard_admin_screen.dart` (+ se limpió el import
  `go_router` que quedó sin uso).

---

### 2026-06-06 — Mapa offline + descarga de reportes Excel/PDF + audit exhaustivo

Branch `claude/stoic-tesla-cGkJ6`. Dos features nuevas (sin migraciones, schema
v16 intacto; +3 deps Dart-puras) y un **audit exhaustivo de toda la app** (4
agentes) con 4 fixes de consistencia. Foco de plataforma confirmado: **Android +
Windows** (web ya no es el target; el código degrada en web sin romper).

**Comportamiento esperado — Mapa offline (caché de tiles)**
- El mapa (cobrador + admin + mini-mapa del form de cliente) cachea en disco los
  tiles que el usuario navega CON señal (`flutter_map_cache` +
  `http_cache_file_store`, store de archivos en `getApplicationSupportDirectory`).
  Cache-first (default `forceCache`), expiración 90d, **sin tope de tamaño**
  (decisión de Rubén). Sin señal, las zonas ya vistas se ven; las nunca visitadas
  quedan en gris (NO hay pre-descarga de zona — sprint futuro). Cachea calles
  (OSM) + satélite (ArcGIS) en un store compartido.
- En `/perfil` (nativo, gate `!kIsWeb`): card "Mapa offline" con tamaño en disco
  + botón "Borrar caché del mapa".
- Solo Android/Windows: en web cae a `NetworkTileProvider`; si el init falla,
  degrada a red sin romper el mapa. `MapTileCache` singleton, init en `main.dart`.

**Comportamiento esperado — Descarga de reportes Excel + PDF**
- `/admin/reportes` → FAB "Reportes": cada reporte se baja en PDF (ya existía) y
  en **Excel `.xlsx`** (nuevo, reemplazó el "copiar CSV al portapapeles"). 8
  reportes Excel (cobros, mora, clientes, fiscal, eficiencia, inactivos,
  anulaciones, arqueo). El .xlsx tiene encabezado con color, ancho de columna
  automático y montos como números sumables; fecha en hora Nicaragua.
- Guardado unificado (`guardarArchivo` con `file_picker.saveFile`): Windows abre
  "Guardar como"; Android, el selector de ubicación del sistema (sin permisos);
  web → mensaje claro. Mismo diálogo para Excel y PDF (los 9 PDF migraron de
  `Printing.sharePdf` a `guardarArchivo`).

**Audit exhaustivo (4 agentes, todo el codebase) — 4 fixes de consistencia**
El audit dio la app **SÓLIDA**: 0 bugs de SQL/SQLite, 0 contables (10/10
invariantes), 0 de seguridad/RLS, 0 crashes de stream, rutas OK. Los únicos
hallazgos fueron 4 inconsistencias de presentación Excel↔PDF, todas corregidas:

- **Fecha del PDF en UTC crudo** — los PDF formateaban `fecha_pago` sin restar 6h
  (el Excel sí). *Fix:* los 5 `_formatearFecha` (cobros/anulaciones/clientes/
  inactivos/por_cobrador) aplican `-6h`. *Exp:* el día del PDF coincide con el Excel.
- **Orden de columnas de mora distinto** — PDF tenía Comunidad última; Excel 2ª.
  *Fix:* reordenado el PDF de mora (Comunidad 2ª). *Exp:* mismo orden en ambos.
- **Labels de método en PDF** — daba "Transfer." y "Deposito" sin tilde (faltaba
  el case `deposito`). *Fix:* los 3 PDF (cobros/fiscal/por_cobrador) usan
  `MetodoPago.label` como el Excel. *Exp:* "Transferencia"/"Depósito" completos.
- **Bucketing de reportes sin `-6h`** — `date(fecha_pago) BETWEEN`/`strftime`
  interpretaban el timestamp como UTC, desfasando un pago de medianoche vs el
  dashboard. *Fix:* `date(p.fecha_pago, '-6 hours')` en todas las queries de
  reportes + `RangoReporte` en hora Nicaragua. *Exp:* el corte por día/mes del
  reporte coincide con el dashboard. No afecta totales.

*Archivos:* `map_tile_cache.dart` (nuevo), `descarga_archivo.dart` (nuevo),
`excel/reporte_excel.dart` (nuevo), `reportes_admin_screen.dart`, los 8
`pdf/reporte_*`, `mapa_screen.dart`, `cliente_form_screen.dart`,
`perfil_screen.dart`, `main.dart`, `formatters.dart` (helpers `fechaHoraNi`/
`fechaNi`), `pubspec.yaml`. Sin migraciones (schema v16 intacto). *Pendiente:*
testing en Windows + Android antes del bump de versión.

### 2026-06-05 — Impresión térmica RESUELTA + recibo afinado (v0.7.6 → v0.8.0)

Branch `claude/stoic-tesla-cGkJ6`. Cierre de la saga de impresión: tras dos
fixes fallidos (v0.7.4/v0.7.5), se dejó de adivinar y se **diagnosticó con la
imagen real**. Detalle completo en `ESTADO-APP.md §10.6`.

**Impresión salía negativa / angosta / chica (v0.7.6 diagnóstico)**
- *Error:* el recibo imprimía con fondo oscuro, angosto y letra chica; dos fixes
  previos sobre la IMAGEN no lo resolvieron.
- *Diagnóstico:* se agregó un botón que muestra el PNG crudo de la captura + el
  bitmap final que va a la térmica + métricas. **Reveló que el bitmap era
  correcto** (positivo, ancho completo) → el bug no era la imagen.
- *Expectativa:* poder VER qué se manda a la impresora antes de tocar código.

**Codificación ESC/POS rota (v0.7.7 — fix real)**
- *Error:* `gen.imageRaster` (esc_pos_utils_plus) codificaba mal el bitmap para
  la PT-210 (polaridad/ancho) → negativo + angosto, aunque el bitmap estaba bien.
- *Fix:* `_rasterGsv0` armado a mano — GS v 0 con polaridad explícita (1=negro),
  ancho en bytes correcto y partición en bandas de 255 filas. Diagnóstico con
  A/B de 3 métodos (gsv0 / gsv0 invertido / ESC * columnas). **Confirmado:
  Método A (GS v 0 normal) imprime perfecto en la PT-210.** Letra más grande
  (`baseFont` 58mm 1.5×, 80mm 1.9×, desacoplado del ancho).
- *Expectativa:* el recibo imprime positivo, ancho completo y legible en
  cualquier impresora, online y offline, con tildes (lo renderiza Skia).

**Recibo no aprovechaba el papel (v0.7.8)**
- *Error:* márgenes izq/der grandes, mucho aire vertical, valores que saltaban
  de línea.
- *Fix:* padding h. 24→6px, interlineado 1.3→1.12, gaps a la mitad, padding
  vertical 16→4, avance ESC d 3→2, recorte blanco pad 8→4.
- *Expectativa:* el texto cubre el ancho útil del papel (≈48mm en 58mm; el ~5mm
  por lado restante es zona física no imprimible) y nada salta de línea.

**Totales y mora no se justificaban (v0.8.0)**
- *Error:* COBRADO/VUELTO/PAGADO/TOTAL MORA mostraban el valor a media página,
  rompiendo la armonía del recibo (el resto sí pega el valor al margen derecho).
- *Causa:* en `_totalLine` la etiqueta usaba `Flexible` con flex 1 (default),
  encajonando el valor en ~50% del ancho. Las filas normales usan `flex: 0`.
- *Fix:* `Flexible(flex: 0)` en la etiqueta de `_totalLine` → el valor (Expanded)
  se queda con todo el resto y se justifica al margen derecho.
- *Expectativa:* todas las líneas etiqueta→valor del recibo se justifican igual.

**"Recibo emitido" como entrada separada en el historial (v0.8.0)**
- *Error:* en el historial de la cuota, el recibo emitido aparecía como tarjeta
  aparte de "Pago registrado" (redundante: el recibo se emite en el mismo cobro).
- *Conflicto:* chocaba con CLAUDE.md #5 (recibo en el timeline de la cuota). Se
  consultó a Rubén → fundir la EMISIÓN en el pago, mantener la ANULACIÓN aparte.
- *Fix:* `_construirEventos` (HistorialCuotaWidget) absorbe el `recibos/create`
  cuyo `pago_id` = `registro_id` del pago y muestra el número en el subtítulo del
  card "Pago registrado". La anulación de recibo NO se absorbe (acción posterior,
  rastro de dinero #5). Se agregó `a.registro_id` al SELECT de la query.
- *Expectativa:* un cobro = un card "Pago registrado · Recibo CT-XXXXX"; anular
  un recibo sí genera su propia entrada.

**Notas del cobrador truncadas (v0.8.0)**
- *Error:* las notas del cobro se mostraban cortadas ("...con 1000, vuel…") en el
  change log.
- *Causa:* `_fmt` en `audit_changelog.dart` cortaba todo valor >30 chars con "…".
- *Fix:* tope subido a 500 (el tile del historial ya hace wrap del texto).
- *Expectativa:* las notas se ven completas en el historial.

*Archivos:* `recibo_ticket.dart`, `impresora_service_io.dart`,
`impresora_service_web.dart`, `impresora_diagnostico.dart` (nuevo en v0.7.6,
eliminado en v0.8.1), `recibo_screen.dart`, `historial_cambios_widget.dart`,
`audit_changelog.dart`, `pubspec.yaml`, `version.json`. Sin migraciones (schema
v16 intacto).

**Limpieza post-confirmación (v0.8.1)**
- *Contexto:* Rubén confirmó el recibo impreso en la PT-210 (justificado, ancho
  completo, limpio). El diagnóstico A/B ya cumplió su función.
- *Fix:* se eliminó el botón "Diagnóstico", el `_DiagnosticoDialog`, los métodos
  `imprimirImagenMetodo` (B/C) y `diagnosticar`, `DiagnosticoImpresion` y el
  archivo `impresora_diagnostico.dart`. `imprimirImagen` hace GS v 0 directo
  (`_rasterGsv0` sin el flag `invertir`). 0 referencias colgando.
- *Expectativa:* misma impresión que v0.8.0, sin el botón de diagnóstico.

### 2026-06-04 — Sesión v0.6.4 → v0.7.5 (roles + drift DB + impresión)

Branch `claude/stoic-tesla-cGkJ6`. Sesión larga; resumen ejecutivo (detalle en
`ESTADO-APP.md §10`). Cada batch pasó audits (correctness + offline/QA +
deployment-safety) con fixes antes de commitear.

**Drift Postgres-vs-repo (crítico)**
- *Error:* crear contrato fallaba con "Could not find the 'codigo' column of
  'contratos' in the schema cache" — la migr **0077** (`contratos.codigo`) no
  estaba aplicada en el Postgres del usuario (DB atrás del repo).
- *Fix:* aplicar 0077 + `notify pgrst, 'reload schema'` + redeploy sync rules.
  Query de verificación de drift (information_schema vs `schema.dart`) confirmó
  que era el único faltante.
- *Expectativa:* **al abrir sesión, correr la query de drift** — el Postgres
  puede estar desfasado de las migraciones del repo.

**v0.6.4 — auditoría super-only + quitar onboarding + versión visible + recibo upsert**
- Auditoría oculta al admin por defecto (toggle super-admin, 0089); wizard de
  onboarding eliminado (admin configura desde Ajustes); versión en login/sidebar/
  perfil; toggles del diseñador de recibo persisten (`upsert` + seed 0090).

**v0.7.0 — roles (admin_cobranza) + backlog de testing**
- *Error/pedido:* admin_cobranza no podía crear contratos / editar clientes /
  asignar cobrador / cobrar; admin no podía forzar password; faltaba email en
  Personal; super_admin impersonando no podía invitar; navegación rota en
  Android 11+; botón WhatsApp de más; prefijo solo para cobrador.
- *Fix:* `puedeGestionar` (admin ∪ admin_cobranza) en cliente_detail; prefijo
  para los 3 roles que cobran (+ índice único 0092 + RPC 0093); cobrador en
  detalle de cliente (inline + form); nav con `<queries>` + `launchUrl` directo;
  WhatsApp oculto; `forzar-password-cobrador` acepta admin (su tenant, target
  no-admin) + botón en Personal; email vía RPC `list_cobrador_emails` (0091);
  invitar manda `tenant_id` en impersonación; super_shell escucha errores de sync.
- *Expectativa:* admin_cobranza opera como admin MENOS Settings/Personal/Planes/
  Geo/Audit. Migr 0091/0092/0093 + redeploy de `forzar-password` e `invitar`.

**v0.7.1 → v0.7.5 — IMPRESIÓN del recibo (varias iteraciones)**
- *Error:* la térmica (PT-210, codepage chino GB18030) imprimía tildes como
  chino; el codepage es por-modelo (no universal).
- *Camino:* CP850 (0.7.1, falló) → rasterizar PDF con PDFium (0.7.2, imprimía
  solo el logo: PDFium no renderiza la fuente embebida) → **enfoque definitivo
  (0.7.3): un solo widget `ReciboTicket` (Flutter/Skia) para preview Y impresión
  (captura con `screenshot` → raster ESC/POS)** → fixes de negativo/constraint/
  preview (0.7.4) → fondo blanco sólido + letras más grandes (0.7.5).
- *Fix final (v0.7.5):* el recibo se dibuja con Skia (tildes seguras en cualquier
  impresora, offline; preview = impresión); se captura sobre un **Container
  blanco que cubre todo el targetSize** (no más negativo); `baseFont =
  anchoDots/384` (58mm 1.0×, 80mm 1.5×, legible); 58→58mm estándar; CHECK
  `recibos_ultimo_formato_mm` acepta 58 (migr **0094**+**0095**); sin reimpresión;
  banner "red inestable" no aparece al arrancar. Matemática del dinero del ticket
  = copia exacta del PDF (auditada).
- *Expectativa:* recibo fondo blanco + texto negro legible, tildes/ñ perfectas en
  CUALQUIER impresora (58/80mm), online y offline; preview = lo que se imprime.
  **PENDIENTE DE VALIDAR en impresora real** (si sigue oscuro: dump del PNG
  capturado para inspección).

**Distribución + reset**
- `Install Steps/` (guías numeradas + scripts) y `Releases\vX.Y.Z\` (instaladores
  versionados que se apilan; GitHub usa nombre fijo para el auto-update). Reset
  total de testing (wipe preservando super_admin + System). Ícono Android
  commiteado (fuente `assets/icon/app_icon.png` + mipmaps).

### 2026-06-03 — Release v0.6.4: auditoría super-only + quitar onboarding + fix recibos

Branch `claude/stoic-tesla-cGkJ6`. Commits `401ec78` (base v0.6.4), `a393064` +
`139ff1b` (fix recibos). Cada cambio pasó audit (correctness + QA +
deployment-safety), 0 findings.

**Auditoría oculta para el admin (toggle super-admin por tenant)**
- *Pedido:* el panel de Auditoría no debe ser visible para el admin por defecto;
  el super_admin lo habilita con un toggle en los settings del tenant.
- *Fix:* nueva clave super-only `cobranza.audit_visible_admin` (default OFF,
  migr 0089). El item `/admin/audit` del menú toma `settingKey`; `_menuVisible`
  bypassa el gate para `esSuperAdmin` (el super la ve siempre, incl.
  impersonando). Guard en el router echa al admin de la ruta si el toggle está
  OFF. `admin_cobranza` sigue bloqueado por `soloAdmin`.
- *Expectativa:* admin con toggle OFF no ve Auditoría ni accede por URL; el super
  la prende en Ajustes → Avanzado y reaparece en la sesión del admin sin F5.

**Quitar el wizard de onboarding**
- *Pedido:* el admin no debe pasar por un setup inicial; entra y configura
  empresa/planes desde Ajustes por su cuenta.
- *Fix:* borrado `onboarding_screen.dart` + ruta + redirect forzado +
  `empresaNombreRowExistsProvider` + gate de carga de `admin_shell`.
  `empresaNombreProvider` se preserva (lo lee el reporte).
- *Expectativa:* admin de tenant sin configurar entra directo al dashboard (sin
  flash de wizard) y configura empresa en Ajustes → Empresa, planes en
  Administración → Planes.

**Versión visible en la app**
- *Pedido:* la versión en la que estamos tiene que verse en la app.
- *Fix:* `AppVersionLabel` (lee `package_info`) al pie del sidebar admin (rail +
  drawer), login y perfil del cobrador. `pubspec` → `0.6.4+064`, `version.json`
  → `0.6.4`.
- *Expectativa:* "SITECSA CRM v0.6.4" visible en login, sidebar admin y perfil.

**Fix: toggles del diseñador de recibo no se podían desactivar**
- *Error:* en tenants creados después de la migr 0080, los toggles de
  visibilidad de bloques del recibo "rebotaban" a ON. Causa: el editor guardaba
  con `SettingsRepo.update` (UPDATE puro `WHERE tenant_id AND clave`), pero la
  fila `recibo.layout` no estaba sembrada (el trigger de alta llama
  `seed_settings_default`, que nunca incluyó esa clave — solo se backfilleó en
  0080). UPDATE → 0 filas → no persistía. Igual `recibo.mostrar_cedula` (0079).
- *Fix:* (cliente) el editor pasa a `SettingsRepo.upsert` (SELECT→UPDATE|INSERT)
  en sus 3 call sites (layout, ajustes generales, sub-toggles), con tipo +
  categoria. (servidor) migr 0090: `seed_settings_recibo_layout` siembra
  `recibo.layout` + `recibo.mostrar_cedula`, sumada al trigger de alta +
  backfill de tenants faltantes. Idempotente, sin bump de schema/sync rules.
- *Expectativa:* apagar/prender cualquier bloque del recibo (y los sub-toggles
  cédula/saldo) persiste y sobrevive al reload. Correr 0090 arregla tenants
  viejos al instante, incluso en 0.6.3.

**Reorg de distribución (orden absoluto)**
- *Pedido:* instaladores con la versión en el nombre, apilados en una carpeta
  `Releases\` local, y los comandos en una carpeta `Install Steps`.
- *Fix:* `build-release.ps1` archiva `SITECSA-CRM-vX.Y.Z.msix/.apk` en
  `Releases\vX.Y.Z\` (gitignored, se apila) + Escritorio, y sube a GitHub los de
  nombre fijo (auto-update intacto). Nueva carpeta `Install Steps/` con guías
  numeradas + scripts; se borró la vieja `instalador/` (tenía copias stale de
  los .md canónicos).
- *Expectativa:* cada `build-release.ps1` deja la versión nueva en
  `Releases\vX.Y.Z\` con el número en el nombre, sin pisar las anteriores.

### 2026-06-02 (noche) — Backlog del audit liquidado + tests de `pagos_repo`

Continuación del audit total: se liquidó **todo el backlog accionable** y se
escribió la **primera suite de tests de repo del dinero**.

**Backlog liquidado** (migración 0088 + fixes de código)
- *L2/L3:* RLS de storage `comprobantes-pago` ya no exige extensión `.jpg`
  (acepta cualquier subida del path del tenant); `super_admin_all` agregada a
  tablas que la heredaban implícita.
- *F2:* generación de mora ahora considera `cargos_neto` en el saldo.
- *S2:* `cambiar-email-cobrador` con guard de signOut reforzado.
- *INV11:* nueva invariante SQL — contrato fijo activo tiene exactamente
  `duracion_meses` cuotas (regla #5).
- *Dead code:* eliminado `app_version_label.dart` (huérfano).
- *Expectativa:* `invariantes_dinero.sql` da 11 filas en 0 tras el deploy.

**Tests de `pagos_repo`** (el gap de cobertura #1, ahora cerrado)
- *Error/gap:* el repo que mueve el dinero (`registrarCobro` / `Multiple` /
  `anular` / `editar`) tenía 0 tests de repo — solo la matemática pura
  (`cobro_calculo`) estaba cubierta.
- *Fix:* `test/data/repositories/pagos_repo_test.dart` — **14 tests** contra una
  PowerSyncDatabase REAL (no mocks): cobro completo/parcial/sobrepago-vuelto/USD/
  cargos_extra/multi-cuota/correlativo/anular/editar-guard, cada uno aserta contra
  la DB. Requirió un refactor MÍNIMO de inyección de DB en `pagos_repo`
  (`PagosRepo({db})` → `_dbOrGlobal`), cero cambios de lógica (provider intacto).
- *Setup:* corre con `flutter test` + el core nativo `powersync_x64.dll` (de
  `powersync_flutter_libs`, pub cache) en la raíz del repo. Sin él, los tests se
  auto-saltean con mensaje claro. Documentado en la cabecera del test + gitignore.
- *Expectativa:* `flutter test test/data/repositories/pagos_repo_test.dart` →
  `+14: All tests passed!`. Verde verificado en Windows.

**CI verde + tests del dinero corriendo en CI**
- *Hallazgo:* `ci.yml` estaba en ROJO (pre-existente): 5 tests de `Fmt.periodoRecibo`
  asertaban la vieja "regla del 15", pero la función se reescribió a facturación
  vencida (`mesServicio`). La función está bien; los tests quedaron stale.
- *Fix:* reescritos los 5 al modelo vencida (umbral en día 16 para mes anterior de
  30 días, doble clamp en feb no bisiesto, rollover de año). Además `ci.yml` ahora
  provisiona `libpowersync*.so` del pub cache + `LD_LIBRARY_PATH` (en Linux dlopen
  no busca en el cwd) → los 14 tests de `pagos_repo` CORREN en CI, no se saltean.
- *Expectativa:* `ci.yml` verde en cada push (`210 passed, 0 failed`), con el repo
  de dinero cubierto automáticamente.

### 2026-06-02 (tarde) — Audit EXHAUSTIVO TOTAL (5 agentes) + 2 fixes

Audit completo de toda la app (5 agentes en paralelo: integridad DB, dinero,
correctness frontend, cobertura funcional admin-side, cobertura funcional
cobrador + seguridad). **0 findings CRITICAL/HIGH.** La app está sólida y
consistente end-to-end. Commit `c34479d`. Auditado estático (correr
`flutter analyze` al pull). Sin migración.

**F1 — `/admin/cuotas` mostraba el saldo sin `cargos_neto`** (🟠 ALTA, dinero)
- *Error:* `cuotas_admin_screen.dart:779` calculaba `saldo = monto − pagado`,
  omitiendo `cargos_neto` (cargos/descuentos de la cuota). Las otras ~6
  pantallas (clientes, detalle de contrato, reportes, mora, recibo) usan
  `monto + cargos_neto − pagado`. Ej: cuota C$500 + reconexión C$100, paga
  C$300 → esta pantalla mostraba C$200, el resto C$300. Viola la regla #10
  (consistencia cross-pantalla).
- *Fix:* `saldo = monto + COALESCE(cargos_neto,0) − pagado` (el dato ya venía
  en el SELECT, solo no se usaba).
- *Expectativa:* el saldo de una cuota da idéntico en `/admin/cuotas`, lista de
  clientes, detalle de contrato y reportes.

**S4 — anular del historial sin guard de impersonación** (🟡 LOW, seguridad)
- *Error:* `historial._anular` no chequeaba `estaImpersonandoProvider` (a
  diferencia de cobro/cargo/visita). Bajo impacto (anular es UPDATE benigno que
  no mueve tenant), pero inconsistente.
- *Fix:* guard `estaImpersonandoProvider` al inicio de `_anular`, igual que las
  otras acciones de campo.

**Resto:** todo LOW → backlog (acoplamiento `.jpg` en storage RLS, `super_admin_all`
no-automático, dead code `app_version_label.dart` + migración 0054, coherencia de
reloj del dashboard, gap de invariantes regla #5/#6, hardening de edge functions).
Ver ESTADO-APP §3.

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
