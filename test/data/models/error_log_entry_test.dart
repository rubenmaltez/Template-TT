import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/models/error_log_entry.dart';

/// Tests de ErrorLogEntry — modelo del logger. La serialization es
/// crítica porque:
///   - El cliente persiste entries en SharedPreferences (FIFO 200).
///   - Si la serialization rompe, el logger pierde data silenciosa.
///   - Los logs guardados pre-cambio con un formato no se pueden
///     leer si se rompe el `fromJson`.
///
/// Tests pensados como guardia ante divergencia entre `toJson` y
/// `fromJson` — round-trip debe preservar todos los campos.
void main() {
  group('ErrorLogType.fromString', () {
    test('flutter → ErrorLogType.flutter', () {
      expect(ErrorLogType.fromString('flutter'), ErrorLogType.flutter);
    });

    test('zone → ErrorLogType.zone', () {
      expect(ErrorLogType.fromString('zone'), ErrorLogType.zone);
    });

    test('platform → ErrorLogType.platform', () {
      expect(ErrorLogType.fromString('platform'), ErrorLogType.platform);
    });

    test('string no reconocido → zone (default defensivo)', () {
      expect(ErrorLogType.fromString('basura'), ErrorLogType.zone);
      expect(ErrorLogType.fromString(''), ErrorLogType.zone);
    });
  });

  group('ErrorLogEntry serialization', () {
    ErrorLogEntry buildFullEntry() => ErrorLogEntry(
          id: 'abc-uuid-123',
          ts: DateTime.utc(2026, 5, 22, 14, 30, 45),
          type: ErrorLogType.flutter,
          message: 'Assertion failed at framework.dart:2168',
          stack: 'package:foo/bar.dart 42\n#1 main.dart 10',
          route: '/admin/clientes',
          userId: 'user-uuid-456',
          tenantId: 'tenant-uuid-789',
          userAgent: 'Mozilla/5.0',
          appVersion: '0.1.0+1',
          synced: false,
        );

    test('round-trip preserva todos los campos', () {
      final original = buildFullEntry();
      final json = original.toJson();
      final restored = ErrorLogEntry.fromJson(json);

      expect(restored.id, original.id);
      expect(restored.ts, original.ts);
      expect(restored.type, original.type);
      expect(restored.message, original.message);
      expect(restored.stack, original.stack);
      expect(restored.route, original.route);
      expect(restored.userId, original.userId);
      expect(restored.tenantId, original.tenantId);
      expect(restored.userAgent, original.userAgent);
      expect(restored.appVersion, original.appVersion);
      expect(restored.synced, original.synced);
    });

    test('round-trip preserva flag synced=true', () {
      final original = buildFullEntry().copyWith(synced: true);
      final json = original.toJson();
      final restored = ErrorLogEntry.fromJson(json);
      expect(restored.synced, true);
    });

    test('round-trip con campos opcionales en null', () {
      final original = ErrorLogEntry(
        id: 'x',
        ts: DateTime.utc(2026, 5, 22),
        type: ErrorLogType.zone,
        message: 'm',
      );
      final json = original.toJson();
      final restored = ErrorLogEntry.fromJson(json);
      expect(restored.stack, null);
      expect(restored.route, null);
      expect(restored.userId, null);
      expect(restored.tenantId, null);
      expect(restored.userAgent, null);
      expect(restored.appVersion, null);
      expect(restored.synced, false);
    });

    test('toJson incluye todos los campos como keys', () {
      final entry = buildFullEntry();
      final json = entry.toJson();
      expect(
          json.keys,
          containsAll([
            'id',
            'ts',
            'type',
            'message',
            'stack',
            'route',
            'user_id',
            'tenant_id',
            'user_agent',
            'app_version',
            'synced',
          ]));
    });

    test('ts se serializa como ISO 8601 string', () {
      final entry = buildFullEntry();
      final json = entry.toJson();
      expect(json['ts'], '2026-05-22T14:30:45.000Z');
    });

    test('type se serializa como string del enum', () {
      expect(buildFullEntry().toJson()['type'], 'flutter');
    });
  });

  group('ErrorLogEntry.toBackendInsert (payload Supabase)', () {
    test('mapea ts → ts, type → error_type, id → client_log_id', () {
      final entry = ErrorLogEntry(
        id: 'client-uuid',
        ts: DateTime.utc(2026, 5, 22, 14, 30),
        type: ErrorLogType.platform,
        message: 'platform err',
      );
      final insert = entry.toBackendInsert();

      // client_log_id va al servidor para idempotencia (PR #4 + UNIQUE
      // en migración 0035).
      expect(insert['client_log_id'], 'client-uuid');
      // error_type es el name del enum.
      expect(insert['error_type'], 'platform');
      // ts como ISO 8601.
      expect(insert['ts'], contains('2026-05-22'));
    });

    test('NO incluye `synced` (campo local only)', () {
      final entry = ErrorLogEntry(
        id: 'x',
        ts: DateTime.utc(2026, 5, 22),
        type: ErrorLogType.zone,
        message: 'm',
        synced: true,
      );
      final insert = entry.toBackendInsert();
      expect(insert.containsKey('synced'), false);
    });

    test('null fields se incluyen como null (Supabase los acepta)', () {
      final entry = ErrorLogEntry(
        id: 'x',
        ts: DateTime.utc(2026, 5, 22),
        type: ErrorLogType.zone,
        message: 'm',
      );
      final insert = entry.toBackendInsert();
      expect(insert['stack'], null);
      expect(insert['user_id'], null);
    });
  });

  group('ErrorLogEntry.copyWith', () {
    test('synced flag toggle preserva el resto', () {
      final original = ErrorLogEntry(
        id: 'x',
        ts: DateTime.utc(2026, 5, 22),
        type: ErrorLogType.flutter,
        message: 'm',
        stack: 's',
      );
      final copy = original.copyWith(synced: true);
      expect(copy.id, original.id);
      expect(copy.message, original.message);
      expect(copy.stack, original.stack);
      expect(copy.synced, true);
    });
  });

  group('ErrorLogEntry list encoding', () {
    test('encodeList + decodeList round-trip 3 entries', () {
      final entries = [
        ErrorLogEntry(
          id: '1',
          ts: DateTime.utc(2026, 5, 22),
          type: ErrorLogType.flutter,
          message: 'a',
        ),
        ErrorLogEntry(
          id: '2',
          ts: DateTime.utc(2026, 5, 21),
          type: ErrorLogType.zone,
          message: 'b',
        ),
        ErrorLogEntry(
          id: '3',
          ts: DateTime.utc(2026, 5, 20),
          type: ErrorLogType.platform,
          message: 'c',
        ),
      ];
      final encoded = ErrorLogEntry.encodeList(entries);
      final decoded = ErrorLogEntry.decodeList(encoded);

      expect(decoded, hasLength(3));
      expect(decoded[0].id, '1');
      expect(decoded[1].type, ErrorLogType.zone);
      expect(decoded[2].message, 'c');
    });

    test('encodeList de lista vacía', () {
      final encoded = ErrorLogEntry.encodeList([]);
      expect(ErrorLogEntry.decodeList(encoded), isEmpty);
    });

    test('decodeList con JSON corrupto retorna lista vacía (defensa)', () {
      // El service debe sobrevivir a corruption del SharedPreferences.
      expect(ErrorLogEntry.decodeList('no es json'), isEmpty);
      expect(ErrorLogEntry.decodeList(''), isEmpty);
      expect(ErrorLogEntry.decodeList('{}'), isEmpty);
      expect(ErrorLogEntry.decodeList('null'), isEmpty);
    });

    test('decodeList ignora elementos malformados pero no la lista entera',
        () {
      // Mezcla de entry válida y elemento basura → mantiene la válida,
      // descarta el basura. Crítico para no perder TODOS los logs si
      // alguno se corrompió.
      const mixed =
          '[{"id":"1","ts":"2026-05-22T00:00:00.000Z","type":"flutter","message":"ok"},"basura"]';
      final decoded = ErrorLogEntry.decodeList(mixed);
      expect(decoded, hasLength(1));
      expect(decoded.first.id, '1');
    });
  });

  group('ErrorLogEntry == y hashCode', () {
    test('mismo id + synced → iguales', () {
      final a = ErrorLogEntry(
        id: 'x',
        ts: DateTime.utc(2026, 5, 22),
        type: ErrorLogType.flutter,
        message: 'm',
      );
      final b = ErrorLogEntry(
        id: 'x',
        ts: DateTime.utc(2026, 5, 21), // ts distinto, no afecta ==
        type: ErrorLogType.zone, // type distinto, no afecta ==
        message: 'otro',
      );
      // R12 del repo: == basado en id + synced (lo único que cambia
      // en vivo). Suficiente para que Stream emita rebuild solo cuando
      // synced cambia.
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('mismo id pero synced distinto → distintos', () {
      final a = ErrorLogEntry(
        id: 'x',
        ts: DateTime.utc(2026, 5, 22),
        type: ErrorLogType.flutter,
        message: 'm',
      );
      final b = a.copyWith(synced: true);
      expect(a, isNot(equals(b)));
    });

    test('id distinto → distintos', () {
      final a = ErrorLogEntry(
        id: 'x',
        ts: DateTime.utc(2026, 5, 22),
        type: ErrorLogType.flutter,
        message: 'm',
      );
      final b = ErrorLogEntry(
        id: 'y',
        ts: DateTime.utc(2026, 5, 22),
        type: ErrorLogType.flutter,
        message: 'm',
      );
      expect(a, isNot(equals(b)));
    });
  });
}
