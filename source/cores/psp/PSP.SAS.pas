unit PSP.SAS;

// sceSasCore: the SAS voice synthesizer the Media Engine runs for games. Up to
// 32 voices of VAG ADPCM, 16-bit PCM, noise or simple waves, each with a
// per-sample ADSR envelope (heights 0..0x40000000), pitch, dry and effect
// volumes, mixed one grain at a time into stereo or four-plane output. The
// effect send goes through the SPU-style reverb. Parameters are mirrored into
// the guest's SasCore structure where programs read them back.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel,
  PSP.Scheduler, PSP.Service;

const
  PSPSasVoices = 32;
  PSPSasEnvelopeMax = $40000000;

  PSP_SAS_ERROR_ADDRESS = Cardinal($80420005);
  PSP_SAS_ERROR_GRAIN = Cardinal($80420001);
  PSP_SAS_ERROR_MAXVOICES = Cardinal($80420002);
  PSP_SAS_ERROR_OUTPUTMODE = Cardinal($80420003);
  PSP_SAS_ERROR_SAMPLERATE = Cardinal($80420004);
  PSP_SAS_ERROR_VOICE_INDEX = Cardinal($80420010);
  PSP_SAS_ERROR_NOISE_CLOCK = Cardinal($80420011);
  PSP_SAS_ERROR_PITCH_VAL = Cardinal($80420012);
  PSP_SAS_ERROR_ADSR_MODE = Cardinal($80420013);
  PSP_SAS_ERROR_ADPCM_SIZE = Cardinal($80420014);
  PSP_SAS_ERROR_LOOP_MODE = Cardinal($80420015);
  PSP_SAS_ERROR_INVALID_STATE = Cardinal($80420016);
  PSP_SAS_ERROR_VOLUME_VAL = Cardinal($80420018);
  PSP_SAS_ERROR_ADSR_VAL = Cardinal($80420019);
  PSP_SAS_ERROR_PCM_SIZE = Cardinal($8042001A);
  PSP_SAS_ERROR_FX_TYPE = Cardinal($80420020);
  PSP_SAS_ERROR_FX_FEEDBACK = Cardinal($80420021);
  PSP_SAS_ERROR_FX_DELAY = Cardinal($80420022);
  PSP_SAS_ERROR_FX_VOLUME_VAL = Cardinal($80420023);
  PSP_SAS_ERROR_NOT_SUPPORTED = Cardinal($80000004);

type
  TPSPSasVoiceKind = (svNone, svVAG, svNoise, svTriangle, svSteep, svPCM, svATRAC3);
  TPSPSasPhase = (spOff, spAttack, spDecay, spSustain, spRelease);

  // The voice's source when it is an ATRAC3 stream (see PSP.Atrac).
  TPSPSasAtracSource = class
  public
    // Fills Count mono samples, returns False when the stream has ended.
    function Read(Buffer: PSmallInt; Count: Integer): Boolean; virtual; abstract;
    procedure Restart; virtual; abstract;
    procedure Concatenate(Address: Cardinal; Size: Integer); virtual; abstract;
  end;

  TPSPSasVoice = record
    Kind: TPSPSasVoiceKind;
    Address: Cardinal;
    Size: Integer;
    Loop: Integer;
    Pitch: Integer;
    VolLeft, VolRight, EffectLeft, EffectRight: Integer;
    Rate: array[0..3] of Integer;
    Curve: array[0..3] of Integer;
    SustainLevel: Integer;
    NoiseFreq: Integer;
    WaveParam: Integer;
    On: Boolean;
    Paused: Boolean;
    Playing: Boolean;
    Phase: TPSPSasPhase;
    Height: Integer;
    Delay: Integer;
    // Source stream: Cur is output at a zero fraction, Next follows it.
    Cur, Next: Integer;
    NextValid: Boolean;
    Frac: Integer;
    SourceDone: Boolean;
    // PCM
    PcmPos: Integer;
    // VAG
    VagBlock: Integer;
    VagIndex: Integer;
    VagHist1, VagHist2: Integer;
    VagLoopBlock: Integer;
    VagLast: Boolean;
    VagRepeat: Boolean;
    VagSamples: array[0..27] of SmallInt;
    // Noise
    NoiseLevel: Cardinal;
    NoiseTimer: Integer;
    // Waves
    WavePos: Integer;
    Atrac: TPSPSasAtracSource;
  end;

  TPSPSasCore = class(TPSPService)
  private
    FScheduler: TPSPScheduler;
    FAddress: Cardinal;
    FInited: Boolean;
    FGrain: Integer;
    FMaxVoices: Integer;
    FOutputMode: Integer;
    FVoices: array[0..PSPSasVoices - 1] of TPSPSasVoice;
    FRevType: Integer;
    FRevDelay, FRevFeedback: Integer;
    FRevVolLeft, FRevVolRight: Integer;
    FDry, FWet: Boolean;
    FDryL, FDryR, FWetL, FWetR: TArray<Integer>;
    // Reverb work area (SPU style, 22.05 kHz).
    FRevBuffer: TArray<SmallInt>;
    FRevPos: Integer;
    FRevOdd: Boolean;
    FRevOutL, FRevOutR: Integer;
    FRevInL, FRevInR: Integer;
    function VoiceAddress(V: Integer): Cardinal; inline;
    procedure WriteVoice(V: Integer);
    procedure WriteHeader;
    procedure ResetVoice(var V: TPSPSasVoice);
    function CheckVoice(V: Integer): Boolean;
    function Fetch(var V: TPSPSasVoice; out S: Integer): Boolean;
    procedure DecodeVagBlock(var V: TPSPSasVoice);
    function FetchVag(var V: TPSPSasVoice; out S: Integer): Boolean;
    function FetchPcm(var V: TPSPSasVoice; out S: Integer): Boolean;
    function FetchNoise(var V: TPSPSasVoice): Integer;
    function FetchWave(var V: TPSPSasVoice): Integer;
    procedure StartSource(var V: TPSPSasVoice);
    procedure Advance(var V: TPSPSasVoice);
    procedure StepEnvelope(var V: TPSPSasVoice);
    procedure RenderVoice(var V: TPSPSasVoice; Count: Integer);
    procedure Reverb(Count: Integer);
    procedure ReverbSample(InL, InR: Integer; out OutL, OutR: Integer);
    procedure MixGrain(Output: Cardinal; WithMix: Boolean; MixLeft, MixRight: Integer);
    procedure CoreWait;
    procedure hInit;
    procedure hCore;
    procedure hCoreWithMix;
    procedure hGetEndFlag;
    procedure hSetVolume;
    procedure hSetPitch;
    procedure hSetVoice;
    procedure hSetVoicePCM;
    procedure hSetNoise;
    procedure hSetTriangularWave;
    procedure hSetSteepWave;
    procedure hSetADSR;
    procedure hSetADSRmode;
    procedure hSetSL;
    procedure hSetSimpleADSR;
    procedure hGetEnvelopeHeight;
    procedure hGetAllEnvelopeHeights;
    procedure hSetKeyOn;
    procedure hSetKeyOff;
    procedure hSetPause;
    procedure hGetPauseFlag;
    procedure hRevVON;
    procedure hRevEVOL;
    procedure hRevType;
    procedure hRevParam;
    procedure hGetGrain;
    procedure hSetGrain;
    procedure hGetOutputmode;
    procedure hSetOutputmode;
    procedure hSetVoiceATRAC3;
    procedure hConcatenateATRAC3;
    procedure hUnsetATRAC3;
  public
    constructor Create(System: TPSPSystem); override;
    destructor Destroy; override;
    procedure Reset; override;
    procedure Register; override;
  end;

  // PSP.Atrac provides the ATRAC3 voice source for a context address.
  TPSPSasAtracFactory = function(Context: Cardinal; out Source: TPSPSasAtracSource): Cardinal of object;

var
  PSPSasAtracFactory: TPSPSasAtracFactory;

implementation

uses
  System.Math;

const
  // Extended PS-ADPCM predictors (1/64 units).
  VagCoef: array[0..15, 0..1] of Integer = (
    (0, 0), (60, 0), (115, -52), (98, -55), (122, -60), (0, 0), (0, 0), (52, 0),
    (55, -2), (60, -125), (0, 0), (0, -91), (0, 0), (2, -216), (125, -6), (0, -151));

  // The ME starts a keyed-on voice 32 samples into the next grain.
  KeyOnDelay = 32;

  VoiceBase = 20;
  VoiceStride = 56;

  CurveLinearIncrease = 0;
  CurveLinearDecrease = 1;
  CurveLinearBent = 2;
  CurveExponentDecrease = 3;
  CurveExponentIncrease = 4;
  CurveDirect = 5;

function Sar(V: Int64; S: Integer): Int64; inline;
begin
  if V >= 0 then
    Result := V shr S
  else
    Result := not ((not V) shr S);
end;

function Clamp16(V: Integer): Integer; inline;
begin
  if V > 32767 then
    Result := 32767
  else if V < -32768 then
    Result := -32768
  else
    Result := V;
end;

{ TPSPSasCore }

constructor TPSPSasCore.Create(System: TPSPSystem);
begin
  inherited Create(System);
  FScheduler := System.Scheduler;
end;

destructor TPSPSasCore.Destroy;
begin
  for var I := 0 to High(FVoices) do
    FreeAndNil(FVoices[I].Atrac);
  inherited;
end;

procedure TPSPSasCore.ResetVoice(var V: TPSPSasVoice);
begin
  FreeAndNil(V.Atrac);
  V := Default(TPSPSasVoice);
  V.Pitch := $1000;
  V.VolLeft := $1000;
  V.VolRight := $1000;
  V.EffectLeft := $1000;
  V.EffectRight := $1000;
  V.Curve[0] := CurveLinearIncrease;
  V.Curve[1] := CurveLinearDecrease;
  V.Curve[2] := CurveLinearIncrease;
  V.Curve[3] := CurveLinearDecrease;
  V.Loop := -1;
end;

procedure TPSPSasCore.Reset;
begin
  FAddress := 0;
  FInited := False;
  FGrain := 256;
  FMaxVoices := PSPSasVoices;
  FOutputMode := 0;
  for var I := 0 to High(FVoices) do
    ResetVoice(FVoices[I]);
  FRevType := -1;
  FRevDelay := 0;
  FRevFeedback := 0;
  FRevVolLeft := 0;
  FRevVolRight := 0;
  FDry := True;
  FWet := False;
  SetLength(FRevBuffer, $20000);
  FillChar(FRevBuffer[0], Length(FRevBuffer) * 2, 0);
  FRevPos := 0;
  FRevOdd := False;
  FRevOutL := 0;
  FRevOutR := 0;
  FRevInL := 0;
  FRevInR := 0;
end;

function TPSPSasCore.VoiceAddress(V: Integer): Cardinal;
begin
  Result := FAddress + VoiceBase + Cardinal(V) * VoiceStride;
end;

procedure TPSPSasCore.WriteHeader;
begin
  if FAddress = 0 then
    Exit;
  FMemory.Write8(FAddress + 4, Cardinal(FRevType) and $FF);
  FMemory.Write8(FAddress + 6, FRevDelay);
  FMemory.Write8(FAddress + 7, FRevFeedback);
  FMemory.Write8(FAddress + 8, FGrain div 32);
  FMemory.Write8(FAddress + 9, FOutputMode);
  FMemory.Write8(FAddress + 10, Ord(FDry) or (Ord(FWet) shl 1));
  FMemory.Write16(FAddress + 12, FRevVolLeft);
  FMemory.Write16(FAddress + 14, FRevVolRight);
end;

procedure TPSPSasCore.WriteVoice(V: Integer);
begin
  if FAddress = 0 then
    Exit;
  var A := VoiceAddress(V);
  var P: ^TPSPSasVoice := @FVoices[V];
  case P.Kind of
    svVAG:
      begin
        FMemory.Write32(A, P.Address);
        FMemory.Write32(A + 4, Cardinal(P.Size));
      end;
    svPCM:
      begin
        FMemory.Write32(A, P.Address);
        FMemory.Write16(A + 4, Cardinal(P.Size - 1) and $FFFF);
        FMemory.Write16(A + 6, Cardinal(P.Loop) and $FFFF);
      end;
    svNoise:
      begin
        FMemory.Write32(A, Cardinal(P.NoiseFreq));
        FMemory.Write32(A + 4, 0);
      end;
    svTriangle, svSteep:
      begin
        FMemory.Write16(A, Cardinal(P.WaveParam) and $FFFF);
        FMemory.Write16(A + 2, 0);
        FMemory.Write32(A + 4, 0);
      end;
  end;
  var T := Ord(P.Kind);
  if P.Paused then
    T := T or $10;
  FMemory.Write8(A + 8, T);
  FMemory.Write8(A + 9, Ord(P.Loop >= 0));
  FMemory.Write16(A + 10, P.Pitch);
  FMemory.Write16(A + 12, Cardinal(P.VolLeft) and $FFFF);
  FMemory.Write16(A + 14, Cardinal(P.VolRight) and $FFFF);
  FMemory.Write16(A + 16, Cardinal(P.EffectLeft) and $FFFF);
  FMemory.Write16(A + 18, Cardinal(P.EffectRight) and $FFFF);
  for var I := 0 to 3 do
  begin
    FMemory.Write32(A + 24 + Cardinal(I) * 4, Cardinal(P.Rate[I]));
    FMemory.Write8(A + 44 + Cardinal(I), P.Curve[I]);
  end;
  FMemory.Write32(A + 40, Cardinal(P.SustainLevel));
  case P.Phase of
    spOff:
      FMemory.Write8(A + 51, $FF);
    spAttack:
      FMemory.Write8(A + 51, 0);
    spDecay:
      FMemory.Write8(A + 51, 1);
    spSustain:
      FMemory.Write8(A + 51, 2);
    spRelease:
      FMemory.Write8(A + 51, 3);
  end;
  FMemory.Write32(A + 52, Cardinal(P.Height));
end;

function TPSPSasCore.CheckVoice(V: Integer): Boolean;
begin
  Result := (V >= 0) and (V < PSPSasVoices);
  if not Result then
    FHLE.Result(PSP_SAS_ERROR_VOICE_INDEX);
end;

{ Sources }

procedure TPSPSasCore.DecodeVagBlock(var V: TPSPSasVoice);
begin
  var B := V.VagBlock;
  if (V.Size > 0) and (Int64(B + 1) * 16 > V.Size) then
  begin
    V.SourceDone := True;
    Exit;
  end;
  var P := FMemory.Ptr(V.Address + Cardinal(B) * 16, 16);
  if P = nil then
  begin
    V.SourceDone := True;
    Exit;
  end;
  var Flags := P[1];
  // Only 7 stops the voice and only 3 (with looping on) jumps back; a lone
  // end bit plays on (file headers decoded as data carry such bits).
  if (B > 0) and ((Flags and 7) = 7) then
  begin
    V.SourceDone := True;
    Exit;
  end;
  if (Flags and 4) <> 0 then
    V.VagLoopBlock := B;
  V.VagLast := (Flags and 3) = 3;
  V.VagRepeat := V.VagLast;
  var Pred := P[0] shr 4;
  var Shift := P[0] and 15;
  var F0 := VagCoef[Pred, 0];
  var F1 := VagCoef[Pred, 1];
  for var I := 0 to 27 do
  begin
    var Byte_ := P[2 + I shr 1];
    var N: Integer;
    if (I and 1) <> 0 then
      N := Byte_ shr 4
    else
      N := Byte_ and 15;
    if N >= 8 then
      Dec(N, 16);
    var S := Integer(Sar(Int64(N) shl 12, Shift)) + Integer(Sar(Int64(V.VagHist1) * F0 + Int64(V.VagHist2) * F1, 6));
    S := Clamp16(S);
    V.VagHist2 := V.VagHist1;
    V.VagHist1 := S;
    V.VagSamples[I] := S;
  end;
  V.VagIndex := 0;
end;

function TPSPSasCore.FetchVag(var V: TPSPSasVoice; out S: Integer): Boolean;
begin
  S := 0;
  if V.SourceDone then
    Exit(False);
  if V.VagIndex >= 28 then
  begin
    if V.VagLast then
    begin
      if V.VagRepeat and (V.Loop > 0) then
        V.VagBlock := V.VagLoopBlock
      else
      begin
        V.SourceDone := True;
        Exit(False);
      end;
    end
    else
      Inc(V.VagBlock);
    DecodeVagBlock(V);
    if V.SourceDone then
      Exit(False);
  end;
  S := V.VagSamples[V.VagIndex];
  Inc(V.VagIndex);
  Result := True;
end;

function TPSPSasCore.FetchPcm(var V: TPSPSasVoice; out S: Integer): Boolean;
begin
  S := 0;
  if V.SourceDone then
    Exit(False);
  if V.PcmPos >= V.Size then
  begin
    if V.Loop >= 0 then
      V.PcmPos := V.Loop
    else
    begin
      V.SourceDone := True;
      Exit(False);
    end;
  end;
  S := SmallInt(FMemory.Read16(V.Address + Cardinal(V.PcmPos) * 2));
  Inc(V.PcmPos);
  Result := True;
end;

function TPSPSasCore.FetchNoise(var V: TPSPSasVoice): Integer;
begin
  // SPU-style noise: a 16-bit LFSR clocked at a rate set by the 6-bit frequency.
  var Shift := V.NoiseFreq shr 2;
  var Step := 4 - (V.NoiseFreq and 3);
  Dec(V.NoiseTimer, Step);
  var L := V.NoiseLevel;
  var Parity := ((L shr 15) xor (L shr 12) xor (L shr 11) xor (L shr 10) xor 1) and 1;
  if V.NoiseTimer < 0 then
  begin
    L := ((L shl 1) or Parity) and $FFFF;
    Inc(V.NoiseTimer, $20000 shr Shift);
    if V.NoiseTimer < 0 then
      Inc(V.NoiseTimer, $20000 shr Shift);
  end;
  V.NoiseLevel := L;
  Result := SmallInt(L);
end;

function TPSPSasCore.FetchWave(var V: TPSPSasVoice): Integer;
begin
  // A 441-sample cycle per unit of the wave parameter.
  var Period := Max(1, V.WaveParam) * 441;
  var Pos := V.WavePos mod Period;
  Inc(V.WavePos);
  if V.Kind = svTriangle then
  begin
    var Half := Period div 2;
    if Pos < Half then
      Result := -32768 + Integer(Int64(Pos) * 65535 div Max(1, Half))
    else
      Result := 32767 - Integer(Int64(Pos - Half) * 65535 div Max(1, Period - Half));
  end
  else
  begin
    if Pos < Period div 2 then
      Result := 32767
    else
      Result := -32768;
  end;
  Result := Clamp16(Result);
end;

function TPSPSasCore.Fetch(var V: TPSPSasVoice; out S: Integer): Boolean;
begin
  case V.Kind of
    svVAG:
      Result := FetchVag(V, S);
    svPCM:
      Result := FetchPcm(V, S);
    svNoise:
      begin
        S := FetchNoise(V);
        Result := True;
      end;
    svTriangle, svSteep:
      begin
        S := FetchWave(V);
        Result := True;
      end;
    svATRAC3:
      begin
        var X: SmallInt := 0;
        Result := (V.Atrac <> nil) and V.Atrac.Read(@X, 1);
        S := X;
        if not Result then
          V.SourceDone := True;
      end;
  else
    S := 0;
    Result := False;
  end;
end;

procedure TPSPSasCore.StartSource(var V: TPSPSasVoice);
begin
  V.SourceDone := False;
  V.Frac := 0;
  V.PcmPos := 0;
  V.VagBlock := 0;
  V.VagIndex := 28;
  V.VagHist1 := 0;
  V.VagHist2 := 0;
  V.VagLoopBlock := 0;
  V.VagLast := False;
  V.VagRepeat := False;
  V.NoiseLevel := 1;
  V.NoiseTimer := 0;
  V.WavePos := 0;
  if (V.Kind = svATRAC3) and (V.Atrac <> nil) then
    V.Atrac.Restart;
  var S: Integer;
  if V.Kind = svVAG then
  begin
    // The ADPCM decoder runs one sample behind the PCM path.
    DecodeVagBlock(V);
    V.Cur := 0;
    V.NextValid := FetchVag(V, S);
    V.Next := S;
  end
  else
  begin
    if not Fetch(V, S) then
      S := 0;
    V.Cur := S;
    V.NextValid := Fetch(V, S);
    V.Next := S;
  end;
end;

procedure TPSPSasCore.Advance(var V: TPSPSasVoice);
begin
  Inc(V.Frac, V.Pitch);
  while V.Frac >= $1000 do
  begin
    Dec(V.Frac, $1000);
    if not V.NextValid then
    begin
      // The data ran out: the voice ends and can be keyed on again.
      V.Cur := 0;
      V.Next := 0;
      V.Frac := 0;
      V.Playing := False;
      V.On := False;
      Exit;
    end;
    V.Cur := V.Next;
    var S: Integer;
    V.NextValid := Fetch(V, S);
    if V.NextValid then
      V.Next := S
    else
      V.Next := 0;
  end;
end;

{ Envelope }

procedure TPSPSasCore.StepEnvelope(var V: TPSPSasVoice);

  function Apply(Curve, Rate, H: Integer): Int64;
  begin
    case Curve of
      CurveLinearIncrease:
        Result := Int64(H) + Rate;
      CurveLinearDecrease:
        Result := Int64(H) - Rate;
      CurveLinearBent:
        if H <= $30000000 then
          Result := Int64(H) + Rate
        else
          Result := Int64(H) + Rate div 4;
      CurveExponentDecrease:
        Result := Int64(H) - Int64((UInt64(H) * UInt64(Cardinal(Rate)) + $FFFFFFFF) shr 32);
      CurveExponentIncrease:
        Result := Int64(H) + $4000 + Int64((UInt64(Cardinal(Rate)) * UInt64(PSPSasEnvelopeMax - H)) shr 32);
      CurveDirect:
        Result := Rate;
    else
      Result := H;
    end;
  end;

begin
  case V.Phase of
    spAttack:
      begin
        var H := Apply(V.Curve[0], V.Rate[0], V.Height);
        if H >= PSPSasEnvelopeMax then
        begin
          H := PSPSasEnvelopeMax;
          V.Phase := spDecay;
        end;
        V.Height := H;
      end;
    spDecay:
      begin
        var H := Apply(V.Curve[1], V.Rate[1], V.Height);
        if H <= V.SustainLevel then
        begin
          H := Max(Int64(V.SustainLevel), 0);
          V.Phase := spSustain;
        end;
        V.Height := H;
      end;
    spSustain:
      V.Height := EnsureRange(Apply(V.Curve[2], V.Rate[2], V.Height), 0, PSPSasEnvelopeMax);
    spRelease:
      begin
        var H := Apply(V.Curve[3], V.Rate[3], V.Height);
        if H <= 0 then
        begin
          H := 0;
          V.Phase := spOff;
          V.Playing := False;
          V.On := False;
        end;
        V.Height := Min(H, Int64(PSPSasEnvelopeMax));
      end;
  end;
end;

{ Mixing }

procedure TPSPSasCore.RenderVoice(var V: TPSPSasVoice; Count: Integer);
begin
  for var I := 0 to Count - 1 do
  begin
    if not V.Playing then
      Break;
    if V.Delay > 0 then
    begin
      Dec(V.Delay);
      Continue;
    end;
    var S := V.Cur;
    if V.Frac <> 0 then
      S := S + Integer(Sar(Int64(V.Next - V.Cur) * V.Frac, 12));
    var E := Integer(Sar(Int64(S) * V.Height, 30));
    Inc(FDryL[I], Integer(Sar(Int64(E) * V.VolLeft, 12)));
    Inc(FDryR[I], Integer(Sar(Int64(E) * V.VolRight, 12)));
    Inc(FWetL[I], Integer(Sar(Int64(E) * V.EffectLeft, 12)));
    Inc(FWetR[I], Integer(Sar(Int64(E) * V.EffectRight, 12)));
    StepEnvelope(V);
    if V.Playing then
      Advance(V);
  end;
end;

procedure TPSPSasCore.MixGrain(Output: Cardinal; WithMix: Boolean; MixLeft, MixRight: Integer);
begin
  var N := FGrain;
  if Length(FDryL) < N then
  begin
    SetLength(FDryL, N);
    SetLength(FDryR, N);
    SetLength(FWetL, N);
    SetLength(FWetR, N);
  end;
  for var I := 0 to N - 1 do
  begin
    FDryL[I] := 0;
    FDryR[I] := 0;
    FWetL[I] := 0;
    FWetR[I] := 0;
  end;
  for var V := 0 to FMaxVoices - 1 do
    if FVoices[V].Playing and not FVoices[V].Paused then
      RenderVoice(FVoices[V], N);
  for var V := 0 to FMaxVoices - 1 do
    WriteVoice(V);
  if FOutputMode = 1 then
  begin
    // Four planes of one grain each: dry left, dry right, effect left, effect right.
    var P := PSmallInt(FMemory.Ptr(Output, N * 8));
    if P = nil then
      Exit;
    for var I := 0 to N - 1 do
    begin
      PSmallInt(PByte(P) + I * 2)^ := Clamp16(FDryL[I]);
      PSmallInt(PByte(P) + (N + I) * 2)^ := Clamp16(FDryR[I]);
      PSmallInt(PByte(P) + (N * 2 + I) * 2)^ := Clamp16(FWetL[I]);
      PSmallInt(PByte(P) + (N * 3 + I) * 2)^ := Clamp16(FWetR[I]);
    end;
    Exit;
  end;
  Reverb(N);
  var P := PSmallInt(FMemory.Ptr(Output, N * 4));
  if P = nil then
    Exit;
  for var I := 0 to N - 1 do
  begin
    var L := 0;
    var R := 0;
    if FDry then
    begin
      L := FDryL[I];
      R := FDryR[I];
    end;
    if FWet then
    begin
      Inc(L, FWetL[I]);
      Inc(R, FWetR[I]);
    end;
    var Q := PSmallInt(PByte(P) + I * 4);
    if WithMix then
    begin
      Inc(L, Integer(Sar(Int64(Q^) * MixLeft, 12)));
      var Q2 := PSmallInt(PByte(Q) + 2);
      Inc(R, Integer(Sar(Int64(Q2^) * MixRight, 12)));
    end;
    Q^ := Clamp16(L);
    PSmallInt(PByte(Q) + 2)^ := Clamp16(R);
  end;
end;

{ Reverb }

type
  TRevPreset = record
    Size: Integer;
    R: array[0..31] of Word;
  end;

const
  // SPU reverb register sets: dAPF1, dAPF2, vIIR, vCOMB1..4, vWALL, vAPF1, vAPF2,
  // mLSAME, mRSAME, mLCOMB1, mRCOMB1, mLCOMB2, mRCOMB2, dLSAME, dRSAME, mLDIFF, mRDIFF,
  // mLCOMB3, mRCOMB3, mLCOMB4, mRCOMB4, dLDIFF, dRDIFF, mLAPF1, mRAPF1, mLAPF2, mRAPF2,
  // vLIN, vRIN. Addresses are in 8-byte units.
  RevPresets: array[0..8] of TRevPreset = (
    (Size: $26C0; R: ($007D, $005B, $6D80, $54B8, $BED0, $0000, $0000, $BA80, $5800, $5300, $04D6, $0333,
      $03F0, $0227, $0374, $01EF, $0334, $01B5, $0000, $0000, $0000, $0000, $0000, $0000, $0000, $0000,
      $01B4, $0136, $00B8, $005C, $8000, $8000)),
    (Size: $1F40; R: ($0033, $0025, $70F0, $4FA8, $BCE0, $4410, $C0F0, $9C00, $5280, $4EC0, $03E4, $031B,
      $03A4, $02AF, $0372, $0266, $031C, $025D, $025C, $018E, $022F, $0135, $01D2, $00B7, $018F, $00B5,
      $00B4, $0080, $004C, $0026, $8000, $8000)),
    (Size: $4840; R: ($00B1, $007F, $70F0, $4FA8, $BCE0, $4510, $BEF0, $B4C0, $5280, $4EC0, $0904, $076B,
      $0824, $065F, $07A2, $0616, $076C, $05ED, $05EC, $042E, $050F, $0305, $0462, $02B7, $042F, $0265,
      $0264, $01B2, $0100, $0080, $8000, $8000)),
    (Size: $6FE0; R: ($00E3, $00A9, $6F60, $4FA8, $BCE0, $4510, $BEF0, $A680, $5680, $52C0, $0DFB, $0B58,
      $0D09, $0A3C, $0BD9, $0973, $0B59, $08DA, $08D9, $05E9, $07EC, $04B0, $06EF, $03D2, $05EA, $031D,
      $031C, $0238, $0154, $00AA, $8000, $8000)),
    (Size: $ADE0; R: ($01A5, $0139, $6000, $5000, $4C00, $B800, $BC00, $C000, $6000, $5C00, $15BA, $11BB,
      $14C2, $10BD, $11BC, $0DC1, $11C0, $0DC3, $0DC0, $09C1, $0BC4, $07C1, $0A00, $06CD, $09C2, $05C1,
      $05C0, $041A, $0274, $013A, $8000, $8000)),
    (Size: $F6C0; R: ($033D, $0231, $7E00, $5000, $B400, $B000, $4C00, $B000, $6000, $5400, $1ED6, $1A31,
      $1D14, $183B, $1BC2, $16B2, $1A32, $15EF, $15EE, $1055, $1334, $0F2D, $11F6, $0C5D, $1056, $0AE1,
      $0AE0, $07A2, $0464, $0232, $8000, $8000)),
    (Size: $18040; R: ($0001, $0001, $7FFF, $7FFF, $0000, $0000, $0000, $8100, $0000, $0000, $1FFF, $0FFF,
      $1005, $0005, $0000, $0000, $1005, $0005, $0000, $0000, $0000, $0000, $0000, $0000, $0000, $0000,
      $1004, $1002, $0004, $0002, $8000, $8000)),
    (Size: $18040; R: ($0001, $0001, $7FFF, $7FFF, $0000, $0000, $0000, $0000, $0000, $0000, $1FFF, $0FFF,
      $1005, $0005, $0000, $0000, $1005, $0005, $0000, $0000, $0000, $0000, $0000, $0000, $0000, $0000,
      $1004, $1002, $0004, $0002, $8000, $8000)),
    (Size: $3C00; R: ($0017, $0013, $70F0, $4FA8, $BCE0, $4510, $BEF0, $8500, $5F80, $54C0, $0371, $02AF,
      $02E5, $01DF, $02B0, $01D7, $0358, $026A, $01D6, $011E, $012D, $00B1, $011F, $0059, $01A0, $00E3,
      $0058, $0040, $0028, $0014, $8000, $8000)));

procedure TPSPSasCore.ReverbSample(InL, InR: Integer; out OutL, OutR: Integer);
var
  Base, Size: Integer;
  R: ^TRevPreset;

  function Adr(Off: Integer): Integer;
  begin
    Result := Base + ((FRevPos + Off) mod Size + Size) mod Size;
  end;

  function Rd(Off: Integer): Integer;
  begin
    Result := FRevBuffer[Adr(Off)];
  end;

  procedure Wr(Off, Value: Integer);
  begin
    FRevBuffer[Adr(Off)] := Clamp16(Value);
  end;

  function M(Index: Integer): Integer;
  begin
    Result := Integer(R.R[Index]) * 4;
  end;

  function Vol(Index: Integer): Integer;
  begin
    Result := SmallInt(R.R[Index]);
  end;

  function Mul(A, B: Integer): Integer;
  begin
    Result := Integer(Sar(Int64(A) * B, 15));
  end;

begin
  var Regs := RevPresets[FRevType];
  if FRevType in [6, 7] then
  begin
    // ECHO and DELAY: the delay parameter sets the echo distance (the presets
    // are its longest), the feedback parameter ECHO's wall reflection.
    var D := $600 + FRevDelay * $A00 div 127;
    Regs.R[10] := 2 * D - 1;
    Regs.R[11] := D - 1;
    Regs.R[12] := D + 5;
    Regs.R[13] := 5;
    Regs.R[16] := D + 5;
    Regs.R[17] := 5;
    Regs.R[26] := D + 4;
    Regs.R[27] := D + 2;
    if FRevType = 6 then
      Regs.R[7] := Word(-(FRevFeedback shl 8))
    else
      Regs.R[7] := 0;
  end;
  R := @Regs;
  Size := R.Size * 4 div 8;
  if Size > Length(FRevBuffer) then
    Size := Length(FRevBuffer);
  Base := 0;
  var dAPF1 := M(0);
  var dAPF2 := M(1);
  var vIIR := Vol(2);
  var vCOMB1 := Vol(3);
  var vCOMB2 := Vol(4);
  var vCOMB3 := Vol(5);
  var vCOMB4 := Vol(6);
  var vWALL := Vol(7);
  var vAPF1 := Vol(8);
  var vAPF2 := Vol(9);
  var mLSAME := M(10);
  var mRSAME := M(11);
  var mLCOMB1 := M(12);
  var mRCOMB1 := M(13);
  var mLCOMB2 := M(14);
  var mRCOMB2 := M(15);
  var dLSAME := M(16);
  var dRSAME := M(17);
  var mLDIFF := M(18);
  var mRDIFF := M(19);
  var mLCOMB3 := M(20);
  var mRCOMB3 := M(21);
  var mLCOMB4 := M(22);
  var mRCOMB4 := M(23);
  var dLDIFF := M(24);
  var dRDIFF := M(25);
  var mLAPF1 := M(26);
  var mRAPF1 := M(27);
  var mLAPF2 := M(28);
  var mRAPF2 := M(29);
  // The input gains of 8000h pass the send unchanged.
  var vLIN := Integer(R.R[30]);
  var vRIN := Integer(R.R[31]);
  var LIn := Mul(InL, vLIN);
  var RIn := Mul(InR, vRIN);
  // Same-side reflection.
  Wr(mLSAME, Mul(LIn + Mul(Rd(dLSAME), vWALL) - Rd(mLSAME - 1), vIIR) + Rd(mLSAME - 1));
  Wr(mRSAME, Mul(RIn + Mul(Rd(dRSAME), vWALL) - Rd(mRSAME - 1), vIIR) + Rd(mRSAME - 1));
  // Different-side reflection.
  Wr(mLDIFF, Mul(LIn + Mul(Rd(dRDIFF), vWALL) - Rd(mLDIFF - 1), vIIR) + Rd(mLDIFF - 1));
  Wr(mRDIFF, Mul(RIn + Mul(Rd(dLDIFF), vWALL) - Rd(mRDIFF - 1), vIIR) + Rd(mRDIFF - 1));
  // Early echo.
  var LOut := Mul(vCOMB1, Rd(mLCOMB1)) + Mul(vCOMB2, Rd(mLCOMB2)) + Mul(vCOMB3, Rd(mLCOMB3)) + Mul(vCOMB4, Rd(mLCOMB4));
  var ROut := Mul(vCOMB1, Rd(mRCOMB1)) + Mul(vCOMB2, Rd(mRCOMB2)) + Mul(vCOMB3, Rd(mRCOMB3)) + Mul(vCOMB4, Rd(mRCOMB4));
  // Late reverb all-pass filters.
  LOut := LOut - Mul(vAPF1, Rd(mLAPF1 - dAPF1));
  Wr(mLAPF1, LOut);
  LOut := Mul(LOut, vAPF1) + Rd(mLAPF1 - dAPF1);
  ROut := ROut - Mul(vAPF1, Rd(mRAPF1 - dAPF1));
  Wr(mRAPF1, ROut);
  ROut := Mul(ROut, vAPF1) + Rd(mRAPF1 - dAPF1);
  LOut := LOut - Mul(vAPF2, Rd(mLAPF2 - dAPF2));
  Wr(mLAPF2, LOut);
  LOut := Mul(LOut, vAPF2) + Rd(mLAPF2 - dAPF2);
  ROut := ROut - Mul(vAPF2, Rd(mRAPF2 - dAPF2));
  Wr(mRAPF2, ROut);
  ROut := Mul(ROut, vAPF2) + Rd(mRAPF2 - dAPF2);
  OutL := Clamp16(LOut);
  OutR := Clamp16(ROut);
  FRevPos := (FRevPos + 1) mod Size;
end;

procedure TPSPSasCore.Reverb(Count: Integer);
begin
  for var I := 0 to Count - 1 do
  begin
    var L := Clamp16(FWetL[I]);
    var R := Clamp16(FWetR[I]);
    if FRevType >= 0 then
    begin
      // The reverb runs at half rate on the average of each sample pair.
      if not FRevOdd then
      begin
        FRevInL := L;
        FRevInR := R;
      end
      else
        ReverbSample((FRevInL + L) div 2, (FRevInR + R) div 2, FRevOutL, FRevOutR);
      FRevOdd := not FRevOdd;
      L := FRevOutL;
      R := FRevOutR;
    end;
    FWetL[I] := Integer(Sar(Int64(L) * FRevVolLeft, 12));
    FWetR[I] := Integer(Sar(Int64(R) * FRevVolRight, 12));
  end;
end;

{ HLE }

procedure TPSPSasCore.CoreWait;
begin
  // The ME takes a while; the caller waits for it.
  if not FKernel.CanWait then
    Exit;
  var T := FKernel.Current;
  FKernel.BeginWait(PSPWaitDelay, nil, 0, 0, False, nil, nil, 'sascore');
  FKernel.AddWakeTimer(FScheduler.Now + 200000, T, 'sascore', 0);
end;

procedure TPSPSasCore.hInit;
begin
  var A := FHLE.Arg(0);
  var Grain := FHLE.ArgInt(1);
  var MaxVoices := FHLE.ArgInt(2);
  var Mode := FHLE.ArgInt(3);
  var Rate := FHLE.ArgInt(4);
  if (A = 0) or ((A and 63) <> 0) then
  begin
    FHLE.Result(PSP_SAS_ERROR_ADDRESS);
    Exit;
  end;
  if (Grain < $40) or (Grain > $800) or ((Grain and 31) <> 0) then
  begin
    FHLE.Result(PSP_SAS_ERROR_GRAIN);
    Exit;
  end;
  if (MaxVoices < 1) or (MaxVoices > PSPSasVoices) then
  begin
    FHLE.Result(PSP_SAS_ERROR_MAXVOICES);
    Exit;
  end;
  if (Mode <> 0) and (Mode <> 1) then
  begin
    FHLE.Result(PSP_SAS_ERROR_OUTPUTMODE);
    Exit;
  end;
  if Rate <> 44100 then
  begin
    FHLE.Result(PSP_SAS_ERROR_SAMPLERATE);
    Exit;
  end;
  FAddress := A;
  FInited := True;
  FGrain := Grain;
  FMaxVoices := MaxVoices;
  FOutputMode := Mode;
  for var I := 0 to High(FVoices) do
    ResetVoice(FVoices[I]);
  FRevType := -1;
  FRevDelay := 0;
  FRevFeedback := 0;
  FRevVolLeft := 0;
  FRevVolRight := 0;
  FDry := True;
  FWet := False;
  FillChar(FRevBuffer[0], Length(FRevBuffer) * 2, 0);
  FRevPos := 0;
  FMemory.Write32(A, $00180990);
  FMemory.Write8(A + 5, $0B);
  FMemory.Write32(A + 16, $FFFFFFFF);
  WriteHeader;
  for var I := 0 to PSPSasVoices - 1 do
    WriteVoice(I);
  FHLE.Result(0);
end;

procedure TPSPSasCore.hCore;
begin
  if FKernel.RefuseWait then
    Exit;
  FHLE.Result(0);
  MixGrain(FHLE.Arg(1), False, 0, 0);
  CoreWait;
end;

procedure TPSPSasCore.hCoreWithMix;
begin
  if FKernel.RefuseWait then
    Exit;
  if FOutputMode = 1 then
  begin
    FHLE.Result(PSP_SAS_ERROR_NOT_SUPPORTED);
    Exit;
  end;
  FHLE.Result(0);
  MixGrain(FHLE.Arg(1), True, FHLE.ArgInt(2), FHLE.ArgInt(3));
  CoreWait;
end;

procedure TPSPSasCore.hGetEndFlag;
begin
  var F: Cardinal := 0;
  for var I := 0 to PSPSasVoices - 1 do
    if not FVoices[I].Playing then
      F := F or (Cardinal(1) shl I);
  FHLE.Result(F);
end;

procedure TPSPSasCore.hSetVolume;
begin
  var V := FHLE.ArgInt(1);
  if not CheckVoice(V) then
    Exit;
  var L := FHLE.ArgInt(2);
  var R := FHLE.ArgInt(3);
  var EL := FHLE.ArgInt(4);
  var ER := FHLE.ArgInt(5);
  if (Abs(L) > $1000) or (Abs(R) > $1000) or (Abs(EL) > $1000) or (Abs(ER) > $1000) then
  begin
    FHLE.Result(PSP_SAS_ERROR_VOLUME_VAL);
    Exit;
  end;
  FVoices[V].VolLeft := L;
  FVoices[V].VolRight := R;
  FVoices[V].EffectLeft := EL;
  FVoices[V].EffectRight := ER;
  WriteVoice(V);
  FHLE.Result(0);
end;

procedure TPSPSasCore.hSetPitch;
begin
  var V := FHLE.ArgInt(1);
  if not CheckVoice(V) then
    Exit;
  var P := FHLE.ArgInt(2);
  if (P < 0) or (P > $4000) then
  begin
    FHLE.Result(PSP_SAS_ERROR_PITCH_VAL);
    Exit;
  end;
  FVoices[V].Pitch := P;
  WriteVoice(V);
  FHLE.Result(0);
end;

procedure TPSPSasCore.hSetVoice;
begin
  var V := FHLE.ArgInt(1);
  if not CheckVoice(V) then
    Exit;
  var A := FHLE.Arg(2);
  var Size := FHLE.ArgInt(3);
  var Loop := FHLE.ArgInt(4);
  if (Size = 0) or ((Size and 15) <> 0) then
  begin
    FHLE.Result(PSP_SAS_ERROR_ADPCM_SIZE);
    Exit;
  end;
  if (Loop <> 0) and (Loop <> 1) then
  begin
    FHLE.Result(PSP_SAS_ERROR_LOOP_MODE);
    Exit;
  end;
  var P: ^TPSPSasVoice := @FVoices[V];
  if P.Kind = svATRAC3 then
    FreeAndNil(P.Atrac);
  P.Kind := svVAG;
  P.Address := A;
  // Negative sizes act as unbounded.
  if Size < 0 then
    P.Size := 0
  else
    P.Size := Size;
  P.Loop := Loop;
  WriteVoice(V);
  if Size < 0 then
    FMemory.Write32(VoiceAddress(V) + 4, Cardinal(Size));
  FHLE.Result(0);
end;

procedure TPSPSasCore.hSetVoicePCM;
begin
  var V := FHLE.ArgInt(1);
  if not CheckVoice(V) then
    Exit;
  var A := FHLE.Arg(2);
  var Size := FHLE.ArgInt(3);
  var Loop := FHLE.ArgInt(4);
  if (Size <= 0) or (Size > $10000) then
  begin
    FHLE.Result(PSP_SAS_ERROR_PCM_SIZE);
    Exit;
  end;
  if Loop >= Size then
  begin
    FHLE.Result(PSP_SAS_ERROR_LOOP_MODE);
    Exit;
  end;
  var P: ^TPSPSasVoice := @FVoices[V];
  if P.Kind = svATRAC3 then
    FreeAndNil(P.Atrac);
  P.Kind := svPCM;
  P.Address := A;
  P.Size := Size;
  if Loop < 0 then
    P.Loop := -1
  else
    P.Loop := Loop;
  WriteVoice(V);
  FHLE.Result(0);
end;

procedure TPSPSasCore.hSetNoise;
begin
  var V := FHLE.ArgInt(1);
  if not CheckVoice(V) then
    Exit;
  var F := FHLE.ArgInt(2);
  if (F < 0) or (F > 63) then
  begin
    FHLE.Result(PSP_SAS_ERROR_NOISE_CLOCK);
    Exit;
  end;
  var P: ^TPSPSasVoice := @FVoices[V];
  if P.Kind = svATRAC3 then
    FreeAndNil(P.Atrac);
  P.Kind := svNoise;
  P.NoiseFreq := F;
  WriteVoice(V);
  FHLE.Result(0);
end;

procedure TPSPSasCore.hSetTriangularWave;
begin
  var V := FHLE.ArgInt(1);
  if not CheckVoice(V) then
    Exit;
  var P: ^TPSPSasVoice := @FVoices[V];
  if P.Kind = svATRAC3 then
    FreeAndNil(P.Atrac);
  P.Kind := svTriangle;
  P.WaveParam := FHLE.ArgInt(2);
  WriteVoice(V);
  FHLE.Result(0);
end;

procedure TPSPSasCore.hSetSteepWave;
begin
  var V := FHLE.ArgInt(1);
  if not CheckVoice(V) then
    Exit;
  var P: ^TPSPSasVoice := @FVoices[V];
  if P.Kind = svATRAC3 then
    FreeAndNil(P.Atrac);
  P.Kind := svSteep;
  P.WaveParam := FHLE.ArgInt(2);
  WriteVoice(V);
  FHLE.Result(0);
end;

procedure TPSPSasCore.hSetADSR;
begin
  var V := FHLE.ArgInt(1);
  if not CheckVoice(V) then
    Exit;
  var Flags := FHLE.Arg(2);
  var Rates: array[0..3] of Integer;
  for var I := 0 to 3 do
  begin
    Rates[I] := FHLE.ArgInt(3 + I);
    if ((Flags and (Cardinal(1) shl I)) <> 0) and (Rates[I] < 0) then
    begin
      FHLE.Result(PSP_SAS_ERROR_ADSR_VAL);
      Exit;
    end;
  end;
  for var I := 0 to 3 do
    if (Flags and (Cardinal(1) shl I)) <> 0 then
      FVoices[V].Rate[I] := Rates[I];
  WriteVoice(V);
  FHLE.Result(0);
end;

procedure TPSPSasCore.hSetADSRmode;
const
  // Curves each phase accepts: attack rises, decay and release fall.
  Allowed: array[0..3] of set of 0..5 = ([0, 2, 4], [1, 3, 5], [0..5], [1, 3, 5]);
begin
  var V := FHLE.ArgInt(1);
  if not CheckVoice(V) then
    Exit;
  var Flags := FHLE.Arg(2);
  var Modes: array[0..3] of Cardinal;
  for var I := 0 to 3 do
  begin
    Modes[I] := FHLE.Arg(3 + I) and $7FFFFFFF;
    if (Flags and (Cardinal(1) shl I)) <> 0 then
      if (Modes[I] > 5) or not (Integer(Modes[I]) in Allowed[I]) then
      begin
        FHLE.Result(PSP_SAS_ERROR_ADSR_MODE);
        Exit;
      end;
  end;
  for var I := 0 to 3 do
    if (Flags and (Cardinal(1) shl I)) <> 0 then
      FVoices[V].Curve[I] := Modes[I];
  WriteVoice(V);
  FHLE.Result(0);
end;

procedure TPSPSasCore.hSetSL;
begin
  var V := FHLE.ArgInt(1);
  if not CheckVoice(V) then
    Exit;
  FVoices[V].SustainLevel := FHLE.ArgInt(2);
  WriteVoice(V);
  FHLE.Result(0);
end;

function SimpleRate(R: Integer): Integer;
begin
  // SPU 7-bit envelope rate as a per-sample step.
  if R >= $7F then
    Exit(0);
  var Shift := 26 - (R shr 2);
  var Base := 7 - (R and 3);
  if Shift >= 0 then
    Result := Base shl Shift
  else
    Result := Base shr (-Shift);
  if Result < 1 then
    Result := 1;
end;

function SimpleExpRate(R: Integer): Integer;
begin
  if R >= $7F then
    Exit(0);
  var Shift := 24 - (R shr 2);
  var Base := 7 - (R and 3);
  if Shift >= 0 then
    Result := Base shl Shift
  else
    Result := Base shr (-Shift);
  if Result < 1 then
    Result := 1;
end;

function SimpleDecay(R: Integer): Integer;
begin
  if R = 0 then
    Result := $7FFFFFFF
  else
    Result := Integer(Cardinal($80000000) shr R);
end;

procedure TPSPSasCore.hSetSimpleADSR;
begin
  var V := FHLE.ArgInt(1);
  if not CheckVoice(V) then
    Exit;
  var A1 := FHLE.Arg(2) and $FFFF;
  var A2 := FHLE.Arg(3) and $FFFF;
  if (A2 and $2000) <> 0 then
  begin
    FHLE.Result(PSP_SAS_ERROR_ADSR_MODE);
    Exit;
  end;
  var P: ^TPSPSasVoice := @FVoices[V];
  if (A1 and $8000) <> 0 then
    P.Curve[0] := CurveLinearBent
  else
    P.Curve[0] := CurveLinearIncrease;
  P.Rate[0] := SimpleRate((A1 shr 8) and $7F);
  P.Curve[1] := CurveExponentDecrease;
  P.Rate[1] := SimpleDecay((A1 shr 4) and $F);
  P.SustainLevel := Integer(((A1 and $F) + 1) * $4000000);
  var ST := (A2 shr 14) and 3;
  P.Curve[2] := ST;
  if ST = CurveExponentDecrease then
    P.Rate[2] := SimpleExpRate((A2 shr 6) and $7F)
  else
    P.Rate[2] := SimpleRate((A2 shr 6) and $7F);
  var RR := A2 and $1F;
  if (A2 and $20) <> 0 then
  begin
    P.Curve[3] := CurveExponentDecrease;
    if RR = 0 then
      P.Rate[3] := $7FFFFFFF
    else if RR = $1F then
      P.Rate[3] := 0
    else
      P.Rate[3] := Integer(Cardinal($80000000) shr RR);
  end
  else
  begin
    P.Curve[3] := CurveLinearDecrease;
    if RR = $1F then
      P.Rate[3] := 0
    else if RR = $1E then
      P.Rate[3] := $40000000
    else
      P.Rate[3] := Max(1, $10000000 shr RR);
  end;
  WriteVoice(V);
  FHLE.Result(0);
end;

procedure TPSPSasCore.hGetEnvelopeHeight;
begin
  var V := FHLE.ArgInt(1);
  if not CheckVoice(V) then
    Exit;
  FHLE.Result(Cardinal(FVoices[V].Height));
end;

procedure TPSPSasCore.hGetAllEnvelopeHeights;
begin
  var A := FHLE.Arg(1);
  for var I := 0 to PSPSasVoices - 1 do
    FMemory.Write32(A + Cardinal(I) * 4, Cardinal(FVoices[I].Height));
  FHLE.Result(0);
end;

procedure TPSPSasCore.hSetKeyOn;
begin
  var V := FHLE.ArgInt(1);
  if not CheckVoice(V) then
    Exit;
  var P: ^TPSPSasVoice := @FVoices[V];
  if P.Paused or P.On then
  begin
    FHLE.Result(PSP_SAS_ERROR_INVALID_STATE);
    Exit;
  end;
  P.On := True;
  P.Playing := True;
  P.Phase := spAttack;
  P.Height := 0;
  P.Delay := KeyOnDelay;
  StartSource(P^);
  WriteVoice(V);
  FHLE.Result(0);
end;

procedure TPSPSasCore.hSetKeyOff;
begin
  var V := FHLE.ArgInt(1);
  if not CheckVoice(V) then
    Exit;
  var P: ^TPSPSasVoice := @FVoices[V];
  if P.Paused or not P.On then
  begin
    FHLE.Result(PSP_SAS_ERROR_INVALID_STATE);
    Exit;
  end;
  P.On := False;
  if P.Phase <> spOff then
    P.Phase := spRelease;
  WriteVoice(V);
  FHLE.Result(0);
end;

procedure TPSPSasCore.hSetPause;
begin
  var Bits := FHLE.Arg(1);
  var Pause := FHLE.Arg(2) <> 0;
  for var I := 0 to PSPSasVoices - 1 do
    if (Bits and (Cardinal(1) shl I)) <> 0 then
    begin
      FVoices[I].Paused := Pause;
      WriteVoice(I);
    end;
  FHLE.Result(0);
end;

procedure TPSPSasCore.hGetPauseFlag;
begin
  var F: Cardinal := 0;
  for var I := 0 to PSPSasVoices - 1 do
    if FVoices[I].Paused then
      F := F or (Cardinal(1) shl I);
  FHLE.Result(F);
end;

procedure TPSPSasCore.hRevVON;
begin
  FDry := FHLE.Arg(1) <> 0;
  FWet := FHLE.Arg(2) <> 0;
  WriteHeader;
  FHLE.Result(0);
end;

procedure TPSPSasCore.hRevEVOL;
begin
  var L := FHLE.Arg(1);
  var R := FHLE.Arg(2);
  if (L > $1000) or (R > $1000) then
  begin
    FHLE.Result(PSP_SAS_ERROR_FX_VOLUME_VAL);
    Exit;
  end;
  FRevVolLeft := L;
  FRevVolRight := R;
  WriteHeader;
  FHLE.Result(0);
end;

procedure TPSPSasCore.hRevType;
begin
  var T := FHLE.ArgInt(1);
  if (T < -1) or (T > 8) then
  begin
    FHLE.Result(PSP_SAS_ERROR_FX_TYPE);
    Exit;
  end;
  if T <> FRevType then
  begin
    FillChar(FRevBuffer[0], Length(FRevBuffer) * 2, 0);
    FRevPos := 0;
  end;
  FRevType := T;
  WriteHeader;
  FHLE.Result(0);
end;

procedure TPSPSasCore.hRevParam;
begin
  var D := FHLE.Arg(1);
  var F := FHLE.Arg(2);
  if D > 127 then
  begin
    FHLE.Result(PSP_SAS_ERROR_FX_DELAY);
    Exit;
  end;
  if F > 127 then
  begin
    FHLE.Result(PSP_SAS_ERROR_FX_FEEDBACK);
    Exit;
  end;
  FRevDelay := D;
  FRevFeedback := F;
  WriteHeader;
  FHLE.Result(0);
end;

procedure TPSPSasCore.hGetGrain;
begin
  FHLE.Result(Cardinal(FGrain));
end;

procedure TPSPSasCore.hSetGrain;
begin
  var G := FHLE.ArgInt(1);
  if (G < $40) or (G > $800) or ((G and 31) <> 0) then
  begin
    FHLE.Result(PSP_SAS_ERROR_GRAIN);
    Exit;
  end;
  FGrain := G;
  WriteHeader;
  FHLE.Result(0);
end;

procedure TPSPSasCore.hGetOutputmode;
begin
  FHLE.Result(Cardinal(FOutputMode));
end;

procedure TPSPSasCore.hSetOutputmode;
begin
  var M := FHLE.ArgInt(1);
  if (M <> 0) and (M <> 1) then
  begin
    FHLE.Result(PSP_SAS_ERROR_OUTPUTMODE);
    Exit;
  end;
  FOutputMode := M;
  WriteHeader;
  FHLE.Result(0);
end;

procedure TPSPSasCore.hSetVoiceATRAC3;
begin
  var V := FHLE.ArgInt(1);
  if not CheckVoice(V) then
    Exit;
  var P: ^TPSPSasVoice := @FVoices[V];
  FreeAndNil(P.Atrac);
  var S: TPSPSasAtracSource := nil;
  var R: Cardinal := 0;
  if Assigned(PSPSasAtracFactory) then
    R := PSPSasAtracFactory(FHLE.Arg(2), S);
  if Integer(R) < 0 then
  begin
    FHLE.Result(R);
    Exit;
  end;
  P.Kind := svATRAC3;
  P.Atrac := S;
  P.Address := FHLE.Arg(2);
  WriteVoice(V);
  FHLE.Result(0);
end;

procedure TPSPSasCore.hConcatenateATRAC3;
begin
  var V := FHLE.ArgInt(1);
  if not CheckVoice(V) then
    Exit;
  var P: ^TPSPSasVoice := @FVoices[V];
  if P.Atrac <> nil then
    P.Atrac.Concatenate(FHLE.Arg(2), FHLE.ArgInt(3));
  FHLE.Result(0);
end;

procedure TPSPSasCore.hUnsetATRAC3;
begin
  var V := FHLE.ArgInt(1);
  if not CheckVoice(V) then
    Exit;
  var P: ^TPSPSasVoice := @FVoices[V];
  FreeAndNil(P.Atrac);
  if P.Kind = svATRAC3 then
    P.Kind := svNone;
  WriteVoice(V);
  FHLE.Result(0);
end;

procedure TPSPSasCore.Register;
begin
  var H := FHLE;
  const L = 'sceSasCore';
  H.Register(L, $42778A9F, '__sceSasInit', hInit);
  H.Register(L, $A3589D81, '__sceSasCore', hCore);
  H.Register(L, $50A14DFC, '__sceSasCoreWithMix', hCoreWithMix);
  H.Register(L, $68A46B95, '__sceSasGetEndFlag', hGetEndFlag);
  H.Register(L, $440CA7D8, '__sceSasSetVolume', hSetVolume);
  H.Register(L, $AD84D37F, '__sceSasSetPitch', hSetPitch);
  H.Register(L, $99944089, '__sceSasSetVoice', hSetVoice);
  H.Register(L, $B7660A23, '__sceSasSetNoise', hSetNoise);
  H.Register(L, $019B25EB, '__sceSasSetADSR', hSetADSR);
  H.Register(L, $9EC3676A, '__sceSasSetADSRmode', hSetADSRmode);
  H.Register(L, $5F9529F6, '__sceSasSetSL', hSetSL);
  H.Register(L, $74AE582A, '__sceSasGetEnvelopeHeight', hGetEnvelopeHeight);
  H.Register(L, $CBCD4F79, '__sceSasSetSimpleADSR', hSetSimpleADSR);
  H.Register(L, $A0CF2FA4, '__sceSasSetKeyOff', hSetKeyOff);
  H.Register(L, $76F01ACA, '__sceSasSetKeyOn', hSetKeyOn);
  H.Register(L, $F983B186, '__sceSasRevVON', hRevVON);
  H.Register(L, $D5A229C9, '__sceSasRevEVOL', hRevEVOL);
  H.Register(L, $33D4AB37, '__sceSasRevType', hRevType);
  H.Register(L, $267A6DD2, '__sceSasRevParam', hRevParam);
  H.Register(L, $2C8E6AB3, '__sceSasGetPauseFlag', hGetPauseFlag);
  H.Register(L, $787D04D5, '__sceSasSetPause', hSetPause);
  H.Register(L, $A232CBE6, '__sceSasSetTrianglarWave', hSetTriangularWave);
  H.Register(L, $D5EBBBCD, '__sceSasSetSteepWave', hSetSteepWave);
  H.Register(L, $BD11B7C2, '__sceSasGetGrain', hGetGrain);
  H.Register(L, $D1E0A01E, '__sceSasSetGrain', hSetGrain);
  H.Register(L, $E175EF66, '__sceSasGetOutputmode', hGetOutputmode);
  H.Register(L, $E855BF76, '__sceSasSetOutputmode', hSetOutputmode);
  H.Register(L, $07F58C24, '__sceSasGetAllEnvelopeHeights', hGetAllEnvelopeHeights);
  H.Register(L, $E1CD9561, '__sceSasSetVoicePCM', hSetVoicePCM);
  H.Register(L, $4AA9EAD6, '__sceSasSetVoiceATRAC3', hSetVoiceATRAC3);
  H.Register(L, $7497EA85, '__sceSasConcatenateATRAC3', hConcatenateATRAC3);
  H.Register(L, $F6107F00, '__sceSasUnsetATRAC3', hUnsetATRAC3);
end;

initialization
  RegisterPSPService(TPSPSasCore);

end.
