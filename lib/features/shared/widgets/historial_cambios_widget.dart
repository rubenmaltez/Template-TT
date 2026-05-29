import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/audit_changelog.dart';
import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;

class HistorialCambiosWidget extends ConsumerStatefulWidget {
  const HistorialCambiosWidget({
    super.key,
    required this.tabla,
    required this.registroId,
  });
  final String tabla;
  final String registroId;

  @override
  ConsumerState<HistorialCambiosWidget> createState() =>
      _HistorialCambiosWidgetState();
}

class _HistorialCambiosWidgetState
    extends ConsumerState<HistorialCambiosWidget> {
  late Stream<List<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _buildStream();
  }

  @override
  void didUpdateWidget(HistorialCambiosWidget old) {
    super.didUpdateWidget(old);
    if (old.registroId != widget.registroId || old.tabla != widget.tabla) {
      setState(() => _stream = _buildStream());
    }
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    return ps.db.watch(
      '''
      SELECT a.id, a.accion, a.campo,
             a.valor_anterior, a.valor_nuevo,
             a.user_id, a.user_rol, a.created_at, a.ocurrido_en,
             c.nombre AS user_nombre
        FROM audit_log a
   LEFT JOIN cobradores c ON c.id = a.user_id
       WHERE a.registro_id = ? AND a.tabla = ?
       ORDER BY a.created_at DESC
       LIMIT 50
      ''',
      parameters: [widget.registroId, widget.tabla],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Config per-tenant de campos visibles (Fase C). Si una tabla no está en
    // el map, `auditExtraerCambios` cae al default curado por tabla.
    final cfg = ref.watch(appSettingsProvider).auditCamposVisibles;

    return StreamBuilder(
      stream: _stream,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final rows = snap.data!;
        // Inyectamos la tabla del widget en cada row (la query de tabla-única
        // no la selecciona) para que la curaduría del allowlist sepa el origen.
        final eventos = <_EventoVisual>[];
        for (final r in rows) {
          final rowConTabla = {...r, 'tabla': widget.tabla};
          final accion = auditDetectarAccion(rowConTabla);
          final cambios = auditExtraerCambios(
            rowConTabla,
            camposVisibles: cfg[widget.tabla],
          );
          // Hide-empty: descartar updates que quedan sin cambios tras curaduría
          // (eventos fantasma, ej. delta 0 en cargos_neto). Create/delete/
          // anulacion se muestran aunque tengan pocos campos.
          if (accion == 'update' && cambios.isEmpty) continue;
          eventos.add(_EventoVisual(
            row: rowConTabla,
            accion: accion,
            tabla: widget.tabla,
            cambios: cambios,
          ));
        }

        if (eventos.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text('Sin cambios registrados',
                  style: TextStyle(color: scheme.outline)),
            ),
          );
        }

        return ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: eventos.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) => _CambioTile(evento: eventos[i]),
        );
      },
    );
  }
}

// Un evento listo para renderizar. `cambios` ya viene curado; `extraLineas`
// son líneas adicionales precompuestas (usado al fusionar un cobro: el
// resultado de la cuota se anexa al card del pago).
class _EventoVisual {
  _EventoVisual({
    required this.row,
    required this.accion,
    required this.tabla,
    required this.cambios,
    this.extraLineas = const [],
  });
  final Map<String, dynamic> row;
  final String accion;
  final String? tabla;
  final List<CampoChange> cambios;
  final List<CampoChange> extraLineas;

  List<CampoChange> get todos => [...cambios, ...extraLineas];
}

class _CambioTile extends StatelessWidget {
  const _CambioTile({required this.evento});
  final _EventoVisual evento;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final row = evento.row;
    // ocurrido_en = hora REAL del dispositivo cuando ocurrió la acción
    // (offline-first). Fallback a created_at (hora server al sincronizar)
    // para filas viejas previas a la Fase B. Ambas en UTC → toLocal().
    final fecha = DateTime.parse(
      (row['ocurrido_en'] ?? row['created_at']) as String,
    ).toLocal();
    final autor =
        row['user_nombre'] as String? ?? row['user_rol'] as String? ?? '—';

    final (IconData icon, Color color, String label) =
        _labelFor(evento.accion, evento.tabla, scheme);

    final cambios = evento.todos;

    return ExpansionTile(
      leading: Icon(icon, color: color, size: 20),
      title: Text(label,
          style: TextStyle(fontWeight: FontWeight.w600, color: color)),
      subtitle: Text(
        '${Fmt.fechaCorta(fecha)} ${Fmt.hora(fecha)} · $autor',
        style: TextStyle(color: scheme.outline, fontSize: 12),
      ),
      children: [
        if (cambios.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text('Sin detalles disponibles',
                style: TextStyle(color: scheme.outline, fontSize: 12)),
          )
        else
          ...cambios.map((c) => Padding(
                padding: const EdgeInsets.fromLTRB(56, 0, 16, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 100,
                      child: Text(c.campo,
                          style: TextStyle(
                            color: scheme.outline,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          )),
                    ),
                    Expanded(
                      child: Text(
                        '${c.antes} → ${c.despues}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              )),
        const SizedBox(height: 4),
      ],
    );
  }

  // Etiqueta + ícono + color del evento. Si `tabla` viene seteada (timeline
  // unificada), las etiquetas distinguen cuota vs pago; si es null, caen a las
  // genéricas (Creado / Editado / Anulado / Eliminado).
  (IconData, Color, String) _labelFor(
      String accion, String? tabla, ColorScheme scheme) {
    switch (tabla) {
      case 'cuotas':
        return switch (accion) {
          'create' => (Icons.receipt_long, scheme.tertiary, 'Cuota generada'),
          'delete' => (Icons.delete_outline, scheme.error, 'Cuota eliminada'),
          'anulacion' => (Icons.block, scheme.error, 'Cuota anulada'),
          _ => (Icons.edit, scheme.primary, 'Cuota actualizada'),
        };
      case 'pagos':
        return switch (accion) {
          'create' => (Icons.payments, scheme.tertiary, 'Pago registrado'),
          'delete' => (Icons.delete_outline, scheme.error, 'Pago eliminado'),
          'anulacion' => (Icons.block, scheme.error, 'Pago anulado'),
          _ => (Icons.edit, scheme.primary, 'Pago editado'),
        };
      default:
        return switch (accion) {
          'create' => (Icons.add_circle_outline, scheme.tertiary, 'Creado'),
          'delete' => (Icons.delete_outline, scheme.error, 'Eliminado'),
          'anulacion' => (Icons.block, scheme.error, 'Anulado'),
          _ => (Icons.edit, scheme.primary, 'Editado'),
        };
    }
  }
}

// ---------------------------------------------------------------------------
// Timeline unificada de una cuota: mezcla los cambios de la propia cuota
// (generación + cambios de estado/monto_pagado) con los cambios de TODOS los
// pagos asociados (registro / anulación / edición). Una sola línea de tiempo
// cronológica para entender "qué le pasó a esta cuota".
// ---------------------------------------------------------------------------
class HistorialCuotaWidget extends ConsumerStatefulWidget {
  const HistorialCuotaWidget({super.key, required this.cuotaId});
  final String cuotaId;

  @override
  ConsumerState<HistorialCuotaWidget> createState() =>
      _HistorialCuotaWidgetState();
}

class _HistorialCuotaWidgetState extends ConsumerState<HistorialCuotaWidget> {
  late Stream<List<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _buildStream();
  }

  @override
  void didUpdateWidget(HistorialCuotaWidget old) {
    super.didUpdateWidget(old);
    if (old.cuotaId != widget.cuotaId) {
      setState(() => _stream = _buildStream());
    }
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    // Entries de la cuota + entries de sus pagos, unidas en una sola query.
    // La subquery `IN (SELECT ...)` corre sobre SQLite local (válida acá; la
    // restricción de "sin subqueries" aplica a las SYNC RULES, no a las
    // queries de `ps.db.watch`). Orden ASC = cronológico hacia adelante.
    return ps.db.watch(
      '''
      SELECT a.id, a.tabla, a.accion, a.campo,
             a.valor_anterior, a.valor_nuevo,
             a.user_id, a.user_rol, a.created_at, a.ocurrido_en,
             c.nombre AS user_nombre
        FROM audit_log a
   LEFT JOIN cobradores c ON c.id = a.user_id
       WHERE (a.tabla = 'cuotas' AND a.registro_id = ?)
          OR (a.tabla = 'pagos' AND a.registro_id IN (
                SELECT id FROM pagos WHERE cuota_id = ?
              ))
       ORDER BY a.created_at ASC
       LIMIT 100
      ''',
      parameters: [widget.cuotaId, widget.cuotaId],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Config per-tenant de campos visibles (Fase C).
    final cfg = ref.watch(appSettingsProvider).auditCamposVisibles;

    return StreamBuilder(
      stream: _stream,
      builder: (context, snap) {
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text('Error al cargar el historial',
                  style: TextStyle(color: scheme.error)),
            ),
          );
        }
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final rows = snap.data!;
        final eventos = _construirEventos(rows, cfg);

        if (eventos.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text('Sin movimientos registrados',
                  style: TextStyle(color: scheme.outline)),
            ),
          );
        }

        return ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: eventos.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) => _CambioTile(evento: eventos[i]),
        );
      },
    );
  }

  // Pre-procesa las filas crudas del audit_log en una lista de eventos
  // visuales, aplicando:
  //  1. Curaduría + hide-empty (igual que la timeline de tabla-única).
  //  2. "Un cobro = un solo evento": un pago/create + las cuota/update que
  //     genera (mismo user_id y created_at dentro de ≤3s) se fusionan en un
  //     solo card "Pago registrado" con el resultado de la cuota anexado.
  //     Las cuota/update absorbidas NO se muestran por separado.
  // El orden cronológico ASC se preserva (el card del grupo toma la posición
  // del pago/create).
  List<_EventoVisual> _construirEventos(
    List<Map<String, dynamic>> rows,
    Map<String, Set<String>> cfg,
  ) {
    const ventana = Duration(seconds: 3);

    // Parseamos la hora de la acción una vez para el matching de ventana.
    // Usamos ocurrido_en (hora de dispositivo) con fallback a created_at:
    // es la que ahora marca el orden real del cobro offline-first.
    final parsed = rows.map((r) {
      final raw = (r['ocurrido_en'] ?? r['created_at']) as String? ?? '';
      final dt = DateTime.tryParse(raw);
      return (row: r, ts: dt);
    }).toList();

    // Índices de cuota/update ya absorbidos por un grupo de pago.
    final absorbidos = <int>{};

    // Para cada pago/create, buscar cuota/update del mismo user dentro de la
    // ventana, y marcarlas como absorbidas anexando su resultado.
    for (var i = 0; i < parsed.length; i++) {
      final p = parsed[i];
      final row = p.row;
      if (row['tabla'] != 'pagos') continue;
      final accion = auditDetectarAccion(row);
      if (accion != 'create') continue;
      final pagoTs = p.ts;
      final pagoUser = row['user_id'];
      if (pagoTs == null) continue;

      for (var j = 0; j < parsed.length; j++) {
        if (j == i || absorbidos.contains(j)) continue;
        final q = parsed[j];
        final qr = q.row;
        if (qr['tabla'] != 'cuotas') continue;
        if (auditDetectarAccion(qr) != 'update') continue;
        if (qr['user_id'] != pagoUser) continue;
        final qts = q.ts;
        if (qts == null) continue;
        if ((qts.difference(pagoTs)).abs() > ventana) continue;
        absorbidos.add(j);
      }
    }

    final eventos = <_EventoVisual>[];

    for (var i = 0; i < parsed.length; i++) {
      if (absorbidos.contains(i)) continue;
      final row = parsed[i].row;
      final tabla = row['tabla'] as String?;
      final accion = auditDetectarAccion(row);
      final cambios = auditExtraerCambios(row, camposVisibles: cfg[tabla]);

      // Hide-empty: descartar updates sin cambios tras curaduría. No aplica a
      // create/delete/anulacion.
      if (accion == 'update' && cambios.isEmpty) continue;

      // Si es un pago/create, anexar el resultado de las cuota/update que
      // absorbió (líneas extra del card combinado).
      final extra = <CampoChange>[];
      if (tabla == 'pagos' && accion == 'create') {
        final pagoTs = parsed[i].ts;
        final pagoUser = row['user_id'];
        if (pagoTs != null) {
          for (var j = 0; j < parsed.length; j++) {
            if (!absorbidos.contains(j)) continue;
            final qr = parsed[j].row;
            final qts = parsed[j].ts;
            if (qr['tabla'] != 'cuotas') continue;
            if (qr['user_id'] != pagoUser) continue;
            if (qts == null) continue;
            if ((qts.difference(pagoTs)).abs() > ventana) continue;
            extra.addAll(
              auditExtraerCambios(qr, camposVisibles: cfg['cuotas']),
            );
          }
        }
      }

      eventos.add(_EventoVisual(
        row: row,
        accion: accion,
        tabla: tabla,
        cambios: cambios,
        extraLineas: extra,
      ));
    }

    return eventos;
  }
}
