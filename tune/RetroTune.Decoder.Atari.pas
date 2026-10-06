unit RetroTune.Decoder.Atari;

interface

implementation

uses
  System.SysUtils, RetroTune.Decoder, RetroTune.Binary, Atari.AudioMachine;

type
  TAtariDecoder = class(TInterfacedObject, ITuneDecoder)
    Machine: TAtariAudioMachine;
    TuneInfo: TTuneInfo;
    Buffer: TBytes;
    constructor Create(const Data: TBytes; RMT: Boolean);
    destructor Destroy; override;
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

constructor TAtariDecoder.Create(const Data: TBytes; RMT: Boolean);
begin
  inherited Create;
  Machine := TAtariAudioMachine.Create(Data, RMT);
  var M := Machine.Info;
  TuneInfo.FormatName := 'SAP';
  if RMT then
    TuneInfo.FormatName := 'RMT';
  TuneInfo.Title := string(M.title);
  TuneInfo.Artist := string(M.author);
  TuneInfo.CopyrightText := string(M.date);
  TuneInfo.TrackCount := M.songs;
  TuneInfo.DefaultTrack := M.defaultSong;
  TuneInfo.Channels := 2;
  TuneInfo.SampleRate := 44100;
  TuneInfo.Details := 'Atari 8-bit, 6502 / POKEY';
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
  Result := TAtariDecoder.Create(Data, False);
end;

function RMT(const Data: TBytes): ITuneDecoder;
begin
  Result := TAtariDecoder.Create(Data, True);
end;

initialization
  TTuneDecoders.RegisterFormat('.sap', 'Atari SAP', SAP);
  TTuneDecoders.RegisterFormat('.rmt', 'Raster Music Tracker', RMT);

end.

