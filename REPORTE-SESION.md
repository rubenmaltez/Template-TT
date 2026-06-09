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

### 2026-06-09 (cont.) — Limpieza de settings + recibo (zonas) + "fuera de rango" gris

Lote de ajustes pedidos por Rubén durante el testing del feature de colores. 7 commits
(`4abbb41`→`567ca45`), branch `claude/new-features-inventory-tickets-and-technicians`,
auditado (2 agentes; 1 MEDIUM corregido). **Requiere correr la migración 0113.**

- **Settings sensibles → solo super_admin.** *Pedido:* permitir pago parcial, multi-cuota, y que
  el cobrador anule/edite cobros no debe verlo el admin del ISP, solo el dueño del SaaS. *Fix:* los 4
  settings (`cobranza.pago_parcial`, `pago_adelantado`, `cobrador_anula_cobros`, `cobrador_edita_cobros`)
  se movieron de la tab Cobranza a **Avanzado** + `_superAdminOnly` + **`editable_por='super_admin'`** en
  DB (0113). *Exp:* el admin no los ve ni los puede escribir (UI + RLS); el super los gestiona en Avanzado.
- **Settings huérfanos ocultos.** *Pedido:* "Pantalla notificaciones" (módulo eliminado) y "Colores
  estados" (fila JSONB que caía en "Otros") no deben aparecer. *Fix:* ambos a `_hidden`. *Exp:* no se
  ven; la card de colores sigue funcionando (lee por getter, no por el render genérico).
- **Depósito quitado.** *Pedido:* depósito = transferencia, dejar solo efectivo/transferencia/tarjeta.
  *Fix:* removido de "Métodos de pago" + de las 2 listas del cobro. *Exp:* el cobrador no lo ofrece; los
  pagos históricos con `metodo='deposito'` siguen leyéndose (enum + reportes/arqueo intactos).
- **BUG: cuotas lejanas en morado.** *Error:* en el detalle de contrato, TODAS las cuotas futuras se
  pintaban morado ("próxima"), incluso a 456 días — el badge ignoraba el rango. *Fix:* se re-agregó
  `estadoVisualCuota` y el detalle de contrato + lista de cobros lo usan con `diasVisibles`. *Exp:* las que
  vencen dentro del rango (5 días) → morado/azul/etc.; **más allá → GRIS "no disponible"** (aún no cobrable).
  `fueraDeRango` color: morado-atenuado → gris (`sinDeudaColor`).
- **Días de cuotas próximas primordial = 5.** *Pedido:* que sea un setting configurable, seedeado en 5 en
  cada tenant (nuevo y existente), `dias_gracia` en 10. *Fix:* migración **0113** (backfill `DO UPDATE` a 5
  + `dias_gracia=10` donde falte + el trigger de alta normaliza a 5 para tenants nuevos). Getter default
  30→5. Relabel "Días de cuotas próximas". *Exp:* el cobrador ve solo cuotas que vencen dentro de N días
  (5 por defecto, configurable); el admin lo ajusta en Ajustes → Cobranza.
- **Recibo: mover bloques entre zonas + reset + WhatsApp al encabezado.** *Pedido:* el WhatsApp debe ir en
  el encabezado; los handles deben mover items entre encabezado/cuerpo/pie libremente; un botón de reset.
  *Fix:* `ReciboBloque` suma `zona` (override del catálogo); menú **⋮ "Mover a zona"** por bloque + botón
  **"Restaurar layout por defecto"**; WhatsApp default → encabezado; `fromRaw` ordena por zona efectiva
  (estable) y los renderers PDF/Bluetooth usan `zonaEfectiva`. *Exp:* WhatsApp aparece arriba; cualquier
  bloque se reubica entre zonas y se refleja en el recibo impreso; el reset vuelve al layout base.
- **Audit (2 agentes):** *MEDIUM* — los 4 settings movidos tenían `editable_por='admin'` en DB (la RLS no
  los bloqueaba); 0113 los marca `super_admin`. *BAJA* — getter muerto `depositoHabilitado` removido. Resto
  limpio (0113 idempotente, recibo zona round-trip estable, switches exhaustivos).

### 2026-06-09 — Colores configurables de estados de cuota (across-app) + fix banner offline

Rubén pidió: (1) en el mapa y la lista de cobros, un cobrador NO debería ver cuotas fuera del
rango configurado (`cobranza.dias_cuotas_visibles`) — solo el admin ve todo; (2) un esquema de
colores por estado, configurable desde Ajustes, aplicado en TODA la app; (3) que el banner de
"sin conexión" deje de parpadear. Implementado en 7 commits (`d648e00`→`5fff9e1`), branch
`claude/new-features-inventory-tickets-and-technicians`, auditado por 2 agentes (limpio salvo
2 LOW ya fixeados). **Sin deploy server-side** (el color es un setting JSONB en la tabla
`settings` que ya sincroniza por `SELECT *`).

- **Estados del mapa: de 4 a 6.** *Antes:* mora / gracia / pendiente (todo lo pendiente en
  azul) / al-día (verde = sin deuda). *Ahora:* mora 🔴 / gracia 🟠 / **vence hoy** 🔵 /
  **proxima** 🟣 (futura dentro del rango) / **fuera de rango** (🟣 atenuado) / **sin deuda**
  (oculto). *Exp:* el pin toma el color de la cuota más urgente del cliente (precedencia
  mora>gracia>hoy>proxima>fuera>sin-deuda); el cobrador ve por defecto solo lo cobrable en
  rango, el admin tiene chip **"Ver todo"** que revela fuera-de-rango + sin-deuda.
  Archivos: `mapa_screen.dart` (query +counts vence_hoy/proximas/fuera_rango, `_estadoDe`,
  `_markerFor`, `_FiltroChips`).
- **Gate por rango (cobrador).** Mapa y lista de cobros del cobrador se limitan a
  `dias_cuotas_visibles`; el admin no (`esAdminView`/`adminMode`). Para cobrar una adelantada,
  el cobrador entra al cliente y la elige. *Exp:* el cobrador no ve cuotas que vencen demasiado
  en el futuro; el admin sí, vía "Ver todo" en el mapa o `/admin/cuotas`.
- **Filtro "Proximas" en la lista de cobros** (`cuotas_list_screen.dart`). *Exp:* chip nuevo
  que muestra las que vencen DESPUÉS de hoy dentro del rango; "Vencen hoy" queda como chip
  aparte (exclusivo de la fecha de hoy, en azul).
- **Colores configurables across-app.** Ajustes → Cobranza → "Colores de estados de cuota"
  (picker de paleta predefinida, sin dependencias nuevas). Setting `cobranza.colores_estados`
  (JSONB `{mora,gracia,hoy,proxima}` → hex). *Exp:* cambiar un color se refleja EN VIVO en
  mapa, lista de cobros, cuotas admin, detalle de contrato y lista de clientes. Si la clave no
  existe, aplican los defaults (🔴🟠🔵🟣); la 1ª edición la crea (upsert). Fuente única de la
  derivación color↔estado: `lib/data/utils/cuota_estado_visual.dart`.
- **Banner offline parpadeaba.** *Error:* el `ref.listen` del `syncStatusProvider` leía el
  estado `AsyncLoading` (cuando el provider se recrea por cambio de DB / invalidación) como
  'online' en falso (`null?.connected == false` → `null == false` → `false`), cancelando el
  banner pendiente u ocultándolo → flash de ~1s. *Fix:* ignorar el estado de carga
  (`status == null → return`) + debounce de salida de 700ms. *Exp:* el banner aparece solo tras
  ~3s de desconexión REAL y no parpadea en reconexiones transitorias (`offline_banner.dart`).
- **Audit (2 agentes):** *F1* — `estadoVisualCuota()` quedó sin callers → removida (sin dead
  code). *F2* — en el detalle de contrato una cuota PARCIAL que vence hoy/futura usaba azul del
  tema → migrada a `colores.hoy`/`colores.proxima` (consistente con la lista). Los 5 buckets SQL
  del mapa se verificaron mutuamente excluyentes (bordes incl. `diasVisibles=0`). Sin tocar
  schema/sync-rules/schema-version.

### 2026-06-08 (cont.) — Audit integral multi-agente + fixes (todo el backlog accionable)

Audit exhaustivo de TODA la app con 11 agentes especialistas (Opus) → reporte
`AUDIT-INTEGRAL-2026-06-08.md`. Veredicto: app sólida (10/10 invariantes de dinero, RLS
completa, SQLite/TZ/rutas limpios). Hallazgos: 1 ALTA + 9 MEDIA + ~25 BAJA. Rubén pidió
"fixear todo, no dejar backlog". Aplicado en 16 commits (`5e0013b`→`a7a2b99`) + 3 agentes de
review confirmaron limpios los cambios de dinero/impersonación/strip. Detalle y estado en §7
del AUDIT.

- **A1 (ALTA):** la tab "Por cobrar" del cobrador mostraba el saldo SIN `cargos_neto` (mismo
  bug F1 ya corregido en admin, replicado). *Fix:* sumar cargos_neto al SELECT + fórmula con
  clamp. *Exp:* el saldo de la lista coincide con el de cobro/recibo/"Por cliente" (regla #10).
- **M1/M2:** "Anular cuota" sobre una PARCIAL no espejaba la cascada del trigger 0023 (anula
  pagos+recibos) → offline el recaudado quedaba inflado; y el diálogo decía lo contrario.
  *Fix:* espejo local de la cascada en una tx + copy honesto. *Exp:* anular una cuota parcial
  saca su pago del recaudado al instante (también offline).
- **M3/M4/B2 (impersonación unificada):** /admin/pagos, /admin/cuotas y los reads de `settings`
  no respetaban la impersonación (el resto del dinero sí). *Fix:* helper `bloqueadoPorImpersonacion`
  en los write-paths + `settings`/`empresaNombre` filtran por tenant efectivo + el dropdown de
  estado del contrato se oculta TODO al impersonar. *Exp:* impersonando no se mueve plata ni
  estado del tenant, y no se mezclan settings de dos tenants.
- **M5/M6:** la pantalla de edición de contrato era inalcanzable (dead code) y su mensaje de
  éxito mentía ("cuotas ajustadas"). *Decisión de Rubén:* borrar. `ContratoFormScreen` es
  create-only; ruta `/admin/contratos/:id/editar` eliminada. *Exp:* para cambiar un contrato se
  cancela y se crea uno nuevo (consistente con B2 terminal).
- **M7:** `invariantes_dinero.sql` (INV11) contaba las cuotas manuales con `contrato_id` → daba
  falso positivo. *Fix:* `AND tipo_cargo_manual IS NULL`. *Exp:* el test de capa-2 ya no marca
  violaciones con data sana (importante: Rubén lo corre post-deploy).
- **M8/B6:** categorías de inventario eran create-only sin historial (violaba el contrato de
  change-log) + duplicado fallaba silencioso al sync. *Fix:* tab "Categorías" con CRUD +
  historial (patrón Proveedores) + pre-check local de duplicado. *Exp:* se renombran/borran
  (guard si hay productos) y tienen su 🕐.
- **M9:** el detalle del ticket mostraba solo la bitácora de dominio (`ticket_eventos`), no el
  audit_log. *Fix:* botón 🕐 de historial de cambios (oculto para el técnico, que no sincroniza
  audit_log). *Exp:* las ediciones de campo del ticket quedan accesibles.
- **B1/B3/B5/B7/B8/B9/B10/B11/B12** + **dead code** (PendingScreen, Cuota.estadoVisual) +
  **doc-drift** (schema v26 real, onboarding eliminado, -6h en reportes): ver §7 del AUDIT.
- **Backlog que QUEDA** (esfuerzo grande / server-deploy / edge teórico): tests, distribución,
  filtro de fechas + retención en /super/logs (RPC), lock de reenviar-invitación, edge cases no
  reproducibles. Detalle en §7 del AUDIT.
- **Deploy:** `0111`+`0112` (Dashboard) → rebuild → `invariantes_dinero.sql`. Tab Categorías =
  UI nueva (sin migración). B7 = solo comentario en sync-rules (sin redeploy). Correr `dart format`.

### 2026-06-08 — Cancelar contrato = dejar de cobrar sus cuotas (saldo a 0) + RLS + B2/A3

Bug (HIGH): **cancelar un contrato NO dejaba de cobrar sus cuotas** — el cobrador las
seguía viendo en "por cobrar", la mora las seguía contando y el saldo quedaba mal. Fix
con decisiones de Rubén: **Opción A** (preservar la plata real), **mecanismo descuento**,
**A3** (bloqueo total de cancelación impersonando) y **B2** (cancelación terminal).
Commits `c9e5667` → `d6b94b0` → `a2aa04a`. Auditado (3 agentes; 2 ALTA convergentes
corregidas).

- **Cancelar contrato (`contrato_detail_screen.dart` `_cancelarYLiquidarCuotas`):** al pasar
  a `cancelado`, en una transacción atómica: (1) el contrato pasa a cancelado; (2) las cuotas
  **pendientes** (sin pago) → `anulada` (la cascada `cuotas_anular_pagos_asociados_trg` es
  no-op, no tienen pagos); (3) las **parciales** (con pago) → se liquidan con un `cargos_extra`
  **'descuento_monto'** por el saldo restante, **+ espejo LOCAL** de `cargos_neto`/`estado`
  (mismo patrón que `pagos_repo`) → la cuota queda `pagada` al instante (también offline). El
  pago YA cobrado se **PRESERVA** como recaudado (invariante #4). **NO se anula la parcial**
  (anularla revertiría su pago vía la cascada = borraría plata real).
  **Expectativa:** tras cancelar, las cuotas del contrato desaparecen de todas las superficies
  por-cobrar/mora (filtran `estado IN ('pendiente','parcial')`), el recaudado real no cambia,
  y el resumen del contrato muestra **"Total recaudado" / Pendiente 0** (no `total−recaudado`).
- **Resumen del contrato (`contrato_detail_header.dart` `_ContratoResumen`):** un contrato
  cancelado muestra solo lo recaudado (Pendiente 0). Antes mostraría `total−recaudado` (falso
  para un contrato terminado antes de término).
- **RLS — `0111_cuotas_cobrador_no_desanular.sql`:** el trigger `cuotas_check_cobrador_update`
  (0022) bloqueaba poner `estado='anulada'` pero NO el camino inverso. Ahora también bloquea
  que un cobrador cambie una cuota **DE** `anulada` a otro estado (revivirla). Server-side puro.
  **Expectativa:** el cobrador no puede des-anular cuotas vía su policy; solo el admin.
- **Mora — `0112_mora_resolver_al_anular.sql`:** `resolver_notificacion_al_pagar` (0008)
  resolvía la notificación de mora solo al `pagada`. Ahora también al `anulada` → cancelar un
  contrato en mora limpia su mora (panel admin + badge cobrador). **Offline:** la resolución es
  server-side → el badge tarda en limpiarse hasta el sync (la cuota local sí desaparece ya).
- **A3 (impersonación):** cancelar un contrato se **bloquea** mientras el super_admin
  impersona (opción oculta del menú + guard en `_cambiarEstado`). Liquidar parciales generaría
  un `cargos_extra` atribuido a la fila System del super_admin (mismo criterio que cobro/cargo/
  visita). **Expectativa:** impersonando no se cancela; mensaje "hacelo desde la cuenta del
  admin del tenant".
- **B2 (terminal):** un contrato `cancelado` **no se reactiva** — el dropdown de estado
  desaparece cuando ya está cancelado. Para reanudar servicio se crea un contrato nuevo.
- **Gap cerrado (`contrato_form_screen.dart`):** el form de edición tenía un switch
  "activo/cancelado" que cancelaba **sin** liquidar cuotas (el bug viejo) y permitía reactivar
  (rompía B2). Se quitó; el UPDATE del form ya no escribe `estado`. De paso arregla que editar
  un contrato `completado` lo pasaba a `cancelado`. **El estado del contrato se gestiona ahora
  SOLO desde el dropdown del detalle.**
- **Audit (3 agentes) — 2 ALTA corregidas:** (1) faltaba el espejo local → offline la parcial
  quedaba `parcial` con saldo>0 (corregido); (2) cancelar impersonando metía un cargo
  cross-tenant (corregido vía A3). + reentrancy guard anti doble-tap.
- **Deploy:** correr `0111` y `0112` (en orden) por Dashboard. **Sin** bump de schema ni
  redeploy de sync rules (server-side puro). Rebuild de la app por el código Dart. Correr
  `invariantes_dinero.sql` post-deploy (toca dinero).
- **Backlog (BAJA):** `aplicado_en`/`anulada_en` usan hora local (no UTC) — consistente con
  `aplicar_cargo`/`_anular`; normalizar junto si algún día se ataca.

### 2026-06-07 (cont. 13) — Reportes: listado de clientes en Excel (padrón) + bug de dinero descubierto

Pedido de Rubén: exportar la lista de clientes (activos **e** inactivos) con su info, en
Excel formateado como los reportes de cobro. Commit `00d0159`. Auditado (1 agente, foco
en dinero): **padrón SAFE**.

- **Padrón de clientes (feature):** no había un export del roster de clientes (los reportes
  de clientes existentes son financieros: "Estado de clientes" y "Clientes inactivos"). Fix =
  nueva opción **"Listado de clientes"** en `/admin/reportes` → Exportar a Excel: TODOS los
  clientes (activos + inactivos, columna Estado) con Código/Nombre/Cédula/Teléfono/Dirección/
  Referencia/Comunidad/Cobrador/Plan(es)/Día de pago/Saldo/Fecha de alta. **Una fila por
  cliente**; plan/día/saldo vía **subqueries correlacionadas** (no multiplican el saldo por
  contratos ni cuotas). El saldo usa `cuota.monto_pagado` denormalizado (invariante #7), no
  un JOIN a pagos. Reusa `descargarExcel` (mismo diseño). Cero schema/migración/dependencia.
  **Expectativa:** el admin baja un .xlsx con el padrón completo, saldo sumable en Excel.
- **⚠️ BUG DE DINERO PRE-EXISTENTE descubierto (NO arreglado — pendiente de decisión):** el
  reporte **"Estado de clientes"** (`case 'clientes'`, reportes_admin_screen.dart:1051-1067)
  hace `LEFT JOIN pagos` (para `MAX(fecha_pago)`) que **fan-outea las cuotas**: una cuota
  `parcial` con N pagos no-anulados aparece N veces → su saldo y el conteo de pendientes se
  suman **N veces** → **saldo INFLADO**. Viola el invariante #10 (consistencia cross-pantalla:
  este reporte no coincide con el padrón nuevo ni con la verdad por-cuota). **Fix sugerido:**
  computar saldo/pendientes con subqueries correlacionadas (como el padrón) y `ultimo_pago`
  con un subquery escalar aparte, sacando el JOIN que fan-outea. Correr
  `invariantes_dinero.sql` después. Decisión de Rubén si lo atacamos.

### 2026-06-07 (cont. 12) — Calidad de campo (checklists + firma) + Inventario v2 (stock mínimo + código de barras)

Dos features v2 aprobadas con la consigna de Rubén de **mantenerlo simple** (lección de
Nodos). Migración **0110** (3 columnas en tablas existentes, **schema v26**) + 4 slices.
Commits `df1cd3b`→`6a8e824`. Auditadas por 3 agentes (DB+checklists · firma+barcode ·
Dart cross-cutting): **0 ALTA/MEDIA**.

- **Checklists por tipo (slice A):** no había forma de estandarizar los pasos del trabajo
  de campo. Fix = `ticket_tipos.checklist_template` (JSONB, el admin define los pasos) +
  `tickets.checklist` (JSONB **snapshot al crear**, `[{texto,hecho}]`) + sección de
  checkboxes en el detalle. **Expectativa:** el técnico tilda los pasos (progreso X/Y),
  queda registrado; editar el template de un tipo NO altera los tickets ya creados (cada
  ticket es dueño de su copia → sin drift). El tick no ensucia el change-log (fuera del
  allowlist).
- **Firma del cliente (slice B):** no había prueba de servicio. Fix = `SignaturePad` propio
  (RepaintBoundary + CustomPaint → PNG, **sin dependencias**); se sube como un
  `ticket_adjunto` con descripción "Firma del cliente" (reusa el bucket/sync/RLS/audit de
  adjuntos, **cero schema nuevo**). **Expectativa:** al resolver, el técnico captura la firma
  (dedo en Android, mouse en Windows); se ve en la galería de adjuntos. Requiere conexión
  para subir (igual que las fotos).
- **Stock mínimo (slice C):** no había alerta de quiebre de stock. Fix =
  `inv_productos.stock_minimo` (campo en el form) + la tab de Existencias resalta en rojo los
  bajo-mínimo + **badge** en el item "Inventario" del menú (`inventarioStockBajoCountProvider`,
  derivado del ledger igual que la tab, offline). **Expectativa:** el admin ve el número de
  productos bajo-mínimo de un vistazo y "mín N" en la lista.
- **Código de barras (slice D):** los seriales se tipeaban a mano. Fix = `mobile_scanner`
  (única dep nueva) + botón "Escanear" en el ingreso de seriales que agrega el código leído.
  Gateado a **Android** (Windows/web ocultan el botón → tipeo manual). **Expectativa:** el
  serial/MAC del equipo se carga escaneando su código de barras.
- **Fixes del audit (`6a8e824`):** `_scanSoportado` solo Android (iOS sacado: no es target y
  le falta el `NSCameraUsageDescription` → habría crasheado al tocar el botón) · `stock_minimo`
  agregado al allowlist/catálogo/label del change-log (editar el mínimo ahora es trazable).
- **By-design / pendiente de Rubén:** firma online-only (= fotos) · `mobile_scanner` no tiene
  impl de Windows → el gating lo oculta, pero **Rubén debe correr `flutter pub get` +
  `flutter build windows --release`** (el lockfile no se regeneró) para confirmar que el build
  pasa con el plugin no-registrado (esperado, como `image_picker`). ⚠️ Deploy: sumar `0110` a
  la corrida de migraciones.

### 2026-06-07 (cont. 11) — SLA accionable (v2): badge del admin + auto-cierre

Feature v2 sobre tickets, aprobada con la consigna explícita de Rubén de **mantenerlo
simple** (la lección de Nodos: una feature "simple" que se complicó por entidades/vínculos
nuevos). Propuesta formal con la decisión tomada hacia lo mínimo funcional. Commits
`d785912` (slice 1) + `8b9a099` (slice 2). Auditados SAFE (slice 2 con agente dedicado a
la migración/cron). **Cero entidades/columnas/vínculos nuevos.**

- **Escalación = visibilidad para el admin (slice 1, derivado, cero migración):** error =
  el countdown de 3E es informativo, pero el admin no tenía forma de saber *de un vistazo*
  cuántos tickets están venciendo sin abrir la lista. Fix = badge con la cuenta de
  vencidos + por vencer en el item "Tickets" del menú admin (rail + drawer), reusando
  `ticketsEnRiesgoCountProvider` de 3E (en el admin cuenta los del tenant; el conteo se
  watchea en el build del rail/drawer, no inline). **Expectativa:** el admin ve "3" en
  Tickets → entra → los rojos saltan a la vista → reasigna. Derivado/offline, sin cron.
- **Auto-cierre de resueltos (slice 2, server):** error = los tickets `resuelto` se
  acumulan esperando un cierre manual. Fix = migración **0109**: función
  `tickets_auto_cierre(p_tenant_id)` (SECURITY DEFINER per-tenant, patrón del cron de mora)
  que pasa `resuelto→cerrado` los que llevan > N días sin reapertura, con evento de
  bitácora (autor "Sistema", `hecho_por` NULL) — vía un CTE data-modifying (un evento por
  ticket cerrado). Cron diario 06:30 UTC. N = setting `tickets.auto_cierre_dias`
  (**0 = OFF por defecto** → cero sorpresas; el admin lo prende en la pantalla de Tipos).
  **Expectativa:** un ticket resuelto que nadie reabre en N días se cierra solo, con
  rastro en la bitácora; es **reversible** (`cerrado→reabierto` sigue válido); el cambio
  baja por sync (offline → se ve al reconectar). **Sin tabla/columna nueva** → sin bump de
  schema ni redeploy de sync rules (usa estado/resuelto_en/cerrado_en que ya sincronizan).
- **Por qué NO se complicó (decisión de diseño):** la escalación quedó **derivada en el
  cliente** (reusa la math de 3E) → **no hubo que portar el SLA efectivo a SQL** ni seedear
  el default de prioridad server-side. Sin push/WhatsApp/inbox, sin auto-subir prioridad,
  sin columna `escalado_en`. ⚠️ Deploy: agregar `0109` a la corrida de migraciones de Fase 3.

### 2026-06-07 (cont. 10) — Cierre de Fase 3: audit integral + fix del trigger de consumo

Audit integral de cierre de toda la Fase 3 (3A→3E) con 4 agentes paralelos
(DB/schema/sync/RLS · Dart cross-módulo · dinero+audit-log · aislamiento+offline).
**Veredicto: Fase 3 sólida, 0 ALTA.** Dinero hermético, sin fuga cross-tenant /
role-bypass / offline-breaker, cadena DB↔schema↔sync íntegra, audit-log completo.
Commit `3cbd148`. 1 MEDIA + cleanups aplicados (resto LOW/by-design → backlog).

- **Hueco de custodia intra-tenant en el consumo de materiales (MEDIA):** error = el
  trigger `ticket_materiales_consumo` (0106) validaba co-tenencia pero NO que el serial
  estuviera EN la ubicación de origen declarada → un insert crafteado podía instalar un
  serial de la custodia de otro técnico; y en un dup offline del mismo serial el
  `inv_movimientos` se insertaba igual (doble-descuento). Fix = reordenar (UPDATE del
  serial primero, con guard `ubicacion_id IS NOT DISTINCT FROM ubicacion_origen_id` +
  `estado='en_stock'`) e insertar el movimiento SOLO si se consumió (`IF NOT FOUND THEN
  RETURN NEW`). Re-auditado SAFE. **Expectativa:** sólo se consume un serial de donde
  realmente está; el ledger queda consistente; el 2º consumo offline del mismo serial es
  no-op (sin RAISE → no traba la cola de upload). Granel sin cambios (tolerancia negativa
  por diseño). ⚠️ 0106 cambió → re-deployar (idempotente, `CREATE OR REPLACE`).
- **Constante muerta (BAJA):** `kTicketEstados` estaba definida y nunca usada → borrada.
- **Label de prioridad en el change-log (LOW):** `tickets.prioridad` no tenía value-label
  → agregada la branch en `_fmtField` (Baja/Media/Alta/Urgente), así no se filtra el slug
  crudo si en el futuro se expone el history del audit_log de tickets.
- **Backlog documentado (no bloquea):** surface de history del audit_log de tickets ·
  huérfano de Storage al borrar adjunto offline (= comprobantes) · enforcement de custodia
  full para granel · guard serial-sin-cliente en el trigger · comentarios de versión de
  schema en headers de migración (cosmético).

### 2026-06-07 (cont. 9) — Fase 3 slice 3E: cuenta regresiva de SLA (offline)

Slice 3E reframeado con Rubén + un agente experto en ticket-management: el pedido
real no era una "bandeja de notificaciones" sino **ver el tiempo de vencimiento de
cada ticket, contando en vivo y OFFLINE**. Decisiones aprobadas: **SLA híbrido
"min(tipo, prioridad)"** y **notificaciones lean (badge derivado, sin tabla)**.
Commits `a523157` (feature) + `c1a9869` (fixes del audit). **SIN migración / sin
bump de schema / sin redeploy de sync rules** — usa columnas y un setting que ya
sincronizan a ambos buckets. Auditado (3 agentes: code+DB · QA · UX), 0 bloqueantes.

- **Cuenta regresiva viva del SLA** (feature central): error previo = el chip solo
  mostraba un ESTADO ("Por vencer") sin el tiempo restante. Fix = `ticketSlaRestante`
  + `formatSlaRestante` + widget `TicketSlaCountdown` (`Timer.periodic`, 1min en listas
  / 1s en detalle). **Expectativa:** cada ticket asignado muestra "2h 15m restantes" →
  ámbar "por vencer" → rojo "vencido hace 30m", **tickeando sin conexión** (es
  `DateTime.now()` + la fila local; nada toca la red). En espera → "SLA pausado" (no
  tickea); sin SLA / cerrado → no muestra chip de SLA.
- **SLA por prioridad** (pedido explícito "alta → 1h, baja → 12h"): error previo = el SLA
  era solo por TIPO; la prioridad era una etiqueta muerta. Fix = `slaHorasEfectivas` =
  **menor entre el SLA del tipo y el de la prioridad** (nulls ignorados) + setting
  `tickets.sla_horas_por_prioridad` (default urgente1/alta2/media6/baja12) + editor en la
  pantalla de Tipos. **Expectativa:** un ticket *alta* se aprieta a ~1-2h aunque el tipo
  permita más; uno sin prioridad cae al SLA del tipo. El admin edita las horas y el técnico
  las ve tras sincronizar settings.
- **Badge "en riesgo" del técnico** (notificación lean): no había aviso de vencimiento
  inminente. Fix = `ticketsEnRiesgoCountProvider` → badge rojo en la tab "Mis tickets" =
  count(porVencer + vencido), recomputado por sync **y cada 60s** (el paso del tiempo solo
  ya cruza un ticket a "por vencer"). **Expectativa:** el técnico no se pierde un ticket
  asignado (aparece solo en su lista vía el bucket) ni un vencimiento inminente (badge).
- **BUILD-BREAK PRE-EXISTENTE corregido** (regresión de `ab8f5b0`/3D): error = `ticket_detail_screen`
  llamaba `_chip`/`_row` que **no estaban definidos en ningún lado** → la app no compilaba.
  Fix = restaurar los dos helpers (estilo espejado de `cliente_detail`). Barrido de
  tickets/tecnico/incidentes: no hay otros casos. **Expectativa:** la app compila y el
  detalle del ticket renderiza chips + filas como siempre.
- **Semáforo del SLA invertido** (fix del audit UX): error = `slaColor` mapeaba `enPlazo`
  al AZUL de marca (`primary`) y `pausado` al VERDE (`tertiary=success`) → "en plazo" se
  veía azul y "pausado" verde (señal invertida). Fix = verde (`c.tertiary`) en plazo,
  ámbar (`amber.shade700`, espeja "En gracia") por vencer, rojo vencido, **gris neutro**
  pausado. `slaColor` ahora solo alimenta el countdown → cambio localizado. **Expectativa:**
  el semáforo verde→ámbar→rojo es real; un SLA congelado nunca se ve "ok".
- **Legibilidad** (fix audit UX/QA): `formatSlaRestante` rolea a días arriba de 24h ("2d 3h"
  en vez de "50h") + modo `compact` (listas muestran "2h 15m" sin "restantes"; detalle full);
  chip pausado dice "SLA pausado" (no duplica el chip de estado "En espera"). Editor con
  `digitsOnly` + nota de que el SLA aplica también a tickets ya creados.
- **By-design (no re-flag):** el default-map de prioridad aplica a tickets YA creados (uno
  viejo abierto puede nacer "vencido" — correcto, ES el punto del SLA; hay nota en el editor) ·
  `created_at` device-local-naive (pre-existente, consistente con `fecha_pago`, offline-correcto) ·
  `appSettingsProvider` re-dispara el provider del badge en cualquier cambio de settings (sin
  leak, solo trabajo redundante; memoizar el map es v2).

### 2026-06-07 (cont. 8) — Fase 3 slice 3D: incidentes (outages)

Slice 3D aprobado (FASE3-PLAN.md; mapa de outages DIFERIDO por decisión de Rubén).
Migraciones **0107** (incidentes + FK tickets) y **0108** (alcance_label, fix del audit),
schema **v23→v25**. Auditado con **3 agentes** (DB/RLS/sync · cross-módulo/lifecycle ·
Dart/UI): **0 ALTA**, 1 MEDIA corregida.

**Comportamiento esperado:**
- El admin (módulo tickets) entra a **Incidentes** (`/admin/incidentes`), registra un corte
  con un **alcance**: general, o por nodo / hub / puerto (dropdowns en cascada). El técnico
  NO ve ni crea incidentes (admin-only: RLS `is_admin_or_tickets` + router + sin sync).
- El detalle muestra los **clientes afectados DERIVADOS de la topología de red**
  (clientes.puerto_id → red_puertos.hub_id → red_hubs.nodo_id), los **tickets agrupados**
  bajo el incidente, y un botón **resolver** (estado→resuelto, fin=ahora).
- Los tickets se vinculan a un incidente: al crear (picker de outages abiertos) o, para
  uno ya creado, con la acción **"Vincular a incidente"** en el detalle del ticket (el
  flujo real es: entran tickets → el admin nota que es un corte → lo declara y los agrupa).
- Un incidente resuelto conserva sus tickets vinculados (histórico). El dinero NO se toca.

**Errores → fixes (audit):**
- **Ambigüedad de etiqueta del alcance (MEDIA, `5d8a218`)**: el alcance es FK ON DELETE
  SET NULL; al borrar el nodo/hub/puerto, un incidente histórico se leía como "corte
  general (todos los clientes)". Fix = columna **`alcance_label`** (snapshot al crear); la
  UI prefiere el nombre vivo del FK (maneja renombres) y cae al snapshot si el FK quedó
  NULL. **Expectativa**: un "Corte puerto 3" resuelto sigue diciendo "Puerto 3" aunque se
  borre el puerto.
- **No se podía agrupar un ticket preexistente (alto valor, `5d8a218`)**: `incidente_id`
  sólo se seteaba al crear el ticket. Fix = acción "Vincular a incidente" en el detalle.
  **Expectativa**: cubre la secuencia real (tickets-primero, corte-después).
- **Corte general sin filtro de tenant (defensa, `5d8a218`)**: la derivación de afectados
  en un corte general consultaba `clientes WHERE activo=1` sin `tenant_id`. Fix = filtro
  explícito de tenant. **Expectativa**: consistente con el resto (aunque el SQLite local ya
  es mono-tenant, no hay leak).

**Cierre de backlog 3C** (en este slice, `ab8f5b0`): el consumo de material **serializado**
se bloquea si el ticket NO tiene cliente (outage) — no se instala un equipo "a nadie".

**Accepted (no re-flag):** índice por scope (perf, ISP chico) · `_evento` duplicado en
ticket_form/detail (preexistente) · lista de afectados cap visual 50.

Commits: `5d43dd9` (datos) · `ab8f5b0` (UI + cierre 3C) · `5d8a218` (fixes audit).
Archivos: `0107_incidentes.sql` + `0108_incidente_alcance_label.sql` (nuevos) ·
`incidentes_screen.dart` + `incidente_detail_screen.dart` (nuevos) · `ticket_form_screen.dart` ·
`ticket_detail_screen.dart` · `ticket_materiales_widget.dart` · `router.dart` · `admin_shell.dart` ·
`schema.dart` · `db.dart` · `sync-rules.yaml` · `audit_changelog.dart`.

### 2026-06-07 (cont. 7) — Fase 3 slice 3C: materiales (engancha inventario)

Slice 3C aprobado (FASE3-PLAN.md D1 + decisiones de Rubén: 3C completo, trazabilidad
vía ticket_materiales). Migración **0106**, schema **v22→v23**. Auditado con **4 agentes**
(trigger/inventario/dinero · cross-módulo · sync/RLS · Dart/UI): dinero **hermético**,
**1 ALTA corregida**, resto BAJA.

**Comportamiento esperado:**
- En el detalle de un ticket (admin o técnico), si el tenant tiene el módulo **inventario**
  encendido, aparece la sección **Materiales**. "Agregar" elige: la ubicación-origen (la
  **custodia del técnico** `tipo='tecnico'` automática, o cualquier ubicación para el admin)
  y un equipo **serializado** (de stock en esa ubicación) o **granel** (producto con stock +
  cantidad).
- Al registrar, se inserta `ticket_materiales` (+ evento `'material'` en la bitácora). El
  **descuento de stock es server-side**: un trigger inserta el `inv_movimientos 'consumo'`
  (descuenta del origen) y, si es serial, lo marca **'instalado'** en el cliente del ticket.
  Offline el técnico registra ya; el stock se descuenta al sincronizar ("server gana").
- El equipo instalado vía ticket aparece en **"Equipos instalados"** del cliente (2D) y, al
  cancelar el contrato o desactivar el cliente, en el ofrecimiento de **devolver/retirar**.
- El consumo se ve en: la **bitácora del ticket**, el **cuna-a-tumba del serial**
  (HistorialSerialWidget une `ticket_materiales`). NO se descuenta dos veces ni toca dinero.

**Errores → fixes:**
- **Aislamiento multi-tenant (ALTA, `65fc29d`)**: el trigger SECURITY DEFINER (que saltea
  RLS) validaba sólo el tenant del ticket, no el de producto/ubicación/serial → una fila
  podía referenciar recursos de otro tenant. Fix = validar la co-tenencia de los 3 FK con
  RAISE EXCEPTION. **Expectativa**: imposible crear un material que cruce tenants.
- **Equipos de ticket fantasma al cancelar contrato (cross-módulo, `f349f1f`)**: el consumo
  instala el serial con `cliente_id` pero sin `contrato_id` (el ticket no tiene contrato);
  `equipos_en_baja` filtraba sólo por `contrato_id` → no los ofrecía al cancelar el contrato
  (sí al desactivar el cliente). Fix = el barrido de cancelación de contrato ahora incluye
  los equipos del MISMO cliente sin contrato. **Expectativa**: ningún equipo instalado vía
  ticket queda fantasma; el admin lo ve y decide (ofrecimiento no bloqueante).
- **Botón "Registrar" de granel sin validar cantidad (BAJA, `65fc29d`)**: quedaba habilitado
  con cantidad vacía/0 y hacía no-op silencioso. Fix = se habilita sólo con cantidad >0 +
  listener que reacciona al tipear.

**Accepted/v2 (documentado):** granel offline puede doble-descontar (tolerancia negativa,
por diseño) · serial instalado en ticket-sin-cliente (outage) queda sin cliente (v2) · el
consumo-install no aparece en el change-log del **cliente** (es nieto vía ticket → regla de
profundidad; sí aparece en el del serial + el ticket).

Commits: `56c2a49` (datos) · `3393461` (UI) · `65fc29d` (fixes audit) · `f349f1f` (cross-módulo).
Archivos: `0106_ticket_materiales.sql` (nuevo) · `ticket_materiales_widget.dart` (nuevo) ·
`ticket_detail_screen.dart` · `historial_cambios_widget.dart` · `equipos_en_baja.dart` ·
`audit_changelog.dart` · `schema.dart` · `db.dart` · `sync-rules.yaml`.

### 2026-06-07 (cont. 6) — Fase 3 slice 3B: rol técnico (shell móvil + resolución)

Slice 3B aprobado (FASE3-PLAN.md D3) — el rol `tecnico` ya es asignable y operable.
**SIN migración** (sólo redeploy de sync rules; schema v22 estable). Auditado con 3
agentes (sync-rules · router/roles/regresión · Dart/regresión): **0 ALTA/MEDIA**.

**Comportamiento esperado del técnico:**
- El super_admin asigna el rol `Técnico` a un miembro desde el picker (necesita el
  módulo `tickets` encendido en el tenant). El admin (o admin completo) crea tickets y
  se los asigna a un técnico.
- El técnico loguea y entra a su **shell móvil-first** (`/tecnico`): bottom-nav
  **Mis tickets · Mapa · Perfil**. Es offline-first como el cobrador.
- **Mis tickets**: ve SÓLO sus tickets asignados (el bucket `por_tecnico_tickets` ya
  los acota — el SQLite local no tiene otros). Filtro Activos/Cerrados. Badges de
  estado + SLA. Tap → detalle.
- **Detalle** (`/tecnico/tickets/:id`, push con back): puede **avanzar / pausar /
  resolver** (en_progreso · en_espera · resuelto — `kEstadosDestinoTecnico`), comentar
  y adjuntar fotos. NO puede reasignar ni cerrar/cancelar/reabrir (eso es del admin).
  El server re-valida la transición (trigger 0103) y la RLS (`is_ticket_staff`) permite
  su escritura.
- **Mapa**: ve en el mapa SÓLO los clientes de sus tickets (sin filtros de admin, sin
  datos de cobranza — el técnico NO ve dinero). **Perfil**: su nombre/rol, impresora,
  caché del mapa, cambiar contraseña, cerrar sesión (sin prefijo/historial-de-cobros/
  fotos-de-comprobantes, que son del cobrador).
- **Contención**: el técnico NO accede a /admin, /super, al shell del cobrador, ni a
  pantallas de dinero (cobro/recibo/historial/detalle-de-cliente). El router lo rebota
  a `/tecnico`; además el sync NO le baja contratos/cuotas/pagos (doble defensa).
- **Loop completo**: admin crea+asigna → técnico resuelve offline → sincroniza (FIFO,
  el trigger de pausa SLA corre server-side) → admin ve `resuelto` y **cierra**.

**Decisiones / accepted (no re-flag):**
- `admin_tickets` se DIFIRIÓ (no expuesto en el picker, sin shell/bucket → no hay login
  roto). Su shell acotado en AdminShell es un slice propio.
- Título por-tab del AppBar cae al nombre del ISP (idéntico al `AppShell` del cobrador
  ya shippeado — no es regresión; el bottom-nav ya indica la tab).
- `por_tecnico` baja todos los campos de cobradores del tenant (consistente con el
  bucket admin; la own-row los necesita para `Cobrador.fromRow`).

Commit: `9ca9fdc`. Archivos: `sync-rules.yaml` · `tenant_dialogs_miembro.dart` ·
`ticket_sla.dart` · `ticket_detail_screen.dart` · `perfil_screen.dart` · `mapa_screen.dart`
· `router.dart` + nuevos `tecnico/tecnico_shell.dart` · `tecnico/mis_tickets_screen.dart`.

### 2026-06-07 (cont. 5) — Fase 3 slice 3A: vaciado de backlog + audit (pre-3B)

Antes de arrancar 3B se vació TODO el backlog de 3A (pedido de Rubén: "no dejar
ningún ítem en backlog, todo fixed y auditado antes de la siguiente fase").
Auditado con 2 agentes (Code+offline-safety · DB-integrity+QA).

- **Coalescing de transiciones offline (era ALTA "verificar"):** error supuesto = si
  PowerSync junta varios saltos del mismo ticket en un PATCH con el estado final, el
  trigger de transición (0103) lo rechaza. **Verificado FALSO POSITIVO** (docs PowerSync
  + WebSearch): la cola CRUD es **FIFO y NO coalescea** updates a la misma fila; cada
  `_cambiarEstado` es su propia tx → su propia op CRUD subida en orden. → sin cambio de
  trigger. **Expectativa:** un técnico que mueve un ticket por varios estados offline
  sincroniza cada salto en orden; el server los valida uno por uno.
- **SLA pausa exacta** (antes "v2"): error = la pausa solo contaba si el ticket estaba en
  espera AHORA (no sumaba tramos pasados). Fix = **migración 0105**: columnas
  `tickets.segundos_pausado` + `en_espera_desde`; el trigger de transición acumula el
  tiempo en `en_espera` usando el **device-time `ocurrido_en`** de cada transición
  (offline-safe, FIFO server-side); el SLA derivado en el cliente suma `segundos_pausado`
  al plazo. **Expectativa:** el plazo del SLA se "corre" por todo el tiempo que el ticket
  estuvo en espera, aunque la pausa se haya hecho offline; el cliente lo ve al sincronizar
  (trigger server-side). Mientras tanto el plazo local queda conservador (más urgente,
  nunca oculta un vencimiento). Schema **v21→v22**.
- **Lista de tickets — filtro en SQL** (era anti-patrón): error = cargaba TODOS los
  tickets y filtraba por grupo de estado en memoria. Fix = `WHERE estado IN (?)` +
  `LIMIT 300`, el stream se recrea al cambiar el chip de filtro. **Expectativa:** la lista
  solo trae los tickets del grupo elegido (activos/resueltos/cancelados), acotada a 300.
- **Umbral "por vencer" ruidoso** (audit E1, MEDIA): error = `max(20% del SLA, 1h)` hacía
  que un SLA corto (1-5h) naciera directo en "por vencer". Fix = techo del **50% del SLA**
  → un SLA de 1h muestra "en plazo" su primera mitad. **Expectativa:** "por vencer" aparece
  proporcional al plazo, nunca desde el minuto 0.
- **Matriz de transiciones cliente↔server:** verificada **idéntica** (incl. `cancelado →
  reabierto` y `cerrado → reabierto`) — un agente la marcó divergente pero fue falso
  positivo (misleyó el literal). Se agregó comentario aclaratorio.
- **Deferred a v2 (documentado en HANDOFF):** `reabierto` nace vencido (anclar SLA a
  `resuelto_en`) · over-count por clock-skew inter-device · lista sin "cargar más"
  (LIMIT 300) · borrado de adjunto no-atómico (mismo patrón aceptado que fotos_cliente).

Commits: ver abajo. Archivos: `0105_ticket_sla_pausa.sql` (nuevo) · `ticket_sla.dart` ·
`tickets_list_screen.dart` · `ticket_detail_screen.dart` · `schema.dart` · `db.dart`.

### 2026-06-07 (cont. 4) — Fase 3 slice 3A: fundación de Tickets (código completo)

Propuesta aprobada (`FASE3-PLAN.md`); 3A implementado completo (migraciones
0103-0104 + UI). Módulo `tickets` opcional (OFF por defecto). **Comportamiento
esperado:**
- **Roles:** `tecnico` (móvil-first, shell propio en 3B) y `admin_tickets` (admin
  acotado). El super_admin los asigna con `set_cobrador_rol`.
- **Tipos de ticket:** catálogo per-tenant con SLA por tipo. Borrar un tipo en uso
  está bloqueado (FK RESTRICT + guarda client-side).
- **Crear ticket:** tipo + título + cliente (opcional, con búsqueda) + prioridad +
  asignar técnico. Código legible `T-00001` (correlativo MAX+1 por tenant). Al crear
  se registra el evento `creado` en la bitácora; si se asigna, también `asignado`.
- **Estados:** `abierto → asignado → en_progreso → en_espera → resuelto → cerrado`
  (+ reabierto/cancelado). El detalle ofrece SOLO las transiciones válidas; el
  trigger server-side (0103) las re-valida ("server gana"); la UI re-valida el
  estado dentro de la tx para no pisar cambios de otra pestaña.
- **SLA derivado** (en plazo / por vencer / vencido / en espera / cerrado), por tipo,
  con badge en lista y detalle. Pausa si está en espera (pausa exacta = v2).
- **Bitácora** (`ticket_eventos`, append-only): creado/asignado/cambio de estado/
  comentario/adjunto, con autor + fecha, en timeline cronológica.
- **Adjuntos:** fotos a Storage (`ticket-adjuntos`), galería en el detalle, registra
  evento `adjunto`. Requiere conexión.
- **Gating:** módulo OFF → menú oculto + /admin/tickets rebota; admin_cobranza no entra.

**Cadena de integridad:** schema.dart (4 tablas) + sync-rules (admin/impersonado) +
`_schemaVersion` 20→21 + audit_changelog (4 entidades + value-labels). Auditándose
con 3 agentes; fixes al cerrar el slice.

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
  > ⚠️ **Corrección posterior (audit 2026-06-08):** el `-6h` sobre `fecha_pago`
  > se REVIRTIÓ — `fecha_pago` ya se guarda en hora Nicaragua wall-clock, así que
  > el código vigente usa `date(fecha_pago)` RAW y solo el LÍMITE del rango lleva
  > `date('now','-6h')`. NO re-agregar `-6h` a `fecha_pago` (sería doble-shift).

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
