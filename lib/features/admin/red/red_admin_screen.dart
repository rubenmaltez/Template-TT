import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/mapa_picker_screen.dart';

/// Datos capturados por `_NodoDialog` (crear/editar nodo).
typedef _NodoData = ({
  String nombre,
  String? tipo,
  String? notas,
  double? lat,
  double? lng,
});

/// CRUD de la topología de red (Nodo → Hub → Puerto). Parte del módulo de
/// cobranza base (no es módulo opcional). Mismo patrón de ExpansionTile
/// anidado que la pantalla de geografía: tocar un nodo revela sus hubs, tocar
/// un hub revela sus puertos. Cada nivel se crea inline. Per-tenant (0098).
class RedAdminScreen extends ConsumerStatefulWidget {
  const RedAdminScreen({super.key});

  @override
  ConsumerState<RedAdminScreen> createState() => _RedAdminScreenState();
}

class _RedAdminScreenState extends ConsumerState<RedAdminScreen> {
  late final Stream<List<Map<String, dynamic>>> _nodos;

  @override
  void initState() {
    super.initState();
    _nodos = ps.db.watch('SELECT * FROM red_nodos ORDER BY nombre');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Topología de red (Nodo → Hub → Puerto). Asigná un puerto a '
                  'cada cliente para ubicarlo en la red.',
                  style: TextStyle(color: Theme.of(context).colorScheme.outline),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Nodo'),
                onPressed: () => _crearNodo(context),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: _nodos,
            initialData: const [],
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(child: Text('Error: ${snap.error}'));
              }
              final nodos = snap.data!;
              if (nodos.isEmpty) {
                return EmptyState(
                  icon: Icons.hub_outlined,
                  titulo: 'Sin nodos',
                  accion: FilledButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Agregar primero'),
                    onPressed: () => _crearNodo(context),
                  ),
                );
              }
              return ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: nodos
                    .map((n) => _NodoTile(
                          key: ValueKey(n['id']?.toString() ?? ''),
                          nodo: n,
                        ))
                    .toList(),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _crearNodo(BuildContext context) async {
    final res = await showDialog<_NodoData?>(
      context: context,
      builder: (_) => const _NodoDialog(),
    );
    if (res == null) return;
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return; // sin tenant resuelto no se puede crear
    try {
      await ps.db.execute(
        'INSERT INTO red_nodos (id, tenant_id, nombre, tipo, notas, lat, lng, activo, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)',
        [const Uuid().v4(), tenantId, res.nombre, res.tipo, res.notas, res.lat, res.lng, DateTime.now().toIso8601String()],
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }
}

class _NodoTile extends StatefulWidget {
  const _NodoTile({super.key, required this.nodo});
  final Map<String, dynamic> nodo;

  @override
  State<_NodoTile> createState() => _NodoTileState();
}

class _NodoTileState extends State<_NodoTile> {
  late Stream<List<Map<String, dynamic>>> _hubs;

  @override
  void initState() {
    super.initState();
    _hubs = _watch(widget.nodo['id'] as String);
  }

  @override
  void didUpdateWidget(_NodoTile old) {
    super.didUpdateWidget(old);
    if (old.nodo['id'] != widget.nodo['id']) {
      _hubs = _watch(widget.nodo['id'] as String);
    }
  }

  Stream<List<Map<String, dynamic>>> _watch(String nodoId) => ps.db.watch(
        'SELECT * FROM red_hubs WHERE nodo_id = ? ORDER BY nombre',
        parameters: [nodoId],
      );

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
      leading: const Icon(Icons.hub),
      title: Text(widget.nodo['nombre'] as String),
      childrenPadding: const EdgeInsets.only(left: 16),
      maintainState: true,
      children: [
        StreamBuilder<List<Map<String, dynamic>>>(
          stream: _hubs,
          initialData: const [],
          builder: (context, snap) {
            final hubs = snap.data!;
            return Column(
              children: [
                ...hubs.map((h) => _HubTile(
                      key: ValueKey(h['id']?.toString() ?? ''),
                      hub: h,
                    )),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.add, size: 18),
                  title: const Text('Agregar hub'),
                  onTap: () => _crearHub(context, widget.nodo['id'] as String),
                ),
              ],
            );
          },
        ),
      ],
      ),
    );
  }

  Future<void> _crearHub(BuildContext context, String nodoId) async {
    final res = await promptNombreNotasRed(context, 'Nuevo hub');
    if (res == null) return;
    final tenantId = widget.nodo['tenant_id'];
    try {
      await ps.db.execute(
        'INSERT INTO red_hubs (id, tenant_id, nodo_id, nombre, notas, activo, created_at) VALUES (?, ?, ?, ?, ?, 1, ?)',
        [const Uuid().v4(), tenantId, nodoId, res.nombre, res.notas, DateTime.now().toIso8601String()],
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }
}

class _HubTile extends StatefulWidget {
  const _HubTile({super.key, required this.hub});
  final Map<String, dynamic> hub;

  @override
  State<_HubTile> createState() => _HubTileState();
}

class _HubTileState extends State<_HubTile> {
  late Stream<List<Map<String, dynamic>>> _puertos;

  @override
  void initState() {
    super.initState();
    _puertos = _watch(widget.hub['id'] as String);
  }

  @override
  void didUpdateWidget(_HubTile old) {
    super.didUpdateWidget(old);
    if (old.hub['id'] != widget.hub['id']) {
      _puertos = _watch(widget.hub['id'] as String);
    }
  }

  Stream<List<Map<String, dynamic>>> _watch(String hubId) => ps.db.watch(
        'SELECT * FROM red_puertos WHERE hub_id = ? ORDER BY nombre',
        parameters: [hubId],
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 16),
      child: ExpansionTile(
        leading: const Icon(Icons.router),
        title: Text(widget.hub['nombre'] as String),
        childrenPadding: const EdgeInsets.only(left: 16),
        maintainState: true,
        children: [
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: _puertos,
            initialData: const [],
            builder: (context, snap) {
              final puertos = snap.data!;
              return Column(
                children: [
                  ...puertos.map((p) => ListTile(
                        dense: true,
                        leading: const Icon(Icons.settings_input_hdmi, size: 18),
                        title: Text(p['nombre'] as String),
                      )),
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.add, size: 18),
                    title: const Text('Agregar puerto'),
                    onTap: () => _crearPuerto(context, widget.hub['id'] as String),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _crearPuerto(BuildContext context, String hubId) async {
    final res = await promptNombreNotasRed(context, 'Nuevo puerto');
    if (res == null) return;
    final tenantId = widget.hub['tenant_id'];
    try {
      await ps.db.execute(
        'INSERT INTO red_puertos (id, tenant_id, hub_id, nombre, notas, activo, created_at) VALUES (?, ?, ?, ?, ?, 1, ?)',
        [const Uuid().v4(), tenantId, hubId, res.nombre, res.notas, DateTime.now().toIso8601String()],
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }
}

/// Diálogo para Hub/Puerto: nombre + notas (opcional).
Future<({String nombre, String? notas})?> promptNombreNotasRed(
    BuildContext context, String titulo) async {
  final nombreCtrl = TextEditingController();
  final notasCtrl = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(titulo),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: nombreCtrl,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Nombre'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: notasCtrl,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
                labelText: 'Notas (opcional)',
                hintText: 'Ej. detrás de la pulpería de Doña Rosa'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Guardar'),
        ),
      ],
    ),
  );
  final nombre = nombreCtrl.text.trim();
  final notas = notasCtrl.text.trim();
  nombreCtrl.dispose();
  notasCtrl.dispose();
  if (ok != true || nombre.isEmpty) return null;
  return (nombre: nombre, notas: notas.isEmpty ? null : notas);
}

/// Diálogo de Nodo: nombre + tipo (fibra/wireless/híbrido) + lat/lng (opcionales).
class _NodoDialog extends StatefulWidget {
  const _NodoDialog({this.inicial});

  /// Fila del nodo a editar (null = crear nuevo).
  final Map<String, dynamic>? inicial;

  @override
  State<_NodoDialog> createState() => _NodoDialogState();
}

class _NodoDialogState extends State<_NodoDialog> {
  final _nombre = TextEditingController();
  final _notas = TextEditingController();
  final _lat = TextEditingController();
  final _lng = TextEditingController();
  String? _tipo;

  @override
  void initState() {
    super.initState();
    final n = widget.inicial;
    if (n != null) {
      _nombre.text = n['nombre'] as String? ?? '';
      _notas.text = n['notas'] as String? ?? '';
      _lat.text = (n['lat'] as num?)?.toString() ?? '';
      _lng.text = (n['lng'] as num?)?.toString() ?? '';
      _tipo = n['tipo'] as String?;
    }
  }

  @override
  void dispose() {
    _nombre.dispose();
    _notas.dispose();
    _lat.dispose();
    _lng.dispose();
    super.dispose();
  }

  Future<void> _elegirEnMapa() async {
    final inicial = (double.tryParse(_lat.text) != null &&
            double.tryParse(_lng.text) != null)
        ? LatLng(double.parse(_lat.text), double.parse(_lng.text))
        : const LatLng(12.13, -86.25); // Managua default
    final picked = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(builder: (_) => MapaPickerScreen(inicial: inicial)),
    );
    if (picked != null && mounted) {
      setState(() {
        _lat.text = picked.latitude.toStringAsFixed(6);
        _lng.text = picked.longitude.toStringAsFixed(6);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.inicial == null ? 'Nuevo nodo' : 'Editar nodo'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nombre,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nombre'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              value: _tipo,
              decoration: const InputDecoration(labelText: 'Tipo (opcional)'),
              onChanged: (v) => setState(() => _tipo = v),
              items: const [
                DropdownMenuItem(value: null, child: Text('—')),
                DropdownMenuItem(value: 'fibra', child: Text('Fibra')),
                DropdownMenuItem(value: 'wireless', child: Text('Wireless')),
                DropdownMenuItem(value: 'hibrido', child: Text('Híbrido')),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notas,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                  labelText: 'Notas (opcional)',
                  hintText: 'Ej. torre detrás de la iglesia'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _lat,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true, signed: true),
                    decoration: const InputDecoration(labelText: 'Latitud'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _lng,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true, signed: true),
                    decoration: const InputDecoration(labelText: 'Longitud'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.map),
                label: const Text('Elegir en el mapa'),
                onPressed: _elegirEnMapa,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            final nombre = _nombre.text.trim();
            if (nombre.isEmpty) return;
            final notas = _notas.text.trim();
            Navigator.pop(context, (
              nombre: nombre,
              tipo: _tipo,
              notas: notas.isEmpty ? null : notas,
              lat: double.tryParse(_lat.text.trim()),
              lng: double.tryParse(_lng.text.trim()),
            ) as _NodoData);
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}
