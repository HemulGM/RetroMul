unit PS2.SPU2;

// SPU2: two sound cores of 24 ADPCM voices each over 2 MiB of sound RAM,
// mixed at 48 kHz. A voice decodes 16-byte blocks of 28 samples (header:
// shift and filter, flags: loop end, repeat, loop start), interpolates them
// with the 4-point Gaussian table and runs its ADSR envelope and volume
// sweeps; noise and pitch modulation as on the PlayStation SPU. Each core
// mixes its voices (VMIX*), its MEMIN input fed by AutoDMA (AVOL) and its
// sound input (core 0's output for core 1) as MMIX selects: bits 11/10 voices
// left/right, 7/6 MEMIN, 3/2 sound input, and bits 9/8, 5/4, 1/0 the same
// into the core's effects unit (VMIXEL/VMIXER for the voices). The effects
// unit is the PlayStation reverb at half rate in the work area ESA..EEA,
// writing only with ATTR bit 7; its output (EVOL) joins the dry mix before
// MVOL. Core 1's output is the console's. ATTR bit 15 enables a core, bit 14
// unmutes it, bit 6 enables the IRQ (a voice block, a transfer, a DMA or a
// reverb access touching IRQA). Addresses (SSA, LSAX, NAX, TSA, IRQA, the
// reverb registers) count halfwords.
// References: ps2sdk spu2_mmio_hwport.h (AFL 2.0; register layout), psx-spx
// (voice decoding, envelopes, interpolation, noise), ps2tek (AutoDMA, MEMIN).
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, PS2.Scheduler;

const
  PS2SPU2RAMSize = $200000;

type
  TPS2SPU2Voice = record
    // Halfword address of the block being played and its flags, the pitch
    // counter (bits 12 and up: sample within the block), decoder history.
    Address: Cardinal;
    Flags: Byte;
    Counter: Cardinal;
    Old, Older: Integer;
    // The last three samples of the previous block, then this block's 28.
    Samples: array[0..30] of SmallInt;
    // Envelope phase, level (ENVX) and step counter.
    Phase: Byte;
    Level, EnvelopeCounter: Integer;
    // Current left/right volumes and their sweep counters.
    Volume, SweepCounter: array[0..1] of Integer;
    // Output after the envelope (pitch modulation source).
    Output: Integer;
  end;

  TPS2SPU2Core = record
    Voices: array[0..23] of TPS2SPU2Voice;
    EndX: Cardinal;
    // STATX: bit 7 once a DMA transfer finished.
    StatX: Word;
    // IRQ raised since the enable bit was last set.
    IRQFired: Boolean;
    NoiseLevel, NoiseTimer: Integer;
    MainVolume, MainCounter: array[0..1] of Integer;
    // MEMIN: the half (256 samples) being played and the position in it.
    PlayHalf, PlayPos: Integer;
    // Output of the last sample (core 0's feeds core 1).
    OutLeft, OutRight: Integer;
    // Reverb: current halfword in the work area, half-rate phase and the
    // histories of the resampling filter.
    ReverbAddress: Cardinal;
    ReverbPhase, ReverbPosition: Integer;
    ReverbIn, ReverbOut: array[0..1, 0..63] of SmallInt;
  end;

  TPS2SPU2 = class
  private
    FScheduler: TPS2Scheduler;
    FCores: array[0..1] of TPS2SPU2Core;
    FIRQInfo: Word;
    FOut: TArray<SmallInt>;
    FOutCount: Integer;
    function R(Core: Integer; Offset: Cardinal): Word; inline;
    function R32(Core: Integer; Offset: Cardinal): Cardinal; inline;
    procedure SetR32(Core: Integer; Offset, Value: Cardinal);
    function Signed(Offset: Cardinal): Integer; inline;
    procedure CheckIRQ(First, Count: Cardinal);
    procedure LoadBlock(Core, Index: Integer);
    procedure KeyOn(Core: Integer; Mask: Cardinal);
    procedure KeyOff(Core: Integer; Mask: Cardinal);
    procedure TickEnvelope(Core, Index: Integer; var V: TPS2SPU2Voice);
    procedure TickNoise(Core: Integer);
    procedure TickVoice(Core, Index: Integer; Noise, Modulate: Boolean; Previous: Integer; out Left, Right: Integer);
    function ReverbAddress(Core: Integer; Offset: Integer): Cardinal;
    function ReverbRead(Core: Integer; Offset: Integer): Integer;
    procedure ReverbWrite(Core: Integer; Offset, Value: Integer);
    procedure ReverbStep(Core: Integer; InLeft, InRight: Integer; out OutLeft, OutRight: Integer);
    procedure TickReverb(Core: Integer; InLeft, InRight: Integer; out OutLeft, OutRight: Integer);
    procedure MixCore(Core: Integer; InLeft, InRight: Integer);
    procedure Emit(Left, Right: Integer);
  public
    // Byte offsets 0..7FFh of the register window (1F900000h).
    Regs: array[0..$3FF] of Word;
    RAM: TBytes;
    OnInterrupt: TProc;
    // Diagnostics: register writes (not the data port) and voice ends.
    Log: TStrings;
    constructor Create(Scheduler: TPS2Scheduler);
    procedure Reset;
    function Read(Offset: Cardinal): Word;
    procedure Write(Offset: Cardinal; Value: Word);
    // AutoDMA mode on this core (ADMA register).
    function AutoDMA(Core: Integer): Boolean;
    // A DMA block: into MEMIN in AutoDMA mode, else at TSA (or from TSA when
    // not ToSPU).
    procedure DMA(Core: Integer; Data: PByte; Bytes: Integer; ToSPU: Boolean);
    procedure DMADone(Core: Integer);
    // Runs Samples output samples (48 kHz).
    procedure Tick(Samples: Integer);
    // Stereo samples produced since the last call (interleaved left, right).
    function TakeSamples: TArray<SmallInt>;
    procedure SerializeState(State: TStateArchive);
    // Diagnostics: core settings and the voices that sound.
    function Describe: string;
  end;

implementation

const
  // Core registers (byte offsets from the core base, core 1 at +400h).
  VoiceVolumeLeft = $0;
  VoiceVolumeRight = $2;
  VoicePitch = $4;
  VoiceADSR1 = $6;
  VoiceADSR2 = $8;
  VoiceEnvelope = $A;
  VoiceVolumeXLeft = $C;
  VoiceVolumeXRight = $E;
  RegPMON = $180;
  RegNON = $184;
  RegVMIXL = $188;
  RegVMIXEL = $18C;
  RegVMIXR = $190;
  RegVMIXER = $194;
  RegMMIX = $198;
  RegATTR = $19A;
  RegIRQA = $19C;
  RegKON = $1A0;
  RegKOFF = $1A4;
  RegTSA = $1A8;
  RegData = $1AC;
  RegADMA = $1B0;
  RegAddresses = $1C0;
  AddrSSA = 0;
  AddrLSAX = 4;
  AddrNAX = 8;
  // Reverb (pairs of halfwords, high bits first, from ESA): the all-pass
  // sizes, then same-side and cross reflections, comb sources and all-pass
  // destinations; EEA holds the end's high bits.
  RegESA = $2E0;
  RvAPF1Size = $2E4;
  RvAPF2Size = $2E8;
  RvSameLeft = $2EC;
  RvSameRight = $2F0;
  RvComb1Left = $2F4;
  RvComb1Right = $2F8;
  RvComb2Left = $2FC;
  RvComb2Right = $300;
  RvSameSourceLeft = $304;
  RvSameSourceRight = $308;
  RvDiffLeft = $30C;
  RvDiffRight = $310;
  RvComb3Left = $314;
  RvComb3Right = $318;
  RvComb4Left = $31C;
  RvComb4Right = $320;
  RvDiffSourceLeft = $324;
  RvDiffSourceRight = $328;
  RvAPF1Left = $32C;
  RvAPF1Right = $330;
  RvAPF2Left = $334;
  RvAPF2Right = $338;
  RegEEA = $33C;
  RegENDX = $340;
  RegSTATX = $344;
  // Per-core registers past both cores: MVOL, EVOL, AVOL, BVOL, MVOLX.
  RegVolumes = $760;
  VolumesStride = $28;
  VolMain = 0;
  VolEffects = 4;
  VolMemIn = 8;
  VolMainX = $10;
  VolIIR = $14;
  VolComb1 = $16;
  VolComb2 = $18;
  VolComb3 = $1A;
  VolComb4 = $1C;
  VolWall = $1E;
  VolAPF1 = $20;
  VolAPF2 = $22;
  VolInLeft = $24;
  VolInRight = $26;
  RegIRQInfo = $7C2;

  AttrEnable = $8000;
  AttrUnmute = $4000;
  AttrIRQ = $0040;
  AttrEffects = $0080;

  MixVoicesLeft = $800;
  MixVoicesRight = $400;
  MixMemInLeft = $80;
  MixMemInRight = $40;
  MixInLeft = $8;
  MixInRight = $4;
  MixVoicesEffectsLeft = $200;
  MixVoicesEffectsRight = $100;
  MixMemInEffectsLeft = $20;
  MixMemInEffectsRight = $10;
  MixInEffectsLeft = $2;
  MixInEffectsRight = $1;

  MemInBase = $2000;

  PhaseOff = 0;
  PhaseAttack = 1;
  PhaseDecay = 2;
  PhaseSustain = 3;
  PhaseRelease = 4;

  // Output kept for the front end (two seconds of stereo samples); older
  // samples are dropped.
  OutputLimit = 2 * 2 * 48000;

  // psx-spx "Reverb Buffer Resampling".
  ReverbFIR: array[0..38] of Integer = (-$0001, 0, $0002, 0, -$000A, 0, $0023, 0, -$0067, 0, $010A, 0,
    -$0268, 0, $0534, 0, -$0B90, 0, $2806, $4000, $2806, 0, -$0B90, 0, $0534, 0, -$0268, 0, $010A, 0,
    -$0067, 0, $0023, 0, -$000A, 0, $0002, 0, -$0001);

  ADPCMPositive: array[0..4] of Integer = (0, 60, 115, 98, 122);
  ADPCMNegative: array[0..4] of Integer = (0, 0, -52, -55, -60);

  // psx-spx "4-Point Gaussian Interpolation".
  Gauss: array[0..511] of Integer = (
    -$0001, -$0001, -$0001, -$0001, -$0001, -$0001, -$0001, -$0001,
    -$0001, -$0001, -$0001, -$0001, -$0001, -$0001, -$0001, -$0001,
    $0000, $0000, $0000, $0000, $0000, $0000, $0000, $0001,
    $0001, $0001, $0001, $0002, $0002, $0002, $0003, $0003,
    $0003, $0004, $0004, $0005, $0005, $0006, $0007, $0007,
    $0008, $0009, $0009, $000A, $000B, $000C, $000D, $000E,
    $000F, $0010, $0011, $0012, $0013, $0015, $0016, $0018,
    $0019, $001B, $001C, $001E, $0020, $0021, $0023, $0025,
    $0027, $0029, $002C, $002E, $0030, $0033, $0035, $0038,
    $003A, $003D, $0040, $0043, $0046, $0049, $004D, $0050,
    $0054, $0057, $005B, $005F, $0063, $0067, $006B, $006F,
    $0074, $0078, $007D, $0082, $0087, $008C, $0091, $0096,
    $009C, $00A1, $00A7, $00AD, $00B3, $00BA, $00C0, $00C7,
    $00CD, $00D4, $00DB, $00E3, $00EA, $00F2, $00FA, $0101,
    $010A, $0112, $011B, $0123, $012C, $0135, $013F, $0148,
    $0152, $015C, $0166, $0171, $017B, $0186, $0191, $019C,
    $01A8, $01B4, $01C0, $01CC, $01D9, $01E5, $01F2, $0200,
    $020D, $021B, $0229, $0237, $0246, $0255, $0264, $0273,
    $0283, $0293, $02A3, $02B4, $02C4, $02D6, $02E7, $02F9,
    $030B, $031D, $0330, $0343, $0356, $036A, $037E, $0392,
    $03A7, $03BC, $03D1, $03E7, $03FC, $0413, $042A, $0441,
    $0458, $0470, $0488, $04A0, $04B9, $04D2, $04EC, $0506,
    $0520, $053B, $0556, $0572, $058E, $05AA, $05C7, $05E4,
    $0601, $061F, $063E, $065C, $067C, $069B, $06BB, $06DC,
    $06FD, $071E, $0740, $0762, $0784, $07A7, $07CB, $07EF,
    $0813, $0838, $085D, $0883, $08A9, $08D0, $08F7, $091E,
    $0946, $096F, $0998, $09C1, $09EB, $0A16, $0A40, $0A6C,
    $0A98, $0AC4, $0AF1, $0B1E, $0B4C, $0B7A, $0BA9, $0BD8,
    $0C07, $0C38, $0C68, $0C99, $0CCB, $0CFD, $0D30, $0D63,
    $0D97, $0DCB, $0E00, $0E35, $0E6B, $0EA1, $0ED7, $0F0F,
    $0F46, $0F7F, $0FB7, $0FF1, $102A, $1065, $109F, $10DB,
    $1116, $1153, $118F, $11CD, $120B, $1249, $1288, $12C7,
    $1307, $1347, $1388, $13C9, $140B, $144D, $1490, $14D4,
    $1517, $155C, $15A0, $15E6, $162C, $1672, $16B9, $1700,
    $1747, $1790, $17D8, $1821, $186B, $18B5, $1900, $194B,
    $1996, $19E2, $1A2E, $1A7B, $1AC8, $1B16, $1B64, $1BB3,
    $1C02, $1C51, $1CA1, $1CF1, $1D42, $1D93, $1DE5, $1E37,
    $1E89, $1EDC, $1F2F, $1F82, $1FD6, $202A, $207F, $20D4,
    $2129, $217F, $21D5, $222C, $2282, $22DA, $2331, $2389,
    $23E1, $2439, $2492, $24EB, $2545, $259E, $25F8, $2653,
    $26AD, $2708, $2763, $27BE, $281A, $2876, $28D2, $292E,
    $298B, $29E7, $2A44, $2AA1, $2AFF, $2B5C, $2BBA, $2C18,
    $2C76, $2CD4, $2D33, $2D91, $2DF0, $2E4F, $2EAE, $2F0D,
    $2F6C, $2FCC, $302B, $308B, $30EA, $314A, $31AA, $3209,
    $3269, $32C9, $3329, $3389, $33E9, $3449, $34A9, $3509,
    $3569, $35C9, $3629, $3689, $36E8, $3748, $37A8, $3807,
    $3867, $38C6, $3926, $3985, $39E4, $3A43, $3AA2, $3B00,
    $3B5F, $3BBD, $3C1B, $3C79, $3CD7, $3D35, $3D92, $3DEF,
    $3E4C, $3EA9, $3F05, $3F62, $3FBD, $4019, $4074, $40D0,
    $412A, $4185, $41DF, $4239, $4292, $42EB, $4344, $439C,
    $43F4, $444C, $44A3, $44FA, $4550, $45A6, $45FC, $4651,
    $46A6, $46FA, $474E, $47A1, $47F4, $4846, $4898, $48E9,
    $493A, $498A, $49D9, $4A29, $4A77, $4AC5, $4B13, $4B5F,
    $4BAC, $4BF7, $4C42, $4C8D, $4CD7, $4D20, $4D68, $4DB0,
    $4DF7, $4E3E, $4E84, $4EC9, $4F0E, $4F52, $4F95, $4FD7,
    $5019, $505A, $509A, $50DA, $5118, $5156, $5194, $51D0,
    $520C, $5247, $5281, $52BA, $52F3, $532A, $5361, $5397,
    $53CC, $5401, $5434, $5467, $5499, $54CA, $54FA, $5529,
    $5558, $5585, $55B2, $55DE, $5609, $5632, $565B, $5684,
    $56AB, $56D1, $56F6, $571B, $573E, $5761, $5782, $57A3,
    $57C3, $57E2, $57FF, $581C, $5838, $5853, $586D, $5886,
    $589E, $58B5, $58CB, $58E0, $58F4, $5907, $5919, $592A,
    $593A, $5949, $5958, $5965, $5971, $597C, $5986, $598F,
    $5997, $599E, $59A4, $59A9, $59AD, $59B0, $59B2, $59B3);

function Sar32(Value: Integer; Count: Integer): Integer; inline;
begin
  if Value < 0 then
    Result := not ((not Value) shr Count)
  else
    Result := Value shr Count;
end;

function Sar64(Value: Int64; Count: Integer): Int64; inline;
begin
  if Value < 0 then
    Result := not ((not Value) shr Count)
  else
    Result := Value shr Count;
end;

function Clamp16(Value: Int64): Integer; inline;
begin
  if Value < -32768 then
    Result := -32768
  else if Value > 32767 then
    Result := 32767
  else
    Result := Integer(Value);
end;

// psx-spx "Envelope Operation depending on Shift/Step/Mode/Direction", one
// sample's step. A rate of all ones (Step or Shift shl 2 = 7Fh) never steps.
procedure EnvelopeStep(var Level, Counter: Integer; Exponential, Decrease, Negative: Boolean; Shift, Step: Integer);
begin
  if (Step or (Shift shl 2)) = $7F then
    Exit;
  var Delta := 7 - Step;
  if Decrease xor Negative then
    Delta := not Delta;
  if Shift < 11 then
    Delta := Delta shl (11 - Shift);
  var Increment := $8000;
  if Shift > 11 then
    Increment := $8000 shr (Shift - 11);
  if Exponential and not Decrease and (Level > $6000) then
  begin
    if Shift < 10 then
      Delta := Sar32(Delta, 2)
    else if Shift >= 11 then
      Increment := Increment shr 2
    else
    begin
      Delta := Sar32(Delta, 1);
      Increment := Increment shr 1;
    end;
  end
  else if Exponential and Decrease then
    Delta := Integer(Sar64(Int64(Delta) * Level, 15));
  if Increment < 1 then
    Increment := 1;
  Inc(Counter, Increment);
  if (Counter and $8000) = 0 then
    Exit;
  Counter := Counter and $7FFF;
  Inc(Level, Delta);
  if not Decrease then
  begin
    if Level < -$8000 then
      Level := -$8000
    else if Level > $7FFF then
      Level := $7FFF;
  end
  else if Negative then
  begin
    if Level < -$8000 then
      Level := -$8000
    else if Level > 0 then
      Level := 0;
  end
  else if Level < 0 then
    Level := 0;
end;

// Volume registers: bit 15 clear sets the volume (bits 0..14 times two);
// set, it sweeps from the current volume.
procedure TickVolume(Setting: Word; var Level, Counter: Integer);
begin
  if (Setting and $8000) = 0 then
    Level := SmallInt(Word(Setting shl 1))
  else
    EnvelopeStep(Level, Counter, (Setting and $4000) <> 0, (Setting and $2000) <> 0, (Setting and $1000) <> 0,
      (Setting shr 2) and $1F, Setting and 3);
end;

{ TPS2SPU2 }

constructor TPS2SPU2.Create(Scheduler: TPS2Scheduler);
begin
  inherited Create;
  FScheduler := Scheduler;
  SetLength(RAM, PS2SPU2RAMSize);
  SetLength(FOut, 8192);
  Reset;
end;

procedure TPS2SPU2.Reset;
begin
  FillChar(Regs, SizeOf(Regs), 0);
  FillChar(RAM[0], Length(RAM), 0);
  FillChar(FCores, SizeOf(FCores), 0);
  FIRQInfo := 0;
  FOutCount := 0;
end;

function TPS2SPU2.R(Core: Integer; Offset: Cardinal): Word;
begin
  Result := Regs[((Cardinal(Core) * $400 + Offset) shr 1) and $3FF];
end;

// A pair of halfword registers: high bits first.
function TPS2SPU2.R32(Core: Integer; Offset: Cardinal): Cardinal;
begin
  Result := ((Cardinal(R(Core, Offset)) shl 16) or R(Core, Offset + 2)) and $FFFFF;
end;

procedure TPS2SPU2.SetR32(Core: Integer; Offset, Value: Cardinal);
begin
  var I := ((Cardinal(Core) * $400 + Offset) shr 1) and $3FF;
  Regs[I] := Word((Value shr 16) and $F);
  Regs[I + 1] := Word(Value);
end;

function TPS2SPU2.Signed(Offset: Cardinal): Integer;
begin
  Result := SmallInt(Regs[(Offset shr 1) and $3FF]);
end;

function TPS2SPU2.AutoDMA(Core: Integer): Boolean;
begin
  Result := (R(Core, RegADMA) and (1 shl Core)) <> 0;
end;

// An access to Count halfwords at First: a core's IRQ fires when it covers
// the core's IRQ address with ATTR bit 6 set (once until the bit is cleared).
procedure TPS2SPU2.CheckIRQ(First, Count: Cardinal);
begin
  for var C := 0 to 1 do
  begin
    if FCores[C].IRQFired or ((R(C, RegATTR) and AttrIRQ) = 0) then
      Continue;
    if ((R32(C, RegIRQA) - First) and $FFFFF) < Count then
    begin
      FCores[C].IRQFired := True;
      FIRQInfo := FIRQInfo or Word(4 shl C);
      if Assigned(OnInterrupt) then
        OnInterrupt();
    end;
  end;
end;

// The block at the voice's address: loop start flag (LSAX), IRQ and 28
// decoded samples (psx-spx "SPU ADPCM Samples": shifts 13..15 act as 9,
// filters above 4 as filter 4).
procedure TPS2SPU2.LoadBlock(Core, Index: Integer);
begin
  var V: ^TPS2SPU2Voice := @FCores[Core].Voices[Index];
  var At := V.Address and $FFFF8;
  V.Address := At;
  var P := PByte(@RAM[At * 2]);
  var Header := P[0];
  V.Flags := P[1];
  if (V.Flags and 4) <> 0 then
    SetR32(Core, RegAddresses + Cardinal(Index) * 12 + AddrLSAX, At);
  CheckIRQ(At, 8);
  var Shift := Header and $F;
  if Shift > 12 then
    Shift := 9;
  var Filter := (Header shr 4) and 7;
  if Filter > 4 then
    Filter := 4;
  var F0 := ADPCMPositive[Filter];
  var F1 := ADPCMNegative[Filter];
  for var J := 0 to 27 do
  begin
    var Nibble := (P[2 + (J shr 1)] shr ((J and 1) * 4)) and $F;
    var Sample := Integer(Nibble) shl 12;
    if Nibble >= 8 then
      Dec(Sample, $10000);
    var Value := Clamp16(Sar32(Sample, Shift) + Sar32(V.Old * F0 + V.Older * F1 + 32, 6));
    V.Older := V.Old;
    V.Old := Value;
    V.Samples[3 + J] := SmallInt(Value);
  end;
end;

procedure TPS2SPU2.KeyOn(Core: Integer; Mask: Cardinal);
begin
  for var Index := 0 to 23 do
    if (Mask and (Cardinal(1) shl Index)) <> 0 then
    begin
      var V: ^TPS2SPU2Voice := @FCores[Core].Voices[Index];
      V.Address := R32(Core, RegAddresses + Cardinal(Index) * 12 + AddrSSA);
      V.Counter := 0;
      V.Old := 0;
      V.Older := 0;
      V.Samples[0] := 0;
      V.Samples[1] := 0;
      V.Samples[2] := 0;
      V.Phase := PhaseAttack;
      V.Level := 0;
      V.EnvelopeCounter := 0;
      FCores[Core].EndX := FCores[Core].EndX and not (Cardinal(1) shl Index);
      LoadBlock(Core, Index);
    end;
end;

procedure TPS2SPU2.KeyOff(Core: Integer; Mask: Cardinal);
begin
  for var Index := 0 to 23 do
    if (Mask and (Cardinal(1) shl Index)) <> 0 then
    begin
      var V: ^TPS2SPU2Voice := @FCores[Core].Voices[Index];
      if V.Phase <> PhaseOff then
      begin
        V.Phase := PhaseRelease;
        V.EnvelopeCounter := 0;
      end;
    end;
end;

// psx-spx "SPU Volume and ADSR Generator".
procedure TPS2SPU2.TickEnvelope(Core, Index: Integer; var V: TPS2SPU2Voice);
begin
  var A1 := R(Core, Cardinal(Index) * $10 + VoiceADSR1);
  var A2 := R(Core, Cardinal(Index) * $10 + VoiceADSR2);
  case V.Phase of
    PhaseAttack:
      begin
        EnvelopeStep(V.Level, V.EnvelopeCounter, (A1 and $8000) <> 0, False, False, (A1 shr 10) and $1F,
          (A1 shr 8) and 3);
        if V.Level >= $7FFF then
        begin
          V.Phase := PhaseDecay;
          if V.Level <= ((A1 and $F) + 1) * $800 then
            V.Phase := PhaseSustain;
        end;
      end;
    PhaseDecay:
      begin
        EnvelopeStep(V.Level, V.EnvelopeCounter, True, True, False, (A1 shr 4) and $F, 0);
        if V.Level <= ((A1 and $F) + 1) * $800 then
          V.Phase := PhaseSustain;
      end;
    PhaseSustain:
      EnvelopeStep(V.Level, V.EnvelopeCounter, (A2 and $8000) <> 0, (A2 and $4000) <> 0, False, (A2 shr 8) and $1F,
        (A2 shr 6) and 3);
    PhaseRelease:
      begin
        EnvelopeStep(V.Level, V.EnvelopeCounter, (A2 and $20) <> 0, True, False, A2 and $1F, 0);
        if V.Level <= 0 then
        begin
          V.Level := 0;
          V.Phase := PhaseOff;
        end;
      end;
  end;
end;

// psx-spx "SPU Noise Generator" (clock in ATTR bits 8..13).
procedure TPS2SPU2.TickNoise(Core: Integer);
begin
  var C: ^TPS2SPU2Core := @FCores[Core];
  var A := R(Core, RegATTR);
  var Step := Integer((A shr 8) and 3) + 4;
  var Shift := (A shr 10) and $F;
  Dec(C.NoiseTimer, Step);
  var L := C.NoiseLevel;
  var Parity := ((L shr 15) xor (L shr 12) xor (L shr 11) xor (L shr 10) xor 1) and 1;
  if C.NoiseTimer < 0 then
  begin
    C.NoiseLevel := ((L shl 1) or Parity) and $FFFF;
    Inc(C.NoiseTimer, $20000 shr Shift);
    if C.NoiseTimer < 0 then
      Inc(C.NoiseTimer, $20000 shr Shift);
  end;
end;

// One sample of a voice: interpolated ADPCM (or noise) after the envelope,
// the left/right contributions, then the pitch counter (psx-spx "Pitch
// Counter"), the envelope and the volume sweeps.
procedure TPS2SPU2.TickVoice(Core, Index: Integer; Noise, Modulate: Boolean; Previous: Integer;
  out Left, Right: Integer);
begin
  var V: ^TPS2SPU2Voice := @FCores[Core].Voices[Index];
  var Base := Cardinal(Index) * $10;
  Left := 0;
  Right := 0;
  V.Output := 0;
  var Sample: Integer;
  if Noise then
    Sample := SmallInt(Word(FCores[Core].NoiseLevel))
  else
  begin
    var I := (V.Counter shr 4) and $FF;
    var S := V.Counter shr 12;
    Sample := Sar32(Gauss[$FF - I] * V.Samples[S], 15) + Sar32(Gauss[$1FF - I] * V.Samples[S + 1], 15) +
      Sar32(Gauss[$100 + I] * V.Samples[S + 2], 15) + Sar32(Gauss[I] * V.Samples[S + 3], 15);
  end;
  V.Output := Sar32(Sample * V.Level, 15);
  Left := Sar32(V.Output * V.Volume[0], 15);
  Right := Sar32(V.Output * V.Volume[1], 15);

  var Step := Integer(R(Core, Base + VoicePitch));
  if Modulate then
    Step := Integer(Sar64(Int64(SmallInt(Word(Step))) * (Previous + $8000), 15)) and $FFFF;
  if Step > $3FFF then
    Step := $4000;
  Inc(V.Counter, Cardinal(Step));
  if V.Counter >= 28 shl 12 then
  begin
    Dec(V.Counter, 28 shl 12);
    if (V.Flags and 1) <> 0 then
    begin
      // Loop end: on to LSAX; without the repeat flag the voice ends at
      // level zero.
      FCores[Core].EndX := FCores[Core].EndX or (Cardinal(1) shl Index);
      if (Log <> nil) and (Log.Count < 100000) then
        Log.Add(Format('%d spu voice %d:%d end at %x flags %x', [FScheduler.Now, Core, Index, V.Address, V.Flags]));
      V.Address := R32(Core, RegAddresses + Cardinal(Index) * 12 + AddrLSAX);
      if (V.Flags and 2) = 0 then
      begin
        V.Phase := PhaseRelease;
        V.Level := 0;
      end;
    end
    else
      V.Address := (V.Address + 8) and $FFFFF;
    V.Samples[0] := V.Samples[28];
    V.Samples[1] := V.Samples[29];
    V.Samples[2] := V.Samples[30];
    LoadBlock(Core, Index);
  end;

  TickEnvelope(Core, Index, V^);
  TickVolume(R(Core, Base + VoiceVolumeLeft), V.Volume[0], V.SweepCounter[0]);
  TickVolume(R(Core, Base + VoiceVolumeRight), V.Volume[1], V.SweepCounter[1]);
end;

// Offsets are relative to the current reverb address and wrap within the
// work area ESA..EEA (halfwords).
function TPS2SPU2.ReverbAddress(Core: Integer; Offset: Integer): Cardinal;
begin
  var Base := Int64(R32(Core, RegESA));
  var Top := (Int64(R(Core, RegEEA) and $F) shl 16) or $FFFF;
  var Size := Top - Base + 1;
  if Size <= 0 then
    Exit(Cardinal(Base));
  var Relative := (Int64(FCores[Core].ReverbAddress) - Base + Offset) mod Size;
  if Relative < 0 then
    Inc(Relative, Size);
  Result := Cardinal(Base + Relative) and $FFFFF;
end;

function TPS2SPU2.ReverbRead(Core: Integer; Offset: Integer): Integer;
begin
  var At := ReverbAddress(Core, Offset);
  CheckIRQ(At, 1);
  Result := PSmallInt(@RAM[At * 2])^;
end;

procedure TPS2SPU2.ReverbWrite(Core: Integer; Offset, Value: Integer);
begin
  var At := ReverbAddress(Core, Offset);
  CheckIRQ(At, 1);
  PSmallInt(@RAM[At * 2])^ := SmallInt(Value);
end;

// One half-rate step of psx-spx "Reverb Formula". With ATTR bit 7 clear
// nothing is written and the reflection stages are skipped.
procedure TPS2SPU2.ReverbStep(Core: Integer; InLeft, InRight: Integer; out OutLeft, OutRight: Integer);
var
  Enabled: Boolean;
  IIR, Wall: Integer;
  VolBase: Cardinal;

  function A(Reg: Cardinal): Integer;
  begin
    Result := Integer(R32(Core, Reg));
  end;

  function V(Reg: Cardinal): Integer;
  begin
    Result := Signed(VolBase + Reg);
  end;

  procedure Reflect(Dest, Source, Input: Integer);
  begin
    var Prev := ReverbRead(Core, A(Dest) - 1);
    var Value := Sar64(Int64(Input + Sar32(ReverbRead(Core, A(Source)) * Wall, 15) - Prev) * IIR, 15) + Prev;
    if IIR = -$8000 then
      Value := -Value;
    ReverbWrite(Core, A(Dest), Clamp16(Value));
  end;

  function Comb(C1, C2, C3, C4: Cardinal): Integer;
  begin
    Result := Clamp16(Sar64(Int64(V(VolComb1)) * ReverbRead(Core, A(C1)) + Int64(V(VolComb2)) *
      ReverbRead(Core, A(C2)) + Int64(V(VolComb3)) * ReverbRead(Core, A(C3)) + Int64(V(VolComb4)) *
      ReverbRead(Core, A(C4)), 15));
  end;

  function AllPass(Value: Integer; Dest, Size, Volume: Cardinal): Integer;
  begin
    var Delayed := ReverbRead(Core, A(Dest) - A(Size));
    var Gain := V(Volume);
    var X := Clamp16(Value - Sar32(Gain * Delayed, 15));
    if Enabled then
      ReverbWrite(Core, A(Dest), X);
    Result := Clamp16(Sar32(X * Gain, 15) + Delayed);
  end;

begin
  VolBase := RegVolumes + Cardinal(Core) * VolumesStride;
  Enabled := (R(Core, RegATTR) and AttrEffects) <> 0;
  IIR := V(VolIIR);
  Wall := V(VolWall);
  var LeftIn := Sar32(InLeft * V(VolInLeft), 15);
  var RightIn := Sar32(InRight * V(VolInRight), 15);
  if Enabled then
  begin
    Reflect(RvSameLeft, RvSameSourceLeft, LeftIn);
    Reflect(RvSameRight, RvSameSourceRight, RightIn);
    Reflect(RvDiffLeft, RvDiffSourceRight, LeftIn);
    Reflect(RvDiffRight, RvDiffSourceLeft, RightIn);
  end;
  var L := Comb(RvComb1Left, RvComb2Left, RvComb3Left, RvComb4Left);
  var Rt := Comb(RvComb1Right, RvComb2Right, RvComb3Right, RvComb4Right);
  L := AllPass(AllPass(L, RvAPF1Left, RvAPF1Size, VolAPF1), RvAPF2Left, RvAPF2Size, VolAPF2);
  Rt := AllPass(AllPass(Rt, RvAPF1Right, RvAPF1Size, VolAPF1), RvAPF2Right, RvAPF2Size, VolAPF2);
  OutLeft := Sar32(L * V(VolEffects), 15);
  OutRight := Sar32(Rt * V(VolEffects + 2), 15);
  FCores[Core].ReverbAddress := ReverbAddress(Core, 1);
end;

// The reverb runs at half the output rate; its input is filtered down and
// its output (zero-stuffed back) filtered up with the 39-tap half-band FIR.
// Without writes or output volume the step only moves the buffer address.
procedure TPS2SPU2.TickReverb(Core: Integer; InLeft, InRight: Integer; out OutLeft, OutRight: Integer);
begin
  var C: ^TPS2SPU2Core := @FCores[Core];
  C.ReverbIn[0, C.ReverbPosition] := SmallInt(InLeft);
  C.ReverbIn[1, C.ReverbPosition] := SmallInt(InRight);
  var StepLeft := 0;
  var StepRight := 0;
  if C.ReverbPhase = 0 then
  begin
    var VolBase := RegVolumes + Cardinal(Core) * VolumesStride;
    if ((R(Core, RegATTR) and AttrEffects) <> 0) or (Signed(VolBase + VolEffects) <> 0) or
      (Signed(VolBase + VolEffects + 2) <> 0) then
    begin
      var SumL: Integer := 0;
      var SumR: Integer := 0;
      var K := 0;
      while K <= 38 do
      begin
        var At := (C.ReverbPosition - K) and 63;
        Inc(SumL, ReverbFIR[K] * C.ReverbIn[0, At]);
        Inc(SumR, ReverbFIR[K] * C.ReverbIn[1, At]);
        Inc(K, 2);
      end;
      var Center := (C.ReverbPosition - 19) and 63;
      Inc(SumL, ReverbFIR[19] * C.ReverbIn[0, Center]);
      Inc(SumR, ReverbFIR[19] * C.ReverbIn[1, Center]);
      ReverbStep(Core, Clamp16(Sar32(SumL, 15)), Clamp16(Sar32(SumR, 15)), StepLeft, StepRight);
    end
    else
      C.ReverbAddress := ReverbAddress(Core, 1);
  end;
  C.ReverbOut[0, C.ReverbPosition] := SmallInt(Clamp16(StepLeft));
  C.ReverbOut[1, C.ReverbPosition] := SmallInt(Clamp16(StepRight));
  var SumL: Integer := 0;
  var SumR: Integer := 0;
  var K := 0;
  while K <= 38 do
  begin
    var At := (C.ReverbPosition - K) and 63;
    Inc(SumL, ReverbFIR[K] * C.ReverbOut[0, At]);
    Inc(SumR, ReverbFIR[K] * C.ReverbOut[1, At]);
    Inc(K, 2);
  end;
  var Center := (C.ReverbPosition - 19) and 63;
  Inc(SumL, ReverbFIR[19] * C.ReverbOut[0, Center]);
  Inc(SumR, ReverbFIR[19] * C.ReverbOut[1, Center]);
  OutLeft := Clamp16(Sar32(SumL, 14));
  OutRight := Clamp16(Sar32(SumR, 14));
  C.ReverbPosition := (C.ReverbPosition + 1) and 63;
  C.ReverbPhase := C.ReverbPhase xor 1;
end;

// One sample of a core: its voices, MEMIN and the sound input as MMIX
// selects (dry and into the effects unit), through MVOL.
procedure TPS2SPU2.MixCore(Core: Integer; InLeft, InRight: Integer);
begin
  var C: ^TPS2SPU2Core := @FCores[Core];
  var Attr := R(Core, RegATTR);
  var Mix := R(Core, RegMMIX);
  TickNoise(Core);
  var PMON := (Cardinal(R(Core, RegPMON + 2)) shl 16) or R(Core, RegPMON);
  var NON := (Cardinal(R(Core, RegNON + 2)) shl 16) or R(Core, RegNON);
  var MixL := (Cardinal(R(Core, RegVMIXL + 2)) shl 16) or R(Core, RegVMIXL);
  var MixR := (Cardinal(R(Core, RegVMIXR + 2)) shl 16) or R(Core, RegVMIXR);
  var MixEL := (Cardinal(R(Core, RegVMIXEL + 2)) shl 16) or R(Core, RegVMIXEL);
  var MixER := (Cardinal(R(Core, RegVMIXER + 2)) shl 16) or R(Core, RegVMIXER);
  var VoicesL := 0;
  var VoicesR := 0;
  var VoicesEL := 0;
  var VoicesER := 0;
  var Previous := 0;
  for var Index := 0 to 23 do
  begin
    var V: ^TPS2SPU2Voice := @C.Voices[Index];
    if (V.Phase = PhaseOff) and (V.Level = 0) then
    begin
      V.Output := 0;
      Previous := 0;
      Continue;
    end;
    var Bit := Cardinal(1) shl Index;
    var L, Rt: Integer;
    TickVoice(Core, Index, (NON and Bit) <> 0, (Index > 0) and ((PMON and Bit) <> 0), Previous, L, Rt);
    Previous := V.Output;
    if (MixL and Bit) <> 0 then
      Inc(VoicesL, L);
    if (MixR and Bit) <> 0 then
      Inc(VoicesR, Rt);
    if (MixEL and Bit) <> 0 then
      Inc(VoicesEL, L);
    if (MixER and Bit) <> 0 then
      Inc(VoicesER, Rt);
  end;

  // MEMIN: the AutoDMA samples of this position (read once).
  var Half := Cardinal(C.PlayHalf) * $100 + Cardinal(C.PlayPos);
  var AL := (MemInBase + Cardinal(Core) * $400 + Half) * 2;
  var AR := AL + $400;
  var MemL := Integer(PSmallInt(@RAM[AL])^);
  var MemR := Integer(PSmallInt(@RAM[AR])^);
  PWord(@RAM[AL])^ := 0;
  PWord(@RAM[AR])^ := 0;
  Inc(C.PlayPos);
  if C.PlayPos >= $100 then
  begin
    C.PlayPos := 0;
    C.PlayHalf := C.PlayHalf xor 1;
  end;
  var VolBase := RegVolumes + Cardinal(Core) * VolumesStride;
  MemL := Sar32(MemL * Signed(VolBase + VolMemIn), 15);
  MemR := Sar32(MemR * Signed(VolBase + VolMemIn + 2), 15);

  var OutL: Int64 := 0;
  var OutR: Int64 := 0;
  if (Mix and MixVoicesLeft) <> 0 then
    Inc(OutL, VoicesL);
  if (Mix and MixVoicesRight) <> 0 then
    Inc(OutR, VoicesR);
  if (Mix and MixMemInLeft) <> 0 then
    Inc(OutL, MemL);
  if (Mix and MixMemInRight) <> 0 then
    Inc(OutR, MemR);
  if (Mix and MixInLeft) <> 0 then
    Inc(OutL, InLeft);
  if (Mix and MixInRight) <> 0 then
    Inc(OutR, InRight);
  var WetL: Int64 := 0;
  var WetR: Int64 := 0;
  if (Mix and MixVoicesEffectsLeft) <> 0 then
    Inc(WetL, VoicesEL);
  if (Mix and MixVoicesEffectsRight) <> 0 then
    Inc(WetR, VoicesER);
  if (Mix and MixMemInEffectsLeft) <> 0 then
    Inc(WetL, MemL);
  if (Mix and MixMemInEffectsRight) <> 0 then
    Inc(WetR, MemR);
  if (Mix and MixInEffectsLeft) <> 0 then
    Inc(WetL, InLeft);
  if (Mix and MixInEffectsRight) <> 0 then
    Inc(WetR, InRight);
  var RevL, RevR: Integer;
  TickReverb(Core, Clamp16(WetL), Clamp16(WetR), RevL, RevR);
  Inc(OutL, RevL);
  Inc(OutR, RevR);

  TickVolume(Regs[((VolBase + VolMain) shr 1) and $3FF], C.MainVolume[0], C.MainCounter[0]);
  TickVolume(Regs[((VolBase + VolMain + 2) shr 1) and $3FF], C.MainVolume[1], C.MainCounter[1]);
  if (Attr and (AttrEnable or AttrUnmute)) <> (AttrEnable or AttrUnmute) then
  begin
    C.OutLeft := 0;
    C.OutRight := 0;
  end
  else
  begin
    C.OutLeft := Clamp16(Sar64(Clamp16(OutL) * Int64(C.MainVolume[0]), 15));
    C.OutRight := Clamp16(Sar64(Clamp16(OutR) * Int64(C.MainVolume[1]), 15));
  end;
end;

procedure TPS2SPU2.Emit(Left, Right: Integer);
begin
  if FOutCount + 2 > Length(FOut) then
  begin
    if Length(FOut) >= OutputLimit then
    begin
      // Nobody takes the samples: keep the newer half.
      var Keep := FOutCount div 2 and not 1;
      Move(FOut[FOutCount - Keep], FOut[0], Keep * SizeOf(SmallInt));
      FOutCount := Keep;
    end
    else
      SetLength(FOut, Length(FOut) * 2);
  end;
  FOut[FOutCount] := SmallInt(Left);
  FOut[FOutCount + 1] := SmallInt(Right);
  Inc(FOutCount, 2);
end;

procedure TPS2SPU2.Tick(Samples: Integer);
begin
  for var N := 1 to Samples do
  begin
    MixCore(0, 0, 0);
    MixCore(1, FCores[0].OutLeft, FCores[0].OutRight);
    Emit(FCores[1].OutLeft, FCores[1].OutRight);
  end;
end;

function TPS2SPU2.TakeSamples: TArray<SmallInt>;
begin
  Result := Copy(FOut, 0, FOutCount);
  FOutCount := 0;
end;

function TPS2SPU2.Read(Offset: Cardinal): Word;
begin
  Offset := Offset and $7FE;
  if Offset = RegIRQInfo then
  begin
    Result := FIRQInfo;
    FIRQInfo := 0;
    Exit;
  end;
  if Offset >= RegVolumes then
  begin
    var Rel := Offset - RegVolumes;
    if Rel < 2 * VolumesStride then
    begin
      var Core := Integer(Rel div VolumesStride);
      case Rel mod VolumesStride of
        VolMainX: Exit(Word(FCores[Core].MainVolume[0]));
        VolMainX + 2: Exit(Word(FCores[Core].MainVolume[1]));
      end;
    end;
    Exit(Regs[Offset shr 1]);
  end;
  var Core := Integer(Offset shr 10) and 1;
  var Local := Offset and $3FF;
  var C: ^TPS2SPU2Core := @FCores[Core];
  case Local of
    RegSTATX: Exit(C.StatX);
    RegENDX: Exit(Word(C.EndX));
    RegENDX + 2: Exit(Word(C.EndX shr 16));
    0..$17F:
      begin
        var V := Integer(Local shr 4);
        case Local and $F of
          VoiceEnvelope: Exit(Word(C.Voices[V].Level));
          VoiceVolumeXLeft: Exit(Word(C.Voices[V].Volume[0]));
          VoiceVolumeXRight: Exit(Word(C.Voices[V].Volume[1]));
        end;
      end;
    RegAddresses..RegAddresses + 24 * 12 - 1:
      begin
        var V := Integer((Local - RegAddresses) div 12);
        case (Local - RegAddresses) mod 12 of
          AddrNAX: Exit(Word((C.Voices[V].Address shr 16) and $F));
          AddrNAX + 2: Exit(Word(C.Voices[V].Address));
        end;
      end;
  end;
  Result := Regs[Offset shr 1];
end;

procedure TPS2SPU2.Write(Offset: Cardinal; Value: Word);
begin
  Offset := Offset and $7FE;
  if (Log <> nil) and (Log.Count < 100000) and ((Offset and $3FF) <> RegData) and
    (((Offset and $3FF) >= RegPMON) or (Offset >= RegVolumes)) then
    Log.Add(Format('%d spu w %.3x = %.4x', [FScheduler.Now, Offset, Value]));
  Regs[Offset shr 1] := Value;
  if Offset >= RegVolumes then
    Exit;
  var Core := Integer(Offset shr 10) and 1;
  var C: ^TPS2SPU2Core := @FCores[Core];
  case Offset and $3FF of
    RegATTR:
      begin
        C.StatX := 0;
        if (Value and AttrIRQ) = 0 then
          C.IRQFired := False;
      end;
    RegKON: KeyOn(Core, Value);
    RegKON + 2: KeyOn(Core, Cardinal(Value and $FF) shl 16);
    RegKOFF: KeyOff(Core, Value);
    RegKOFF + 2: KeyOff(Core, Cardinal(Value and $FF) shl 16);
    RegENDX, RegENDX + 2: C.EndX := 0;
    RegData:
      begin
        // Manual transfer: one halfword at the transfer address.
        var A := R32(Core, RegTSA);
        CheckIRQ(A, 1);
        PWord(@RAM[(A * 2) and (PS2SPU2RAMSize - 2)])^ := Value;
        SetR32(Core, RegTSA, (A + 1) and $FFFFF);
      end;
  end;
end;

procedure TPS2SPU2.DMA(Core: Integer; Data: PByte; Bytes: Integer; ToSPU: Boolean);
begin
  FCores[Core].StatX := FCores[Core].StatX and not $80;
  if Bytes <= 0 then
    Exit;
  if ToSPU and AutoDMA(Core) then
  begin
    // A block of left then right samples into the MEMIN half not playing.
    var Count := Bytes div 4;
    if Count > $100 then
      Count := $100;
    var Half := Cardinal(FCores[Core].PlayHalf xor 1) * $100;
    var L := (MemInBase + Cardinal(Core) * $400 + Half) * 2;
    var Rt := L + $400;
    Move(Data^, RAM[L], Count * 2);
    Move((Data + Bytes div 2)^, RAM[Rt], Count * 2);
    Exit;
  end;
  var A := R32(Core, RegTSA);
  var Halfwords := Cardinal(Bytes div 2);
  CheckIRQ(A, Halfwords);
  for var K := 0 to Integer(Halfwords) - 1 do
  begin
    var S := ((A + Cardinal(K)) * 2) and (PS2SPU2RAMSize - 2);
    if ToSPU then
      PWord(@RAM[S])^ := PWord(Data + K * 2)^
    else
      PWord(Data + K * 2)^ := PWord(@RAM[S])^;
  end;
end;

procedure TPS2SPU2.DMADone(Core: Integer);
begin
  FCores[Core].StatX := FCores[Core].StatX or $80;
end;

function TPS2SPU2.Describe: string;
begin
  Result := '';
  for var Core := 0 to 1 do
  begin
    var C: ^TPS2SPU2Core := @FCores[Core];
    var VolBase := RegVolumes + Cardinal(Core) * VolumesStride;
    Result := Result + Format('spu2 core %d: admas %.4x tsa %x attr %.4x mmix %.4x mvol %.4x/%.4x (now %d/%d) avol %.4x/%.4x out %d/%d',
      [Core, R(Core, RegADMA), R32(Core, RegTSA), R(Core, RegATTR), R(Core, RegMMIX), Regs[(VolBase shr 1) and $3FF], Regs[((VolBase + 2) shr 1) and $3FF],
      C.MainVolume[0], C.MainVolume[1], Regs[((VolBase + VolMemIn) shr 1) and $3FF],
      Regs[((VolBase + VolMemIn + 2) shr 1) and $3FF], C.OutLeft, C.OutRight]) + sLineBreak;
    for var Index := 0 to 23 do
    begin
      var V: ^TPS2SPU2Voice := @C.Voices[Index];
      if (V.Phase = PhaseOff) and (V.Level = 0) then
        Continue;
      var Base := Cardinal(Index) * $10;
      Result := Result + Format('  voice %d: phase %d level %d vol %d/%d (reg %.4x/%.4x) pitch %.4x adsr %.4x %.4x addr %x',
        [Index, V.Phase, V.Level, V.Volume[0], V.Volume[1], R(Core, Base + VoiceVolumeLeft),
        R(Core, Base + VoiceVolumeRight), R(Core, Base + VoicePitch), R(Core, Base + VoiceADSR1),
        R(Core, Base + VoiceADSR2), V.Address]) + sLineBreak;
    end;
  end;
end;

procedure TPS2SPU2.SerializeState(State: TStateArchive);
begin
  State.Field(Regs, SizeOf(Regs));
  State.Field(FCores, SizeOf(FCores));
  State.Field(FIRQInfo, SizeOf(FIRQInfo));
  State.Field(RAM[0], Length(RAM));
  if State.Loading then
    FOutCount := 0;
end;

end.
