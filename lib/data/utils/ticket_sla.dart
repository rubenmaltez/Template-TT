import 'package:flutter/material.dart';

/// Helpers de tickets (Fase 3): SLA derivado en el cliente, código legible,
/// transiciones válidas y labels/colores. Sin model class: las pantallas usan
/// `Map<String, dynamic>` de `ps.db.watch` (mismo patrón que inventario).

/// Estado del SLA, DERIVADO en el cliente (no se persiste). El SLA es por TIPO
/// (`ticket_tipos.sla_horas`). Plazo = created_at + sla_horas. Mientras el ticket
/// está `en_espera` el SLA se considera PAUSADO (no vence); resuelto/cerrado/
/// cancelado lo cierran. NOTA: la pausa exacta (sumar todos los tramos en
/// `en_espera`) es refinamiento de v2; acá pausamos solo si está en espera AHORA.
enum SlaEstado { sinSla, enPlazo, porVencer, vencido, pausado, cerrado }

const _estadosCerrados = {'resuelto', 'cerrado', 'cancelado'};

SlaEstado ticketSlaEstado({
  required String estado,
  required DateTime createdAt,
  int? slaHoras,
  DateTime? ahora,
}) {
  if (_estadosCerrados.contains(estado)) return SlaEstado.cerrado;
  if (slaHoras == null || slaHoras <= 0) return SlaEstado.sinSla;
  if (estado == 'en_espera') return SlaEstado.pausado;
  final now = ahora ?? DateTime.now();
  final deadline = createdAt.add(Duration(hours: slaHoras));
  if (now.isAfter(deadline)) return SlaEstado.vencido;
  // Por vencer: dentro del último 20% del plazo (o de la última hora).
  final restante = deadline.difference(now);
  final umbral = Duration(minutes: (slaHoras * 60 * 0.2).round());
  if (restante <= umbral || restante <= const Duration(hours: 1)) {
    return SlaEstado.porVencer;
  }
  return SlaEstado.enPlazo;
}

String slaLabel(SlaEstado s) => switch (s) {
      SlaEstado.sinSla => 'Sin SLA',
      SlaEstado.enPlazo => 'En plazo',
      SlaEstado.porVencer => 'Por vencer',
      SlaEstado.vencido => 'Vencido',
      SlaEstado.pausado => 'En espera',
      SlaEstado.cerrado => 'Cerrado',
    };

Color slaColor(SlaEstado s, ColorScheme c) => switch (s) {
      SlaEstado.vencido => c.error,
      SlaEstado.porVencer => Colors.orange,
      SlaEstado.enPlazo => c.primary,
      SlaEstado.pausado => c.tertiary,
      SlaEstado.cerrado => c.outline,
      SlaEstado.sinSla => c.outline,
    };

/// Código legible del ticket: T-00001 (correlativo cliente-computado).
String ticketCodigo(num? correlativo) {
  if (correlativo == null || correlativo <= 0) return 'T-(s/n)';
  return 'T-${correlativo.toInt().toString().padLeft(5, '0')}';
}

// ── Estados del ticket ─────────────────────────────────────────────────────
const kTicketEstados = [
  'abierto', 'asignado', 'en_progreso', 'en_espera',
  'resuelto', 'cerrado', 'reabierto', 'cancelado',
];

String estadoTicketLabel(String e) => switch (e) {
      'abierto' => 'Abierto',
      'asignado' => 'Asignado',
      'en_progreso' => 'En progreso',
      'en_espera' => 'En espera',
      'resuelto' => 'Resuelto',
      'cerrado' => 'Cerrado',
      'reabierto' => 'Reabierto',
      'cancelado' => 'Cancelado',
      _ => e,
    };

Color estadoTicketColor(String e, ColorScheme c) => switch (e) {
      'abierto' => c.primary,
      'asignado' => c.secondary,
      'en_progreso' => Colors.blue,
      'en_espera' => c.tertiary,
      'resuelto' => Colors.green,
      'cerrado' => c.outline,
      'reabierto' => Colors.orange,
      'cancelado' => c.error,
      _ => c.outline,
    };

/// Transiciones de estado válidas (espeja el trigger server-side de 0103). La UI
/// solo ofrece estas; el server las re-valida ("server gana").
const Map<String, List<String>> kTransicionesTicket = {
  'abierto': ['asignado', 'en_progreso', 'cancelado'],
  'asignado': ['en_progreso', 'en_espera', 'abierto', 'cancelado'],
  'en_progreso': ['en_espera', 'resuelto', 'asignado', 'cancelado'],
  'en_espera': ['en_progreso', 'resuelto', 'cancelado'],
  'resuelto': ['cerrado', 'reabierto'],
  'reabierto': ['asignado', 'en_progreso', 'en_espera', 'resuelto', 'cancelado'],
  'cerrado': ['reabierto'],
  'cancelado': ['reabierto'],
};

List<String> transicionesDesde(String estado) =>
    kTransicionesTicket[estado] ?? const [];

// ── Prioridad ──────────────────────────────────────────────────────────────
const kTicketPrioridades = ['baja', 'media', 'alta', 'urgente'];

String prioridadLabel(String? p) => switch (p) {
      'baja' => 'Baja',
      'media' => 'Media',
      'alta' => 'Alta',
      'urgente' => 'Urgente',
      _ => '—',
    };

Color prioridadColor(String? p, ColorScheme c) => switch (p) {
      'urgente' => c.error,
      'alta' => Colors.orange,
      'media' => c.primary,
      'baja' => c.outline,
      _ => c.outline,
    };

// ── Eventos de la bitácora ─────────────────────────────────────────────────
String tipoEventoLabel(String t) => switch (t) {
      'creado' => 'Ticket creado',
      'asignado' => 'Asignado',
      'cambio_estado' => 'Cambio de estado',
      'comentario' => 'Comentario',
      'material' => 'Material',
      'adjunto' => 'Adjunto',
      'reabierto' => 'Reabierto',
      'cerrado' => 'Cerrado',
      'cancelado' => 'Cancelado',
      _ => t,
    };

IconData tipoEventoIcon(String t) => switch (t) {
      'creado' => Icons.add_circle_outline,
      'asignado' => Icons.person_pin_circle_outlined,
      'cambio_estado' => Icons.swap_horiz,
      'comentario' => Icons.chat_bubble_outline,
      'material' => Icons.inventory_2_outlined,
      'adjunto' => Icons.attach_file,
      'reabierto' => Icons.refresh,
      'cerrado' => Icons.check_circle_outline,
      'cancelado' => Icons.cancel_outlined,
      _ => Icons.circle,
    };
