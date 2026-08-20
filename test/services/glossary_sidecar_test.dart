import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:subtitle_studio_pro/services/ai/glossary_store.dart';
import 'package:subtitle_studio_pro/services/ai/translation_service.dart'
    show GlossaryTerm, kGlossaryMaxTerms;

/// v1.3 术语表旁车文件化：`.glossary.json` 跟随字幕所在目录，
/// 同目录多任务共享；与全局词库合并（旁车同 source 优先）。
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('glossary_sidecar');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  group('GlossaryStore 读写', () {
    test('save → load round-trip 保序保内容', () async {
      final terms = [
        const GlossaryTerm(source: 'Aria', translation: '阿里亚'),
        const GlossaryTerm(source: 'Magic', translation: ''),
      ];
      await GlossaryStore.save(tmp.path, terms);

      final loaded = GlossaryStore.load(tmp.path);
      expect(loaded.length, 2);
      expect(loaded[0].source, 'Aria');
      expect(loaded[0].translation, '阿里亚');
      expect(loaded[1].translation, '', reason: '空译文（不译）应保留');
    });

    test('旁车路径固定为目录下 .glossary.json', () {
      expect(GlossaryStore.pathFor('D:/proj'),
          p.join('D:/proj', GlossaryStore.fileName));
    });

    test('目录无旁车 → load 返回空列表不抛', () {
      expect(GlossaryStore.load(tmp.path), isEmpty);
    });

    test('旁车 JSON 损坏 → 返回空列表不抛', () async {
      await File(GlossaryStore.pathFor(tmp.path)).writeAsString('{broken');
      expect(GlossaryStore.load(tmp.path), isEmpty);
    });

    test('旁车含空 source 条目 → 读取时过滤', () async {
      final raw = jsonEncode({
        'terms': [
          {'source': '', 'translation': 'x'},
          {'source': 'Aria', 'translation': '阿里亚'},
        ]
      });
      await File(GlossaryStore.pathFor(tmp.path)).writeAsString(raw);
      final loaded = GlossaryStore.load(tmp.path);
      expect(loaded.length, 1);
      expect(loaded.first.source, 'Aria');
    });
  });

  group('GlossaryStore.merge 合并语义', () {
    const global = [
      GlossaryTerm(source: 'Aria', translation: '全局译'),
      GlossaryTerm(source: 'Guild', translation: '公会'),
    ];
    const sidecar = [
      GlossaryTerm(source: 'Aria', translation: '旁车译'),
      GlossaryTerm(source: 'Dragon', translation: '龙'),
    ];

    test('旁车同 source 覆盖全局，其余叠加', () {
      final merged = GlossaryStore.merge(global: global, sidecar: sidecar);
      final bySource = {for (final t in merged) t.source: t};
      expect(bySource['Aria']!.translation, '旁车译');
      expect(bySource['Guild']!.translation, '公会');
      expect(bySource['Dragon']!.translation, '龙');
      expect(merged.length, 3);
    });

    test('旁车为空 → 全局原样', () {
      final merged = GlossaryStore.merge(global: global, sidecar: const []);
      expect(merged.length, global.length);
      expect(
          {for (final t in merged) '${t.source}=${t.translation}'},
          {for (final t in global) '${t.source}=${t.translation}'});
    });

    test('合并结果受 kGlossaryMaxTerms 上限约束（旁车优先保留）', () {
      final bigGlobal = [
        for (var i = 0; i < kGlossaryMaxTerms; i++)
          GlossaryTerm(source: 'g$i', translation: 'v$i'),
      ];
      final merged = GlossaryStore.merge(
        global: bigGlobal,
        sidecar: const [GlossaryTerm(source: 'Aria', translation: '旁车译')],
      );
      expect(merged.length, kGlossaryMaxTerms);
      expect(
        merged.where((t) => t.source == 'Aria'),
        isNotEmpty,
        reason: '超限裁剪时旁车条目优先保留',
      );
    });
  });

  group('mergedFor 文件级便捷入口', () {
    test('取字幕文件所在目录的旁车与全局合并', () async {
      await GlossaryStore.save(tmp.path,
          const [GlossaryTerm(source: 'Aria', translation: '旁车译')]);
      final merged = GlossaryStore.mergedFor('${tmp.path}/ep01.ass', const [
        GlossaryTerm(source: 'Aria', translation: '全局译'),
        GlossaryTerm(source: 'Guild', translation: '公会'),
      ]);
      final bySource = {for (final t in merged) t.source: t};
      expect(bySource['Aria']!.translation, '旁车译');
      expect(bySource['Guild']!.translation, '公会');
    });

    test('目录无旁车 → 仅全局', () {
      final merged = GlossaryStore.mergedFor('${tmp.path}/ep01.srt', const [
        GlossaryTerm(source: 'Aria', translation: '全局译'),
      ]);
      expect(merged.length, 1);
      expect(merged.first.translation, '全局译');
    });
  });
}
