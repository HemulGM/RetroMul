unit INTV.PlayCable;

interface

uses
  System.SysUtils, Core.Snapshots;

const
  IntvPlayCableBootSize = 1024;

type
  TIntvPlayCableChannel = record
    TuneWord: Word;
    Symbols: TBytes;
  end;

  TIntvPlayCable = class
  private
    FROM: array[0..$1FF] of Word;
    FRAM: array[0..$1FFF] of Word;
    FChannels: TArray<TIntvPlayCableChannel>;
    FClock, FPhase, FSelected, FPosition: Integer;
    FShift: Word;
    FShiftCount, FStatus, FData: Byte;
    procedure SelectChannel(TuneWord: Word);
  public
    constructor Create(const BootROM: TBytes; const Channels: TArray<TIntvPlayCableChannel>; CPUHz: Integer);
    constructor CreateFromImage(const Image: TBytes; CPUHz: Integer);
    class function IsImage(const Data: TBytes): Boolean; static;
    procedure Reset;
    function ReadWord(Address: Word): Word;
    procedure WriteWord(Address, Value: Word);
    procedure Advance(Cycles: Integer);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Classes;

const
  SerialBitsPerSecond = 13982;
  SerialBitsPerWord = 10;

constructor TIntvPlayCable.Create(const BootROM: TBytes; const Channels: TArray<TIntvPlayCableChannel>; CPUHz: Integer);
begin
  inherited Create;
  if (Length(BootROM) <> SizeOf(FROM)) or (CPUHz <= SerialBitsPerSecond) or
    (CPUHz > High(Integer) div SerialBitsPerWord) then
    raise EReadError.Create('Invalid PlayCable ROM or CPU clock');
  for var Index := Low(FROM) to High(FROM) do
  begin
    var Value := BootROM[Index * 2] shl 8 or BootROM[Index * 2 + 1];
    if Value > $3FF then
      raise EReadError.Create('PlayCable boot ROM contains data wider than 10 bits');
    FROM[Index] := Value;
  end;
  FClock := CPUHz;
  FChannels := Copy(Channels);
  for var Index := Low(FChannels) to High(FChannels) do
  begin
    if Length(FChannels[Index].Symbols) = 0 then
      raise EReadError.Create('PlayCable channel has no data');
    for var Symbol in FChannels[Index].Symbols do
      if Symbol > $7F then
        raise EReadError.Create('PlayCable channel data must be seven-bit symbols');
    for var Prior := 0 to Index - 1 do
      if FChannels[Prior].TuneWord = FChannels[Index].TuneWord then
        raise EReadError.Create('Duplicate PlayCable tune word');
  end;
  Reset;
end;

class function TIntvPlayCable.IsImage(const Data: TBytes): Boolean;
begin
  Result := (Length(Data) >= 4) and (Data[0] = Ord('P')) and (Data[1] = Ord('C')) and
    (Data[2] = Ord('A')) and (Data[3] = Ord('B'));
end;

constructor TIntvPlayCable.CreateFromImage(const Image: TBytes; CPUHz: Integer);
var
  Cursor: Integer;

  function ReadBE(Count: Integer): Cardinal;
  begin
    if Count > Length(Image) - Cursor then
      raise EReadError.Create('Truncated PlayCable image');
    Result := 0;
    for var Index := 1 to Count do
    begin
      Result := (Result shl 8) or Image[Cursor];
      Inc(Cursor);
    end;
  end;

begin
  if not IsImage(Image) or (Length(Image) < 8 + IntvPlayCableBootSize) then
    raise EReadError.Create('Invalid PlayCable image');
  Cursor := 4;
  if ReadBE(2) <> 1 then
    raise EReadError.Create('Unsupported PlayCable image version');
  var Count := ReadBE(2);
  if (Count = 0) or (Count > 256) then
    raise EReadError.Create('Invalid PlayCable channel count');
  var Boot := Copy(Image, Cursor, IntvPlayCableBootSize);
  Inc(Cursor, IntvPlayCableBootSize);
  var Channels: TArray<TIntvPlayCableChannel>;
  SetLength(Channels, Count);
  for var Index := Low(Channels) to High(Channels) do
  begin
    Channels[Index].TuneWord := ReadBE(2);
    var Size := ReadBE(4);
    if (Size = 0) or (Size > Cardinal(Length(Image) - Cursor)) then
      raise EReadError.Create('Invalid PlayCable channel size');
    Channels[Index].Symbols := Copy(Image, Cursor, Integer(Size));
    Inc(Cursor, Integer(Size));
  end;
  if Cursor <> Length(Image) then
    raise EReadError.Create('Unexpected data after PlayCable channels');
  Create(Boot, Channels, CPUHz);
end;

procedure TIntvPlayCable.Reset;
begin
  FillChar(FRAM, SizeOf(FRAM), 0);
  FShift := 0;
  FShiftCount := 0;
  FSelected := -1;
  FPosition := 0;
  FPhase := 0;
  FStatus := 0;
  FData := 0;
end;

procedure TIntvPlayCable.SelectChannel(TuneWord: Word);
begin
  FSelected := -1;
  for var Index := Low(FChannels) to High(FChannels) do
    if FChannels[Index].TuneWord = TuneWord then
    begin
      FSelected := Index;
      Break;
    end;
  FPosition := 0;
  FPhase := 0;
  FStatus := 0;
  FData := 0;
end;

function TIntvPlayCable.ReadWord(Address: Word): Word;
begin
  case Address of
    $4800..$4FFD:
      Result := FROM[Address and $1FF];
    $4FFE:
      begin
        Result := FStatus;
        FStatus := 0;
      end;
    $4FFF:
      Result := FData;
    $5000..$6FFF:
      Result := FRAM[Address - $5000];
  else
    Result := $FFFF;
  end;
end;

procedure TIntvPlayCable.WriteWord(Address, Value: Word);
begin
  case Address of
    $4FFF:
      begin
        FShift := Word((Integer(FShift) shl 1) or (Value shr 15));
        Inc(FShiftCount);
        if FShiftCount = 16 then
        begin
          FShiftCount := 0;
          SelectChannel(FShift);
        end;
      end;
    $5000..$6FFF:
      FRAM[Address - $5000] := Value and $3FF;
  end;
end;

procedure TIntvPlayCable.Advance(Cycles: Integer);
begin
  if (FSelected < 0) or (Cycles <= 0) then
    Exit;
  var Interval := Int64(FClock) * SerialBitsPerWord;
  var Phase := Int64(FPhase) + Int64(Cycles) * SerialBitsPerSecond;
  var Received := Phase div Interval;
  FPhase := Phase mod Interval;
  if Received = 0 then
    Exit;
  var Stream := FChannels[FSelected].Symbols;
  FData := Stream[(Int64(FPosition) + Received - 1) mod Length(Stream)];
  FPosition := (Int64(FPosition) + Received) mod Length(Stream);
  FStatus := 1;
end;

procedure TIntvPlayCable.SerializeState(State: TStateArchive);
begin
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FPhase, SizeOf(FPhase));
  State.Field(FSelected, SizeOf(FSelected));
  State.Field(FPosition, SizeOf(FPosition));
  State.Field(FShift, SizeOf(FShift));
  State.Field(FShiftCount, SizeOf(FShiftCount));
  State.Field(FStatus, SizeOf(FStatus));
  State.Field(FData, SizeOf(FData));
  if not State.Loading then
    Exit;
  if (FSelected < -1) or (FSelected > High(FChannels)) or
    (FPhase < 0) or (FPhase >= FClock * SerialBitsPerWord) or (FShiftCount > 15) or
    (FStatus > 1) or (FData > $7F) or (FPosition < 0) or
    ((FSelected < 0) and (FPosition <> 0)) or
    ((FSelected >= 0) and (FPosition >= Length(FChannels[FSelected].Symbols))) then
    raise EReadError.Create('Invalid PlayCable snapshot state');
end;

end.

