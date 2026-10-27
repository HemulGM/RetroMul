unit RM.Settings.SF7000;

interface

uses
  RM.Settings.Builder, RM.Settings.Platform, RM.Settings.Sega8Bit;

type
  TSF7000Settings = class(TSega8BitSettings)
  public
    procedure Hardware(Context: TSettingsPageBuilder); override;
    procedure Peripherals(Context: TSettingsPageBuilder); override;
  end;

implementation

uses
  RM.Settings.Catalog, System.SysUtils, RM.Icons;

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

initialization
  RegisterSettingsProfile('SF7000', TSF7000Settings);

end.

