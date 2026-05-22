import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';

/// CRUD del catálogo geográfico (departamento → municipio → comunidad).
/// Usa ExpansionTile anidado: tocar un departamento revela sus municipios,
/// tocar un municipio revela sus comunidades.
class GeografiaAdminScreen extends StatelessWidget {
  const GeografiaAdminScreen({super.key});

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
            stream: ps.db
                .watch('SELECT * FROM departamentos ORDER BY nombre'),
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
                children: deptos.map((d) => _DeptoTile(depto: d)).toList(),
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

class _DeptoTile extends StatelessWidget {
  const _DeptoTile({required this.depto});
  final Map<String, dynamic> depto;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: const Icon(Icons.map),
        title: Text(depto['nombre'] as String),
        subtitle: depto['codigo'] != null ? Text(depto['codigo'] as String) : null,
        children: [
          StreamBuilder(
            stream: ps.db.watch(
              'SELECT * FROM municipios WHERE departamento_id = ? ORDER BY nombre',
              parameters: [depto['id']],
            ),
            builder: (context, snap) {
              final municipios = snap.data ?? const [];
              return Column(
                children: [
                  ...municipios.map((m) => _MunicipioTile(municipio: m)),
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

class _MunicipioTile extends StatelessWidget {
  const _MunicipioTile({required this.municipio});
  final Map<String, dynamic> municipio;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 16),
      child: ExpansionTile(
        leading: const Icon(Icons.location_city),
        title: Text(municipio['nombre'] as String),
        childrenPadding: const EdgeInsets.only(left: 16),
        children: [
          StreamBuilder(
            stream: ps.db.watch(
              'SELECT * FROM comunidades WHERE municipio_id = ? ORDER BY nombre',
              parameters: [municipio['id']],
            ),
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
