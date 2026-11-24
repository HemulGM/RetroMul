// Unswizzle staged GS bytes and replicate native pixels at the device scale.
// The immutable scale module is supplied by the host and keyed in its cache.
{$I PS2GSUploadScale.pasm}

type
  TPS2HLEUploadPush = record
    OffsetWords, WidthPages, Format, Scale, Width, Height, FirstY, Depth: Cardinal;
  end;

var
  [Binding(0, 0), ReadOnly] SourceWords: array of Cardinal;
  [Binding(0, 1), WriteOnly] ImageWords: array of Cardinal;
  [PushConstant] PC: TPS2HLEUploadPush;

[Vulkan11, LocalSize(8, 8, 1)]
procedure Main;
begin
  var Q: Cardinal2 := GlobalInvocationID.XY;
  if (Q.X >= PC.Width) or (Q.Y >= PC.Height) then
    Exit;
  var X := Q.X div UploadScale;
  var Y := PC.FirstY + Q.Y div UploadScale;
  var Small := (PC.Format = 2) or (PC.Format = $A) or
    (PC.Format = $32) or (PC.Format = $3A);
  var ZFormat := (PC.Format and $30) = $30;
  var Raw: Cardinal;
  if not Small then
  begin
    var Page := (X shr 6) + (Y shr 5) * PC.WidthPages;
    var BX := (X shr 3) and 7;
    var BY := (Y shr 3) and 3;
    var Block := (BX and 1) or ((BX and 2) shl 1) or ((BX and 4) shl 2) or
      ((BY and 1) shl 1) or ((BY and 2) shl 2);
    if ZFormat then
      Block := Block xor 24;
    var Column := (X and 1) or ((Y and 1) shl 1) or (((X shr 1) and 3) shl 2) or
      (((Y shr 1) and 3) shl 4);
    Raw := SourceWords[PC.OffsetWords + (Page shl 11) + (Block shl 6) + Column];
  end
  else
  begin
    var Page := (X shr 6) + (Y shr 6) * PC.WidthPages;
    var BX := (X shr 4) and 3;
    var BY := (Y shr 3) and 7;
    var Block: Cardinal;
    if (PC.Format and 8) <> 0 then
      Block := ((BX and 1) shl 1) or ((BX and 2) shl 3) or (BY and 1) or
        ((BY and 2) shl 2) or (BY and 4)
    else
      Block := ((BX and 1) shl 1) or ((BX and 2) shl 2) or (BY and 1) or
        ((BY and 2) shl 1) or ((BY and 4) shl 2);
    if ZFormat then
      Block := Block xor 24;
    var Column := ((X and 1) shl 1) or ((X and 2) shl 2) or ((X and 4) shl 2) or
      ((X and 8) shr 3) or ((Y and 1) shl 2) or ((Y and 2) shl 4) or ((Y and 4) shl 4);
    var At := (Page shl 12) + (Block shl 7) + Column;
    Raw := (SourceWords[PC.OffsetWords + (At shr 1)] shr ((At and 1) * 16)) and $FFFF;
  end;
  var Value: Cardinal;
  if PC.Depth <> 0 then
  begin
    Raw := Raw and (if Small then Cardinal($FFFF) else Cardinal($FFFFFF));
    Value := 0;
    if Raw <> 0 then
    begin
      var HighBit := FindMSB(Raw);
      var RangeBits := if Small then 16 else 24;
      Value := (Cardinal(HighBit + 127 - RangeBits) shl 23) or
        ((Raw shl Cardinal(23 - HighBit)) and $7FFFFF);
    end;
  end
  else if Small then
    Value := ((Raw and 31) shl 3) or (((Raw shr 5) and 31) shl 11) or
      (((Raw shr 10) and 31) shl 19) or (if (Raw and $8000) <> 0 then Cardinal($FF000000) else Cardinal(0))
  else if PC.Format = 1 then
    Value := (Raw and $FFFFFF) or $80000000
  else
    Value := Raw;
  ImageWords[Q.Y * PC.Width + Q.X] := Value;
end;
