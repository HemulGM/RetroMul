unit Flash.Audio;

interface

uses
  System.SysUtils, System.Generics.Collections, SWF.Sound;

type
  TFlashSoundTransform = record
    Volume, LL, LR, RL, RR: Integer; // Output channel first, input channel second.
    class function Identity: TFlashSoundTransform; static;
    function ThenBy(const Next: TFlashSoundTransform): TFlashSoundTransform;
    function Pan: Integer;
    procedure SetPan(Value: Integer);
  end;

  TFlashSoundTransformReader = function(Owner: TObject): TFlashSoundTransform of object;

  TFlashSoundProgress = procedure(Client: TObject; Position: UInt32; Finished: Boolean) of object;

  TFlashSoundVoice = record
    Sound: TSWFSound;
    Owner, Client: TObject;
    IsStream: Boolean;
    StartFrame, EndFrame, Loops: Integer;
    Phase: Int64;
    Envelope: TArray<TSWFSoundEnvelope>;
    EnvelopeIndex: Integer;
    Played: Int64;
  end;

  TFlashAudio = class
  private
    FVoices: TList<TFlashSoundVoice>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start(Sound: TSWFSound; Owner: TObject; const Info: TSWFSoundInfo; Client: TObject = nil);
    procedure StartStream(Sound: TSWFSound; Owner: TObject; FirstFrame, EndFrame: Integer);
    procedure StopStream(Owner: TObject);
    procedure StopSound(Sound: TSWFSound);
    procedure StopOwner(Owner: TObject);
    procedure Clear;
    procedure VisitClients(const Visit: TProc<TObject>);
    function Mix(Frames: Integer; ReadTransform: TFlashSoundTransformReader = nil; Progress: TFlashSoundProgress = nil): TArray<SmallInt>;
  end;

implementation

uses
  System.Math;

class function TFlashSoundTransform.Identity: TFlashSoundTransform;
begin
  Result := Default(TFlashSoundTransform);
  Result.Volume := 100;
  Result.LL := 100;
  Result.RR := 100;
end;

function TFlashSoundTransform.ThenBy(const Next: TFlashSoundTransform): TFlashSoundTransform;
const
  Mask = $3FFFFFFF;
begin
  // The accumulated coefficients are at most 30 bits, so the products and
  // their sums fit an Int64 even for arbitrary values from ActionScript.
  Result.Volume := Abs(Int64(Volume) * Next.Volume div 100) and Mask;
  Result.LL := ((Int64(LL) * Next.LL + Int64(RL) * Next.LR) div 100) and Mask;
  Result.LR := ((Int64(LR) * Next.LL + Int64(RR) * Next.LR) div 100) and Mask;
  Result.RL := ((Int64(LL) * Next.RL + Int64(RL) * Next.RR) div 100) and Mask;
  Result.RR := ((Int64(LR) * Next.RL + Int64(RR) * Next.RR) div 100) and Mask;
end;

function TFlashSoundTransform.Pan: Integer;
begin
  if LL <> 100 then
    Result := 100 - Abs(Int64(LL))
  else
    Result := Abs(Int64(RR)) - 100;
end;

procedure TFlashSoundTransform.SetPan(Value: Integer);
begin
  LL := 100;
  RR := 100;
  LR := 0;
  RL := 0;
  if Value >= 0 then
    LL := 100 - Value
  else
    RR := 100 + Value;
end;

constructor TFlashAudio.Create;
begin
  inherited Create;
  FVoices := TList<TFlashSoundVoice>.Create;
end;

destructor TFlashAudio.Destroy;
begin
  FVoices.Free;
  inherited;
end;

procedure TFlashAudio.Start(Sound: TSWFSound; Owner: TObject; const Info: TSWFSoundInfo; Client: TObject);
var
  I: Integer;
  Voice: TFlashSoundVoice;
begin
  if Sound = nil then
    Exit;
  if Info.Stop then
  begin
    StopSound(Sound);
    Exit;
  end;
  if Info.NoMultiple then
    for I := 0 to FVoices.Count - 1 do
      if FVoices[I].Sound = Sound then
        Exit;
  if (FVoices.Count >= 64) or (Sound.FrameCount = 0) then
    Exit;
  Voice := Default(TFlashSoundVoice);
  Voice.Sound := Sound;
  Voice.Owner := Owner;
  Voice.Client := Client;
  Voice.StartFrame := Min(Sound.FrameCount, Int64(Info.First) * Sound.SampleRate div SWFSoundRate);
  Voice.EndFrame := Sound.FrameCount;
  if Info.HasEnd then
    Voice.EndFrame := Min(Voice.EndFrame, Int64(Info.Last) * Sound.SampleRate div SWFSoundRate + 1);
  if Voice.StartFrame >= Voice.EndFrame then
    Exit;
  Voice.Phase := Int64(Voice.StartFrame) * SWFSoundRate;
  Voice.Loops := Max(1, Info.Loops);
  Voice.Envelope := Info.Envelope;
  FVoices.Add(Voice);
end;

procedure TFlashAudio.StopSound(Sound: TSWFSound);
var
  I: Integer;
begin
  for I := FVoices.Count - 1 downto 0 do
    if FVoices[I].Sound = Sound then
      FVoices.Delete(I);
end;

procedure TFlashAudio.StartStream(Sound: TSWFSound; Owner: TObject; FirstFrame, EndFrame: Integer);
var
  I: Integer;
  Voice: TFlashSoundVoice;
begin
  for I := FVoices.Count - 1 downto 0 do
    if FVoices[I].IsStream and (FVoices[I].Owner = Owner) then
    begin
      if (FVoices[I].Sound = Sound) and (FVoices[I].EndFrame = EndFrame) then
        Exit;
      FVoices.Delete(I);
    end;
  if (FVoices.Count >= 64) or (Sound = nil) or (FirstFrame >= EndFrame) then
    Exit;
  Voice := Default(TFlashSoundVoice);
  Voice.Sound := Sound;
  Voice.Owner := Owner;
  Voice.IsStream := True;
  Voice.StartFrame := FirstFrame;
  Voice.EndFrame := EndFrame;
  Voice.Phase := Int64(FirstFrame) * SWFSoundRate;
  Voice.Loops := 1;
  FVoices.Add(Voice);
end;

procedure TFlashAudio.StopStream(Owner: TObject);
var
  I: Integer;
begin
  for I := FVoices.Count - 1 downto 0 do
    if FVoices[I].IsStream and (FVoices[I].Owner = Owner) then
      FVoices.Delete(I);
end;

procedure TFlashAudio.StopOwner(Owner: TObject);
var
  I: Integer;
begin
  for I := FVoices.Count - 1 downto 0 do
    if FVoices[I].Owner = Owner then
      FVoices.Delete(I);
end;

procedure TFlashAudio.Clear;
begin
  FVoices.Clear;
end;

procedure TFlashAudio.VisitClients(const Visit: TProc<TObject>);
var
  Voice: TFlashSoundVoice;
begin
  for Voice in FVoices do
    if Voice.Client <> nil then
      Visit(Voice.Client);
end;

procedure EnvelopeGains(var Voice: TFlashSoundVoice; out Left, Right: Integer);
var
  A, B: TSWFSoundEnvelope;
  Age, Span: Int64;
begin
  Left := 32768;
  Right := 32768;
  if Length(Voice.Envelope) = 0 then
    Exit;
  while (Voice.EnvelopeIndex < High(Voice.Envelope)) and
      (Voice.Played >= Voice.Envelope[Voice.EnvelopeIndex + 1].Position) do
    Inc(Voice.EnvelopeIndex);
  A := Voice.Envelope[Voice.EnvelopeIndex];
  Left := A.LeftGain;
  Right := A.RightGain;
  if (Voice.Played <= A.Position) or (Voice.EnvelopeIndex = High(Voice.Envelope)) then
    Exit;
  B := Voice.Envelope[Voice.EnvelopeIndex + 1];
  Span := Int64(B.Position) - A.Position;
  if Span <= 0 then
    Exit;
  Age := Voice.Played - A.Position;
  Left := Left + (Integer(B.LeftGain) - Left) * Age div Span;
  Right := Right + (Integer(B.RightGain) - Right) * Age div Span;
end;

function TFlashAudio.Mix(Frames: Integer; ReadTransform: TFlashSoundTransformReader; Progress: TFlashSoundProgress): TArray<SmallInt>;
var
  Voice: TFlashSoundVoice;
  Accum: TArray<Double>;
  Buffer: TArray<SmallInt>;
  Transform: TFlashSoundTransform;
  I, J, Frame, Offset, Following, Fraction, L, R, GainL, GainR: Integer;
  LL, LR, RL, RR, Scale: Double;
  EndPhase, LoopSpan, CompletedLoops: Int64;
  Position: UInt32;
begin
  Result := nil;
  if (Frames < 0) or (Frames > SWFSoundRate) then
    raise EArgumentOutOfRangeException.Create('Flash audio batch size');
  if (Frames = 0) or (FVoices.Count = 0) then
    Exit;
  SetLength(Accum, Frames * 2);
  I := 0;
  while I < FVoices.Count do
  begin
    Voice := FVoices[I];
    Transform := TFlashSoundTransform.Identity;
    if Assigned(ReadTransform) then
      Transform := ReadTransform(Voice.Owner);
    Scale := Transform.Volume / 10000.0;
    LL := Transform.LL * Scale;
    LR := Transform.LR * Scale;
    RL := Transform.RL * Scale;
    RR := Transform.RR * Scale;
    EndPhase := Int64(Voice.EndFrame) * SWFSoundRate;
    LoopSpan := Int64(Voice.EndFrame - Voice.StartFrame) * SWFSoundRate;
    for J := 0 to Frames - 1 do
    begin
      Frame := Voice.Phase div SWFSoundRate;
      Fraction := Voice.Phase mod SWFSoundRate;
      Offset := Frame * Voice.Sound.Channels;
      Following := Offset;
      if Frame + 1 < Voice.EndFrame then
        Inc(Following, Voice.Sound.Channels)
      else if Voice.Loops > 1 then
        Following := Voice.StartFrame * Voice.Sound.Channels;
      L := (Int64(Voice.Sound.Samples[Offset]) * (SWFSoundRate - Fraction) +
        Int64(Voice.Sound.Samples[Following]) * Fraction) div SWFSoundRate;
      R := L;
      if Voice.Sound.Channels = 2 then
        R := (Int64(Voice.Sound.Samples[Offset + 1]) * (SWFSoundRate - Fraction) +
          Int64(Voice.Sound.Samples[Following + 1]) * Fraction) div SWFSoundRate;
      EnvelopeGains(Voice, GainL, GainR);
      if Voice.Sound.Channels = 1 then
      begin
        GainL := (GainL + GainR) div 2;
        GainR := GainL;
      end;
      L := Int64(L) * GainL div 32768;
      R := Int64(R) * GainR div 32768;
      Accum[J * 2] := Accum[J * 2] + L * LL + R * LR;
      Accum[J * 2 + 1] := Accum[J * 2 + 1] + L * RL + R * RR;
      Inc(Voice.Played);
      Inc(Voice.Phase, Voice.Sound.SampleRate);
      if Voice.Phase >= EndPhase then
      begin
        CompletedLoops := 1 + (Voice.Phase - EndPhase) div LoopSpan;
        if CompletedLoops >= Voice.Loops then
        begin
          Voice.Loops := 0;
          Break;
        end;
        Dec(Voice.Loops, Integer(CompletedLoops));
        Dec(Voice.Phase, LoopSpan * CompletedLoops);
      end;
    end;
    if Voice.Loops = 0 then
      FVoices.Delete(I)
    else
    begin
      FVoices[I] := Voice;
      Inc(I);
    end;
    if (Voice.Client <> nil) and Assigned(Progress) then
    begin
      if Voice.Loops = 0 then
        Position := Trunc(Voice.Sound.FrameCount * 1000.0 / Voice.Sound.SampleRate + 0.5)
      else
        Position := Trunc(Voice.Phase * 1000.0 / (Int64(SWFSoundRate) * Voice.Sound.SampleRate) + 0.5);
      Progress(Voice.Client, Position, Voice.Loops = 0);
    end;
  end;
  SetLength(Buffer, Frames * 2);
  for I := 0 to High(Buffer) do
    Buffer[I] := SmallInt(Trunc(EnsureRange(Accum[I], -32768.0, 32767.0)));
  Result := Buffer;
end;

end.

