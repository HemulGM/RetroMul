unit NES.Mapper.VrcAudio;

interface

uses
  System.Math, NES.State, NES.Types, NES.Mapper, NES.Mapper.Vrc;

type
  TMapperVrcAudio = class(TMapperVrc)
  protected
    FMode: Integer;
    FChrRegs: array[0..7] of Byte;
    FNameBanks: array[0..3] of Integer;
    FNameRam: array[0..$7FF] of Byte;
    FAudioRegs: array[0..2, 0..2] of Byte;
    FTimers, FSteps, FOutputs: array[0..2] of Integer;
    FAccumulator, FAudioControl: Integer;
    FFmAddress, FFmDivider: Integer;
    FFmRegs: array[0..$3F] of Byte;
    FFmPhase, FFmEnvelope, FFmFeedback: array[0..11] of Double;
    FFmStage: array[0..11] of Integer;
    FFmOutput: Double;
    procedure UpdatePpu;
    procedure WriteIrq(Reg: Integer; Value: Byte);
    procedure ClockPulseAudio;
    procedure ClockFm;
  public
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockCpu; override;
    function ExpansionAudio: Double; override;
  end;

implementation

// VRC7 uses a six-channel, two-operator FM model. Its envelopes are currently
// approximate; hardware LFO and key scaling remain to be implemented.

constructor TMapperVrcAudio.Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Board, Prg, Chr, HasChrRam, MirrorMode);
  Reset
end;

procedure TMapperVrcAudio.Reset;
begin
  inherited;
  FMode := 0;
  FAudioControl := 0;
  FAccumulator := 0;
  FFmAddress := 0;
  FFmDivider := 0;
  FFmOutput := 0;
  FillChar(FChrRegs, SizeOf(FChrRegs), 0);
  FillChar(FAudioRegs, SizeOf(FAudioRegs), 0);
  FillChar(FOutputs, SizeOf(FOutputs), 0);
  FillChar(FSteps, SizeOf(FSteps), 0);
  FillChar(FFmRegs, SizeOf(FFmRegs), 0);
  FillChar(FFmPhase, SizeOf(FFmPhase), 0);
  FillChar(FFmEnvelope, SizeOf(FFmEnvelope), 0);
  FillChar(FFmStage, SizeOf(FFmStage), 0);
  FillChar(FFmFeedback, SizeOf(FFmFeedback), 0);
  for var i := 0 to 2 do
    FTimers[i] := 1;
  if FBoard = MAPPER_VRC7 then
  begin
    Mirror(0);
    FRamEnabled := False;
    for var i := 0 to 7 do
      Chr1(i, 0)
  end
  else
    UpdatePpu;
end;

procedure TMapperVrcAudio.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FMode, SizeOf(FMode));
  State.Field(FChrRegs, SizeOf(FChrRegs));
  State.Field(FNameBanks, SizeOf(FNameBanks));
  State.Field(FNameRam, SizeOf(FNameRam));
  State.Field(FAudioRegs, SizeOf(FAudioRegs));
  State.Field(FTimers, SizeOf(FTimers));
  State.Field(FSteps, SizeOf(FSteps));
  State.Field(FOutputs, SizeOf(FOutputs));
  State.Field(FAccumulator, SizeOf(FAccumulator));
  State.Field(FAudioControl, SizeOf(FAudioControl));
  State.Field(FFmAddress, SizeOf(FFmAddress));
  State.Field(FFmDivider, SizeOf(FFmDivider));
  State.Field(FFmRegs, SizeOf(FFmRegs));
  State.Field(FFmPhase, SizeOf(FFmPhase));
  State.Field(FFmEnvelope, SizeOf(FFmEnvelope));
  State.Field(FFmStage, SizeOf(FFmStage));
  State.Field(FFmFeedback, SizeOf(FFmFeedback));
  State.Field(FFmOutput, SizeOf(FFmOutput));
end;

procedure TMapperVrcAudio.UpdatePpu;
begin
  var Mask := $FF;
  var Extra := 0;
  if (FMode and $20) <> 0 then
  begin
    Mask := $FE;
    Extra := 1
  end;
  for var i := 0 to 7 do
    case FMode and 3 of
      0:
        Chr1(i, FChrRegs[i]);
      1:
        Chr1(i, (FChrRegs[i shr 1] and Mask) or ((i and 1) * Extra));
      2, 3:
        if i < 4 then
          Chr1(i, FChrRegs[i])
        else
          Chr1(i, (FChrRegs[4 + ((i - 4) shr 1)] and Mask) or ((i and 1) * Extra));
    end;
  for var i := 0 to 3 do
    case FMode and $2F of
      $20, $27:
        FNameBanks[i] := (FChrRegs[6 + (i shr 1)] and $FE) or (i and 1);
      $23, $24:
        FNameBanks[i] := (FChrRegs[6 + (i and 1)] and $FE) or (i shr 1);
      $28, $2F:
        FNameBanks[i] := FChrRegs[6] and $FE;
      $2B, $2C:
        FNameBanks[i] := (FChrRegs[6] and $FE) or 1;
    else
      case FMode and 7 of
        0, 6, 7:
          FNameBanks[i] := FChrRegs[6 + (i shr 1)];
        1, 5:
          FNameBanks[i] := FChrRegs[4 + i];
        2, 3, 4:
          FNameBanks[i] := FChrRegs[6 + (i and 1)];
      end;
    end;
  FRamEnabled := (FMode and $80) <> 0;
end;

procedure TMapperVrcAudio.WriteIrq(Reg: Integer; Value: Byte);
begin
  case Reg of
    0:
      FLatch := Value;
    1:
      begin
        FControl := Value and 7;
        FPending := False;
        if (FControl and 2) <> 0 then
        begin
          FCounter := FLatch;
          FPrescaler := 341
        end
      end;
    2:
      begin
        FPending := False;
        FControl := (FControl and 5) or ((FControl and 1) shl 1)
      end;
  end;
end;

function TMapperVrcAudio.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address < $8000 then
    Exit(inherited CpuWrite(Address, Value));

  if FBoard = MAPPER_VRC7 then
  begin
    if ((Address and $10) <> 0) and ((Address and $F010) <> $9010) then
      Address := (Address or 8) and $FFEF;
    case Address and $F038 of
      $8000:
        Prg8(0, Value and $3F);
      $8008:
        Prg8(1, Value and $3F);
      $9000:
        Prg8(2, Value and $3F);
      $9010:
        FFmAddress := Value and $3F;
      $9030:
        begin
          var Old := FFmRegs[FFmAddress];
          FFmRegs[FFmAddress] := Value;
          if (FFmAddress >= $20) and (FFmAddress <= $25) and ((Old xor Value) and $10 <> 0) then
          begin
            var Ch := FFmAddress - $20;
            for var Op := Ch * 2 to Ch * 2 + 1 do
              if (Value and $10) <> 0 then
              begin
                FFmStage[Op] := 1;
                FFmPhase[Op] := 0;
                FFmEnvelope[Op] := 0
              end
              else
                FFmStage[Op] := 4;
          end;
        end;
      $A000, $A008, $B000, $B008, $C000, $C008, $D000, $D008:
        Chr1(((Address shr 12) - 10) * 2 + ((Address shr 3) and 1), Value);
      $E000:
        begin
          FMode := Value;
          Mirror(Value and 3);
          FRamEnabled := (Value and $80) <> 0
        end;
      $E008:
        WriteIrq(0, Value);
      $F000:
        WriteIrq(1, Value);
      $F008:
        WriteIrq(2, Value);
    end;
    Exit(True);
  end;

  if FBoard = MAPPER_VRC6B then
    Address := (Address and $FFFC) or ((Address and 1) shl 1) or ((Address and 2) shr 1);
  case Address and $F003 of
    $8000..$8003:
      Prg16(0, Value and 15);
    $9003:
      FAudioControl := Value;
    $9000..$9002, $A000..$A002, $B000..$B002:
      begin
        var Ch := (Address shr 12) - 9;
        var Reg := Address and 3;
        FAudioRegs[Ch, Reg] := Value;
        if (Reg = 2) and ((Value and $80) = 0) then
        begin
          FSteps[Ch] := 0;
          if Ch = 2 then
            FAccumulator := 0
        end;
      end;
    $B003:
      begin
        FMode := Value;
        UpdatePpu
      end;
    $C000..$C003:
      Prg8(2, Value and 31);
    $D000..$D003, $E000..$E003:
      begin
        FChrRegs[((Address shr 12) - 13) * 4 + (Address and 3)] := Value;
        UpdatePpu
      end;
    $F000..$F002:
      WriteIrq(Address and 3, Value);
  end;
  Result := True;
end;

function TMapperVrcAudio.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FBoard <> MAPPER_VRC7) and (Address >= $2000) and (Address < $3F00) then
  begin
    var Bank := FNameBanks[(Address shr 10) and 3];
    if (FMode and $10) <> 0 then
      Value := FChrMemory[(Bank * $400 + (Address and $3FF)) mod Length(FChrMemory)]
    else
      Value := FNameRam[(Bank and 1) * $400 + (Address and $3FF)];
    Exit(True);
  end;

  Result := inherited;
end;

function TMapperVrcAudio.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (FBoard <> MAPPER_VRC7) and (Address >= $2000) and (Address < $3F00) then
  begin
    var Bank := FNameBanks[(Address shr 10) and 3];
    if (FMode and $10) = 0 then
      FNameRam[(Bank and 1) * $400 + (Address and $3FF)] := Value
    else if FHasChrRam then
      FChrMemory[(Bank * $400 + (Address and $3FF)) mod Length(FChrMemory)] := Value;
    Exit(True);
  end;

  Result := inherited;
end;

procedure TMapperVrcAudio.ClockPulseAudio;
begin
  if (FAudioControl and 1) = 0 then
    for var Ch := 0 to 2 do
      if (FAudioRegs[Ch, 2] and $80) <> 0 then
      begin
        Dec(FTimers[Ch]);
        if FTimers[Ch] <= 0 then
        begin
          var Shift := 0;
          if (FAudioControl and 4) <> 0 then
            Shift := 8
          else if (FAudioControl and 2) <> 0 then
            Shift := 4;
          FTimers[Ch] := ((FAudioRegs[Ch, 1] or ((FAudioRegs[Ch, 2] and 15) shl 8)) shr Shift) + 1;
          if Ch < 2 then
            FSteps[Ch] := (FSteps[Ch] + 1) and 15
          else
          begin
            FSteps[Ch] := (FSteps[Ch] + 1) mod 14;
            if FSteps[Ch] = 0 then
              FAccumulator := 0
            else if (FSteps[Ch] and 1) = 0 then
              FAccumulator := (FAccumulator + (FAudioRegs[Ch, 0] and $3F)) and $FF
          end;
        end;
      end;
  for var Ch := 0 to 2 do
  begin
    FOutputs[Ch] := 0;
    if (FAudioRegs[Ch, 2] and $80) <> 0 then
      if Ch = 2 then
        FOutputs[Ch] := FAccumulator shr 3
      else if ((FAudioRegs[Ch, 0] and $80) <> 0) or (FSteps[Ch] <= ((FAudioRegs[Ch, 0] shr 4) and 7)) then
        FOutputs[Ch] := FAudioRegs[Ch, 0] and 15;
  end;
end;

procedure TMapperVrcAudio.ClockFm;
const
  Instruments: array[1..15, 0..7] of Byte = (
    ($03, $21, $05, $06, $E8, $81, $42, $27),
    ($13, $41, $14, $0D, $D8, $F6, $23, $12),
    ($11, $11, $08, $08, $FA, $B2, $20, $12),
    ($31, $61, $0C, $07, $A8, $64, $61, $27),
    ($32, $21, $1E, $06, $E1, $76, $01, $28),
    ($02, $01, $06, $00, $A3, $E2, $F4, $F4),
    ($21, $61, $1D, $07, $82, $81, $11, $07),
    ($23, $21, $22, $17, $A2, $72, $01, $17),
    ($35, $11, $25, $00, $40, $73, $72, $01),
    ($B5, $01, $0F, $0F, $A8, $A5, $51, $02),
    ($17, $C1, $24, $07, $F8, $F8, $22, $12),
    ($71, $23, $11, $06, $65, $74, $18, $16),
    ($01, $02, $D3, $05, $C9, $95, $03, $02),
    ($61, $63, $0C, $00, $94, $C0, $33, $F6),
    ($21, $72, $0D, $00, $C1, $D5, $56, $06));
  Multipliers: array[0..15] of Double = (0.5, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 12, 12, 15, 15);
begin
  Inc(FFmDivider);
  if FFmDivider < 36 then
    Exit;

  FFmDivider := 0;
  FFmOutput := 0;
  if (FMode and $40) <> 0 then
    Exit;

  for var Ch := 0 to 5 do
  begin
    var Patch: array[0..7] of Byte;
    var Instrument := FFmRegs[$30 + Ch] shr 4;
    if Instrument = 0 then
      Move(FFmRegs[0], Patch[0], 8)
    else
      Move(Instruments[Instrument, 0], Patch[0], 8);
    var Frequency := (FFmRegs[$10 + Ch] or ((FFmRegs[$20 + Ch] and 1) shl 8)) * Power(2, (FFmRegs[$20 + Ch] shr 1) and 7) * (49715.909 / 524288.0);
    var Modulator := 0.0;
    for var Op := 0 to 1 do
    begin
      var Index := Ch * 2 + Op;
      var Sustain := Power(10, -(Patch[6 + Op] shr 4) * 3 / 20.0);
      var Attack := Patch[4 + Op] shr 4;
      var Decay := Patch[4 + Op] and 15;
      var Release := Patch[6 + Op] and 15;
      if (FFmRegs[$20 + Ch] and $20) <> 0 then
        Release := 5;
      case FFmStage[Index] of
        1:
          if Attack > 0 then
          begin
            FFmEnvelope[Index] := FFmEnvelope[Index] + (1 - FFmEnvelope[Index]) * Power(2, Attack - 15) * 0.5;
            if FFmEnvelope[Index] >= 0.999 then
              FFmStage[Index] := 2
          end;
        2:
          begin
            FFmEnvelope[Index] := Max(Sustain, FFmEnvelope[Index] - Power(2, Decay - 15) * 0.002);
            if FFmEnvelope[Index] <= Sustain then
              FFmStage[Index] := 3
          end;
        3:
          if (Patch[Op] and $20) = 0 then
            FFmEnvelope[Index] := Max(0, FFmEnvelope[Index] - Power(2, Release - 15) * 0.002);
        4:
          FFmEnvelope[Index] := Max(0, FFmEnvelope[Index] - Power(2, Release - 15) * 0.002);
      end;
      FFmPhase[Index] := FFmPhase[Index] + Frequency * Multipliers[Patch[Op] and 15] * (2 * Pi * 36 / 1789772.5);
      FFmPhase[Index] := FFmPhase[Index] - Floor(FFmPhase[Index] / (2 * Pi)) * 2 * Pi;
      var Level: Double;
      if Op = 0 then
        Level := Power(10, -(Patch[2] and $3F) * 0.75 / 20.0)
      else
        Level := Power(10, -(FFmRegs[$30 + Ch] and 15) * 3 / 20.0);
      var Phase := FFmPhase[Index];
      if Op = 0 then
        Phase := Phase + FFmFeedback[Index] * ((Patch[3] and 7) / 4.0)
      else
        Phase := Phase + Modulator * 4;
      var Sample := Sin(Phase);
      if (Patch[3] and ($8 shl Op)) <> 0 then
        Sample := Max(0, Sample);
      Sample := Sample * FFmEnvelope[Index] * Level;
      if Op = 0 then
      begin
        Modulator := Sample;
        FFmFeedback[Index] := Sample
      end
      else
        FFmOutput := FFmOutput + Sample / 24;
    end;
  end;
end;

procedure TMapperVrcAudio.ClockCpu;
begin
  inherited;
  if FBoard = MAPPER_VRC7 then
    ClockFm
  else
    ClockPulseAudio
end;

function TMapperVrcAudio.ExpansionAudio: Double;
begin
  if FBoard = MAPPER_VRC7 then
    Result := FFmOutput
  else
    Result := (FOutputs[0] + FOutputs[1] + FOutputs[2]) / 240.0;
end;

end.

