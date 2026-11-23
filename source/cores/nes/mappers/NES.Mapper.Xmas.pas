unit NES.Mapper.Xmas;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

const
  XMAS_LABEL_WIDTH = 240;
  XMAS_LABEL_HEIGHT = 320;

type
  TMapperXmas = class(TMapperBanked)
  private
    FLowerBank, FUpperBank, FInnerBank, FActiveLeds: Byte;
    FControl, FCommand, FMemoryAccess, FParameterCount: Byte;
    FLabelVisible: Boolean;
    FParameters: array[0..3] of Byte;
    FColumnStart, FColumnEnd, FPageStart, FPageEnd: Word;
    FColumn, FPage, FPixel: Word;
    FHighByteReceived, FWindowComplete: Boolean;
    FLabelPixels: array[0..XMAS_LABEL_HEIGHT - 1, 0..XMAS_LABEL_WIDTH - 1] of Word;
    procedure UpdateBanks;
    procedure ResetLabel;
    procedure WriteLabelCommand(Value: Byte);
    procedure WriteLabelData(Value: Byte);
    procedure WriteLabelPixel(Value: Word);
  public
    constructor Create(const Prg, Chr: TByteArray; MirrorMode: TMirrorMode);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure CpuRamWrite(Address: UInt16; Value: UInt8); override;
    function ReadLabelPixel(X, Y: Integer): Word;
    property ActiveLeds: Byte read FActiveLeds;
    property LabelVisible: Boolean read FLabelVisible;
  end;

implementation

constructor TMapperXmas.Create(const Prg, Chr: TByteArray; MirrorMode: TMirrorMode);
begin
  if Length(Chr) <> 0 then
    raise ENesException.Create('8-BIT XMAS 2017 uses CHR-RAM');
  inherited Create(Prg, Chr, True, MirrorMode);
  SetLength(FChrMemory, $8000);
  FPrgRam := nil;
  Reset;
end;

procedure TMapperXmas.UpdateBanks;
begin
  Prg16(0, (FLowerBank and $F8) or (FInnerBank and 7));
  Prg16(1, FUpperBank or 7);
  Chr8((FInnerBank shr 5) and 3);
  Mirror((FUpperBank shr 5) and 1);
end;

procedure TMapperXmas.ResetLabel;
begin
  FCommand := 0;
  FMemoryAccess := $40;
  FParameterCount := 0;
  FColumnStart := 0;
  FColumnEnd := XMAS_LABEL_WIDTH - 1;
  FPageStart := 0;
  FPageEnd := XMAS_LABEL_HEIGHT - 1;
  FColumn := 0;
  FPage := 0;
  FPixel := 0;
  FHighByteReceived := False;
  FLabelVisible := False;
  FWindowComplete := False;
end;

procedure TMapperXmas.Reset;
begin
  inherited;
  FRamEnabled := False;
  FRamWritable := False;
  FLowerBank := 0;
  FUpperBank := $80;
  FInnerBank := 0;
  FActiveLeds := 0;
  FControl := 3;
  FillChar(FParameters, SizeOf(FParameters), 0);
  FillChar(FLabelPixels, SizeOf(FLabelPixels), $FF);
  ResetLabel;
  UpdateBanks;
end;

procedure TMapperXmas.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FLowerBank, SizeOf(FLowerBank));
  State.Field(FUpperBank, SizeOf(FUpperBank));
  State.Field(FInnerBank, SizeOf(FInnerBank));
  State.Field(FActiveLeds, SizeOf(FActiveLeds));
  State.Field(FControl, SizeOf(FControl));
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FMemoryAccess, SizeOf(FMemoryAccess));
  State.Field(FParameters, SizeOf(FParameters));
  State.Field(FParameterCount, SizeOf(FParameterCount));
  State.Field(FColumnStart, SizeOf(FColumnStart));
  State.Field(FColumnEnd, SizeOf(FColumnEnd));
  State.Field(FPageStart, SizeOf(FPageStart));
  State.Field(FPageEnd, SizeOf(FPageEnd));
  State.Field(FColumn, SizeOf(FColumn));
  State.Field(FPage, SizeOf(FPage));
  State.Field(FPixel, SizeOf(FPixel));
  State.Field(FHighByteReceived, SizeOf(FHighByteReceived));
  State.Field(FWindowComplete, SizeOf(FWindowComplete));
  State.Field(FLabelVisible, SizeOf(FLabelVisible));
  State.Field(FLabelPixels, SizeOf(FLabelPixels));
  if State.Loading then
    UpdateBanks;
end;

function TMapperXmas.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  case Address of
    $6800..$6FFF:
      FControl := Value and 3;
    $7000..$77FF:
      if (Address and $3F) = 0 then
      begin
        FLowerBank := Value;
        UpdateBanks;
      end;
    $7800..$7FFF:
      begin
        FUpperBank := Value;
        UpdateBanks;
      end;
    $8000..$BFFF:
      FActiveLeds := Value xor $FF;
    $C000..$FFFF:
      begin
        FInnerBank := Value;
        UpdateBanks;
      end;
  else
    Exit(False);
  end;
  Result := True;
end;

procedure TMapperXmas.CpuRamWrite(Address: UInt16; Value: UInt8);
begin
  if (Address <> $FF) or ((FControl and 1) <> 0) then
    Exit;
  if (FControl and 2) = 0 then
    WriteLabelCommand(Value)
  else
    WriteLabelData(Value);
end;

procedure TMapperXmas.WriteLabelCommand(Value: Byte);
begin
  FCommand := Value;
  FParameterCount := 0;
  FHighByteReceived := False;
  case Value of
    $01:
      ResetLabel;
    $28:
      FLabelVisible := False;
    $29:
      FLabelVisible := True;
    $2C:
      begin
        FColumn := FColumnStart;
        FPage := FPageStart;
        FWindowComplete := False;
      end;
  end;
end;

procedure TMapperXmas.WriteLabelData(Value: Byte);
begin
  case FCommand of
    $2A, $2B:
      if FParameterCount < Length(FParameters) then
      begin
        FParameters[FParameterCount] := Value;
        Inc(FParameterCount);
        if FParameterCount = Length(FParameters) then
        begin
          var First := (Word(FParameters[0]) shl 8) or FParameters[1];
          var Last := (Word(FParameters[2]) shl 8) or FParameters[3];
          if FCommand = $2A then
          begin
            FColumnStart := First;
            FColumnEnd := Last;
          end
          else
          begin
            FPageStart := First;
            FPageEnd := Last;
          end;
        end;
      end;
    $36:
      if FParameterCount = 0 then
      begin
        FMemoryAccess := Value;
        Inc(FParameterCount);
      end;
    $2C, $3C:
      begin
        // The XMAS firmware sends RGB565, most-significant byte first.
        if FHighByteReceived then
          WriteLabelPixel(FPixel or Value)
        else
          FPixel := Word(Value) shl 8;
        FHighByteReceived := not FHighByteReceived;
      end;
  end;
end;

procedure TMapperXmas.WriteLabelPixel(Value: Word);
begin
  if FWindowComplete then
    Exit;

  var ColumnLimit := XMAS_LABEL_WIDTH;
  var PageLimit := XMAS_LABEL_HEIGHT;
  var X: Integer := FColumn;
  var Y: Integer := FPage;
  if (FMemoryAccess and $20) <> 0 then
  begin
    ColumnLimit := XMAS_LABEL_HEIGHT;
    PageLimit := XMAS_LABEL_WIDTH;
    X := FPage;
    Y := FColumn;
  end;
  if (FMemoryAccess and $40) <> 0 then
    X := XMAS_LABEL_WIDTH - 1 - X;
  if (FMemoryAccess and $80) <> 0 then
    Y := XMAS_LABEL_HEIGHT - 1 - Y;
  if (X >= 0) and (X < XMAS_LABEL_WIDTH) and (Y >= 0) and (Y < XMAS_LABEL_HEIGHT) then
  begin
    if (FMemoryAccess and 8) <> 0 then
      Value := ((Value and $F800) shr 11) or (Value and $07E0) or ((Value and $001F) shl 11);
    FLabelPixels[Y, X] := Value;
  end;
  // The menu requests 320 columns in portrait mode and rounds the transfer
  // up to whole PRG banks. Stop advancing at the physical display boundary.
  if (FColumn < FColumnEnd) and (FColumn + 1 < ColumnLimit) then
    Inc(FColumn)
  else
  begin
    FColumn := FColumnStart;
    if (FPage < FPageEnd) and (FPage + 1 < PageLimit) then
      Inc(FPage)
    else
      FWindowComplete := True;
  end;
end;

function TMapperXmas.ReadLabelPixel(X, Y: Integer): Word;
begin
  Result := FLabelPixels[Y, X];
end;

end.

