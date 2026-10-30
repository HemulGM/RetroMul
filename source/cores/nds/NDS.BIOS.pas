unit NDS.BIOS;

interface

uses
  System.SysUtils, System.Classes, System.Math, HW.ARM;

type
  TNDSBIOSCall = function(Address, R0, R1, R2: Cardinal): Cardinal of object;

  // Original HLE implementations of the public NDS decompression ABI.
  TNDSBIOS = class
  public
    class procedure Unpack(Number: Integer; CPU: TARMProcessor; Read: TARMRead; Write: TARMWrite; Call: TNDSBIOSCall); static;
  end;

implementation

class procedure TNDSBIOS.Unpack(Number: Integer; CPU: TARMProcessor; Read: TARMRead; Write: TARMWrite; Call: TNDSBIOSCall);
var
  Source, Destination, Start, Remaining, Header, Parameter, Callbacks: Cardinal;
  Pending, PackedWord: Cardinal;
  PackedBits, UnitSize: Integer;
  UseCallbacks: Boolean;

  function Invoke(Index: Integer; Address: Cardinal): Cardinal;
  begin
    var Target := Read(ARMAdd(Callbacks, Index * 4), 4);
    if Target = 0 then
      raise EReadError.Create('Missing NDS BIOS decompression callback');
    Result := Call(Target, Address, Destination, Parameter);
  end;

  function GetByte: Byte;
  begin
    if UseCallbacks then
      Result := Byte(Invoke(2, Source))
    else
      Result := Byte(Read(Source, 1));
    Source := ARMAdd(Source, 1);
  end;

  function GetWord: Cardinal;
  begin
    if UseCallbacks then
      Result := Invoke(4, Source)
    else
      Result := Read(Source, 4);
    Source := ARMAdd(Source, 4);
  end;

  procedure Emit(Value: Cardinal; Bits: Integer);
  begin
    PackedWord := PackedWord or (Value shl PackedBits);
    Inc(PackedBits, Bits);
    if PackedBits = UnitSize * 8 then
    begin
      Write(Destination, PackedWord, UnitSize);
      Destination := ARMAdd(Destination, UnitSize);
      PackedBits := 0;
      PackedWord := 0;
    end;
  end;

begin
  Source := CPU.R[0];
  Destination := CPU.R[1];
  Start := Destination;
  Parameter := CPU.R[2];
  Callbacks := CPU.R[3];
  PackedWord := 0;
  PackedBits := 0;
  Pending := 0;
  UseCallbacks := Number in [$12, $13, $15];
  if Number = $10 then
  begin
    var Count := Read(Parameter, 2);
    var SourceBits := Read(ARMAdd(Parameter, 2), 1);
    var DestBits := Read(ARMAdd(Parameter, 3), 1);
    var Offset := Read(ARMAdd(Parameter, 4), 4);
    var AddZero := Offset and $80000000 <> 0;
    Offset := Offset and $7FFFFFFF;
    UnitSize := 4;
    if not (SourceBits in [1, 2, 4, 8]) or not (DestBits in [1, 2, 4, 8, 16, 32]) or (DestBits < SourceBits) then
      raise EReadError.Create('Invalid NDS BIOS bit unpack widths');
    for var I := 1 to Integer(Count) do
    begin
      var Value := GetByte;
      for var Bit := 0 to (8 div Integer(SourceBits)) - 1 do
      begin
        var Part: Cardinal := (Value shr (Bit * Integer(SourceBits))) and ((1 shl SourceBits) - 1);
        if (Part <> 0) or AddZero then
          Part := ARMAdd(Part, Offset);
        if DestBits < 32 then
          Part := Part and ((Cardinal(1) shl DestBits) - 1);
        Emit(Part, DestBits);
      end;
    end;
    Exit;
  end;
  if UseCallbacks then
    Header := Invoke(0, Source)
  else
    Header := Read(Source, 4);
  if UseCallbacks and (Integer(Header) < 0) then
  begin
    CPU.R[0] := Header;
    Exit;
  end;
  Remaining := Header shr 8;
  Source := ARMAdd(Source, 4);
  UnitSize := 1;
  if Number in [$12, $15] then
    UnitSize := 2
  else if Number = $13 then
    UnitSize := 4;
  case Number of
    $11, $12:
      while Remaining > 0 do
      begin
        var Flags := GetByte;
        for var Bit := 7 downto 0 do
        begin
          if Remaining = 0 then
            Break;
          if Flags and (1 shl Bit) = 0 then
          begin
            Emit(GetByte, 8);
            Dec(Remaining);
          end
          else
          begin
            var A := GetByte;
            var B := GetByte;
            var Distance := ((A and 15) shl 8) + B + 1;
            var Count := (A shr 4) + 3;
            if Cardinal(Distance) > Destination - Start + Cardinal(PackedBits div 8) then
              raise EReadError.Create('Invalid NDS BIOS LZ77 back reference');
            for var I := 1 to Integer(Min(Cardinal(Count), Remaining)) do
            begin
              // A pending halfword byte has not reached VRAM yet. Retain it so
              // overlapping strings also work without illegal byte writes.
              var Position := ARMAdd(Destination, Cardinal(PackedBits div 8));
              if (PackedBits <> 0) and (Distance = 1) then
                Pending := PackedWord and 255
              else
                Pending := Read(ARMSub(Position, Distance), 1);
              Emit(Pending, 8);
              Dec(Remaining);
            end;
          end;
        end;
      end;
    $14, $15:
      while Remaining > 0 do
      begin
        var Flags := GetByte;
        var Count := (Flags and 127) + 1;
        if Flags and $80 <> 0 then
        begin
          Inc(Count, 2);
          Pending := GetByte;
        end;
        for var I := 1 to Integer(Min(Cardinal(Count), Remaining)) do
        begin
          if Flags and $80 = 0 then
            Pending := GetByte;
          Emit(Pending, 8);
          Dec(Remaining);
        end;
      end;
    $13:
      begin
        var Bits := Integer(Header and 15);
        if not (Bits in [4, 8]) then
          raise EReadError.Create('Invalid NDS BIOS Huffman symbol size');
        var Tree: TBytes;
        var TreeSize: Integer := (Integer(GetByte) + 1) * 2;
        SetLength(Tree, TreeSize);
        Tree[0] := Byte(TreeSize div 2 - 1);
        for var I := 1 to TreeSize - 1 do
        begin
          Tree[I] := GetByte;
          Write(ARMAdd(Parameter, I - 1), Tree[I], 1);
        end;
        var Node := 1;
        var Available := 0;
        var Data: Cardinal := 0;
        var Symbols := Remaining * (8 div Cardinal(Bits));
        while Symbols > 0 do
        begin
          if Available = 0 then
          begin
            Data := GetWord;
            Available := 32;
          end;
          var Branch: Integer := Data shr 31;
          Data := Data shl 1;
          Dec(Available);
          var Parent := Tree[Node];
          Node := (Node and not 1) + (Parent and 63) * 2 + 2 + Branch;
          if Node >= TreeSize then
            raise EReadError.Create('Invalid NDS BIOS Huffman tree');
          if Parent and ($80 shr Branch) <> 0 then
          begin
            Emit(Tree[Node] and ((1 shl Bits) - 1), Bits);
            Node := 1;
            Dec(Symbols);
          end;
        end;
      end;
    $16, $18:
      begin
        var Size := 1;
        if Number = $18 then
          Size := 2;
        var Value: Cardinal := 0;
        for var I := 1 to Integer(Remaining div Cardinal(Size)) do
        begin
          Value := ARMAdd(Value, Read(Source, Size));
          Write(Destination, Value, Size);
          Source := ARMAdd(Source, Size);
          Destination := ARMAdd(Destination, Size);
        end;
      end;
  else
    raise EArgumentException.Create('Invalid NDS BIOS decompression service');
  end;
  if PackedBits <> 0 then
    Write(Destination, PackedWord, UnitSize);
  if UseCallbacks then
  begin
    CPU.R[0] := Header shr 8;
    var Close := Read(ARMAdd(Callbacks, 4), 4);
    if Close <> 0 then
    begin
      var Status := Call(Close, Source, Start, Parameter);
      if Integer(Status) < 0 then
        CPU.R[0] := Status;
    end;
  end;
end;

end.

