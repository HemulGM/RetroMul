type
  TPS2HLEUploadPush = record
    OffsetWords, WidthPages, Format, Scale, Width, Height, FirstY, Depth: Cardinal;
  end;

var
  [Binding(0, 0), ReadOnly]
  SourceWords: array of Cardinal;
  [Binding(0, 1), WriteOnly]
  OutputImage: Image2D_RGBA8;
  [PushConstant]
  PC: TPS2HLEUploadPush;

[Vulkan11, LocalSize(8, 8, 1)]
procedure Main;
begin
  var Q: Cardinal2 := GlobalInvocationID.XY;
  if (Q.X >= PC.Width) or (Q.Y >= PC.Height) then
    Exit;
  var X := Q.X;
  var Y := Q.Y;
  var Small := (PC.Format = 2) or (PC.Format = $A) or (PC.Format = $32) or (PC.Format = $3A);
  var ZFormat := (PC.Format and $30) = $30;
  var Raw: Cardinal;
  if not Small then
  begin
    var Page := (X shr 6) + (Y shr 5) * PC.WidthPages;
    var BX := (X shr 3) and 7;
    var BY := (Y shr 3) and 3;
    var Block := (BX and 1) or ((BX and 2) shl 1) or ((BX and 4) shl 2) or ((BY and 1) shl 1) or ((BY and 2) shl 2);
    if ZFormat then
      Block := Block xor 24;
    var Column := (X and 1) or ((Y and 1) shl 1) or (((X shr 1) and 3) shl 2) or (((Y shr 1) and 3) shl 4);
    Raw := SourceWords[PC.OffsetWords + (Page shl 11) + (Block shl 6) + Column];
  end
  else
  begin
    var Page := (X shr 6) + (Y shr 6) * PC.WidthPages;
    var BX := (X shr 4) and 3;
    var BY := (Y shr 3) and 7;
    var Block: Cardinal;
    if (PC.Format and 8) <> 0 then
      Block := ((BX and 1) shl 1) or ((BX and 2) shl 3) or (BY and 1) or ((BY and 2) shl 2) or (BY and 4)
    else
      Block := ((BX and 1) shl 1) or ((BX and 2) shl 2) or (BY and 1) or ((BY and 2) shl 1) or ((BY and 4) shl 2);
    if ZFormat then
      Block := Block xor 24;
    var Column :=
      ((X and 1) shl 1)
        or ((X and 2) shl 2)
        or ((X and 4) shl 2)
        or ((X and 8) shr 3)
        or ((Y and 1) shl 2)
        or ((Y and 2) shl 4)
        or ((Y and 4) shl 4);
    var At := (Page shl 12) + (Block shl 7) + Column;
    Raw := (SourceWords[PC.OffsetWords + (At shr 1)] shr ((At and 1) * 16)) and $FFFF;
  end;
  var Value: Cardinal;
  if Small then
    Value :=
      ((Raw and 31) shl 3)
        or (((Raw shr 5) and 31) shl 11)
        or (((Raw shr 10) and 31) shl 19)
        or (if (Raw and $8000) <> 0 then Cardinal($FF000000)
        else
          Cardinal(0))
  else if PC.Format = 1 then
    Value := (Raw and $FFFFFF) or $80000000
  else
    Value := Raw;
  var C :=
    Single4(Single(Value and 255), Single((Value shr 8) and 255), Single((Value shr 16) and 255), Single(Value shr 24))
      / 255.0;
  var P := Integer2(Integer(Q.X shl 1), Integer(Q.Y shl 1));
  ImageStore(OutputImage, P, C);
  ImageStore(OutputImage, P + Integer2(1, 0), C);
  ImageStore(OutputImage, P + Integer2(0, 1), C);
  ImageStore(OutputImage, P + Integer2(1, 1), C);
end;
