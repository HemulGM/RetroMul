unit Media.Image.GIF;

interface

uses
  System.SysUtils, Media.Image.Types;

// Static bitmap API: the first image is placed on the logical screen. Later
// frames are structurally checked, but are not animated or composited.
function DecodeGIF(const Data: TBytes; MaxPixels: Integer = 16 * 1024 * 1024): TRasterImage;

implementation

uses
  System.Math;

type
  TPalette = TArray<UInt32>;

procedure Bad(const Why: string);
begin
  raise EImageFormat.Create('GIF: ' + Why);
end;

function DecodeGIF(const Data: TBytes; MaxPixels: Integer): TRasterImage;
var
  At: Integer;

  procedure Need(Count: Integer);
  begin
    if (Count < 0) or (Count > Length(Data) - At) then
      Bad('truncated data');
  end;

  function U8: Integer;
  begin
    Need(1);
    Result := Data[At];
    Inc(At);
  end;

  function U16: Integer;
  begin
    Result := U8;
    Result := Result or (U8 shl 8);
  end;

  function Palette(Count: Integer): TPalette;
  begin
    Need(Count * 3);
    SetLength(Result, Count);
    for var K := 0 to Count - 1 do
    begin
      var R := U8;
      var G := U8;
      var B := U8;
      Result[K] := $FF000000 or (UInt32(R) shl 16) or (UInt32(G) shl 8) or UInt32(B);
    end;
  end;

  function Blocks: TBytes;
  begin
    // Count first so an arbitrarily fragmented stream does not repeatedly
    // reallocate/copy the accumulated bytes.
    var Start := At;
    var Total := 0;
    repeat
      var Count := U8;
      if Count = 0 then
        Break;
      Need(Count);
      Inc(Total, Count);
      Inc(At, Count);
    until False;
    var Finish := At;
    At := Start;
    SetLength(Result, Total);
    var Offset := 0;
    repeat
      var Count := U8;
      if Count = 0 then
        Break;
      Move(Data[At], Result[Offset], Count);
      Inc(Offset, Count);
      Inc(At, Count);
    until False;
    At := Finish;
  end;

  function Indices(const Encoded: TBytes; Minimum, Expected: Integer): TBytes;
  var
    Prefix: array[0..4095] of Word;
    Suffix: array[0..4095] of Byte;
    Stack: array[0..4095] of Byte;
    Bits, CodeSize: Integer;

    function Code: Integer;
    begin
      if Int64(Bits) + CodeSize > Int64(Length(Encoded)) * 8 then
        Bad('truncated LZW code');
      Result := 0;
      for var B := 0 to CodeSize - 1 do
        Result := Result or (((Encoded[(Bits + B) div 8] shr ((Bits + B) and 7)) and 1) shl B);
      Inc(Bits, CodeSize);
    end;

  begin
    if (Minimum < 2) or (Minimum > 8) then
      Bad('LZW minimum code size');
    SetLength(Result, Expected);
    Bits := 0;
    var Clear := 1 shl Minimum;
    var EndCode := Clear + 1;
    var Next := EndCode + 1;
    CodeSize := Minimum + 1;
    var Previous := -1;
    var Written := 0;
    var First := 0;
    for var K := 0 to Clear - 1 do
      Suffix[K] := K;
    repeat
      var Value := Code;
      if Value = Clear then
      begin
        Next := EndCode + 1;
        CodeSize := Minimum + 1;
        Previous := -1;
        Continue;
      end;
      if Value = EndCode then
        Break;
      if (Value > Next) or ((Previous < 0) and (Value >= Clear)) then
        Bad('invalid LZW dictionary reference');
      var Original := Value;
      var Depth := 0;
      if Value = Next then
      begin
        Stack[Depth] := First;
        Inc(Depth);
        Value := Previous;
      end;
      while Value >= Clear do
      begin
        if (Value >= Next) or (Value <= EndCode) or (Depth >= Length(Stack) - 1) then
          Bad('invalid LZW prefix chain');
        Stack[Depth] := Suffix[Value];
        Inc(Depth);
        Value := Prefix[Value];
      end;
      First := Value;
      Stack[Depth] := First;
      Inc(Depth);
      if Depth > Expected - Written then
        Bad('LZW exceeds image dimensions');
      for var K := Depth - 1 downto 0 do
      begin
        Result[Written] := Stack[K];
        Inc(Written);
      end;
      if (Previous >= 0) and (Next < 4096) then
      begin
        Prefix[Next] := Previous;
        Suffix[Next] := First;
        Inc(Next);
        if (Next = (1 shl CodeSize)) and (CodeSize < 12) then
          Inc(CodeSize);
      end;
      Previous := Original;
    until False;
    if Written <> Expected then
      Bad('LZW image is incomplete');
  end;

begin
  Result := Default(TRasterImage);
  At := 0;
  if (Length(Data) < 13) or (Length(Data) > 64 * 1024 * 1024) then
    Bad('file size');
  if (Data[0] <> Ord('G')) or (Data[1] <> Ord('I')) or (Data[2] <> Ord('F')) or (Data[3] <> Ord('8')) or
    not (Data[4] in [Ord('7'), Ord('9')]) or (Data[5] <> Ord('a')) then
    Bad('signature');
  At := 6;
  Result.Width := U16;
  Result.Height := U16;
  if (Result.Width = 0) or (Result.Height = 0) then
    Bad('logical screen dimensions');
  if (MaxPixels < 1) or (Int64(Result.Width) * Result.Height > MaxPixels) then
    raise EImageResourceLimit.Create('GIF pixel limit');
  var ScreenFlags := U8;
  var Background := U8;
  U8; // Pixel aspect ratio is presentation metadata.
  var Global: TPalette := nil;
  if (ScreenFlags and $80) <> 0 then
    Global := Palette(1 shl ((ScreenFlags and 7) + 1));
  var Transparent := -1;
  var Found := False;
  var Frames := 0;
  repeat
    case U8 of
      $3B:
        begin
          if not Found then
            Bad('no image');
          if At <> Length(Data) then
            Bad('data after trailer');
          Exit;
        end;
      $21:
        begin
          case U8 of
            $F9:
              begin
                if U8 <> 4 then
                  Bad('graphic control size');
                var Flags := U8;
                if ((Flags and $E0) <> 0) or (((Flags shr 2) and 7) > 3) then
                  Bad('graphic control flags');
                U16;
                var Index := U8;
                Transparent := -1;
                if (Flags and 1) <> 0 then
                  Transparent := Index;
                if U8 <> 0 then
                  Bad('graphic control terminator');
              end;
            $FE:
              Blocks;
            $FF:
              begin
                if U8 <> 11 then
                  Bad('application identifier size');
                Need(11);
                Inc(At, 11);
                Blocks;
              end;
            $01:
              Bad('plain text graphics are not supported');
          else
            Bad('unknown extension');
          end;
        end;
      $2C:
        begin
          Inc(Frames);
          if Frames > 100000 then
            Bad('frame limit');
          var Left := U16;
          var Top := U16;
          var Width := U16;
          var Height := U16;
          var Flags := U8;
          if ((Flags and $18) <> 0) or (Width = 0) or (Height = 0) or
            (Left + Width > Result.Width) or (Top + Height > Result.Height) then
            Bad('image bounds/flags');
          var Colors := Global;
          if (Flags and $80) <> 0 then
            Colors := Palette(1 shl ((Flags and 7) + 1));
          if Length(Colors) = 0 then
            Bad('missing color table');
          var Minimum := U8;
          if (Minimum < 2) or (Minimum > 8) then
            Bad('LZW minimum code size');
          var Encoded := Blocks;
          if not Found then
          begin
            var Pixels := Indices(Encoded, Minimum, Width * Height);
            SetLength(Result.Pixels, Result.Width * Result.Height);
            var Color: UInt32 := 0;
            if (Transparent < 0) and (Background < Length(Global)) then
              Color := Global[Background];
            for var K := 0 to High(Result.Pixels) do
              Result.Pixels[K] := Color;
            var Offset := 0;
            for var Pass := 0 to 3 do
            begin
              var Y := 0;
              var Step := 1;
              if (Flags and $40) <> 0 then
                case Pass of
                  0:
                    Step := 8;
                  1:
                    begin
                      Y := 4;
                      Step := 8;
                    end;
                  2:
                    begin
                      Y := 2;
                      Step := 4;
                    end;
                  3:
                    begin
                      Y := 1;
                      Step := 2;
                    end;
                end
              else if Pass <> 0 then
                Break;
              while Y < Height do
              begin
                for var X := 0 to Width - 1 do
                begin
                  var Index := Pixels[Offset];
                  Inc(Offset);
                  if Index >= Length(Colors) then
                    Bad('palette index');
                  Color := Colors[Index];
                  if Index = Transparent then
                    Color := Color and $FFFFFF;
                  Result.Pixels[(Top + Y) * Result.Width + Left + X] := Color;
                end;
                Inc(Y, Step);
              end;
            end;
            Found := True;
          end;
          Transparent := -1;
        end;
    else
      Bad('unknown block');
    end;
  until False;
end;

end.

