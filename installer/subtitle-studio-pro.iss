; Subtitle Studio Pro —— Windows 安装包（v1.5 发布就绪）
;
; 本地编译（需先 flutter build windows --release）：
;   "D:\Program Files\Inno Setup 7\ISCC.exe" installer\subtitle-studio-pro.iss
; CI 编译（覆盖版本号与构建目录，均传绝对路径）：
;   ISCC /DAppVersion=2.1.1 /DAppBuildDir=<repo>\build\windows\x64\runner\Release installer\subtitle-studio-pro.iss
;
; 产物：installer\dist\SubtitleStudioPro-<版本>-setup.exe

#define AppName "Subtitle Studio Pro"
#define AppExeName "subtitle_studio_pro.exe"
#ifndef AppVersion
#define AppVersion "2.1.1"
#endif
; 相对路径相对本脚本目录（installer\）；CI 传绝对路径覆盖
#ifndef AppBuildDir
#define AppBuildDir SourcePath + "..\build\windows\x64\runner\Release"
#endif

; Inno 7 自带简体中文语言文件；choco 的 6.x 未必有 —— 缺则整包回退英文
; （语言文件与任务文案一起切，避免中英混排）
#if FileExists(CompilerPath + "\Languages\ChineseSimplified.isl")
#define InstallerLanguage "compiler:Languages\ChineseSimplified.isl"
#define TaskFileAssocText "关联字幕文件（.srt / .ass / .ssa / .vtt / .sub），双击用 Subtitle Studio Pro 打开"
#define TaskDesktopText "创建桌面快捷方式"
#else
#define InstallerLanguage "compiler:Default.isl"
#define TaskFileAssocText "Associate subtitle files (.srt / .ass / .ssa / .vtt / .sub) with Subtitle Studio Pro"
#define TaskDesktopText "Create a desktop shortcut"
#endif

[Setup]
AppId={{A90DAFC6-1930-472C-AC3D-C0D55141CB58}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Subtitle Studio Pro
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
UninstallDisplayName={#AppName}
OutputDir=dist
OutputBaseFilename=SubtitleStudioPro-{#AppVersion}-setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64
; 按用户安装（%LocalAppData%\Programs）：免 UAC；文件关联写 HKCU 一定
; 落在当前用户；后续自动更新静默升级也无需提权
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
; 写入文件关联后通知资源管理器刷新图标
ChangesAssociations=yes

[Languages]
Name: "chinesesimplified"; MessagesFile: "{#InstallerLanguage}"

[Tasks]
Name: "fileassoc"; Description: "{#TaskFileAssocText}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "desktopicon"; Description: "{#TaskDesktopText}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; 构建产物全量带入（含 data\、mpv/插件 DLL、resources\ffmpeg\ 捆绑的 ffmpeg/ffprobe）
Source: "{#AppBuildDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Registry]
; ── 字幕文件关联（仅当前用户 HKCU，不碰机器级默认；卸载自动清理）──
; ProgID：类型说明 + 图标 + 打开命令（"%1" = 双击的文件路径，应用启动
; 参数里解析字幕文件并载入字幕库）
Root: HKCU; Subkey: "Software\Classes\SubtitleStudioPro.Subtitle.1"; ValueType: string; ValueName: ""; ValueData: "{#AppName} 字幕文件"; Flags: uninsdeletekey; Tasks: fileassoc
Root: HKCU; Subkey: "Software\Classes\SubtitleStudioPro.Subtitle.1\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#AppExeName},0"; Flags: uninsdeletekey; Tasks: fileassoc
Root: HKCU; Subkey: "Software\Classes\SubtitleStudioPro.Subtitle.1\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"" ""%1"""; Flags: uninsdeletekey; Tasks: fileassoc
; 各扩展名默认值指向 ProgID（HKCU 影子覆盖机器级，卸载删值后回退原有关联）
Root: HKCU; Subkey: "Software\Classes\.srt"; ValueType: string; ValueName: ""; ValueData: "SubtitleStudioPro.Subtitle.1"; Flags: uninsdeletevalue; Tasks: fileassoc
Root: HKCU; Subkey: "Software\Classes\.ass"; ValueType: string; ValueName: ""; ValueData: "SubtitleStudioPro.Subtitle.1"; Flags: uninsdeletevalue; Tasks: fileassoc
Root: HKCU; Subkey: "Software\Classes\.ssa"; ValueType: string; ValueName: ""; ValueData: "SubtitleStudioPro.Subtitle.1"; Flags: uninsdeletevalue; Tasks: fileassoc
Root: HKCU; Subkey: "Software\Classes\.vtt"; ValueType: string; ValueName: ""; ValueData: "SubtitleStudioPro.Subtitle.1"; Flags: uninsdeletevalue; Tasks: fileassoc
Root: HKCU; Subkey: "Software\Classes\.sub"; ValueType: string; ValueName: ""; ValueData: "SubtitleStudioPro.Subtitle.1"; Flags: uninsdeletevalue; Tasks: fileassoc

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
