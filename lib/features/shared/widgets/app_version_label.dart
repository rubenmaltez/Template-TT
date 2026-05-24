import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Widget que muestra la versión de la app en texto sutil.
/// Se coloca en el footer de los shells (sidebar/drawer).
class AppVersionLabel extends StatelessWidget {
  const AppVersionLabel({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'v${snap.data!.version}',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        );
      },
    );
  }
}
