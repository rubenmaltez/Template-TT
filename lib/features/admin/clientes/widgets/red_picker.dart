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

  /// Streams cacheados (no inline en build): el form de cliente reconstruye en
  /// cada tecla, así que crear el stream en build re-suscribiría el StreamBuilder
  /// (anti-patrón "Stream already listened"). Los de hub/puerto se recrean en los
  /// onChanged / al hidratar.
  late final Stream<List<Map<String, dynamic>>> _nodosStream;
  Stream<List<Map<String, dynamic>>> _hubsStream = const Stream.empty();
  Stream<List<Map<String, dynamic>>> _puertosStream = const Stream.empty();

  Stream<List<Map<String, dynamic>>> _watchHubs(String nodoId) => ps.db.watch(
        'SELECT id, nombre FROM red_hubs WHERE nodo_id = ? ORDER BY nombre',
        parameters: [nodoId],
      );
  Stream<List<Map<String, dynamic>>> _watchPuertos(String hubId) => ps.db.watch(
        'SELECT id, nombre FROM red_puertos WHERE hub_id = ? ORDER BY nombre',
        parameters: [hubId],
      );

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
      if (_nodoId != null) _hubsStream = _watchHubs(_nodoId!);
      if (_hubId != null) _puertosStream = _watchPuertos(_hubId!);
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
        _RedSelector(
          label: 'Nodo',
          valueId: _nodoId,
          stream: _nodosStream,
          emptyHint: 'Aún no cargaste tu red. '
              'Configurala en Administración → Red.',
          onChanged: (id) {
            setState(() {
              _nodoId = id;
              _hubId = null;
              _puertoId = null;
              _hubsStream = id == null ? const Stream.empty() : _watchHubs(id);
              _puertosStream = const Stream.empty();
            });
            widget.onChanged(null);
          },
        ),
        const SizedBox(height: 12),
        _RedSelector(
          label: 'Hub',
          valueId: _hubId,
          enabled: _nodoId != null,
          stream: _hubsStream,
          onChanged: (id) {
            setState(() {
              _hubId = id;
              _puertoId = null;
              _puertosStream = const Stream.empty();
            });
            widget.onChanged(null);
          },
        ),
        const SizedBox(height: 12),
        _RedSelector(
          label: 'Puerto',
          valueId: _puertoId,
          enabled: _hubId != null,
          stream: _puertosStream,
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
    this.emptyHint,
  });

  final String label;
  final String? valueId;
  final Stream<List<Map<String, dynamic>>> stream;
  final ValueChanged<String?> onChanged;
  final bool enabled;

  /// Si el catálogo está vacío y este hint no es null, se muestra debajo del
  /// dropdown (ej. en Nodo: "cargá tu red en Administración → Red").
  final String? emptyHint;

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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String?>(
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
            if (rows.isEmpty && emptyHint != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 4),
                child: Text(
                  emptyHint!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline),
                ),
              ),
          ],
        );
      },
    );
  }
}
