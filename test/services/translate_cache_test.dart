import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:subtitle_studio_pro/models/subtitle.dart';
import 'package:subtitle_studio_pro/services/ai/translation_cache.dart';
import 'package:subtitle_studio_pro/services/ai/translation_service.dart';

/// v2.2.1 翻译内容缓存：
/// 行文本哈希 → 译文 JSON 缓存；重跑失败任务、翻译相似文件
/// （同剧集不同集数片头）零成本命中；部分命中只送未命中行。
void main() {
  const config =
      AiApiConfig(baseUrl: 'https://api.test', apiKey: 'k', model: 'm');
  final zh = TranslateLanguage.presets.first;

  SubtitleDocument doc(List<String> texts) => SubtitleDocument(
        format: SubtitleFormat.srt,
        cues: [
          for (var i = 0; i < texts.length; i++)
            SubtitleCue(
              index: i,
              start: Duration(milliseconds: i * 1000),
              end: Duration(milliseconds: i * 1000 + 900),
              rawText: texts[i],
            ),
        ],
      );

  late Directory tmp;
  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('translate_cache_test');
  });
  tearDownAll(() async {
    await tmp.delete(recursive: true);
  });

  group('TranslationCache 键与持久化', () {
    test('keyFor：稳定、区分语言、首尾空白归一', () {
      final a = TranslationCache.keyFor('zh', 'Hello');
      expect(a, TranslationCache.keyFor('zh', 'Hello'));
      expect(a, isNot(TranslationCache.keyFor('ja', 'Hello')),
          reason: '不同目标语言译文不同，键必须区分');
      expect(a, TranslationCache.keyFor('zh', '  Hello  '),
          reason: '首尾空白不影响命中');
      expect(a, isNot(TranslationCache.keyFor('zh', 'Hello!')));
    });

    test('put → flush → 新实例同路径 load → get 命中', () async {
      final path = p.join(tmp.path, 'a.json');
      final c1 = TranslationCache(path);
      await c1.put('zh', 'Hello', '你好');
      await c1.flush();
      expect(File(path).existsSync(), isTrue, reason: 'flush 落盘');

      final c2 = TranslationCache(path);
      expect(await c2.get('zh', 'Hello'), '你好');
      expect(await c2.get('zh', 'Bye'), isNull, reason: '未命中返回 null');
      expect(await c2.get('ja', 'Hello'), isNull);
    });

    test('文件损坏 → 空缓存不抛错', () async {
      final path = p.join(tmp.path, 'bad.json');
      File(path).writeAsStringSync('{不是 JSON');
      final c = TranslationCache(path);
      expect(await c.get('zh', 'Hello'), isNull);
      await c.put('zh', 'Hello', '你好');
      await c.flush();
      expect(File(path).readAsStringSync(), contains('你好'),
          reason: '损坏后被覆盖重建');
    });
  });

  group('translateDocument 缓存集成', () {
    test('部分命中：只送未命中行，命中行零网络回填', () async {
      final path = p.join(tmp.path, 'b.json');
      final cache = TranslationCache(path);
      await cache.put(zh.code, 'line 0', '缓存0');
      await cache.put(zh.code, 'line 2', '缓存2');

      final requested = <String>[];
      final out = await TranslationService.instance.translateDocument(
        doc(['line 0', 'line 1', 'line 2', 'line 3']),
        config: config,
        target: zh,
        cache: cache,
        chatOverride: ({required system, required user}) async {
          final lines = parseUserLines(user);
          requested.addAll(lines);
          return jsonEncode({
            'lines': [for (final l in lines) '译${l.split(' ').last}'],
          });
        },
      );
      expect(requested, ['line 1', 'line 3'],
          reason: '命中的 0/2 行不发起网络请求');
      expect(out.cues.map((c) => c.rawText).toList(),
          ['缓存0', '译1', '缓存2', '译3'],
          reason: '缓存与新鲜译文按原顺序合并');
    });

    test('全部命中：不发起任何网络请求', () async {
      final path = p.join(tmp.path, 'c.json');
      final cache = TranslationCache(path);
      await cache.put(zh.code, 'line 0', '缓存0');
      await cache.put(zh.code, 'line 1', '缓存1');

      var calls = 0;
      final out = await TranslationService.instance.translateDocument(
        doc(['line 0', 'line 1']),
        config: config,
        target: zh,
        cache: cache,
        chatOverride: ({required system, required user}) async {
          calls++;
          return '不会被调用';
        },
      );
      expect(calls, 0);
      expect(out.cues.map((c) => c.rawText).toList(), ['缓存0', '缓存1']);
    });

    test('新译文写回缓存并落盘：重跑零网络', () async {
      final path = p.join(tmp.path, 'd.json');
      final cache = TranslationCache(path);
      await TranslationService.instance.translateDocument(
        doc(['line 0', 'line 1']),
        config: config,
        target: zh,
        cache: cache,
        chatOverride: ({required system, required user}) async => jsonEncode({
              'lines': [
                for (final l in parseUserLines(user)) '译${l.split(' ').last}',
              ],
            }),
      );
      expect(await cache.get(zh.code, 'line 0'), '译0');

      // 重跑同内容（模拟同剧集另一集片头）：全部命中
      var calls = 0;
      final out = await TranslationService.instance.translateDocument(
        doc(['line 0', 'line 1']),
        config: config,
        target: zh,
        cache: cache,
        chatOverride: ({required system, required user}) async {
          calls++;
          return '不会被调用';
        },
      );
      expect(calls, 0, reason: '重跑完全命中缓存，零成本');
      expect(out.cues.map((c) => c.rawText).toList(), ['译0', '译1']);
    });
  });
}

/// 从 user payload JSON 取 lines 列表。
List<String> parseUserLines(String user) {
  final m = jsonDecode(user) as Map<String, dynamic>;
  return [for (final e in m['lines'] as List) '$e'];
}
