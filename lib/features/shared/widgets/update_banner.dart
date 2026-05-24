import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/providers/update_provider.dart';

/// Banner que aparece en la parte superior de cualquier shell cuando
/// hay una actualización disponible. Muestra versión + release notes
/// + botón "Descargar".
///
/// Se oculta si no hay update, si el check falló, o si el user lo
/// descartó (dismiss por sesión, reaparece al reiniciar la app).
class UpdateBanner extends ConsumerStatefulWidget {
  const UpdateBanner({super.key});

  @override
  ConsumerState<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends ConsumerState<UpdateBanner> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();

    final updateAsync = ref.watch(updateAvailableProvider);

    return updateAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (update) {
        if (update == null) return const SizedBox.shrink();

        return Material(
          color: Colors.blue.shade800,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.system_update,
                    size: 20, color: Colors.blue.shade50),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Actualización disponible v${update.version}',
                        style: TextStyle(
                          color: Colors.blue.shade50,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      if (update.releaseNotes != null)
                        Text(
                          update.releaseNotes!,
                          style: TextStyle(
                            color: Colors.blue.shade100,
                            fontSize: 11,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => _download(update.downloadUrl),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.blue.shade50,
                  ),
                  child: const Text('Descargar'),
                ),
                IconButton(
                  icon: Icon(Icons.close,
                      size: 18, color: Colors.blue.shade100),
                  onPressed: () => setState(() => _dismissed = true),
                  tooltip: 'Cerrar',
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _download(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
