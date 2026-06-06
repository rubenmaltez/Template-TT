# HANDOFF — dónde vamos quedando

> **Claude: leé ESTO PRIMERO al abrir la sesión.** Es el estado vivo del
> proyecto, en una pantalla. Mantenelo CORTO (≤1 pantalla). El detalle vive en
> los otros docs (links abajo). **Actualizá este archivo al CERRAR cada sesión**
> (es parte del lifecycle de CLAUDE.md, Fase 6).

---

## Estado actual

- **Branch de trabajo:** `claude/stoic-tesla-cGkJ6`
- **Último commit:** `90666cf` — Router: transición FadeThrough (zoom + fade) 400ms
- **Schema PowerSync:** `_schemaVersion = 16` (`lib/powersync/db.dart`). Sin cambios de DB pendientes.
- **Plataformas target:** Android + Windows (web degrada sin romper, NO es target).
- **App version:** v0.9.0 (ver `RELEASE.md`).

## Última sesión (2026-06-06 cont.) — qué se hizo

Lote UX/reportes, **sin migraciones**, auditado (3 agentes, 0 bloqueantes):
1. **Reportes con detalle USD** (cobros/por cobrador/fiscal): columnas Moneda /
   Entregado (orig.) / Tasa / Vuelto. Recaudado sigue = `monto_cordobas`. PDFs en landscape.
2. **Impresora del sistema en PC** (recibo, solo desktop): `Printing.layoutPdf`.
3. **Búsqueda multi-campo en el mapa**: nombre/cédula/teléfono/código cliente/código contrato.
4. **Transición entre vistas** — varias iteraciones hasta que cerró:
   (a) `AnimatedSwitcher`/`_ShellFade` envolviendo el body → fallaba (el Navigator
   interno del ShellRoute cruzaba 2 pantallas encimadas);
   (b) fade secuencial por ruta con `Interval` → Rubén lo vio brusco/parpadeo;
   (c) **FINAL (`90666cf`): FadeThrough (zoom + fade) 400ms** por ruta
   (`pageBuilder` + `CustomTransitionPage` + `_FadeThrough` que distingue
   entrante/saliente por `animation.status`). Todo en `router.dart`.
   **Lección:** en `ShellRoute` la transición va a NIVEL DE PÁGINA (pageBuilder),
   no envolviendo el body; y un fade plano se siente barato → sumar movimiento (zoom).
5. **Dashboard** sin card "Acciones rápidas".

Detalle completo → `REPORTE-SESION.md` (entrada 2026-06-06 cont.).

## Pendiente / próximo paso

- ⏳ **Rubén está testeando** el lote en Windows (pull `68577f9` + **restart completo**, no hot reload). Falta su OK del fade secuencial y de la impresora cableada con su equipo real.
- 📄 `ARQUITECTURA.md` recién generado — **revisar** que el mapa de módulos/interconexiones sea correcto antes de confiar 100%.
- Backlog persistente: ver fin de `CLAUDE.md` (no re-flaggear ítems ya resueltos).

## Docs del proyecto (qué leer y para qué)

| Doc | Para qué |
|---|---|
| `HANDOFF.md` (este) | Dónde quedamos AHORA. Leer primero. |
| `CLAUDE.md` | Reglas, proceso/lifecycle, invariantes de dinero, backlog. |
| `ARQUITECTURA.md` | Módulos y cómo se interconectan (flujo de datos). |
| `ESTADO-APP.md` | Snapshot detallado de estado/cobertura/findings. |
| `REPORTE-SESION.md` | Comportamiento esperado por feature + historial de fixes. |
| `TESTING.md` | Cómo se testea (setup + loop manual por feature). |
| `STACK.md` / `ROADMAP.md` | Stack técnico / plan a futuro. |
