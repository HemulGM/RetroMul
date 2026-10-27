unit RM.Settings.GameBoy.Base;

interface

uses
  RM.Settings.Platform, RM.Settings.Builder, System.IniFiles;

type
  TGameBoySettingsBase = class(TSettingsPlatform)
  public
    procedure Display(Context: TSettingsPageBuilder); virtual;
    procedure Video(Context: TSettingsPageBuilder); override;
    procedure Audio(Context: TSettingsPageBuilder); override;
    procedure Peripherals(Context: TSettingsPageBuilder); override;
  end;

implementation

uses
  FMX.Types, System.SysUtils, System.Math, RM.Icons, GB.Memory, GB.Palettes;

function GBBootFileDetail(Model: TGBBootModel): string;
begin
  if Model in [TGBBootModel.DMG, TGBBootModel.MGB] then
    Result := 'Leave empty to use the built-in boot ROM.'
  else
    Result := 'Choose your boot ROM file for this model.';
end;

procedure TGameBoySettingsBase.Display(Context: TSettingsPageBuilder);
begin
  var Labels, Values: TArray<string>;
  SetLength(Labels, SCREEN_PALETTE_COUNT);
  SetLength(Values, SCREEN_PALETTE_COUNT);
  for var i := 0 to SCREEN_PALETTE_COUNT - 1 do
  begin
    Labels[i] := ScreenPalettes[i].Name;
    Values[i] := IntToStr(i);
  end;
  var Palette := Context.AddChoice('RowGameBoypalette', 'Game Boy palette', 'Colors of the monochrome display.', 'Video', 'Palette', SettingChoices(Labels, Values), '0');
  Context.PalettePreview(Palette);
end;

procedure TGameBoySettingsBase.Video(Context: TSettingsPageBuilder);
begin
  Display(Context);
  Context.Heading('GroupGBEnhancements', 'Game Boy enhancements');
  Context.AddBoolean('RowGBFrameBlending', 'Frame blending', 'Blend the current and previous emulated frames equally.', 'Video', 'FrameBlending', False, True);
  var PaletteLabels, PaletteValues: TArray<string>;
  SetLength(PaletteLabels, SCREEN_PALETTE_COUNT + 1);
  SetLength(PaletteValues, SCREEN_PALETTE_COUNT + 1);
  PaletteLabels[0] := Translate('Default palette');
  PaletteValues[0] := '-1';
  for var i := 0 to SCREEN_PALETTE_COUNT - 1 do
  begin
    PaletteLabels[i + 1] := ScreenPalettes[i].Name;
    PaletteValues[i + 1] := IntToStr(i);
  end;
  Context.AddChoice('RowGBBGPalette', 'Background palette', 'Palette for monochrome games.', 'Video', 'BGPalette', SettingChoices(PaletteLabels, PaletteValues), '-1', True);
  Context.AddChoice('RowGBOBJ0Palette', 'OBJ0 palette', 'Palette for monochrome games.', 'Video', 'OBJ0Palette', SettingChoices(PaletteLabels, PaletteValues), '-1', True);
  Context.AddChoice('RowGBOBJ1Palette', 'OBJ1 palette', 'Palette for monochrome games.', 'Video', 'OBJ1Palette', SettingChoices(PaletteLabels, PaletteValues), '-1', True);
  Context.AddBoolean('RowGBShowBackground', 'Show background', 'Display the background layer.', 'Video', 'ShowBackground', True, True);
  Context.AddBoolean('RowGBShowWindow', 'Show window', 'Display the window layer.', 'Video', 'ShowWindow', True, True);
  Context.AddBoolean('RowGBShowSprites', 'Show sprites', 'Display the sprite layer.', 'Video', 'ShowSprites', True, True);
  Context.AddBoolean('RowGBRemoveSpriteLimit', 'Remove sprite limit', 'Display up to 40 sprites per line; games may show unexpected graphics.', 'Video', 'RemoveSpriteLimit', False, True);
  var CPUPercent := Context.AddInteger('RowGBOverclock', 'CPU speed (%)', '100 is normal speed; higher values reduce CPU slowdown and may affect games.', 'Emulation', 'Overclock', 100, 400, True);
  CPUPercent.Min := 100;
  CPUPercent.Value := EnsureRange(CPUPercent.Value, 100, 400);
  Context.Heading('GroupBootROM', 'Boot ROM');
  var BootLabels, BootKeys: TArray<string>;
  SetLength(BootLabels, Ord(High(TGBBootModel)) + 1);
  SetLength(BootKeys, Length(BootLabels));
  for var Model := Low(TGBBootModel) to High(TGBBootModel) do
  begin
    BootLabels[Ord(Model)] := Translate(GB_BOOT_MODEL_LABELS[Model]);
    BootKeys[Ord(Model)] := GB_BOOT_MODEL_KEYS[Model];
  end;
  var BootModel := Context.AddChoice('RowBootModel', 'Boot ROM model', 'Select a console boot sequence, or start the game directly.', 'Boot', 'Model', SettingChoices(BootLabels,
      BootKeys), 'none', True);
  BootModel.OnChange := Context.OnRebuild;
  var SelectedBoot := GBBootModel(Context.Draft.ReadString('Boot', 'Model', 'none'));
  if SelectedBoot <> TGBBootModel.Skip then
    Context.AddPath('RowBootFile' + GB_BOOT_MODEL_KEYS[SelectedBoot], 'Boot ROM file', GBBootFileDetail(SelectedBoot), 'Boot', GB_BOOT_MODEL_KEYS[SelectedBoot] + 'File', '', False, True);
end;

procedure TGameBoySettingsBase.Audio(Context: TSettingsPageBuilder);
const
  Captions: array[1..4] of string = ('Channel 1 volume (%)', 'Channel 2 volume (%)',
    'Wave channel volume (%)', 'Noise channel volume (%)');
  Details: array[1..4] of string = ('Square wave with frequency sweep.',
    'Second square wave channel.', 'Programmable wave channel.', 'Noise channel.');
begin
  for var i := 1 to 4 do
    Context.AddInteger('RowGBChannel' + IntToStr(i) + 'Volume', Captions[i], Details[i], 'Audio', 'Channel' + IntToStr(i) + 'Volume', 100, 100, True);
end;

procedure TGameBoySettingsBase.Peripherals(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupRumble', 'Rumble');
  Context.AddBoolean('RowRumble', 'Cartridge rumble', 'Vibrate the device when the game activates its rumble motor.', 'Peripherals', 'Rumble', True, True);
end;

end.

