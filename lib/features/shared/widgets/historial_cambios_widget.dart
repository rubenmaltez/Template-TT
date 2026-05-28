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
    final accionRaw = row['accion'] as String? ?? 'update';
    final fecha = DateTime.parse(row['created_at'] as String);
    final autor = row['user_nombre'] as String? ?? row['user_rol'] as String? ?? '—';

    // Detectar anulación: el trigger guarda 'update' pero el JSONB
    // contiene anulado: 0→1. Lo identificamos para mostrar "Anulado".
    final accion = _detectarAccion(accionRaw, row);

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

  // Columnas computadas / auto que se omiten en cualquier snapshot.
  static const _skipKeys = {
    'id', 'tenant_id', 'client_local_id', 'created_at', 'updated_at',
    'foto_comprobante_path', 'monto_pagado', 'cargos_neto',
  };

  List<_CampoChange> _extraerCambios(Map<String, dynamic> row) {
    final anteriorRaw = row['valor_anterior'] as String?;
    final nuevoRaw = row['valor_nuevo'] as String?;
    if (anteriorRaw == null && nuevoRaw == null) return [];

    try {
      final anterior = anteriorRaw != null ? jsonDecode(anteriorRaw) : null;
      final nuevo = nuevoRaw != null ? jsonDecode(nuevoRaw) : null;

      // UPDATE: ambos snapshots → diff campo por campo.
      if (anterior is Map && nuevo is Map) {
        final cambios = <_CampoChange>[];
        final allKeys = {...anterior.keys, ...nuevo.keys};
        for (final key in allKeys) {
          if (_skipKeys.contains(key)) continue;
          final a = anterior[key];
          final n = nuevo[key];
          if (a != n) {
            cambios.add(_CampoChange(
              campo: _fieldLabel(key),
              antes: _fmt(a),
              despues: _fmt(n),
            ));
          }
        }
        return cambios;
      }

      // CREATE: solo valor_nuevo. Mostramos los valores iniciales no nulos
      // como "— → valor".
      if (anterior == null && nuevo is Map) {
        return _snapshotAsCambios(nuevo, isCreate: true);
      }

      // DELETE: solo valor_anterior. Mostramos los valores eliminados
      // como "valor → —".
      if (nuevo == null && anterior is Map) {
        return _snapshotAsCambios(anterior, isCreate: false);
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

  // Convierte un snapshot completo (create/delete) en una lista de cambios
  // que el ExpansionTile pueda renderizar con el mismo widget que update.
  // - isCreate true:  "— → valor"  (campos del row inicial)
  // - isCreate false: "valor → —"  (campos del row eliminado)
  List<_CampoChange> _snapshotAsCambios(Map snap, {required bool isCreate}) {
    final cambios = <_CampoChange>[];
    for (final entry in snap.entries) {
      final key = entry.key as String;
      if (_skipKeys.contains(key)) continue;
      final v = entry.value;
      // Omitir nulls y vacíos del snapshot (no aportan info).
      if (v == null) continue;
      if (v is String && v.isEmpty) continue;
      cambios.add(_CampoChange(
        campo: _fieldLabel(key),
        antes: isCreate ? '—' : _fmt(v),
        despues: isCreate ? _fmt(v) : '—',
      ));
    }
    return cambios;
  }

  static String _detectarAccion(String accion, Map<String, dynamic> row) {
    if (accion != 'update') return accion;
    try {
      final nuevoRaw = row['valor_nuevo'] as String?;
      if (nuevoRaw == null) return accion;
      final nuevo = jsonDecode(nuevoRaw);
      if (nuevo is Map && nuevo['anulado'] == 1) return 'anulacion';
    } catch (_) {}
    return accion;
  }

  static String _fmt(dynamic v) {
    if (v == null) return '—';
    if (v is bool) return v ? 'Sí' : 'No';
    if (v is num) return v.toStringAsFixed(v.truncateToDouble() == v ? 0 : 2);
    final s = v.toString();
    if (s.length >= 19 && RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(s)) {
      final dt = DateTime.tryParse(s);
      if (dt != null) return Fmt.fechaCorta(dt);
    }
    if (s.length > 30) return '${s.substring(0, 27)}…';
    return s;
  }

  static String _fieldLabel(String raw) {
    const labels = {
      'monto_cordobas': 'Monto (C\$)',
      'monto_original': 'Monto original',
      'monto_pagado': 'Monto pagado',
      'vuelto_cordobas': 'Vuelto (C\$)',
      'fecha_pago': 'Fecha de pago',
      'fecha_vencimiento': 'Fecha vencimiento',
      'fecha_inicio': 'Fecha inicio',
      'fecha_fin': 'Fecha fin',
      'cobrador_id': 'Cobrador',
      'cliente_id': 'Cliente',
      'contrato_id': 'Contrato',
      'cuota_id': 'Cuota',
      'plan_id': 'Plan',
      'metodo': 'Método de pago',
      'moneda': 'Moneda',
      'tasa_conversion': 'Tasa de conversión',
      'anulado': 'Anulado',
      'anulado_en': 'Anulado en',
      'anulado_por': 'Anulado por',
      'motivo_anulacion': 'Motivo anulación',
      'estado': 'Estado',
      'monto': 'Monto',
      'periodo': 'Período',
      'nombre': 'Nombre',
      'telefono': 'Teléfono',
      'direccion': 'Dirección',
      'cedula': 'Cédula',
      'comunidad_id': 'Comunidad',
      'departamento_id': 'Departamento',
      'municipio_id': 'Municipio',
      'activo': 'Activo',
      'referencia': 'Referencia',
      'notas': 'Notas',
      'descripcion': 'Descripción',
      'numero_completo': 'Número recibo',
      'grupo_cobro': 'Cobro agrupado',
      'cargos_neto': 'Cargos neto',
      'lat': 'Latitud',
      'lng': 'Longitud',
      'dia_pago': 'Día de pago',
      'reimpresiones': 'Reimpresiones',
      'documento_path': 'Documento adjunto',
      'precio_mensual': 'Precio mensual',
      'tipo_cargo_manual': 'Tipo de cargo',
      'pago_id': 'Pago',
      'recibo_id': 'Recibo',
      'numero': 'Número',
      'prefijo': 'Prefijo',
      'serie': 'Serie',
      'rol': 'Rol',
      'email': 'Email',
      'prefijo_recibo': 'Prefijo recibo',
    };
    return labels[raw] ?? raw
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
