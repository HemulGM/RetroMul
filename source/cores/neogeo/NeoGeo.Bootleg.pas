unit NeoGeo.Bootleg;

interface

uses
  System.SysUtils, System.Classes;

procedure DecryptBootleg(var ProgramData, Fixed, Audio, Samples, Graphics: TBytes; const Kind: string; EncryptedAudio: Boolean);

function BootlegBits(Value: Integer; const Order: array of Integer): Integer;

implementation

uses
  NeoGeo.Protection;

// MAME BSD-3-Clause: S. Smith, David Haywood, Fabio Priuli. See LICENSE.txt.
// All offsets refer to bounded arrays. Program words use the core's big endian order.
function BootlegBits(Value: Integer; const Order: array of Integer): Integer;
begin
  Result := 0;
  for var Bit in Order do
    Result := (Result shl 1) or ((Value shr Bit) and 1);
end;

procedure CopyRange(const Source: TBytes; SourceOffset: Integer; var Target: TBytes; TargetOffset, Count: Integer);
begin
  if (SourceOffset < 0) or (TargetOffset < 0) or (Count < 0) or
    (Int64(SourceOffset) + Count > Length(Source)) or
    (Int64(TargetOffset) + Count > Length(Target)) then
    raise EReadError.Create('Truncated Neo Geo bootleg region');

  // A temporary slice gives memmove semantics when source and destination alias.
  var Slice := Copy(Source, SourceOffset, Count);
  for var i := 0 to Count - 1 do
    Target[TargetOffset + i] := Slice[i];
end;

function ReadWord(const Data: TBytes; Offset: Integer): Word;
begin
  if (Offset < 0) or (Int64(Offset) + 2 > Length(Data)) then
    raise EReadError.Create('Truncated Neo Geo bootleg program');

  Result := Word(Integer(Data[Offset]) * 256 + Data[Offset + 1]);
end;

procedure PutWord(var Data: TBytes; Offset, Value: Integer);
begin
  if (Offset < 0) or (Int64(Offset) + 2 > Length(Data)) then
    raise EReadError.Create('Truncated Neo Geo bootleg program');

  Data[Offset] := (Value shr 8) and $FF;
  Data[Offset + 1] := Value and $FF;
end;

procedure Blocks(var Data: TBytes; Base, Size: Integer; const Order: array of Integer);
begin
  var Buffer := Copy(Data);
  for var i := 0 to High(Order) do
    CopyRange(Buffer, Base + Order[i] * Size, Data, Base + i * Size, Size);
end;

procedure FixedDecrypt(var Data: TBytes; Mode: Integer);
begin
  var Buffer := Copy(Data);
  if Mode = 1 then
  begin
    if Length(Data) mod 16 <> 0 then
      raise EReadError.Create('Invalid bootleg fixed region');

    for var i := 0 to High(Data) do
      Data[i] := Buffer[i xor 8];
  end
  else
    for var i := 0 to High(Data) do
      Data[i] := Byte(BootlegBits(Data[i], [7, 6, 0, 4, 3, 2, 1, 5]));
end;

procedure SwapGraphics(var Data: TBytes);
begin
  if Length(Data) mod $80 <> 0 then
    raise EReadError.Create('Invalid bootleg sprite region');

  var Buffer := Copy(Data);
  for var i := 0 to High(Data) do
    Data[i] := Buffer[i xor $40];
end;

procedure SVCGraphics(var Data: TBytes);
const
  Index: array[0..15] of Integer = (0, 1, 0, 1, 2, 3, 2, 3, 3, 4, 3, 4, 4, 5, 4, 5);
  Order: array[0..5, 0..3] of Integer = (
    (3, 0, 1, 2), (2, 3, 0, 1), (1, 2, 3, 0),
    (0, 1, 2, 3), (3, 2, 1, 0), (3, 0, 2, 1));
begin
  var Buffer := Copy(Data);
  for var i := 0 to Length(Data) div $80 - 1 do
  begin
    var N := Index[(i shr 8) and $F];
    var Offset := (i and $7FFFFF00) + BootlegBits(i and $FF, [7, 6, 5, 4, Order[N, 3], Order[N, 2], Order[N, 1], Order[N, 0]]);
    CopyRange(Buffer, Offset * $80, Data, i * $80, $80);
  end;
end;

procedure KOF2002Graphics(var Data: TBytes);
const
  Order: array[0..7, 0..5] of Integer = (
    (0, 8, 7, 6, 2, 1), (1, 0, 8, 7, 6, 2),
    (2, 1, 0, 8, 7, 6), (6, 2, 1, 0, 8, 7),
    (7, 6, 2, 1, 0, 8), (0, 1, 2, 6, 7, 8),
    (2, 1, 0, 6, 7, 8), (8, 0, 7, 6, 2, 1));
begin
  if Length(Data) mod $10000 <> 0 then
    raise EReadError.Create('Invalid KOF2002 bootleg graphics');

  for var Block := 0 to Length(Data) div $10000 - 1 do
  begin
    var Buffer := Copy(Data, Block * $10000, $10000);
    for var i := 0 to $1FF do
    begin
      var N := (i shr 3) and 7;
      var Offset := BootlegBits(i, [15, 14, 13, 12, 11, 10, 9, Order[N, 0], Order[N, 1],
          Order[N, 2], 5, 4, 3, Order[N, 3], Order[N, 4], Order[N, 5]]);
      CopyRange(Buffer, i * $80, Data, Block * $10000 + Offset * $80, $80);
    end;
  end;
end;

procedure CTHDGraphics(var Data: TBytes);
const
  Order: array[0..7, 0..3] of Integer = (
    (0, 3, 2, 1), (1, 0, 3, 2),
    (2, 1, 0, 3), (0, 1, 2, 3),
    (0, 1, 2, 3), (0, 1, 2, 3),
    (0, 1, 2, 3), (0, 2, 3, 1));
begin
  if Length(Data) <> $4000000 then
    raise EReadError.Create('Invalid CTHD sprite region');

  for var Group := 0 to 127 do
    for var Section := 0 to 7 do
    begin
      if (Section = 3) or (Section = 4) then
        Continue;

      for var Chunk := 0 to 31 do
      begin
        var Base := ((Group * 8 + Section) * 512 + Chunk * 16) * 128;
        var Buffer := Copy(Data, Base, 16 * 128);
        for var Tile := 0 to 15 do
        begin
          var Offset := ((Tile and 1) shl Order[Section, 3]) or
            (((Tile shr 1) and 1) shl Order[Section, 2]) or
            (((Tile shr 2) and 1) shl Order[Section, 1]) or
            (((Tile shr 3) and 1) shl Order[Section, 0]);
          CopyRange(Buffer, Offset * 128, Data, Base + Tile * 128, 128);
        end;
      end;
    end;
end;

procedure PatchCTHD(var Data: TBytes);
begin
  PutWord(Data, $F415A, $4EF9);
  PutWord(Data, $F415C, $000F);
  PutWord(Data, $F415E, $4CF2);
  for var i := $1AE290 div 2 to $1AE8D0 div 2 - 1 do
    PutWord(Data, i * 2, 0);
  for var i := 0 to ($1FA1F0 - $1F8EF0) div 4 - 1 do
  begin
    var A := $1F8EF0 + i * 4;
    PutWord(Data, A, (Integer(ReadWord(Data, A)) + $9000) and $FFFF);
    PutWord(Data, A + 2, (Integer(ReadWord(Data, A + 2)) + $FFF0) and $FFFF);
  end;
  for var i := $AC500 div 2 to $AC520 div 2 - 1 do
    PutWord(Data, i * 2, $FFFF);
  for var A in [$991D0, $99306, $99354, $9943E] do
    PutWord(Data, A, $DD03);
end;

procedure DecryptBootleg(var ProgramData, Fixed, Audio, Samples, Graphics: TBytes; const Kind: string; EncryptedAudio: Boolean);
const
  Kf10Order: array[0..7] of Integer = ($60000, $100000, $E0000, $180000, $20000, $140000, $C0000, $1A0000);
  SvcOrder: array[0..7] of Integer = (6, 7, 1, 2, 3, 4, 5, 0);
  KogPatch: array[0..21, 0..1] of Integer = (
    ($93966, $FFDA), ($93974, $FFCC), ($93982, $FFBE), ($93990, $FFB0),
    ($9399E, $FFA2), ($939AC, $FF94), ($939BA, $FF86), ($939C8, $FF78),
    ($939D4, $FA5C), ($939E0, $FA50), ($939EC, $FA44), ($939F8, $FA38),
    ($93A04, $FA2C), ($93A10, $FA20), ($93A1C, $FA14), ($93A28, $FA08),
    ($93A34, $F9FC), ($93A40, $F9F0), ($93A4C, $FD14), ($93A58, $FD08),
    ($93A66, $F9CA), ($93A72, $F9BE));
begin
  if Kind = 'garoubl' then
  begin
    FixedDecrypt(Fixed, 2);
    SwapGraphics(Graphics);
  end
  else if (Kind = 'cthd2k3') or (Kind = 'ct2k3sp') or (Kind = 'ct2k3sa') then
  begin
    Blocks(Audio, 0, $8000, [0, 2, 1, 3]);
    if Kind = 'cthd2k3' then
      Blocks(Fixed, 0, $8000, [0, 2, 1, 3]);
    if Kind = 'ct2k3sp' then
    begin
      var Buffer := Copy(Fixed);
      for var i := 0 to High(Fixed) do
        Fixed[i] := Buffer[(i and $7FFE0000) + BootlegBits(i and $1FFFF,
              [23, 22, 21, 20, 19, 18, 17, 3, 0, 1, 4, 2, 13, 14, 16, 15, 5, 6, 11, 10, 9, 8, 7, 12])];
      Blocks(Fixed, 0, $8000, [0, 2, 1, 3, 4, 6, 5, 7]);
    end;
    CTHDGraphics(Graphics);
    PatchCTHD(ProgramData);
  end
  else if Kind = 'matrimbl' then
  begin
    ReorderProgram(ProgramData, 'matrim');
    ExtractCMCText(Graphics, Fixed);
    var Buffer := Copy(Audio);
    if Length(Audio) < $20000 then
      raise EReadError.Create('Truncated Matrimelee audio');

    for var i := 0 to $1FFFF do
    begin
      var A := i;
      if ((i and $10000) <> 0) xor ((i and $800) <> 0) then
        A := A xor 1;
      A := A xor (BootlegBits(A and 3, [4, 3, 1, 2, 0, 7, 6, 5]) shl 8);
      if (i and $800) <> 0 then
        A := A xor $10000;
      Audio[A] := Buffer[i];
    end;
    CTHDGraphics(Graphics);
  end
  else if (Kind = 'kf2k2mp') or (Kind = 'kof2km2') or (Kind = 'kf2k2mp2') or (Kind = 'kof2002b') then
  begin
    if Kind = 'kf2k2mp' then
    begin
      CopyRange(ProgramData, $300000, ProgramData, 0, $500000);
      for var Block := 0 to $800000 div $80 - 1 do
      begin
        var Buffer := Copy(ProgramData, Block * $80, $80);
        for var i := 0 to $3F do
          CopyRange(Buffer, BootlegBits(i, [6, 7, 2, 3, 4, 5, 0, 1]) * 2, ProgramData, Block * $80 + i * 2, 2);
      end;
      FixedDecrypt(Fixed, 2);
    end
    else if Kind = 'kof2002b' then
    begin
      ReorderProgram(ProgramData, 'kof2002');
      KOF2002Graphics(Graphics);
      KOF2002Graphics(Fixed);
    end
    else
    begin
      var Buffer := Copy(ProgramData);
      CopyRange(Buffer, $1C0000, ProgramData, 0, $40000);
      CopyRange(Buffer, $140000, ProgramData, $40000, $80000);
      CopyRange(Buffer, $100000, ProgramData, $C0000, $40000);
      CopyRange(Buffer, $200000, ProgramData, $100000, $400000);
      FixedDecrypt(Fixed, 1);
    end;
    DecryptPCM(Samples, 0, 0);
    if Kind <> 'kof2002b' then
      DecryptCMC(Graphics, Fixed, Audio, $EC, True, False, EncryptedAudio)
    else if EncryptedAudio then
      DecryptCMCAudio(Audio);
  end
  else if Kind = 'kf10thep' then
  begin
    var Buffer: TBytes;
    SetLength(Buffer, $100000);

    for var i := 0 to 7 do
      CopyRange(ProgramData, Kf10Order[i], Buffer, i * $20000, $20000);
    CopyRange(ProgramData, $402E0, Buffer, $2E0, $6A);
    CopyRange(ProgramData, $492BC, Buffer, $F92BC, $B9E);
    CopyRange(Buffer, 0, ProgramData, 0, $100000);
    for var i := $F92BC div 2 to $F9E58 div 2 - 1 do
      if ((ReadWord(ProgramData, i * 2) = $4EB9) or (ReadWord(ProgramData, i * 2) = $4EF9)) and
        (ReadWord(ProgramData, i * 2 + 2) = 0) then
        PutWord(ProgramData, i * 2 + 2, $F);
    PutWord(ProgramData, $342, $F);
    CopyRange(ProgramData, $200000, ProgramData, $100000, $600000);
    FixedDecrypt(Fixed, 1);
  end
  else if Kind = 'kf2k5uni' then
  begin
    for var Block := 0 to $800000 div $80 - 1 do
    begin
      var Buffer := Copy(ProgramData, Block * $80, $80);
      for var i := 0 to $3F do
        CopyRange(Buffer, BootlegBits(i * 2, [0, 3, 4, 5, 6, 1, 2, 7]), ProgramData, Block * $80 + i * 2, 2);
    end;
    CopyRange(ProgramData, $600000, ProgramData, 0, $100000);
    for var i := 0 to High(Fixed) do
      Fixed[i] := Byte(BootlegBits(Fixed[i], [4, 5, 6, 7, 0, 1, 2, 3]));
    for var i := 0 to High(Audio) do
      Audio[i] := Byte(BootlegBits(Audio[i], [4, 5, 6, 7, 0, 1, 2, 3]));
  end
  else if Kind = 'kof2k4se' then
    Blocks(ProgramData, $100000, $100000, [3, 2, 1, 0])
  else if Kind = 'mslug3b6' then
  begin
    FixedDecrypt(Fixed, 2);
    DecryptCMC(Graphics, Fixed, Audio, $AD, False, False, False);
  end
  else if Kind = 'ms5plus' then
  begin
    FixedDecrypt(Fixed, 1);
    DecryptCMC(Graphics, Fixed, Audio, $19, True, False, EncryptedAudio);
    DecryptPCM(Samples, 0, 2);
  end
  else if (Kind = 'kf2k3bl') or (Kind = 'kf2k3pl') or (Kind = 'kf2k3upl') then
  begin
    if Kind = 'kf2k3pl' then
    begin
      for var Block := 0 to 6 do
      begin
        var Buffer := Copy(ProgramData, Block * $100000, $100000);
        for var i := 0 to $7FFFF do
          CopyRange(Buffer, BootlegBits(i, [23, 22, 21, 20, 19, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18]) * 2,
            ProgramData, Block * $100000 + i * 2, 2);
      end;
      PutWord(ProgramData, $F38AC, $4E75);
    end
    else if Kind = 'kf2k3upl' then
    begin
      CopyRange(ProgramData, 0, ProgramData, $100000, $600000);
      CopyRange(ProgramData, $700000, ProgramData, 0, $100000);
      var Buffer := Copy(ProgramData);
      for var i := 0 to $FFF do
        CopyRange(Buffer, $D0610 + ((i and $FF00) + BootlegBits(i and $FF, [7, 6, 0, 4, 3, 2, 1, 5])) * 2,
          ProgramData, $FE000 + i * 2, 2);
    end;
    FixedDecrypt(Fixed, 1);
    DecryptCMC(Graphics, Fixed, Audio, $9D, True, False, False);
    DecryptPCM(Samples, 0, 5);
  end
  else if Kind = 'kof10th' then
  begin
    var Buffer: TBytes;
    SetLength(Buffer, $900000);
    CopyRange(ProgramData, $700000, Buffer, 0, $100000);
    CopyRange(ProgramData, 0, Buffer, $100000, $800000);
    for var i := 0 to $8FFFFF do
      ProgramData[BootlegBits(i, [23, 22, 21, 20, 19, 18, 17, 16, 15, 14, 13, 12, 11, 2, 9, 8, 7, 1, 5, 4, 3, 10, 6, 0]) xor 1] := Buffer[i xor 1];
    PutWord(ProgramData, $124, $D);
    PutWord(ProgramData, $126, $F7A8);
    PutWord(ProgramData, $8BF4, $4EF9);
    PutWord(ProgramData, $8BF6, $D);
    PutWord(ProgramData, $8BF8, $F980);
  end
  else if (Kind = 'svcboot') or (Kind = 'svcplus') or (Kind = 'svcplusa') or (Kind = 'svcsplus') then
  begin
    if Kind = 'svcboot' then
    begin
      Blocks(ProgramData, 0, $100000, [6, 7, 1, 2, 3, 4, 5, 0]);
      var Buffer := Copy(ProgramData);
      for var i := 0 to Length(ProgramData) div 2 - 1 do
        CopyRange(Buffer, ((i and $7FFFFF00) + BootlegBits(i and $FF, [7, 6, 1, 0, 3, 2, 5, 4])) * 2, ProgramData, i * 2, 2);
    end
    else if Kind = 'svcplusa' then
      Blocks(ProgramData, 0, $100000, [1, 2, 3, 4, 5, 0])
    else if Kind = 'svcplus' then
    begin
      var Buffer := Copy(ProgramData);
      for var i := 0 to Length(ProgramData) div 2 - 1 do
      begin
        var A := (BootlegBits(i and $FFFFF, [23, 22, 21, 20, 19, 0, 1, 2, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 16, 17, 18]) xor $F0007) + (i and $7FF00000);
        CopyRange(Buffer, A * 2, ProgramData, i * 2, 2);
      end;
      Blocks(ProgramData, 0, $100000, [0, 3, 2, 5, 4, 1]);
      FixedDecrypt(Fixed, 1);
    end
    else
    begin
      var Buffer := Copy(ProgramData);
      for var i := 0 to Length(ProgramData) div 2 - 1 do
      begin
        var A := BootlegBits(i and $7FFF, [15, 0, 8, 9, 11, 10, 12, 13, 4, 3, 1, 7, 6, 2, 5, 14]) +
          (i and $78000) + (SvcOrder[(i shr 19) and 7] shl 19);
        CopyRange(Buffer, A * 2, ProgramData, i * 2, 2);
      end;
      FixedDecrypt(Fixed, 2);
      PutWord(ProgramData, $9E90, $F);
      PutWord(ProgramData, $9E92, $C9C0);
      PutWord(ProgramData, $A10C, $4EB9);
      PutWord(ProgramData, $A10E, $E);
      PutWord(ProgramData, $A110, $9750);
    end;
    if (Kind = 'svcplus') or (Kind = 'svcplusa') then
      PutWord(ProgramData, $F8016, $33C1);
    SVCGraphics(Graphics);
  end
  else if (Kind = 'samsho5b') or (Kind = 'lans2004') or (Kind = 'kog') then
  begin
    var Buffer := Copy(ProgramData);
    if Kind = 'samsho5b' then
    begin
      for var i := 0 to Length(ProgramData) div 2 - 1 do
        CopyRange(Buffer, (((i and $7FFFFF00) + BootlegBits(i and $FF, [7, 6, 5, 4, 3, 0, 1, 2])) xor $60005) * 2,
          ProgramData, i * 2, 2);
      Blocks(ProgramData, 0, $100000, [7, 0, 1, 2, 3, 4, 5, 6]);
    end
    else
    begin
      Blocks(ProgramData, 0, $20000, [3, 8, 7, 12, 1, 10, 6, 13]);
      CopyRange(Buffer, $200000, ProgramData, $100000, $400000);
      if Kind = 'lans2004' then
      begin
        CopyRange(Buffer, $45B00, ProgramData, $BBB00, $1710);
        CopyRange(Buffer, $1A92BE, ProgramData, $2FFF0, $10);
        for var i := $BBB00 div 2 to $BE000 div 2 - 1 do
          if (((ReadWord(ProgramData, i * 2) and $FFBF) = $4EB9) or
            ((ReadWord(ProgramData, i * 2) and $FFBF) = $43B9)) and (ReadWord(ProgramData, i * 2 + 2) = 0) then
          begin
            PutWord(ProgramData, i * 2 + 2, $B);
            PutWord(ProgramData, i * 2 + 4, (Integer(ReadWord(ProgramData, i * 2 + 4)) + $6000) and $FFFF);
          end;
        PutWord(ProgramData, $2D15C, $B);
        PutWord(ProgramData, $2D15E, $BB00);
        for var A in [$2D1E4, $2EA7E, $BBCD0, $BBDF2, $BBE42] do
          PutWord(ProgramData, A, $6002);
      end
      else
      begin
        for var A in [$7A6, $7C6, $7E6] do
          CopyRange(Buffer, $40000 + A, ProgramData, A, 6);
        CopyRange(Buffer, $40000, ProgramData, $90000, $4000);
        for var i := $90000 div 2 to $94000 div 2 - 1 do
        begin
          var W := ReadWord(ProgramData, i * 2);
          if (((W and $FFBF) = $4EB9) or (W = $43F9)) and (ReadWord(ProgramData, i * 2 + 2) = 0) then
            PutWord(ProgramData, i * 2 + 2, 9);
          if W = $4EB8 then
            PutWord(ProgramData, i * 2, $6100);
        end;
        for var A in [$7A8, $7C8, $7E8, $924AC, $9251C] do
          PutWord(ProgramData, A, 9);
        PutWord(ProgramData, $93408, $F168);
        PutWord(ProgramData, $9340C, $FB7A);

        for var i := 0 to 21 do
          PutWord(ProgramData, KogPatch[i, 0], KogPatch[i, 1]);
      end;
    end;
    if Kind <> 'kog' then
      for var i := 0 to High(Samples) do
        Samples[i] := Byte(BootlegBits(Samples[i], [0, 1, 5, 4, 3, 2, 6, 7]));
    FixedDecrypt(Fixed, 1);
    SwapGraphics(Graphics);
  end
  else
    raise ENotSupportedException.Create('Unknown Neo Geo bootleg board: ' + Kind);
end;

end.

