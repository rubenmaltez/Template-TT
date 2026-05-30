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

### Invariantes de dinero (resumen — ver CLAUDE.md para el detalle)
- `recaudado` = `SUM(pagos.monto_cordobas)` no anulados.
- Total de contrato fijo = `precio_mensual × duracion_meses` (definido al crear,
  **nunca** re-derivado de fechas ni sumando cuotas). `pendiente = total − recaudado`.
- Contrato indefinido: solo "recaudado acumulado", sin pendiente.
- **Consistencia cross-pantalla**: saldo/recaudado dan idéntico en lista de
  clientes, detalle de contrato y reportes.

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
   contrato de doña Rosa: plan + **duración 1 año** → se guarda
   `duracion_meses = 12` y se generan las 12 cuotas.

4. **Campo (cobrador — María).** Sale con el celular (offline-first). Busca
   **"42"** y encuentra a doña Rosa al toque. Abre el cobro de mayo (C$500):
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
