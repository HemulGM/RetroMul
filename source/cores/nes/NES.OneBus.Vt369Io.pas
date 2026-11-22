unit NES.OneBus.Vt369Io;

interface

{$SCOPEDENUMS ON}

uses
  NES.State, NES.Types, NES.Consts, NES.Controller;

type
  TVt369Io = class
  private
    type
      TPort = record
        Direction, Attribute, Latch: Byte;
        function Pins: Byte;
      end;

      TSerialPhase = (Idle, Command, Parameter, ReadRom, ReadParameter);

      TInverterPhase = (Idle, Command, CommandAck, Argument, ArgumentAck, Response);

      TI2cPhase = (Idle, Control, Address, Writing, Reading, DeviceAck, MasterAck);

      TSerialState = record
        Phase: TSerialPhase;
        BitIndex, Shift: Integer;
        Clock, Selected, Output: Boolean;
      end;

      TInverterState = record
        Phase: TInverterPhase;
        Bits, Shift, Reply: Byte;
        Clock, Data, Output: Boolean;
      end;

      TPanelPhase = (Command, ResetKey, InvertByte, WriteAddress, WriteData, ReadAddress, ControlByte);

      TPanelState = packed record
        Phase: TPanelPhase;
        Request, Address, ReplyCount, ReplyIndex, Shift, Bits, Delay: Byte;
        ClockIn, ClockOut, DataOut: Boolean;
        Reply: array[0..3] of Byte;
      end;

      TEepromState = record
        Phase, NextPhase: TI2cPhase;
        Clock, Data, Released: Boolean;
        Shift, Bits: Byte;
        Address, PageMask: Word;
        Page: array[0..15] of Byte;
        WriteTicks: Integer;
      end;
  private
    FPorts: array[0..7] of TPort;
    FSerial: TSerialState;
    FInverter: TInverterState;
    FEeprom: TEepromState;
    FRom, FParameters: TArray<Byte>;
    FSave: TByteArray;
    FEepromAddressMask: Word;
    FWriteCycleTicks: Integer;
    FPhoneBoard, FParallelPanel: Boolean;
    FPanel: TPanelState;
    FPanelMemory: array[0..255] of Byte;
    FPanelController: TController;
    FPanelPointer: TZapper;
    FPanelX, FPanelY: Byte;
    FPhoneLatches: array[0..5] of Byte;
    FPhoneLastCommand, FPhoneResponseIndex: Byte;
    FInverterPort, FInverterClockBit, FInverterDataBit: Integer;
    function LocateRegister(Address: Word; out Port, RegisterIndex: Integer): Boolean;
    procedure UpdatePanel(Pins: Byte);
    procedure ProcessPanelByte(Value: Byte);
    procedure ReadPanelInput;
    procedure UpdateSerial(Selected, Clock, Data: Boolean);
    procedure UpdateInverter(Clock, Data: Boolean);
    procedure UpdateEeprom(Clock, Data: Boolean);
    procedure FinishEepromByte;
    procedure CommitEepromPage;
    function PhoneBusValue(Response: Boolean): Byte;
  public
    constructor Create(const SerialRom, Parameters: TArray<Byte>; InverterSubmapper, EepromSize: Integer; PhoneBoard: Boolean = False; ParallelPanel: Boolean = False);
    procedure ConnectPanel(Controller: TController; Pointer: TZapper);
    procedure ClockPanel;
    procedure Reset;
    procedure SetCpuFrequency(Frequency: Cardinal);
    procedure ClockEeprom(Ticks: Integer);
    function Read(Address: Word; out Value: Byte): Boolean;
    function Write(Address: Word; Value: Byte): Boolean;
    procedure SerializeState(State: TNesStateArchive);
    function HasSave: Boolean;
    function GetSaveMemory: TByteArray;
    procedure SetSaveMemory(const Data: TByteArray);
  end;

implementation

uses
  System.Math;

function TVt369Io.LocateRegister(Address: Word; out Port, RegisterIndex: Integer): Boolean;
begin
  if FParallelPanel then
  begin
    case Address of
      $4140..$4153:
        Port := (Address - $4140) shr 2;
      $4154..$415B:
        begin
          Port := Address - $4154;
          RegisterIndex := 4;
          Exit(True);
        end;
      $41E0..$41EB:
        Port := ((Address - $41E0) shr 2) + 5;
    else
      Exit(False);
    end;
    RegisterIndex := Address and 3;
    Exit(True);
  end;

  case Address of
    $4140..$415F:
      begin
        if Address = $415C then
          Exit(False);
        Port := (Address - $4140) shr 3;
        RegisterIndex := Address and 7;
        Exit(True);
      end;
    $41E0..$41EB:
      Port := ((Address - $41E0) shr 2) + 4;
  else
    Exit(False);
  end;
  RegisterIndex := Address and 3;
  Result := True;
end;

function Pin(Value: Byte; Bit: Integer): Boolean; inline;
begin
  Result := (Value and (1 shl Bit)) <> 0;
end;

function Tvt369Io.TPort.Pins: Byte;
begin
  Result := not Direction or Latch;
end;

constructor TVt369Io.Create(const SerialRom, Parameters: TArray<Byte>; InverterSubmapper, EepromSize: Integer; PhoneBoard, ParallelPanel: Boolean);
begin
  inherited Create;
  SetCpuFrequency(NES_CPU_HZ);
  FPhoneBoard := PhoneBoard;
  FParallelPanel := ParallelPanel;
  FPanelX := 64;
  FPanelY := 64;
  FRom := SerialRom;
  FParameters := Parameters;
  FInverterPort := -1;
  case InverterSubmapper of
    0:
      begin
        FInverterPort := 1;
        FInverterClockBit := 5;
        FInverterDataBit := 4;
      end;
    1:
      begin
        FInverterPort := 2;
        FInverterClockBit := 0;
        FInverterDataBit := 1;
      end;
  end;
  if EepromSize <> 0 then
  begin
    FEepromAddressMask := EepromSize - 1;
    SetLength(FSave, EepromSize);
    FillChar(FSave[0], Length(FSave), $FF);
  end;
  Reset;
end;

procedure TVt369Io.Reset;
begin
  FillChar(FPorts, SizeOf(FPorts), 0);
  FPanel := Default(TPanelState);
  FillChar(FPhoneLatches, SizeOf(FPhoneLatches), 0);
  FPhoneLastCommand := $FF;
  FPhoneResponseIndex := 2;
  FSerial := Default(TSerialState);
  FSerial.Clock := True;
  FSerial.Output := True;
  FInverter := Default(TInverterState);
  FInverter.Clock := True;
  FInverter.Data := True;
  FInverter.Output := True;
  if FEeprom.WriteTicks = 0 then
    FEeprom := Default(TEepromState)
  else
  begin
    // A console reset releases the bus while the external EEPROM is programming.
    FEeprom.Phase := TI2cPhase.Idle;
    FEeprom.NextPhase := TI2cPhase.Idle;
    FEeprom.Bits := 0;
    FEeprom.Shift := 0;
  end;
  FEeprom.Clock := True;
  FEeprom.Data := True;
  FEeprom.Released := True;
end;

procedure TVt369Io.ConnectPanel(Controller: TController; Pointer: TZapper);
begin
  FPanelController := Controller;
  FPanelPointer := Pointer;
end;

procedure TVt369Io.ReadPanelInput;
begin
  FPanel.Reply[0] := 0;
  if FPanelController <> nil then
    for var Button := Low(TNesButton) to High(TNesButton) do
      if FPanelController.IsButtonPressed(Button) then
        FPanel.Reply[0] := FPanel.Reply[0] or ($80 shr Ord(Button));
  FPanel.Reply[1] := 0;
  if FPanelPointer <> nil then
  begin
    if FPanelPointer.TriggerPressed then
      FPanel.Reply[1] := $80;
    if Assigned(FPanelPointer.OnReadPosition) then
    begin
      var Position := FPanelPointer.OnReadPosition();
      if Position.X >= 0 then
        FPanelX := Byte(System.Math.Min(Position.X, 255));
      if Position.Y >= 0 then
        FPanelY := Byte(System.Math.Min(Position.Y, 255));
    end;
  end;
  FPanel.Reply[2] := FPanelY xor $FF;
  FPanel.Reply[3] := FPanelX;
end;

procedure TVt369Io.ProcessPanelByte(Value: Byte);
begin
  case FPanel.Phase of
    TPanelPhase.Command:
      case Value of
        $00:
          begin
            ReadPanelInput;
            FPanel.ReplyCount := 4;
          end;
        $02:
          FPanel.Phase := TPanelPhase.InvertByte;
        $0A:
          FPanel.Phase := TPanelPhase.WriteAddress;
        $0B:
          FPanel.Phase := TPanelPhase.ReadAddress;
        $0D:
          FPanel.Phase := TPanelPhase.ControlByte;
        $55:
          FPanel.Phase := TPanelPhase.ResetKey;
      end;
    TPanelPhase.ResetKey:
      if Value = $AA then
        FPanel := Default(TPanelState);
    TPanelPhase.InvertByte:
      begin
        FPanel.Reply[0] := ($AF - Integer(Value)) and $FF;
        FPanel.ReplyCount := 1;
      end;
    TPanelPhase.WriteAddress:
      begin
        FPanel.Address := Value;
        FPanel.Phase := TPanelPhase.WriteData;
      end;
    TPanelPhase.WriteData:
      begin
        FPanelMemory[FPanel.Address] := Value;
        FPanel.Phase := TPanelPhase.Command;
      end;
    TPanelPhase.ReadAddress:
      begin
        FPanel.Reply[0] := FPanelMemory[Value];
        FPanel.ReplyCount := 1;
      end;
    TPanelPhase.ControlByte:
      FPanel.Phase := TPanelPhase.Command;
  end;
  if FPanel.ReplyCount <> 0 then
  begin
    FPanel.ReplyIndex := 0;
    FPanel.Delay := 50;
  end;
end;

procedure TVt369Io.UpdatePanel(Pins: Byte);
begin
  var Clock := Pin(Pins, 2);
  if Clock = FPanel.ClockIn then
    Exit;

  FPanel.ClockIn := Clock;
  if FPanel.Bits <> 0 then
  begin
    FPanel.ClockOut := not FPanel.ClockOut;
    Dec(FPanel.Bits);
    FPanel.Shift := (FPanel.Shift shl 1) and $FF;
    FPanel.DataOut := Pin(FPanel.Shift, 7);
    if FPanel.Bits = 0 then
    begin
      FPanel.Phase := TPanelPhase.Command;
      if FPanel.ReplyIndex < FPanel.ReplyCount then
        FPanel.Delay := 10
      else
        FPanel.ReplyCount := 0;
    end;
  end
  else if FPanel.Delay = 0 then
  begin
    FPanel.ClockOut := Clock;
    if Clock then
      FPanel.Request := Pins and $F0
    else
      ProcessPanelByte(FPanel.Request or (Pins shr 4));
  end;
end;

procedure TVt369Io.ClockPanel;
begin
  if FPanel.Delay = 0 then
    Exit;
  Dec(FPanel.Delay);
  if FPanel.Delay = 0 then
  begin
    FPanel.Shift := FPanel.Reply[FPanel.ReplyIndex];
    Inc(FPanel.ReplyIndex);
    FPanel.Bits := 8;
    FPanel.DataOut := Pin(FPanel.Shift, 7);
    FPanel.ClockOut := True;
  end;
end;

function TVt369Io.PhoneBusValue(Response: Boolean): Byte;
const
  Signature: array[0..1] of Byte = ($93, $35);
begin
  if Response and (FPhoneResponseIndex < Length(Signature)) then
    Result := Signature[FPhoneResponseIndex]
  else
    Result := (FPhoneLatches[2] and $1F) or ((FPhoneLatches[4] and $1C) shl 3);
end;

function PhoneRegister(Address: Word): Integer;
begin
  case Address of
    $4144:
      Result := 0;
    $4147:
      Result := 1;
    $414F:
      Result := 2;
    $41E6:
      Result := 3;
    $41E7:
      Result := 4;
    $41EB:
      Result := 5;
  else
    Result := -1;
  end;
end;

function TVt369Io.Read(Address: Word; out Value: Byte): Boolean;
begin
  if FPhoneBoard then
  begin
    var Index := PhoneRegister(Address);
    if Index >= 0 then
    begin
      Value := FPhoneLatches[Index];
      case Index of
        2:
          Value := (Value and $E0) or (PhoneBusValue(True) and $1F);
        4:
          Value := (Value and $E3) or ((PhoneBusValue(True) shr 3) and $1C);
      end;
      Exit(True);
    end;
  end;
  var Port, RegisterIndex: Integer;
  Result := LocateRegister(Address, Port, RegisterIndex);
  if not Result then
    Exit;
  case RegisterIndex of
    0:
      Value := FPorts[Port].Direction;
    1:
      Value := FPorts[Port].Attribute;
    2:
      Value := FPorts[Port].Latch;
    3:
      begin
        var Input := $FF;
        if FParallelPanel then
        begin
          if Port = 2 then
            Input := $F5 or (Ord(FPanel.ClockOut) shl 1) or (Ord(FPanel.DataOut) shl 3);
          Value := (Input and not FPorts[Port].Direction) or
            (FPorts[Port].Latch and FPorts[Port].Direction);
          Exit;
        end;
        if Port = FInverterPort then
          if not FInverter.Output then
            Input := Input and not (1 shl FInverterDataBit);
        if Port = 2 then
        begin
          if (Length(FRom) <> 0) and not FSerial.Output then
            Input := Input and not $20;
          if HasSave and not FEeprom.Released then
            Input := Input and not 8;
        end;
        // The pin input register exposes input pins. The output latch has its own address.
        Value := Input and not FPorts[Port].Direction;
      end;
    4:
      if FParallelPanel then
        Value := 0
      else
        Value := $FF;
  else
    Value := $FF;
  end;
end;

function TVt369Io.Write(Address: Word; Value: Byte): Boolean;
begin
  if FPhoneBoard then
  begin
    var Index := PhoneRegister(Address);
    if Index >= 0 then
    begin
      var Rising := Value and not FPhoneLatches[Index];
      FPhoneLatches[Index] := Value;
      if (Index = 1) and ((Rising and $20) <> 0) then
      begin
        var Command := PhoneBusValue(False);
        if (FPhoneLastCommand = 0) and (Command = 0) then
          FPhoneResponseIndex := 0;
        FPhoneLastCommand := Command;
      end;
      if (Index = 5) and ((Rising and $10) <> 0) and (FPhoneResponseIndex < 2) then
        Inc(FPhoneResponseIndex);
      Exit(True);
    end;
  end;
  var Port, RegisterIndex: Integer;
  Result := LocateRegister(Address, Port, RegisterIndex);
  if not Result then
    Exit;
  case RegisterIndex of
    0:
      FPorts[Port].Direction := Value;
    1:
      FPorts[Port].Attribute := Value;
    2:
      FPorts[Port].Latch := Value;
    3:
      FPorts[Port].Latch := (FPorts[Port].Latch and not FPorts[Port].Direction) or
        (Value and FPorts[Port].Direction);
  end;
  var Pins := FPorts[Port].Pins;
  if FParallelPanel and (Port = 2) then
    UpdatePanel(Pins);
  if Port = FInverterPort then
    UpdateInverter(Pin(Pins, FInverterClockBit), Pin(Pins, FInverterDataBit));
  if Port = 2 then
  begin
    if Length(FRom) <> 0 then
      UpdateSerial(not Pin(Pins, 4), Pin(Pins, 3), Pin(Pins, 5));
    if HasSave then
      UpdateEeprom(Pin(Pins, 2), Pin(Pins, 3));
  end;
end;

procedure TVt369Io.UpdateSerial(Selected, Clock, Data: Boolean);
begin
  if not Selected or not FSerial.Selected then
  begin
    FSerial.Phase := TSerialPhase.Command;
    FSerial.BitIndex := 0;
    FSerial.Shift := 0;
    FSerial.Output := True;
  end
  else if Clock and not FSerial.Clock then
  begin
    case FSerial.Phase of
      TSerialPhase.Command, TSerialPhase.Parameter:
        begin
          FSerial.Shift := ((FSerial.Shift shl 1) or Ord(Data)) and $FF;
          Inc(FSerial.BitIndex);
          if FSerial.BitIndex = 8 then
          begin
            FSerial.BitIndex := 0;
            if FSerial.Phase = TSerialPhase.Parameter then
            begin
              if Length(FParameters) <> 0 then
                FSerial.Shift := FParameters[FSerial.Shift]
              else
                // Values observed on the late-revision phone-case board.
                case FSerial.Shift of
                  $02:
                    FSerial.Shift := $01;
                  $6D:
                    FSerial.Shift := $1E;
                  $B2:
                    FSerial.Shift := $02;
                else
                  FSerial.Shift := 0;
                end;
              FSerial.Phase := TSerialPhase.ReadParameter;
            end
            else if FSerial.Shift = $30 then
            begin
              FSerial.Phase := TSerialPhase.ReadRom;
              // The phone case's original dump includes an unused leading byte.
              if FPhoneBoard and (Length(FParameters) = 0) then
                FSerial.BitIndex := 8;
            end
            else if (FSerial.Shift = $10) and ((Length(FParameters) <> 0) or FPhoneBoard) then
              FSerial.Phase := TSerialPhase.Parameter
            else
              FSerial.Phase := TSerialPhase.Idle;
          end;
        end;
      TSerialPhase.ReadRom:
        begin
          FSerial.Output := Pin(FRom[FSerial.BitIndex shr 3], 7 - (FSerial.BitIndex and 7));
          FSerial.BitIndex := (FSerial.BitIndex + 1) and $7FF;
          if FSerial.BitIndex = 0 then
            FSerial.Phase := TSerialPhase.Command;
        end;
      TSerialPhase.ReadParameter:
        begin
          FSerial.Output := Pin(FSerial.Shift, 7 - FSerial.BitIndex);
          Inc(FSerial.BitIndex);
          if FSerial.BitIndex = 8 then
            FSerial.Phase := TSerialPhase.Idle;
        end;
    end;
  end;
  FSerial.Selected := Selected;
  FSerial.Clock := Clock;
end;

procedure TVt369Io.UpdateInverter(Clock, Data: Boolean);
begin
  if Clock and FInverter.Clock and (Data <> FInverter.Data) then
  begin
    FInverter.Bits := 0;
    FInverter.Shift := 0;
    if Data then
      FInverter.Phase := TInverterPhase.Response
    else
      FInverter.Phase := TInverterPhase.Command;
  end
  else if Clock and not FInverter.Clock then
  begin
    case FInverter.Phase of
      TInverterPhase.Command, TInverterPhase.Argument:
        begin
          FInverter.Shift := ((FInverter.Shift shl 1) or Ord(Data)) and $FF;
          Inc(FInverter.Bits);
          if FInverter.Bits = 8 then
          begin
            if FInverter.Phase = TInverterPhase.Command then
              if FInverter.Shift = $80 then
                FInverter.Phase := TInverterPhase.CommandAck
              else
                FInverter.Phase := TInverterPhase.Idle
            else
            begin
              var Negative := (-Integer(FInverter.Shift)) and $FF;
              FInverter.Reply := ((Negative and 15) shl 4) or (Negative shr 4);
              FInverter.Phase := TInverterPhase.ArgumentAck;
            end;
            FInverter.Bits := 0;
            FInverter.Shift := 0;
          end;
        end;
      TInverterPhase.CommandAck:
        FInverter.Phase := TInverterPhase.Argument;
      TInverterPhase.ArgumentAck:
        FInverter.Phase := TInverterPhase.Idle;
      TInverterPhase.Response:
        begin
          FInverter.Output := (FInverter.Reply and $80) <> 0;
          FInverter.Reply := (FInverter.Reply shl 1) and $FF;
        end;
    end;
  end;
  FInverter.Clock := Clock;
  FInverter.Data := Data;
end;

procedure TVt369Io.SetCpuFrequency(Frequency: Cardinal);
begin
  // Thirds of a base CPU cycle also represent the VT369's 3x CPU mode.
  FWriteCycleTicks := (Frequency * 3 + 199) div 200; // 5 ms write time
end;

procedure TVt369Io.ClockEeprom(Ticks: Integer);
begin
  if FEeprom.WriteTicks > 0 then
  begin
    Dec(FEeprom.WriteTicks, Ticks);
    if FEeprom.WriteTicks <= 0 then
      CommitEepromPage;
  end;
end;

procedure TVt369Io.CommitEepromPage;
begin
  var PageBase := FEeprom.Address and $FFF0;
  for var I := 0 to High(FEeprom.Page) do
    if (FEeprom.PageMask and (1 shl I)) <> 0 then
      FSave[PageBase + I] := FEeprom.Page[I];
  FEeprom.PageMask := 0;
  FEeprom.WriteTicks := 0;
end;

procedure TVt369Io.FinishEepromByte;
begin
  FEeprom.NextPhase := TI2cPhase.Writing;
  case FEeprom.Phase of
    TI2cPhase.Control:
      begin
        var Block := (FEeprom.Shift and 6) shl 7;
        if ((FEeprom.Shift and $F8) <> $A0) or (Block > FEepromAddressMask) or (FEeprom.WriteTicks > 0) then
        begin
          FEeprom.Phase := TI2cPhase.Idle;
          Exit;
        end;
        FEeprom.Address := (FEeprom.Address and $FF) or Block;
        if Odd(FEeprom.Shift) then
          FEeprom.NextPhase := TI2cPhase.Reading
        else
          FEeprom.NextPhase := TI2cPhase.Address;
      end;
    TI2cPhase.Address:
      FEeprom.Address := (FEeprom.Address and $FF00) or FEeprom.Shift;
    TI2cPhase.Writing:
      begin
        var Column := FEeprom.Address and 15;
        FEeprom.Page[Column] := FEeprom.Shift;
        FEeprom.PageMask := FEeprom.PageMask or (1 shl Column);
        // These EEPROMs wrap page writes within 16 bytes.
        FEeprom.Address := (FEeprom.Address and $FFF0) or ((FEeprom.Address + 1) and 15);
      end;
  end;
  FEeprom.Phase := TI2cPhase.DeviceAck;
  FEeprom.Released := False;
  FEeprom.Bits := 0;
  FEeprom.Shift := 0;
end;

procedure TVt369Io.UpdateEeprom(Clock, Data: Boolean);
begin
  if Clock and FEeprom.Clock and (Data <> FEeprom.Data) then
  begin
    FEeprom.Released := True;
    FEeprom.Bits := 0;
    FEeprom.Shift := 0;
    if Data then
    begin
      if (FEeprom.PageMask <> 0) and (FEeprom.WriteTicks = 0) then
        FEeprom.WriteTicks := FWriteCycleTicks;
      FEeprom.Phase := TI2cPhase.Idle;
    end
    else
    begin
      if FEeprom.WriteTicks = 0 then
        FEeprom.PageMask := 0;
      FEeprom.Phase := TI2cPhase.Control;
    end;
  end
  else if Clock and not FEeprom.Clock then
  begin
    case FEeprom.Phase of
      TI2cPhase.Control, TI2cPhase.Address, TI2cPhase.Writing:
        begin
          FEeprom.Shift := ((FEeprom.Shift shl 1) or Ord(Data)) and $FF;
          Inc(FEeprom.Bits);
        end;
      TI2cPhase.Reading, TI2cPhase.DeviceAck:
        Inc(FEeprom.Bits);
      TI2cPhase.MasterAck:
        begin
          FEeprom.NextPhase := TI2cPhase.Idle;
          if not Data then
            FEeprom.NextPhase := TI2cPhase.Reading;
          Inc(FEeprom.Bits);
        end;
    end;
  end
  else if not Clock and FEeprom.Clock then
  begin
    case FEeprom.Phase of
      TI2cPhase.Control, TI2cPhase.Address, TI2cPhase.Writing:
        if FEeprom.Bits = 8 then
          FinishEepromByte;
      TI2cPhase.DeviceAck, TI2cPhase.MasterAck:
        if FEeprom.Bits = 1 then
        begin
          FEeprom.Phase := FEeprom.NextPhase;
          FEeprom.Bits := 0;
          FEeprom.Released := True;
          if FEeprom.Phase = TI2cPhase.Reading then
            FEeprom.Released := Pin(FSave[FEeprom.Address], 7);
        end;
      TI2cPhase.Reading:
        if FEeprom.Bits < 8 then
          FEeprom.Released := Pin(FSave[FEeprom.Address], 7 - FEeprom.Bits)
        else
        begin
          FEeprom.Address := (FEeprom.Address + 1) and FEepromAddressMask;
          FEeprom.Phase := TI2cPhase.MasterAck;
          FEeprom.Bits := 0;
          FEeprom.Released := True;
        end;
    end;
  end;
  FEeprom.Clock := Clock;
  FEeprom.Data := Data;
end;

procedure TVt369Io.SerializeState(State: TNesStateArchive);
begin
  State.Field(FPorts, SizeOf(FPorts));
  State.Field(FSerial, SizeOf(FSerial));
  State.Field(FInverter, SizeOf(FInverter));
  State.Field(FEeprom, SizeOf(FEeprom));
  if FPhoneBoard then
  begin
    State.Field(FPhoneLatches, SizeOf(FPhoneLatches));
    State.Field(FPhoneLastCommand, SizeOf(FPhoneLastCommand));
    State.Field(FPhoneResponseIndex, SizeOf(FPhoneResponseIndex));
  end;
  if FParallelPanel then
  begin
    State.Field(FPanel, SizeOf(FPanel));
    State.Field(FPanelMemory, SizeOf(FPanelMemory));
    State.Field(FPanelX, SizeOf(FPanelX));
    State.Field(FPanelY, SizeOf(FPanelY));
    if State.Loading and ((Ord(FPanel.Phase) > Ord(High(TPanelPhase))) or
      (FPanel.Bits > 8) or (FPanel.Delay > 50) or (FPanel.ReplyCount > Length(FPanel.Reply)) or
      (FPanel.ReplyIndex > Length(FPanel.Reply)) or
      ((FPanel.Delay <> 0) and (FPanel.ReplyIndex >= FPanel.ReplyCount))) then
      raise ENesException.Create('Invalid VT389 panel state');
  end;
  if HasSave then
  begin
    State.Field(FSave[0], $200);
    if Length(FSave) > $200 then
      if State.Version >= 31 then
        State.Field(FSave[$200], Length(FSave) - $200)
      else if State.Loading then
        FillChar(FSave[$200], Length(FSave) - $200, $FF);
  end;
  if State.Loading and ((Ord(FSerial.Phase) > Ord(High(TSerialPhase))) or
    (FSerial.BitIndex < 0) or (FSerial.BitIndex >= $800) or
    (FSerial.Shift < 0) or (FSerial.Shift > $FF) or
    ((FSerial.Phase = TSerialPhase.Parameter) and (Length(FParameters) = 0) and not FPhoneBoard) or
    (FPhoneResponseIndex > 2) or
    (Ord(FInverter.Phase) > Ord(High(TInverterPhase))) or (FInverter.Bits > 8) or
    (Ord(FEeprom.Phase) > Ord(High(TI2cPhase))) or (Ord(FEeprom.NextPhase) > Ord(High(TI2cPhase))) or
    (FEeprom.Address > FEepromAddressMask) or (FEeprom.Bits > 8) or
    (FEeprom.WriteTicks < 0) or (FEeprom.WriteTicks > FWriteCycleTicks) or
    (not HasSave and (FEeprom.WriteTicks <> 0))) then
    raise ENesException.Create('Invalid VT369 serial peripheral state');
end;

function TVt369Io.HasSave: Boolean;
begin
  Result := Length(FSave) <> 0;
end;

function TVt369Io.GetSaveMemory: TByteArray;
begin
  Result := Copy(FSave);
end;

procedure TVt369Io.SetSaveMemory(const Data: TByteArray);
begin
  if Length(Data) <> Length(FSave) then
    raise ENesException.Create('Invalid VT369 EEPROM save size');
  FSave := Copy(Data);
end;

end.

