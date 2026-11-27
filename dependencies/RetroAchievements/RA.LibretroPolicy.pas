unit RA.LibretroPolicy;

interface

type
  TRALibretroSettingRule = record
    Key, Pattern: string;
  end;

// Returns the rules registered for the exact core and console pair.
function RALibretroDisallowedSettings(const Core: string; ConsoleID: Cardinal = 0): TArray<TRALibretroSettingRule>;

function RALibretroIsSettingAllowed(const Rules: array of TRALibretroSettingRule; const Key, Value: string): Boolean; overload;

// Applies the core-wide rules and, when a console is supplied, its specific rules.
function RALibretroIsSettingAllowed(const Core, Key, Value: string; ConsoleID: Cardinal = 0): Boolean; overload;

function RALibretroIsSystemAllowed(const Core: string; ConsoleID: Cardinal): Boolean;

implementation

uses
  System.SysUtils, RA.Console;

type
  TRALibretroCoreRules = record
    Core: string;
    ConsoleID: Cardinal;
    First, Count: Integer;
  end;

const
  // Hardcore restrictions from rcheevos v12.5.0.
  SettingRules: array[0..37] of TRALibretroSettingRule = (
    (Key: 'beetle_psx_cpu_freq_scale'; Pattern: '<100'),
    (Key: 'beetle_psx_hw_cpu_freq_scale'; Pattern: '<100'),
    (Key: 'bsnes_region'; Pattern: 'pal'),
    (Key: 'cap32_autorun'; Pattern: 'disabled'),
    (Key: 'dolphin_cheats_enabled'; Pattern: 'enabled'),
    (Key: 'dosbox_pure_strict_mode'; Pattern: 'false'),
    (Key: 'duckstation_CDROM.LoadImagePatches'; Pattern: 'true'),
    (Key: 'ecwolf-invulnerability'; Pattern: 'enabled'),
    (Key: 'fceumm_game_genie'; Pattern: '!disabled'),
    (Key: 'fceumm_region'; Pattern: ',PAL,Dendy'),
    (Key: 'fbneo-allow-patched-romsets'; Pattern: 'enabled'),
    (Key: 'fbneo-cheat-*'; Pattern: '!,Disabled,0 - Disabled'),
    (Key: 'fbneo-cpu-speed-adjust'; Pattern: '??%'),
    (Key: 'fbneo-dipswitch-*'; Pattern: 'Universe BIOS*'),
    (Key: 'fbneo-neogeo-mode'; Pattern: 'UNIBIOS'),
    (Key: 'reicast_sh4clock'; Pattern: '<200'),
    (Key: 'genesis_plus_gx_lock_on'; Pattern: ',action replay (pro),game genie'),
    (Key: 'genesis_plus_gx_region_detect'; Pattern: 'pal'),
    (Key: 'genesis_plus_gx_wide_lock_on'; Pattern: ',action replay (pro),game genie'),
    (Key: 'genesis_plus_gx_wide_region_detect'; Pattern: 'pal'),
    (Key: 'melonds_console_mode'; Pattern: 'dsi'),
    (Key: 'mesen_region'; Pattern: ',PAL,Dendy'),
    (Key: 'mesen-s_region'; Pattern: 'PAL'),
    (Key: 'neocd_bios'; Pattern: 'uni-bios*'),
    (Key: 'ppsspp_cheats'; Pattern: 'enabled'),
    (Key: 'pcsx_rearmed_psxclock'; Pattern: ',!auto,<55'),
    (Key: 'pcsx_rearmed_region'; Pattern: 'pal'),
    (Key: 'picodrive_region'; Pattern: ',Europe,Japan PAL'),
    (Key: 'q88_cpu_clock'; Pattern: ',1,2'),
    (Key: 'smsplus_region'; Pattern: 'pal'),
    (Key: 'snes9x_gfx_clip'; Pattern: 'disabled'),
    (Key: 'snes9x_gfx_transp'; Pattern: 'disabled'),
    (Key: 'snes9x_layer_*'; Pattern: 'disabled'),
    (Key: 'snes9x_region'; Pattern: 'pal'),
    (Key: 'swanstation_CPU_Overclock'; Pattern: '<100'),
    (Key: 'vice_autostart'; Pattern: 'disabled'),
    (Key: 'vice_reset'; Pattern: '!autostart'),
    (Key: 'virtualjaguar_pal'; Pattern: 'enabled')
  );
  CoreRules: array[0..25] of TRALibretroCoreRules = (
    (Core: 'Beetle PSX'; ConsoleID: 0; First: 0; Count: 1),
    (Core: 'Beetle PSX HW'; ConsoleID: 0; First: 1; Count: 1),
    (Core: 'bsnes-mercury'; ConsoleID: 0; First: 2; Count: 1),
    (Core: 'cap32'; ConsoleID: 0; First: 3; Count: 1),
    (Core: 'dolphin-emu'; ConsoleID: 0; First: 4; Count: 1),
    (Core: 'DOSBox-pure'; ConsoleID: 0; First: 5; Count: 1),
    (Core: 'DuckStation'; ConsoleID: 0; First: 6; Count: 1),
    (Core: 'ecwolf'; ConsoleID: 0; First: 7; Count: 1),
    (Core: 'FCEUmm'; ConsoleID: 0; First: 8; Count: 2),
    (Core: 'FinalBurn Neo'; ConsoleID: 0; First: 10; Count: 5),
    (Core: 'Flycast'; ConsoleID: 0; First: 15; Count: 1),
    (Core: 'Genesis Plus GX'; ConsoleID: 0; First: 16; Count: 2),
    (Core: 'Genesis Plus GX Wide'; ConsoleID: 0; First: 18; Count: 2),
    (Core: 'melonDS'; ConsoleID: RAConsoleNintendoDS; First: 20; Count: 1),
    (Core: 'Mesen'; ConsoleID: 0; First: 21; Count: 1),
    (Core: 'Mesen-S'; ConsoleID: 0; First: 22; Count: 1),
    (Core: 'NeoCD'; ConsoleID: 0; First: 23; Count: 1),
    (Core: 'PPSSPP'; ConsoleID: 0; First: 24; Count: 1),
    (Core: 'PCSX-ReARMed'; ConsoleID: 0; First: 25; Count: 2),
    (Core: 'PicoDrive'; ConsoleID: 0; First: 27; Count: 1),
    (Core: 'QUASI88'; ConsoleID: 0; First: 28; Count: 1),
    (Core: 'SMS Plus GX'; ConsoleID: 0; First: 29; Count: 1),
    (Core: 'Snes9x'; ConsoleID: 0; First: 30; Count: 4),
    (Core: 'SwanStation'; ConsoleID: 0; First: 34; Count: 1),
    (Core: 'VICE x64'; ConsoleID: 0; First: 35; Count: 2),
    (Core: 'Virtual Jaguar'; ConsoleID: 0; First: 37; Count: 1)
  );

function CStringPrefix(const Value: string): string;
var
  Terminator: Integer;
begin
  Terminator := Pos(#0, Value);
  if Terminator = 0 then
    Result := Value
  else
    Result := Copy(Value, 1, Terminator - 1);
end;

function RALibretroDisallowedSettings(const Core: string; ConsoleID: Cardinal): TArray<TRALibretroSettingRule>;
var
  CoreName: string;
  Group: TRALibretroCoreRules;
  I: Integer;
begin
  Result := nil;
  CoreName := CStringPrefix(Core);
  for Group in CoreRules do
    if (Group.ConsoleID = ConsoleID) and (Group.Core = CoreName) then
    begin
      SetLength(Result, Group.Count);
      for I := 0 to Group.Count - 1 do
        Result[I] := SettingRules[Group.First + I];
      Exit;
    end;
end;

function AsciiLower(Ch: AnsiChar): AnsiChar;
begin
  if (Ch >= 'A') and (Ch <= 'Z') then
    Result := AnsiChar(Ord(Ch) + Ord('a') - Ord('A'))
  else
    Result := Ch;
end;

function MatchesWildcard(const Value, Pattern: string): Boolean;
var
  EncodedValue, EncodedPattern: UTF8String;
begin
  EncodedValue := UTF8String(Value);
  EncodedPattern := UTF8String(Pattern);
  for var Index := 1 to Length(EncodedValue) do
  begin
    if Index > Length(EncodedPattern) then
      Exit(False);
    if (AsciiLower(EncodedValue[Index]) <> AsciiLower(EncodedPattern[Index])) and (EncodedPattern[Index] <> '?') then
      Exit(EncodedPattern[Index] = '*');
  end;
  Result := Length(EncodedValue) = Length(EncodedPattern);
end;

function ParseIntegerPrefix(const Value: string): Integer;
var
  Start, I: Integer;
  Number: Int64;
begin
  I := 1;
  while (I <= Length(Value)) and CharInSet(Value[I], [#9..#13, ' ']) do
    Inc(I);
  Start := I;
  if (I <= Length(Value)) and CharInSet(Value[I], ['+', '-']) then
    Inc(I);
  if (I > Length(Value)) or not CharInSet(Value[I], ['0'..'9']) then
    Exit(0);
  repeat
    Inc(I);
  until (I > Length(Value)) or not CharInSet(Value[I], ['0'..'9']);

  if not TryStrToInt64(Copy(Value, Start, I - Start), Number) then
  begin
    if Value[Start] = '-' then
      Number := Low(Int64)
    else
      Number := High(Int64);
  end;
  {$IFDEF MSWINDOWS}
  // Match the Windows C runtime's atoi used by upstream rcheevos.
  if Number < Low(Integer) then
    Exit(Low(Integer));
  if Number > High(Integer) then
    Exit(High(Integer));
  {$ENDIF}
  Result := Integer(Cardinal(Number and High(Cardinal)));
end;

function MatchToken(const Value, Token: string; out Disallowed: Boolean): Boolean;
begin
  if Token.StartsWith('!') and MatchToken(Value, Copy(Token, 2), Disallowed) then
  begin
    Disallowed := False;
    Exit(True);
  end;

  Result := (Token.StartsWith('<') and (ParseIntegerPrefix(Value) < ParseIntegerPrefix(Copy(Token, 2)))) or
    MatchesWildcard(Value, Token);
  Disallowed := Result;
end;

function IsValueDisallowed(const Value, Pattern: string): Boolean;
var
  Token: string;
  Disallowed: Boolean;
begin
  if Pattern.StartsWith('!') then
    Exit(not IsValueDisallowed(Value, Copy(Pattern, 2)));

  if Pattern.StartsWith(',') then
  begin
    for Token in Copy(Pattern, 2).Split([',']) do
      if MatchToken(Value, Token, Disallowed) then
        Exit(Disallowed);
    Exit(False);
  end;
  Result := MatchToken(Value, Pattern, Disallowed) and Disallowed;
end;

function RALibretroIsSettingAllowed(const Rules: array of TRALibretroSettingRule; const Key, Value: string): Boolean;
var
  SettingKey, SettingValue, RuleKey: string;
  Rule: TRALibretroSettingRule;
begin
  SettingKey := CStringPrefix(Key);
  SettingValue := CStringPrefix(Value);
  for Rule in Rules do
  begin
    RuleKey := CStringPrefix(Rule.Key);
    if ((SettingKey = RuleKey) or (RuleKey.EndsWith('*') and
      SettingKey.StartsWith(Copy(RuleKey, 1, Length(RuleKey) - 1)))) and
      IsValueDisallowed(SettingValue, CStringPrefix(Rule.Pattern)) then
      Exit(False);
  end;
  Result := True;
end;

function RALibretroIsSettingAllowed(const Core, Key, Value: string; ConsoleID: Cardinal): Boolean;
begin
  Result := RALibretroIsSettingAllowed(RALibretroDisallowedSettings(Core), Key, Value) and
    ((ConsoleID = 0) or RALibretroIsSettingAllowed(RALibretroDisallowedSettings(Core, ConsoleID), Key, Value));
end;

function RALibretroIsSystemAllowed(const Core: string; ConsoleID: Cardinal): Boolean;
begin
  // The fixed-size upstream restriction list also matches the Unknown ID.
  Result := (CStringPrefix(Core) <> 'Mesen-S') or
    not (ConsoleID in [RAConsoleUnknown, RAConsoleGameBoy, RAConsoleGameBoyColor]);
end;

end.

