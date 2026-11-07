unit RM.Platforms.PSP.Settings;

interface

uses
  RM.Settings.Platform, RM.Settings.Builder, System.IniFiles;

type
  TPSPSettings = class(TSettingsPlatform)
  public
    procedure Configuration(Context: TSettingsPageBuilder); override;
    procedure Video(Context: TSettingsPageBuilder); override;
  end;

implementation

uses
  RM.Settings.Catalog, FMX.Types, System.SysUtils, HW.JIT,
  Core.Platforms.PSP.RendererCaps, Core.Platforms.PSP.Renderer;

function PSPRendererCaption(const Value: string): string;
begin
  if SameText(Value, 'cpu') then
    Result := Translate('CPU (software)')
  else if SameText(Value, 'vulkan') or SameText(Value, 'vulkan-lle') then
    Result := Translate('Vulkan LLE (experimental)')
  else if SameText(Value, 'vulkan-hle') then
    Result := Translate('Vulkan HLE (experimental)')
  else
    Result := Value;
end;

procedure TPSPSettings.Configuration(Context: TSettingsPageBuilder);
begin
  if JitSupported then
  begin
    Context.Heading('GroupPSPEmulation', 'PSP emulation');
    Context.AddChoice('RowPSPExecution', 'CPU', 'The recompiler runs the game''s code as native code; the interpreter runs it instruction by instruction. Both give the same emulation; the recompiler is faster. Applies during play.', 'Emulation', 'Execution', SettingChoices([Translate('Recompiler (JIT)'), Translate('Interpreter')], ['jit', 'interpreter']), 'jit', True);
  end;
  Context.Heading('GroupPSPSystem', 'PSP system');
  Context.AddChoice('RowPSPLanguage', 'System language', 'The language games read from the system settings. Applies when the game starts.', 'System', 'Language', SettingChoices([Translate('Japanese'), Translate('English'), Translate('French'), Translate('Spanish'), Translate('German'), Translate('Italian'), Translate('Dutch'), Translate('Portuguese'), Translate('Russian'), Translate('Korean'), Translate('Chinese (traditional)'), Translate('Chinese (simplified)')], ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11']), '1', True);
  Context.AddChoice('RowPSPConfirm', 'Confirm button', 'Which button confirms in system dialogs and in games that follow the system setting.', 'System', 'ButtonSwap', SettingChoices([Translate('Cross'), Translate('Circle')], ['1', '0']), '1', True);
  Context.AddText('RowPSPNickname', 'Nickname', 'The user name games show and store in saves.', 'System', 'Nickname', 'RetroMul', True);
  Context.AddPath('RowPSPFonts', 'PSP font directory', 'Optional folder containing your PSP .pgf fonts (jpn0.pgf, ltn*.pgf). Read-only; fonts are not bundled. Reopen the game to apply.', 'System', 'FontDirectory', '', True, True).ApplyMode := TSettingsApplyMode.OnNextLoad;
end;

procedure TPSPSettings.Video(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupPSPVideo', 'PSP video');
  var Support := PSPRendererSupport;
  var Captions: TArray<string>;
  var Values: TArray<string>;
  for var Renderer in AvailablePSPRenderers(Support) do
  begin
    var Value := PSPRendererName(Renderer);
    Captions := Captions + [PSPRendererCaption(Value)];
    Values := Values + [Value];
  end;
  var Choice := Context.AddChoice('RowPSPRenderer', 'Renderer', 'Vulkan LLE draws exactly as the CPU renderer, in compute shaders. Vulkan HLE draws with the GPU''s own pipeline: faster, but not pixel exact. Both are experimental and use the CPU when the host or required features are unsupported. Applies after stopping and starting the game. Reset and LoadExec of a running game keep the current renderer.', 'Video', 'Renderer', SettingChoices(Captions, Values), 'cpu', True);
  Choice.ApplyMode := TSettingsApplyMode.OnNextLoad;
  Choice.PreserveUnknownValue := True;
  if Choice.SelectionIndex < 0 then
    Context.AddInformation('RowPSPRendererUnavailable', 'Renderer',
      'The saved renderer is unavailable on this device. Select a supported renderer to change it.', PSPRendererCaption(Choice.Value));
  Context.AddChoice('RowPSPResolution', 'Internal resolution', 'How many times the PSP''s 480x272 the Vulkan HLE renderer draws at. The CPU and Vulkan LLE renderers always draw at 1x. Applies after stopping and starting the game.', 'Video', 'Resolution', SettingChoices([Translate('1x (480x272)'), Translate('2x (960x544)'), Translate('3x (1440x816)'), Translate('4x (1920x1088)'), Translate('6x (2880x1632)'), Translate('8x (3840x2176)')], ['1', '2', '3', '4', '6', '8']), '1', True).ApplyMode := TSettingsApplyMode.OnNextLoad;
  Context.AddChoice('RowPSPTextureScale', 'Texture scaling', 'Makes the games'' textures larger for the Vulkan HLE renderer above 1x, with the filter below. Textures that keep changing (videos) stay as they are. Applies after stopping and starting the game.', 'Video', 'TextureScale', SettingChoices([Translate('Off'), Translate('2x'), Translate('3x'), Translate('4x'), Translate('5x'), Translate('6x')], ['0', '2', '3', '4', '5', '6']), '0', True).ApplyMode := TSettingsApplyMode.OnNextLoad;
  Context.AddChoice('RowPSPTextureFilter', 'Texture filter', 'xBRZ keeps edges sharp: text, interface, drawn outlines; photographic textures may look painted. Bicubic is smooth, for photographic and painted textures. Hybrid uses bicubic in even areas and xBRZ on edges. Applies after stopping and starting the game.', 'Video', 'TextureFilter', SettingChoices([Translate('xBRZ (sharp edges)'), Translate('Hybrid (xBRZ and bicubic)'), Translate('Bicubic (smooth)')], ['xbrz', 'hybrid', 'bicubic']), 'xbrz', True).ApplyMode := TSettingsApplyMode.OnNextLoad;
end;

end.
