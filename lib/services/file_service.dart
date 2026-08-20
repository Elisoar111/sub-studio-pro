import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';
import '../core/utils/logger.dart';

/// 选择的文件（Windows 桌面：磁盘路径）。
class PickedFile {
  final String? path;
  final String name;
  final int size;

  /// 内存字节（Web 端使用；Windows 桌面恒为 null，保留字段以兼容）。
  final Uint8List? bytes;

  const PickedFile({this.path, required this.name, this.size = 0, this.bytes});

  /// 是否为「无路径的内存文件」（Windows 桌面恒为 false）。
  bool get isWebFile => path == null && bytes != null;
}

/// 文件选择 / 保存工具（Windows 桌面）。
///
/// Windows 桌面应用无移动端权限限制，直接使用 file_picker 的
/// 原生对话框（WIN32 文件选择器）即可，无需存储权限。
class FileService {
  FileService._();

  static final FileService instance = FileService._();

  /// 从磁盘路径创建 [PickedFile]（拖拽导入场景）。
  static PickedFile pickedFromFile(String path) {
    final f = File(path);
    return PickedFile(
      path: path,
      name: p.basename(path),
      size: f.existsSync() ? f.lengthSync() : 0,
    );
  }

  // ─────────────────────── 目录管理 ───────────────────────

  /// 应用输出根目录（Documents/subtitle_studio/<sub>）。
  /// 与后端无关的中立目录工具（原在 FfmpegService，提取/封装走
  /// MKVToolNix 后迁出）。
  Future<String> outputDirFor(String sub) async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(base.path, AppConstants.appDirName, sub));
      await dir.create(recursive: true);
      return dir.path;
    } catch (_) {
      return sub; // Web：无文件系统，返回虚拟目录名
    }
  }

  // ─────────────────────── 选择 ───────────────────────

  Future<List<PickedFile>> pickVideos({bool multi = true}) => _pick(
        exts: AppConstants.videoExtensions,
        multi: multi,
        title: '选择视频文件',
      );

  Future<List<PickedFile>> pickSubtitles({bool multi = true}) => _pick(
        exts: AppConstants.subtitleExtensions,
        multi: multi,
        title: '选择字幕文件',
      );

  Future<List<PickedFile>> pickAudios({bool multi = true}) => _pick(
        exts: const ['aac', 'm4a', 'mp3', 'flac', 'wav', 'ac3', 'eac3', 'dts', 'ogg', 'opus', 'wma'],
        multi: multi,
        title: '选择音频文件',
      );

  /// 视频与音频（Whisper 转写输入，参考 WhisperElectron 支持清单）。
  Future<List<PickedFile>> pickMediaFiles({bool multi = true}) => _pick(
        exts: [
          ...AppConstants.videoExtensions,
          ...AppConstants.audioExtensions,
          'aac', 'ac3', 'eac3', 'dts', 'wma',
        ],
        multi: multi,
        title: '选择视频/音频文件',
      );

  Future<List<PickedFile>> pickAttachments({bool multi = true}) => _pick(
        exts: const ['ttf', 'otf', 'woff', 'woff2', 'jpg', 'jpeg', 'png'],
        multi: multi,
        title: '选择附件（字体/图片）',
      );

  /// 选择 JSON 文件（术语表旁车导入）。
  Future<List<PickedFile>> pickJsonFile() => _pick(
        exts: const ['json'],
        multi: false,
        title: '选择术语表文件（.glossary.json）',
      );

  Future<List<PickedFile>> _pick({
    required List<String> exts,
    required bool multi,
    String? title,
  }) async {
    try {
      // file_picker 12：pickFiles 恒为多选（返回列表），单选走 pickFile
      if (multi) {
        final files = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: exts,
          dialogTitle: title,
        );
        return [
          for (final f in files)
            PickedFile(path: f.path, name: f.name, size: await f.length()),
        ];
      }
      final f = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: exts,
        dialogTitle: title,
      );
      if (f == null) return const [];
      return [PickedFile(path: f.path, name: f.name, size: await f.length())];
    } catch (e) {
      Logger.instance.error('文件选择失败', e);
      rethrow;
    }
  }

  /// 选择目录（返回目录路径）。
  Future<String?> pickDirectory() async {
    try {
      return await FilePicker.getDirectoryPath(dialogTitle: '选择目录');
    } catch (e) {
      Logger.instance.error('目录选择失败', e);
      return null;
    }
  }

  /// 选择可执行文件（用于设置页指定 FFmpeg / FFprobe 路径）。
  Future<String?> pickExecutable({String? title}) async {
    try {
      final f = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['exe'],
        dialogTitle: title ?? '选择可执行文件',
      );
      return f?.path;
    } catch (e) {
      Logger.instance.error('选择可执行文件失败', e);
      return null;
    }
  }

  // ─────────────────────── 保存 ───────────────────────

  /// 「另存为」对话框并写入内容（file_picker 12 契约：saveFile 接收
  /// 字节、由插件写盘，返回保存位置 Uri；用户取消返回 null）。
  Future<String?> copyToUserLocation(
    String srcPath, {
    String? suggestedName,
  }) async {
    try {
      final bytes = await File(srcPath).readAsBytes();
      final ext = p.extension(srcPath).replaceFirst('.', '');
      final uri = await FilePicker.saveFile(
        dialogTitle: '保存到…',
        fileName: suggestedName ?? p.basename(srcPath),
        type: FileType.custom,
        allowedExtensions: ext.isEmpty ? null : [ext],
        bytes: bytes,
      );
      if (uri == null) return null;
      return uri.scheme == 'file' ? uri.toFilePath() : uri.toString();
    } catch (e) {
      Logger.instance.error('复制文件失败', e);
      rethrow;
    }
  }

  // ─────────────────────── 目录 ───────────────────────

  /// 列出目录中的文件（按扩展名过滤）。
  List<FileSystemEntity> listFiles(
    String dirPath, {
    List<String>? extensions,
  }) {
    try {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) return const [];
      return dir.listSync().whereType<File>().where((f) {
        if (extensions == null) return true;
        final ext = p.extension(f.path).replaceFirst('.', '').toLowerCase();
        return extensions.contains(ext);
      }).toList();
    } catch (e) {
      Logger.instance.error('目录读取失败: $dirPath', e);
      return const [];
    }
  }

  /// Windows 桌面无移动端权限限制（兼容调用方，直接放行）。
  Future<bool> ensureStoragePermissions() async => true;

  /// 清理应用临时文件（处理中间产物）。
  Future<void> cleanupTempFiles() async {
    try {
      final base = await getTemporaryDirectory();
      final target = Directory(p.join(base.path, AppConstants.appDirName));
      if (target.existsSync()) {
        await target.delete(recursive: true);
      }
    } catch (e) {
      Logger.instance.error('清理临时文件失败', e);
    }
  }
}
