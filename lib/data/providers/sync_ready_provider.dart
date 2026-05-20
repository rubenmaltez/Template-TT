import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_identity_provider.dart';
import 'sync_status_provider.dart';

/// Boolean derivado que indica si la UI puede mostrarse o si hay que
/// esperar a que PowerSync sincronice tras un cambio de identidad.
///
/// Retorna `true` cuando:
///   - No hay sesión (el router redirigirá a /login, no hay nada
///     que gatear).
///   - La identidad nunca cambió en este proceso ni cross-session
///     (`changedAt == null`, restore inicial del último user conocido).
///   - PowerSync confirmó un sync POSTERIOR al último cambio de
///     identidad (`lastSyncedAt > changedAt`).
///
/// Retorna `false` cuando hay un changedAt pero PowerSync aún no
/// confirmó un sync más reciente. En ese caso el router redirige a
/// `/sync-gate`.
///
/// No es `autoDispose` a propósito: el router escucha esta dependencia
/// continuamente y el cierre/reapertura causaría rebuilds raros.
final syncReadyProvider = Provider<bool>((ref) {
  final identity = ref.watch(authIdentityProvider);

  if (identity.userId == null) return true;
  if (identity.changedAt == null) return true;

  final lastSyncedAt =
      ref.watch(syncStatusProvider).valueOrNull?.lastSyncedAt;
  if (lastSyncedAt == null) return false;

  return lastSyncedAt.isAfter(identity.changedAt!);
});
