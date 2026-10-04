unit SNES.SPC7110;

interface

uses
  System.SysUtils, System.DateUtils, Core.Snapshots;

type
  TSpcDataRead = function(Address: Cardinal): Byte of object;

  TSpcContext = packed record
    Prediction, Swap: Byte;
  end;

  PSpcContext = ^TSpcContext;

  TSpcDecoderState = packed record
    Context: array[0..4, 0..14] of TSpcContext;
    Bpp, Offset, Bits: Cardinal;
    Range, Input: Word;
    Output: Byte;
    Pixels, ColorMap: UInt64;
    Value: Cardinal;
  end;

  TSpc7110Decoder = class
  private
    FRead: TSpcDataRead;
    function ReadByte: Byte;
    function Deinterleave(Data: UInt64; Bits: Cardinal): Cardinal;
    function MoveToFront(List: UInt64; Nibble: Cardinal): UInt64;
  public
    State: TSpcDecoderState;
    constructor Create(ReadData: TSpcDataRead);
    procedure Initialize(Mode, Origin: Cardinal);
    procedure Decode;
  end;

  TRtc4513State = packed record
    Regs: array[0..15] of Byte;
    LastTime: Int64;
    Enabled: Byte;
    Mode, Index: ShortInt;
  end;

  TRtc4513 = class
  public
    State: TRtc4513State;
    constructor Create;
    procedure UpdateTime(Time: Int64);
    function Read(Address: Word): Byte;
    procedure Write(Address: Word; Value: Byte);
    function Battery: TBytes;
    procedure LoadBattery(const Data: TBytes);
  end;

  TSpc7110State = packed record
    DirectoryBase: Cardinal;
    DirectoryIndex: Byte;
    TargetOffset, LengthCounter: Word;
    SkipBytes, Flags, Mode: Byte;
    Source, Offset: Cardinal;
    Status: Byte;
    Buffer: array[0..31] of Byte;
    Dividend: Cardinal;
    Multiplier, Divisor: Word;
    ResultValue: Cardinal;
    Remainder: Word;
    AluState, AluFlags, SramEnabled: Byte;
    Banks: array[0..2] of Byte;
    DataSize: Byte;
    ReadBase: Cardinal;
    ReadOffset, ReadStep: Word;
    ReadMode, ReadBuffer: Byte;
  end;

  TSnesSPC7110 = class
  private
    FRead: TSpcDataRead;
    FDataSize: Cardinal;
    FDecoder: TSpc7110Decoder;
    FRTC: TRtc4513;
    procedure FillReadBuffer;
    procedure IncrementPosition;
    procedure BeginDecompression;
    function ReadDecompressed: Byte;
  public
    State: TSpc7110State;
    constructor Create(ReadROM: TSpcDataRead; DataSize: Cardinal; RTC: Boolean);
    destructor Destroy; override;
    procedure Reset;
    function ReadData(Address: Cardinal): Byte;
    function Read(Address: Cardinal; OpenBus: Byte): Byte;
    procedure Write(Address: Cardinal; Value: Byte);
    function ROMAddress(Address: Cardinal): Cardinal;
    procedure SerializeState(Archive: TStateArchive);
    function RTCBattery: TBytes;
    procedure LoadRTCBattery(const Data: TBytes);
  end;

implementation

const
  Evolution: array[0..52, 0..2] of Byte = (
    ($5A, 1, 1), ($25, 2, 6), ($11, 3, 8), ($08, 4, 10), ($03, 5, 12), ($01, 5, 15),
    ($5A, 7, 7), ($3F, 8, 19), ($2C, 9, 21), ($20, 10, 22), ($17, 11, 23), ($11, 12, 25),
    ($0C, 13, 26), ($09, 14, 28), ($07, 15, 29), ($05, 16, 31), ($04, 17, 32), ($03, 18, 34), ($02, 5, 35),
    ($5A, 20, 20), ($48, 21, 39), ($3A, 22, 40), ($2E, 23, 42), ($26, 24, 44), ($1F, 25, 45),
    ($19, 26, 46), ($15, 27, 25), ($11, 28, 26), ($0E, 29, 26), ($0B, 30, 27), ($09, 31, 28),
    ($08, 32, 29), ($07, 33, 30), ($05, 34, 31), ($04, 35, 33), ($04, 36, 33), ($03, 37, 34),
    ($02, 38, 35), ($02, 5, 36), ($58, 40, 39), ($4D, 41, 47), ($43, 42, 48), ($3B, 43, 49),
    ($34, 44, 50), ($2E, 45, 51), ($29, 46, 44), ($25, 24, 45), ($56, 48, 47), ($4F, 49, 47),
    ($47, 50, 48), ($41, 51, 49), ($3C, 52, 50), ($37, 43, 51));

constructor TSpc7110Decoder.Create(ReadData: TSpcDataRead);
begin
  inherited Create;
  FRead := ReadData;
end;

function TSpc7110Decoder.ReadByte: Byte;
begin
  Result := FRead(State.Offset);
  Inc(State.Offset);
end;

function TSpc7110Decoder.Deinterleave(Data: UInt64; Bits: Cardinal): Cardinal;
begin
  Data := Data and ((UInt64(1) shl Bits) - 1);
  Data := $5555555555555555 and ((Data shl Bits) or (Data shr 1));
  Data := $3333333333333333 and (Data or (Data shr 1));
  Data := $0F0F0F0F0F0F0F0F and (Data or (Data shr 2));
  Data := $00FF00FF00FF00FF and (Data or (Data shr 4));
  Data := $0000FFFF0000FFFF and (Data or (Data shr 8));
  Result := Cardinal(Data or (Data shr 16));
end;

function TSpc7110Decoder.MoveToFront(List: UInt64; Nibble: Cardinal): UInt64;
begin
  var Mask: UInt64 := not UInt64(15);
  for var N := 0 to 15 do
  begin
    if ((List shr (N * 4)) and 15) = Nibble then
      Exit((List and Mask) + ((List shl 4) and not Mask) + Nibble);
    Mask := Mask shl 4;
  end;
  Result := List;
end;

procedure TSpc7110Decoder.Initialize(Mode, Origin: Cardinal);
begin
  State := Default(TSpcDecoderState);
  State.Bpp := 1 shl Mode;
  State.Offset := Origin;
  State.Bits := 8;
  State.Range := 256;
  State.Input := ReadByte;
  State.Input := (State.Input shl 8) or ReadByte;
  State.ColorMap := $FEDCBA9876543210;
end;

procedure TSpc7110Decoder.Decode;
begin
  for var Pixel := 0 to 7 do
  begin
    var Map := State.ColorMap;
    var Diff: Cardinal := 0;
    if State.Bpp > 1 then
    begin
      var PA, PB, PC: Cardinal;
      if State.Bpp = 2 then
      begin
        PA := (State.Pixels shr 2) and 3;
        PB := (State.Pixels shr 14) and 3;
        PC := (State.Pixels shr 16) and 3;
      end
      else
      begin
        PA := State.Pixels and 15;
        PB := (State.Pixels shr 28) and 15;
        PC := (State.Pixels shr 32) and 15;
      end;
      if (PA <> PB) or (PB <> PC) then
      begin
        var Match := PA xor PB xor PC;
        Diff := 4;
        if (Match xor PC) = 0 then
          Diff := 3;
        if (Match xor PB) = 0 then
          Diff := 2;
        if (Match xor PA) = 0 then
          Diff := 1;
      end;
      State.ColorMap := MoveToFront(State.ColorMap, PA);
      Map := MoveToFront(Map, PC);
      Map := MoveToFront(Map, PB);
      Map := MoveToFront(Map, PA);
    end;
    for var Plane := 0 to Integer(State.Bpp) - 1 do
    begin
      var BitValue: Cardinal;
      if State.Bpp > 1 then
        BitValue := 1 shl Plane
      else
        BitValue := 1 shl (Pixel and 3);
      var History := (BitValue - 1) and State.Output;
      var SetIndex: Cardinal := 0;
      if State.Bpp = 1 then
        SetIndex := Ord(Pixel >= 4)
      else if State.Bpp = 2 then
        SetIndex := Diff;
      if (Plane >= 2) and (History <= 1) then
        SetIndex := Diff;
      var Context: PSpcContext := @State.Context[SetIndex, BitValue + History - 1];
      var Model := Evolution[Context.Prediction];
      var LpsOffset := Byte(State.Range - Model[0]);
      var Symbol: Cardinal := Ord(State.Input >= (Word(LpsOffset) shl 8));
      State.Output := Byte((State.Output shl 1) or (Symbol xor Context.Swap));
      if Symbol = 0 then
        State.Range := LpsOffset
      else
      begin
        Dec(State.Range, LpsOffset);
        Dec(State.Input, Word(LpsOffset) shl 8);
      end;
      while State.Range <= 127 do
      begin
        Context.Prediction := Model[1 + Symbol];
        State.Range := State.Range shl 1;
        State.Input := (State.Input shl 1) and $FFFF;
        Dec(State.Bits);
        if State.Bits = 0 then
        begin
          State.Bits := 8;
          Inc(State.Input, ReadByte);
        end;
      end;
      if (Symbol = 1) and (Model[0] > $55) then
        Context.Swap := Context.Swap xor 1;
    end;
    var Index := State.Output and ((1 shl State.Bpp) - 1);
    if State.Bpp = 1 then
      Index := Index xor ((State.Pixels shr 15) and 1);
    State.Pixels := (State.Pixels shl State.Bpp) or ((Map shr (4 * Index)) and 15);
  end;
  case State.Bpp of
    1:
      State.Value := Cardinal(State.Pixels);
    2:
      State.Value := Deinterleave(State.Pixels, 16);
    4:
      State.Value := Deinterleave(Deinterleave(State.Pixels, 32), 32);
  end;
end;

constructor TRtc4513.Create;
begin
  inherited;
  State.Mode := -1;
  State.Index := -1;
  State.LastTime := DateTimeToUnix(Now, False);
end;

procedure TRtc4513.UpdateTime(Time: Int64);
begin
  if (State.Regs[15] and 1) <> 0 then
  begin
    State.Regs[0] := 0;
    State.Regs[1] := 0;
  end;
  if Time <= State.LastTime then
    Exit;

  if State.Regs[8] + (State.Regs[9] and 1) * 10 = 0 then
  begin
    State.LastTime := Time;
    Exit;
  end;

  if ((State.Regs[15] and 3) = 0) and ((State.Regs[13] and 1) = 0) then
  begin
    var Year := State.Regs[10] + State.Regs[11] * 10;
    if Year >= 90 then
      Inc(Year, 1900)
    else
      Inc(Year, 2000);
    // mktime in Mesen normalizes even partially written or invalid BCD dates.
    var Stamp := IncMonth(EncodeDate(Year, 1, 1), State.Regs[8] + (State.Regs[9] and 1) * 10 - 1);
    Stamp := IncDay(Stamp, State.Regs[6] + (State.Regs[7] and 3) * 10 - 1);
    begin
      Stamp := IncSecond(Stamp, (State.Regs[4] + (State.Regs[5] and 3) * 10) * 3600 +
        (State.Regs[2] + (State.Regs[3] and 7) * 10) * 60 + State.Regs[0] + (State.Regs[1] and 7) * 10);
      var Gap := (DayOfWeek(Stamp) - 1) - Integer(State.Regs[12] and 7);
      Stamp := IncSecond(Stamp, Time - State.LastTime);
      var Y, M, D, H, N, S, MS: Word;
      DecodeDate(Stamp, Y, M, D);
      DecodeTime(Stamp, H, N, S, MS);
      State.Regs[0] := S mod 10;
      State.Regs[1] := S div 10;
      State.Regs[2] := N mod 10;
      State.Regs[3] := N div 10;
      State.Regs[4] := H mod 10;
      State.Regs[5] := H div 10;
      State.Regs[6] := D mod 10;
      State.Regs[7] := D div 10;
      State.Regs[8] := M mod 10;
      State.Regs[9] := M div 10;
      State.Regs[10] := Y mod 10;
      State.Regs[11] := (Y mod 100) div 10;
      State.Regs[12] := (DayOfWeek(Stamp) - 1 - Gap + 7) mod 7;
    end;
  end;
  State.LastTime := Time;
end;

function TRtc4513.Read(Address: Word): Byte;
begin
  UpdateTime(DateTimeToUnix(Now, False));
  Result := 0;
  if (Address = $4841) and (State.Mode = $C) and (State.Index >= 0) then
  begin
    Result := State.Regs[State.Index];
    State.Index := (State.Index + 1) and 15;
  end;
  if Address = $4842 then
    Result := $80;
end;

procedure TRtc4513.Write(Address: Word; Value: Byte);
begin
  UpdateTime(DateTimeToUnix(Now, False));
  case Address of
    $4840:
      begin
        State.Enabled := Value;
        if (Value and 1) = 0 then
        begin
          State.Mode := -1;
          State.Index := -1;
          State.Regs[15] := State.Regs[15] and 6;
        end;
      end;
    $4841:
      if State.Mode = -1 then
        State.Mode := Value and 15
      else if State.Index = -1 then
        State.Index := Value and 15
      else if State.Mode = 3 then
      begin
        State.Regs[State.Index] := Value and 15;
        State.Index := (State.Index + 1) and 15;
      end;
  end;
end;

function TRtc4513.Battery: TBytes;
begin
  SetLength(Result, 24);
  Move(State.Regs, Result[0], 16);
  for var J := 0 to 7 do
    Result[16 + J] := Byte(UInt64(State.LastTime) shr ((7 - J) * 8));
end;

procedure TRtc4513.LoadBattery(const Data: TBytes);
begin
  if Length(Data) <> 24 then
    raise EArgumentException.Create('SPC7110 RTC battery size mismatch');

  Move(Data[0], State.Regs, 16);
  State.LastTime := 0;
  for var J := 0 to 7 do
    State.LastTime := (State.LastTime shl 8) or Data[16 + J];
end;

constructor TSnesSPC7110.Create(ReadROM: TSpcDataRead; DataSize: Cardinal; RTC: Boolean);
begin
  inherited Create;
  FRead := ReadROM;
  FDataSize := DataSize;
  FDecoder := TSpc7110Decoder.Create(ReadData);
  if RTC then
    FRTC := TRtc4513.Create;
  Reset;
end;

destructor TSnesSPC7110.Destroy;
begin
  FRTC.Free;
  FDecoder.Free;
  inherited;
end;

procedure TSnesSPC7110.Reset;
begin
  State := Default(TSpc7110State);
  State.Banks[1] := 1;
  State.Banks[2] := 2;
  FDecoder.State := Default(TSpcDecoderState);
end;

function TSnesSPC7110.ReadData(Address: Cardinal): Byte;
begin
  if (Address >= FDataSize) or (Address >= Cardinal($100000) shl (State.DataSize and 3)) then
    Exit(0);

  Result := FRead($100000 + Address);
end;

procedure TSnesSPC7110.FillReadBuffer;
begin
  var Offset: Integer := 0;
  if (State.ReadMode and 2) <> 0 then
    Offset := State.ReadOffset;
  if (State.ReadMode and 8) <> 0 then
    Offset := SmallInt(Offset);
  State.ReadBuffer := ReadData(Cardinal((Int64(State.ReadBase) + Offset) and $FFFFFFFF));
end;

procedure TSnesSPC7110.IncrementPosition;
begin
  var Offset: Integer := State.ReadOffset;
  if (State.ReadMode and 8) <> 0 then
    Offset := SmallInt(Offset);
  State.ReadBase := Cardinal((Int64(State.ReadBase) + Offset) and $FFFFFFFF);
  FillReadBuffer;
end;

procedure TSnesSPC7110.BeginDecompression;
begin
  if State.Mode = 3 then
    Exit;

  FDecoder.Initialize(State.Mode, State.Source);
  FDecoder.Decode;
  if (State.Flags and 2) <> 0 then
    for var J := 1 to State.TargetOffset do
      FDecoder.Decode;
  State.Status := State.Status or $80;
  State.Offset := 0;
end;

function TSnesSPC7110.ReadDecompressed: Byte;
begin
  if (State.Status and $80) = 0 then
    Exit(0);

  var Bpp := FDecoder.State.Bpp;
  if State.Offset = 0 then
    for var J := 0 to 7 do
    begin
      var V := FDecoder.State.Value;
      case Bpp of
        1:
          State.Buffer[J] := Byte(V);
        2, 4:
          begin
            State.Buffer[J * 2] := Byte(V);
            State.Buffer[J * 2 + 1] := Byte(V shr 8);
            if Bpp = 4 then
            begin
              State.Buffer[J * 2 + 16] := Byte(V shr 16);
              State.Buffer[J * 2 + 17] := Byte(V shr 24);
            end;
          end;
      end;
      var Seek := 1;
      if (State.Flags and 1) <> 0 then
        Seek := State.SkipBytes;
      for var K := 1 to Seek do
        FDecoder.Decode;
    end;
  Result := State.Buffer[State.Offset];
  State.Offset := (State.Offset + 1) and (Bpp * 8 - 1);
end;

function TSnesSPC7110.ROMAddress(Address: Cardinal): Cardinal;
begin
  var Bank := Address shr 16;
  if Bank >= $D0 then
  begin
    if FDataSize = 0 then
      Exit($FFFFFFFF);
    Exit($100000 + (Cardinal(State.Banks[(Bank - $D0) shr 4]) * $100000 mod FDataSize) + (Address and $FFFFF));
  end;

  if (Bank >= $40) and (Bank <= $4F) then
    Exit($600000 + (Address and $FFFFF));

  Result := Address and $FFFFF;
end;

function TSnesSPC7110.Read(Address: Cardinal; OpenBus: Byte): Byte;
begin
  if (Address shr 16) = $50 then
    Address := $4800
  else if (Address shr 16) = $58 then
    Address := $4808;
  Address := Address and $FFFF;
  case Address of
    $4800:
      begin
        State.LengthCounter := (Integer(State.LengthCounter) - 1) and $FFFF;
        Exit(ReadDecompressed);
      end;
    $4801..$4803:
      Exit(Byte(State.DirectoryBase shr ((Address - $4801) * 8)));
    $4804:
      Exit(State.DirectoryIndex);
    $4805..$4806:
      Exit(Byte(State.TargetOffset shr ((Address - $4805) * 8)));
    $4807:
      Exit(State.SkipBytes);
    $4808:
      Exit(0);
    $4809..$480A:
      Exit(Byte(State.LengthCounter shr ((Address - $4809) * 8)));
    $480B:
      Exit(State.Flags);
    $480C:
      Exit(State.Status);
    $4810:
      begin
        Result := State.ReadBuffer;
        var Step: Integer := 1;
        if (State.ReadMode and 1) <> 0 then
          Step := State.ReadStep;
        if (State.ReadMode and 4) <> 0 then
          Step := SmallInt(Step);
        if (State.ReadMode and $10) <> 0 then
          State.ReadOffset := (Int64(State.ReadOffset) + Step) and $FFFF
        else
          State.ReadBase := (Int64(State.ReadBase) + Step) and $FFFFFF;
        FillReadBuffer;
        Exit;
      end;
    $4811..$4813:
      Exit(Byte(State.ReadBase shr ((Address - $4811) * 8)));
    $4814..$4815:
      Exit(Byte(State.ReadOffset shr ((Address - $4814) * 8)));
    $4816..$4817:
      Exit(Byte(State.ReadStep shr ((Address - $4816) * 8)));
    $4818:
      Exit(State.ReadMode);
    $481A:
      begin
        if (State.ReadMode and $60) = $60 then
          IncrementPosition;
        Exit(0);
      end;
    $4820..$4823:
      Exit(Byte(State.Dividend shr ((Address - $4820) * 8)));
    $4824..$4825:
      Exit(Byte(State.Multiplier shr ((Address - $4824) * 8)));
    $4826..$4827:
      Exit(Byte(State.Divisor shr ((Address - $4826) * 8)));
    $4828..$482B:
      Exit(Byte(State.ResultValue shr ((Address - $4828) * 8)));
    $482C..$482D:
      Exit(Byte(State.Remainder shr ((Address - $482C) * 8)));
    $482E:
      Exit(State.AluFlags);
    $482F:
      Exit(State.AluState);
    $4830:
      Exit(State.SramEnabled);
    $4831..$4833:
      Exit(State.Banks[Address - $4831]);
    $4834:
      Exit(State.DataSize);
    $4840..$4842:
      begin
        if FRTC <> nil then
          Exit(FRTC.Read(Address));
        Exit(0);
      end;
  end;
  Result := OpenBus;
end;

procedure SetByte(var Dest: Cardinal; Index: Integer; Value: Byte);
begin
  Dest := (Dest and not (Cardinal($FF) shl (Index * 8))) or (Cardinal(Value) shl (Index * 8));
end;

procedure TSnesSPC7110.Write(Address: Cardinal; Value: Byte);
begin
  if (Address shr 16) = $50 then
    Address := $4800
  else if (Address shr 16) = $58 then
    Address := $4808;
  Address := Address and $FFFF;
  case Address of
    $4801..$4803:
      SetByte(State.DirectoryBase, Address - $4801, Value);
    $4804:
      begin
        State.DirectoryIndex := Value;
        var Base := State.DirectoryBase + Cardinal(Value) * 4;
        State.Mode := ReadData(Base) and 3;
        State.Source := (Cardinal(ReadData(Base + 1)) shl 16) or (Cardinal(ReadData(Base + 2)) shl 8) or ReadData(Base + 3);
      end;
    $4805:
      State.TargetOffset := (State.TargetOffset and $FF00) or Value;
    $4806:
      begin
        State.TargetOffset := (State.TargetOffset and $FF) or (Word(Value) shl 8);
        BeginDecompression;
      end;
    $4807:
      State.SkipBytes := Value;
    $4809:
      State.LengthCounter := (State.LengthCounter and $FF00) or Value;
    $480A:
      State.LengthCounter := (State.LengthCounter and $FF) or (Word(Value) shl 8);
    $480B:
      State.Flags := Value and 3;
    $4811..$4813:
      begin
        SetByte(State.ReadBase, Address - $4811, Value);
        if Address = $4813 then
          FillReadBuffer;
      end;
    $4814:
      begin
        State.ReadOffset := (State.ReadOffset and $FF00) or Value;
        if (State.ReadMode and $60) = $20 then
          IncrementPosition;
      end;
    $4815:
      begin
        State.ReadOffset := (State.ReadOffset and $FF) or (Word(Value) shl 8);
        if (State.ReadMode and 2) <> 0 then
          FillReadBuffer;
        if (State.ReadMode and $60) = $40 then
          IncrementPosition;
      end;
    $4816:
      State.ReadStep := (State.ReadStep and $FF00) or Value;
    $4817:
      State.ReadStep := (State.ReadStep and $FF) or (Word(Value) shl 8);
    $4818:
      begin
        State.ReadMode := Value and $7F;
        FillReadBuffer;
      end;
    $4820..$4823:
      SetByte(State.Dividend, Address - $4820, Value);
    $4824:
      State.Multiplier := (State.Multiplier and $FF00) or Value;
    $4825:
      begin
        State.Multiplier := (State.Multiplier and $FF) or (Word(Value) shl 8);
        if (State.AluFlags and 1) <> 0 then
          State.ResultValue := Cardinal(Integer(SmallInt(State.Dividend)) * Integer(SmallInt(State.Multiplier)))
        else
          State.ResultValue := Cardinal((UInt64(State.Dividend) * State.Multiplier) and $FFFFFFFF);
        State.AluState := (State.AluState or 1) and $7F;
      end;
    $4826:
      State.Divisor := (State.Divisor and $FF00) or Value;
    $4827:
      begin
        State.Divisor := (State.Divisor and $FF) or (Word(Value) shl 8);
        if State.Divisor = 0 then
        begin
          State.ResultValue := 0;
          State.Remainder := Word(State.Dividend);
        end
        else if (State.AluFlags and 1) <> 0 then
        begin
          State.ResultValue := Cardinal(Int64(Integer(State.Dividend)) div SmallInt(State.Divisor));
          State.Remainder := Word(Int64(Integer(State.Dividend)) mod SmallInt(State.Divisor));
        end
        else
        begin
          State.ResultValue := State.Dividend div State.Divisor;
          State.Remainder := State.Dividend mod State.Divisor;
        end;
        State.AluState := State.AluState and $7F;
      end;
    $482E:
      State.AluFlags := Value and 1;
    $4830:
      State.SramEnabled := Value and $87;
    $4831..$4833:
      State.Banks[Address - $4831] := Value and 7;
    $4834:
      State.DataSize := Value and 7;
    $4840..$4842:
      if FRTC <> nil then
        FRTC.Write(Address, Value);
  end;
end;

procedure TSnesSPC7110.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(State, SizeOf(State));
  Archive.Field(FDecoder.State, SizeOf(FDecoder.State));
  if FRTC <> nil then
    Archive.Field(FRTC.State, SizeOf(FRTC.State));
end;

function TSnesSPC7110.RTCBattery: TBytes;
begin
  Result := nil;
  if FRTC <> nil then
    Result := FRTC.Battery;
end;

procedure TSnesSPC7110.LoadRTCBattery(const Data: TBytes);
begin
  if FRTC = nil then
  begin
    if Length(Data) <> 0 then
      raise EArgumentException.Create('Unexpected RTC battery');
  end
  else
    FRTC.LoadBattery(Data);
end;

end.

