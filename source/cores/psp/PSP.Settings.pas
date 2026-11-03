unit PSP.Settings;

// The console's system settings (what the XMB would store in the registry):
// read by sceUtility system parameters, sceReg, sceImpose and sceRtc local time.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

type
  TPSPSettings = record
    Nickname: string;
    Language: Integer;
    // 1: cross confirms (the western layout), 0: circle confirms.
    ButtonSwap: Integer;
    // Minutes east of UTC.
    Timezone: Integer;
    DaylightSaving: Integer;
    // 0 YYYYMMDD, 1 MMDDYYYY, 2 DDMMYYYY.
    DateFormat: Integer;
    // 0 24 hours, 1 12 hours.
    TimeFormat: Integer;
    AdhocChannel: Integer;
    WlanPowerSave: Integer;
    ParentalLevel: Integer;
    class function Defaults: TPSPSettings; static;
  end;

var
  PSPSettings: TPSPSettings;

implementation

class function TPSPSettings.Defaults: TPSPSettings;
begin
  Result.Nickname := 'RetroMul';
  Result.Language := 1;
  Result.ButtonSwap := 1;
  Result.Timezone := 60;
  Result.DaylightSaving := 0;
  Result.DateFormat := 2;
  Result.TimeFormat := 0;
  Result.AdhocChannel := 0;
  Result.WlanPowerSave := 0;
  Result.ParentalLevel := 9;
end;

initialization
  PSPSettings := TPSPSettings.Defaults;

end.
