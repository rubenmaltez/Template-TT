import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Resultado de una visita de campo del cobrador.
enum VisitaResultado {
  cobrado('Cobrado'),
  noEstaba('No estaba'),
  sinPago('Sin pago'),
  promesaPago('Promesa de pago'),
  otro('Otro');

  const VisitaResultado(this.label);
  final String label;

  static VisitaResultado fromString(String s) => switch (s) {
        'cobrado' => VisitaResultado.cobrado,
        'no_estaba' => VisitaResultado.noEstaba,
        'sin_pago' => VisitaResultado.sinPago,
        'promesa_pago' => VisitaResultado.promesaPago,
        _ => VisitaResultado.otro,
      };

  String get value => switch (this) {
        VisitaResultado.cobrado => 'cobrado',
        VisitaResultado.noEstaba => 'no_estaba',
        VisitaResultado.sinPago => 'sin_pago',
        VisitaResultado.promesaPago => 'promesa_pago',
        VisitaResultado.otro => 'otro',
      };
}

/// Registro de una visita a un cliente.
class Visita {
  const Visita({
    required this.fecha,
    required this.resultado,
    this.notas,
  });

  final DateTime fecha;
  final VisitaResultado resultado;
  final String? notas;

  Map<String, dynamic> toJson() => {
        'fecha': fecha.toIso8601String(),
        'resultado': resultado.value,
        if (notas != null && notas!.isNotEmpty) 'notas': notas,
      };

  factory Visita.fromJson(Map<String, dynamic> json) => Visita(
        fecha: DateTime.parse(json['fecha'] as String),
        resultado: VisitaResultado.fromString(json['resultado'] as String),
        notas: json['notas'] as String?,
      );
}

/// Servicio de visitas local (SharedPreferences).
///
/// Almacena las visitas como un JSON array bajo la clave
/// `visitas_{clienteId}`. Cada cliente tiene su lista independiente.
/// Máximo 50 visitas por cliente (FIFO — las más viejas se descartan).
///
/// Nota: esta data es per-device y no sincroniza entre dispositivos.
/// En un sprint futuro se puede migrar a una tabla `visitas` en
/// Postgres/PowerSync para habilitar sync + visibilidad del admin.
class VisitasService {
  static const _maxVisitas = 50;
  static String _key(String clienteId) => 'visitas_$clienteId';

  /// Registra una visita para el cliente dado.
  Future<void> registrar({
    required String clienteId,
    required VisitaResultado resultado,
    String? notas,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final visitas = await listar(clienteId);
    visitas.insert(
      0,
      Visita(
        fecha: DateTime.now(),
        resultado: resultado,
        notas: notas,
      ),
    );

    // Mantener solo las últimas _maxVisitas
    final trimmed = visitas.length > _maxVisitas
        ? visitas.sublist(0, _maxVisitas)
        : visitas;

    await prefs.setString(
      _key(clienteId),
      jsonEncode(trimmed.map((v) => v.toJson()).toList()),
    );
  }

  /// Lista las visitas del cliente, ordenadas por fecha descendente.
  Future<List<Visita>> listar(String clienteId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(clienteId));
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => Visita.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}

final visitasServiceProvider = Provider((_) => VisitasService());
