unit RM.Platforms.SG1000.Settings;

interface

uses
  RM.Settings.Builder, RM.Settings.Platform, RM.Platforms.SG1000.Settings.Base;

type
  TSG1000Settings = class(TSega8BitSettings)
  public
    procedure Hardware(Context: TSettingsPageBuilder); override;
    procedure Peripherals(Context: TSettingsPageBuilder); override;
  end;

type
  TSC3000Settings = class(TSega8BitSettings)
  public
    procedure Hardware(Context: TSettingsPageBuilder); override;
    procedure Peripherals(Context: TSettingsPageBuilder); override;
  end;

type
  TSF7000Settings = class(TSega8BitSettings)
  public
    procedure Hardware(Context: TSettingsPageBuilder); override;
    procedure Peripherals(Context: TSettingsPageBuilder); override;
  end;

type
  TMultivisionSettings = class(TSega8BitSettings)
  public
    procedure Peripherals(Context: TSettingsPageBuilder); override;
  end;

implementation

uses
  FMX.Types, System.SysUtils, RM.Icons;

procedure TSG1000Settings.Hardware(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupSegaHardware', 'Sega hardware');
  Context.AddChoice('RowSegaModel', 'Console model', 'Select the hardware used when opening a ROM.', 'Hardware', 'Model',
    SettingChoices([Translate('Automatic'), 'SG-1000', 'SG-1000 II / SK-1100'], ['auto', 'sg1000', 'sg1000ii']), 'auto', True);
end;

procedure TSG1000Settings.Peripherals(Context: TSettingsPageBuilder);
begin
  if SameText(Context.Draft.ReadString('Hardware', 'Model', 'auto'), 'sg1000ii') then
    Keyboard(Context, True);
end;

procedure TSC3000Settings.Hardware(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupSegaHardware', 'Sega hardware');
  Context.AddChoice('RowSegaModel', 'Console model', 'Select the hardware used when opening a ROM.', 'Hardware', 'Model',
    SettingChoices([Translate('Automatic'), 'SC-3000', 'SC-3000H'], ['auto', 'sc3000', 'sc3000h']), 'auto', True);
end;

procedure TSC3000Settings.Peripherals(Context: TSettingsPageBuilder);
begin
  Keyboard(Context, True);
end;

procedure TSF7000Settings.Hardware(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupSegaHardware', 'Sega hardware');
  Context.AddPath('RowSegaIPL', 'IPL ROM file', 'Required 8 KiB SF-7000 firmware. Leave empty to search beside the disk.', 'Hardware', 'IPL', '', False, True);
  Context.AddBoolean('RowSegaWarmBoot', 'Fast boot', 'Skip the SF-7000 startup memory tests for a faster boot.', 'Hardware', 'WarmBoot', True, True);
end;

procedure TSF7000Settings.Peripherals(Context: TSettingsPageBuilder);
begin
  Keyboard(Context, True);
  Context.Heading('GroupSegaDisk', 'Floppy drive');
  Context.AddBoolean('RowSegaWriteProtected', 'Write protect disk', 'Prevent the emulated drive from writing or formatting the disk.', 'Disk', 'WriteProtected', False, True);
end;

procedure TMultivisionSettings.Peripherals(Context: TSettingsPageBuilder);
begin
  Keyboard(Context, False);
end;

end.

