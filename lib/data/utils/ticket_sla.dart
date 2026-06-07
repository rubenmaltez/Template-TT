import 'package:flutter/material.dart';

/// Helpers de tickets (Fase 3): SLA derivado en el cliente, código legible,
/// transiciones válidas y labels/colores. Sin model class: las pantallas usan
/// `Map<String, dynamic>` de `ps.db.watch` (mismo patrón que inventario).

/// Estado del SLA, DERIVADO en el cliente (no se persiste). El SLA es por TIPO
/// (`ticket_tipos.sla_horas`). Plazo = created_at + sla_horas + segundos_pausado.
/// Mientras el ticket está `en_espera` el SLA se considera PAUSADO (no vence);
/// resuelto/cerrado/cancelado lo cierran.
///
/// PAUSA EXACTA (migración 0105): el trigger server-side acumula en
/// `tickets.segundos_pausado` TODO el tiempo que el ticket estuvo en `en_espera`
/// (usando el device-time `ocurrido_en` de cada transición → offline-safe). Acá
/// lo sumamos al plazo. Offline mid-pausa: el cliente recién ve el `segundos_pausado`
/// actualizado al sincronizar (el trigger es server-side); hasta entonces el plazo
/// queda levemente conservador (más urgente, nunca oculta un vencimiento).
enum SlaEstado { sinSla, enPlazo, porVencer, vencido, pausado, cerrado }

const _estadosCerrados = {'resuelto', 'cerrado', 'cancelado'};

SlaEstado ticketSlaEstado({
  required String estado,
  required DateTime createdAt,
  int? slaHoras,
  int segundosPausado = 0, // tiempo acumulado en en_espera (no consume SLA)
  DateTime? ahora,
}) {
  if (_estadosCerrados.contains(estado)) return SlaEstado.cerrado;
  if (slaHoras == null || slaHoras <= 0) return SlaEstado.sinSla;
  if (estado == 'en_espera') return SlaEstado.pausado;
  final now = ahora ?? DateTime.now();
  // El plazo se corre por todo el tiempo que el ticket estuvo en espera.
  final deadline = createdAt
      .add(Duration(hours: slaHoras))
      .add(Duration(seconds: segundosPausado));
  if (now.isAfter(deadline)) return SlaEstado.vencido;
  // Por vencer: dentro del último 20% del plazo, con piso de 1h para SLAs largos,
  // pero NUNCA más del 50% del plazo — sin el techo, un SLA corto (1-5h) nacería
  // directo en "por vencer" porque el piso de 1h cubriría casi todo el plazo.
  final restante = deadline.difference(now);
  final minutosSla = slaHoras * 60;
  var umbralMin = (minutosSla * 0.2).round();
  if (umbralMin < 60) umbralMin = 60; // piso 1h
  final techo = (minutosSla * 0.5).round();
  if (umbralMin > techo) umbralMin = techo; // techo 50% del SLA
  if (restante <= Duration(minutes: umbralMin)) {
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
  // Estados terminales: solo se pueden REABRIR (ticket cancelado/cerrado por
  // error). Espeja exactamente el trigger server-side de 0103/0105.
  'cerrado': ['reabierto'],
  'cancelado': ['reabierto'],
};

List<String> transicionesDesde(String estado) =>
    kTransicionesTicket[estado] ?? const [];

/// Estados a los que un TÉCNICO puede mover un ticket desde el campo (subconjunto
/// de [kTransicionesTicket]). El admin hace el resto: cerrar, cancelar, reabrir y
/// reasignar. "Server gana": el trigger 0103 igual valida la transición base, y
/// la RLS (`is_ticket_staff`) permite el UPDATE — esto sólo acota lo que la UI del
/// técnico OFRECE, para que el flujo de campo sea simple (avanzar / pausar / resolver).
const kEstadosDestinoTecnico = {'en_progreso', 'en_espera', 'resuelto'};

/// Transiciones que la UI del técnico ofrece desde [estado]: las válidas filtradas
/// a [kEstadosDestinoTecnico].
List<String> transicionesTecnico(String estado) =>
    transicionesDesde(estado).where(kEstadosDestinoTecnico.contains).toList();

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
