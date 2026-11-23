unit RM.Help.Content;

interface

uses
  RM.Settings.Platform;

type
  THelpSection = record
    Title, Text: string;
  end;

function GeneralHelpSections: TArray<THelpSection>;

function PlatformHelpSections(platform: TSettingsPlatform): TArray<THelpSection>;

implementation

uses
  System.SysUtils, FMX.Types, Core.Platforms, Core.MediaArchive;

const
  GeneralSections: array[0..12] of THelpSection = (
    (Title: 'How the library is built';
      Text: 'In Settings → Library, assign a ROM folder to each platform. RetroMul scans that ' +
      'folder and its subfolders and lists files with extensions registered for that ' +
      'platform. The list starts with file names. You can search by title, switch between ' +
      'grid and list views, filter by platform or letter, or open Recent and Favorites. ' +
      'Use refresh after adding, moving or renaming files.'),
    (Title: 'Covers and game information';
      Text: 'Use a tool such as RetroScraper to scan the same ROM folders and export an ' +
      'EmulationStation gamelist.xml with artwork. In RetroScraper, choose the platforms ' +
      'and folders, connect to ScreenScraper, then select descriptions and media and run ' +
      'the scrape. Keep gamelist.xml at the root of each platform folder and keep the ' +
      'exported artwork in the folders referenced by the XML. Refresh the RetroMul ' +
      'library after exporting.'),
    (Title: 'When artwork is missing';
      Text: 'Each game entry uses path to match the ROM, for example ./Sonic.md or ./Sonic.zip. ' +
      'The paths in image, thumbnail and box point to artwork, for example ' +
      './media/sonic.png. Relative paths keep the library portable. Entries can also ' +
      'supply name, desc, developer, genre and players. The XML adds information to files ' +
      'RetroMul finds on disk. If artwork is missing, check the ROM extension, file names ' +
      'and the media paths, then refresh.'),
    (Title: 'Archives and arcade sets';
      Text: 'RetroMul recognizes %s. For cartridges, a practical layout is one game per ' +
      'archive, with a supported image inside. For arcade systems, keep the recognized ' +
      'ROM set together in its correctly named archive, including all files required by ' +
      'that set. Prefer unencrypted, single-volume archives. A file can appear in the ' +
      'library by extension and still fail to start if its contents are unsupported.'),
    (Title: 'Disc images and playlists';
      Text: 'Open the descriptor, such as .cue or .gdi, and keep its referenced tracks beside ' +
      'it with their original names and relative paths. CHD is a compressed disk image ' +
      'for platforms that support it. Use an .m3u playlist for multi-disc games on ' +
      'supported platforms. The library groups playable descriptors and playlists with ' +
      'their corresponding tracks or discs where that platform supports it.'),
    (Title: 'HLE, LLE and firmware';
      Text: 'HLE recreates the services or results that a game expects, such as a firmware ' +
      'call. LLE reproduces a device at a lower level, including hardware behavior or ' +
      'execution of its firmware. LLE can help with hardware-specific behavior, depending ' +
      'on the implementation. BIOS or boot ROM options control how a system starts. The ' +
      'platform’s help explains when a separate file is useful.'),
    (Title: 'JIT and the interpreter';
      Text: 'The interpreter executes guest CPU instructions one by one. JIT, also called a ' +
      'recompiler, translates blocks into native code while the game is running to reduce ' +
      'CPU overhead. It is a separate choice from HLE or LLE. RetroMul offers it for N64, ' +
      'Dreamcast and PSP on supported hosts (Windows x64, Linux x64 and Android ARM64). ' +
      'If a game behaves differently after switching modes, compare it with the ' +
      'interpreter.'),
    (Title: 'Rendering and platform settings';
      Text: 'A CPU renderer draws on the processor. Vulkan can use the graphics device for ' +
      'compute or graphics commands, depending on the renderer. The effect on speed, ' +
      'accuracy and internal resolution depends on the platform and device. Region, video ' +
      'standard and machine model choose which original hardware is emulated. If a ' +
      'setting applies on next load, close and reopen the game after applying it.'),
    (Title: 'Shaders and image scaling';
      Text: 'In Settings → Video and Audio, choose a platform, then a shader. Scanlines darkens ' +
      'alternating lines. CRT adds a phosphor mask, curvature and glow. LCD adds a pixel ' +
      'grid and adjustable persistence. Color correction adjusts gamma, saturation and ' +
      'temperature. The preview shows the effect before you apply it. Nearest-neighbor ' +
      'scaling preserves hard pixel edges. Smooth filtering blends them.'),
    (Title: 'Custom shaders';
      Text: 'Select Custom and point it to a .shader.json bundle or a shader source supported ' +
      'by the active graphics backend. Bundles can reference variants by relative paths. ' +
      'Source formats include .hlsl or .fx on Windows, .glsl or .frag for GLSL, .metal ' +
      'for Metal and .sksl for Skia. Use the preview to check compatibility. Display ' +
      'shaders apply to the finished frame, while internal resolution and texture scaling ' +
      'belong to the emulator’s renderer.'),
    (Title: 'Controls and shortcuts';
      Text: 'Open Controls and shortcuts while a game is running to see its current bindings. ' +
      'In Settings → Controls, choose the platform, player and input device to change ' +
      'them. Peripherals such as light guns, keyboards and multitaps are available on ' +
      'specific systems and can change the controls assigned to a port.'),
    (Title: 'Save states';
      Text: 'On supported platforms, save or load the whole emulated state in the game menu. On ' +
      'desktop, F5 saves to the quick slot and F6 loads it. A save state can depend on ' +
      'the ROM, hardware configuration and emulator version. A save created inside a game ' +
      'uses a separate mechanism, such as battery-backed memory or a virtual memory card. ' +
      'Use normal in-game saves for longer-term progress when possible.'),
    (Title: 'If a game fails to start';
      Text: 'Check the platform’s supported formats, required files and BIOS settings. Try the ' +
      'automatic region or hardware selection if you changed a default. With a disc ' +
      'image, check the paths in its descriptor. When reporting a problem, include the ' +
      'platform, game name, mode and steps to reproduce it. A screenshot or a save state ' +
      'can help when the form offers the option.'));

function GeneralHelpSections: TArray<THelpSection>;
begin
  SetLength(Result, Length(GeneralSections));
  for var I := 0 to High(GeneralSections) do
  begin
    Result[I].Title := Translate(GeneralSections[I].Title);
    Result[I].Text := Translate(GeneralSections[I].Text);
    if GeneralSections[I].Title = 'Archives and arcade sets' then
      Result[I].Text := Format(Result[I].Text, [string.Join(', ', MediaArchiveExtensions)]);
  end;
end;

function PlatformHelpSections(platform: TSettingsPlatform): TArray<THelpSection>;
begin
  SetLength(Result, 1);
  Result[0].Title := Translate('Library file extensions');
  for var Info in TPlatformRegistry.All do
    if SameText(Info.SettingsCoreId, platform.CoreId) then
    begin
      if Result[0].Text <> '' then
        Result[0].Text := Result[0].Text + sLineBreak;
      Result[0].Text := Result[0].Text + Translate(Info.Name) + ' · ' +
        string.Join(', ', Info.Extensions);
    end;

  if platform.HelpText <> '' then
  begin
    SetLength(Result, 2);
    Result[1].Title := Translate('Platform notes');
    Result[1].Text := Translate(platform.HelpText);
  end;
end;

end.

