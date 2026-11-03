unit NES.Options;

interface

uses
  System.IniFiles, System.SysUtils, Core.Storage;

const
  NES_CHANNEL_KEYS: array[0..5] of string =
    ('Pulse1Volume', 'Pulse2Volume', 'TriangleVolume', 'NoiseVolume', 'DmcVolume', 'ExpansionVolume');

type
  TNesChannelVolumes = array[0..5] of Integer;
  // User preferences are deliberately separate from emulated register state.
  // Loading a snapshot must not undo the current mixer or display settings.

  TNesOptions = record
    RemoveSpriteLimit, SwapDutyCycles, SilenceUltrasonicTriangle, DisableNoiseMode: Boolean;
    CropLeft, CropRight, CropTop, CropBottom: Integer;
    PaletteFile: string;
    ChannelVolume: TNesChannelVolumes;
    FdsVolume, FdsLoadSpeed, FdsChangeDelayMs: Integer;
    FdsAutoLoad, FdsFastForward, FdsAutoSwitch: Boolean;
    class function Defaults: TNesOptions; static;
    procedure Normalize;
    procedure Load(Ini: TCustomIniFile);
    procedure Save(Ini: TCustomIniFile);
  end;

// Standard RGB .pal files: 64 colors, or 8 explicit emphasis banks of 64.
function LoadNesPalette(const Storage: IStorage; const FileName: string): TArray<UInt32>;

implementation

uses
  System.Math;

class function TNesOptions.Defaults: TNesOptions;
begin
  Result := Default(TNesOptions);
  for var i := 0 to High(Result.ChannelVolume) do
    Result.ChannelVolume[i] := 100;
  Result.FdsVolume := 100;
  Result.FdsLoadSpeed := 4;
  Result.FdsChangeDelayMs := 1000;
  Result.FdsAutoLoad := True;
  Result.FdsAutoSwitch := True;
end;

procedure TNesOptions.Normalize;
begin
  CropLeft := EnsureRange(CropLeft, 0, 16);
  CropRight := EnsureRange(CropRight, 0, 16);
  CropTop := EnsureRange(CropTop, 0, 16);
  CropBottom := EnsureRange(CropBottom, 0, 16);
  PaletteFile := PaletteFile.Trim;
  for var i := 0 to High(ChannelVolume) do
    ChannelVolume[i] := EnsureRange(ChannelVolume[i], 0, 200);
  FdsVolume := EnsureRange(FdsVolume, 0, 200);
  FdsChangeDelayMs := EnsureRange(FdsChangeDelayMs, 500, 2000);
  if not (FdsLoadSpeed in [2, 4, 8]) then
    FdsLoadSpeed := 4;
end;

procedure TNesOptions.Load(Ini: TCustomIniFile);
begin
  Self := Defaults;
  RemoveSpriteLimit := Ini.ReadBool('Video', 'RemoveSpriteLimit', RemoveSpriteLimit);
  CropLeft := Ini.ReadInteger('Video', 'CropLeft', CropLeft);
  CropRight := Ini.ReadInteger('Video', 'CropRight', CropRight);
  CropTop := Ini.ReadInteger('Video', 'CropTop', CropTop);
  CropBottom := Ini.ReadInteger('Video', 'CropBottom', CropBottom);
  PaletteFile := Ini.ReadString('Video', 'PaletteFile', '');
  SwapDutyCycles := Ini.ReadBool('Audio', 'SwapDutyCycles', SwapDutyCycles);
  SilenceUltrasonicTriangle := Ini.ReadBool('Audio', 'SilenceUltrasonicTriangle', SilenceUltrasonicTriangle);
  DisableNoiseMode := Ini.ReadBool('Audio', 'DisableNoiseMode', DisableNoiseMode);
  for var i := 0 to High(ChannelVolume) do
    ChannelVolume[i] := Ini.ReadInteger('Audio', NES_CHANNEL_KEYS[i], ChannelVolume[i]);
  FdsVolume := Ini.ReadInteger('FDS', 'Volume', FdsVolume);
  FdsAutoLoad := Ini.ReadBool('FDS', 'AutoLoadDisk', FdsAutoLoad);
  FdsAutoSwitch := Ini.ReadBool('FDS', 'AutoSwitchSides', FdsAutoSwitch);
  FdsFastForward := Ini.ReadBool('FDS', 'FastForwardOnLoad', FdsFastForward);
  FdsLoadSpeed := Ini.ReadInteger('FDS', 'LoadSpeed', FdsLoadSpeed);
  FdsChangeDelayMs := Ini.ReadInteger('FDS', 'ChangeDelayMs', FdsChangeDelayMs);
  Normalize;
end;

procedure TNesOptions.Save(Ini: TCustomIniFile);
begin
  Normalize;
  Ini.WriteBool('Video', 'RemoveSpriteLimit', RemoveSpriteLimit);
  Ini.WriteInteger('Video', 'CropLeft', CropLeft);
  Ini.WriteInteger('Video', 'CropRight', CropRight);
  Ini.WriteInteger('Video', 'CropTop', CropTop);
  Ini.WriteInteger('Video', 'CropBottom', CropBottom);
  Ini.WriteString('Video', 'PaletteFile', PaletteFile);
  Ini.WriteBool('Audio', 'SwapDutyCycles', SwapDutyCycles);
  Ini.WriteBool('Audio', 'SilenceUltrasonicTriangle', SilenceUltrasonicTriangle);
  Ini.WriteBool('Audio', 'DisableNoiseMode', DisableNoiseMode);
  for var i := 0 to High(ChannelVolume) do
    Ini.WriteInteger('Audio', NES_CHANNEL_KEYS[i], ChannelVolume[i]);
  Ini.WriteInteger('FDS', 'Volume', FdsVolume);
  Ini.WriteBool('FDS', 'AutoLoadDisk', FdsAutoLoad);
  Ini.WriteBool('FDS', 'AutoSwitchSides', FdsAutoSwitch);
  Ini.WriteBool('FDS', 'FastForwardOnLoad', FdsFastForward);
  Ini.WriteInteger('FDS', 'LoadSpeed', FdsLoadSpeed);
  Ini.WriteInteger('FDS', 'ChangeDelayMs', FdsChangeDelayMs);
end;

function LoadNesPalette(const Storage: IStorage; const FileName: string): TArray<UInt32>;
begin
  Result := nil;
  if FileName.Trim = '' then
    Exit;
  if not Storage.Exists(FileName) then
    raise Exception.CreateFmt('NES palette file not found: %s', [FileName]);
  var Stream := Storage.OpenRead(FileName);
  try
    if (Stream.Size <> 192) and (Stream.Size <> 1536) then
      raise Exception.CreateFmt('NES palette must contain 192 or 1536 bytes: %s', [FileName]);
    SetLength(Result, Stream.Size div 3);
    for var i := 0 to High(Result) do
    begin
      var RGB: array[0..2] of Byte;
      Stream.ReadBuffer(RGB, SizeOf(RGB));
      Result[i] := $FF000000 or (UInt32(RGB[0]) shl 16) or (UInt32(RGB[1]) shl 8) or RGB[2];
    end;
  finally
    Stream.Free;
  end;
end;

end.

