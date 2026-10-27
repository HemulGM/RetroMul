unit MSX.MapperAnalysis;

interface

uses
  System.SysUtils;

type
  TMSXCodeWrite = record
    Offset: Integer;
    PC, Address: Word;
    Depth: Integer;
    Indexed: Boolean;
    Value: SmallInt; // -1 when the value cannot be proven statically.
  end;

  TMSXCodeAnalysis = record
    EntryPoints, Instructions: Integer;
    Limited: Boolean;
    Writes: TArray<TMSXCodeWrite>;
  end;

// Read-only, bounded control-flow analysis. This does not execute a cartridge.
function AnalyzeMSXCode(const Data: TBytes): TMSXCodeAnalysis;

implementation

uses
  System.Generics.Collections, System.Math;

type
  TCodeCopy = record
    Source, Destination, Count: Integer;
  end;

  TCodeState = record
    Offset, PC: Integer;
    R: array[0..7] of Integer; // Z80 B,C,D,E,H,L,(HL),A; -1 means unknown.
    IX, IY, Depth, Family: Integer;
    Banks: array[0..3] of Integer;
    Controls: array[0..3] of Integer;
  end;

function AnalyzeMSXCode(const Data: TBytes): TMSXCodeAnalysis;
const
  MaxInstructions = 131072;
  MaxStatesPerLocation = 8;
  MaxWrites = 1024;
var
  Queue: TList<TCodeState>;
  Seen, Written: TDictionary<UInt64, Byte>;
  Writes: TList<TMSXCodeWrite>;
  Visits: TDictionary<Integer, Byte>;
  Copies: TList<TCodeCopy>;
  State: TCodeState;
  Analysis: TMSXCodeAnalysis;
  Head: Integer;

  function Pair(Index: Integer): Integer;
  begin
    Result := -1;
    if (State.R[Index] >= 0) and (State.R[Index + 1] >= 0) then
      Result := State.R[Index] * 256 + State.R[Index + 1];
  end;

  procedure SetPair(Index, Value: Integer);
  begin
    State.R[Index] := -1;
    State.R[Index + 1] := -1;
    if Value >= 0 then
    begin
      State.R[Index] := (Value shr 8) and 255;
      State.R[Index + 1] := Value and 255;
    end;
  end;

  procedure UnknownRegisters;
  begin
    for var I := 0 to 7 do
      State.R[I] := -1;
    State.IX := -1;
    State.IY := -1;
  end;

  procedure WriteAt(Address, Value: Integer; Indexed: Boolean = False);
  var
    Key: UInt64;
    W: TMSXCodeWrite;
  begin
    if (Address < $4000) or (Address >= $C000) then
      Exit;
    Key := UInt64(State.Offset) shl 24 or UInt64(State.PC shr 13) shl 16 or Cardinal(Address);
    if Written.Count >= MaxWrites then
      Analysis.Limited := True
    else if not Written.ContainsKey(Key) then
    begin
      Written.Add(Key, 0);
      W.Offset := State.Offset;
      W.PC := State.PC;
      W.Address := Address;
      W.Value := Value;
      W.Depth := State.Depth;
      W.Indexed := Indexed;
      Writes.Add(W);
    end;
    if (Address >= $6000) and (Address < $8000) then
      State.Controls[(Address - $6000) shr 11] := Value;
    if State.Family = 0 then
    begin
      if ((Address >= $6800) and (Address < $7000)) or ((Address >= $7800) and (Address < $8000)) then
        State.Family := 1
      else if ((Address >= $5000) and (Address < $5800)) or
        ((Address >= $9000) and (Address < $9800)) or
        ((Address >= $B000) and (Address < $B800)) then
        State.Family := 4
      else if (Address >= $8000) and (Address < $B000) then
        State.Family := 3
      else if (State.Controls[0] >= 0) and (State.Controls[2] >= 0) then
        State.Family := 2;
      if (State.Family = 3) and (State.Controls[0] >= 0) then
        State.Banks[1] := State.Controls[0];
      if (State.Family = 4) and (State.Controls[2] >= 0) then
        State.Banks[1] := State.Controls[2];
      if State.Family in [1, 2] then
      begin
        for var I := 0 to 3 do
          State.Banks[I] := 0;
        if State.Family = 1 then
        begin
          for var I := 0 to 3 do
            if State.Controls[I] >= 0 then
              State.Banks[I] := State.Controls[I];
        end
        else
        begin
          for var I := 0 to 1 do
            if State.Controls[I * 2] >= 0 then
            begin
              State.Banks[I * 2] := State.Controls[I * 2] * 2;
              State.Banks[I * 2 + 1] := State.Controls[I * 2] * 2 + 1;
            end;
        end;
      end;
    end;
    case State.Family of
      1:
        if (Address >= $6000) and (Address < $8000) then
          State.Banks[(Address - $6000) shr 11] := Value;
      2:
        if (Address >= $6000) and (Address < $7800) and (Address and $800 = 0) then
        begin
          var Page := ((Address - $6000) shr 12) * 2;
          if Value < 0 then
          begin
            State.Banks[Page] := -1;
            State.Banks[Page + 1] := -1;
          end
          else
          begin
            State.Banks[Page] := Value * 2;
            State.Banks[Page + 1] := Value * 2 + 1;
          end;
        end;
      3:
        if Address >= $6000 then
          State.Banks[(Address - $4000) shr 13] := Value;
      4:
        if Address and $1800 = $1000 then
          State.Banks[(Address - $4000) shr 13] := Value;
    end;
  end;

  procedure Enqueue(Offset, PC: Integer; const Registers: TCodeState);
  var
    S: TCodeState;
    Location: Integer;
    Count: Byte;
    Signature: Cardinal;
    Key: UInt64;
  begin
    if (Offset < 0) or (Offset >= Length(Data)) or (PC < 0) or (PC > $FFFF) then
      Exit;
    Location := Offset * 8 + (PC shr 13);
    Count := 0;
    Visits.TryGetValue(Location, Count);
    Signature := 2166136261;
    for var V in Registers.Controls do
      Signature := Cardinal((UInt64(Signature xor Cardinal(V + 1)) * 16777619) and $FFFFFFFF);
    Signature := Cardinal((UInt64(Signature xor Cardinal(Registers.Family)) * 16777619) and $FFFFFFFF);
    for var V in Registers.Banks do
      Signature := Cardinal((UInt64(Signature xor Cardinal(V + 1)) * 16777619) and $FFFFFFFF);
    for var V in Registers.R do
      Signature := Cardinal((UInt64(Signature xor Cardinal(V + 1)) * 16777619) and $FFFFFFFF);
    Signature := Cardinal((UInt64(Signature xor Cardinal(Registers.IX + 1)) * 16777619) and $FFFFFFFF);
    Signature := Cardinal((UInt64(Signature xor Cardinal(Registers.IY + 1)) * 16777619) and $FFFFFFFF);
    Key := UInt64(Signature) shl 32 or Cardinal(Location);
    var OldDepth: Byte;
    if Seen.TryGetValue(Key, OldDepth) and (OldDepth <= Registers.Depth) then
      Exit;
    if Count >= MaxStatesPerLocation then
    begin
      Analysis.Limited := True;
      Exit;
    end;
    if Queue.Count >= MaxInstructions then
    begin
      Analysis.Limited := True;
      Exit;
    end;
    Seen.AddOrSetValue(Key, Byte(Min(255, Registers.Depth)));
    Visits.AddOrSetValue(Location, Count + 1);
    S := Registers;
    S.Offset := Offset;
    S.PC := PC;
    Queue.Add(S);
  end;

  procedure Target(PC: Integer);
  begin
    PC := PC and $FFFF;
    if (PC >= $4000) and (PC < $C000) and (State.Family <> 0) then
    begin
      var Bank := State.Banks[(PC - $4000) shr 13];
      if Bank >= 0 then
      begin
        Enqueue((Bank * $2000 + (PC and $1FFF)) mod Length(Data), PC, State);
        Exit;
      end;
    end;
    for var Copy in Copies do
      if (PC >= Copy.Destination) and (PC < Copy.Destination + Copy.Count) then
      begin
        Enqueue(Copy.Source + PC - Copy.Destination, PC, State);
        Exit;
      end;
    if (PC < $4000) or (PC >= $C000) then
      Exit;
    if (Length(Data) = $10000) and (Data[$4000] = $41) and (Data[$4001] = $42) then
    begin
      Enqueue(PC, PC, State);
      Exit;
    end;
    if PC shr 13 = State.PC shr 13 then
      Enqueue((State.Offset and not $1FFF) + (PC and $1FFF), PC, State)
    else
    begin
      // Initial linear windows and bank zero are both possible before the
      // cartridge family is known. Never treat every data bank as executable.
      var Saved := State;
      var Page := (PC - $4000) shr 13;
      // A known selector value can describe either 8 KiB or 16 KiB banks.
      // Explore these explicit alternatives before unassigned initial windows.
      if State.Controls[Page] >= 0 then
      begin
        State.Family := 1;
        Inc(State.Depth);
        for var I := 0 to 3 do
          State.Banks[I] := Max(0, State.Controls[I]);
        Enqueue((State.Banks[Page] * $2000 + (PC and $1FFF)) mod Length(Data), PC, State);
        State := Saved;
      end;
      if State.Controls[Page and 2] >= 0 then
      begin
        State.Family := 2;
        Inc(State.Depth);
        for var I := 0 to 3 do
          State.Banks[I] := Max(0, State.Controls[I and 2]) * 2 + (I and 1);
        Enqueue((State.Banks[Page] * $2000 + (PC and $1FFF)) mod Length(Data), PC, State);
        State := Saved;
      end;
      Inc(State.Depth);
      Enqueue(PC - $4000, PC, State);
      if Length(Data) > $8000 then
        Enqueue(PC and $1FFF, PC, State);
      if Length(Data) = $10000 then
        Enqueue(PC, PC, State);
      Dec(State.Depth);
    end;
  end;

  procedure Next(Count: Integer);
  begin
    if (State.Family <> 0) and (State.PC >= $4000) and (State.PC < $C000) then
      Target(State.PC + Count)
    else if (State.PC and $1FFF) + Count < $2000 then
      Enqueue(State.Offset + Count, State.PC + Count, State)
    else
      Target(State.PC + Count);
  end;

  procedure Seed(Header: Integer);
  var
    S: TCodeState;
    Address: Integer;
  begin
    if (Header + 16 > Length(Data)) or (Data[Header] <> $41) or (Data[Header + 1] <> $42) then
      Exit;
    var Standard := True;
    for var I := 10 to 15 do
      Standard := Standard and (Data[Header + I] = 0);
    for var Field in [2, 4, 6] do
    begin
      if (Field <> 2) and not Standard then
        Continue;
      Address := Data[Header + Field] or (Integer(Data[Header + Field + 1]) shl 8);
      if (Address < $4000) or (Address >= $C000) then
        Continue;
      S := Default(TCodeState);
      for var I := 0 to 7 do
        S.R[I] := -1;
      S.IX := -1;
      S.IY := -1;
      for var I := 0 to 3 do
      begin
        S.Banks[I] := I;
        S.Controls[I] := -1;
      end;
      // Header bank is the initial bank at INIT's 16 KiB page. Small ROMs
      // may start at 8000h and are mirrored within their cartridge window.
      if Header = 0 then
      begin
        if Length(Data) <= $4000 then
          Enqueue((Address and $3FFF) mod Length(Data), Address, S)
        else
          Enqueue(Address - $4000, Address, S);
      end
      else if (Header = $4000) and (Length(Data) = $10000) then
        Enqueue(Address, Address, S)
      else
        Enqueue(Header + (Address and $3FFF), Address, S);
      Inc(Analysis.EntryPoints);
    end;
  end;

  procedure Instruction;
  var
    Pos, Prefix, Op, X, Y, Z, P, Q, Size, Immediate, Displacement: Integer;
    Address, Value, HL: Integer;
    Indexed: Boolean;

    function ReadReg(Index: Integer): Integer;
    begin
      Result := State.R[Index];
      if (Prefix <> 0) and not Indexed and (Index in [4, 5]) then
      begin
        Result := -1;
        if HL >= 0 then
          if Index = 4 then
            Result := HL shr 8
          else
            Result := HL and 255;
      end;
    end;

    procedure WriteReg(Index, V: Integer);
    begin
      if (Prefix <> 0) and not Indexed and (Index in [4, 5]) then
      begin
        Value := -1;
        if (HL >= 0) and (V >= 0) then
          if Index = 4 then
            Value := (HL and 255) or (V shl 8)
          else
            Value := (HL and $FF00) or V;
        if Prefix = $DD then
          State.IX := Value
        else
          State.IY := Value;
      end
      else
        State.R[Index] := V;
    end;

  begin
    Pos := State.Offset;
    Prefix := 0;
    while (Pos < Length(Data)) and (Data[Pos] in [$DD, $FD]) do
    begin
      Prefix := Data[Pos];
      Inc(Pos);
      if Pos - State.Offset > 16 then
      begin
        Analysis.Limited := True;
        Exit;
      end;
    end;
    if Pos >= Length(Data) then
      Exit;
    Op := Data[Pos];
    Inc(Pos);
    HL := Pair(4);
    if Prefix = $DD then
      HL := State.IX
    else if Prefix = $FD then
      HL := State.IY;
    if Op = $CB then
    begin
      if Prefix <> 0 then
      begin
        if Pos + 1 >= Length(Data) then
          Exit;
        Displacement := Data[Pos];
        if Displacement >= 128 then
          Dec(Displacement, 256);
        Address := -1;
        if HL >= 0 then
          Address := (HL + Displacement) and $FFFF;
        Op := Data[Pos + 1];
        Inc(Pos, 2);
        if Op shr 6 <> 1 then
          WriteAt(Address, -1, True);
        if (Op and 7 <> 6) and (Op shr 6 <> 1) then
          State.R[Op and 7] := -1;
      end
      else
      begin
        if Pos >= Length(Data) then
          Exit;
        Op := Data[Pos];
        Inc(Pos);
        if Op shr 6 <> 1 then
          if Op and 7 = 6 then
            WriteAt(HL, -1)
          else
            State.R[Op and 7] := -1;
      end;
      Next(Pos - State.Offset);
      Exit;
    end;
    if Op = $ED then
    begin
      if Pos >= Length(Data) then
        Exit;
      Op := Data[Pos];
      Inc(Pos);
      if Op and $C7 = $43 then
      begin
        if Pos + 1 >= Length(Data) then
          Exit;
        Address := Data[Pos] or (Integer(Data[Pos + 1]) shl 8);
        Inc(Pos, 2);
        P := (Op shr 4) and 3;
        if Op and 8 = 0 then
        begin
          Value := -1;
          if P < 3 then
            Value := Pair(P * 2);
          if Value < 0 then
          begin
            WriteAt(Address, -1);
            WriteAt((Address + 1) and $FFFF, -1);
          end
          else
          begin
            WriteAt(Address, Value and 255);
            WriteAt((Address + 1) and $FFFF, Value shr 8);
          end;
        end
        else if P < 3 then
          SetPair(P * 2, -1);
      end
      else if Op and $C7 = $45 then
        Exit // RETN/RETI
      else if Op and $C7 = $44 then
      begin
        if State.R[7] >= 0 then
          State.R[7] := (-State.R[7]) and 255;
      end
      else if Op and $C7 = $40 then
        State.R[(Op shr 3) and 7] := -1
      else if Op and $CF in [$42, $4A] then
        SetPair(4, -1)
      else if Op in [$57, $5F] then
        State.R[7] := -1
      else if Op in [$67, $6F] then
      begin
        WriteAt(Pair(4), -1);
        State.R[7] := -1;
      end;
      // Track ROM code copied to RAM, without executing or altering memory.
      if Op in [$A0, $A8, $B0, $B8] then
      begin
        var Count := Pair(0);
        var Source := Pair(4);
        var Destination := Pair(2);
        if Op in [$A0, $A8] then
          Count := 1;
        if (Count > 0) and (Source >= $4000) and (Source < $C000) and (Destination >= 0) then
        begin
          var Physical := Source - $4000;
          if Source shr 13 = State.PC shr 13 then
            Physical := State.Offset + Source - State.PC
          else if (State.Family <> 0) and (State.Banks[(Source - $4000) shr 13] >= 0) then
            Physical := (State.Banks[(Source - $4000) shr 13] * $2000 + (Source and $1FFF)) mod Length(Data);
          if Op in [$A8, $B8] then
          begin
            Dec(Physical, Count - 1);
            Dec(Destination, Count - 1);
          end;
          if (Physical >= 0) and (Physical + Count <= Length(Data)) and (Destination + Count <= $10000) and (Copies.Count < 256) then
          begin
            var C: TCodeCopy;
            C.Source := Physical;
            C.Destination := Destination;
            C.Count := Count;
            if not Copies.Contains(C) then
              Copies.Add(C);
          end;
          var Delta := Count;
          if Op in [$A8, $B8] then
            Delta := -Delta;
          SetPair(4, (Source + Delta) and $FFFF);
          SetPair(2, (Pair(2) + Delta) and $FFFF);
          if Op in [$B0, $B8] then
            SetPair(0, 0)
          else
            SetPair(0, -1);
        end
        else
        begin
          SetPair(0, -1);
          SetPair(2, -1);
          SetPair(4, -1);
        end;
      end
      else if Op in [$A2, $AA, $B2, $BA] then
      begin
        SetPair(0, -1);
        SetPair(4, -1);
      end;
      Next(Pos - State.Offset);
      Exit;
    end;
    X := Op shr 6;
    Y := (Op shr 3) and 7;
    Z := Op and 7;
    P := Y shr 1;
    Q := Y and 1;
    Immediate := 0;
    if X = 0 then
      case Z of
        0:
          if Y >= 2 then
            Immediate := 1;
        1:
          if Q = 0 then
            Immediate := 2;
        2:
          if P >= 2 then
            Immediate := 2;
        6:
          Immediate := 1;
      end
    else if X = 3 then
      case Z of
        2, 4:
          Immediate := 2;
        3:
          if Y = 0 then
            Immediate := 2
          else if Y in [2, 3] then
            Immediate := 1;
        5:
          if (Q = 1) and (P = 0) then
            Immediate := 2;
        6:
          Immediate := 1;
      end;
    Indexed := (Prefix <> 0) and (((X = 0) and (Z in [4, 5, 6]) and (Y = 6)) or
      ((X = 1) and (Op <> $76) and ((Y = 6) or (Z = 6))) or ((X = 2) and (Z = 6)));
    Address := HL;
    if Indexed then
    begin
      if Pos >= Length(Data) then
        Exit;
      Displacement := Data[Pos];
      if Displacement >= 128 then
        Dec(Displacement, 256);
      Inc(Pos);
      Address := -1;
      if HL >= 0 then
        Address := (HL + Displacement) and $FFFF;
    end;
    if Pos + Immediate > Length(Data) then
      Exit;
    Value := 0;
    if Immediate > 0 then
      Value := Data[Pos];
    if Immediate = 2 then
      Value := Value or (Integer(Data[Pos + 1]) shl 8);
    Size := Pos + Immediate - State.Offset;
    if X = 0 then
      case Z of
        0:
          begin
            if Y = 1 then
              State.R[7] := -1;
            if Y >= 2 then
            begin
              Displacement := Value;
              if Displacement >= 128 then
                Dec(Displacement, 256);
              Target(State.PC + Size + Displacement);
              if Y = 3 then
                Exit;
              if Y = 2 then
                State.R[0] := -1;
            end;
          end;
        1:
          if Q = 0 then
          begin
            if (P = 2) and (Prefix <> 0) then
              if Prefix = $DD then
                State.IX := Value
              else
                State.IY := Value
            else if P < 3 then
              SetPair(P * 2, Value);
          end
          else if Prefix = $DD then
            State.IX := -1
          else if Prefix = $FD then
            State.IY := -1
          else
            SetPair(4, -1);
        2:
          if Q = 0 then
            case P of
              0:
                WriteAt(Pair(0), State.R[7]);
              1:
                WriteAt(Pair(2), State.R[7]);
              2:
                begin
                  // BIOS hook entries contain a JP/CALLF operand at +1/+2.
                  // Follow stored ROM routine pointers as deferred entry roots.
                  if (Value >= $FD9B) and (Value <= $FFC2) and (HL >= $4000) and (HL < $C000) then
                    Target(HL);
                  if HL < 0 then
                  begin
                    WriteAt(Value, -1);
                    WriteAt((Value + 1) and $FFFF, -1);
                  end
                  else
                  begin
                    WriteAt(Value, HL and 255);
                    WriteAt((Value + 1) and $FFFF, HL shr 8);
                  end;
                end;
              3:
                WriteAt(Value, State.R[7]);
            end
          else if P = 2 then
            if Prefix = $DD then
              State.IX := -1
            else if Prefix = $FD then
              State.IY := -1
            else
              SetPair(4, -1)
          else
            State.R[7] := -1;
        3:
          begin
            Value := -1;
            if P = 2 then
              Value := HL
            else if P < 3 then
              Value := Pair(P * 2);
            if Value >= 0 then
              if Q = 0 then
                Value := (Value + 1) and $FFFF
              else
                Value := (Value - 1) and $FFFF;
            if (P = 2) and (Prefix <> 0) then
              if Prefix = $DD then
                State.IX := Value
              else
                State.IY := Value
            else if P < 3 then
              SetPair(P * 2, Value);
          end;
        4, 5:
          if Y = 6 then
            WriteAt(Address, -1)
          else if ReadReg(Y) >= 0 then
            WriteReg(Y, (ReadReg(Y) + 1 - 2 * Ord(Z = 5)) and 255);
        6:
          if Y = 6 then
            WriteAt(Address, Value)
          else
            WriteReg(Y, Value);
        7:
          if Y < 6 then
            State.R[7] := -1;
      end
    else if X = 1 then
    begin
      if Op = $76 then
        Exit;
      if Y = 6 then
        WriteAt(Address, ReadReg(Z))
      else if Z = 6 then
        WriteReg(Y, -1)
      else
        WriteReg(Y, ReadReg(Z));
    end
    else if X = 2 then
    begin
      if Op in [$97, $AF] then
        State.R[7] := 0
      else
        State.R[7] := -1;
    end
    else
      case Z of
        0:
          ; // Conditional RET: the not-taken path remains reachable.
          1:
          if Q = 0 then
          begin
            if P = 3 then
              State.R[7] := -1
            else if (P = 2) and (Prefix <> 0) then
              if Prefix = $DD then
                State.IX := -1
              else
                State.IY := -1
            else
              SetPair(P * 2, -1);
          end
          else
            case P of
              0:
                Exit;
              1:
                begin
                  SetPair(0, -1);
                  SetPair(2, -1);
                  SetPair(4, -1);
                end;
              2:
                begin
                  if HL >= 0 then
                    Target(HL);
                  Exit;
                end;
            end;
        2:
          Target(Value);
        3:
          case Y of
            0:
              begin
                Target(Value);
                Exit;
              end;
            3:
              State.R[7] := -1;
            4:
              begin
                if Prefix = $DD then
                  State.IX := -1
                else if Prefix = $FD then
                  State.IY := -1
                else
                  SetPair(4, -1);
              end;
            5:
              begin
                Value := Pair(2);
                SetPair(2, Pair(4));
                SetPair(4, Value);
              end;
          end;
        4:
          begin
            Target(Value);
            UnknownRegisters;
          end;
        5:
          if (Q = 1) and (P = 0) then
          begin
            Target(Value);
            UnknownRegisters;
          end;
        6:
          State.R[7] := -1;
        7:
          UnknownRegisters; // BIOS/RST services are outside the ROM image.
      end;
    Next(Size);
  end;

begin
  Analysis := Default(TMSXCodeAnalysis);
  if (Length(Data) = 0) or (Length(Data) > $800000) then
    Exit(Analysis);
  Queue := TList<TCodeState>.Create;
  Seen := TDictionary<UInt64, Byte>.Create;
  Written := TDictionary<UInt64, Byte>.Create;
  Writes := TList<TMSXCodeWrite>.Create;
  try
    Visits := TDictionary<Integer, Byte>.Create;
    Copies := TList<TCodeCopy>.Create;
    Seed(0);
    if (Length(Data) > $4000) and ((Data[0] <> $41) or (Data[1] <> $42) or (Length(Data) = $10000)) then
      Seed($4000);
    // R-Type's fixed page is physical bank 15, not the start of its dump.
    if Length(Data) = $60000 then
      Seed($3C000);
    Head := 0;
    while Head < Queue.Count do
    begin
      State := Queue[Head];
      Inc(Head);
      Inc(Analysis.Instructions);
      Instruction;
    end;
    Analysis.Writes := Writes.ToArray;
    Result := Analysis;
  finally
    Copies.Free;
    Visits.Free;
    Writes.Free;
    Written.Free;
    Seen.Free;
    Queue.Free;
  end;
end;

end.

