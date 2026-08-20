import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/services/concurrent_probe_pool.dart';

void main() {
  group('ConcurrentProbePool', () {
    test('并发不超过 limit：4 个任务 limit=2，峰值并发 ≤ 2', () async {
      var concurrent = 0;
      var peak = 0;
      final pool = ConcurrentProbePool(limit: 2);

      Future<String> mockProbe(String input) async {
        concurrent++;
        peak = peak > concurrent ? peak : concurrent;
        await Future.delayed(const Duration(milliseconds: 50));
        concurrent--;
        return 'result_$input';
      }

      final inputs = ['a', 'b', 'c', 'd'];
      final results = <String>[];
      await pool.run(inputs, mockProbe, (input, result) {
        results.add(result);
      });

      expect(peak, lessThanOrEqualTo(2));
      expect(results.toSet(), {'result_a', 'result_b', 'result_c', 'result_d'});
      expect(results.length, 4);
    });

    test('limit=1 退化为串行', () async {
      var concurrent = 0;
      var peak = 0;
      final pool = ConcurrentProbePool(limit: 1);

      Future<String> mockProbe(String input) async {
        concurrent++;
        peak = peak > concurrent ? peak : concurrent;
        await Future.delayed(const Duration(milliseconds: 20));
        concurrent--;
        return input;
      }

      await pool.run(['x', 'y', 'z'], mockProbe, (_, __) {});
      expect(peak, 1);
    });

    test('空输入直接完成', () async {
      final pool = ConcurrentProbePool(limit: 3);
      final results = <String>[];
      await pool.run<String, String>([], (_) async => '', (_, result) => results.add(result));
      expect(results, isEmpty);
    });

    test('单个 probe 抛异常不阻断其他任务', () async {
      final pool = ConcurrentProbePool(limit: 2);
      final errors = <String>[];
      final oks = <String>[];

      await pool.run(
        ['ok1', 'fail', 'ok2'],
        (input) async {
          if (input == 'fail') throw Exception('boom');
          return input;
        },
        (input, result) => oks.add(result),
        onError: (input, error) => errors.add(input),
      );

      expect(oks.toSet(), {'ok1', 'ok2'});
      expect(errors, ['fail']);
    });
  });
}
