unit NES.Mapper.Bandai;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

{$SCOPEDENUMS ON}

type
  TEepromPhase = (Idle, Device, Address, Write, Read, Ack, HostAck);

  TMapperBandai = class(TMapperBanked)
  private
    FSmallEeprom: Boolean;
    FEeprom: array[0..255] of Byte;
    FPhase, FNextPhase: TEepromPhase;
    FBits, FShift, FEepromAddress: Integer;
    FClock, FData, FOutput: Boolean;
    FChrRegisters: array[0..7] of Byte;
    FPrgRegister: Byte;
    FCounter, FReload: Integer;
    FEnabled, FPending: Boolean;
    procedure WriteSerial(Value: Byte);
    procedure UpdatePrg;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
    constructor Create(SmallEeprom: Boolean; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure Reset; override;
    procedure ClockCpu; override;
    function IrqPending: Boolean; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

implementation

procedure TMapperBandai.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FSmallEeprom, SizeOf(FSmallEeprom));
  State.Field(FEeprom, SizeOf(FEeprom));
  State.Field(FPhase, SizeOf(FPhase));
  State.Field(FNextPhase, SizeOf(FNextPhase));
  State.Field(FBits, SizeOf(FBits));
  State.Field(FShift, SizeOf(FShift));
  State.Field(FEepromAddress, SizeOf(FEepromAddress));
  State.Field(FClock, SizeOf(FClock));
  State.Field(FData, SizeOf(FData));
  State.Field(FOutput, SizeOf(FOutput));
  State.Field(FChrRegisters, SizeOf(FChrRegisters));
  State.Field(FPrgRegister, SizeOf(FPrgRegister));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FReload, SizeOf(FReload));
  State.Field(FEnabled, SizeOf(FEnabled));
  State.Field(FPending, SizeOf(FPending));
end;

function TMapperBandai.GetSaveMemory: TByteArray;
begin
  SetLength(Result, (256 shr Ord(FSmallEeprom)));
  Move(FEeprom[0], Result[0], Length(Result));
end;

procedure TMapperBandai.SetSaveMemory(const Data: TByteArray);
begin
  if Length(Data) <> (256 shr Ord(FSmallEeprom)) then
    raise ENesException.Create('Invalid cartridge save size');
  Move(Data[0], FEeprom[0], Length(Data));
end;

constructor TMapperBandai.Create(SmallEeprom: Boolean; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FSmallEeprom := SmallEeprom;
  FillChar(FEeprom, SizeOf(FEeprom), $FF);
  Reset;
end;

procedure TMapperBandai.Reset;
begin
  inherited;
  FCounter := 0;
  FReload := 0;
  FEnabled := False;
  FPending := False;
  FPhase := TEepromPhase.Idle;
  FNextPhase := TEepromPhase.Idle;
  FBits := 0;
  FShift := 0;
  FEepromAddress := 0;
  FClock := False;
  FData := True;
  FOutput := True;
  FPrgRegister := 0;
  FillChar(FChrRegisters, SizeOf(FChrRegisters), 0);
  UpdatePrg;
end;

procedure TMapperBandai.UpdatePrg;
begin
  var Outer := 0;
  if Length(FPrgRom) >= $80000 then
    for var i := 0 to 7 do
      Outer := Outer or ((FChrRegisters[i] and 1) shl 4);
  Prg16(0, Outer or FPrgRegister);
  Prg16(1, Outer or $0F);
end;

procedure TMapperBandai.WriteSerial(Value: Byte);
begin
  var Clock := (Value and $20) <> 0;
  var Data := (Value and $40) <> 0;
  var Mask := $FF;
  if FSmallEeprom then
    Mask := $7F;
  if FClock and Clock and (Data <> FData) then
  begin
    FOutput := True;
    FBits := 0;
    FShift := 0;
    if Data then
      FPhase := TEepromPhase.Idle
    else if FSmallEeprom then
      FPhase := TEepromPhase.Address
    else
      FPhase := TEepromPhase.Device;
  end
  else if Clock and not FClock then
  begin
    case FPhase of
      TEepromPhase.Device, TEepromPhase.Address, TEepromPhase.Write:
        if FBits < 8 then
        begin
          if FSmallEeprom then
            FShift := FShift or (Ord(Data) shl FBits)
          else
            FShift := ((FShift shl 1) or Ord(Data)) and $FF;
          Inc(FBits);
        end;
      TEepromPhase.Read:
        if FBits < 8 then
        begin
          var BitIndex := 7 - FBits;
          if FSmallEeprom then
            BitIndex := FBits;
          FOutput := (FEeprom[FEepromAddress] and (1 shl BitIndex)) <> 0;
          Inc(FBits);
        end;
      TEepromPhase.Ack:
        FOutput := False;
      TEepromPhase.HostAck:
        if Data then
          FNextPhase := TEepromPhase.Idle
        else
          FNextPhase := TEepromPhase.Read;
    end;
  end
  else if not Clock and FClock then
  begin
    case FPhase of
      TEepromPhase.Device, TEepromPhase.Address, TEepromPhase.Write:
        if FBits = 8 then
        begin
          FNextPhase := TEepromPhase.Write;
          case FPhase of
            TEepromPhase.Device:
              if (FShift and $F0) <> $A0 then
                FNextPhase := TEepromPhase.Idle
              else if (FShift and 1) <> 0 then
                FNextPhase := TEepromPhase.Read
              else
                FNextPhase := TEepromPhase.Address;
            TEepromPhase.Address:
              begin
                FEepromAddress := FShift and Mask;
                if FSmallEeprom and ((FShift and $80) <> 0) then
                  FNextPhase := TEepromPhase.Read;
              end;
            TEepromPhase.Write:
              begin
                FEeprom[FEepromAddress] := FShift;
                FEepromAddress := (FEepromAddress + 1) and Mask;
                if FSmallEeprom then
                  FNextPhase := TEepromPhase.Idle;
              end;
          end;
          if (FPhase = TEepromPhase.Device) and (FNextPhase = TEepromPhase.Idle) then
            FPhase := TEepromPhase.Idle
          else
            FPhase := TEepromPhase.Ack;
          FOutput := True;
        end;
      TEepromPhase.Read:
        if FBits = 8 then
        begin
          FPhase := TEepromPhase.HostAck;
          FNextPhase := TEepromPhase.Idle;
          FEepromAddress := (FEepromAddress + 1) and Mask;
          FOutput := True;
        end;
      TEepromPhase.Ack, TEepromPhase.HostAck:
        begin
          FPhase := FNextPhase;
          FBits := 0;
          FShift := 0;
          FOutput := True;
        end;
    end;
  end;
  FClock := Clock;
  FData := Data;
end;

function TMapperBandai.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (Address >= $6000) and (Address < $8000) then
  begin
    Value := Ord(FOutput) shl 4;
    Exit(True);
  end;
  Result := inherited CpuRead(Address, Value);
end;

function TMapperBandai.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := Address >= $6000;
  if FSmallEeprom then
    Result := Address >= $8000;
  if not Result then
    Exit;
  case Address and $0F of
    0..7:
      begin
        FChrRegisters[Address and 7] := Value;
        if not FHasChrRam then
          Chr1(Address and 7, Value);
        UpdatePrg;
      end;
    8:
      begin
        FPrgRegister := Value and $0F;
        UpdatePrg;
      end;
    9:
      Mirror(Value and 3);
    10:
      begin
        FEnabled := (Value and 1) <> 0;
        FCounter := FReload;
        FPending := False;
      end;
    11:
      FReload := (FReload and $FF00) or Value;
    12:
      FReload := (FReload and $FF) or (Integer(Value) shl 8);
    13:
      WriteSerial(Value);
  end;
end;

procedure TMapperBandai.ClockCpu;
begin
  if FEnabled then
  begin
    if FCounter = 0 then
      FPending := True;
    FCounter := (FCounter - 1) and $FFFF;
  end;
end;

function TMapperBandai.IrqPending: Boolean;
begin
  Result := FPending;
end;

end.

