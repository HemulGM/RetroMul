unit Yamaha.Sound.OPL4;

interface

uses System.SysUtils, PC.Sound.OPL3, Core.Snapshots;

type
  TOPL4Read = function(Context: Pointer; Address: Cardinal; MemoryMode: Boolean): Byte;
  TOPL4Write = procedure(Context: Pointer; Address: Cardinal; Value: Byte; MemoryMode: Boolean);
  TOPL4Voice = record
    Start: Cardinal;
    LoopPosition, EndNegative, Position, Fraction: Word;
    Format, State: Byte; // 0 off, 1 attack, 2 decay, 3 sustain, 4 release
    Envelope, Level: Integer;
    LFO: Cardinal;
  end;
  // Yamaha YMF278B, 33.8688 MHz. Native RetroMul OPL3 FM and 24 PCM voices.
  // Hardware register layout follows Yamaha's manual; rate increment constants
  // are shared with Aaron Giles' BSD-3-Clause YMFM (see OPL4-LICENSE.md).
  POPL4Voice = ^TOPL4Voice;
  TOPL4 = class
  private
    FFM: TOPL3;
    FRegisters: array[0..255] of Byte;
    FVoices: array[0..23] of TOPL4Voice;
    FFMLatch: Word;
    FWaveLatch: Byte;
    FMemoryAddress, FEnvelopeClock: Cardinal;
    FBusy, FLoad, FFMClockRemainder, FFMPhase: Integer;
    FContext: Pointer;
    FRead: TOPL4Read;
    FWrite: TOPL4Write;
    function MemoryRead(Address: Cardinal): Byte;
    procedure StartVoice(Index: Integer);
    function Rate(Index, Value: Integer): Integer;
    procedure EnvelopeTick(Index: Integer);
    function NextPosition(const V: TOPL4Voice; Increment: Integer): Word;
    function Fetch(const V: TOPL4Voice; Position: Word): Integer;
    procedure LoadHeader(Index: Integer);
  public
    constructor Create(Context: Pointer; ReadMemory: TOPL4Read; WriteMemory: TOPL4Write);
    destructor Destroy; override;
    procedure Reset;
    procedure AdvanceClocks(Count: Integer);
    procedure WritePort(Port: Byte; Value: Byte);
    function ReadPort(Port: Byte): Byte;
    procedure WriteWave(RegisterIndex, Value: Byte);
    function ReadWave(RegisterIndex: Byte): Byte;
    procedure Sample(out Left, Right: Double);
    function Interrupt: Boolean;
    procedure SerializeState(State: TStateArchive);
    function ActiveVoices: Integer;
  end;

implementation

uses System.Classes, System.Math;

const
  LfoSteps: array[0..7] of Integer = (1,12,19,25,31,35,37,42);
  Vibrato: array[0..7] of Integer = (0,2,3,4,6,12,24,48);
  Tremolo: array[0..7] of Integer = (0,$14,$20,$28,$30,$40,$50,$80);
  // Factual 8-step Yamaha envelope pattern, also used by YMFM (BSD-3-Clause).
  Increments: array[0..63] of Cardinal = (
    $00000000,$00000000,$10101010,$10101010,
    $10101010,$10101010,$11101110,$11101110,
    $10101010,$10111010,$11101110,$11111110,
    $10101010,$10111010,$11101110,$11111110,
    $10101010,$10111010,$11101110,$11111110,
    $10101010,$10111010,$11101110,$11111110,
    $10101010,$10111010,$11101110,$11111110,
    $10101010,$10111010,$11101110,$11111110,
    $10101010,$10111010,$11101110,$11111110,
    $10101010,$10111010,$11101110,$11111110,
    $10101010,$10111010,$11101110,$11111110,
    $10101010,$10111010,$11101110,$11111110,
    $11111111,$21112111,$21212121,$22212221,
    $22222222,$42224222,$42424242,$44424442,
    $44444444,$84448444,$84848484,$88848884,
    $88888888,$88888888,$88888888,$88888888);
  MixLevel: array[0..7] of Double = (1,0.75,0.5,0.375,0.25,0.1875,0.125,0);

function SignedOctave(Value: Byte): Integer;
begin Result:=((Value shr 4) xor 8)-8;end;

function Attenuate(Sample, Attenuation: Integer): Integer;
begin
  if Attenuation>=640 then Exit(0);
  // 6 dB halves the signal; intermediate ladder steps interpolate linearly.
  var Gain:Integer:=(32768*(128-(Attenuation and 63))) shr (7+(Attenuation shr 6));
  Result:=Floor(Int64(Sample)*Gain/32768);
end;

constructor TOPL4.Create(Context: Pointer; ReadMemory: TOPL4Read; WriteMemory: TOPL4Write);
begin
  inherited Create;
  FContext:=Context;FRead:=ReadMemory;FWrite:=WriteMemory;
  // Native FM steps are scheduled at the exact master/(19*36) ratio below.
  FFM:=TOPL3.Create(14260547,44100);Reset;
end;

destructor TOPL4.Destroy;
begin FFM.Free;inherited;end;

procedure TOPL4.Reset;
begin
  FFM.Reset;FillChar(FRegisters,SizeOf(FRegisters),0);FRegisters[$F8]:=$1B;
  FillChar(FVoices,SizeOf(FVoices),0);
  for var I:=0 to 23 do FVoices[I].Envelope:=640;
  FFMLatch:=0;FWaveLatch:=0;FMemoryAddress:=0;FEnvelopeClock:=0;
  FBusy:=0;FLoad:=0;FFMClockRemainder:=0;FFMPhase:=0;
end;

procedure TOPL4.AdvanceClocks(Count: Integer);
begin
  FBusy:=Max(0,FBusy-Count);FLoad:=Max(0,FLoad-Count);
  // The existing OPL3 timer uses its master/288 units. OPL4 FM is master*8/19.
  Inc(FFMClockRemainder,Count*8);
  FFM.AdvanceClocks(FFMClockRemainder div 19);FFMClockRemainder:=FFMClockRemainder mod 19;
end;

function TOPL4.MemoryRead(Address: Cardinal): Byte;
begin Result:=FRead(FContext,Address and $3FFFFF,(FRegisters[2] and 2)<>0);end;

function TOPL4.Rate(Index, Value: Integer): Integer;
begin
  if Value=0 then Exit(0);if Value=15 then Exit(63);
  Result:=Value*4;var RC:=FRegisters[$C8+Index] shr 4;
  if RC<>15 then begin
    Inc(Result,2*EnsureRange(SignedOctave(FRegisters[$38+Index])+RC,0,15));
    Inc(Result,Ord((FRegisters[$38+Index] and 4)<>0));
  end;
  Result:=EnsureRange(Result,0,63);
end;

procedure TOPL4.StartVoice(Index: Integer);
begin
  FVoices[Index].Envelope:=640;FVoices[Index].State:=1;
  if Rate(Index,FRegisters[$98+Index] shr 4)=63 then begin FVoices[Index].Envelope:=0;FVoices[Index].State:=2;end;
  FVoices[Index].Position:=0;FVoices[Index].Fraction:=0;
end;

procedure TOPL4.LoadHeader(Index: Integer);
begin
  var Wave:=Integer(FRegisters[8+Index]) or ((FRegisters[$20+Index] and 1) shl 8);
  var Bank:Integer:=(FRegisters[2] shr 2) and 7;
  var Address:=Wave*12;
  if (Wave>=384) and (Bank<>0) then Address:=Bank*$80000+(Wave-384)*12;
  var B:array[0..11] of Byte;for var I:=0 to 11 do B[I]:=MemoryRead(Address+I);
  var V:POPL4Voice:=@FVoices[Index];V.Format:=B[0] shr 6;
  V.Start:=((Cardinal(B[0]) and 63) shl 16) or (Cardinal(B[1]) shl 8) or B[2];
  V.LoopPosition:=(Word(B[3]) shl 8) or B[4];V.EndNegative:=(Word(B[5]) shl 8) or B[6];
  for var I:=7 to 11 do WriteWave($80+Index+(I-7)*24,B[I]);
  V.Position:=0;V.Fraction:=0;
  if (FRegisters[$68+Index] and $80)<>0 then StartVoice(Index);
  FLoad:=10000;
end;

procedure TOPL4.WriteWave(RegisterIndex, Value: Byte);
begin
  var Old:=FRegisters[RegisterIndex];FRegisters[RegisterIndex]:=Value;
  case RegisterIndex of
    2: FRegisters[2]:=Value and $1F;
    3: FRegisters[3]:=Value and $3F;
    5: FMemoryAddress:=(Cardinal(FRegisters[3]) shl 16) or (Cardinal(FRegisters[4]) shl 8) or Value;
    6: if (FRegisters[2] and 1)<>0 then begin
      FWrite(FContext,FMemoryAddress,Value,(FRegisters[2] and 2)<>0);
      FMemoryAddress:=(FMemoryAddress+1) and $3FFFFF;
    end;
  end;
  if (RegisterIndex<8) or (RegisterIndex>$F7) then Exit;
  var I:Integer:=(RegisterIndex-8) mod 24;
  case (RegisterIndex-8) div 24 of
    0: LoadHeader(I);
    3: if (Value and 1)<>0 then begin
      FVoices[I].Level:=Value shr 1;
      if FVoices[I].Level=127 then FVoices[I].Level:=255;
    end;
    4: begin
      if (Value and $20)<>0 then FVoices[I].LFO:=0;
      if ((Value xor Old) and $80)<>0 then
        if (Value and $80)<>0 then StartVoice(I)
        else if FVoices[I].State<>0 then FVoices[I].State:=4;
    end;
  end;
end;

function TOPL4.ReadWave(RegisterIndex: Byte): Byte;
begin
  Result:=FRegisters[RegisterIndex];
  if RegisterIndex=2 then Result:=Result or $20;
  if RegisterIndex=6 then begin
    Result:=$FF;
    if (FRegisters[2] and 1)<>0 then begin
      Result:=MemoryRead(FMemoryAddress);FMemoryAddress:=(FMemoryAddress+1) and $3FFFFF;
    end;
    FBusy:=38;
  end;
end;

procedure TOPL4.WritePort(Port: Byte; Value: Byte);
begin
  case Port and 7 of
    0,2: begin FFMLatch:=Value or ((Port and 2) shl 7);FBusy:=56;end;
    1,3: begin FFM.WriteRegister(FFMLatch,Value);FBusy:=56;end;
    4: if (FFM.RegisterValue($105) and 2)<>0 then begin FWaveLatch:=Value;FBusy:=88;end;
    5: if (FFM.RegisterValue($105) and 2)<>0 then begin
      WriteWave(FWaveLatch,Value);FBusy:=88;if FWaveLatch in [3..6] then FBusy:=28;
    end;
  end;
end;

function TOPL4.ReadPort(Port: Byte): Byte;
begin
  Result:=$FF;
  case Port and 7 of
    0,2: begin Result:=FFM.ReadStatus; if FBusy>0 then Result:=Result or 1;if FLoad>0 then Result:=Result or 2;end;
    1,3: Result:=FFM.RegisterValue(FFMLatch);
    5: Result:=ReadWave(FWaveLatch);
  end;
end;

function TOPL4.NextPosition(const V: TOPL4Voice; Increment: Integer): Word;
begin
  Result:=(Cardinal(V.Position)+Cardinal(Increment)) and $FFFF;
  if Cardinal(Result)+V.EndNegative>=$10000 then
    Result:=(Cardinal(Result)+V.EndNegative+V.LoopPosition) and $FFFF;
end;

function TOPL4.Fetch(const V: TOPL4Voice; Position: Word): Integer;
var Address:Cardinal; N:Integer;
begin
  Address:=V.Start;
  case V.Format of
    0: N:=Integer(MemoryRead(Address+Position)) shl 8;
    1: begin
      Inc(Address,(Position div 2)*3);
      if (Position and 1)=0 then N:=(Integer(MemoryRead(Address)) shl 8) or ((MemoryRead(Address+1) and 15) shl 4)
      else N:=(Integer(MemoryRead(Address+2)) shl 8) or (MemoryRead(Address+1) and $F0);
    end;
    2: begin Inc(Address,Position*2);N:=(Integer(MemoryRead(Address)) shl 8) or MemoryRead(Address+1);end;
  else Exit(0);
  end;
  Result:=(N xor $8000)-$8000;
end;

procedure TOPL4.EnvelopeTick(Index: Integer);
begin
  var V:POPL4Voice:=@FVoices[Index];if V.State=0 then Exit;
  var SL:=Integer(FRegisters[$B0+Index] shr 4)*32;if SL=480 then SL:=992;
  if (V.State=2) and (V.Envelope>=SL) then V.State:=3;
  var R:Integer;
  case V.State of
    1: R:=Rate(Index,FRegisters[$98+Index] shr 4);
    2: R:=Rate(Index,FRegisters[$98+Index] and 15);
    3: R:=Rate(Index,FRegisters[$B0+Index] and 15);
  else R:=Rate(Index,FRegisters[$C8+Index] and 15);
  end;
  if (FRegisters[$68+Index] and $40)<>0 then begin
    V.State:=4;if V.Envelope<128 then R:=48 else R:=63;
  end else if (V.State<>1) and (V.Envelope>=192) and ((FRegisters[$38+Index] and 8)<>0) then R:=20;
  if (R=0) or ((V.State=1) and (R=63)) then Exit;
  var Shift:=R shr 2;
  var Counter:=Cardinal((UInt64(FEnvelopeClock shr 1) shl Shift) and $FFFFFFFF);
  if (Counter and $7FF)<>0 then Exit;
  var Step:=Integer((Increments[R] shr (((Counter shr Max(11,Shift)) and 7)*4)) and 15);
  if V.State=1 then begin
    V.Envelope:=Max(0,V.Envelope+Floor((-V.Envelope-1)*Step/16));
    if V.Envelope=0 then V.State:=2;
  end else begin
    V.Envelope:=Min(640,V.Envelope+Step);
    if V.Envelope>=640 then V.State:=0;
  end;
end;

procedure TOPL4.Sample(out Left, Right: Double);
var FMLeft,FMRight:SmallInt;
begin
  FMLeft:=0;FMRight:=0;Inc(FFMPhase,192);
  while FFMPhase>=171 do begin FFMPhase:=FFMPhase-171;FFM.GenerateNative(FMLeft,FMRight,False);end;
  Left:=0;Right:=0;
  for var I:=0 to 23 do begin
    var V:POPL4Voice:=@FVoices[I];
    // Level interpolation runs even while a voice is silent.
    var Target:=Integer(FRegisters[$50+I] shr 1);if Target=127 then Target:=255;
    if (FEnvelopeClock mod 9)=0 then
      if (FEnvelopeClock div 9 mod 3)=0 then begin if V.Level<Target then Inc(V.Level);end
      else if V.Level>Target then Dec(V.Level);
    if V.State=0 then Continue;
    var Control:=FRegisters[$68+I];var LFO:=Integer(V.LFO shr 10);
    if (LFO and $80)<>0 then LFO:=LFO xor $FF;
    var Env:=V.Envelope;
    if (Control and $20)=0 then Inc(Env,(LFO*Tremolo[FRegisters[$E0+I] and 7]) shr 7);
    var N:=Fetch(V^,V.Position);var Next:=V^;Next.Position:=NextPosition(V^,1);
    var Interpolated:=Floor((Int64(N)*($10000-V.Fraction)+Int64(Fetch(V^,Next.Position))*V.Fraction)/65536);
    var Output:=Attenuate(Attenuate(Interpolated,Env),V.Level*4);
    var Pan:=Control and 15;
    if ((Control and $10)=0) and (Pan<>8) then begin
      if Pan<=7 then begin if Pan<>7 then Left:=Left+Output*MixLevel[Pan];Right:=Right+Output;end
      else begin Left:=Left+Output;Right:=Right+Output*MixLevel[16-Pan];end;
    end;
    var Octave:=SignedOctave(FRegisters[$38+I]);
    var FN:=Integer(FRegisters[$20+I] shr 1) or ((FRegisters[$38+I] and 7) shl 7);
    if ((Control and $20)=0) and ((FRegisters[$80+I] and 7)<>0) then begin
      var Triangle:=Integer(V.LFO shr 12);if (Triangle and $10)<>0 then Triangle:=Triangle xor 31;
      if (Triangle and $20)<>0 then Triangle:=-(Triangle and 15);
      Inc(FN,Trunc(Triangle*Vibrato[FRegisters[$80+I] and 7]/12));
    end;
    var Step:Cardinal:=0;
    if Octave<>-8 then Step:=Cardinal(((Int64(FN+1024) shl (8+Octave)) shr 3));
    var Phase:=Cardinal(V.Fraction)+Step;V.Position:=NextPosition(V^,Phase shr 16);V.Fraction:=Phase and $FFFF;
    if (Control and $20)=0 then V.LFO:=(V.LFO+Cardinal(LfoSteps[(FRegisters[$80+I] shr 3) and 7])) and $3FFFF;
  end;
  Left:=Left/262144*MixLevel[FRegisters[$F9] and 7]+FMLeft/32768*MixLevel[FRegisters[$F8] and 7]*0.5;
  Right:=Right/262144*MixLevel[(FRegisters[$F9] shr 3) and 7]+FMRight/32768*MixLevel[(FRegisters[$F8] shr 3) and 7]*0.5;
  FEnvelopeClock:=Cardinal((UInt64(FEnvelopeClock)+1) and $FFFFFFFF);
  for var I:=0 to 23 do EnvelopeTick(I);
end;

function TOPL4.Interrupt: Boolean;
begin Result:=(FFM.ReadStatus and $80)<>0;end;

function TOPL4.ActiveVoices: Integer;
begin Result:=0;for var V in FVoices do if V.State<>0 then Inc(Result);end;

procedure TOPL4.SerializeState(State: TStateArchive);
begin
  FFM.SerializeState(State);State.Field(FRegisters,SizeOf(FRegisters));State.Field(FVoices,SizeOf(FVoices));
  State.Field(FFMLatch,2);State.Field(FWaveLatch,1);State.Field(FMemoryAddress,4);State.Field(FEnvelopeClock,4);
  State.Field(FBusy,4);State.Field(FLoad,4);State.Field(FFMClockRemainder,4);State.Field(FFMPhase,4);
  if (FFMLatch>$1FF) or (FMemoryAddress>$3FFFFF) or (FBusy<0) or (FBusy>88) or
    (FLoad<0) or (FLoad>10000) or (FFMPhase<0) or (FFMPhase>=171) or
    (FFMClockRemainder<0) or (FFMClockRemainder>=19) then raise EReadError.Create('Invalid OPL4 state');
  for var V in FVoices do
    if (V.Start>$3FFFFF) or (V.State>4) or (V.Format>3) or (V.Envelope<0) or
      (V.Envelope>640) or (V.Level<0) or (V.Level>255) or (V.LFO>$3FFFF) then raise EReadError.Create('Invalid OPL4 voice');
end;

end.
