import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';

/// CRUD del catálogo geográfico (departamento → municipio → comunidad).
/// Usa ExpansionTile anidado: tocar un departamento revela sus municipios,
/// tocar un municipio revela sus comunidades.
///
/// **StatefulWidget** (no Stateless) para cachear el stream de PowerSync
/// en `late _departamentos` inicializado en `initState`. Sin este cache,
/// cada `build()` del padre re-ejecuta `ps.db.watch(...)` retornando un
/// stream single-subscription; el `StreamBuilder` intenta resubscribirse
/// y choca con `Bad state: Stream has already been listened to`. Mismo
/// patrón que el fix aplicado a `_DeptoTile` / `_MunicipioTile`. Hoy
/// no se reproduce porque el padre no recibe triggers de rebuild
/// externos, pero sería bomba de tiempo ante cualquier cambio futuro
/// (provider watched arriba, resize de window en Web, theme switch).
class GeografiaAdminScreen extends StatefulWidget {
  const GeografiaAdminScreen({super.key});

  @override
  State<GeografiaAdminScreen> createState() => _GeografiaAdminScreenState();
}

class _GeografiaAdminScreenState extends State<GeografiaAdminScreen> {
  late final Stream<List<Map<String, dynamic>>> _departamentos;

  @override
  void initState() {
    super.initState();
    _departamentos =
        ps.db.watch('SELECT * FROM departamentos ORDER BY nombre');
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
                  'Catálogo geográfico (departamentos / municipios / comunidades). '
                  'Crece con uso — sólo agregá lo que necesités.',
                  style: TextStyle(color: Theme.of(context).colorScheme.outline),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Departamento'),
                onPressed: () => _crearDepto(context),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder(
            stream: _departamentos,
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final deptos = snap.data!;
              if (deptos.isEmpty) {
                return EmptyState(
                  icon: Icons.place_outlined,
                  titulo: 'Sin departamentos',
                  accion: FilledButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Agregar primero'),
                    onPressed: () => _crearDepto(context),
                  ),
                );
              }
              return ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: deptos
                    .map((d) => _DeptoTile(
                          key: ValueKey(d['id']?.toString() ?? ''),
                          depto: d,
                        ))
                    .toList(),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _crearDepto(BuildContext context) async {
    final nombre = await _promptNombre(context, 'Nuevo departamento');
    if (nombre == null) return;
    try {
      await ps.db.execute(
        'INSERT INTO departamentos (id, nombre, created_at) VALUES (?, ?, ?)',
        [const Uuid().v4(), nombre, DateTime.now().toIso8601String()],
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }
}

class _DeptoTile extends StatefulWidget {
  const _DeptoTile({super.key, required this.depto});
  final Map<String, dynamic> depto;

  @override
  State<_DeptoTile> createState() => _DeptoTileState();
}

class _DeptoTileState extends State<_DeptoTile> {
  // Stream cacheado en el state. Antes el `StreamBuilder` ejecutaba
  // `ps.db.watch(...)` dentro del `build()` — PowerSync cachea el stream
  // por (query+params), así que en el segundo build el `StreamBuilder`
  // intentaba resubscribirse al MISMO stream y fallaba con
  // `Bad state: Stream has already been listened to`. Capturado en
  // /super/logs durante smoke testing del sprint del logger.
  // Cacheando en `late` se crea una vez en initState y se reusa.
  late Stream<List<Map<String, dynamic>>> _municipios;

  @override
  void initState() {
    super.initState();
    _municipios = _watchMunicipios(widget.depto['id'] as String);
  }

  @override
  void didUpdateWidget(_DeptoTile old) {
    super.didUpdateWidget(old);
    // Si el padre rebuilda y nos pasa OTRO depto (mismo widget reusado
    // por posición en la lista, sin Key), recreamos el stream para que
    // apunte al departamento correcto. Sin esto, el tile mostraría
    // municipios del depto anterior.
    if (old.depto['id'] != widget.depto['id']) {
      _municipios = _watchMunicipios(widget.depto['id'] as String);
    }
  }

  Stream<List<Map<String, dynamic>>> _watchMunicipios(String deptoId) {
    return ps.db.watch(
      'SELECT * FROM municipios WHERE departamento_id = ? ORDER BY nombre',
      parameters: [deptoId],
    );
  }

  @override
  Widget build(BuildContext context) {
    final depto = widget.depto;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: const Icon(Icons.map),
        title: Text(depto['nombre'] as String),
        subtitle: depto['codigo'] != null ? Text(depto['codigo'] as String) : null,
        children: [
          StreamBuilder(
            stream: _municipios,
            builder: (context, snap) {
              final municipios = snap.data ?? const [];
              return Column(
                children: [
                  ...municipios.map((m) => _MunicipioTile(
                        key: ValueKey(m['id']?.toString() ?? ''),
                        municipio: m,
                      )),
                  ListTile(
                    leading: const Icon(Icons.add, size: 18),
                    title: const Text('Agregar municipio'),
                    onTap: () => _crearMunicipio(context, depto['id'] as String),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _crearMunicipio(BuildContext context, String deptoId) async {
    final nombre = await _promptNombre(context, 'Nuevo municipio');
    if (nombre == null) return;
    try {
      await ps.db.execute(
        'INSERT INTO municipios (id, departamento_id, nombre, created_at) VALUES (?, ?, ?, ?)',
        [const Uuid().v4(), deptoId, nombre, DateTime.now().toIso8601String()],
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }
}

class _MunicipioTile extends StatefulWidget {
  const _MunicipioTile({super.key, required this.municipio});
  final Map<String, dynamic> municipio;

  @override
  State<_MunicipioTile> createState() => _MunicipioTileState();
}

class _MunicipioTileState extends State<_MunicipioTile> {
  // Mismo patrón que _DeptoTileState — stream cacheado para evitar
  // `Bad state: Stream has already been listened to` en rebuilds.
  late Stream<List<Map<String, dynamic>>> _comunidades;

  @override
  void initState() {
    super.initState();
    _comunidades = _watchComunidades(widget.municipio['id'] as String);
  }

  @override
  void didUpdateWidget(_MunicipioTile old) {
    super.didUpdateWidget(old);
    if (old.municipio['id'] != widget.municipio['id']) {
      _comunidades = _watchComunidades(widget.municipio['id'] as String);
    }
  }

  Stream<List<Map<String, dynamic>>> _watchComunidades(String municipioId) {
    return ps.db.watch(
      'SELECT * FROM comunidades WHERE municipio_id = ? ORDER BY nombre',
      parameters: [municipioId],
    );
  }

  @override
  Widget build(BuildContext context) {
    final municipio = widget.municipio;
    return Padding(
      padding: const EdgeInsets.only(left: 16),
      child: ExpansionTile(
        leading: const Icon(Icons.location_city),
        title: Text(municipio['nombre'] as String),
        childrenPadding: const EdgeInsets.only(left: 16),
        children: [
          StreamBuilder(
            stream: _comunidades,
            builder: (context, snap) {
              final comunidades = snap.data ?? const [];
              return Column(
                children: [
                  ...comunidades.map((c) => ListTile(
                        dense: true,
                        leading: const Icon(Icons.place, size: 18),
                        title: Text(c['nombre'] as String),
                      )),
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.add, size: 18),
                    title: const Text('Agregar comunidad'),
                    onTap: () => _crearComunidad(context, municipio['id'] as String),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _crearComunidad(BuildContext context, String municipioId) async {
    final nombre = await _promptNombre(context, 'Nueva comunidad');
    if (nombre == null) return;
    try {
      await ps.db.execute(
        'INSERT INTO comunidades (id, municipio_id, nombre, created_at) VALUES (?, ?, ?, ?)',
        [const Uuid().v4(), municipioId, nombre, DateTime.now().toIso8601String()],
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }
}

Future<String?> _promptNombre(BuildContext context, String titulo) {
  // El controller vive sólo mientras el dialog está montado. Antes
  // lo creábamos acá pero nunca lo disponíamos — quedaba retenido por
  // la closure del builder con listeners apuntando a Elements ya
  // desmontados. En la siguiente navegación de vuelta a Geografía,
  // el rebuild del árbol pegaba contra
  // `_elements.contains(element) is not true` (framework.dart:2168).
  // whenComplete cubre happy AND error path del showDialog future.
  //
  // CRÍTICO: el builder recibe `dialogContext` (no `_`). Los Navigator.pop
  // de adentro DEBEN usar ese context, no el del screen capturado por
  // closure. Razón: el screen vive bajo ShellRoute de go_router; su
  // Navigator más cercano es el que go_router maneja con Page-based
  // navigation. Si pop usa el context del screen, go_router intercepta
  // el pop como si fuera Page, choca con `currentConfiguration.isNotEmpty`
  // (delegate.dart:162), y aunque el dialog cierre visualmente, el
  // Navigator queda en estado inconsistente. La siguiente navegación
  // por el sidebar cascadea: lifecycle inactive (framework.dart:4735) →
  // Duplicate GlobalKey → `_elements.contains` (framework.dart:2168) →
  // red screen. Diagnosticado vía /super/logs (sprint 0035).
  final ctrl = TextEditingController();
  return showDialog<String?>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(titulo),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Nombre'),
        onSubmitted: (v) => Navigator.pop(
            dialogContext, v.trim().isEmpty ? null : v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
              dialogContext, ctrl.text.trim().isEmpty ? null : ctrl.text.trim()),
          child: const Text('Agregar'),
        ),
      ],
    ),
  ).whenComplete(ctrl.dispose);
}
