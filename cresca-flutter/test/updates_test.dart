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
    test('exact ABI wins, else universal, else first', () {
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

  group('throttle', () {
    test('manual always checks; auto gated on last success', () {
      expect(
          shouldCheckForUpdates(
              manual: true, nowMs: 1000, lastCheckMs: 999),
          isTrue);
      expect(
          shouldCheckForUpdates(
              manual: false,
              nowMs: updateIntervalMs,
              lastCheckMs: 0),
          isTrue);
      expect(
          shouldCheckForUpdates(
              manual: false, nowMs: 1000, lastCheckMs: 1000),
          isFalse);
      expect(
          shouldCheckForUpdates(
              manual: false,
              nowMs: 1000 + updateIntervalMs,
              lastCheckMs: 1000),
          isTrue);
      expect(
          shouldCheckForUpdates(
              manual: false,
              nowMs: 1000 + updateIntervalMs - 1,
              lastCheckMs: 1000),
          isFalse);
    });
  });

  group('abi', () {
    test('normalizes SUPPORTED_ABIS entries to asset slugs', () {
      expect(normalizeAbi('arm64-v8a'), 'arm64');
      expect(normalizeAbi('armeabi-v7a'), 'armv7');
      expect(normalizeAbi('x86_64'), 'x86_64');
      expect(normalizeAbi(''), 'universal');
    });

    test('no exact/universal falls back to first asset', () {
      final names = [
        ('cresca-arm64.apk', 'u-arm64'),
        ('cresca-x86_64.apk', 'u-x86'),
      ];
      expect(pickApkAsset(names, deviceAbiOverride: 'armv7')!.$2,
          'u-arm64');
      expect(pickApkAsset([], deviceAbiOverride: 'arm64'), isNull);
    });

    test('parseRelease honors device ABI', () {
      Map<String, dynamic> rel(List<Map<String, String>> assets) => {
            'tag_name': 'v1.5.1',
            'html_url': 'https://rel',
            'assets': [
              for (final a in assets)
                {
                  'name': a['name'],
                  'browser_download_url': a['url']
                },
            ],
          };
      final o = rel([
        {'name': 'cresca-arm64.apk', 'url': 'https://arm64'},
        {'name': 'cresca-universal.apk', 'url': 'https://uni'},
      ]);
      expect(parseRelease(o, deviceAbi: 'arm64')!.apkUrl, 'https://arm64');
      expect(parseRelease(o, deviceAbi: 'x86_64')!.apkUrl, 'https://uni');
    });
  });
}
