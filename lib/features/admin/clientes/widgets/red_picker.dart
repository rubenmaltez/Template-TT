import 'package:flutter/material.dart';

import '../../../../powersync/db.dart' as ps;

/// Selector en cascada de la topología de red (Nodo → Hub → Puerto) para
/// asignar `clientes.puerto_id`. **Solo selección** (la topología la administra
/// el admin en `/admin/red`; acá no se crea inline). El Hub y el Nodo se
/// derivan del Puerto elegido. Asignación opcional en el cliente.
class RedPicker extends StatefulWidget {
  const RedPicker({super.key, required this.puertoId, required this.onChanged});
  final String? puertoId;
  final ValueChanged<String?> onChanged;

  @override
  State<RedPicker> createState() => _RedPickerState();
}

class _RedPickerState extends State<RedPicker> {
  String? _nodoId;
  String? _hubId;
  String? _puertoId;
  bool _cargando = true;

  /// Stream cacheado de nodos (query fija). Hubs/puertos van inline porque sus
  /// parámetros cambian con cada selección (cascading).
  late final Stream<List<Map<String, dynamic>>> _nodosStream;

  @override
  void initState() {
    super.initState();
    _nodosStream =
        ps.db.watch('SELECT id, nombre FROM red_nodos ORDER BY nombre');
    _puertoId = widget.puertoId;
    _resolverCascada();
  }

  @override
  void didUpdateWidget(covariant RedPicker old) {
    super.didUpdateWidget(old);
    if (widget.puertoId != _puertoId) {
      _puertoId = widget.puertoId;
      _resolverCascada();
    }
  }

  /// Si llega un puertoId pre-existente, hidratamos nodo + hub.
  Future<void> _resolverCascada() async {
    if (_puertoId == null) {
      setState(() => _cargando = false);
      return;
    }
    final rows = await ps.db.getAll(
      '''
      SELECT h.nodo_id AS nodo, p.hub_id AS hub
        FROM red_puertos p
        JOIN red_hubs h ON h.id = p.hub_id
       WHERE p.id = ?
      ''',
      [_puertoId!],
    );
    if (!mounted) return;
    setState(() {
      if (rows.isNotEmpty) {
        _nodoId = rows.first['nodo'] as String?;
        _hubId = rows.first['hub'] as String?;
      }
      _cargando = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Conexión de red (opcional)',
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
        const SizedBox(height: 8),
        _RedSelector(
          label: 'Nodo',
          valueId: _nodoId,
          stream: _nodosStream,
          onChanged: (id) {
            setState(() {
              _nodoId = id;
              _hubId = null;
              _puertoId = null;
            });
            widget.onChanged(null);
          },
        ),
        const SizedBox(height: 12),
        _RedSelector(
          label: 'Hub',
          valueId: _hubId,
          enabled: _nodoId != null,
          stream: _nodoId == null
              ? const Stream.empty()
              : ps.db.watch(
                  'SELECT id, nombre FROM red_hubs WHERE nodo_id = ? ORDER BY nombre',
                  parameters: [_nodoId!],
                ),
          onChanged: (id) {
            setState(() {
              _hubId = id;
              _puertoId = null;
            });
            widget.onChanged(null);
          },
        ),
        const SizedBox(height: 12),
        _RedSelector(
          label: 'Puerto',
          valueId: _puertoId,
          enabled: _hubId != null,
          stream: _hubId == null
              ? const Stream.empty()
              : ps.db.watch(
                  'SELECT id, nombre FROM red_puertos WHERE hub_id = ? ORDER BY nombre',
                  parameters: [_hubId!],
                ),
          onChanged: (id) {
            setState(() => _puertoId = id);
            widget.onChanged(id);
          },
        ),
      ],
    );
  }
}

class _RedSelector extends StatelessWidget {
  const _RedSelector({
    required this.label,
    required this.valueId,
    required this.stream,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final String? valueId;
  final Stream<List<Map<String, dynamic>>> stream;
  final ValueChanged<String?> onChanged;
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
        final stillExists =
            valueId == null || rows.any((r) => r['id'] == valueId);
        return DropdownButtonFormField<String?>(
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
        );
      },
    );
  }
}
