import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../powersync/db.dart' as ps;

/// Resolución de FK (cobrador_id, cliente_id, etc.) a nombres legibles para
/// el change log. Sin esto, los UUIDs no aportan info al usuario y la Fase A
/// los oculta — pero entonces los cambios que SOLO tocan FK (ej. asignar un
/// cobrador a un cliente) quedan invisibles en el historial.
///
/// El provider se autodispose por screen; cada vez que se abre un bottom sheet
/// de historial se rearma. Bajo MVP es aceptable; si el dataset crece, se
/// puede convertir a un `StreamProvider` que cachee reactivamente.
class AuditLookups {
  const AuditLookups({
    this.cobradores = const {},
    this.clientes = const {},
    this.planes = const {},
    this.comunidades = const {},
    this.departamentos = const {},
    this.municipios = const {},
    this.contratos = const {},
    this.nodos = const {},
    this.hubs = const {},
    this.puertos = const {},
  });

  final Map<String, String> cobradores;
  final Map<String, String> clientes;
  final Map<String, String> planes;
  final Map<String, String> comunidades;
  final Map<String, String> departamentos;
  final Map<String, String> municipios;
  final Map<String, String> nodos;
  final Map<String, String> hubs;
  final Map<String, String> puertos;
  // Contratos no tienen nombre propio: usamos el nombre del plan asociado
  // ("Plan Básico 10 Mbps") como label, que es lo que el usuario reconoce.
  final Map<String, String> contratos;

  /// Devuelve el label humano para un FK, o `null` si la columna no es FK
  /// resoluble. Cubre además aliases comunes (`anulado_por` apunta a
  /// `cobradores`, `municipio_id` a `municipios`, etc.).
  String? resolve(String campo, String id) {
    final m = switch (campo) {
      'cobrador_id' || 'anulado_por' || 'user_id' => cobradores,
      'cliente_id' => clientes,
      'plan_id' => planes,
      'contrato_id' => contratos,
      'comunidad_id' => comunidades,
      'departamento_id' => departamentos,
      'municipio_id' => municipios,
      'nodo_id' => nodos,
      'hub_id' => hubs,
      'puerto_id' => puertos,
      _ => null,
    };
    if (m == null) return null;
    return m[id];
  }
}

/// Carga todos los mapas id→nombre en paralelo desde SQLite local. Cada query
/// es chiquita (mira solo id+nombre) y SQLite es rápido, así que el costo es
/// trivial salvo en tenants enormes (donde se puede agregar paginado/index).
final auditLookupsProvider = FutureProvider.autoDispose<AuditLookups>((ref) async {
  Future<Map<String, String>> _cargar(String sql) async {
    final rows = await ps.db.getAll(sql);
    final out = <String, String>{};
    for (final r in rows) {
      final id = r['id'] as String?;
      final nombre = r['nombre'] as String?;
      if (id != null && nombre != null && nombre.isNotEmpty) {
        out[id] = nombre;
      }
    }
    return out;
  }

  // Contratos: id + nombre del plan asociado vía JOIN (los contratos no tienen
  // nombre propio; el plan es lo que el usuario reconoce).
  Future<Map<String, String>> _cargarContratos() async {
    final rows = await ps.db.getAll('''
      SELECT c.id AS id, p.nombre AS nombre
        FROM contratos c
   LEFT JOIN planes p ON p.id = c.plan_id
    ''');
    final out = <String, String>{};
    for (final r in rows) {
      final id = r['id'] as String?;
      final nombre = r['nombre'] as String?;
      if (id != null) {
        out[id] = (nombre == null || nombre.isEmpty) ? 'Contrato' : nombre;
      }
    }
    return out;
  }

  final results = await Future.wait([
    _cargar('SELECT id, nombre FROM cobradores'),
    _cargar('SELECT id, nombre FROM clientes'),
    _cargar('SELECT id, nombre FROM planes'),
    _cargar('SELECT id, nombre FROM comunidades'),
    _cargar('SELECT id, nombre FROM departamentos'),
    _cargar('SELECT id, nombre FROM municipios'),
    _cargarContratos(),
    _cargar('SELECT id, nombre FROM red_nodos'),
    _cargar('SELECT id, nombre FROM red_hubs'),
    _cargar('SELECT id, nombre FROM red_puertos'),
  ]);

  return AuditLookups(
    cobradores: results[0],
    clientes: results[1],
    planes: results[2],
    comunidades: results[3],
    departamentos: results[4],
    municipios: results[5],
    contratos: results[6],
    nodos: results[7],
    hubs: results[8],
    puertos: results[9],
  );
});
