unit RetroTune.Decoder.SPC;

interface

uses
  System.SysUtils, RetroTune.Decoder, SNES.SPC;

type
  TSPCDecoder = class(TInterfacedObject, ITuneDecoder)
  private
    FInfo: TTuneInfo;
    FData: TBytes;
    FSPC: TSnesSPC;
    FRead, FCount: Integer;
    FReady: Boolean;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

implementation

uses
  RetroTune.Binary;

constructor TSPCDecoder.Create(const Data: TBytes);
begin
  inherited Create;
  RequireBytes(Data, 0, $10200);
  if TEncoding.ASCII.GetString(Data, 0, 33) <> 'SNES-SPC700 Sound File Data v0.30' then
    raise EArgumentException.Create('Invalid SPC signature');
  if (Data[$21] <> $1A) or (Data[$22] <> $1A) then
    raise EArgumentException.Create('Invalid SPC header');
  FData := Copy(Data);
  FInfo.FormatName := 'SPC';
  FInfo.Details := 'SNES SPC700 / DSP';
  FInfo.TrackCount := 1;
  FInfo.SampleRate := 32000;
  FInfo.Channels := 2;
  if Data[$23] = $1A then
  begin
    FInfo.Title := TextField(Data, $2E, 32);
    FInfo.CopyrightText := TextField(Data, $4E, 32);
    // ID666 text and binary variants place the artist at different offsets.
    if (Data[$9E] >= Ord('0')) and (Data[$9E] <= Ord('9')) then
      FInfo.Artist := TextField(Data, $B1, 32)
    else
      FInfo.Artist := TextField(Data, $B0, 32);
  end;
  FSPC := TSnesSPC.Create;
end;

destructor TSPCDecoder.Destroy;
begin
  FSPC.Free;
  inherited;
end;

function TSPCDecoder.GetInfo: TTuneInfo;
begin
  Result := FInfo;
end;

procedure TSPCDecoder.SelectTrack(Index: Integer);
begin
  if Index <> 0 then
    raise EArgumentOutOfRangeException.Create('Invalid SPC track');
  FSPC.Reset;
  Move(FData[$100], FSPC.State.RAM[0], $10000);
  Move(FData[$10100], FSPC.State.DSP[0], $80);
  FSPC.State.PC := LE16(FData, $25);
  FSPC.State.A := FData[$27];
  FSPC.State.X := FData[$28];
  FSPC.State.Y := FData[$29];
  FSPC.State.P := FData[$2A];
  FSPC.State.SP := FData[$2B];
  FSPC.State.Control := FSPC.State.RAM[$F1];
  for var J := 0 to 3 do
  begin
    FSPC.State.PortsIn[J] := FSPC.State.RAM[$F4 + J];
    FSPC.State.PortsOut[J] := FSPC.State.PortsIn[J];
  end;
  for var J := 0 to 2 do
    FSPC.State.TimerOutput[J] := FSPC.State.RAM[$FD + J] and 15;
  // The dump contains hidden RAM under the enabled IPL ROM.
  if (FSPC.State.Control and $80) <> 0 then
    Move(FData[$101C0], FSPC.State.RAM[$FFC0], 64);
  var DSPAddress := FSPC.State.RAM[$F2];
  FSPC.Write($F2, $4C);
  FSPC.Write($F3, FData[$1014C]);
  FSPC.Write($F2, DSPAddress);
  FRead := 0;
  FCount := 0;
  FReady := True;
end;

function TSPCDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 2);
  if not FReady then
    raise EInvalidOpException.Create('Select a track before rendering');
  Result := 0;
  while Result < Frames do
  begin
    if FRead = FCount then
    begin
      FSPC.BeginFrame;
      FSPC.RunUntil(FSPC.State.Cycles + 512 * 32);
      FRead := 0;
      FCount := FSPC.SampleFrames;
    end;
    var N := Frames - Result;
    if N > FCount - FRead then
      N := FCount - FRead;
    var PCM := FSPC.Samples;
    Move(PCM[FRead * 2], Samples[Result * 2], N * 4);
    Inc(Result, N);
    Inc(FRead, N);
  end;
end;

function CreateSPC(const Data: TBytes): ITuneDecoder;
begin
  Result := TSPCDecoder.Create(Data);
end;

initialization
  TTuneDecoders.RegisterFormat('.spc', 'Super Nintendo SPC', CreateSPC);

end.

