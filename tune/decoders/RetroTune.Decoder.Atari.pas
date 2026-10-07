unit RetroTune.Decoder.Atari;

interface

implementation

uses
  System.SysUtils, System.IOUtils, RetroTune.Decoder, RetroTune.Binary,
  Atari.AudioMachine;

type
  TAtariDecoder = class(TInterfacedObject, ITuneDecoder)
    Machine: TAtariAudioMachine;
    TuneInfo: TTuneInfo;
    Buffer: TBytes;
    constructor Create(const Data: TBytes; const Kind: string);
    destructor Destroy; override;
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

constructor TAtariDecoder.Create(const Data: TBytes; const Kind: string);
begin
  inherited Create;
  if Kind = 'MD1' then
  begin
    RequireBytes(Data, 0, 14);
    if (TEncoding.ASCII.GetString(Data, 0, 4) <> 'RMD1') or (Data[4] <> 1) or (Data[5] > 1) then
      raise EArgumentException.Create('MD1 requires its companion D15 or D8 sample bank; open the MD1 file by path');
    var ModuleSize := LE32(Data, 6);
    var BankSize := LE32(Data, 10);
    if (ModuleSize < 464) or (ModuleSize > 65000) or (BankSize < 288) or (BankSize > 12320) then
      raise EArgumentException.Create('Invalid MD1 snapshot lengths');
    if Length(Data) <> 14 + Integer(ModuleSize) + Integer(BankSize) then
      raise EArgumentException.Create('Truncated MD1 snapshot');
    Machine := TAtariAudioMachine.Create(Copy(Data, 14, ModuleSize), Kind,
      Copy(Data, 14 + Integer(ModuleSize), BankSize), Data[5] = 1);
  end
  else
    Machine := TAtariAudioMachine.Create(Data, Kind);
  var M := Machine.Info;
  TuneInfo.FormatName := Kind;
  TuneInfo.Title := string(M.title);
  TuneInfo.Artist := string(M.author);
  TuneInfo.CopyrightText := string(M.date);
  TuneInfo.TrackCount := M.songs;
  TuneInfo.DefaultTrack := M.defaultSong;
  TuneInfo.Channels := 2;
  TuneInfo.SampleRate := 44100;
  TuneInfo.Details := 'Atari 8-bit, 6502 / POKEY';
  if Kind = 'MD1' then
    if Data[5] = 1 then
      TuneInfo.Details := TuneInfo.Details + '; Music ProTracker, 1 sample channel, D15 bank'
    else
      TuneInfo.Details := TuneInfo.Details + '; Music ProTracker, 1 sample channel, D8 bank';
  if Kind = 'D15' then
  begin
    TuneInfo.Details := TuneInfo.Details + '; 15 kHz packed 4-bit sample bank';
    SetLength(TuneInfo.TrackNames, M.songs);
    for var I := 0 to M.songs - 1 do
      TuneInfo.TrackNames[I] := 'Sample ' + IntToStr(I + 1);
  end;
  if M.channels = 2 then
    TuneInfo.Details := TuneInfo.Details + ' stereo';
  SetLength(TuneInfo.TrackDurations, M.songs);
  var UnknownDuration := False;
  for var I := 0 to M.songs - 1 do
    if M.durations[I] >= 0 then
      TuneInfo.TrackDurations[I] := M.durations[I] / 1000.0
    else
    begin
      TuneInfo.TrackDurations[I] := 180;
      UnknownDuration := True;
    end;
  if UnknownDuration then
    TuneInfo.Details := TuneInfo.Details + '; default duration 3 min for tracks without TIME';
  SelectTrack(M.defaultSong);
end;

destructor TAtariDecoder.Destroy;
begin
  Machine.Free;
  inherited;
end;

function TAtariDecoder.GetInfo: TTuneInfo;
begin
  Result := TuneInfo;
end;

procedure TAtariDecoder.SelectTrack(Index: Integer);
begin
  if (Index < 0) or (Index >= TuneInfo.TrackCount) then
    raise EArgumentOutOfRangeException.Create('Atari track');
  Machine.Start(Index, Round(TuneInfo.TrackDurations[Index] * 1000));
end;

function TAtariDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 2);
  if Frames > 16 * 1024 * 1024 div 4 then
    raise EArgumentException.Create('Atari PCM request too large');
  SetLength(Buffer, Frames * Machine.Info.channels * 2);
  Result := Machine.Generate(Buffer, Frames);
  for var I := 0 to Result - 1 do
  begin
    var L := Integer(Buffer[I * Machine.Info.channels * 2]) + Integer(Buffer[I * Machine.Info.channels * 2 + 1]) * 256;
    if L >= 32768 then
      Dec(L, 65536);
    var R := L;
    if Machine.Info.channels = 2 then
    begin
      R := Integer(Buffer[I * 4 + 2]) + Integer(Buffer[I * 4 + 3]) * 256;
      if R >= 32768 then
        Dec(R, 65536);
    end;
    Samples[I * 2] := L;
    Samples[I * 2 + 1] := R;
  end;
end;

function SAP(const Data: TBytes): ITuneDecoder;
begin
  Result := TAtariDecoder.Create(Data, 'SAP');
end;

function RMT(const Data: TBytes): ITuneDecoder;
begin
  Result := TAtariDecoder.Create(Data, 'RMT');
end;

function D15(const Data: TBytes): ITuneDecoder;
begin
  Result := TAtariDecoder.Create(Data, 'D15');
end;

function MD1(const Data: TBytes): ITuneDecoder;
begin
  Result := TAtariDecoder.Create(Data, 'MD1');
end;

function ResolveMD1(const Path: string; const Data: TBytes): TBytes;

  procedure PutWord(At, Value: Integer);
  begin
    for var I := 0 to 3 do
      Result[At + I] := (Value shr (I * 8)) and 255;
  end;

begin
  if (Length(Data) < 464) or (Length(Data) > 65000) then
    raise EArgumentException.Create('Invalid MD1 module size');
  var Name := TPath.ChangeExtension(Path, '.d15');
  var Is15kHz := True;
  if not TFile.Exists(Name) then
  begin
    Name := TPath.ChangeExtension(Path, '.d8');
    Is15kHz := False;
  end;
  if not TFile.Exists(Name) then
    raise EArgumentException.Create('MD1 companion sample bank not found: ' + TPath.ChangeExtension(Path, '.d15') + ' / .d8');
  var Bank := TTuneDecoders.ReadData(Name);
  if (Length(Bank) < 288) or (Length(Bank) > 12320) then
    raise EArgumentException.Create('Invalid MD1 sample bank size');
  // Capture both files once; reset, seek and WAV export reuse this snapshot.
  SetLength(Result, 14 + Length(Data) + Length(Bank));
  var Magic := TEncoding.ASCII.GetBytes('RMD1');
  for var I := 0 to 3 do
    Result[I] := Magic[I];
  Result[4] := 1;
  Result[5] := Ord(Is15kHz);
  PutWord(6, Length(Data));
  PutWord(10, Length(Bank));
  for var I := 0 to High(Data) do
    Result[14 + I] := Data[I];
  for var I := 0 to High(Bank) do
    Result[14 + Length(Data) + I] := Bank[I];
end;

initialization
  TTuneDecoders.RegisterFormat('.d15', 'Atari MPT 15 kHz sample bank', D15);
  TTuneDecoders.RegisterFormat('.md1', 'Atari Music ProTracker with samples', MD1);
  TTuneDecoders.RegisterDataLoader('.md1', ResolveMD1);
  TTuneDecoders.RegisterFormat('.sap', 'Atari SAP', SAP);
  TTuneDecoders.RegisterFormat('.rmt', 'Raster Music Tracker', RMT);

end.

