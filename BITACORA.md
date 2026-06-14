# BITACORA.md — Control de cambios y estado vivo del proyecto

> **Quién lee esto:** la PRIMERA lectura de toda sesión nueva (humano o AI).
> Responde "¿dónde quedamos, qué fue lo último que se trabajó y por qué?".
> **Cómo se actualiza (OBLIGATORIO al cerrar cada sesión de trabajo):**
> 1. Refrescar el bloque **ESTADO ACTUAL** (branch, commit, pendientes).
> 2. Agregar una **entrada nueva ARRIBA** de las demás con el formato:
>    `## AAAA-MM-DD — título` + qué se pidió/por qué + qué se hizo (con
>    commits y archivos clave) + qué quedó pendiente + deploy necesario.
> 3. Si el cambio tocó módulos/conexiones → actualizar también
>    `ARQUITECTURA.md`. Si tocó misión/roles/stack → `PRODUCTO.md`.
> Mantener cada entrada en ≤15 líneas. El detalle fino vive en los commits.
> **Documentos hermanos:** `PRODUCTO.md` (qué es la app) · `ARQUITECTURA.md`
> (cómo está conectada) · `AGENTS.md` (reglas/proceso) · `Install Steps/`
> (build y release) · `TESTING.md` (testing manual).

---

## ⭐ ESTADO ACTUAL (refrescar al cerrar cada sesión)

- **Branch viva de trabajo: `claude/awesome-joliot-a2bd43`** (Feature C EN PROGRESO; pusheada a
  origin para backup). `main` está estable en `df80c05` (= **GitHub y local idénticos**) con todo el
  Sprint A+B + fixes + bump a v0.11.10. **Único tag/release en GitHub: `v0.11.9`**.
- **⚠ Lo de Feature C (4 commits sobre main) está en la rama, NO en `main`.** Al reanudar: `git checkout
  claude/awesome-joliot-a2bd43` (o `git pull` la rama). NO mergear C a main hasta terminarla + auditarla.
- **App:** v0.11.10 (sin buildear/publicar) · schema PowerSync **v27 en main / v28 en la rama C** ·
  migraciones **0001→0118 corridas; la 0119 (Feature C) está ESCRITA pero NO DEPLOYADA**.
- **Edge Functions:** las 6 al día (2026-06-09).
- **Sprint A+B:** testeado por Rubén (debug Windows) ✓ y mergeado a main. Pendiente: build+publicar release v0.11.10.
- **Hecho recién (2026-06-14):** arrancó **Feature C — cambio de fecha de pago por días** (ver entrada
  abajo): base matemática + DB 0119 + plumbing + gating UI. Falta la transacción/diálogo/botón/recibo
  /reportería y toda **Feature A (suspensión)**. `flutter analyze` limpio · `flutter test` 293 verdes.

---

## 2026-06-14 (cont.) — Contratos: Feature C (cambio de fecha de pago por días) EN PROGRESO

**Contexto:** Rubén pidió 3 features de flexibilidad de contrato. Tras consolidar: quedaron **2**
(la "restructura B" se fundió en C). Esta sesión arrancó **Feature C**; **Feature A (suspensión)**
NO empezó. Trabajo en rama `claude/awesome-joliot-a2bd43` (4 commits sobre main, NO mergeados).

**Feature C — cambio de fecha de pago por días. DISEÑO CERRADO (decisiones de Rubén):**
- El cliente AL DÍA mueve su día de pago. Paga los **días puente** entre lo pagado y el día nuevo,
  prorrateados a **precio_mensual ÷ días reales del mes** (cada día con los días de su propio mes).
- **Regla del ancla:** primera ocurrencia del día nuevo DESPUÉS de "pagado hasta". La cuota que cae en
  la ventana del puente se **absorbe (anula)**; la 1ª cuota completa cae en el día nuevo. Ejemplos
  validados: 15→30 = puente 15d (C$450 con plan 900) · 15→10 = puente 25d, 1er pago 10-ago · 15→14 =
  puente 29d, 1er pago 14-ago. Helper `lib/data/utils/prorrateo.dart` (18 tests).
- **Puente = `cargos_extra` (origen 'puente', "Puente de pago")** sobre la cuota que el cliente paga en
  ese momento ("se aprovecha"); aparece en EL RECIBO de ese cobro. NO es una cuota suelta (chocaría con
  el unique (contrato_id, periodo)). Entra a recaudado; NO infla el total fijo (es extra, como reconexión).
- **Re-anclaje:** anular la cuota absorbida + el trigger `0018` mueve el día de las futuras pendientes
  (espejar local offline) + en contratos FIJOS agregar 1 cuota de cierre al final (conserva el conteo →
  el contrato termina unos días después, los del puente). Indefinidos: solo se re-ancla el cushion.
- **Gating 2 niveles:** super_admin activa la feature por tenant (setting super-only
  `cobranza.cambio_fecha_habilitado`); el admin habilita por usuario (`cobradores.puede_cambiar_fecha`)
  a cobradores/admin_cobranza (el rol admin siempre). Botón "Cambiar fecha" al lado de "Pagar" en la
  vista Por Cobrar Y en el mapa. Sin flujo de aprobación extra. RLS server `puede_cambiar_fecha_pago()`.
- **Offline-first:** el cobrador escribe local (writeTransaction + espejo de triggers) y sincroniza; por
  eso la `0119` EXTIENDE la RLS de contratos/cuotas para el personal habilitado, solo sobre SUS contratos.

**Hecho y commiteado (rama, 4 commits):**
- `42b8baf` `prorrateo.dart` + tests. · `6e72143` migración **0119** (permiso col, setting super-only,
  helper `puede_cambiar_fecha_pago()`, RLS contratos/cuotas) + schema.dart (cobradores.puede_cambiar_fecha,
  v27→**v28**) + sync rules (columna agregada a los SELECT de cobradores). · `9c1c0d8` modelo
  `Cobrador.puedeCambiarFecha` + `puedeCambiarFechaPagoProvider` + getter `cambioFechaHabilitado`. ·
  `0bcfe1f` gating UI (grupo en tab Avanzado + `_superAdminOnly` + toggle por usuario en _EditarCobradorDialog).

**PENDIENTE Feature C (orden sugerido):**
1. Transacción offline (repo): calcular "pagado hasta" (max venc de cuotas 'pagada') + guard al-día,
   cargo puente sobre la cuota cobrada, cobro+recibo, anular absorbida, mover futuras (espejo), fijos:
   cuota de cierre, UPDATE dia_pago (+ fecha_fin fijos). Tests + invariantes_dinero.
2. Diálogo "Cambiar fecha" con preview (usar `calcularPuenteCambioFecha`).
3. Botón en `cuotas_list_screen.dart` (al lado de Pagar) y en el pin del mapa.
4. Recibo: línea "Puente de pago" (mapear origen='puente'); verificar CHECK de cargos_extra.origen
   (¿hay que extenderlo? revisar 0007/0115) y el tipo (usar 'otro' que SUMA).
5. Reportería/dashboard: el puente entra a recaudado; verificar invariante #10 (totales idénticos).
6. Audit Fase 4 (Code+QA dinero+Security por la RLS) + testing manual.

**PENDIENTE Feature A — suspensión temporal (NO empezada):** estado contrato 'suspendido' + motivo
(tabla `contrato_suspensiones`, Receta R10), pausa de generación (cron ya saltea no-activo), anti-backfill
al reactivar, prorrateo de días consumidos, **PDF de deuda pendiente**. Decisiones cerradas: no se cobra el
período suspendido, contrato termina igual; solo admin/admin_cobranza suspenden; indefinidos solo pausan,
fijos anulan cuotas del período.

**DEPLOY de Feature C (cuando esté completa, JUNTO con el build):** correr `0119` en Dashboard (verificar)
→ redeploy sync rules a "Active" → build con el schema v28. NO deployar suelto (el bump de schema fuerza
DB local fresca; hacerlo una sola vez).

---

## 2026-06-14 — Sprint A+B: mapa picker, bug red, logo, vista Por Cobrar, reporte por cobrador

**Qué se pidió (6 features):** 1) mapa de geolocalización del cliente consistente
con el mapa principal; 2) bug: al asignar nodo a cliente no aparecían Hub/Puerto;
3) vista de cobros sin tab "Por cliente", "Por cobrar" única con buscador + 1 cuota
(la más antigua) + botón Pagar + tap→detalle; 4) reporte por cobrador que incluya
admins + multi-select; 5) export Excel de ese reporte; 6) logo de la app en el login.

**Decisiones de Rubén (AskUserQuestion):** #2 es bug real (creó hub+puerto y no salían) ·
#3 una fila POR CONTRATO (no por cliente) y **el admin también paga** desde la lista ·
#6 usar el ícono actual `app_icon.png`, **sin** el texto "SITECSA CRM" · defaults #4/#5
confirmados (incluir cobrador+admin+admin_cobranza + inactivos con pagos; "Todos" default;
PDF agrupado con subtotal + total general).

**Qué se hizo** (rama `claude/awesome-joliot-a2bd43`, 9 commits `bb700a7`→`7883318`):
- **#1** `mapa_picker_screen.dart` enriquecido (brújula, pin GPS, toggle satélite, atribución);
  `UbicacionActualMarker`/`MapAttributionBanner` extraídos a `shared/widgets/mapa_widgets_compartidos.dart`
  (DRY con `mapa_screen`). Beneficia también al picker de nodos de red.
- **#2** `red_picker.dart`: `emptyHint` en Hub/Puerto (autoexplica el vacío y sirve de diagnóstico) +
  `key` por nivel de cascada (anti estado viejo de `initialValue`). **Causa raíz no reproducible
  estáticamente** — toda la cadena (schema/sync/RLS/INSERT/cascada) está correcta; el `emptyHint`
  dirá en el dispositivo si la query devuelve 0 filas (dato) o si es otro mecanismo.
- **#6** logo `app_icon.png` en recuadro negro redondeado en login + set-password (sin el texto, decisión de Rubén).
- **#3** `cuotas_list_screen.dart` REESCRITO: vista única, 1 fila por contrato (cuota más antigua,
  desempate por periodo = paridad con el mapa), buscador client-side, botón Pagar (admin+cobrador)
  → `/cobro/:id`, tap→detalle; indicador "N cuotas · debe C$total" por contrato; sin tabs ni multi-select.
- **#4+#5** `reportes_admin_screen.dart` + `pdf/reporte_por_cobrador_pdf.dart`: selector multi-cobrador
  (incluye admins + inactivos con pagos vía EXISTS), PDF agrupado por `cobrador_id` con subtotal/total,
  export Excel desde la misma query `_rowsPorCobrador` (totales idénticos PDF↔Excel).
- **Audit Fase 4 (6 agentes, 2 tandas):** Sprint A → 1 MEDIO (logo se estiraba a barra negra por
  `stretch`) + BAJOs, todos fixeados (`5df418f`). Sprint B → 1 MEDIO (se perdía el contexto de deuda
  por cliente) + BAJOs, fixeados (`7883318`: indicador de deuda, desempate por periodo, clamp del saldo
  del mapa, PDF por id anti-homónimos, botón Pagar más tocable, fin de mutación de estado en build).

**Testing manual de Rubén (2026-06-14, debug Windows) + fixes** (commits `062665c`→`00f8425`):
corrido desde una **worktree de ruta corta** (`C:\Users\ruben\sc`) porque el build Windows desde
la worktree bajo OneDrive excedía MAX_PATH (MSB3491 en los `.tlog`). Fixes que salieron del testing:
- **Bug guardado de cliente (causa raíz real):** `ref` NO es usable en `dispose()` (Riverpod 2.6.1
  lanza "Cannot use ref after the widget was disposed") → se captura el `StateController` de
  `formDirtyProvider` en `initState` (`_formDirtyCtrl`) y se usa en dispose. Mismo fix en
  `contrato_form_screen`. Además en `_guardar` se capturan `ScaffoldMessenger`/`GoRouter` ANTES del
  await (el árbol se reconstruye por PowerSync y desactiva el context → "ancestor unsafe").
- **Vista cobros (pedido de Rubén):** fila con **código arriba** → nombre+municipio → mes → fecha
  (se agregó join a `municipios`); **se quitó** la línea "N cuotas · debe total" (Rubén la pidió out).
- **Cédula** alfanumérica libre (se quitó el validator de formato 000-000000-0000A).
- **Legibilidad:** `scheme.secondary` (= primary al 10%, color de relleno) se usaba como color de
  TEXTO/ÍCONO → ilegible. Arreglado en: notas de visita (Promesa de pago), dashboard (Pago parcial),
  estado de ticket "Asignado", avatares de rol `admin_cobranza`, íconos del log de auditoría.
- **Robustez:** el sheet de equipos en baja no bloquea el cierre del form de cliente (try/catch).

**Backlog/aceptado:** `pi` sin import explícito (vía latlong2, pre-existente) · chips "Próximas/Vencen
hoy" muestran la cuota futura aunque haya mora (semántica de filtro, aceptada) · **fix completo del
context estable para `ofrecerGestionEquiposEnBaja`** en el path de baja (cliente y contrato_detail) —
hoy mitigado con try/catch; pendiente capturar un Navigator estable (chip `task_5c833dc7`).

---

## 2026-06-12 (l) — Onboarding con Contraseña por Defecto + Ocultación de Toggles de Email + Release v0.11.9

**Qué se pidió:** Cambiar el flujo para que por defecto siempre se generen contraseñas en lugar de invitaciones por correo electrónico al crear usuarios, y ocultar visualmente el interruptor de invitaciones por email en todas las pantallas donde se invite a nuevos usuarios (cobradores, tenants, administradores y reenvíos).

**Qué se hizo:**
- **UI/UX**: Modificados 4 diálogos (`_InvitarDialog` en `cobradores_admin_screen.dart`, `_CrearTenantDialog` en `tenants_list_screen.dart`, `InvitarAdminDialog` en `tenant_dialogs_invitar.dart`, y `ReenviarInvitacionDialog` en `tenant_dialogs_miembro.dart`) para cambiar el valor inicial a `_enviarEmail = false` y comentar los widgets `SwitchListTile` correspondientes.
- **Validación**: Análisis estático `flutter analyze` libre de advertencias `dead_code`, y suite completa de tests de la app (`flutter test` con 275 aprobados).
- **Release**: Incrementada la versión a `0.11.9+119`, ejecutado script de build, y publicado release en GitHub, barriendo el tag/release obsoleto `v0.11.8`.

---

## 2026-06-12 (k) — Fix de pantalla negra en Ruta + Reglas Audit 7-9 + Release v0.11.8

**Qué se pidió:** Corregir el bug donde la pantalla quedaba negra y bloqueada al presionar el botón "Ruta" tanto en Android como en Windows.

**Qué se hizo:**
- **UI/UX**: Modificado `mapa_screen.dart` para eliminar el uso de `showDialog` como indicador de carga para el cálculo de rutas (anti-patrón de Flutter). Implementado un indicador de carga reactivo basado en un flag de estado interno (`_isCalculatingRoute`) y un overlay condicional en el `Stack` principal.
- **Robustez**: Se envolvió el flujo asíncrono de cálculo en un bloque `try/catch/finally` para asegurar que `_isCalculatingRoute = false` se ejecute siempre, previniendo pantallas bloqueadas en caso de excepciones.
- **AGENTS.md**: Agregadas las Reglas de Audit 7, 8 y 9 para prohibir `showDialog` para loadings, alertar sobre desajustes de contexto con GoRouter al usar `Navigator.pop()`, y obligar a verificar los caminos de error asíncronos.
- **Release**: Incrementada versión a `0.11.8+118`, ejecutado script de build, y publicado release en GitHub con APK y MSIX, limpiando releases viejos hasta `v0.11.7`.


---

## 2026-06-12 (j) — Rotación de Mapa y Motor de Ruteo 100% Offline (SQLite + A*)

**Qué se pidió:** 1) Rotar la orientación del mapa con dos dedos y reorientar al norte con brújula; 2) Ruteo y trazado de caminos reales de Nicaragua de forma interna, 100% local y offline, sin abrir Google Maps externo (salvo como fallback).

**Qué se hizo:**
- **Mapa**: Habilitada la rotación en `MapOptions`. Creado el botón flotante de Brújula que se orienta de manera inversa a la cámara y resetea a 0 grados.
- **Ruteo Offline**: Compilada una base de datos local SQLite (`rutas_nicaragua.db`, 11.08MB) filtrando la red vial principal de Nicaragua desde OpenStreetMap (Overpass API) y formateando coordenadas a 5 decimales.
- **Dart**: Creado `OfflineRoutingService` ejecutando el algoritmo A* en memoria con cola de prioridad y decodificación geométrica de tramos. Dibujo de la ruta mediante `PolylineLayer` y panel inferior de control.
- **Verificación**: `flutter analyze` exitoso (0 errores). Bump a `v0.11.7+117`.

---

## 2026-06-12 (i) — Simplificación del banner de actualización + Release v0.11.6

**Qué se pidió:** Quitar el detalle de las notas de versión (release notes) en el banner superior de actualización para evitar problemas de codificación (tildes raras) y tener una interfaz más limpia, mostrando únicamente el aviso de actualización y el botón.

**Qué se hizo:**
- **UI**: Modificado `update_banner.dart` para remover el renderizado de `update.releaseNotes` en la columna del banner.
- **Verificación**: `flutter analyze` exitoso (0 errores, 4 deprecaciones conocidas) y `flutter test` (275 exitosos). Bump a `v0.11.6+116`.

---

## 2026-06-12 (h) — Fix de filtros congelados + Release v0.11.5 (Filtros de Cobrador/Zona/Nodo)

**Qué se pidió:** Corregir bug donde al seleccionar "Todas" o "Todos" en los filtros desplegables de cobrador, zona o nodo en el mapa y lista de cuotas, el filtro se quedaba congelado en el valor anterior.

**Qué se hizo:**
- **Shared widgets**: Modificado `dropdown_filtro.dart` para cambiar el tipo genérico del `PopupMenuButton` de `String?` a `String`, utilizando `'__TODOS__'` como valor interno para la opción general. Esto previene que Flutter interprete la selección de `null` como una cancelación del menú y descarte el trigger de selección.
- **Verificación**: `flutter analyze` exitoso (0 errores, 4 deprecaciones conocidas) y `flutter test` (275 exitosos). Bump a `v0.11.5+115`.

---

## 2026-06-12 (g) — Opción A & Opción B / Sprint 4 (baja terminal, motivo obligatorio, saldo >= 0, auto-eventos)

**Qué se pidió:** Implementar la Opción A (seriales: baja es estado terminal, bloquear transferencias de instalado sin volver a stock; contratos: motivo de cancelación obligatorio) y Opción B / Sprint 4 (saldo clampeado a >= 0 para evitar saldos negativos por sobre-pagos; auto-eventos de ticket en el servidor).

**Qué se hizo:**
- **Base de Datos**: Creada migración `0118_serial_baja_transferencias_tardias.sql` que actualiza el trigger guard de transiciones de seriales y crea el trigger `trg_tickets_eventos_auto` para centralizar la inserción de eventos de ticket en el servidor.
- **Contratos**: Añadido diálogo stateful obligatorio `_CancelarContratoDialog` en `contrato_detail_screen.dart` para capturar el motivo de cancelación, y propagación del mismo a cuotas y cargos de liquidación. Clampero de saldos en cuotas parciales.
- **Clampero de Saldos**: Modificados `clientes_list_screen.dart`, `clientes_admin_screen.dart` (lista y Excel), `dashboard_providers.dart` (KPIs), y `reportes_admin_screen.dart` (las 6 consultas PDF/Excel) para clampear el saldo de cada cuota a `>= 0` vía `max(..., 0)`.
- **Tickets**: Eliminadas inserciones manuales de eventos de ticket (`creado`, `asignado`, `cambio_estado`, `reasignado`) en `ticket_form_screen.dart` y `ticket_detail_screen.dart` (los comentarios, materiales y adjuntos siguen haciéndose desde el cliente).
- **Verificación**: `flutter analyze` exitoso (0 errores, 4 deprecaciones pre-existentes) y `flutter test` (275 exitosos).

---

## 2026-06-12 (f) — Release v0.11.3 (compresión de media + branding de reportes)

**Qué se pidió:** dejar la carpeta local al día, correr analyze/tests y
publicar la build v0.11.3 con el sprint de compresión + branding (Rubén
decidió testear directo con la versión instalada, sin pasada previa en rama).

**Qué se hizo:**
- Merge fast-forward de `compress-media-and-report-ui` a `main` (6 commits,
  `2ead790`→`be6453d`) y rama efímera BORRADA (local + GitHub).
- Bump `pubspec.yaml` a `0.11.3+113`. Sin migraciones SQL ni cambios de
  schema/sync rules (sprint 100% client-side).
- Verificación sobre `main`: `flutter analyze` (solo las 4 deprecaciones
  conocidas) y `flutter test` (275 pasan).
- `build-release.ps1` con notas de versión → instaladores versionados en
  `Releases\v0.11.3\` + Escritorio, release `v0.11.3` en GitHub con assets
  fijos y `version.json` actualizado.

**Pendiente:** testing manual de Rubén con la v0.11.3 instalada (los 9 pasos
de la entrada (e) + §0.3 de TESTING.md).

---

## 2026-06-12 (e) — Compresión de media + branding de reportes (rama compress-media-and-report-ui, MERGEADA en (f))

**Qué se pidió:** 1) comprimir fotos/documentos al subir a Storage sin
degradar calidad visible (el storage se llenaba rápido); 2) reportes PDF y
Excel con header estilo la referencia de Telecable Mairena (logo del tenant,
el mismo del recibo).

**Qué se hizo** (6 commits `2ead790`→`e9aa01f`):
- `imagen_compresion.dart` NUEVO: pipeline en isolate (resize 1920px/JPEG 85,
  EXIF horneado, alpha→blanco, escalera de calidad hasta cumplir el bucket,
  passthrough anti doble-compresión). Razón: en WINDOWS `image_picker` ignora
  `imageQuality/maxWidth` → el admin subía fotos crudas. Aplicado en los 6
  puntos de subida (fotos cliente/ticket/comprobante/logo/documento-foto).
  PDF/Word NO se recomprimen: peso visible + confirmación si >5 MB.
- Logo del tenant en los 9 PDF (`buildHeaderEstandar(logo:)`, bytes offline
  de `logoEmpresaBytesProvider`); Excel con header tipográfico (la lib
  `excel` no embebe imágenes — decisión de Rubén: NO migrar a syncfusion).
- Audit Fase 4 (Code+QA+UX): 0 ALTO, 6 MEDIO + 6 BAJO, TODOS fixeados
  (`e9aa01f`): spinners durante compresión, logo fresco tras reemplazo
  (invalidación + cache disco), PNG real en logo, guard 10 MB post-compresión
  para fotos, timeout 8s del download. Decisión aceptada: período PDF
  mora/clientes queda "Junio 2026" (Excel dice "Al dd/mm"). Tests 275 ✓.

**Pendiente:** testing manual (pasos abajo) → merge a `main` + borrar rama.
Backlog nuevo: "1024 KB" en el borde de `Fmt.pesoArchivo` · string "3 meses"
duplicado en inactivos · mapear 413 de Storage a mensaje humano.

---

## 2026-06-12 (d) — Release v0.11.2 (Ubicación GPS y Exportación de Clientes)

**Qué se pidió:** Merge de la rama `mapa-lista-clientes` a `main`, bump de versión a `0.11.2` y publicación de la build para probar el banner de actualización en dispositivos de campo.

**Qué se hizo:**
- Fusionada la rama `mapa-lista-clientes` a `main` sin conflictos. Pushed a GitHub y eliminada la rama efímera.
- Incrementada la versión en `pubspec.yaml` a `0.11.2+112`.
- Ejecutado el script `build-release.ps1` con notas de versión. Generados instaladores versionados para Windows (`.msix`) y Android (`.apk`), copiados automáticamente al Escritorio.
- Actualizado `version.json` y cargado el nuevo release en el repositorio de GitHub con el tag `v0.11.2`.

## 2026-06-12 (c) — Ubicación GPS y Exportación de Clientes (Rama mapa-lista-clientes)

**Qué se pidió:** 1) Mostrar la ubicación actual con un pin estilo Google Maps en el mapa que funcione online/offline con un botón de centrado rápido. 2) Añadir un botón de exportar clientes a Excel directamente en la vista de clientes (admin/admin_cobranza) con soporte para exportar todos o con la vista filtrada actual.

**Qué se hizo:**
- Agregada dependencia `geolocator: ^13.0.2` en `pubspec.yaml` + permisos en `AndroidManifest.xml` (Android) y capabilities de `location` en `pubspec.yaml` (Windows MSIX).
- Modificado `lib/features/mapa/mapa_screen.dart` para integrar Geolocator en tiempo real, agregando el marcador animado pulsante `_UbicacionActualMarker` y el botón flotante de centrado rápido (`my_location`).
- Modificado `lib/features/admin/clientes/clientes_admin_screen.dart` para agregar un `PopupMenuButton` de exportación. Soporta exportar todos los clientes o la vista actual, clonando dinámicamente las condiciones del filtro en la consulta SQL.
- Verificación: `flutter analyze` exitoso (0 errores, 4 deprecaciones conocidas) y `flutter test` (263 exitosos).

---

## 2026-06-12 (b) — Vista previa dinámica del recibo (Rama test-receipt)

**Qué se pidió:** hacer que los cargos/descuentos de ejemplo de la vista previa del recibo en Configuración -> Recibos sean dinámicos según el estado de la configuración (ajustes y reconexión), para que no se muestren si están desactivados y la matemática cierre siempre. Cambios en la rama `test-receipt`.

**Qué se hizo:**
- Creada rama `test-receipt` y hecho checkout (`fe1dfa2`).
- Modificado `lib/features/admin/settings/recibo_preview.dart` para recibir `AppSettings` en `_sampleCargos` and `_sampleRow`. Los cargos de ejemplo y la matemática (cargos_neto, monto_cordobas) ahora se recalculan dinámicamente.
- Verificación: `flutter analyze` exitoso (0 errores/warnings, 4 deprecaciones conocidas) y `flutter test` (263 exitosos). Pushed a GitHub.

---

## 2026-06-12 — Rediseño de descuentos (cierra el feedback 2026-06-11 d)

**Qué se pidió:** unificar los DOS diálogos de descuento, semántica
ajuste/promo, recibo con desglose, settings descubribles, y retirar
`/admin/cuotas` (decisiones de Rubén vía AskUserQuestion; multi-cuota NO).

**Qué se hizo** (rama `claude/adoring-carson-w6l6rj`, 9 commits `16337be`→
`5d2f169`): `DescuentoDialog` ÚNICO (contrato: selector Ajuste/Promo →
`aplicarAjuste(origen:)`; cobro: devuelve `CargoPendiente` DIFERIDO — nada
se graba hasta confirmar, viaja con `pago_id` → anular revierte; fin del
"descuento fantasma") · `CargoDialog` aparte (reconexión/otro, diferido) ·
recibo: desglose en el bloque `cuota` con sub-toggles (3 renderers) ·
settings: grupos Ajustes/Descuentos del cobrador/Pronto pago en Avanzado ·
`/admin/cuotas` RETIRADA (anular cuota y cuotas manuales fuera del
producto) · **migración 0117** (guard promo + motivo server del cobro +
CONDONACIÓN: descuento 100% → cuota `pagada`, espejo en `cuota_estado`).
**Audit Fase 4:** 3 agentes (Code/QA dinero/UX) — 2 ALTOS (USD pisado en
C$, condonación) + 7 menores, TODOS fixeados (`5d2f169`). Tests nuevos:
promos, condonación, descuento manual diferido.

**Iteración 2 (mismo día, feedback de Rubén en el manual):** el COBRADOR
NO descuenta — gestión centralizada en el contrato: sheet "Descuentos y
cargos de la cuota" (lista TODOS los orígenes; pago_id = solo-lectura) con
"Aplicar descuento" + "Cargo extra" (`aplicarCargo` origen='cobro' sin
pago_id, `quitarCargo` protege pago_id/liquidación); el cobro solo
REFERENCIA ("Ver descuentos y cargos"); settings descuento_* del cobrador
a `_hidden`; sub-toggles del recibo visibles solo con features ON (la data
aplicada se sigue imprimiendo). 0117 NO cambió (ya estaba deployada).

**Pendiente:** analyze/test/invariantes → manual §0.3 (deploy 0117 ✓
2026-06-12) → SQL Byr → merge a main. Backlog nuevo: tope ajuste default
50 cliente vs 0 server (pre-0115) · "ANULADO" en recibo de pago anulado ·
reimpresión lee cargos vivos (sin corte temporal).

---

## 2026-06-11 (d) — CHECKPOINT: feedback de Rubén sobre Ajustes (rediseño pendiente)

**Testing del mega-sprint:** pasos 1-6 TODOS verdes (deploy 0115+0116
verificados, invariantes 14/14=0, pub get, analyze 4 infos, tests 254).
El manual destapó 4 problemas de PRODUCTO/UX — la próxima sesión arranca
acá: evaluar el approach y proponer el rediseño ANTES de seguir.

**Feedback de Rubén (verbatim resumido) + diagnóstico preliminar:**
1. **No encuentra el toggle "Ajustes de cuota" en Avanzado** — activó
   "Permitir descuentos" (que es OTRO feature: el del cobrador en campo).
   Causa: los 3 settings nuevos de ajustes no tienen GRUPO curado en el
   panel → caen al final en "Otros" (el F3 que QA flaggeó como backlog
   resultó bloqueante de descubribilidad). Consecuencia: nunca vio el
   icono % ni el AjustarCuotaDialog (motivo+preview) — lo que probó fue el
   viejo AplicarCargoDialog del flujo de cobro, que le pareció poco
   intuitivo. HAY DOS DIÁLOGOS y se confunden → candidato a unificar.
2. **Quiere ajustes a UNA O VARIAS cuotas pendientes a la vez** (ej. días
   sin internet que afectan 2 meses) con semántica clara ajuste vs promo.
3. **Espera los toggles del recibo** (mostrar ajustes/promos) — eso era
   Sprint 3 (bloque "Descuentos y ajustes" del diseñador, no implementado).
   Alinear: adelantarlo al rediseño.
4. **El tab Cuotas re-linkeado (M25) lo afectó:** anuló una cuota de prueba
   y NO HAY des-anular (la anulación de cuota es terminal). Decidir:
   des-anular cuota (trivial sin pagos; complejo con pagos por la cascada
   0023) o sacar/endurecer "Anular cuota" de esa pantalla.

**Reparación de data pendiente (SQL en Dashboard):** des-anular la cuota
de prueba (cliente Byr, Febrero 2026, sin pagos) — SELECT id de la anulada
y UPDATE estado='pendiente', anulada_en/por/motivo_anulacion = NULL.

**Plan próxima sesión (pedido explícito):** re-evaluar el approach completo
de ajustes/promos/descuentos con sugerencias de diseño: (a) panel Avanzado
con grupo propio "Ajustes" (y revisar nombres/UX de los 3 settings), (b) UN
solo flujo intuitivo de descuentos (¿unificar AplicarCargoDialog +
AjustarCuotaDialog?), (c) ajustes multi-cuota desde el contrato, (d) bloque
de recibo + toggles, (e) destino de /admin/cuotas y des-anular. La base
contable (cargos_extra origen/pago_id/grupo_promo + guards 0115/0116 +
INV13/14) está deployada y sólida — el rediseño es de UX/entrada, no del
motor.

---

## 2026-06-11 (c) — Mega-sprint de correcciones (todo el backlog arreglable)

**Por qué:** decisión de Rubén: "corrijamos todo lo faltante primero y
dejamos para último los tests" — atacar TODOS los HIGH restantes del audit
integral + los MEDIUM/LOW técnicos acumulados, y testear todo junto.

**Qué se hizo** (commits `1cc16e3`→`8c4e330`; detalle por commit en git):
- **Los 7 HIGH restantes**: #3 cargos auto re-deduplicados al aplicar cargo
  manual · #4 enforce server de cobrador_anula/edita_cobros · #6 PopScope en
  cobro · #7 doble-submit en forms de cliente/contrato · #8 confirmación al
  cancelar contrato · #9 changelog de `cobradores` (+ botón Historial) ·
  #10 guard server de transiciones de seriales.
- **Migración 0116** (NO corrida aún): los guards #4/#9/#10 + correlativo de
  tickets re-asignado en server (M18) + audit_log append-only para el súper
  (M23) + sin filas update fantasma (no-op guard en la función de changelog).
- **MEDIUMs**: M8 coma decimal en TODOS los montos (parseMonto) · M9 flush
  del debounce de settings · M11 fin del flash "Recibo no encontrado" · M12
  el admin ya no borra el badge de mora del cobrador · M13 KPIs con error
  visible · M14 `mensajeErrorHumano` en ~40 spots · M15 gates de edición en
  historial · M16 confirmación de transiciones terminales de tickets · M17
  updater sin re-descarga post-permiso · M21 UTC en inventario · M25 menú
  Cuotas re-linkeado · M26 build-release -Notes · M5 lock con while.
- **LOWs**: aplicado_en UTC · OfflineBanner en SuperShell · aviso de
  retry-loop en _SyncCard · copy Bluetooth · auth humanizado · mounted tras
  awaits · Cargar más en historial · geolocator fuera / web_plugins
  declarado · 50 de los 54 infos del analyze (42 initialValue + 8 imports).
- **Decisiones tomadas** (revisables): #4 ENFORZADO server-side (no solo
  documentado) · /admin/cuotas RE-LINKEADA (recupera "Anular cuota") · una
  cuota con ajuste NO recibe además pronto-pago (anti doble-descuento).

**Diferido (consciente):** promos (Sprint 3 aprobado en diseño) · M19/M20
(evento server de tickets / cola offline de firma: diseño) · compresión real
de fotos (dep nueva) · M4 clamp de saldo (decisión de semántica) · vista de
rechazos para admin/súper · deprecations announce/Radio/translate.

---

## 2026-06-11 (b) — Sprint 2: Ajustes de cuota + rieles de cargos (M2/M3/M22)

**Por qué:** Rubén pidió evaluar promos y ajustes de cuota; se aprobó el
diseño "todo descuento es cargos_extra, nunca mutar cuotas.monto" + retirar
"Editar monto" + topes preventivos. Promos (opción A) quedan para Sprint 3.

**Qué se hizo** (commits `c98251f`→`fa00fa3`, rama de trabajo):
- **Migración 0115** (NO corrida aún): cargos_extra.origen/grupo_promo/
  pago_id · setting_bool · settings super-only `ajustes_habilitados` +
  topes · `trg_cargos_ajuste_guard` (guard server REAL del feature) ·
  `trg_pagos_revertir_descuentos` (M3). Schema v27 (resync al actualizar).
- **Feature Ajustes:** CuotasRepo.aplicarAjuste/quitarAjuste/ajustesDeCuota
  con mirrors · AjustarCuotaDialog (preview, motivo, topes, coma decimal) ·
  icono % por cuota en el detalle del contrato + sheet con quitar.
- **Fixes del audit:** M22 (agregadores leen `$.padre_id` del snapshot —
  los cargos borrados conservan rastro) · M2 (tope en editarPago) · M3
  (anular pago borra SUS descuentos; reconexión se preserva; cargos del
  cobro llevan pago_id) · M1/M25 ("Editar monto" RETIRADO; setting a
  `_hidden`).
- INV13 en `invariantes_dinero.sql` · tests: 5 de ajustes + 3 de reversión
  + 2 de tope (harness PowerSync real).

**Audit Fase 4 (Code+QA+Regresión): 3 aprobados**; fixes aplicados (seed
chain 0113 · guard sin rebote de cascadas · DELETE de cargos para
admin_cobranza · INV14 anti-fantasma · UX quitar en pagadas).
**Pendiente:** deploy 0115 + sync rules → testing Rubén → merge.
**Backlog nuevo (QA/Regresión, no bloquea):** descuento MANUAL del cobro
(sin pago_id) no se auto-revierte al anular · settings de ajustes caen en
"Otros" del tab Avanzado (agruparlos) · "Exception:" crudo al editar pago
(M15) · guard server sin validación de saldo (INV4/14 lo detectan) ·
'origen' no seleccionable en el catálogo del viewer de audit · DECISIÓN
Rubén: cuota con ajuste no recibe además pronto-pago (anti doble-descuento,
default actual) · el cobrador ve bajar el saldo sin el motivo (capacitación
o mostrar el ajuste en su vista).

---

## 2026-06-11 — Audit integral profundo (8 agentes) + Sprint 1 de fixes

**Por qué:** pedido de Rubén: audit completo de la app (módulos, entidades,
interacciones) con agentes especializados en UI/UX/lógica buscando bugs no
encontrados antes; luego aprobó implementar la recomendación (Sprint 1).

**Audit:** 8 agentes en paralelo + re-verificación manual de cada HIGH →
1 CRITICAL + 9 HIGH + ~26 MEDIUM + ~20 LOW. Reporte completo con plan de
4 sprints: `docs/archive/AUDIT-INTEGRAL-2026-06-11.md` (commit `87a277d`).
Veredicto: dinero/multi-tenant/SQL/TZ sólidos; el riesgo real está en la
divergencia silenciosa y en escrituras offline sin guard server-side.

**Sprint 1 — "ningún cobro se pierde en silencio"** (commits `c9175d1` ·
`c6c5293` · `3436466` + commit de cierre con los fixes de Fase 4):
- `connector.dart`: **allowlist** SQLSTATE (P0001/23/42/22 de 5 chars) —
  PGRST301 (JWT expirado), 429 y desconocidos ahora REINTENTAN; antes se
  descartaba el cobro de la cola para siempre (CRITICAL #1).
- **`CorrelativoStore`** (nuevo): high-water mark monotónico del correlativo
  por cobrador+prefijo (SharedPreferences) + `.timeout(5s)` del piso server —
  no se reusa un número impreso tras anulación+offline (HIGH #2 + M6).
- **`RechazosSyncService`** (nuevo) + card "Cambios sin sincronizar" en el
  Perfil (cobrador/técnico) + SnackBars humanizados en los 4 shells con VER +
  `opData` en error_logs (HIGH #5). Dedupe por retry de batch + writes
  serializados (fixes del audit Fase 4: Code+QA+Regresión, 3 aprobados).
- Tests nuevos: clasificador del connector · monotonicidad del hwm · 2
  regresiones en `pagos_repo_test` (sync borra recibo anulado) · rechazos.

**Testing de Rubén (2026-06-11): APROBADO** — `flutter analyze` sin issues del
sprint (54 infos pre-existentes: deprecations `value→initialValue` etc., quedan
para una pasada de limpieza) · `flutter test` 244 verdes (se actualizó
`recibo_layout_test` que esperaba el orden PRE-954b624, no era regresión) ·
smoke manual OK (pre-check de código duplicado + cobro con correlativo
correcto). **Mergeado a `main`; rama borrada.**

**Pendiente/backlog nuevo:** fotos de cliente SIN compresión → Storage rechaza
con 413 y el SnackBar muestra el error crudo en inglés (visto en el smoke;
candidato Sprint 2 junto con M14 errores crudos) · avisos de rechazo invisibles
para admin/súper (sin pantalla Perfil; decidir si darles vista) · surfacear el
retry-loop de una op envenenada en `_SyncCard` · `rechazos_sync_v1` es
per-device, no per-user (aceptado: equipos personales).

---

## 2026-06-10 — Auto-update in-app + fix de firma del APK + limpieza de releases

**Por qué:** el banner de update delegaba la descarga al browser — en Android
Chrome nunca completaba la descarga (moría en los redirects de GitHub) y en
Windows quedaba en Descargas con instalación manual. Rubén eligió la opción A
(updater in-app, GitHub sigue de host; la opción B —Supabase Storage, que
permitiría repo privado— quedó documentada como alternativa futura).

**Qué se hizo (commits `fc1583a` + `2fdcb3c` + `66e09e5`):**
- **Updater in-app**: la app descarga el binario ella misma (http streamed,
  timeout 30s handshake + por-chunk, progreso 0-100% en el banner, errores en
  español con Reintentar + plan B "Navegador") y lanza el instalador del
  sistema vía `open_filex` (+1 dep): Android → diálogo "¿Instalar?" (permiso
  `REQUEST_INSTALL_PACKAGES` runtime, 1 toggle la 1ª vez), Windows → App
  Installer. Web mantiene fallback browser. Estado `_instalando` evita doble
  descarga. Archivos: `update_service.dart`, `update_banner.dart`, manifest.
- **Fix CRÍTICO de firma del APK** (encontrado por el audit de plataforma):
  el release firmaba con la **debug key de la PC** → un APK de otra PC no
  podía actualizar instalaciones existentes (y "arreglarlo" = desinstalar =
  perder la DB offline del cobrador). Ahora `build.gradle.kts` firma con
  keystore dedicado (`android/key.properties` + `sitecsa-release.jks`,
  LOCALES — gitignored) con fallback a debug para dev. **Rubén debe generar
  el keystore 1 vez** (pasos en `Install Steps/0-Setup-PC-desarrollo.md` §3b).
  ⚠️ Transición: el PRÓXIMO release tendrá firma nueva → las apps ya
  instaladas (firmadas debug) deben desinstalar/reinstalar UNA vez (sincronizar
  antes). Después, updates normales para siempre.
- **Releases viejos limpiados** (con Rubén, gh CLI): quedó solo `v0.9.0`
  (endpoint vivo del auto-update) + tags `pre-mvp-v1/v2`. 18 releases borrados.
- **Pendiente (Rubén):** ~~pub get~~ ✓ · ~~keystore~~ ✓ (generado y
  verificado, backup recomendado) · smoke tests B.2-B.6 + flujo del updater →
  publicar release nuevo (`v0.11.0`) → borrar `v0.9.0`.

## 2026-06-09 (e) — Limpieza de PC local + setup multi-PC

**Por qué:** la carpeta local de Rubén tenía restos de versiones anteriores;
y quiere poder trabajar desde otras PCs con solo `git clone`.

**Qué se hizo:**
- Carpeta local limpiada con `git clean -fdx` (dry-run revisado; exclusiones:
  `.env.json`, `Releases\`, cert y DLLs) → working tree = `main` exacto.
- **Binarios de soporte AL repo** (cambio de `.gitignore`): `powersync.dll` /
  `powersync_x64.dll` (core nativo para los tests de dinero en Windows) y
  `SITECSA-CRM.cer` (cert PÚBLICO del MSIX — no es secreto). `.env.json`
  sigue SIEMPRE fuera de git (keys; a PC nueva va por canal seguro).
- **`Install Steps/0-Setup-PC-desarrollo.md`** (nuevo): guía completa de PC
  de dev nueva (herramientas → clone → .env.json → pub get → run → tests →
  gh para releases). La firma MSIX usa el cert de prueba del paquete `msix`
  (sin certificate_path) → releases compatibles desde cualquier PC.
- `pubspec.lock` actualizado (faltaba `mobile_scanner` — pendiente viejo).

## 2026-06-09 (d) — Consolidación de ramas: main + tags pre-mvp

**Por qué:** había 4 ramas en GitHub (2 de Claude viejas, el checkpoint
`pre-mvp-v1`, y la default era una rama muerta `claude/plan-billing-app-q9mC4`)
— confuso para sesiones futuras y para ver el código actual en GitHub.

**Qué se hizo (decisión de Rubén — opción A):**
- **`main`** creada desde el estado auditado (todo el trabajo del 2026-06-09)
  → **única rama permanente y default del repo**.
- Checkpoints convertidos a **tags inmutables**: `pre-mvp-v2` (= este estado,
  audit integral + fixes + docs rework) y `pre-mvp-v1` (= `48111e5`, el
  checkpoint previo).
- **Borradas** todas las demás ramas: `claude/hopeful-ride-u1ivz5`,
  `claude/new-features-inventory-tickets-and-technicians`, `pre-mvp-v1`,
  `claude/plan-billing-app-q9mC4`.
- Modelo de branching documentado acá (§ESTADO ACTUAL) y en `AGENTS.md`
  (§Git/branching): ramas efímeras desde `main` → merge → borrar; hitos = tags.
- **`AGENTS.md` = LA fuente única de reglas** (decisión de Rubén, patrón
  oficial de Claude Code): todas las reglas/invariantes/proceso viven en
  `AGENTS.md` (estándar que leen OpenCode/Codex/Cursor/Antigravity directo);
  `CLAUDE.md` quedó como shim de 1 línea (`@AGENTS.md`) solo para que Claude
  Code lo cargue automáticamente. Las referencias de los demás docs apuntan
  a `AGENTS.md`. NO editar reglas en CLAUDE.md.

## 2026-06-09 (c) — Rework del sistema de documentación + build a Install Steps

**Por qué:** pedido de Rubén (prioridad máxima): que cualquier modelo futuro
pueda hacer cambios SIN escanear todo el código, con docs que se
auto-referencien y se mantengan al día.

**Qué se hizo:**
- Nuevo sistema de 4 docs activos en la raíz: `PRODUCTO.md` (misión/visión/
  día-a-día/stack+porqués) · `ARQUITECTURA.md` (rework: esquema dual
  humano/AI, módulo por módulo con conexiones + **recetas de cambios
  comunes**) · `BITACORA.md` (este archivo) · `AGENTS.md` (adelgazado: reglas/
  proceso/invariantes + índice maestro).
- `build-release.ps1` movido de la raíz a **`Install Steps/`** (con auto-cd a
  la raíz del repo para que las rutas relativas sigan funcionando);
  referencias actualizadas.
- Docs históricos movidos a **`docs/archive/`** (HANDOFF, REPORTE-SESION,
  ESTADO-APP, STACK, ROADMAP, planes BULK/FASE3, audits, RELEASE) con README
  índice. Nada se borró: historia completa en archive + git.

## 2026-06-09 (b) — Audit integral profundo + TODOS los findings resueltos + deploy

**Por qué:** pedido de Rubén: audit completo de lógica de módulos +
interacciones + conformidad con lifecycle/misión, y resolver todo.

**Qué se hizo (commits `2917a73` → `d31bbb8` → `9f60ab9` → `8eb19e9` → `3f162eb`):**
- **Audit 6 agentes** (dinero, offline-first, change log, inventario/tickets,
  multi-tenant/seguridad, integridad estructural) → veredicto: app sólida,
  sin CRITICAL/HIGH. 6 MEDIUM + 8 LOW, **todos atacados**.
- Fixes clave: lock de `connectPowerSync` (cierra el sync-gate-stuck
  post-forzar-password) · clase 40 retryable en el connector · SLA de tickets
  sin corrimiento de 6h post-sync (`parseTicketWallClock`) · mirror local de
  cargos (saldo correcto offline) · migración **0114** (gate de módulos
  server-side: escritura de inv_*/tickets/incidentes + storage exige
  `tenant_tiene_modulo`) · `eliminar-cobrador` con 12 conteos nuevos tolerante
  a `PGRST205` · `HistorialTicketWidget` (agregador) · UploadResult de fotos
  persistido · password sin sesgo de módulo · viewer de audit ordena por
  `ocurrido_en`.
- **Audit final** (3 agentes sobre todo el diff): sin gaps de código.
- **Deploy verificado CON Rubén:** migraciones 0099→0112 confirmadas corridas
  (tablas 15/15, columnas 6/6, triggers 7/7) · 0114 corrida y verificada
  (~19 policies con el gate) · 4 edge functions redeployadas.
- **Pendiente:** smoke tests en la app — B.2 regresión 0114 con módulo ON ·
  B.3 forzar-password sin F5 · B.4 cargo offline · B.5 SLA estable tras sync ·
  B.6 historial del ticket.

## 2026-06-09 (a) — Checkpoint pre-MVP v1 (sesiones anteriores)

Estado al cierre de la ventana anterior: colores configurables de estados de
cuota across-app (6 estados, gate por rango del cobrador) · limpieza de
settings + recibo con zonas + "Restaurar layout" · fix pantalla negra del
reset · menú Pagos respetando setting para el super. Migración 0113 corrida.
Branch checkpoint: `pre-mvp-v1` (commit `48111e5`).

## Historia anterior (resumen telegráfico — detalle en `docs/archive/`)

- **2026-06-08:** audit integral multi-agente (11 agentes) + cancelar contrato
  = saldo 0 + 16 commits de fixes. Migraciones 0111/0112.
- **2026-06-05→07:** Fase 3 completa (tickets 3A→3E: técnico, materiales,
  incidentes, SLA offline) + inventario v2 + red. Schema v17→v26.
- **2026-06-04→06:** impresión térmica resuelta (GS v 0) · mapa offline ·
  reportes Excel/PDF · distribución Windows/Android (MSIX/APK + auto-update).
- **2026-05-23→06-03:** fundación: multi-tenant + RLS + PowerSync per-user ·
  invariantes de dinero + fix del vuelto · change log universal · impersonación
  · BULK 11/12 (multi-cuota, UX admin) · hardening de Edge Functions.

---

## 📌 Backlog vivo (lo REALMENTE pendiente — no re-flagear lo resuelto)

**Operativo (Rubén):**
- Smoke tests B.2–B.6 (ver entrada 2026-06-09 b).
- `flutter analyze` + `dart format` en el próximo build local.

**LOW / cuando toque (con contexto en `docs/archive/AUDIT-INTEGRAL-2026-06-09.md`):**
- Completar o eliminar el rol `admin_tickets` (hoy no se ofrece; decisión de producto).
- Tests: widget + integración + redirects del router (hoy 0).
- `/super/logs`: filtro de fechas + cron de retención >90d.
- `reenviar-invitacion`: lock delete→create (solo afecta con 2+ super_admins).
- Edge cases teóricos documentados: cross-tab sin sync, race autoDispose entre
  tenants, PKCE recovery user-switch, `lastSyncedAt` semantics.
- Config de distribución de producción: applicationId, cert, deep-links.

**Parqueados por decisión de Rubén:** flags `modo_ruta`/`caja_chica` (ocultos) ·
geo del cobro · Resend/dominio (externo).
