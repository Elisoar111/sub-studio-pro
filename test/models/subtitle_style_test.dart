import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/models/subtitle.dart';

void main() {
  group('SubtitleStyle.fromAssStyleLine', () {
    test('Bold/Italic 取对列（v4+ Format 第 8/9 列）', () {
      // Format: Name, Fontname, Fontsize, Primary, Secondary, Outline,
      //         Back, Bold, Italic, Underline, ...
      const line =
          'Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,'
          '&H80000000,-1,-1,0,0,100,100,0,0,1,2,1,2,20,20,30,1';
      final st = SubtitleStyle.fromAssStyleLine(line);
      expect(st.bold, isTrue,
          reason: 'Bold 是第 8 列（index 7），当前读的是第 7 列 BackColour');
      expect(st.italic, isTrue, reason: 'Italic 是第 9 列（index 8）');
      expect(st.fontName, 'Arial');
      expect(st.fontSize, 20);
    });

    test('Bold/Italic 关闭时为 false', () {
      const line =
          'Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,'
          '&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,20,20,30,1';
      final st = SubtitleStyle.fromAssStyleLine(line);
      expect(st.bold, isFalse);
      expect(st.italic, isFalse);
    });
  });
}
