import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

/// Acciones del sistema operativo (llamar, abrir mapa de navegación, etc.).
/// Web-safe: en mobile abre la app nativa; en web hace fallback a clipboard
/// + snackbar cuando no aplica.
class ExternalActions {
  /// Abre el dialer con el teléfono. En web copia al clipboard.
  static Future<void> llamar(BuildContext context, String telefono) async {
    final normalizado = telefono.replaceAll(RegExp(r'[^0-9+]'), '');
    if (kIsWeb) {
      await Clipboard.setData(ClipboardData(text: normalizado));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Teléfono $normalizado copiado')),
        );
      }
      return;
    }
    final uri = Uri.parse('tel:$normalizado');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir el marcador')),
      );
    }
  }

  /// Abre WhatsApp con el teléfono (sólo mobile; en web abre web.whatsapp.com).
  static Future<void> whatsapp(BuildContext context, String telefono) async {
    final n = telefono.replaceAll(RegExp(r'[^0-9]'), '');
    final uri = Uri.parse(
        kIsWeb ? 'https://wa.me/$n' : 'whatsapp://send?phone=$n');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Abre la app de mapas/navegación con coordenadas.
  /// Android/iOS: usa esquema geo:; web: Google Maps.
  static Future<void> navegarA(
    BuildContext context, {
    required double lat,
    required double lng,
    String? label,
  }) async {
    final uri = kIsWeb
        ? Uri.parse(
            'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng')
        : Uri.parse('geo:$lat,$lng?q=$lat,$lng${label != null ? "(${Uri.encodeComponent(label)})" : ""}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay app de mapas instalada')),
      );
    }
  }
}
