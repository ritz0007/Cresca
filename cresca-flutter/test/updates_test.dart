import 'package:test/test.dart';

import 'package:cresca_app/app/updates.dart';

void main() {
  group('tag compare', () {
    test('newer tags win, v-prefix + suffixes ignored', () {
      expect(isNewerTag('v1.5.0', '1.4.1'), isTrue);
      expect(isNewerTag('1.4.1', '1.4.1'), isFalse);
      expect(isNewerTag('1.4.0', '1.4.1'), isFalse);
      expect(isNewerTag('v2.0.0-beta', '1.9.9'), isTrue);
      expect(isNewerTag('1.10.0', '1.9.9'), isTrue);
      expect(isNewerTag('', '1.0.0'), isFalse);
    });
  });

  group('apk pick', () {
    test('exact ABI wins, else universal, else null', () {
      final names = [
        ('cresca-arm64.apk', 'u-arm64'),
        ('cresca-universal.apk', 'u-uni'),
      ];
      expect(
          pickApkAsset(names, deviceAbiOverride: 'arm64')!.$2,
          'u-arm64');
      expect(
          pickApkAsset(names, deviceAbiOverride: 'x86_64')!.$2,
          'u-uni');
      expect(
          pickApkAsset([], deviceAbiOverride: 'arm64'), isNull);
    });
  });

  group('release parse', () {
    test('draft/prerelease/tagless rejected', () {
      expect(parseRelease({'draft': true, 'tag_name': 'v1'}), isNull);
      expect(
          parseRelease(
              {'prerelease': true, 'tag_name': 'v1'}),
          isNull);
      expect(parseRelease({'tag_name': ''}), isNull);
      final u = parseRelease({
        'tag_name': 'v1.5.1',
        'html_url': 'https://rel',
        'assets': [
          {
            'name': 'cresca-universal.apk',
            'browser_download_url': 'https://apk'
          },
          {'name': 'notes.txt', 'browser_download_url': 'x'},
        ],
      })!;
      expect(u.tag, 'v1.5.1');
      expect(u.apkUrl, 'https://apk');
      expect(u.pageUrl, 'https://rel');
    });
  });
}
