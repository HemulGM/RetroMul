unit S32.BusProtection;

// Observed FD1149 bus effects and Air Rescue DSP mailbox, from MAME
// segas32_m.cpp (Aaron Giles, BSD-3-Clause). These are behavioural models:
// the undumped FD1149 firmware and the untraced 837-8341 DMA are not executed.
interface

uses
  System.SysUtils, Core.Snapshots;

type
  TS32BusProtectionKind = (bpNone, bpSonic, bpBrival, bpDarkEdge, bpDBZ,
    bpF1Lap, bpJLeague, bpAirRescue);

  TS32WorkRAM = array[0..65535] of Byte;

  PS32WorkRAM = ^TS32WorkRAM;

  TS32BusProtection = class
  private
    FKind: TS32BusProtectionKind;
    FRAM: PS32WorkRAM;
    FROM: TBytes;
    FMailbox: array[0..3] of Word;
    FResult: array[0..$FFF] of Byte;
    procedure DSPAcknowledge;
  public
    constructor Create(Kind: TS32BusProtectionKind; RAM: PS32WorkRAM; const ROM: TBytes);
    procedure Reset;
    function ReadWord(Address: Cardinal; out Value: Word): Boolean;
    function ReadByte(Address: Cardinal; out Value: Byte): Boolean;
    function Write(Address: Cardinal; Value, Mask: Word): Boolean;
    procedure WorkRAMWritten(Offset: Cardinal);
    procedure VBlank;
    procedure SerializeState(State: TStateArchive);
    function ReadAchievementRAM(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;
  end;

implementation

uses
  Core.Emulation.Types;

const
  // Read back from a working 317-0217 by Charles MacDonald; s32tech.txt.
  DBZ_READBACK: array[0..15] of Byte = ($0A, $40, $03, $94, $02, $22, $93, $02, $00, $00, $20, $0C, $C8, $80, $00, $00);

function TS32BusProtection.ReadAchievementRAM(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;
begin
  // FBNeo reuses DrvV25RAM for these two devices. Read the backing storage
  // directly because a CPU read of Air Rescue's mailbox can acknowledge a command.
  case FKind of
    bpAirRescue:
      Result := ReadAchievementMemoryBlock(Address, Buffer, Count, @FMailbox, SizeOf(FMailbox));
    bpBrival:
      Result := ReadAchievementMemoryBlock(Address, Buffer, Count, @FResult, SizeOf(FResult));
  else
    Result := 0;
  end;
end;

constructor TS32BusProtection.Create(Kind: TS32BusProtectionKind; RAM: PS32WorkRAM; const ROM: TBytes);
begin
  inherited Create;
  FKind := Kind;
  FRAM := RAM;
  FROM := ROM;
  Reset;
end;

procedure TS32BusProtection.Reset;
begin
  FillChar(FMailbox, SizeOf(FMailbox), 0);
  FillChar(FResult, SizeOf(FResult), 0);
end;

procedure TS32BusProtection.DSPAcknowledge;
begin
  case FMailbox[0] of
    3:
      begin
        FMailbox[0] := $8000;
        FMailbox[1] := 1;
      end;
    6:
      FMailbox[0] := Word(4 * FMailbox[1]);
  end;
end;

function TS32BusProtection.ReadWord(Address: Cardinal; out Value: Word): Boolean;
begin
  Result := True;
  Value := $FFFF;
  case FKind of
    bpBrival:
      if (Address = $20BA00) or (Address = $20BA04) or (Address = $20BA06) then
        Value := 0
      else
        Result := False;
    bpDarkEdge:
      Result := (Address >= $A00000) and (Address < $A80000);
    bpDBZ:
      begin
        Result := (Address >= $A00000) and (Address < $A80000);
        if Result then
        begin
          Value := Word(DBZ_READBACK[Address and 15]) or (Word(DBZ_READBACK[(Address + 1) and 15]) shl 8);
          if Address and 15 = 0 then
            Value := Value or (Word(FResult[1]) shl 8);
        end;
      end;
    bpAirRescue:
      if (Address >= $A00000) and (Address < $A00008) then
      begin
        if Address = $A00004 then
          DSPAcknowledge;
        Value := FMailbox[(Address shr 1) and 3];
      end
      else
        Result := False;
  else
    Result := False;
  end;
end;

function TS32BusProtection.ReadByte(Address: Cardinal; out Value: Byte): Boolean;
begin
  Result := (FKind = bpAirRescue) and (Address >= $A00000) and (Address < $A00008);
  Value := $FF;
  if (FKind = bpDBZ) and (Address >= $A00000) and (Address < $A80000) then
  begin
    Value := DBZ_READBACK[Address and 15];
    if Address and 15 = 1 then
      Value := Value or FResult[1];
    Exit(True);
  end;
  if Result then
  begin
    if Address and $FFFFFE = $A00004 then
      DSPAcknowledge;
    Value := Byte(FMailbox[(Address shr 1) and 3] shr (8 * (Address and 1)));
  end;
end;

function TS32BusProtection.Write(Address: Cardinal; Value, Mask: Word): Boolean;
const
  Sources: array[0..5] of Cardinal = ($109517, $109597, $109597, $109597, $109597, $109617);
begin
  Result := False;
  if (Address < $A00000) or (Address >= $A80000) then
    Exit;
  case FKind of
    bpDBZ:
      begin
        FRAM[$80C8] := FRAM[$44];
        FRAM[$80C9] := FRAM[$45];
        // The power-on readback is not the command-complete status. The
        // V60 polls bit 15 after submitting a command; acknowledge it only
        // after applying the observed bus-master write above.
        FResult[1] := $80;
        Result := True;
      end;
    bpDarkEdge:
      Result := True;
    bpBrival:
      if Address < $A01000 then
      begin
        Result := True;
        var Off := Address and $FFF;
        if Mask and $FF <> 0 then
          FResult[Off] := Byte(Value);
        if Mask and $FF00 <> 0 then
          FResult[Off + 1] := Byte(Value shr 8);
        if (Off >= $800) and (Off <= $80A) then
        begin
          var Index := (Off - $800) shr 1;
          if Sources[Index] + 16 <= Cardinal(Length(FROM)) then
            Move(FROM[Sources[Index]], FResult[Index * $10], 16);
        end;
      end;
    bpAirRescue:
      if Address < $A00008 then
      begin
        Result := True;
        var Index := (Address shr 1) and 3;
        FMailbox[Index] := (FMailbox[Index] and not Mask) or (Value and Mask);
      end;
  end;
end;

procedure TS32BusProtection.WorkRAMWritten(Offset: Cardinal);
begin
  Offset := Offset and $FFFE;
  if (FKind = bpSonic) and (Offset = $E5C4) then
  begin
    var Cleared := Word(FRAM[$E5C4]) or (Word(FRAM[$E5C5]) shl 8);
    var Level: Word := 7;
    var Table: Cardinal := $263A + Cardinal(Cleared) * 2;
    if (Cleared <> 0) and (Table <= Cardinal(Length(FROM))) then
      Level := (Word(FROM[Table - 2]) shl 8) or FROM[Table - 1];
    FRAM[$F06E] := Byte(Level);
    FRAM[$F06F] := Byte(Level shr 8);
    FillChar(FRAM[$F0BC], 4, 0);
  end;
  if FKind = bpJLeague then
    case Offset of
      $F700:
        begin
          var Selection := Word(FRAM[$F700]) or (Word(FRAM[$F701]) shl 8);
          var Source: Cardinal := $7BBC0 + Cardinal(Selection) * 2;
          if Source < Cardinal(Length(FROM)) then
            FRAM[$F708] := FROM[Source];
        end;
      $F704:
        FRAM[$16] := FRAM[$F704];
    end;
end;

procedure TS32BusProtection.VBlank;
begin
  case FKind of
    bpDarkEdge:
      begin
        FRAM[$F072] := 0;
        FRAM[$F073] := 0;
        FRAM[$F082] := 0;
        FRAM[$F083] := 0;
        if FRAM[$A12C] <> 0 then
        begin
          Dec(FRAM[$A12C]);
          if FRAM[$A12C] = 0 then
            FRAM[$A12E] := 1;
        end;
      end;
    bpF1Lap:
      begin
        FRAM[$F7C6] := 0;
        if FRAM[$EE81] = $FF then
          FRAM[$EE81] := 0;
      end;
  end;
end;

procedure TS32BusProtection.SerializeState(State: TStateArchive);
begin
  State.Field(FMailbox, SizeOf(FMailbox));
  State.Field(FResult, SizeOf(FResult));
end;

end.

