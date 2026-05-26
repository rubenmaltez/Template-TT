import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../../powersync/db.dart' as ps;

/// Selector geo en cascada (departamento → municipio → comunidad) con
/// opción de crear inline cualquier nivel si no existe.
/// Recibe `comunidadId` (puede ser null) y notifica cambios.
class GeoPicker extends StatefulWidget {
  const GeoPicker({super.key, required this.comunidadId, required this.onChanged});
  final String? comunidadId;
  final ValueChanged<String?> onChanged;

  @override
  State<GeoPicker> createState() => _GeoPickerState();
}

class _GeoPickerState extends State<GeoPicker> {
  String? _deptoId;
  String? _munId;
  String? _comId;
  bool _cargando = true;

  /// Stream cacheado para departamentos (query fija, no depende de state).
  /// Los streams de municipios y comunidades se dejan inline porque sus
  /// parámetros cambian con cada selección del usuario (cascading).
  late final Stream<List<Map<String, dynamic>>> _deptosStream;

  @override
  void initState() {
    super.initState();
    _deptosStream = ps.db.watch(
      'SELECT id, nombre FROM departamentos ORDER BY nombre',
    );
    _comId = widget.comunidadId;
    _resolverCascada();
  }

  @override
  void didUpdateWidget(covariant GeoPicker old) {
    super.didUpdateWidget(old);
    if (widget.comunidadId != _comId) {
      _comId = widget.comunidadId;
      _resolverCascada();
    }
  }

  /// Si llega un comunidadId pre-existente, hidratamos depto+municipio.
  Future<void> _resolverCascada() async {
    if (_comId == null) {
      setState(() => _cargando = false);
      return;
    }
    final rows = await ps.db.getAll(
      '''
      SELECT m.departamento_id AS depto, co.municipio_id AS mun
        FROM comunidades co
        JOIN municipios m ON m.id = co.municipio_id
       WHERE co.id = ?
      ''',
      [_comId],
    );
    if (rows.isNotEmpty) {
      _deptoId = rows.first['depto'] as String?;
      _munId = rows.first['mun'] as String?;
    }
    if (mounted) setState(() => _cargando = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: LinearProgressIndicator(),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Selector(
          label: 'Departamento',
          valueId: _deptoId,
          stream: _deptosStream,
          onChanged: (id) {
            setState(() {
              _deptoId = id;
              _munId = null;
              _comId = null;
            });
            widget.onChanged(null);
          },
          onCreate: (nombre) async {
            final id = const Uuid().v4();
            await ps.db.execute(
              'INSERT INTO departamentos (id, nombre, created_at) VALUES (?, ?, ?)',
              [id, nombre, DateTime.now().toIso8601String()],
            );
            return id;
          },
        ),
        const SizedBox(height: 12),
        _Selector(
          label: 'Municipio',
          valueId: _munId,
          enabled: _deptoId != null,
          stream: _deptoId == null
              ? const Stream.empty()
              : ps.db.watch(
                  'SELECT id, nombre FROM municipios WHERE departamento_id = ? ORDER BY nombre',
                  parameters: [_deptoId!],
                ),
          onChanged: (id) {
            setState(() {
              _munId = id;
              _comId = null;
            });
            widget.onChanged(null);
          },
          onCreate: _deptoId == null
              ? null
              : (nombre) async {
                  final id = const Uuid().v4();
                  await ps.db.execute(
                    'INSERT INTO municipios (id, departamento_id, nombre, created_at) VALUES (?, ?, ?, ?)',
                    [id, _deptoId, nombre, DateTime.now().toIso8601String()],
                  );
                  return id;
                },
        ),
        const SizedBox(height: 12),
        _Selector(
          label: 'Comunidad',
          valueId: _comId,
          enabled: _munId != null,
          stream: _munId == null
              ? const Stream.empty()
              : ps.db.watch(
                  'SELECT id, nombre FROM comunidades WHERE municipio_id = ? ORDER BY nombre',
                  parameters: [_munId!],
                ),
          onChanged: (id) {
            setState(() => _comId = id);
            widget.onChanged(id);
          },
          onCreate: _munId == null
              ? null
              : (nombre) async {
                  final id = const Uuid().v4();
                  await ps.db.execute(
                    'INSERT INTO comunidades (id, municipio_id, nombre, created_at) VALUES (?, ?, ?, ?)',
                    [id, _munId, nombre, DateTime.now().toIso8601String()],
                  );
                  return id;
                },
        ),
      ],
    );
  }
}

class _Selector extends StatelessWidget {
  const _Selector({
    required this.label,
    required this.valueId,
    required this.stream,
    required this.onChanged,
    this.onCreate,
    this.enabled = true,
  });

  final String label;
  final String? valueId;
  final Stream<List<Map<String, dynamic>>> stream;
  final ValueChanged<String?> onChanged;
  final Future<String> Function(String nombre)? onCreate;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: stream,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text('Error: ${snap.error}'));
        }
        final rows = snap.data!;
        // Verificar que valueId sigue existiendo en la lista; si no, reset.
        final stillExists =
            valueId == null || rows.any((r) => r['id'] == valueId);
        return Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String?>(
                value: stillExists ? valueId : null,
                decoration: InputDecoration(labelText: label, enabled: enabled),
                onChanged: enabled ? onChanged : null,
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('—')),
                  ...rows.map((r) => DropdownMenuItem(
                        value: r['id'] as String,
                        child: Text(r['nombre'] as String),
                      )),
                ],
              ),
            ),
            if (onCreate != null && enabled) ...[
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'Agregar $label',
                onPressed: () => _crear(context),
              ),
            ],
          ],
        );
      },
    );
  }

  Future<void> _crear(BuildContext context) async {
    final nombre = await showDialog<String?>(
      context: context,
      builder: (_) => _CrearDialog(label: label),
    );
    if (nombre == null || nombre.trim().isEmpty) return;
    try {
      final id = await onCreate!(nombre.trim());
      onChanged(id);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }
}

class _CrearDialog extends StatefulWidget {
  const _CrearDialog({required this.label});
  final String label;

  @override
  State<_CrearDialog> createState() => _CrearDialogState();
}

class _CrearDialogState extends State<_CrearDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Nueva ${widget.label.toLowerCase()}'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: InputDecoration(labelText: widget.label),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: const Text('Agregar'),
        ),
      ],
    );
  }
}
