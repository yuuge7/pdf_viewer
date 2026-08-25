import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/services/document_service.dart';

String p(List<String> parts) => parts.join(Platform.pathSeparator);

void main() {
  group('encode / decode', () {
    test('round-trips every field', () {
      const ref = DocumentRef(
        uri: 'content://com.android.providers/document/1234',
        path: '/cache/open_1.pdf',
        name: 'report.pdf',
        canWrite: true,
      );
      final decoded = DocumentRef.decode(ref.encode())!;

      expect(decoded.uri, ref.uri);
      expect(decoded.path, ref.path);
      expect(decoded.name, ref.name);
      expect(decoded.canWrite, ref.canWrite);
    });

    test('preserves canWrite false', () {
      const ref = DocumentRef(
        uri: 'content://x/1',
        path: '/cache/a.pdf',
        name: 'a.pdf',
        canWrite: false,
      );
      expect(DocumentRef.decode(ref.encode())!.canWrite, isFalse);
    });
  });

  group('migration from bare paths', () {
    // Recent Files used to be a list of absolute paths. Upgrading must not
    // wipe the list.
    test('reads a legacy path entry', () {
      final path = p(['docs', 'legacy.pdf']);
      final ref = DocumentRef.decode(path)!;

      expect(ref.path, path);
      expect(ref.name, 'legacy.pdf');
      expect(ref.uri, isNull);
    });

    test('a legacy entry keys on its path', () {
      final path = p(['docs', 'legacy.pdf']);
      expect(DocumentRef.decode(path)!.key, path);
    });

    test('rejects empty and malformed entries', () {
      expect(DocumentRef.decode(''), isNull);
      expect(DocumentRef.decode('{not json'), isNull);
      expect(DocumentRef.decode('{"path":123}'), isNull);
      expect(DocumentRef.decode('{"uri":"content://x"}'), isNull);
    });
  });

  group('identity', () {
    test('the URI is the key when present, so cache copies collapse', () {
      const a = DocumentRef(
        uri: 'content://x/1',
        path: '/cache/open_1.pdf',
        name: 'a.pdf',
      );
      const b = DocumentRef(
        uri: 'content://x/1',
        path: '/cache/open_2.pdf',
        name: 'a.pdf',
      );
      // Same document re-opened later: different cache copy, same identity.
      expect(a.key, b.key);
    });

    test('paths key separately when there is no URI', () {
      const a = DocumentRef(path: '/docs/a.pdf', name: 'a.pdf');
      const b = DocumentRef(path: '/docs/b.pdf', name: 'b.pdf');
      expect(a.key, isNot(b.key));
    });
  });

  group('savesInPlace', () {
    test('a writable URI saves in place', () {
      const ref = DocumentRef(
        uri: 'content://x/1',
        path: '/cache/a.pdf',
        name: 'a.pdf',
        canWrite: true,
      );
      expect(ref.savesInPlace, isTrue);
    });

    test('a URI without a write grant does not', () {
      const ref = DocumentRef(
        uri: 'content://x/1',
        path: '/cache/a.pdf',
        name: 'a.pdf',
        canWrite: false,
      );
      expect(ref.savesInPlace, isFalse);
    });

    test('a plain file path saves in place', () {
      const ref = DocumentRef(path: '/docs/a.pdf', name: 'a.pdf');
      expect(ref.savesInPlace, isTrue);
    });
  });

  group('copyWith', () {
    test('replaces the cache path but keeps identity', () {
      const ref = DocumentRef(
        uri: 'content://x/1',
        path: '/cache/old.pdf',
        name: 'a.pdf',
        canWrite: true,
      );
      final refreshed = ref.copyWith(path: '/cache/new.pdf', canWrite: false);

      expect(refreshed.path, '/cache/new.pdf');
      expect(refreshed.canWrite, isFalse);
      expect(refreshed.uri, ref.uri);
      expect(refreshed.name, ref.name);
      expect(refreshed.key, ref.key);
    });
  });
}
