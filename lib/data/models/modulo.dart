/// Módulo del catálogo del sistema (cobranza, inventario, etc.).
/// Sólo el panel Super Admin lo lee — vía RPC `list_modulos`.
class Modulo {
  const Modulo({
    required this.codigo,
    required this.nombre,
    this.descripcion,
    required this.esBase,
    required this.orden,
  });

  final String codigo;
  final String nombre;
  final String? descripcion;
  final bool esBase;
  final int orden;

  factory Modulo.fromMap(Map<String, dynamic> m) => Modulo(
        codigo: m['codigo'] as String,
        nombre: m['nombre'] as String,
        descripcion: m['descripcion'] as String?,
        esBase: m['es_base'] as bool,
        orden: (m['orden'] as num).toInt(),
      );
}
