import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/utils/extension_permission_gate.dart';

void main() {
  group('diffPermissions', () {
    test('returns only newly requested permissions', () {
      expect(
        diffPermissions(
          ['network:a.example.com', 'storage'],
          ['network:a.example.com', 'network:b.example.com', 'storage', 'file'],
        ),
        ['network:b.example.com', 'file'],
      );
    });

    test('fresh installs and unchanged permissions produce no diff', () {
      expect(diffPermissions(const [], const []), isEmpty);
      expect(diffPermissions(const ['storage'], const ['storage']), isEmpty);
    });

    test('duplicates in the new list collapse to one entry', () {
      expect(
        diffPermissions(const [], const ['file', 'file', 'storage']),
        ['file', 'storage'],
      );
    });
  });
}
