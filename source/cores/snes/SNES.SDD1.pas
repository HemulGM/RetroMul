unit SNES.SDD1;

interface

uses
  Core.Snapshots;

type
  TSdd1Read = function(Address: Cardinal): Byte of object;

  TSdd1State = packed record
    AllowDMA, ProcessDMA: Byte;
    Banks: array[0..3] of Byte;
    DMAAddress: array[0..7] of Cardinal;
    DMALength: array[0..7] of Word;
    NeedInit: Boolean;
    ReadAddress: Cardinal;
    BitCount, Bitplanes, ContextBits, BitNumber, Plane: Byte;
    MPSCount: array[0..7] of Byte;
    LPS: array[0..7] of Boolean;
    ContextStatus, ContextMPS: array[0..31] of Byte;
    Previous: array[0..7] of Word;
    OutputMask, Output1, Output2: Byte;
  end;

  TSnesSDD1 = class
  private
    FRead: TSdd1Read;
    function Codeword(Code: Byte): Byte;
    function ProbabilityBit(Context: Byte): Byte;
    function ContextBit: Byte;
  public
    State: TSdd1State;
    constructor Create(Read: TSdd1Read);
    procedure Reset;
    procedure Init(Address: Cardinal);
    function NextByte: Byte;
    function MapROM(Address: Cardinal): Cardinal;
    function Read(Address: Cardinal): Byte;
    function ReadRegister(Address: Word; OpenBus: Byte): Byte;
    procedure Write(Address: Word; Value: Byte);
    procedure SerializeState(Archive: TStateArchive);
  end;

implementation

const
  Evolution: array[0..32, 0..2] of Byte = (
    (0, 25, 25), (0, 2, 1), (0, 3, 1), (0, 4, 2), (0, 5, 3), (1, 6, 4), (1, 7, 5), (1, 8, 6),
    (1, 9, 7), (2, 10, 8), (2, 11, 9), (2, 12, 10), (2, 13, 11), (3, 14, 12), (3, 15, 13),
    (3, 16, 14), (3, 17, 15), (4, 18, 16), (4, 19, 17), (5, 20, 18), (5, 21, 19),
    (6, 22, 20), (6, 23, 21), (7, 24, 22), (7, 24, 23), (0, 26, 1), (1, 27, 2),
    (2, 28, 4), (3, 29, 8), (4, 30, 12), (5, 31, 16), (6, 32, 18), (7, 24, 22));

constructor TSnesSDD1.Create(Read: TSdd1Read);
begin
  inherited Create;
  FRead := Read;
  Reset;
end;

procedure TSnesSDD1.Reset;
begin
  State := Default(TSdd1State);
  State.NeedInit := True;
  for var J := 0 to 3 do
    State.Banks[J] := J;
end;

function TSnesSDD1.MapROM(Address: Cardinal): Cardinal;
begin
  if (Address and $400000) = 0 then
  begin
    var Mask: Cardinal := $3F0000;
    var Bank := 1;
    if (Address and $800000) <> 0 then
      Bank := 3;
    if (State.Banks[Bank] and $80) <> 0 then
      Mask := $1F0000;
    Result := ((Address and Mask) shr 1) or (Address and $7FFF);
  end
  else
    Result := (Cardinal(State.Banks[(Address shr 20) and 3] and 15) shl 20) or (Address and $FFFFF);
end;

function TSnesSDD1.Codeword(Code: Byte): Byte;
begin
  Result := Byte(FRead(State.ReadAddress) shl State.BitCount);
  Inc(State.BitCount);
  if (Result and $80) <> 0 then
  begin
    Result := Result or (FRead(State.ReadAddress + 1) shr (9 - State.BitCount));
    Inc(State.BitCount, Code);
  end;
  if (State.BitCount and 8) <> 0 then
  begin
    Inc(State.ReadAddress);
    State.BitCount := State.BitCount and 7;
  end;
end;

function TSnesSDD1.ProbabilityBit(Context: Byte): Byte;
begin
  var Status := State.ContextStatus[Context];
  var MPS := State.ContextMPS[Context];
  var Code := Evolution[Status, 0];
  if (State.MPSCount[Code] = 0) and not State.LPS[Code] then
  begin
    var WordCode := Codeword(Code);
    if (WordCode and $80) <> 0 then
    begin
      State.LPS[Code] := True;
      // Naive's run_count table is the complemented bit reversal of this code.
      var Index := WordCode shr (Code xor 7);
      var Run := 0;
      for var J := 0 to Integer(Code) - 1 do
        Run := (Run shl 1) or ((Index shr J) and 1);
      State.MPSCount[Code] := ((1 shl Code) - 1) - Run;
    end
    else
      State.MPSCount[Code] := 1 shl Code;
  end;
  if State.MPSCount[Code] > 0 then
  begin
    Result := 0;
    Dec(State.MPSCount[Code]);
  end
  else
  begin
    Result := 1;
    State.LPS[Code] := False;
  end;
  if (State.MPSCount[Code] = 0) and not State.LPS[Code] then
    if Result <> 0 then
    begin
      if Status <= 1 then
        State.ContextMPS[Context] := MPS xor 1;
      State.ContextStatus[Context] := Evolution[Status, 2];
    end
    else
      State.ContextStatus[Context] := Evolution[Status, 1];
  Result := Result xor MPS;
end;

function TSnesSDD1.ContextBit: Byte;
begin
  case State.Bitplanes of
    $00:
      State.Plane := State.Plane xor 1;
    $40:
      begin
        State.Plane := State.Plane xor 1;
        if (State.BitNumber and $7F) = 0 then
          State.Plane := (State.Plane + 2) and 7;
      end;
    $80:
      begin
        State.Plane := State.Plane xor 1;
        if (State.BitNumber and $7F) = 0 then
          State.Plane := State.Plane xor 2;
      end;
    $C0:
      State.Plane := State.BitNumber and 7;
  end;
  var Previous := State.Previous[State.Plane];
  var Context := (State.Plane and 1) shl 4;
  case State.ContextBits of
    $00:
      Context := Context or ((Previous and $1C0) shr 5) or (Previous and 1);
    $10:
      Context := Context or ((Previous and $180) shr 5) or (Previous and 1);
    $20:
      Context := Context or ((Previous and $C0) shr 5) or (Previous and 1);
    $30:
      Context := Context or ((Previous and $180) shr 5) or (Previous and 3);
  end;
  Result := ProbabilityBit(Context);
  State.Previous[State.Plane] := Word((Previous shl 1) or Result);
  State.BitNumber := (Integer(State.BitNumber) + 1) and $FF;
end;

procedure TSnesSDD1.Init(Address: Cardinal);
begin
  State.ReadAddress := Address;
  State.BitCount := 4;
  FillChar(State.MPSCount, SizeOf(State.MPSCount), 0);
  FillChar(State.LPS, SizeOf(State.LPS), 0);
  FillChar(State.ContextStatus, SizeOf(State.ContextStatus), 0);
  FillChar(State.ContextMPS, SizeOf(State.ContextMPS), 0);
  FillChar(State.Previous, SizeOf(State.Previous), 0);
  var Header := FRead(Address);
  State.Bitplanes := Header and $C0;
  State.ContextBits := Header and $30;
  State.BitNumber := 0;
  State.Plane := 0;
  case State.Bitplanes of
    $00:
      State.Plane := 1;
    $40:
      State.Plane := 7;
    $80:
      State.Plane := 3;
  end;
  State.OutputMask := 1;
end;

function TSnesSDD1.NextByte: Byte;
begin
  if State.Bitplanes <> $C0 then
  begin
    if State.OutputMask = 0 then
    begin
      State.OutputMask := $FF;
      Exit(State.Output2);
    end;
    State.Output1 := 0;
    State.Output2 := 0;
    State.OutputMask := $80;
    while State.OutputMask <> 0 do
    begin
      if ContextBit <> 0 then
        State.Output1 := State.Output1 or State.OutputMask;
      if ContextBit <> 0 then
        State.Output2 := State.Output2 or State.OutputMask;
      State.OutputMask := State.OutputMask shr 1;
    end;
  end
  else
  begin
    State.Output1 := 0;
    State.OutputMask := 1;
    while State.OutputMask <> 0 do
    begin
      if ContextBit <> 0 then
        State.Output1 := State.Output1 or State.OutputMask;
      State.OutputMask := Byte(State.OutputMask shl 1);
    end;
  end;
  Result := State.Output1;
end;

function TSnesSDD1.Read(Address: Cardinal): Byte;
begin
  if Address >= $C00000 then
    for var J := 0 to 7 do
      if ((State.AllowDMA and State.ProcessDMA and (1 shl J)) <> 0) and (Address = State.DMAAddress[J]) then
      begin
        if State.NeedInit then
        begin
          Init(Address);
          State.NeedInit := False;
        end;
        Result := NextByte;
        State.DMALength[J] := (Integer(State.DMALength[J]) - 1) and $FFFF;
        if State.DMALength[J] = 0 then
        begin
          State.NeedInit := True;
          State.ProcessDMA := State.ProcessDMA and not (1 shl J);
        end;
        Exit;
      end;
  Result := FRead(Address);
end;

function TSnesSDD1.ReadRegister(Address: Word; OpenBus: Byte): Byte;
begin
  case Address of
    $4800:
      Result := State.AllowDMA;
    $4801:
      Result := State.ProcessDMA;
    $4804..$4807:
      Result := State.Banks[Address and 3];
  else
    Result := OpenBus;
  end;
end;

procedure TSnesSDD1.Write(Address: Word; Value: Byte);
begin
  case Address of
    $4800:
      State.AllowDMA := Value;
    $4801:
      State.ProcessDMA := Value;
    $4804..$4807:
      State.Banks[Address and 3] := Value;
    $4300..$437F:
      begin
        var Channel := (Address shr 4) and 7;
        var Shift: Integer;
        case Address and 15 of
          2..4:
            begin
              Shift := ((Address and 15) - 2) * 8;
              State.DMAAddress[Channel] := (State.DMAAddress[Channel] and not (Cardinal($FF) shl Shift)) or (Cardinal(Value) shl Shift);
            end;
          5..6:
            begin
              Shift := ((Address and 15) - 5) * 8;
              State.DMALength[Channel] := (State.DMALength[Channel] and not (Word($FF) shl Shift)) or (Word(Value) shl Shift);
            end;
        end;
      end;
  end;
end;

procedure TSnesSDD1.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(State, SizeOf(State));
end;

end.

