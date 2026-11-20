unit Audio.Music.SPC;

interface

uses
  Audio.Types, System.SysUtils, Audio.Decoder, SNES.SPC;

type
  TSPCDecoder = class(TAudioMusicSource)
  private
    FInfo: TAudioInfo;
    FData: TBytes;
    FSPC: TSnesSPC;
    FRead, FCount: Integer;
    FPosition, FFadeStart, FEndFrame: Int64;
    FReady: Boolean;
    procedure ReadTags(const Data: TBytes);
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    function GetInfo: TAudioInfo; override;
    procedure SelectTrack(Index: Integer); override;
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer; override;
  end;

function CreateSPC(const Data: TBytes): IAudioSource;

implementation

uses
  System.Math, Audio.Binary;

const
  SPCSampleRate = 32000;
  ID666TicksPerSecond = 64000;
  SPCBaseSize = $10200;
  MaxTimingTicks = 383999999;

function ReadDecimalField(const Data: TBytes; Offset, Count: Integer): Integer;
begin
  var Value := TextField(Data, Offset, Count);
  if Value = '' then
    Exit(-1);
  Result := 0;
  for var Digit in Value do
  begin
    if not CharInSet(Digit, ['0'..'9']) then
      Exit(-1);
    Result := Result * 10 + Ord(Digit) - Ord('0');
  end;
end;

procedure ReadExtendedTiming(const Data: TBytes; var PlayTicks, FadeTicks: Int64);
var
  Intro, LoopLength, Ending, Fade, LoopCount, Offset, PayloadSize, ChunkEnd: Integer;
begin
  if (Length(Data) < SPCBaseSize + 8) or (LE32(Data, SPCBaseSize) <> $36646978) then
    Exit;
  Offset := SPCBaseSize + 8;
  var ChunkSize := LE32(Data, SPCBaseSize + 4);
  if ChunkSize > Cardinal(Length(Data) - Offset) then
    Exit;
  ChunkEnd := Offset + Integer(ChunkSize);
  Intro := 0;
  LoopLength := 0;
  Ending := 0;
  Fade := -1;
  LoopCount := 1;
  while Offset < ChunkEnd do
  begin
    if ChunkEnd - Offset < 4 then
      Exit;
    var ID := Data[Offset];
    var ItemType := Data[Offset + 1];
    var Value := LE16(Data, Offset + 2);
    Inc(Offset, 4);
    if ItemType = 0 then
    begin
      if (ID = $35) and (Value <= High(Byte)) then
        LoopCount := Value;
      Continue;
    end;
    PayloadSize := (Integer(Value) + 3) and not 3;
    if PayloadSize > ChunkEnd - Offset then
      Exit;
    if (ItemType = 4) and (Value = 4) then
    begin
      var Ticks := Integer(LE32(Data, Offset));
      case ID of
        $30:
          Intro := Ticks;
        $31:
          LoopLength := Ticks;
        $32:
          Ending := Ticks;
        $33:
          Fade := Ticks;
      end;
    end;
    Inc(Offset, PayloadSize);
  end;
  var Total := Int64(Intro) + Int64(LoopLength) * LoopCount + Ending;
  if (Intro >= 0) and (LoopLength >= 0) and (Total > 0) and (Total <= MaxTimingTicks) then
    PlayTicks := Total;
  if (Fade >= 0) and (Fade <= MaxTimingTicks) then
    FadeTicks := Fade;
end;

procedure TSPCDecoder.ReadTags(const Data: TBytes);
var
  PlayTicks, FadeTicks, PlaySeconds, FadeMilliseconds: Int64;
  TextTag, TextDate, TextFadeField: Boolean;
begin
  PlayTicks := 0;
  FadeTicks := 0;
  if Data[$23] = $1A then
  begin
    FInfo.Title := TextField(Data, $2E, 32);
    FInfo.CopyrightText := TextField(Data, $4E, 32);
    PlaySeconds := ReadDecimalField(Data, $A9, 3);
    FadeMilliseconds := ReadDecimalField(Data, $AC, 5);
    // There is no format flag. Text dumps often leave the date empty.
    TextDate := (Data[$9E] in [Ord('0')..Ord('9')]) and
      ((Data[$9F] = Ord('/')) or (Data[$A0] = Ord('/')) or (Data[$A2] in [Ord('/'), Ord('-')]));
    TextFadeField := (Data[$B0] in [0, Ord(' '), Ord('0')..Ord('9')]) and
      ((FadeMilliseconds >= 0) or ((Data[$B0] = 0) and (Data[$B1] <> 0)));
    TextTag := TextDate or (Data[$D2] in [Ord('0')..Ord('9')]) or
      ((PlaySeconds >= 0) and ((Data[$AA] in [Ord('0')..Ord('9')]) or
      TextFadeField));
    if TextTag then
      FInfo.Artist := TextField(Data, $B1, 32)
    else
    begin
      FInfo.Artist := TextField(Data, $B0, 32);
      PlaySeconds := LE16(Data, $A9) or (Integer(Data[$AB]) shl 16);
      FadeMilliseconds := LE32(Data, $AC);
    end;
    if (PlaySeconds > 0) and (PlaySeconds <= MaxTimingTicks div ID666TicksPerSecond) then
      PlayTicks := PlaySeconds * ID666TicksPerSecond;
    if (FadeMilliseconds > 0) and (FadeMilliseconds <= MaxTimingTicks div (ID666TicksPerSecond div 1000)) then
      FadeTicks := FadeMilliseconds * (ID666TicksPerSecond div 1000);
  end;
  ReadExtendedTiming(Data, PlayTicks, FadeTicks);
  if PlayTicks > 0 then
  begin
    FFadeStart := (PlayTicks * SPCSampleRate + ID666TicksPerSecond - 1) div ID666TicksPerSecond;
    FEndFrame := ((PlayTicks + FadeTicks) * SPCSampleRate + ID666TicksPerSecond - 1) div ID666TicksPerSecond;
    FInfo.TrackDurations := [FEndFrame / SPCSampleRate];
  end;
end;

constructor TSPCDecoder.Create(const Data: TBytes);
begin
  inherited Create;
  RequireBytes(Data, 0, SPCBaseSize);
  if TEncoding.ASCII.GetString(Data, 0, 33) <> 'SNES-SPC700 Sound File Data v0.30' then
    raise EArgumentException.Create('Invalid SPC signature');
  if (Data[$21] <> $1A) or (Data[$22] <> $1A) then
    raise EArgumentException.Create('Invalid SPC header');
  FData := Copy(Data);
  FInfo.FormatName := 'SPC';
  FInfo.Details := 'SNES SPC700 / DSP';
  FInfo.TrackCount := 1;
  FInfo.SampleRate := SPCSampleRate;
  FInfo.Channels := 2;
  ReadTags(Data);
  FSPC := TSnesSPC.Create;
end;

destructor TSPCDecoder.Destroy;
begin
  FSPC.Free;
  inherited;
end;

function TSPCDecoder.GetInfo: TAudioInfo;
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
  begin
    FSPC.State.TimerTarget[J] := FSPC.State.RAM[$FA + J];
    FSPC.State.TimerOutput[J] := FSPC.State.RAM[$FD + J] and 15;
  end;
  // The dump contains hidden RAM under the enabled IPL ROM.
  if (FSPC.State.Control and $80) <> 0 then
    Move(FData[$101C0], FSPC.State.RAM[$FFC0], 64);
  var DSPAddress := FSPC.State.RAM[$F2];
  FSPC.Write($F2, $4C);
  FSPC.Write($F3, FData[$1014C]);
  FSPC.Write($F2, DSPAddress);
  FRead := 0;
  FCount := 0;
  FPosition := 0;
  FReady := True;
end;

function TSPCDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 2);
  if not FReady then
    raise EInvalidOpException.Create('Select a track before rendering');
  if FEndFrame > 0 then
    Frames := Integer(Min(Int64(Frames), FEndFrame - FPosition));
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
  if FEndFrame > FFadeStart then
    for var J := Integer(Max(Int64(0), FFadeStart - FPosition)) to Result - 1 do
    begin
      // Halve the amplitude eight times over the fade, interpolating each step.
      var Step := 8 * (FPosition + J - FFadeStart) / (FEndFrame - FFadeStart);
      var WholeStep := Trunc(Step);
      var Gain := (1 - 0.5 * (Step - WholeStep)) / (1 shl WholeStep);
      Samples[J * 2] := Round(Samples[J * 2] * Gain);
      Samples[J * 2 + 1] := Round(Samples[J * 2 + 1] * Gain);
    end;
  Inc(FPosition, Result);
end;

function CreateSPC(const Data: TBytes): IAudioSource;
begin
  Result := TSPCDecoder.Create(Data);
end;

end.

