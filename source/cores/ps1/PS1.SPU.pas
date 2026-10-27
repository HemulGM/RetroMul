unit PS1.SPU;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, PS1.Types, PS1.Scheduler,
  PS1.DMA, PS1.CDROM.Audio;

const
  PS1SoundRAMSize = $80000;

type
  TPS1SPUVoice = record
    // Byte address of the ADPCM block being played, its flags, the pitch
    // counter (bits 12 and up: sample within the block) and the decoder
    // history.
    Address: Cardinal;
    Flags: Byte;
    Counter: Cardinal;
    Old, Older: Integer;
    // The last three samples of the previous block, then the 28 of this one
    // (the four-point interpolation looks back three samples).
    Samples: array[0..30] of SmallInt;
    // Envelope phase, level (ENVX) and step counter.
    Phase: Byte;
    Level, EnvelopeCounter: Integer;
    // Current left/right volumes and their sweep counters.
    Volume, SweepCounter: array[0..1] of Integer;
    // Sample after the envelope: pitch modulation source and capture data.
    Output: Integer;
  end;

  // Sound processing unit: 24 ADPCM voices with Gaussian interpolation,
  // envelopes, volume sweeps, noise and pitch modulation; the reverb unit;
  // capture buffers; the SPU interrupt; sound RAM transfers by I/O and DMA4;
  // and the CD audio input. One stereo frame is produced every 768 CPU
  // cycles. Frames are computed lazily: every access that can observe or
  // change the SPU first produces the frames due by the current time, so the
  // result does not depend on when they are computed.
  TPS1SPU = class(TPS1DMADevice)
  private
    FScheduler: TPS1Scheduler;
    FIRQ: TPS1IRQRequest;
    FCDAudio: TPS1CDAudio;
    FRegisters: array[0..$1FF] of Word;
    FVoices: array[0..23] of TPS1SPUVoice;
    // Key on/off bits written since the last frame; they act on the next one.
    FKeyOn, FKeyOff, FEndX: Cardinal;
    FMain, FMainCounter: array[0..1] of Integer;
    FIRQFlag: Boolean;
    FNoiseLevel, FNoiseTimer: Integer;
    // Position in the capture buffers (0..511).
    FCapture: Integer;
    // Reverb: work area address, 22050 Hz phase, and the 44100 Hz input and
    // (zero-stuffed) output histories of the resampling filter.
    FReverbAddress: Cardinal;
    FReverbPhase: Integer;
    FReverbPosition: Integer;
    FReverbIn, FReverbOut: array[0..1, 0..63] of SmallInt;
    // Transfers: current address, manual-write FIFO, the time the SPU has
    // written everything it was given, and the time the read FIFO is full.
    FTransferAddress: Cardinal;
    FFIFO: array[0..31] of Word;
    FFIFOCount: Integer;
    FWriteBusyUntil, FReadReadyAt: Int64;
    // Time of the next frame.
    FNextSample: Int64;
    FOutput: TArray<SmallInt>;
    FOutputCount: Integer;
    function Control: Word; inline;
    function Armed: Boolean; inline;
    procedure RaiseIRQ;
    procedure CheckIRQ(Address, Size: Cardinal); inline;
    procedure LoadBlock(Index: Integer);
    procedure KeyOn(Index: Integer);
    procedure TickEnvelope(var V: TPS1SPUVoice; Index: Integer);
    procedure TickVolume(Setting: Word; var Level, Counter: Integer);
    procedure TickVoice(Index: Integer; Noise, Modulate: Boolean; Previous: Integer; out Left, Right: Integer);
    procedure TickNoise;
    function ReverbAddress(Offset: Integer): Cardinal;
    function ReverbRead(Offset: Integer): Integer;
    procedure ReverbWrite(Offset, Value: Integer);
    procedure ReverbStep(InLeft, InRight: Integer; out OutLeft, OutRight: Integer);
    procedure TickReverb(InLeft, InRight: Integer; out OutLeft, OutRight: Integer);
    procedure WriteCapture(Address: Cardinal; Value: Integer);
    procedure Tick;
    procedure FlushFIFO;
    function TransferMode: Integer; inline;
    procedure ScheduleNext;
    procedure Emit(Left, Right: Integer);
  public
    RAM: array[0..PS1SoundRAMSize - 1] of Byte;
    // DMA4 may continue: the SPU can take or supply the next block.
    OnReady: TPS1Notify;
    constructor Create(Scheduler: TPS1Scheduler; const IRQ: TPS1IRQRequest; CDAudio: TPS1CDAudio);
    procedure Reset;
    // Produces every frame due by the current time.
    procedure CatchUp;
    function Read(Address: Cardinal): Word;
    procedure Write(Address: Cardinal; Value: Word);
    procedure Event(Time: Int64);
    function DMARequest(Channel: Integer): Boolean; override;
    procedure DMAWrite(Channel: Integer; Data: PCardinal; Count: Integer); override;
    procedure DMARead(Channel: Integer; Data: PCardinal; Count: Integer); override;
    // Interleaved stereo 44100 Hz samples produced since the last call.
    function TakeSamples: TArray<SmallInt>;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

const
  // Register offsets from 1F801C00h, in halfwords.
  RegVoiceCount = 24;
  RegMainLeft = $180 shr 1;
  RegMainRight = $182 shr 1;
  RegReverbOutLeft = $184 shr 1;
  RegReverbOutRight = $186 shr 1;
  RegKeyOn = $188 shr 1;
  RegKeyOff = $18C shr 1;
  RegPitchModulation = $190 shr 1;
  RegNoise = $194 shr 1;
  RegReverbOn = $198 shr 1;
  RegEndX = $19C shr 1;
  RegReverbBase = $1A2 shr 1;
  RegIRQAddress = $1A4 shr 1;
  RegTransferAddress = $1A6 shr 1;
  RegFIFO = $1A8 shr 1;
  RegControl = $1AA shr 1;
  RegRAMControl = $1AC shr 1;
  RegStatus = $1AE shr 1;
  RegCDLeft = $1B0 shr 1;
  RegCDRight = $1B2 shr 1;
  RegMainCurrentLeft = $1B8 shr 1;
  RegMainCurrentRight = $1BA shr 1;
  RegVoiceCurrent = $200 shr 1;

  // Reverb configuration.
  RvAPFOffset1 = $1C0 shr 1;
  RvAPFOffset2 = $1C2 shr 1;
  RvIIR = $1C4 shr 1;
  RvComb1 = $1C6 shr 1;
  RvComb2 = $1C8 shr 1;
  RvComb3 = $1CA shr 1;
  RvComb4 = $1CC shr 1;
  RvWall = $1CE shr 1;
  RvAPF1 = $1D0 shr 1;
  RvAPF2 = $1D2 shr 1;
  RvSameLeft = $1D4 shr 1;
  RvSameRight = $1D6 shr 1;
  RvCombLeft1 = $1D8 shr 1;
  RvCombRight1 = $1DA shr 1;
  RvCombLeft2 = $1DC shr 1;
  RvCombRight2 = $1DE shr 1;
  RvSameSourceLeft = $1E0 shr 1;
  RvSameSourceRight = $1E2 shr 1;
  RvDiffLeft = $1E4 shr 1;
  RvDiffRight = $1E6 shr 1;
  RvCombLeft3 = $1E8 shr 1;
  RvCombRight3 = $1EA shr 1;
  RvCombLeft4 = $1EC shr 1;
  RvCombRight4 = $1EE shr 1;
  RvDiffSourceLeft = $1F0 shr 1;
  RvDiffSourceRight = $1F2 shr 1;
  RvAPFLeft1 = $1F4 shr 1;
  RvAPFRight1 = $1F6 shr 1;
  RvAPFLeft2 = $1F8 shr 1;
  RvAPFRight2 = $1FA shr 1;
  RvInputLeft = $1FC shr 1;
  RvInputRight = $1FE shr 1;

  // Voice registers.
  VoiceVolumeLeft = 0;
  VoiceVolumeRight = 1;
  VoicePitch = 2;
  VoiceStart = 3;
  VoiceADSR1 = 4;
  VoiceADSR2 = 5;
  VoiceLevel = 6;
  VoiceRepeat = 7;
  ControlCDAudio = $0001;
  ControlCDReverb = $0004;
  ControlIRQ = $0040;
  ControlReverb = $0080;
  ControlUnmute = $4000;
  ControlEnable = $8000;
  PhaseOff = 0;
  PhaseAttack = 1;
  PhaseDecay = 2;
  PhaseSustain = 3;
  PhaseRelease = 4;

  // The SPU moves one halfword between its FIFO and RAM per voice slot, 32
  // cycles (ps1-tests spu/memory-transfer expects about 16 cycles per byte).
  HalfwordCycles = 32;
  // Without an armed IRQ, frames are computed in batches at fixed times.
  BatchCycles = 64 * PS1CyclesPerSample;
  // Output kept for the front end; older frames are dropped.
  OutputLimit = 2 * 44100;
  ADPCMPositive: array[0..4] of Integer = (0, 60, 115, 98, 122);
  ADPCMNegative: array[0..4] of Integer = (0, 0, -52, -55, -60);

  // psx-spx "Reverb Buffer Resampling".
  ReverbFIR: array[0..38] of Integer = (-$0001, 0, $0002, 0, -$000A, 0, $0023, 0, -$0067, 0, $010A, 0,
    -$0268, 0, $0534, 0, -$0B90, 0, $2806, $4000, $2806, 0, -$0B90, 0, $0534, 0, -$0268, 0, $010A, 0,
    -$0067, 0, $0023, 0, -$000A, 0, $0002, 0, -$0001);

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

function Sar(Value: Int64; Count: Integer): Int64; inline;
begin
  if Value < 0 then
    Result := not ((not Value) shr Count)
  else
    Result := Value shr Count;
end;

function Sar32(Value: Integer; Count: Integer): Integer; inline;
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

function Signed(Value: Word): Integer; inline;
begin
  Result := SmallInt(Value);
end;

// psx-spx "Envelope Operation depending on Shift/Step/Mode/Direction", one
// 44100 Hz step. A rate of all ones (Step or Shift shl 2 = 7Fh) never steps.
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
      Delta := Integer(Sar(Delta, 2))
    else if Shift >= 11 then
      Increment := Increment shr 2
    else
    begin
      Delta := Integer(Sar(Delta, 1));
      Increment := Increment shr 1;
    end;
  end
  else if Exponential and Decrease then
    Delta := Integer(Sar(Int64(Delta) * Level, 15));
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

constructor TPS1SPU.Create(Scheduler: TPS1Scheduler; const IRQ: TPS1IRQRequest; CDAudio: TPS1CDAudio);
begin
  inherited Create;
  FScheduler := Scheduler;
  FIRQ := IRQ;
  FCDAudio := CDAudio;
  FCDAudio.BeforeChange := CatchUp;
  Reset;
end;

procedure TPS1SPU.Reset;
begin
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FillChar(FVoices, SizeOf(FVoices), 0);
  FillChar(RAM, SizeOf(RAM), 0);
  FKeyOn := 0;
  FKeyOff := 0;
  FEndX := 0;
  FillChar(FMain, SizeOf(FMain), 0);
  FillChar(FMainCounter, SizeOf(FMainCounter), 0);
  FIRQFlag := False;
  FNoiseLevel := 0;
  FNoiseTimer := 0;
  FCapture := 0;
  FReverbAddress := 0;
  FReverbPhase := 0;
  FReverbPosition := 0;
  FillChar(FReverbIn, SizeOf(FReverbIn), 0);
  FillChar(FReverbOut, SizeOf(FReverbOut), 0);
  FTransferAddress := 0;
  FillChar(FFIFO, SizeOf(FFIFO), 0);
  FFIFOCount := 0;
  FWriteBusyUntil := 0;
  FReadReadyAt := 0;
  FNextSample := FScheduler.Now;
  FOutputCount := 0;
  ScheduleNext;
end;

function TPS1SPU.Control: Word;
begin
  Result := FRegisters[RegControl];
end;

function TPS1SPU.TransferMode: Integer;
begin
  Result := (FRegisters[RegControl] shr 4) and 3;
end;

// The IRQ fires once per acknowledge, and only while the SPU is enabled.
function TPS1SPU.Armed: Boolean;
begin
  Result := ((FRegisters[RegControl] and (ControlEnable or ControlIRQ)) = ControlEnable or ControlIRQ) and
    not FIRQFlag;
end;

procedure TPS1SPU.RaiseIRQ;
begin
  FIRQFlag := True;
  FIRQ(TPS1IRQ.SPU);
end;

// Any access by a voice, the reverb unit, a capture write or a transfer
// within [Address, Address + Size) to the IRQ address.
procedure TPS1SPU.CheckIRQ(Address, Size: Cardinal);
begin
  if Armed and ((Sub32(Cardinal(FRegisters[RegIRQAddress]) * 8, Address) and $7FFFF) < Size) then
    RaiseIRQ;
end;

// The block at the voice's address: loop start flag, IRQ, and 28 decoded
// samples (psx-spx "SPU ADPCM Samples"; shifts 13..15 act as 9, filters
// above 4 are undocumented and use filter 4).
procedure TPS1SPU.LoadBlock(Index: Integer);
begin
  var V: ^TPS1SPUVoice := @FVoices[Index];
  var At := V.Address and $7FFF8;
  V.Address := At;
  var Header := RAM[At];
  V.Flags := RAM[(At + 1) and $7FFFF];
  if (V.Flags and 4) <> 0 then
    FRegisters[Index * 8 + VoiceRepeat] := Word(At shr 3);
  CheckIRQ(At, 16);
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
    var Nibble := (RAM[(At + 2 + Cardinal(J shr 1)) and $7FFFF] shr ((J and 1) * 4)) and $F;
    var Sample := Integer(Nibble) shl 12;
    if Nibble >= 8 then
      Dec(Sample, $10000);
    var Value := Clamp16(Sar32(Sample, Shift) + Sar32(V.Old * F0 + V.Older * F1 + 32, 6));
    V.Older := V.Old;
    V.Old := Value;
    V.Samples[3 + J] := SmallInt(Value);
  end;
end;

procedure TPS1SPU.KeyOn(Index: Integer);
begin
  var V: ^TPS1SPUVoice := @FVoices[Index];
  V.Address := Cardinal(FRegisters[Index * 8 + VoiceStart]) * 8;
  V.Counter := 0;
  V.Old := 0;
  V.Older := 0;
  V.Samples[0] := 0;
  V.Samples[1] := 0;
  V.Samples[2] := 0;
  V.Phase := PhaseAttack;
  V.Level := 0;
  V.EnvelopeCounter := 0;
  LoadBlock(Index);
end;

// psx-spx "SPU Volume and ADSR Generator".
procedure TPS1SPU.TickEnvelope(var V: TPS1SPUVoice; Index: Integer);
begin
  var A1 := FRegisters[Index * 8 + VoiceADSR1];
  var A2 := FRegisters[Index * 8 + VoiceADSR2];
  case V.Phase of
    PhaseAttack:
      begin
        EnvelopeStep(V.Level, V.EnvelopeCounter, (A1 and $8000) <> 0, False, False, (A1 shr 10) and $1F,
          (A1 shr 8) and 3);
        // Decay starts at the peak and ends at or below the sustain level
        // (at once for level 15).
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
      EnvelopeStep(V.Level, V.EnvelopeCounter, (A2 and $8000) <> 0, (A2 and $4000) <> 0, False,
        (A2 shr 8) and $1F, (A2 shr 6) and 3);
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

// Volume registers: bit 15 clear sets the volume (bits 0..14 times two) on
// the next frame; set, it sweeps from the current volume.
procedure TPS1SPU.TickVolume(Setting: Word; var Level, Counter: Integer);
begin
  if (Setting and $8000) = 0 then
    Level := SmallInt(Word(Setting shl 1))
  else
    EnvelopeStep(Level, Counter, (Setting and $4000) <> 0, (Setting and $2000) <> 0, (Setting and $1000) <> 0,
      (Setting shr 2) and $1F, Setting and 3);
end;

// One frame of a voice: interpolated ADPCM (or noise) after the envelope,
// the left/right contributions, then the pitch counter, envelope and sweeps.
// Previous is the output of the voice before (pitch modulation source).
procedure TPS1SPU.TickVoice(Index: Integer; Noise, Modulate: Boolean; Previous: Integer; out Left, Right: Integer);
begin
  var V: ^TPS1SPUVoice := @FVoices[Index];
  var Base := Index * 8;
  Left := 0;
  Right := 0;
  V.Output := 0;
  if (V.Phase <> PhaseOff) or (V.Level <> 0) then
  begin
    var Sample: Integer;
    if Noise then
      Sample := SmallInt(Word(FNoiseLevel))
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
  end;

  // psx-spx "Pitch Counter".
  var Step := Integer(FRegisters[Base + VoicePitch]);
  if Modulate then
    Step := Integer(Sar(Int64(SmallInt(Word(Step))) * (Previous + $8000), 15)) and $FFFF;
  if Step > $3FFF then
    Step := $4000;
  Inc(V.Counter, Cardinal(Step));
  if V.Counter >= 28 shl 12 then
  begin
    Dec(V.Counter, 28 shl 12);
    if (V.Flags and 1) <> 0 then
    begin
      // Loop end: jump to the repeat address; without the repeat flag the
      // voice is released at level zero.
      FEndX := FEndX or (Cardinal(1) shl Index);
      V.Address := Cardinal(FRegisters[Base + VoiceRepeat]) * 8;
      if (V.Flags and 2) = 0 then
      begin
        V.Phase := PhaseRelease;
        V.Level := 0;
      end;
    end
    else
      V.Address := (V.Address + 16) and $7FFFF;
    V.Samples[0] := V.Samples[28];
    V.Samples[1] := V.Samples[29];
    V.Samples[2] := V.Samples[30];
    LoadBlock(Index);
  end;

  TickEnvelope(V^, Index);
  TickVolume(FRegisters[Base + VoiceVolumeLeft], V.Volume[0], V.SweepCounter[0]);
  TickVolume(FRegisters[Base + VoiceVolumeRight], V.Volume[1], V.SweepCounter[1]);
end;

// psx-spx "SPU Noise Generator".
procedure TPS1SPU.TickNoise;
begin
  var C := Control;
  var Step := Integer((C shr 8) and 3) + 4;
  var Shift := (C shr 10) and $F;
  Dec(FNoiseTimer, Step);
  var L := FNoiseLevel;
  var Parity := ((L shr 15) xor (L shr 12) xor (L shr 11) xor (L shr 10) xor 1) and 1;
  if FNoiseTimer < 0 then
  begin
    FNoiseLevel := ((L shl 1) or Parity) and $FFFF;
    Inc(FNoiseTimer, $20000 shr Shift);
    if FNoiseTimer < 0 then
      Inc(FNoiseTimer, $20000 shr Shift);
  end;
end;

// Offsets are relative to the current reverb address and wrap within the
// work area (ESA..7FFFFh).
function TPS1SPU.ReverbAddress(Offset: Integer): Cardinal;
begin
  var Base := Int64(FRegisters[RegReverbBase]) * 8;
  var Size := $80000 - Base;
  var Relative := (Int64(FReverbAddress) - Base + Offset) mod Size;
  if Relative < 0 then
    Inc(Relative, Size);
  Result := Cardinal(Base + Relative) and $7FFFE;
end;

function TPS1SPU.ReverbRead(Offset: Integer): Integer;
begin
  var At := ReverbAddress(Offset);
  CheckIRQ(At, 2);
  Result := SmallInt(Word(RAM[At]) or (Word(RAM[At + 1]) shl 8));
end;

procedure TPS1SPU.ReverbWrite(Offset, Value: Integer);
begin
  var At := ReverbAddress(Offset);
  CheckIRQ(At, 2);
  RAM[At] := Byte(Value);
  RAM[At + 1] := Byte(Value shr 8);
end;

// One 22050 Hz step of psx-spx "Reverb Formula". With the master enable off
// nothing is written and the reflection stages are skipped.
procedure TPS1SPU.ReverbStep(InLeft, InRight: Integer; out OutLeft, OutRight: Integer);
var
  Enabled: Boolean;
  IIR, Wall: Integer;

  function R(Index: Integer): Integer;
  begin
    Result := Integer(FRegisters[Index]) * 8;
  end;

  function V(Index: Integer): Integer;
  begin
    Result := SmallInt(FRegisters[Index]);
  end;

  procedure Reflect(Dest, Source, Input: Integer);
  begin
    var Prev := ReverbRead(R(Dest) - 2);
    var Value := Sar(Int64(Input + Sar32(ReverbRead(R(Source)) * Wall, 15) - Prev) * IIR, 15) + Prev;
    // vIIR = -8000h negates the stored result (psx-spx "Bug").
    if IIR = -$8000 then
      Value := -Value;
    ReverbWrite(R(Dest), Clamp16(Value));
  end;

  function Comb(A, B, C, D: Integer): Integer;
  begin
    Result := Clamp16(Sar(Int64(V(RvComb1)) * ReverbRead(R(A)) + Int64(V(RvComb2)) * ReverbRead(R(B)) +
        Int64(V(RvComb3)) * ReverbRead(R(C)) + Int64(V(RvComb4)) * ReverbRead(R(D)), 15));
  end;

  function AllPass(Value, Dest, Offset, Volume: Integer): Integer;
  begin
    var delayed := ReverbRead((Integer(FRegisters[Dest]) - Integer(FRegisters[Offset])) * 8);
    var Gain := V(Volume);
    var X := Clamp16(Value - Sar32(Gain * delayed, 15));
    if Enabled then
      ReverbWrite(R(Dest), X);
    Result := Clamp16(Sar32(X * Gain, 15) + delayed);
  end;

begin
  Enabled := (Control and ControlReverb) <> 0;
  IIR := V(RvIIR);
  Wall := V(RvWall);
  var LeftIn := Sar32(InLeft * V(RvInputLeft), 15);
  var RightIn := Sar32(InRight * V(RvInputRight), 15);
  if Enabled then
  begin
    Reflect(RvSameLeft, RvSameSourceLeft, LeftIn);
    Reflect(RvSameRight, RvSameSourceRight, RightIn);
    Reflect(RvDiffLeft, RvDiffSourceRight, LeftIn);
    Reflect(RvDiffRight, RvDiffSourceLeft, RightIn);
  end;
  var L := Comb(RvCombLeft1, RvCombLeft2, RvCombLeft3, RvCombLeft4);
  var Rt := Comb(RvCombRight1, RvCombRight2, RvCombRight3, RvCombRight4);
  L := AllPass(AllPass(L, RvAPFLeft1, RvAPFOffset1, RvAPF1), RvAPFLeft2, RvAPFOffset2, RvAPF2);
  Rt := AllPass(AllPass(Rt, RvAPFRight1, RvAPFOffset1, RvAPF1), RvAPFRight2, RvAPFOffset2, RvAPF2);
  OutLeft := Sar32(L * V(RegReverbOutLeft), 15);
  OutRight := Sar32(Rt * V(RegReverbOutRight), 15);

  var Base := Cardinal(FRegisters[RegReverbBase]) * 8;
  FReverbAddress := (FReverbAddress + 2) and $7FFFE;
  if FReverbAddress < Base then
    FReverbAddress := Base;
end;

// The reverb runs at 22050 Hz; its input is filtered down and its output
// (zero-stuffed back to 44100 Hz) filtered up with the 39-tap half-band FIR.
// Without writes, output volume or an armed IRQ the step has no effect and
// only the buffer address moves.
procedure TPS1SPU.TickReverb(InLeft, InRight: Integer; out OutLeft, OutRight: Integer);
begin
  FReverbIn[0, FReverbPosition] := SmallInt(InLeft);
  FReverbIn[1, FReverbPosition] := SmallInt(InRight);
  var StepLeft := 0;
  var StepRight := 0;
  if FReverbPhase = 0 then
  begin
    if ((Control and ControlReverb) <> 0) or (FRegisters[RegReverbOutLeft] <> 0) or
      (FRegisters[RegReverbOutRight] <> 0) or Armed then
    begin
      var SumL: Integer := 0;
      var SumR: Integer := 0;
      var K := 0;
      while K <= 38 do
      begin
        var At := (FReverbPosition - K) and 63;
        Inc(SumL, ReverbFIR[K] * FReverbIn[0, At]);
        Inc(SumR, ReverbFIR[K] * FReverbIn[1, At]);
        Inc(K, 2);
      end;
      var Center := (FReverbPosition - 19) and 63;
      Inc(SumL, ReverbFIR[19] * FReverbIn[0, Center]);
      Inc(SumR, ReverbFIR[19] * FReverbIn[1, Center]);
      ReverbStep(Clamp16(Sar32(SumL, 15)), Clamp16(Sar32(SumR, 15)), StepLeft, StepRight);
    end
    else
    begin
      var Base := Cardinal(FRegisters[RegReverbBase]) * 8;
      FReverbAddress := (FReverbAddress + 2) and $7FFFE;
      if FReverbAddress < Base then
        FReverbAddress := Base;
    end;
  end;
  FReverbOut[0, FReverbPosition] := SmallInt(Clamp16(StepLeft));
  FReverbOut[1, FReverbPosition] := SmallInt(Clamp16(StepRight));

  var SumL: Integer := 0;
  var SumR: Integer := 0;
  var K := 0;
  while K <= 38 do
  begin
    var At := (FReverbPosition - K) and 63;
    Inc(SumL, ReverbFIR[K] * FReverbOut[0, At]);
    Inc(SumR, ReverbFIR[K] * FReverbOut[1, At]);
    Inc(K, 2);
  end;
  var Center := (FReverbPosition - 19) and 63;
  Inc(SumL, ReverbFIR[19] * FReverbOut[0, Center]);
  Inc(SumR, ReverbFIR[19] * FReverbOut[1, Center]);
  OutLeft := Clamp16(Sar32(SumL, 14));
  OutRight := Clamp16(Sar32(SumR, 14));

  FReverbPosition := (FReverbPosition + 1) and 63;
  FReverbPhase := FReverbPhase xor 1;
end;

// Capture buffers: CD audio left/right at 000h/400h, voices 1 and 3 at
// 800h/C00h. Their IRQs need RAM control bits 2..3.
procedure TPS1SPU.WriteCapture(Address: Cardinal; Value: Integer);
begin
  RAM[Address] := Byte(Value);
  RAM[Address + 1] := Byte(Value shr 8);
  if (FRegisters[RegRAMControl] and $C) <> 0 then
    CheckIRQ(Address, 2);
end;

procedure TPS1SPU.Tick;
begin
  if FKeyOff <> 0 then
    for var I := 0 to 23 do
      if (((FKeyOff shr I) and 1) <> 0) and (FVoices[I].Phase <> PhaseOff) then
        FVoices[I].Phase := PhaseRelease;
  if FKeyOn <> 0 then
  begin
    for var I := 0 to 23 do
      if ((FKeyOn shr I) and 1) <> 0 then
        KeyOn(I);
    FEndX := FEndX and not FKeyOn;
  end;
  FKeyOn := 0;
  FKeyOff := 0;

  TickNoise;
  var C := Control;
  var Noise := Cardinal(FRegisters[RegNoise]) or (Cardinal(FRegisters[RegNoise + 1]) shl 16);
  var Modulation := (Cardinal(FRegisters[RegPitchModulation]) or
    (Cardinal(FRegisters[RegPitchModulation + 1]) shl 16)) and $FFFFFE;
  var ReverbOn := Cardinal(FRegisters[RegReverbOn]) or (Cardinal(FRegisters[RegReverbOn + 1]) shl 16);
  var DryL := 0;
  var DryR := 0;
  var WetL := 0;
  var WetR := 0;
  var Previous := 0;
  for var I := 0 to 23 do
  begin
    var L, R: Integer;
    TickVoice(I, ((Noise shr I) and 1) <> 0, ((Modulation shr I) and 1) <> 0, Previous, L, R);
    Previous := FVoices[I].Output;
    Inc(DryL, L);
    Inc(DryR, R);
    if ((ReverbOn shr I) and 1) <> 0 then
    begin
      Inc(WetL, L);
      Inc(WetR, R);
    end;
  end;
  if (C and ControlEnable) = 0 then
  begin
    DryL := 0;
    DryR := 0;
    WetL := 0;
    WetR := 0;
  end;

  // CD audio (after the drive's volume matrix) does not depend on the SPU
  // enable and mute bits.
  var CDL, CDR: Integer;
  FCDAudio.Pop(CDL, CDR);
  var CDOutL := Sar32(CDL * SmallInt(FRegisters[RegCDLeft]), 15);
  var CDOutR := Sar32(CDR * SmallInt(FRegisters[RegCDRight]), 15);
  if (C and ControlCDReverb) <> 0 then
  begin
    Inc(WetL, CDOutL);
    Inc(WetR, CDOutR);
  end;
  if (C and ControlCDAudio) = 0 then
  begin
    CDOutL := 0;
    CDOutR := 0;
  end;

  var Position := Cardinal(FCapture) * 2;
  WriteCapture(Position, CDL);
  WriteCapture($400 + Position, CDR);
  WriteCapture($800 + Position, FVoices[1].Output);
  WriteCapture($C00 + Position, FVoices[3].Output);
  FCapture := (FCapture + 1) and $1FF;

  var RevL, RevR: Integer;
  TickReverb(Clamp16(WetL), Clamp16(WetR), RevL, RevR);
  if (C and ControlUnmute) = 0 then
  begin
    DryL := 0;
    DryR := 0;
    RevL := 0;
    RevR := 0;
  end;
  var OutL := Sar32(Clamp16(Clamp16(DryL) + CDOutL) * FMain[0], 15) + RevL;
  var OutR := Sar32(Clamp16(Clamp16(DryR) + CDOutR) * FMain[1], 15) + RevR;
  Emit(Clamp16(OutL), Clamp16(OutR));
  TickVolume(FRegisters[RegMainLeft], FMain[0], FMainCounter[0]);
  TickVolume(FRegisters[RegMainRight], FMain[1], FMainCounter[1]);
end;

procedure TPS1SPU.Emit(Left, Right: Integer);
begin
  if FOutputCount >= 2 * OutputLimit then
    FOutputCount := 0;
  if FOutputCount + 2 > Length(FOutput) then
    SetLength(FOutput, FOutputCount * 2 + 4096);
  FOutput[FOutputCount] := SmallInt(Left);
  FOutput[FOutputCount + 1] := SmallInt(Right);
  Inc(FOutputCount, 2);
end;

procedure TPS1SPU.CatchUp;
begin
  var Now := FScheduler.Now;
  while FNextSample <= Now do
  begin
    Tick;
    Inc(FNextSample, PS1CyclesPerSample);
  end;
end;

// Frames are due every sample while the IRQ can fire, otherwise at fixed
// batch times; transfers wake DMA4 when the SPU becomes ready.
procedure TPS1SPU.ScheduleNext;
begin
  var Next: Int64;
  if Armed then
    Next := FNextSample
  else
    Next := ((FNextSample + BatchCycles - 1) div BatchCycles) * BatchCycles;
  var Now := FScheduler.Now;
  case TransferMode of
    2:
      if (FWriteBusyUntil > Now) and (FWriteBusyUntil < Next) then
        Next := FWriteBusyUntil;
    3:
      if (FReadReadyAt > Now) and (FReadReadyAt < Next) then
        Next := FReadReadyAt;
  end;
  FScheduler.Schedule(TPS1Event.SPU, Next);
end;

procedure TPS1SPU.Event(Time: Int64);
begin
  CatchUp;
  if (TransferMode >= 2) and DMARequest(4) and Assigned(OnReady) then
    OnReady;
  ScheduleNext;
end;

// Manual write: the FIFO contents go to RAM at the transfer address.
procedure TPS1SPU.FlushFIFO;
begin
  if FFIFOCount = 0 then
    Exit;

  for var I := 0 to FFIFOCount - 1 do
  begin
    var At := FTransferAddress and $7FFFE;
    CheckIRQ(At, 2);
    RAM[At] := Byte(FFIFO[I]);
    RAM[At + 1] := Byte(FFIFO[I] shr 8);
    FTransferAddress := (At + 2) and $7FFFF;
  end;
  var Start := FScheduler.Now;
  if FWriteBusyUntil > Start then
    Start := FWriteBusyUntil;
  FWriteBusyUntil := Start + Int64(FFIFOCount) * HalfwordCycles;
  FFIFOCount := 0;
end;

function TPS1SPU.Read(Address: Cardinal): Word;
begin
  CatchUp;
  var Index := Integer((Address and $3FF) shr 1);
  case Index of
    0..RegVoiceCount * 8 - 1:
      if (Index and 7) = VoiceLevel then
        Result := Word(FVoices[Index shr 3].Level)
      else
        Result := FRegisters[Index];
    RegEndX:
      Result := Word(FEndX);
    RegEndX + 1:
      Result := Word(FEndX shr 16);
    RegStatus:
      begin
        var Now := FScheduler.Now;
        var C := Control;
        Result := C and $3F;
        if FIRQFlag then
          Result := Result or $40;
        if (C and $20) <> 0 then
          Result := Result or $80;
        case TransferMode of
          2:
            if Now >= FWriteBusyUntil then
              Result := Result or $100;
          3:
            if Now >= FReadReadyAt then
              Result := Result or $200;
        end;
        if FWriteBusyUntil > Now then
          Result := Result or $400;
        if ((FRegisters[RegRAMControl] and $C) <> 0) and (FCapture >= $100) then
          Result := Result or $800;
      end;
    RegMainCurrentLeft:
      Result := Word(FMain[0]);
    RegMainCurrentRight:
      Result := Word(FMain[1]);
    RegVoiceCurrent..RegVoiceCurrent + RegVoiceCount * 2 - 1:
      Result := Word(FVoices[(Index - RegVoiceCurrent) shr 1].Volume[(Index - RegVoiceCurrent) and 1]);
  else
    Result := FRegisters[Index];
  end;
end;

procedure TPS1SPU.Write(Address: Cardinal; Value: Word);
begin
  CatchUp;
  var Index := Integer((Address and $3FF) shr 1);
  case Index of
    0..RegVoiceCount * 8 - 1:
      begin
        FRegisters[Index] := Value;
        if (Index and 7) = VoiceLevel then
          FVoices[Index shr 3].Level := SmallInt(Value);
      end;
    RegKeyOn:
      begin
        FRegisters[Index] := Value;
        FKeyOn := FKeyOn or Value;
      end;
    RegKeyOn + 1:
      begin
        FRegisters[Index] := Value;
        FKeyOn := FKeyOn or (Cardinal(Value and $FF) shl 16);
      end;
    RegKeyOff:
      begin
        FRegisters[Index] := Value;
        FKeyOff := FKeyOff or Value;
      end;
    RegKeyOff + 1:
      begin
        FRegisters[Index] := Value;
        FKeyOff := FKeyOff or (Cardinal(Value and $FF) shl 16);
      end;
    // ENDX and SPUSTAT are read-only; current volumes follow the hardware.
      RegEndX, RegEndX + 1, RegStatus, RegMainCurrentLeft, RegMainCurrentRight:
      ;
    RegReverbBase:
      begin
        FRegisters[Index] := Value;
        FReverbAddress := Cardinal(Value) * 8;
      end;
    RegTransferAddress:
      begin
        FRegisters[Index] := Value;
        FTransferAddress := Cardinal(Value) * 8;
      end;
    RegFIFO:
      begin
        FRegisters[Index] := Value;
        // The FIFO holds 32 halfwords; more are written out first.
        if FFIFOCount >= Length(FFIFO) then
          FlushFIFO;
        FFIFO[FFIFOCount] := Value;
        Inc(FFIFOCount);
      end;
    RegControl:
      begin
        var Before := TransferMode;
        FRegisters[Index] := Value;
        // Clearing the IRQ enable acknowledges the IRQ.
        if (Value and ControlIRQ) = 0 then
          FIRQFlag := False;
        case TransferMode of
          1:
            FlushFIFO;
          3:
            // The SPU fills its FIFO before it requests DMA.
            if Before <> 3 then
              FReadReadyAt := FScheduler.Now + Length(FFIFO) * HalfwordCycles;
        end;
        if (TransferMode >= 2) and DMARequest(4) and Assigned(OnReady) then
          OnReady;
      end;
    RegVoiceCurrent..RegVoiceCurrent + RegVoiceCount * 2 - 1:
      FVoices[(Index - RegVoiceCurrent) shr 1].Volume[(Index - RegVoiceCurrent) and 1] := SmallInt(Value);
  else
    FRegisters[Index] := Value;
  end;
  ScheduleNext;
end;

function TPS1SPU.DMARequest(Channel: Integer): Boolean;
begin
  case TransferMode of
    2:
      Result := FScheduler.Now >= FWriteBusyUntil;
    3:
      Result := FScheduler.Now >= FReadReadyAt;
  else
    Result := False;
  end;
end;

// DMA data moves at once; the SPU then needs 32 cycles per halfword before
// it requests the next block.
procedure TPS1SPU.DMAWrite(Channel: Integer; Data: PCardinal; Count: Integer);
begin
  CatchUp;
  for var I := 0 to Count - 1 do
  begin
    var Value := Data^;
    for var Half := 0 to 1 do
    begin
      var At := FTransferAddress and $7FFFE;
      CheckIRQ(At, 2);
      RAM[At] := Byte(Value);
      RAM[At + 1] := Byte(Value shr 8);
      Value := Value shr 16;
      FTransferAddress := (At + 2) and $7FFFF;
    end;
    Inc(Data);
  end;
  var Start := FScheduler.Now;
  if FWriteBusyUntil > Start then
    Start := FWriteBusyUntil;
  FWriteBusyUntil := Start + Int64(Count) * 2 * HalfwordCycles;
  ScheduleNext;
end;

procedure TPS1SPU.DMARead(Channel: Integer; Data: PCardinal; Count: Integer);
begin
  CatchUp;
  for var I := 0 to Count - 1 do
  begin
    var Value: Cardinal := 0;
    for var Half := 0 to 1 do
    begin
      var At := FTransferAddress and $7FFFE;
      CheckIRQ(At, 2);
      Value := Value or ((Cardinal(RAM[At]) or (Cardinal(RAM[At + 1]) shl 8)) shl (Half * 16));
      FTransferAddress := (At + 2) and $7FFFF;
    end;
    Data^ := Value;
    Inc(Data);
  end;
  FReadReadyAt := FScheduler.Now + Int64(Count) * 2 * HalfwordCycles;
  ScheduleNext;
end;

function TPS1SPU.TakeSamples: TArray<SmallInt>;
begin
  CatchUp;
  Result := Copy(FOutput, 0, FOutputCount);
  FOutputCount := 0;
end;

procedure TPS1SPU.SerializeState(State: TStateArchive);
begin
  State.Field(FRegisters, SizeOf(FRegisters));
  State.Field(FVoices, SizeOf(FVoices));
  State.Field(FKeyOn, SizeOf(FKeyOn));
  State.Field(FKeyOff, SizeOf(FKeyOff));
  State.Field(FEndX, SizeOf(FEndX));
  State.Field(FMain, SizeOf(FMain));
  State.Field(FMainCounter, SizeOf(FMainCounter));
  State.Field(FIRQFlag, SizeOf(FIRQFlag));
  State.Field(FNoiseLevel, SizeOf(FNoiseLevel));
  State.Field(FNoiseTimer, SizeOf(FNoiseTimer));
  State.Field(FCapture, SizeOf(FCapture));
  State.Field(FReverbAddress, SizeOf(FReverbAddress));
  State.Field(FReverbPhase, SizeOf(FReverbPhase));
  State.Field(FReverbPosition, SizeOf(FReverbPosition));
  State.Field(FReverbIn, SizeOf(FReverbIn));
  State.Field(FReverbOut, SizeOf(FReverbOut));
  State.Field(FTransferAddress, SizeOf(FTransferAddress));
  State.Field(FFIFO, SizeOf(FFIFO));
  State.Field(FFIFOCount, SizeOf(FFIFOCount));
  State.Field(FWriteBusyUntil, SizeOf(FWriteBusyUntil));
  State.Field(FReadReadyAt, SizeOf(FReadReadyAt));
  State.Field(FNextSample, SizeOf(FNextSample));
  State.Field(RAM, SizeOf(RAM));
  if State.Loading then
  begin
    var Valid := (FFIFOCount >= 0) and (FFIFOCount <= Length(FFIFO)) and (FCapture >= 0) and (FCapture <= $1FF) and
      (FReverbPhase in [0, 1]) and (FReverbPosition >= 0) and (FReverbPosition <= 63) and
      (FReverbAddress < PS1SoundRAMSize) and (FTransferAddress < PS1SoundRAMSize) and (FNextSample >= 0);
    for var I := 0 to 23 do
      Valid := Valid and (FVoices[I].Phase <= PhaseRelease) and (FVoices[I].Counter < 28 shl 12) and
        (FVoices[I].Address < PS1SoundRAMSize);
    if not Valid then
      raise EReadError.Create('PS1 snapshot SPU');
    FOutputCount := 0;
  end;
end;

end.

