unit PSP.MP3;

// Native service using RetroMul's shared Audio.MP3 decoder. Buffer scheduling
// follows PPSSPP SimpleAudioDec.cpp (PPSSPP Project, GPL-2.0-or-later) and
// pspautotests hardware traces. This implementation is GPL-3.0-or-later.
// License text: https://www.gnu.org/licenses/gpl-3.0.html

interface

uses
  System.SysUtils, PSP.Memory, PSP.CPU, PSP.Kernel, Audio.MP3.Types,
  Audio.MP3.Layer3;

type
  TPSPMP3Context = class
    StartPosition, EndPosition: UInt64;
    ReadPosition, Buffered: Int64;
    Buffer, BufferSize, PCMBuffer, PCMSize, OutputHalf, SumSamples: Cardinal;
    SourceOffset: Integer;
    LoopCount: Integer;
    Source, Reservoir: TBytes;
    Initialized, LowLevel: Boolean;
    Rate, Channels, BitRate, Version, FrameCount: Cardinal;
    Decoder: TMP3Layer3Decoder;
    constructor Create;
    destructor Destroy; override;
    function HalfSize: Int64;
    function WriteOffset: Cardinal;
    function Needed: Cardinal;
    procedure Seek(Position: Int64; Samples: Cardinal);
    function DecodePacket(const Data: TBytes; out Consumed: Integer; out PCM: TBytes): Boolean;
  end;

  TPSPMP3 = class
  private
    FMemory: TPSPMemory;
    FCPU: TPSPCPU;
    FKernel: TPSPKernel;
    FResourceInitialized: Boolean;
    FContexts: array[0..1] of TPSPMP3Context;
    procedure ReleaseAll;
    function InitStream(Context: TPSPMP3Context): Cardinal;
    function Decode(Context: TPSPMP3Context; OutputPointer: Cardinal): Cardinal;
  public
    constructor Create(Memory: TPSPMemory; CPU: TPSPCPU; Kernel: TPSPKernel);
    destructor Destroy; override;
    function Handle(NID: Cardinal; out Value: Cardinal): Boolean;
  end;

implementation

uses
  System.Classes, System.Math, Audio.MP3.BitStream, Audio.MP3.Frame;

const
  WorkArea = $5C0;
  InvalidHandle = $80671001;
  Unreserved = $80671102;
  NotInitialized = $80671103;
  NoResource = $80671201;
  BadAddress = $80671002;
  BadSize = $80671003;
  InvalidData = $807F00FD;

constructor TPSPMP3Context.Create;
begin
  inherited;
  LoopCount := -1;
  Decoder := TMP3Layer3Decoder.Create;
end;

destructor TPSPMP3Context.Destroy;
begin
  Decoder.Free;
  inherited;
end;

function TPSPMP3Context.HalfSize: Int64;
begin
  Result := (Int64(BufferSize) - WorkArea) div 2;
end;

function TPSPMP3Context.WriteOffset: Cardinal;
begin
  var Capacity := HalfSize * 2;
  if Capacity <= 0 then Exit(0);
  var Offset := (ReadPosition - Int64(StartPosition)) mod Capacity;
  if Offset < 0 then Inc(Offset, Capacity);
  Result := Cardinal(Offset);
end;

function TPSPMP3Context.Needed: Cardinal;
begin
  if (ReadPosition >= 0) and (UInt64(ReadPosition) >= EndPosition) then Exit(0);
  var Half := HalfSize;
  if Half <= 0 then Exit(0);
  var Written := ReadPosition - Int64(StartPosition);
  var Consumed := Written - Buffered;
  var CompleteHalves := Consumed div Half;
  if Consumed mod Half < 0 then Dec(CompleteHalves);
  Result := Cardinal(Min(Int64(High(Cardinal)), Max(Int64(0), (CompleteHalves + 2) * Half - Written)));
end;

procedure TPSPMP3Context.Seek(Position: Int64; Samples: Cardinal);
begin
  ReadPosition := Position;
  Buffered := 0;
  Source := nil;
  SourceOffset := 0;
  Reservoir := nil;
  SumSamples := Samples;
  Decoder.Free;
  Decoder := TMP3Layer3Decoder.Create;
end;

function TPSPMP3Context.DecodePacket(const Data: TBytes; out Consumed: Integer; out PCM: TBytes): Boolean;
begin
  Result := False;
  Consumed := 0;
  PCM := nil;
  var Stream := TBytesStream.Create(Data);
  try
    var Header: TMP3FrameHeader;
    if not TMP3FrameParser.ParseHeader(Stream, Header) then Exit;
    var FrameStart := Stream.Position - 4;
    if (Header.FrameSize < 4) or (FrameStart + Header.FrameSize > Stream.Size) then Exit;
    if HDR_IS_CRC(Header.Hdr) then Stream.Position := Stream.Position + 2;
    var SideSize := TMP3FrameParser.SideInfoSize(Header);
    if Stream.Position + SideSize > FrameStart + Header.FrameSize then Exit;
    var SideData: TBytes;
    SetLength(SideData, SideSize);
    Stream.ReadBuffer(SideData[0], SideSize);
    var SideInfo: TMP3SideInfo;
    var Bits := TMP3BitStream.Create(SideData);
    try
      if not TMP3FrameParser.ParseSideInfo(Bits, Header, SideInfo) then Exit;
    finally
      Bits.Free;
    end;
    var Main: TBytes;
    SetLength(Main, FrameStart + Header.FrameSize - Stream.Position);
    if Length(Main) > 0 then Stream.ReadBuffer(Main[0], Length(Main));
    var Samples := 1152;
    if Header.Hdr[1] and $18 <> $18 then Samples := 576;
    SetLength(PCM, Samples * 4);
    if SideInfo.MainDataBegin <= Length(Reservoir) then
    begin
      var Input := Copy(Reservoir, Length(Reservoir) - SideInfo.MainDataBegin, SideInfo.MainDataBegin) + Main;
      SetLength(Input, Length(Input) + 16);
      var Left, Right: TArray<Single>;
      Decoder.DecodeFrame(Header, SideInfo, Input, 0, Left, Right);
      if Length(Left) <> Samples then raise EReadError.Create('Unexpected MP3 sample count');
      for var I := 0 to Samples - 1 do
      begin
        var L := SmallInt(EnsureRange(Round(Left[I] * 32768), Int64(-32768), Int64(32767)));
        var R := L;
        if Header.Channels = 2 then R := SmallInt(EnsureRange(Round(Right[I] * 32768), Int64(-32768), Int64(32767)));
        Move(L, PCM[I * 4], 2);
        Move(R, PCM[I * 4 + 2], 2);
      end;
    end;
    Reservoir := Reservoir + Main;
    if Length(Reservoir) > 511 then Reservoir := Copy(Reservoir, Length(Reservoir) - 511, 511);
    Consumed := FrameStart + Header.FrameSize;
    Result := True;
  finally
    Stream.Free;
  end;
end;

constructor TPSPMP3.Create(Memory: TPSPMemory; CPU: TPSPCPU; Kernel: TPSPKernel);
begin
  inherited Create;
  FMemory := Memory;
  FCPU := CPU;
  FKernel := Kernel;
end;

destructor TPSPMP3.Destroy;
begin
  ReleaseAll;
  inherited;
end;

procedure TPSPMP3.ReleaseAll;
begin
  for var I := 0 to High(FContexts) do FreeAndNil(FContexts[I]);
end;

function TPSPMP3.InitStream(Context: TPSPMP3Context): Cardinal;
const
  Rates: array[0..2] of Cardinal = (44100, 48000, 32000);
  BitRates: array[0..15] of Cardinal = (0,32,40,48,56,64,80,96,112,128,160,192,224,256,320,0);
begin
  Result := InvalidData;
  if not FMemory.IsValid(Context.Buffer, WorkArea + 1443) then Exit;
  var Data := FMemory.ReadBytes(Context.Buffer + WorkArea, 1443);
  var Offset := 0;
  while Offset < 1440 do
  begin
    if (Data[Offset] = $FF) and (Data[Offset + 1] and $C0 = $C0) then Break;
    Inc(Offset);
  end;
  if Offset = 1440 then Exit;
  var Version := (Data[Offset + 1] shr 3) and 3;
  var Layer := (Data[Offset + 1] shr 1) and 3;
  var BitRate := BitRates[Data[Offset + 2] shr 4];
  var RateIndex := (Data[Offset + 2] shr 2) and 3;
  if (Layer <> 1) or (BitRate = 0) or (RateIndex = 3) then Exit;
  if Version <> 3 then Exit($80671301);
  var Rate := Rates[RateIndex];
  if (Rate <> 44100) and (FKernel.SDK < $03090500) then Exit($80671302);
  if (FKernel.SDK >= $06000000) and (Context.ReadPosition < 156) then Exit($800001FE);
  Context.Rate := Rate;
  Context.BitRate := BitRate;
  Context.Channels := 2;
  if Data[Offset + 3] shr 6 = 3 then Context.Channels := 1;
  Context.Version := Version;
  var Bytes := (Context.EndPosition - Context.StartPosition) and $FFFFFFFF;
  Context.FrameCount := Cardinal((Bytes * Rate) div (UInt64(144) * BitRate * 1000));
  Context.Initialized := True;
  FKernel.WaitUntil(FKernel.Time + 500);
  Result := 0;
end;

function TPSPMP3.Decode(Context: TPSPMP3Context; OutputPointer: Cardinal): Cardinal;
begin
  var HalfSize := Context.PCMSize div 2;
  var Address := UInt64(Context.PCMBuffer) + UInt64(Context.OutputHalf) * HalfSize;
  if (Address > High(Cardinal)) or not FMemory.IsValid(Cardinal(Address), HalfSize) or
    ((OutputPointer <> 0) and not FMemory.IsValid(OutputPointer, 4)) then Exit(BadAddress);
  var PCM: TBytes;
  var Consumed := 0;
  var Position := Context.ReadPosition - Context.Buffered;
  var Ended := (Position >= 0) and (UInt64(Position) >= Context.EndPosition);
  if not Ended and (Context.SourceOffset < Length(Context.Source)) then
  begin
    var Count := Length(Context.Source) - Context.SourceOffset;
    if Position >= 0 then Count := Integer(Min(UInt64(Count), Context.EndPosition - UInt64(Position)));
    var Data := Copy(Context.Source, Context.SourceOffset, Count);
    try
      if Context.DecodePacket(Data, Consumed, PCM) then
      begin
        Inc(Context.SourceOffset, Consumed);
        Dec(Context.Buffered, Consumed);
        Context.SumSamples := Cardinal((UInt64(Context.SumSamples) + Cardinal(Length(PCM) div 4)) and $FFFFFFFF);
      end;
    except
      on E: EReadError do Exit(InvalidData);
    end;
  end;
  Result := Length(PCM);
  Position := Context.ReadPosition - Context.Buffered;
  Ended := (Position >= 0) and (UInt64(Position) >= Context.EndPosition);
  if Ended and (Context.LoopCount <> 0) then
  begin
    Context.Seek(Int64(Context.StartPosition), 0);
    if Context.LoopCount > 0 then Dec(Context.LoopCount);
  end;
  if (Result = 0) and not Ended then Result := HalfSize;
  FMemory.Zero(Cardinal(Address), HalfSize);
  if Length(PCM) > 0 then FMemory.Load(Cardinal(Address), PCM);
  if OutputPointer <> 0 then FMemory.Write32(OutputPointer, Cardinal(Address));
  Context.OutputHalf := Context.OutputHalf xor 1;
  if Result > 0 then FKernel.WaitUntil(FKernel.Time + 2400);
end;

function TPSPMP3.Handle(NID: Cardinal; out Value: Cardinal): Boolean;
begin
  Result := True;
  Value := 0;
  var A := FCPU.Registers[4];var B := FCPU.Registers[5];var C := FCPU.Registers[6];var D := FCPU.Registers[7];
  case NID of
    $35750070: begin FResourceInitialized := True;FKernel.WaitUntil(FKernel.Time + 200);Exit end;
    $3C2FA058: begin ReleaseAll;FResourceInitialized := False;Exit end;
    $07EC321A:
      begin
        if not FResourceInitialized then begin Value := NoResource;Exit end;
        var Id := -1;
        for var I := 0 to 1 do if FContexts[I] = nil then begin Id := I;Break end;
        if Id < 0 then begin Value := NoResource;Exit end;
        var Context := TPSPMP3Context.Create;
        try
          if A <> 0 then
          begin
            if not FMemory.IsValid(A, 32) then begin Value := BadAddress;Exit end;
            Context.StartPosition := UInt64(FMemory.Read32(A)) or (UInt64(FMemory.Read32(A + 4)) shl 32);
            Context.EndPosition := UInt64(FMemory.Read32(A + 8)) or (UInt64(FMemory.Read32(A + 12)) shl 32);
            Context.Buffer := FMemory.Read32(A + 16);Context.BufferSize := FMemory.Read32(A + 20);
            Context.PCMBuffer := FMemory.Read32(A + 24);Context.PCMSize := FMemory.Read32(A + 28);
            if (Context.StartPosition >= Context.EndPosition) or (Context.StartPosition > High(Int64)) then begin Value := BadSize;Exit end;
            if (Context.Buffer = 0) or (Context.PCMBuffer = 0) then begin Value := BadAddress;Exit end;
            if (Context.BufferSize < 8192) or (Context.BufferSize > High(Integer)) or
              (Context.PCMSize < 9216) or (Context.PCMSize > High(Integer)) then begin Value := BadSize;Exit end;
          end;
          Context.ReadPosition := Int64(Context.StartPosition);
          FContexts[Id] := Context;Context := nil;Value := Id;
        finally Context.Free end;
        Exit;
      end;
  end;
  case NID of
    $0DB149F4,$2A368661,$354D27EA,$3CEF484F,$44E07129,$7F696782,$87677E40,
    $87C263D1,$8F450998,$A703FE0F,$D021C0FB,$D0A56296,$D8F54A51,$F5478233,$AE6D2027,
    $3548AEC8,$0840E808,$1B839B83,$E3EE2C81: ;
  else Exit(False) end;
  if A > 1 then begin Value := InvalidHandle;Exit end;
  if NID = $F5478233 then begin FreeAndNil(FContexts[A]);Exit end;
  if NID = $1B839B83 then
  begin
    FreeAndNil(FContexts[A]);FContexts[A] := TPSPMP3Context.Create;
    FContexts[A].LowLevel := True;FContexts[A].Initialized := True;FContexts[A].Version := 1;Exit;
  end;
  var Context := FContexts[A];
  if Context = nil then
  begin
    Value := Unreserved;
    if NID=$E3EE2C81 then Value:=InvalidHandle;
    case NID of $D021C0FB,$2A368661,$7F696782,$87677E40,$87C263D1,$8F450998,$3548AEC8,$0840E808: Value := NotInitialized end;
    Exit;
  end;
  if NID = $E3EE2C81 then
  begin
    var E := FCPU.Registers[8];
    if not FMemory.IsValid(B, 4096) or not FMemory.IsValid(C, 4) or
      not FMemory.IsValid(D, 4608) or not FMemory.IsValid(E, 4) then begin Value := BadAddress;Exit end;
    var PCM: TBytes;var Consumed: Integer;
    try
      if not Context.DecodePacket(FMemory.ReadBytes(B, 4096), Consumed, PCM) then begin Value := InvalidData;Exit end;
    except on EReadError do begin Value := InvalidData;Exit end end;
    FMemory.Load(D, PCM);FMemory.Write32(C, Consumed);FMemory.Write32(E, Length(PCM));Exit;
  end;
  if Context.Buffer = 0 then
  begin
    Value := Unreserved;
    case NID of
      $D021C0FB,$2A368661,$3548AEC8,$0840E808: Value := NotInitialized;
      $7F696782,$87677E40,$87C263D1,$8F450998:
        if Context.LowLevel and Context.Initialized then Value := 0 else Value := NotInitialized;
      $AE6D2027: if Context.LowLevel and Context.Initialized then Value := 0;
    end;
    Exit;
  end;
  case NID of
    $44E07129: Value := InitStream(Context);
    $0DB149F4:
      begin
        var Size := Integer(B);var Offset := Context.WriteOffset;
        var ReadAddress := UInt64(Context.Buffer) + WorkArea + Offset;
        if (Size > 0) and (UInt64(WorkArea) + Offset + Cardinal(Size) <= Context.BufferSize) and
          (ReadAddress <= High(Cardinal)) and FMemory.IsValid(Cardinal(ReadAddress), Cardinal(Size)) and
          (Int64(Length(Context.Source)) - Context.SourceOffset + Size <= PSPRAMSize) then
        begin
          if Context.SourceOffset <> 0 then Context.Source := Copy(Context.Source, Context.SourceOffset, Length(Context.Source) - Context.SourceOffset);
          Context.SourceOffset := 0;
          Context.Source := Context.Source + FMemory.ReadBytes(Cardinal(ReadAddress), Cardinal(Size));
        end;
        Inc(Context.ReadPosition, Size);Inc(Context.Buffered, Size);
      end;
    $A703FE0F:
      begin
        var Needed := Context.Needed;var Address: Cardinal := 0;var Position: Cardinal := 0;
        if Needed <> 0 then
        begin
          Address := Cardinal((UInt64(Context.Buffer) + WorkArea + Context.WriteOffset) and $FFFFFFFF);
          Position := Cardinal(UInt64(Context.ReadPosition) and $FFFFFFFF);
        end;
        if FMemory.IsValid(B, 4) then FMemory.Write32(B, Address);
        if FMemory.IsValid(C, 4) then FMemory.Write32(C, Needed);
        if FMemory.IsValid(D, 4) then FMemory.Write32(D, Position);
      end;
    $D0A56296: Value := Ord(Context.Needed <> 0);
    $3CEF484F: begin Context.LoopCount := Integer(B);if Context.LoopCount < 0 then Context.LoopCount := -1 end;
    $D8F54A51: Value := Cardinal(Int64(Context.LoopCount) and $FFFFFFFF);
    $354D27EA: Value := Context.SumSamples;
  else
    if not Context.Initialized then
    begin Value := NotInitialized;if NID=$AE6D2027 then Value:=Unreserved;Exit end;
    case NID of
      $D021C0FB: Value := Decode(Context, B);
      $7F696782: Value := Context.Channels;
      $87677E40: Value := Context.BitRate;
      $87C263D1: Value := 1152;
      $8F450998: Value := Context.Rate;
      $AE6D2027: Value := Context.Version;
      $3548AEC8: Value := Context.FrameCount;
      $2A368661: Context.Seek(Int64(Context.StartPosition), 0);
      $0840E808:
        if B >= Context.FrameCount then Value := $80671501
        else
        begin
          var Position := Int64(Context.StartPosition) + Int64((UInt64(B) * 144 * Context.BitRate * 1000) div Context.Rate);
          if B <> 0 then Dec(Position);
          Context.Seek(Position, Cardinal((UInt64(B) * 1152) and $FFFFFFFF));
        end;
    end;
  end;
end;

end.
