unit MD.EEPROM;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots;

type
  TMDEEPROMMode = (None, Address7, Address8, Address16);

  TMDEEPROMConfig = record
    Mode: TMDEEPROMMode;
    Size, PageSize, PageAlignment: Integer;
    SDAInAddress, SDAOutAddress, SCLAddress: Cardinal;
    SDAInMask, SDAOutMask, SCLMask: Byte;
  end;

  TMDEEPROM = class
  private
    type
      TPhase = (Idle, Control, AddressHigh, AddressLow, WriteData,
        SlaveAck, ReadData, MasterAck);

      TSerialState = record
        Phase, NextPhase: TPhase;
        SCL, SDA, OutputHigh, Accepted: Boolean;
        Bits, Shift, AckStep: Byte;
        Address, PageBase: Word;
        Written: UInt64;
        Page: array[0..63] of Byte;
      end;
  private
    FConfig: TMDEEPROMConfig;
    FState: TSerialState;
    FData: TBytes;
    FDirty: Boolean;
    procedure SetLines(SDA, SCL: Boolean);
    procedure ReceiveByte(Value: Byte);
    procedure BeginRead;
    procedure CommitPage;
  public
    constructor Create(const Config: TMDEEPROMConfig);
    procedure Reset;
    function ReadBus(Address: Cardinal; Value: Word): Word;
    function WriteBus(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean): Boolean;
    procedure LoadBattery(const Data: TBytes);
    function BatteryData: TBytes;
    procedure SerializeState(State: TStateArchive);
    property Dirty: Boolean read FDirty write FDirty;
  end;

function DetectMDEEPROM(const Serial: string; Checksum: Word; StackPointer: Cardinal = 0): TMDEEPROMConfig;

implementation

// Board identification and wiring: EkeEke's cartridge investigation (2007),
// https://krikzz.com/pub/support/everdrive-md/v2/gen_eeprom.pdf .
// Independently checked against sanni/cartreader's physical cartridge reader.
// Protocol: Xicor X24C01 and Microchip 24xx serial EEPROM datasheets.

function DetectMDEEPROM(const Serial: string; Checksum: Word; StackPointer: Cardinal): TMDEEPROMConfig;
type
  TBoard = (Sega, EA, Acclaim1, Acclaim2, Codemasters);

  TEntry = record
    Product: string;
    Checksum: Word; // Zero means all revisions of this product.
    Board: TBoard;
    Mode: TMDEEPROMMode;
    Size, PageSize: Integer;
  end;
const
  Entries: array[0..24] of TEntry = (
    (Product: 'T-12046'; Checksum: 0; Board: Sega; Mode: TMDEEPROMMode.Address7; Size: 128; PageSize: 4),
    (Product: 'T-12053'; Checksum: $EA80; Board: Sega; Mode: TMDEEPROMMode.Address7; Size: 128; PageSize: 4),
    (Product: 'G-4060'; Checksum: 0; Board: Sega; Mode: TMDEEPROMMode.Address7; Size: 128; PageSize: 4),
    (Product: 'MK-1215'; Checksum: 0; Board: Sega; Mode: TMDEEPROMMode.Address7; Size: 128; PageSize: 4),
    (Product: 'G-4084'; Checksum: 0; Board: Sega; Mode: TMDEEPROMMode.Address7; Size: 128; PageSize: 4),
    (Product: 'MK-1228'; Checksum: 0; Board: Sega; Mode: TMDEEPROMMode.Address7; Size: 128; PageSize: 4),
    (Product: 'G-5538'; Checksum: 0; Board: Sega; Mode: TMDEEPROMMode.Address7; Size: 128; PageSize: 4),
    (Product: 'PR-1993'; Checksum: 0; Board: Sega; Mode: TMDEEPROMMode.Address7; Size: 128; PageSize: 4),
    (Product: '00001211'; Checksum: 0; Board: Sega; Mode: TMDEEPROMMode.Address7; Size: 128; PageSize: 4),
    (Product: 'T-50396'; Checksum: 0; Board: EA; Mode: TMDEEPROMMode.Address7; Size: 128; PageSize: 4),
    (Product: 'T-50176'; Checksum: 0; Board: EA; Mode: TMDEEPROMMode.Address7; Size: 128; PageSize: 4),
    (Product: 'T-081326'; Checksum: 0; Board: Acclaim1; Mode: TMDEEPROMMode.Address8; Size: 256; PageSize: 4),
    (Product: 'T-81033'; Checksum: 0; Board: Acclaim1; Mode: TMDEEPROMMode.Address8; Size: 256; PageSize: 4),
    (Product: 'T-81406'; Checksum: 0; Board: Acclaim2; Mode: TMDEEPROMMode.Address8; Size: 512; PageSize: 16),
    (Product: 'T-81143'; Checksum: 0; Board: Acclaim2; Mode: TMDEEPROMMode.Address8; Size: 512; PageSize: 16),
    (Product: 'T-081276'; Checksum: 0; Board: Acclaim2; Mode: TMDEEPROMMode.Address8; Size: 256; PageSize: 8),
    (Product: 'T-081586'; Checksum: 0; Board: Acclaim2; Mode: TMDEEPROMMode.Address8; Size: 2048; PageSize: 16),
    (Product: 'T-81576'; Checksum: 0; Board: Acclaim2; Mode: TMDEEPROMMode.Address16; Size: 8192; PageSize: 64),
    (Product: 'T-81476'; Checksum: 0; Board: Acclaim2; Mode: TMDEEPROMMode.Address16; Size: 8192; PageSize: 64),
    (Product: 'T-120096'; Checksum: 0; Board: Codemasters; Mode: TMDEEPROMMode.Address8; Size: 2048; PageSize: 16),
    (Product: '00000000'; Checksum: $168B; Board: Codemasters; Mode: TMDEEPROMMode.Address8; Size: 1024; PageSize: 16),
    (Product: '00000000'; Checksum: $CEE0; Board: Codemasters; Mode: TMDEEPROMMode.Address8; Size: 1024; PageSize: 16),
    (Product: '00000000'; Checksum: $165E; Board: Codemasters; Mode: TMDEEPROMMode.Address8; Size: 2048; PageSize: 16),
    (Product: '00000000'; Checksum: $2C41; Board: Codemasters; Mode: TMDEEPROMMode.Address8; Size: 2048; PageSize: 16),
    (Product: 'T-120146'; Checksum: 0; Board: Codemasters; Mode: TMDEEPROMMode.Address16; Size: 8192; PageSize: 64)
  );
begin
  Result := Default(TMDEEPROMConfig);
  for var Entry in Entries do
    if (Pos(Entry.Product, UpperCase(Serial)) > 0) and
      ((Entry.Checksum = 0) or (Entry.Checksum = Checksum)) and
      ((Entry.Product <> '00000000') or (StackPointer = $444E4C44)) then
    begin
      Result.Mode := Entry.Mode;
      Result.Size := Entry.Size;
      Result.PageSize := Entry.PageSize;
      Result.PageAlignment := Entry.PageSize;
      // 24C65 maps its 64-byte input cache from an 8-byte page boundary,
      // including across a 64-byte row. See Microchip DS21073J section 7.
      if Entry.Mode = TMDEEPROMMode.Address16 then
        Result.PageAlignment := 8;
      Result.SDAInAddress := $200001;
      Result.SDAOutAddress := $200001;
      Result.SCLAddress := $200001;
      Result.SDAInMask := 1;
      Result.SDAOutMask := 1;
      Result.SCLMask := 2;
      case Entry.Board of
        EA:
          begin
            Result.SDAInMask := $80;
            Result.SDAOutMask := $80;
            Result.SCLMask := $40;
          end;
        Acclaim1:
          Result.SDAOutMask := 2;
        Acclaim2:
          begin
            Result.SCLAddress := $200000;
            Result.SCLMask := 1;
          end;
        Codemasters:
          begin
            Result.SDAInAddress := $300000;
            Result.SCLAddress := $300000;
            Result.SDAOutAddress := $380001;
            Result.SDAOutMask := $80;
          end;
      end;
      Exit;
    end;
end;

constructor TMDEEPROM.Create(const Config: TMDEEPROMConfig);
begin
  inherited Create;
  if (Config.Mode = TMDEEPROMMode.None) or (Config.Size < 128) or
    (Config.Size > 8192) or (Config.Size and (Config.Size - 1) <> 0) or
    (Config.PageSize < 1) or (Config.PageSize > 64) or
    (Config.PageSize and (Config.PageSize - 1) <> 0) or
    (Config.PageAlignment < 1) or (Config.PageAlignment > Config.PageSize) or
    (Config.PageAlignment and (Config.PageAlignment - 1) <> 0) then
    raise EArgumentException.Create('Invalid Mega Drive EEPROM configuration');
  FConfig := Config;
  SetLength(FData, Config.Size);
  FillChar(FData[0], Length(FData), $FF);
  Reset;
end;

procedure TMDEEPROM.Reset;
begin
  // Reset aborts the serial transaction, preserving nonvolatile contents.
  FState := Default(TSerialState);
  FState.SCL := True;
  FState.SDA := True;
  FState.OutputHigh := True;
end;

procedure TMDEEPROM.BeginRead;
begin
  FState.Phase := ReadData;
  FState.Bits := 0;
  FState.Shift := FData[FState.Address];
  FState.OutputHigh := FState.Shift and $80 <> 0;
end;

procedure TMDEEPROM.ReceiveByte(Value: Byte);
begin
  FState.Accepted := True;
  case FState.Phase of
    Control:
      begin
        if FConfig.Mode = TMDEEPROMMode.Address7 then
        begin
          FState.Address := Value shr 1;
          FState.NextPhase := WriteData;
        end
        else
        begin
          // Unconnected device address pins are low. Larger mode-2 parts
          // use the low device bits as the upper memory address instead.
          var Banks := 1;
          if FConfig.Mode = TMDEEPROMMode.Address8 then
            Banks := (FConfig.Size + 255) div 256;
          FState.Accepted := (Value and $F0 = $A0) and
            (((Value shr 1) and 7) < Banks);
          if FConfig.Mode = TMDEEPROMMode.Address8 then
          begin
            if FState.Accepted then
              FState.Address := ((FState.Address and $FF) or
                (((Value shr 1) and 7) shl 8)) and (FConfig.Size - 1);
            FState.NextPhase := AddressLow;
          end
          else
            FState.NextPhase := AddressHigh;
        end;
        if Odd(Value) then
          FState.NextPhase := ReadData;
        if not FState.Accepted then
          FState.NextPhase := Idle;
      end;
    AddressHigh:
      begin
        FState.Address := (Word(Value) shl 8) and (FConfig.Size - 1);
        FState.NextPhase := AddressLow;
      end;
    AddressLow:
      begin
        FState.Address := ((FState.Address and $FF00) or Value) and (FConfig.Size - 1);
        FState.NextPhase := WriteData;
      end;
    WriteData:
      begin
        if FState.Written = 0 then
          FState.PageBase := FState.Address and not (FConfig.PageAlignment - 1);
        var Offset := (Integer(FState.Address) - FState.PageBase) and (FConfig.PageSize - 1);
        FState.Page[Offset] := Value;
        FState.Written := FState.Written or (UInt64(1) shl Offset);
        FState.Address := (FState.PageBase + ((Offset + 1) and (FConfig.PageSize - 1))) and (FConfig.Size - 1);
        FState.NextPhase := WriteData;
      end;
  end;
  FState.Phase := SlaveAck;
  FState.AckStep := 0;
end;

procedure TMDEEPROM.CommitPage;
begin
  for var I := 0 to FConfig.PageSize - 1 do
    if FState.Written and (UInt64(1) shl I) <> 0 then
    begin
      var Address := (FState.PageBase + I) and (FConfig.Size - 1);
      if FData[Address] <> FState.Page[I] then
      begin
        FData[Address] := FState.Page[I];
        FDirty := True;
      end;
    end;
  FState.Written := 0;
end;

procedure TMDEEPROM.SetLines(SDA, SCL: Boolean);
begin
  if FState.SCL and SCL and (SDA <> FState.SDA) then
  begin
    if SDA then
    begin
      CommitPage;
      FState.Phase := Idle;
    end
    else
    begin
      FState.Phase := Control;
      FState.Written := 0;
    end;
    FState.OutputHigh := True;
    FState.Bits := 0;
    FState.Shift := 0;
  end
  else if not FState.SCL and SCL then
    case FState.Phase of
      Control, AddressHigh, AddressLow, WriteData:
        begin
          FState.Shift := ((Word(FState.Shift) shl 1) or Ord(SDA)) and $FF;
          Inc(FState.Bits);
          if FState.Bits = 8 then
            ReceiveByte(FState.Shift);
        end;
      SlaveAck:
        if FState.AckStep = 1 then
          FState.AckStep := 2;
      ReadData:
        begin
          Inc(FState.Bits);
          if FState.Bits = 8 then
            FState.Address := (FState.Address + 1) and (FConfig.Size - 1);
        end;
      MasterAck:
        begin
          FState.Accepted := not SDA;
          FState.Bits := 1;
        end;
    end
  else if FState.SCL and not SCL then
    case FState.Phase of
      SlaveAck:
        if FState.AckStep = 0 then
        begin
          FState.OutputHigh := not FState.Accepted;
          FState.AckStep := 1;
        end
        else if FState.AckStep = 2 then
        begin
          FState.OutputHigh := True;
          FState.Phase := FState.NextPhase;
          FState.Bits := 0;
          FState.Shift := 0;
          if FState.Phase = ReadData then
            BeginRead;
        end;
      ReadData:
        if FState.Bits = 8 then
        begin
          FState.OutputHigh := True;
          FState.Phase := MasterAck;
          FState.Bits := 0;
        end
        else
          FState.OutputHigh := FState.Shift and (1 shl (7 - FState.Bits)) <> 0;
      MasterAck:
        if FState.Bits = 1 then
        begin
          if FState.Accepted then
            BeginRead
          else
            FState.Phase := Idle;
        end;
    end;
  FState.SDA := SDA;
  FState.SCL := SCL;
end;

function TMDEEPROM.ReadBus(Address: Cardinal; Value: Word): Word;
begin
  Result := Value;
  if Address = (FConfig.SDAOutAddress and $FFFFFE) then
  begin
    var Mask: Word := FConfig.SDAOutMask;
    if not Odd(FConfig.SDAOutAddress) then
      Mask := Mask shl 8;
    Result := Result and not Mask;
    if FState.OutputHigh then
      Result := Result or Mask;
  end;
end;

function TMDEEPROM.WriteBus(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean): Boolean;

  function Selected(PinAddress: Cardinal): Boolean;
  begin
    Result := (Address = (PinAddress and $FFFFFE)) and
      ((Odd(PinAddress) and LowByte) or (not Odd(PinAddress) and HighByte));
  end;

  function PinHigh(PinAddress: Cardinal; Mask: Byte): Boolean;
  begin
    if Odd(PinAddress) then
      Result := Value and Mask <> 0
    else
      Result := (Value shr 8) and Mask <> 0;
  end;

begin
  var SDA := FState.SDA;
  var SCL := FState.SCL;
  var DataSelected := Selected(FConfig.SDAInAddress);
  var ClockSelected := Selected(FConfig.SCLAddress);
  Result := DataSelected or ClockSelected;
  if not Result then
    Exit;
  if DataSelected then
    SDA := PinHigh(FConfig.SDAInAddress, FConfig.SDAInMask);
  if ClockSelected then
    SCL := PinHigh(FConfig.SCLAddress, FConfig.SCLMask);
  // Both byte lanes of one word write update atomically.
  SetLines(SDA, SCL);
end;

procedure TMDEEPROM.LoadBattery(const Data: TBytes);
begin
  if Length(Data) <> Length(FData) then
    raise EReadError.Create('Mega Drive EEPROM file has an invalid size');
  FData := Copy(Data);
  FDirty := False;
  Reset;
end;

function TMDEEPROM.BatteryData: TBytes;
begin
  Result := Copy(FData);
end;

procedure TMDEEPROM.SerializeState(State: TStateArchive);
begin
  State.Field(FState, SizeOf(FState));
  State.Field(FData[0], Length(FData));
  if (Ord(FState.Phase) > Ord(High(TPhase))) or
    (Ord(FState.NextPhase) > Ord(High(TPhase))) or
    (FState.Bits > 8) or (FState.AckStep > 2) or
    (FState.Address >= Length(FData)) or
    (FState.PageBase >= Length(FData)) or
    (FState.PageBase and (FConfig.PageAlignment - 1) <> 0) then
    raise EReadError.Create('Invalid snapshot EEPROM state');
end;

end.

