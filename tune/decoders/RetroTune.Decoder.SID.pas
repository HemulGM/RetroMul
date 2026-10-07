unit RetroTune.Decoder.SID;

interface

implementation

uses
  System.SysUtils, System.Math, RetroTune.Decoder, RetroTune.Binary,
  C64.AudioMachine, C64.Sound.SID;

type
  TSIDDecoder = class(TInterfacedObject, ITuneDecoder)
  private
    FInfo: TTuneInfo;
    FData: TBytes;
    FMachine: TC64AudioMachine;
    FLoad, FInit, FPlay: Word;
    FOffset, FClock: Integer;
    FSpeed: Cardinal;
    FBases: TArray<Word>;
    FModels: TArray<TSIDModel>;
    function BE(Offset: Integer): Word;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

function TSIDDecoder.BE(Offset: Integer): Word;
begin
  RequireBytes(FData, Offset, 2);
  Result := Integer(FData[Offset]) * 256 + FData[Offset + 1];
end;

constructor TSIDDecoder.Create(const Data: TBytes);
begin
  inherited Create;
  FData := Copy(Data);
  RequireBytes(FData, 0, $76);
  var Magic := TextField(FData, 0, 4);
  if Magic = 'RSID' then
    raise ENotSupportedException.Create('RSID requires a complete C64 with KERNAL/BASIC ROMs; PSID is supported');
  if Magic <> 'PSID' then
    raise EArgumentException.Create('Invalid SID signature');
  var Version := BE(4);
  if (Version < 1) or (Version > 4) then
    raise ENotSupportedException.Create('Unsupported PSID version');
  var HeaderSize := $76;
  if Version >= 2 then
    HeaderSize := $7C;
  RequireBytes(FData, 0, HeaderSize);
  FOffset := BE(6);
  if FOffset < HeaderSize then
    raise EArgumentException.Create('PSID data overlaps its header');
  RequireBytes(FData, FOffset, 1);
  FLoad := BE(8);
  FInit := BE(10);
  FPlay := BE(12);
  FInfo.TrackCount := BE(14);
  FInfo.DefaultTrack := Integer(BE(16)) - 1;
  if (FInfo.TrackCount < 1) or (FInfo.TrackCount > 256) or (FInfo.DefaultTrack < 0) or (FInfo.DefaultTrack >= FInfo.TrackCount) then
    raise EArgumentException.Create('Invalid PSID track table');
  FSpeed := (Cardinal(BE(18)) shl 16) or BE(20);
  var Flags: Integer := 0;
  if Version >= 2 then
    Flags := BE($76);
  if (Flags and 1) <> 0 then
    raise ENotSupportedException.Create('SID MUS data is not a PSID machine-code player');
  if FLoad = 0 then
  begin
    FLoad := LE16(FData, FOffset);
    Inc(FOffset, 2);
  end;
  RequireBytes(FData, FOffset, 1);
  if Length(FData) - FOffset > 65536 - Integer(FLoad) then
    raise EArgumentException.Create('PSID payload exceeds C64 memory');
  if FInit = 0 then
    FInit := FLoad;
  FClock := 985248;
  if ((Flags shr 2) and 3) = 2 then
    FClock := 1022727;
  FBases := [$D400];
  FModels := [MOS6581];
  if ((Flags shr 4) and 3) = 2 then
    FModels[0] := MOS8580;
  for var I := 1 to 2 do
    if ((I = 1) and (Version >= 3)) or ((I = 2) and (Version >= 4)) then
    begin
      var Value := FData[$79 + I];
      if Value = 0 then
        Continue;
      if ((Value and 1) <> 0) or not (((Value >= $42) and (Value <= $7E)) or ((Value >= $E0) and (Value <= $FE))) then
        raise EArgumentException.Create('Invalid additional SID address');
      var Address := $D000 + Integer(Value) * 16;
      for var Base in FBases do
        if Base = Address then
          raise EArgumentException.Create('Duplicate SID address');
      SetLength(FBases, Length(FBases) + 1);
      SetLength(FModels, Length(FModels) + 1);
      FBases[High(FBases)] := Address;
      FModels[High(FModels)] := MOS6581;
      if ((Flags shr (4 + I * 2)) and 3) = 2 then
        FModels[High(FModels)] := MOS8580;
    end;
  FInfo.Title := TextField(FData, $16, 32);
  FInfo.Artist := TextField(FData, $36, 32);
  FInfo.CopyrightText := TextField(FData, $56, 32);
  FInfo.FormatName := 'SID';
  FInfo.Channels := 2;
  FInfo.SampleRate := 44100;
  FInfo.Details := Format('PSID v%d / MOS6510 / %d SID(s), %d Hz', [Version, Length(FBases), FClock]);
  SelectTrack(FInfo.DefaultTrack);
end;

destructor TSIDDecoder.Destroy;
begin
  FMachine.Free;
  inherited;
end;

function TSIDDecoder.GetInfo: TTuneInfo;
begin
  Result := FInfo;
end;

procedure TSIDDecoder.SelectTrack(Index: Integer);
begin
  if (Index < 0) or (Index >= FInfo.TrackCount) then
    raise EArgumentOutOfRangeException.Create('SID track');
  FMachine.Free;
  FMachine := nil;
  FMachine := TC64AudioMachine.Create(FClock, FBases, FModels);
  for var I := 0 to Length(FData) - FOffset - 1 do
    FMachine.RAM[Integer(FLoad) + I] := FData[FOffset + I];
  FMachine.Start(FInit, FPlay, Index, (FSpeed and (Cardinal(1) shl Min(Index, 31))) <> 0);
end;

function TSIDDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 2);
  for var I := 0 to Frames - 1 do
    FMachine.Sample(Samples[I * 2], Samples[I * 2 + 1]);
  Result := Frames;
end;

function OpenSID(const Data: TBytes): ITuneDecoder;
begin
  Result := TSIDDecoder.Create(Data);
end;

initialization
  TTuneDecoders.RegisterFormat('.sid', 'SID / Commodore 64 (PSID)', OpenSID);

end.

