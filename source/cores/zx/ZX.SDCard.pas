unit ZX.SDCard;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, ZX.BlockImage;

type
  TZXSDState = record
    SDCommand: array[0..5] of Byte;
    SDCount, SDResponsePosition, SDResponseCount, SDWritePosition: Integer;
    SDResponse: array[0..519] of Byte;
    SDBuffer: array[0..513] of Byte;
    SDIdle, SDApp, SDHC, SDCRC, SDReadMultiple, SDWriteMultiple: Boolean;
    SDWriting, SDBusy: Byte;
    SDLBA: Cardinal;
  end;

  // Native SPI protocol, shared by divMMC and NeoGS. Disk is borrowed.
  TZXSDCard = class
  private
    FState: TZXSDState;
    FDisk: TZXBlockImage;
    FSelected: Boolean;
    procedure SDReply(const Bytes: array of Byte);
    procedure SDCommand;
    procedure SDData(const Data: TBytes);
    function CRC16(const Data: TBytes): Word;
  public
    constructor Create;
    procedure Reset;
    procedure Select(Value: Boolean);
    function SPI(Value: Byte): Byte;
    procedure SerializeState(State: TStateArchive);
    property Disk: TZXBlockImage read FDisk write FDisk;
  end;

implementation

uses
  System.Math;

constructor TZXSDCard.Create;
begin
  inherited;
  Reset;
end;

procedure TZXSDCard.Reset;
begin
  FillChar(FState, SizeOf(FState), 0);
  FSelected := False;
  FState.SDIdle := True;
  FState.SDApp := False;
  FState.SDHC := False;
  FState.SDCRC := False;
  FState.SDCount := 0;
  FState.SDResponseCount := 0;
  FState.SDResponsePosition := 0;
  FState.SDWriting := 0;
  FState.SDWritePosition := 0;
  FState.SDBusy := 0;
  FState.SDReadMultiple := False;
  FState.SDWriteMultiple := False;
end;

procedure TZXSDCard.Select(Value: Boolean);
begin
  FSelected := Value;
  if not Value then
  begin
    FState.SDCount := 0;
    FState.SDResponseCount := 0;
    FState.SDResponsePosition := 0;
    FState.SDWriting := 0;
    FState.SDReadMultiple := False;
    FState.SDWriteMultiple := False;
  end;
end;

function TZXSDCard.CRC16(const Data: TBytes): Word;
begin
  var C: Cardinal := 0;
  for var B in Data do
  begin
    C := C xor (Cardinal(B) shl 8);
    for var i := 0 to 7 do
      if (C and $8000) <> 0 then
        C := ((C shl 1) xor $1021) and $FFFF
      else
        C := (C shl 1) and $FFFF;
  end;
  Result := C;
end;

procedure TZXSDCard.SDReply(const Bytes: array of Byte);
begin
  FState.SDResponsePosition := 0;
  FState.SDResponseCount := Length(Bytes);
  for var i := 0 to High(Bytes) do
    FState.SDResponse[i] := Bytes[i];
end;

procedure TZXSDCard.SDData(const Data: TBytes);
begin
  var P := FState.SDResponseCount;
  FState.SDResponse[P] := $FF;
  FState.SDResponse[P + 1] := $FE;
  for var i := 0 to High(Data) do
    FState.SDResponse[P + 2 + i] := Data[i];
  var CRC := CRC16(Data);
  FState.SDResponse[P + 2 + Length(Data)] := CRC shr 8;
  FState.SDResponse[P + 3 + Length(Data)] := CRC and 255;
  Inc(FState.SDResponseCount, Length(Data) + 4);
end;

procedure TZXSDCard.SDCommand;
begin
  var Cmd := FState.SDCommand[0] and 63;
  var Arg: Cardinal := (Cardinal(FState.SDCommand[1]) shl 24) or (Cardinal(FState.SDCommand[2]) shl 16) or
    (Cardinal(FState.SDCommand[3]) shl 8) or FState.SDCommand[4];
  var Idle := Byte(Ord(FState.SDIdle));
  var App := FState.SDApp;
  FState.SDApp := False;
  if FState.SDCRC or (Cmd in [0, 8]) then
  begin
    var CRC: Byte := 0;
    for var i := 0 to 4 do
      for var Bit := 7 downto 0 do
      begin
        var Feedback := ((CRC shr 6) xor (FState.SDCommand[i] shr Bit)) and 1;
        CRC := (CRC shl 1) and $7F;
        if Feedback <> 0 then
          CRC := CRC xor 9;
      end;
    if FState.SDCommand[5] <> ((CRC shl 1) or 1) then
    begin
      SDReply([Idle or 8]);
      Exit;
    end;
  end;
  case Cmd of
    0:
      begin
        FState.SDIdle := True;
        FState.SDHC := False;
        FState.SDCRC := False;
        FState.SDReadMultiple := False;
        FState.SDWriteMultiple := False;
        SDReply([1]);
      end;
    1:
      begin
        FState.SDIdle := False;
        SDReply([0]);
      end;
    8:
      SDReply([Idle, 0, 0, (Arg shr 8) and 255, Arg and 255]);
    55:
      begin
        FState.SDApp := True;
        SDReply([Idle]);
      end;
    41:
      if App then
      begin
        FState.SDIdle := False;
        FState.SDHC := ((Arg and $40000000) <> 0) and (FDisk.Sectors >= 4194304);
        SDReply([0]);
      end
      else
        SDReply([Idle or 4]);
    58:
      SDReply([Idle, $80 or (Ord(FState.SDHC) shl 6), $FF, $80, 0]);
    59:
      begin
        FState.SDCRC := (Arg and 1) <> 0;
        SDReply([Idle]);
      end;
    12:
      begin
        FState.SDReadMultiple := False;
        SDReply([$FF, 0]);
      end;
  else
    if FState.SDIdle then
    begin
      SDReply([1]);
      Exit;
    end;
    case Cmd of
      9, 10:
        begin
          var Data: TBytes;
          SetLength(Data, 16);
          if Cmd = 10 then
          begin
            Data[0] := 1;
            Data[1] := Ord('R');
            Data[2] := Ord('M');
            Data[3] := Ord('S');
            Data[4] := Ord('D');
            Data[5] := Ord('0');
            Data[6] := Ord('1');
          end
          else
          begin
            Data[1] := $0E;
            Data[2] := 0;
            Data[3] := $32;
            Data[4] := $5B;
            Data[5] := $59;
            if FState.SDHC then
            begin
              var Size := FDisk.Sectors div 1024 - 1;
              Data[0] := $40;
              Data[7] := (Size shr 16) and 63;
              Data[8] := (Size shr 8) and 255;
              Data[9] := Size and 255;
            end
            else
            begin
              var Mult := 0;
              while (FDisk.Sectors shr (Mult + 2)) > 4096 do
                Inc(Mult);
              var Size := Max(Cardinal(1), FDisk.Sectors shr (Mult + 2)) - 1;
              Data[6] := (Size shr 10) and 3;
              Data[7] := (Size shr 2) and 255;
              Data[8] := (Size and 3) shl 6;
              Data[9] := Mult shr 1;
              Data[10] := (Mult and 1) shl 7;
            end;
            Data[10] := Data[10] or $7F;
            Data[11] := $80;
            Data[12] := $0A;
            Data[13] := $40;
          end;
          Data[15] := 1;
          SDReply([0]);
          SDData(Data);
        end;
      13:
        SDReply([0, 0]);
      16:
        if Arg = 512 then
          SDReply([0])
        else
          SDReply([$40]);
      17, 18, 24, 25:
        begin
          if not FState.SDHC and ((Arg and 511) <> 0) then
          begin
            SDReply([$40]);
            Exit;
          end;
          var LBA := Arg;
          if not FState.SDHC then
            LBA := LBA div 512;
          if LBA >= FDisk.Sectors then
          begin
            SDReply([$20]);
            Exit;
          end;
          FState.SDLBA := LBA;
          if Cmd in [17, 18] then
          begin
            var Data: TBytes;
            FDisk.ReadSector(LBA, Data);
            SDReply([0]);
            SDData(Data);
            FState.SDReadMultiple := Cmd = 18;
            Inc(FState.SDLBA);
          end
          else
          begin
            SDReply([0]);
            FState.SDWriting := 1;
            FState.SDWriteMultiple := Cmd = 25;
          end;
        end;
      23:
        if App then
          SDReply([0])
        else
          SDReply([4]);
    else
      SDReply([4]);
    end;
  end;
end;

function TZXSDCard.SPI(Value: Byte): Byte;
begin
  Result := $FF;
  if (FDisk = nil) or not FSelected then
    Exit;
  if FState.SDBusy <> 0 then
  begin
    Dec(FState.SDBusy);
    Exit(0);
  end;
  // CMD12 is received over MOSI while the multi-read data stream drives MISO.
  if FState.SDReadMultiple and ((FState.SDCount > 0) or ((Value and $C0) = $40)) then
  begin
    FState.SDCommand[FState.SDCount] := Value;
    Inc(FState.SDCount);
    if FState.SDCount = 6 then
    begin
      FState.SDCount := 0;
      SDCommand;
    end;
    Exit;
  end;
  if FState.SDResponsePosition < FState.SDResponseCount then
  begin
    Result := FState.SDResponse[FState.SDResponsePosition];
    Inc(FState.SDResponsePosition);
    Exit;
  end;
  if FState.SDWriting <> 0 then
  begin
    if FState.SDWriting = 1 then
    begin
      if FState.SDWriteMultiple and (Value = $FD) then
      begin
        FState.SDWriting := 0;
        FState.SDBusy := 1;
        Exit;
      end;
      if (Value = $FE) or (FState.SDWriteMultiple and (Value = $FC)) then
      begin
        FState.SDWriting := 2;
        FState.SDWritePosition := 0;
      end;
    end
    else
    begin
      FState.SDBuffer[FState.SDWritePosition] := Value;
      Inc(FState.SDWritePosition);
      if FState.SDWritePosition = 514 then
      begin
        var Data: TBytes;
        SetLength(Data, 512);
        Move(FState.SDBuffer[0], Data[0], 512);
        var Code: Byte := $05;
        if FState.SDCRC and (CRC16(Data) <> ((Word(FState.SDBuffer[512]) shl 8) or FState.SDBuffer[513])) then
          Code := $0B
        else if not FDisk.WriteSector(FState.SDLBA, Data) then
          Code := $0D;
        SDReply([Code, 0, $FF]);
        Inc(FState.SDLBA);
        if FState.SDWriteMultiple then
          FState.SDWriting := 1
        else
          FState.SDWriting := 0;
      end;
    end;
    Exit;
  end;
  if FState.SDCount = 0 then
  begin
    if (Value and $C0) = $40 then
    begin
      FState.SDCommand[0] := Value;
      FState.SDCount := 1;
    end
    else if FState.SDReadMultiple then
    begin
      var Data: TBytes;
      SDReply([]);
      if FDisk.ReadSector(FState.SDLBA, Data) then
        SDData(Data)
      else
        SDReply([8]);
      Inc(FState.SDLBA);
    end;
  end
  else
  begin
    FState.SDCommand[FState.SDCount] := Value;
    Inc(FState.SDCount);
    if FState.SDCount = 6 then
    begin
      FState.SDCount := 0;
      SDCommand;
    end;
  end;
end;

procedure TZXSDCard.SerializeState(State: TStateArchive);
begin
  State.Field(FState, SizeOf(FState));
  State.Field(FSelected, SizeOf(FSelected));
  if (FState.SDCount < 0) or (FState.SDCount > 5) or
    (FState.SDResponseCount < 0) or (FState.SDResponseCount > 520) or (FState.SDResponsePosition < 0) or
    (FState.SDResponsePosition > FState.SDResponseCount) or (FState.SDWriting > 2) or
    (FState.SDWritePosition < 0) or (FState.SDWritePosition > 514) or
    ((FState.SDWriting = 2) and (FState.SDWritePosition = 514)) then
    raise EReadError.Create('Invalid SD SPI transfer state');
end;

end.

