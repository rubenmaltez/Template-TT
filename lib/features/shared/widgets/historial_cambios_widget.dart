import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;

class HistorialCambiosWidget extends StatefulWidget {
  const HistorialCambiosWidget({
    super.key,
    required this.tabla,
    required this.registroId,
  });
  final String tabla;
  final String registroId;

  @override
  State<HistorialCambiosWidget> createState() => _HistorialCambiosWidgetState();
}

class _HistorialCambiosWidgetState extends State<HistorialCambiosWidget> {
  late Stream<List<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _buildStream();
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    return ps.db.watch(
      '''
      SELECT a.id, a.accion, a.campo,
             a.valor_anterior, a.valor_nuevo,
             a.user_id, a.user_rol, a.created_at,
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
        if (rows.isEmpty) {
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
          itemCount: rows.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final r = rows[i];
            return _CambioTile(row: r);
          },
        );
      },
    );
  }
}

class _CambioTile extends StatelessWidget {
  const _CambioTile({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accion = row['accion'] as String? ?? 'update';
    final fecha = DateTime.parse(row['created_at'] as String);
    final autor = row['user_nombre'] as String? ?? row['user_rol'] as String? ?? '—';

    final (IconData icon, Color color, String label) = switch (accion) {
      'create' => (Icons.add_circle_outline, scheme.tertiary, 'Creado'),
      'delete' => (Icons.delete_outline, scheme.error, 'Eliminado'),
      'anulacion' => (Icons.block, scheme.error, 'Anulado'),
      _ => (Icons.edit, scheme.primary, 'Editado'),
    };

    final cambios = _extraerCambios(row);

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

  List<_CampoChange> _extraerCambios(Map<String, dynamic> row) {
    final anteriorRaw = row['valor_anterior'] as String?;
    final nuevoRaw = row['valor_nuevo'] as String?;
    if (anteriorRaw == null && nuevoRaw == null) return [];

    try {
      final anterior = anteriorRaw != null ? jsonDecode(anteriorRaw) : null;
      final nuevo = nuevoRaw != null ? jsonDecode(nuevoRaw) : null;

      if (anterior is Map && nuevo is Map) {
        final cambios = <_CampoChange>[];
        final allKeys = {...anterior.keys, ...nuevo.keys};
        const skip = {'id', 'tenant_id', 'client_local_id', 'created_at', 'updated_at'};
        for (final key in allKeys) {
          if (skip.contains(key)) continue;
          final a = anterior[key];
          final n = nuevo[key];
          if (a != n) {
            cambios.add(_CampoChange(
              campo: _humanize(key),
              antes: _fmt(a),
              despues: _fmt(n),
            ));
          }
        }
        return cambios;
      }

      return [
        _CampoChange(
          campo: row['campo'] as String? ?? 'valor',
          antes: _fmt(anterior),
          despues: _fmt(nuevo),
        ),
      ];
    } catch (_) {
      return [
        _CampoChange(
          campo: row['campo'] as String? ?? 'valor',
          antes: anteriorRaw ?? '—',
          despues: nuevoRaw ?? '—',
        ),
      ];
    }
  }

  static String _fmt(dynamic v) {
    if (v == null) return '—';
    if (v is bool) return v ? 'Sí' : 'No';
    if (v is num) return v.toStringAsFixed(v.truncateToDouble() == v ? 0 : 2);
    return v.toString();
  }

  static String _humanize(String raw) {
    return raw
        .replaceAll('_', ' ')
        .replaceFirstMapped(RegExp(r'^.'), (m) => m[0]!.toUpperCase());
  }
}

class _CampoChange {
  const _CampoChange({required this.campo, required this.antes, required this.despues});
  final String campo;
  final String antes;
  final String despues;
}
