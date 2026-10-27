unit PS1.MDEC;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, PS1.Types, PS1.DMA;

type
  TPS1MDECBlock = array[0..63] of Integer;

  // Macroblock decoder (psx-spx "Macroblock Decoder (MDEC)"): commands and
  // parameters through the data port or DMA0, run-length decoding with the
  // quant tables, IDCT with the scale table, YUV to RGB (15/24 bit) or
  // monochrome (4/8 bit) output through the data port or DMA1. Decoding is
  // immediate; a macroblock is decoded once the previous one has been read.
  TPS1MDEC = class(TPS1DMADevice)
  private
    FEnableIn, FEnableOut: Boolean;
    // Last command word and the parameter words it still expects.
    FCommand: Cardinal;
    FRemaining: Integer;
    FStatusCount: Word;
    // Received parameter halfwords not yet decoded.
    FInput: TArray<Word>;
    FInputHead, FInputCount: Integer;
    FLuma, FChroma: array[0..63] of Byte;
    FScale: array[0..63] of SmallInt;
    // Cr, Cb, Y1..Y4 of the macroblock being decoded, and the next one.
    FBlocks: array[0..5] of TPS1MDECBlock;
    FBlock: Integer;
    // Decoded macroblock in DMA1 order (rows of the 16x16 or 8x8 picture).
    FOutput: array[0..191] of Cardinal;
    FOutputCount, FOutputRead: Integer;
    FInDMA: Boolean;
    function Depth: Integer; inline;
    function Busy: Boolean;
    function InputFull: Boolean; inline;
    procedure Push(Value: Word);
    procedure Parameter(Value: Cardinal);
    procedure LoadTables;
    function DecodeBlock(var Block: TPS1MDECBlock; const Quant: array of Byte): Boolean;
    procedure IDCT(var Block: TPS1MDECBlock);
    procedure OutputMono(const Block: TPS1MDECBlock);
    procedure OutputColor;
    procedure Process;
    function NextWord(Ordered: Boolean): Cardinal;
    procedure Notify;
  public
    // DMA0 or DMA1 may run.
    OnReady: TPS1Notify;
    procedure Reset;
    function Read(Address: Cardinal): Cardinal;
    procedure Write(Address, Value: Cardinal);
    function Status: Cardinal;
    function DMARequest(Channel: Integer): Boolean; override;
    procedure DMAWrite(Channel: Integer; Data: PCardinal; Count: Integer); override;
    procedure DMARead(Channel: Integer; Data: PCardinal; Count: Integer); override;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

const
  // psx-spx "zigzag[0..63]": raster position to scan index.
  ZigZag: array[0..63] of Integer = (
    0, 1, 5, 6, 14, 15, 27, 28,
    2, 4, 7, 13, 16, 26, 29, 42,
    3, 8, 12, 17, 25, 30, 41, 43,
    9, 11, 18, 24, 31, 40, 44, 53,
    10, 19, 23, 32, 39, 45, 52, 54,
    20, 22, 33, 38, 46, 51, 55, 60,
    21, 34, 37, 47, 50, 56, 59, 61,
    35, 36, 48, 49, 57, 58, 62, 63);

  // Input FIFO size in halfwords (32 words).
  InputFIFO = 64;
  // Fraction bits of IDCT output and YUV conversion.
  Fraction = 7;
  CommandDecode = 1;
  CommandQuant = 2;
  CommandScale = 3;

var
  ZagZig: array[0..63] of Integer;

function Sar(Value: Integer; Count: Integer): Integer; inline;
begin
  if Value < 0 then
    Result := not ((not Value) shr Count)
  else
    Result := Value shr Count;
end;

function Clamp(Value, Low, High: Integer): Integer; inline;
begin
  if Value < Low then
    Result := Low
  else if Value > High then
    Result := High
  else
    Result := Value;
end;

function Signed10(Value: Word): Integer; inline;
begin
  Result := Integer((Value and $3FF) xor $200) - $200;
end;

function Signed9(Value: Integer): Integer; inline;
begin
  Result := Integer((Value and $1FF) xor $100) - $100;
end;

procedure TPS1MDEC.Reset;
begin
  FEnableIn := False;
  FEnableOut := False;
  FCommand := 0;
  FRemaining := 0;
  FStatusCount := 0;
  FInputHead := 0;
  FInputCount := 0;
  FBlock := 0;
  FOutputCount := 0;
  FOutputRead := 0;
end;

function TPS1MDEC.Depth: Integer;
begin
  Result := (FCommand shr 27) and 3;
end;

// Queued input is decoded as soon as the output is free, so the FIFO only
// fills while a decoded macroblock waits to be read.
function TPS1MDEC.InputFull: Boolean;
begin
  Result := (FOutputRead < FOutputCount) and (FInputCount >= InputFIFO);
end;

function TPS1MDEC.Busy: Boolean;
begin
  Result := (FRemaining > 0) or (FInputCount > 0) or (FOutputRead < FOutputCount);
end;

function TPS1MDEC.Status: Cardinal;
begin
  Result := FStatusCount or (((FCommand shr 25) and $F) shl 23);
  var Block: Cardinal := 4;
  if FOutputRead < FOutputCount then
  begin
    // Output in block order: Y1..Y4, or Y for monochrome.
    if Depth >= 2 then
      Block := Cardinal(FOutputRead * 4 div FOutputCount);
  end
  else if (Depth >= 2) and ((FCommand shr 29) = CommandDecode) then
  begin
    // Block being received: Cr, Cb, Y1..Y4.
    case FBlock of
      0:
        Block := 4;
      1:
        Block := 5;
    else
      Block := Cardinal(FBlock - 2);
    end;
  end;
  Result := Result or (Block shl 16);
  if FEnableOut and (FOutputRead < FOutputCount) then
    Result := Result or $08000000;
  if FEnableIn and (FRemaining > 0) and not InputFull then
    Result := Result or $10000000;
  if Busy then
    Result := Result or $20000000;
  // Full, or the last word received while undecoded data remains.
  if InputFull or ((FRemaining = 0) and (FInputCount > 0)) then
    Result := Result or $40000000;
  if FOutputRead >= FOutputCount then
    Result := Result or $80000000;
end;

procedure TPS1MDEC.Push(Value: Word);
begin
  if FInputHead + FInputCount >= Length(FInput) then
  begin
    if FInputHead > 0 then
    begin
      if FInputCount > 0 then
        Move(FInput[FInputHead], FInput[0], FInputCount * SizeOf(Word));
      FInputHead := 0;
    end;
    if FInputCount >= Length(FInput) then
      SetLength(FInput, Length(FInput) * 2 + 256);
  end;
  FInput[FInputHead + FInputCount] := Value;
  Inc(FInputCount);
end;

// MDEC(2) and MDEC(3) parameters, once all have arrived.
procedure TPS1MDEC.LoadTables;
begin
  case FCommand shr 29 of
    CommandQuant:
      begin
        for var I := 0 to 31 do
        begin
          FLuma[I * 2] := Byte(FInput[FInputHead + I]);
          FLuma[I * 2 + 1] := Byte(FInput[FInputHead + I] shr 8);
        end;
        if (FCommand and 1) <> 0 then
          for var I := 0 to 31 do
          begin
            FChroma[I * 2] := Byte(FInput[FInputHead + 32 + I]);
            FChroma[I * 2 + 1] := Byte(FInput[FInputHead + 32 + I] shr 8);
          end;
      end;
    CommandScale:
      for var I := 0 to 63 do
        FScale[I] := SmallInt(FInput[FInputHead + I]);
  end;
  FInputHead := 0;
  FInputCount := 0;
end;

procedure TPS1MDEC.Parameter(Value: Cardinal);
begin
  if FRemaining = 0 then
  begin
    // A new command; data left from an unfinished one is dropped.
    FCommand := Value;
    FInputHead := 0;
    FInputCount := 0;
    FBlock := 0;
    case Value shr 29 of
      CommandDecode:
        FRemaining := Integer(Value and $FFFF);
      CommandQuant:
        if (Value and 1) <> 0 then
          FRemaining := 32
        else
          FRemaining := 16;
      CommandScale:
        FRemaining := 32;
    else
      FRemaining := 0;
    end;
    if (Value shr 29) in [CommandDecode, CommandQuant, CommandScale] then
      FStatusCount := Word(FRemaining - 1)
    else
      FStatusCount := Word(Value);
    Exit;
  end;

  Dec(FRemaining);
  FStatusCount := Word(FRemaining - 1);
  Push(Word(Value));
  Push(Word(Value shr 16));
  if (FRemaining = 0) and ((FCommand shr 29) in [CommandQuant, CommandScale]) then
    LoadTables;
end;

// psx-spx "rl_decode_block": FE00h before a block is padding; a block ends
// with FE00h (or any code that skips past entry 63) or after entry 63.
// Returns False, consuming nothing but padding, until the block is complete.
function TPS1MDEC.DecodeBlock(var Block: TPS1MDECBlock; const Quant: array of Byte): Boolean;
begin
  var Cursor := FInputHead;
  var Last := FInputHead + FInputCount;
  while (Cursor < Last) and (FInput[Cursor] = $FE00) do
    Inc(Cursor);
  FInputCount := Last - Cursor;
  FInputHead := Cursor;
  if Cursor >= Last then
    Exit(False);

  var Coefficients: TPS1MDECBlock;
  FillChar(Coefficients, SizeOf(Coefficients), 0);
  var N := FInput[Cursor];
  Inc(Cursor);
  var Scale := Integer(N shr 10);
  var K := 0;
  // Coefficients keep one fraction bit.
  var Value := Signed10(N) * Quant[0] * 2;
  while True do
  begin
    if Scale = 0 then
      Value := Signed10(N) * 4;
    Value := Clamp(Value, -$800, $7FF);
    if Scale > 0 then
      Coefficients[ZagZig[K]] := Value
    else
      Coefficients[K] := Value;
    if K = 63 then
      Break;
    if Cursor >= Last then
      Exit(False);
    N := FInput[Cursor];
    Inc(Cursor);
    Inc(K, Integer(N shr 10) + 1);
    if K > 63 then
      Break;
    Value := Sar(Signed10(N) * Quant[K] * Scale, 2);
  end;
  FInputCount := Last - Cursor;
  FInputHead := Cursor;
  if FInputCount = 0 then
    FInputHead := 0;
  Block := Coefficients;
  IDCT(Block);
  Result := True;
end;

function TruncShift(Value, Count: Integer): Integer; inline;
begin
  if Value < 0 then
    Result := -((-Value) shr Count)
  else
    Result := Value shr Count;
end;

// psx-spx "real_idct_core": two passes of a matrix product with the upper
// 13 bits of the scale table, each transposing the block. The product and
// sum precision is the closest fit found to the hardware output of
// ps1-tests mdec/8bit, step-by-step-log and frame (not exact: about 9% of
// pixels are off by one or two).
// Zero coefficients contribute exactly zero and are skipped: most blocks
// hold a few low frequencies, and a zero input column makes a zero row of
// the intermediate block.
procedure TPS1MDEC.IDCT(var Block: TPS1MDECBlock);
var
  Temp: TPS1MDECBlock;
  Scale: array[0..63] of Integer;
  Rows: array[0..7] of Boolean;
begin
  for var I := 0 to 63 do
    Scale[I] := Sar(FScale[I], 3);
  FillChar(Temp, SizeOf(Temp), 0);
  for var Y := 0 to 7 do
  begin
    Rows[Y] := False;
    for var Z := 0 to 7 do
    begin
      var Value := Block[Y + Z * 8];
      if Value = 0 then
        Continue;
      Rows[Y] := True;
      for var X := 0 to 7 do
        Inc(Temp[X + Y * 8], TruncShift(Value * Scale[X + Z * 8], 11));
    end;
  end;
  FillChar(Block, SizeOf(Block), 0);
  for var Y := 0 to 7 do
    for var Z := 0 to 7 do
    begin
      if not Rows[Z] then
        Continue;
      var Value := Temp[Y + Z * 8];
      if Value = 0 then
        Continue;
      // Kept with Fraction bits until the output is rounded.
      for var X := 0 to 7 do
        Inc(Block[X + Y * 8], TruncShift(Value * Scale[X + Z * 8], 9));
    end;
end;

// A pixel component with Fraction bits as an output value of Bits bits:
// psx-spx "y_to_mono" 9-bit wrap (monochrome only: colour output saturates,
// mdec/movie) and saturation, the unsigned offset, then
// rounding (15-bit and 4-bit output are rounded from the full value, as
// mdec/4bit, step-by-step-log and frame show).
function Quantize(Value: Integer; Bits: Integer; Unsigned, Wrap: Boolean): Cardinal; inline;
begin
  var V := Value;
  if Wrap then
    V := ((V + (256 shl Fraction)) and ((512 shl Fraction) - 1)) - (256 shl Fraction);
  V := Clamp(V, -128 shl Fraction, (128 shl Fraction) - 1);
  if Unsigned then
    Inc(V, 128 shl Fraction);
  var Shift := Fraction + 8 - Bits;
  V := Sar(V + (1 shl (Shift - 1)), Shift);
  if Unsigned then
    V := Clamp(V, 0, (1 shl Bits) - 1)
  else
    V := Clamp(V, -(1 shl (Bits - 1)), (1 shl (Bits - 1)) - 1);
  Result := Cardinal(V) and ((Cardinal(1) shl Bits) - 1);
end;

// psx-spx "y_to_mono": 9-bit wrap, saturation to 8 bits; 4-bit output has
// the first pixel in the low nibble.
procedure TPS1MDEC.OutputMono(const Block: TPS1MDECBlock);
var
  Pixels: array[0..63] of Byte;
begin
  var Unsigned := (FCommand and $04000000) = 0;
  var Bits := 4;
  if Depth = 1 then
    Bits := 8;
  for var I := 0 to 63 do
    Pixels[I] := Byte(Quantize(Block[I], Bits, Unsigned, True));
  if Depth = 1 then
  begin
    for var W := 0 to 15 do
      FOutput[W] := Cardinal(Pixels[W * 4]) or (Cardinal(Pixels[W * 4 + 1]) shl 8) or
        (Cardinal(Pixels[W * 4 + 2]) shl 16) or (Cardinal(Pixels[W * 4 + 3]) shl 24);
    FOutputCount := 16;
  end
  else
  begin
    for var W := 0 to 7 do
    begin
      var Value: Cardinal := 0;
      for var I := 0 to 7 do
        Value := Value or (Cardinal(Pixels[W * 8 + I]) shl (I * 4));
      FOutput[W] := Value;
    end;
    FOutputCount := 8;
  end;
  FOutputRead := 0;
end;

// psx-spx "yuv_to_rgb" for Y1..Y4 with the 8x8 Cr/Cb blocks scaled up.
procedure TPS1MDEC.OutputColor;
var
  Pixels: array[0..255, 0..2] of Byte;
begin
  var Unsigned := (FCommand and $04000000) = 0;
  var Bits := 8;
  if Depth = 3 then
    Bits := 5;
  for var B := 0 to 3 do
  begin
    var XX := (B and 1) * 8;
    var YY := (B shr 1) * 8;
    for var Y := 0 to 7 do
      for var X := 0 to 7 do
      begin
        var C := ((X + XX) shr 1) + ((Y + YY) shr 1) * 8;
        var Cr := FBlocks[0][C];
        var Cb := FBlocks[1][C];
        var L := FBlocks[2 + B][X + Y * 8];
        // 1.402, -0.3437, -0.7143 and 1.772 (psx-spx) with 12 fraction bits.
        // 24-bit output fits the hardware best from whole Y/Cr/Cb values,
        // 15-bit output from the full values (ps1-tests mdec/frame).
        var R, G, Bl: Integer;
        if Bits = 8 then
        begin
          Cr := Sar(Cr + (1 shl (Fraction - 1)), Fraction);
          Cb := Sar(Cb + (1 shl (Fraction - 1)), Fraction);
          L := Sar(L + (1 shl (Fraction - 1)), Fraction) shl Fraction;
          R := Sar(Cr * 5743 + 2048, 12) shl Fraction;
          G := Sar(-Cb * 1408 - Cr * 2926 + 2048, 12) shl Fraction;
          Bl := Sar(Cb * 7258 + 2048, 12) shl Fraction;
        end
        else
        begin
          R := Sar(Cr * 5743, 12);
          G := Sar(-Cb * 1408 - Cr * 2926, 12);
          Bl := Sar(Cb * 7258, 12);
        end;
        var P := (X + XX) + (Y + YY) * 16;
        Pixels[P, 0] := Byte(Quantize(L + R, Bits, Unsigned, False));
        Pixels[P, 1] := Byte(Quantize(L + G, Bits, Unsigned, False));
        Pixels[P, 2] := Byte(Quantize(L + Bl, Bits, Unsigned, False));
      end;
  end;
  if Depth = 3 then
  begin
    var Mask: Cardinal := 0;
    if (FCommand and $02000000) <> 0 then
      Mask := $8000;
    for var W := 0 to 127 do
    begin
      var Value: Cardinal := 0;
      for var H := 0 to 1 do
      begin
        var P := W * 2 + H;
        var Pixel := Cardinal(Pixels[P, 0]) or (Cardinal(Pixels[P, 1]) shl 5) or
          (Cardinal(Pixels[P, 2]) shl 10) or Mask;
        Value := Value or (Pixel shl (H * 16));
      end;
      FOutput[W] := Value;
    end;
    FOutputCount := 128;
  end
  else
  begin
    var Bytes: array[0..767] of Byte;
    for var P := 0 to 255 do
      for var I := 0 to 2 do
        Bytes[P * 3 + I] := Pixels[P, I];
    for var W := 0 to 191 do
      FOutput[W] := Cardinal(Bytes[W * 4]) or (Cardinal(Bytes[W * 4 + 1]) shl 8) or
        (Cardinal(Bytes[W * 4 + 2]) shl 16) or (Cardinal(Bytes[W * 4 + 3]) shl 24);
    FOutputCount := 192;
  end;
  FOutputRead := 0;
end;

// Decodes blocks while the output is empty and complete blocks are queued.
procedure TPS1MDEC.Process;
begin
  if (FCommand shr 29) <> CommandDecode then
    Exit;

  while FOutputRead >= FOutputCount do
  begin
    if Depth <= 1 then
    begin
      if not DecodeBlock(FBlocks[2], FLuma) then
        Break;
      OutputMono(FBlocks[2]);
    end
    else
    begin
      if FBlock < 2 then
      begin
        if not DecodeBlock(FBlocks[FBlock], FChroma) then
          Break;
      end
      else if not DecodeBlock(FBlocks[FBlock], FLuma) then
        Break;
      Inc(FBlock);
      if FBlock = 6 then
      begin
        FBlock := 0;
        OutputColor;
      end;
    end;
  end;
end;

// Words leave in DMA1 order, which builds the 16x16 picture; read through
// the data port they come block by block (8x8 pixels each).
function TPS1MDEC.NextWord(Ordered: Boolean): Cardinal;
begin
  if FOutputRead >= FOutputCount then
    Exit(0);

  var Index := FOutputRead;
  if not Ordered and (FOutputCount > 16) then
  begin
    var PerBlock := FOutputCount div 4;
    var PerRow := PerBlock div 8;
    var Block := Index div PerBlock;
    var Within := Index mod PerBlock;
    Index := ((Block shr 1) * 8 + Within div PerRow) * PerRow * 2 + (Block and 1) * PerRow + Within mod PerRow;
  end;
  Result := FOutput[Index];
  Inc(FOutputRead);
  if FOutputRead >= FOutputCount then
  begin
    FOutputRead := 0;
    FOutputCount := 0;
    Process;
  end;
end;

procedure TPS1MDEC.Notify;
begin
  if not FInDMA and Assigned(OnReady) and (DMARequest(0) or DMARequest(1)) then
    OnReady;
end;

function TPS1MDEC.Read(Address: Cardinal): Cardinal;
begin
  if (Address and 4) <> 0 then
    Exit(Status);

  Result := NextWord(False);
  Notify;
end;

procedure TPS1MDEC.Write(Address, Value: Cardinal);
begin
  if (Address and 4) <> 0 then
  begin
    if (Value and $80000000) <> 0 then
    begin
      FCommand := 0;
      FRemaining := 0;
      FStatusCount := 0;
      FInputHead := 0;
      FInputCount := 0;
      FBlock := 0;
      FOutputCount := 0;
      FOutputRead := 0;
    end;
    FEnableIn := (Value and $40000000) <> 0;
    FEnableOut := (Value and $20000000) <> 0;
  end
  else
  begin
    Parameter(Value);
    Process;
  end;
  Notify;
end;

function TPS1MDEC.DMARequest(Channel: Integer): Boolean;
begin
  if Channel = 0 then
    Result := FEnableIn and (FRemaining > 0) and not InputFull
  else
    Result := FEnableOut and (FOutputRead < FOutputCount);
end;

procedure TPS1MDEC.DMAWrite(Channel: Integer; Data: PCardinal; Count: Integer);
begin
  FInDMA := True;
  try
    for var I := 0 to Count - 1 do
    begin
      if FRemaining = 0 then
        Break;
      Parameter(Data^);
      Inc(Data);
    end;
    Process;
  finally
    FInDMA := False;
  end;
end;

procedure TPS1MDEC.DMARead(Channel: Integer; Data: PCardinal; Count: Integer);
begin
  FInDMA := True;
  try
    for var I := 0 to Count - 1 do
    begin
      Data^ := NextWord(True);
      Inc(Data);
    end;
  finally
    FInDMA := False;
  end;
end;

procedure TPS1MDEC.SerializeState(State: TStateArchive);
begin
  State.Field(FEnableIn, SizeOf(FEnableIn));
  State.Field(FEnableOut, SizeOf(FEnableOut));
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FRemaining, SizeOf(FRemaining));
  State.Field(FStatusCount, SizeOf(FStatusCount));
  State.Field(FLuma, SizeOf(FLuma));
  State.Field(FChroma, SizeOf(FChroma));
  State.Field(FScale, SizeOf(FScale));
  State.Field(FBlocks, SizeOf(FBlocks));
  State.Field(FBlock, SizeOf(FBlock));
  State.Field(FOutput, SizeOf(FOutput));
  State.Field(FOutputCount, SizeOf(FOutputCount));
  State.Field(FOutputRead, SizeOf(FOutputRead));
  // Queued input: count, then the halfwords.
  var Count := FInputCount;
  State.Field(Count, SizeOf(Count));
  if State.Loading then
  begin
    if (Count < 0) or (Count > $20000) or (FRemaining < 0) or (FRemaining > $FFFF) or (FBlock < 0) or
      (FBlock > 5) or (FOutputCount < 0) or (FOutputCount > Length(FOutput)) or (FOutputRead < 0) or
      (FOutputRead > FOutputCount) then
      raise EReadError.Create('PS1 snapshot MDEC');
    FInputHead := 0;
    FInputCount := Count;
    if Length(FInput) < Count then
      SetLength(FInput, Count);
  end
  else if FInputHead > 0 then
  begin
    if FInputCount > 0 then
      Move(FInput[FInputHead], FInput[0], FInputCount * SizeOf(Word));
    FInputHead := 0;
  end;
  if Count > 0 then
    State.Field(FInput[0], Count * SizeOf(Word));
end;

initialization
  for var I := 0 to 63 do
    ZagZig[ZigZag[I]] := I;

end.

