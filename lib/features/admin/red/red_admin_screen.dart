import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';

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
    final nombre = await promptNombreRed(context, 'Nuevo nodo');
    if (nombre == null) return;
    final tenantId = ref.read(tenantIdProvider);
    try {
      await ps.db.execute(
        'INSERT INTO red_nodos (id, tenant_id, nombre, activo, created_at) VALUES (?, ?, ?, 1, ?)',
        [const Uuid().v4(), tenantId, nombre, DateTime.now().toIso8601String()],
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
    return ExpansionTile(
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
    );
  }

  Future<void> _crearHub(BuildContext context, String nodoId) async {
    final nombre = await promptNombreRed(context, 'Nuevo hub');
    if (nombre == null) return;
    final tenantId = widget.nodo['tenant_id'];
    try {
      await ps.db.execute(
        'INSERT INTO red_hubs (id, tenant_id, nodo_id, nombre, activo, created_at) VALUES (?, ?, ?, ?, 1, ?)',
        [const Uuid().v4(), tenantId, nodoId, nombre, DateTime.now().toIso8601String()],
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
    final nombre = await promptNombreRed(context, 'Nuevo puerto');
    if (nombre == null) return;
    final tenantId = widget.hub['tenant_id'];
    try {
      await ps.db.execute(
        'INSERT INTO red_puertos (id, tenant_id, hub_id, nombre, activo, created_at) VALUES (?, ?, ?, ?, 1, ?)',
        [const Uuid().v4(), tenantId, hubId, nombre, DateTime.now().toIso8601String()],
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }
}

/// Diálogo simple para pedir un nombre (compartido por los 3 niveles).
Future<String?> promptNombreRed(BuildContext context, String titulo) async {
  final ctrl = TextEditingController();
  final res = await showDialog<String?>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(titulo),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(labelText: 'Nombre'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, null),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text),
          child: const Text('Guardar'),
        ),
      ],
    ),
  );
  final nombre = res?.trim();
  return (nombre == null || nombre.isEmpty) ? null : nombre;
}
